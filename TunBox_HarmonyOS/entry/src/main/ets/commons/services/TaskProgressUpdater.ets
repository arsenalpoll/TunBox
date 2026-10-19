/**
 * dataTransfer 长时任务的进度心跳（官方要求，见 startBackgroundRunning 官方示例）。
 *
 * 官方原文：「当长时任务类型包含数据传输(dataTransfer)时，应用需要更新进度，其他
 * 类型不需要」；「如果进度长时间（首次更新超过10分钟）未更新，数据传输的长时任务
 * 会被取消」。更新方式 = 用申请时返回的 notificationId 发一帧 downloadTemplate
 * 系统实况通知（typeCode 固定 8 = dataTransfer，slotType 必须为 LIVE_VIEW），
 * 该通道不需要另行申请实况窗场景权益。
 *
 * 本实现的取舍：
 *  - 进度值对 VPN 没有真实百分比语义 → 以「已连接分钟数 % 100」推进进度条，
 *    fileName 展示已连接时长；title/text 展示运行状态。更新内容仅限进度展示，
 *    与接入规范对 dataTransfer 的豁免条款（可更新进度信息）保持一致。
 *  - 发布失败（通知被禁用 1600004 / 任务已不存在等）只做节流日志，不重试风暴；
 *    任务被外部取消时由 BackgroundTaskWatch → detach() 止损。
 */
import { notificationManager } from '@kit.NotificationKit';
import { AppLogger } from '../utils/AppLogger';
import { SsrvpnNotifier } from './SsrvpnNotifier';

const TAG = 'TaskProgressUpdater';
/** 更新周期：官方窗口为 10 分钟，这里 5 分钟留一倍冗余 */
const UPDATE_INTERVAL_MS: number = 5 * 60 * 1000;
/** dataTransfer 类型实况通知固定 typeCode（官方示例：当前仅支持 8） */
const TYPE_CODE_DATA_TRANSFER: number = 8;
/** 仅支持的模板名（官方：downloadTemplate） */
const TEMPLATE_NAME: string = 'downloadTemplate';
/** 失败日志节流窗口：避免周期性刷屏 */
const FAIL_LOG_THROTTLE_MS: number = 10 * 60 * 1000;

export class TaskProgressUpdater {
  private static taskNotificationId: number = -1;
  private static timer: number = -1;
  // 2026-10-19：原 startedAt 仅用于把「已连接分钟数」写进 progressValue（圆环进度）。
  // 用户要求去掉圆环后该字段再无读取方，删除以免留下只写不读的死字段。
  private static lastFailLogAt: number = 0;
  /** 最近一次实况内容（流量心跳更新，5 分钟心跳沿用同一内容） */
  private static lastNodeText: string = 'TunBox';
  private static lastSpeedLine: string = '隧道已连接 · 持续保护中';
  private static lastDurationText: string = '';

  /**
   * 实况内容更新（连接期间由流量轮询每 2s 调用）：节点名进 title、速率+时长进
   * fileName —— 与「已连接 X 分钟」同一渲染位，不新增第二条通知。长时任务通知
   * 是系统强制的（dataTransfer 连续任务），应用自己的常驻通知与它重复，已合并到
   * 这里。任务通知 id 未拿到（长时任务未挂上）时退回应用自有通知兜底。
   */
  static updateLive(nodeText: string, speedLine: string, durationText: string): void {
    TaskProgressUpdater.lastNodeText = nodeText.trim().length > 0 ? nodeText.trim() : 'TunBox';
    TaskProgressUpdater.lastSpeedLine = speedLine;
    TaskProgressUpdater.lastDurationText = durationText;
    const id = TaskProgressUpdater.taskNotificationId;
    if (id < 0) {
      // 长时任务未挂上：退回应用自有通知（attach 成功时会被 cancel，避免双通知）。
      // 2026-10-19：同样避免超长——自有通知正文单行，只放速率，时长单独成行。
      SsrvpnNotifier.update(`TunBox · ${TaskProgressUpdater.lastNodeText}`,
        durationText.length > 0 ? `已运行 ${durationText}` : '',
        speedLine).catch((): void => {});
      return;
    }
    TaskProgressUpdater.push();
  }

  /** 长时任务申请成功后调用：接管返回的 notificationId，立即推一帧并起周期心跳。 */
  static attach(notificationId: number): void {
    TaskProgressUpdater.detach();
    if (typeof notificationId !== 'number' || notificationId < 0) {
      AppLogger.warn(TAG, `attach skipped: invalid notificationId (${notificationId})`);
      return;
    }
    TaskProgressUpdater.taskNotificationId = notificationId;
    // 应用自有常驻通知与长时任务通知重复（用户实锤「两个通知消息」），接管即撤
    SsrvpnNotifier.cancel().catch((): void => {});
    TaskProgressUpdater.push();
    TaskProgressUpdater.timer = setInterval((): void => {
      TaskProgressUpdater.push();
    }, UPDATE_INTERVAL_MS);
    AppLogger.info(TAG, `progress heartbeat attached (taskNotificationId=${notificationId})`);
  }

  /** 释放 / 断开 / 任务取消时调用（幂等）。 */
  static detach(): void {
    if (TaskProgressUpdater.timer >= 0) {
      clearInterval(TaskProgressUpdater.timer);
      TaskProgressUpdater.timer = -1;
    }
    TaskProgressUpdater.taskNotificationId = -1;
  }

  static isActive(): boolean {
    return TaskProgressUpdater.taskNotificationId >= 0;
  }

  /**
   * 速率串紧凑化，用于挤进实况通知的单行正文。
   *   "↓ 56.0 KB/s  ↑ 0 B/s" → "↓56KB/s ↑0B/s"
   * 只动空白与整数位的小数点（56.0→56），不改数值语义；1.5 MB/s 保持 1.5MB/s。
   */
  private static compactSpeed(line: string): string {
    return line
      .replace(/(\d)\.0(?=\s*[KMG]?B\/s)/g, '$1')
      .replace(/(\d)\s+([KMG]?B\/s)/g, '$1$2')
      .replace(/\s+/g, ' ')
      .trim();
  }

  /** 单帧进度更新（失败绝不抛出，只做节流日志）。 */
  private static push(): void {
    const id = TaskProgressUpdater.taskNotificationId;
    if (id < 0) {
      return;
    }
    const nodeText = TaskProgressUpdater.lastNodeText;
    // 2026-10-19 用户两轮反馈，合并后的正确口径：
    //   第一轮：「把右侧的那个圆环去掉，改成运行时长」；
    //   第二轮：「我是让你把右侧圆环改成运行时间，你怎么把上传下载的速率改没了」。
    //
    // 实测结论（用户截图 + SDK 文档）：
    //   · 右侧圆环是 downloadTemplate 自带的结构元素，**不是** progressValue 画出来的
    //     —— 删掉 progressValue 后圆环仍在（真机截图确认）；SDK 亦注明长时任务的
    //     系统实况通知「Currently, only downloadTemplate is supported」，换不掉。
    //     因此圆环无法在保留系统实况通知的前提下移除，已在此处注明，避免再次误判。
    //   · 实况通知只有「标题」+「单行正文」两个文本位。既然速率与时长都要保留，
    //     两者只能共用这一行。
    //   · 为不让之前的截断问题重演，速率串做去空格/去 .0 的紧凑化
    //     （"↓ 56.0 KB/s ↑ 0 B/s" → "↓56KB/s ↑0B/s"），时长用 0:00:56 紧凑写法。
    const speed = TaskProgressUpdater.compactSpeed(TaskProgressUpdater.lastSpeedLine);
    const duration = TaskProgressUpdater.lastDurationText;
    const liveLine = duration.length > 0 ? `${speed} · ${duration}` : speed;
    const data: Record<string, Object> = {};
    data['title'] = nodeText;
    data['fileName'] = liveLine;
    const request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: {
          typeCode: TYPE_CODE_DATA_TRANSFER,
          title: `TunBox · ${nodeText}`,
          text: liveLine
        }
      },
      template: {
        name: TEMPLATE_NAME,
        data: data
      }
    };
    notificationManager.publish(request).then((): void => {
      TaskProgressUpdater.lastFailLogAt = 0;
    }).catch((e: Error): void => {
      const now = Date.now();
      if (now - TaskProgressUpdater.lastFailLogAt > FAIL_LOG_THROTTLE_MS) {
        TaskProgressUpdater.lastFailLogAt = now;
        AppLogger.warn(TAG, `progress update failed: ${AppLogger.errText(e)}`);
      }
    });
  }
}
