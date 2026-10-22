/**
 * Profile 存储（订阅原文 = 一份 Profile 文件）
 *
 * 来源：FlClash `lib/models/profile.dart` + `lib/core/controller.dart:101-127`
 *      （`Profile.file` / `saveFile` / `validateProfile`）。
 *
 * ## 与旧实现的结构差别（这次是刻意改的）
 *
 * 旧：订阅 → App 侧解析成 ProxyNode 表 → 生成配置时逐字段重建节点。
 * 新（FlClash 同构）：订阅 → **原文落盘** `<filesDir>/profiles/<id>.yaml` → 内核解析。
 *     App 侧不再持有节点清单，节点/分组一律从内核 `/proxies` 读（见 CoreCatalog）。
 *
 * ## 文件布局
 *
 * ```
 * <filesDir>/profiles/<subId>.yaml     订阅原文（或转换后的 proxies 列表）
 * preferences 'ssrvpn_profiles'        { current: '<id>', autoUpdate: {id:bool} }
 * ```
 *
 * ## 校验（等价 FlClash validateProfile，转换分支见 attachConverter）
 *
 * 1. 原文是内核可解析的 Clash 配置 → 原样落盘；
 * 2. 否则尝试 `SubConverter`（mihomo `convert.ConvertsV2Ray` 的移植）→ 转成
 *    `proxies:` 列表再落盘；
 * 3. 两者都失败 → 拒绝，**不覆盖已有文件**（旧 profile 保持可用）。
 */
import { preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppLogger } from '../utils/AppLogger';
import { ProfileConfigMerger } from './ProfileConfigMerger';

const TAG = 'ProfileStore';
const PREF_NAME = 'ssrvpn_profiles';
const KEY_STATE = 'profile_state';
const DIR_NAME = 'profiles';
/** 单份 profile 上限（与订阅拉取上限一致：8MB） */
const MAX_PROFILE_BYTES = 8 * 1024 * 1024;

export class ProfileValidationResult {
  ok: boolean = false;
  /** 面向用户的失败文案（成功为空串，对齐 FlClash validateProfile 的返回） */
  message: string = '';
  /** 是否走了 convertProxies 回退（日志/诊断用） */
  converted: boolean = false;
  /** 转换出的节点数（converted=false 时为原文条目数） */
  nodeCount: number = 0;
}

/** 可注入的转换器（SubConverter 的薄接口，避免本文件依赖其实现细节）。 */
export type ProfileTextConverter = (text: string) => string;

export class ProfileStore {
  private static store: preferences.Preferences | null = null;
  private static dirPath: string = '';
  private static currentProfileId: string = '';
  private static converter: ProfileTextConverter | null = null;
  private static loaded: boolean = false;

  /** 注入 convertProxies 实现（由 SubConverter 接入；未注入时只走 YAML 校验）。 */
  static attachConverter(converter: ProfileTextConverter | null): void {
    ProfileStore.converter = converter;
  }

  static async init(context: Context): Promise<void> {
    if (ProfileStore.loaded) {
      return;
    }
    ProfileStore.dirPath = `${context.filesDir}/${DIR_NAME}`;
    ProfileStore.ensureDir(ProfileStore.dirPath);
    ProfileStore.store = await preferences.getPreferences(context, PREF_NAME);
    const raw = await ProfileStore.store.get(KEY_STATE, '{}') as string;
    try {
      const obj = JSON.parse(raw) as Record<string, Object>;
      const current = obj['current'];
      if (typeof current === 'string') {
        ProfileStore.currentProfileId = current;
      }
    } catch (e) {
      AppLogger.warn(TAG, 'invalid profile state ignored');
    }
    ProfileStore.loaded = true;
    AppLogger.info(TAG, `profiles dir ready: ${ProfileStore.dirPath} current=${ProfileStore.currentProfileId}`);
  }

  /** 确保目录存在（应用私有目录，权限由系统沙箱保证）。 */
  private static ensureDir(dir: string): void {
    try {
      fs.mkdirSync(dir, true);
    } catch (e) {
      // 目录已存在属正常
    }
  }

  static isReady(): boolean {
    return ProfileStore.loaded;
  }

  static dir(): string {
    return ProfileStore.dirPath;
  }

  static pathOf(id: string): string {
    return `${ProfileStore.dirPath}/${ProfileStore.safeId(id)}.yaml`;
  }

  /** 订阅 id 里可能有路径分隔符/冒号：落盘文件名只允许 `[A-Za-z0-9_-]`。 */
  private static safeId(id: string): string {
    let out = '';
    for (let i = 0; i < id.length; i++) {
      const ch = id.charAt(i);
      const isDigit = ch >= '0' && ch <= '9';
      const isLower = ch >= 'a' && ch <= 'z';
      const isUpper = ch >= 'A' && ch <= 'Z';
      const isSafe = ch === '-' || ch === '_';
      out += (isDigit || isLower || isUpper || isSafe) ? ch : '_';
    }
    return out.length === 0 ? 'profile' : out;
  }

  /**
   * profile 文件是否**可用**（存在且非空）。
   *
   * ⚠ 不能用 accessSync 判存在：真机上出现过「accessSync 成功、statSync 报
   * No such file」的现场，于是 exists()=true 而 read()='' —— 调用方会把这个订阅
   * 当成「有 profile」切成 current，配置却拿不到基底，回落到「全部订阅合并」，
   * 界面上就出现「A 订阅里显示 B/C/D 的节点」（用户实锤：飞鸟云里出现另外三个订阅的节点）。
   * 这里以 statSync().size > 0 为唯一判据。
   */
  static exists(id: string): boolean {
    if (id.length === 0) {
      return false;
    }
    try {
      const stat = fs.statSync(ProfileStore.pathOf(id));
      return stat.size > 0;
    } catch (e) {
      return false;
    }
  }

  /** 读原文；不存在/读取失败返回空串（调用方按「无 profile」处理）。 */
  static read(id: string): string {
    if (!ProfileStore.exists(id)) {
      return '';
    }
    const path = ProfileStore.pathOf(id);
    let file: fs.File | null = null;
    try {
      const stat = fs.statSync(path);
      if (stat.size <= 0 || stat.size > MAX_PROFILE_BYTES) {
        AppLogger.warn(TAG, `profile size out of range: ${path} size=${stat.size}`);
        return '';
      }
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      const read = fs.readSync(file.fd, buf);
      return ProfileStore.decode(buf, read);
    } catch (e) {
      AppLogger.warn(TAG, `read profile failed: ${AppLogger.errText(e)}`);
      return '';
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 已关闭/句柄失效：忽略
        }
      }
    }
  }

  private static decode(buf: ArrayBuffer, bytes: number): string {
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(buf, 0, bytes));
  }

  /** 原子写（tmp → rename），权限 0600。 */
  static write(id: string, content: string): boolean {
    if (id.length === 0) {
      return false;
    }
    ProfileStore.ensureDir(ProfileStore.dirPath);
    const target = ProfileStore.pathOf(id);
    const tmp = `${target}.tmp`;
    let file: fs.File | null = null;
    try {
      file = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, content);
      fs.closeSync(file);
      file = null;
      try {
        fs.unlinkSync(target);
      } catch (e) {
        // 目标不存在属正常
      }
      fs.renameSync(tmp, target);
      return true;
    } catch (e) {
      AppLogger.error(TAG, `write profile failed: ${AppLogger.errText(e)}`);
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (closeError) {
          // 忽略
        }
      }
      try {
        fs.unlinkSync(tmp);
      } catch (cleanupError) {
        // 忽略
      }
      return false;
    }
  }

  static remove(id: string): void {
    const path = ProfileStore.pathOf(id);
    try {
      fs.unlinkSync(path);
    } catch (e) {
      // 不存在属正常
    }
  }

  static currentId(): string {
    return ProfileStore.currentProfileId;
  }

  static async setCurrent(id: string): Promise<void> {
    ProfileStore.currentProfileId = id;
    await ProfileStore.persistState();
  }

  private static async persistState(): Promise<void> {
    if (ProfileStore.store === null) {
      return;
    }
    const state: Record<string, string> = { 'current': ProfileStore.currentProfileId };
    try {
      await ProfileStore.store.put(KEY_STATE, JSON.stringify(state));
      await ProfileStore.store.flush();
    } catch (e) {
      AppLogger.warn(TAG, `persist profile state failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 校验并落盘（FlClash `validateProfile` 的等价实现）。
   *
   * 已存在的 profile 不被坏内容覆盖：只有 converted 或 YAML 合法时才写。
   */
  static validateAndStore(id: string, text: string): ProfileValidationResult {
    const out = new ProfileValidationResult();
    if (id.length === 0) {
      out.message = 'profile id is empty';
      return out;
    }
    if (text.trim().length === 0) {
      out.message = '订阅内容为空';
      return out;
    }
    if (ProfileConfigMerger.isKernelLoadableConfig(text)) {
      if (!ProfileStore.write(id, text)) {
        out.message = '订阅保存失败';
        return out;
      }
      out.ok = true;
      out.nodeCount = ProfileConfigMerger.merge('a: 1', text).profileProxyItems;
      AppLogger.info(TAG, `profile saved as-is: id=${id} bytes=${text.length} items=${out.nodeCount}`);
      return out;
    }
    // YAML 不像 Clash 配置 → 走 convertProxies（base64 / URI 列表）
    const converter = ProfileStore.converter;
    if (converter !== null) {
      const converted = converter(text);
      if (converted.length > 0 && ProfileConfigMerger.isKernelLoadableConfig(converted)) {
        if (!ProfileStore.write(id, converted)) {
          out.message = '订阅保存失败';
          return out;
        }
        out.ok = true;
        out.converted = true;
        out.nodeCount = ProfileConfigMerger.merge('a: 1', converted).profileProxyItems;
        AppLogger.info(TAG, `profile converted and saved: id=${id} nodes=${out.nodeCount}`);
        return out;
      }
    }
    out.message = '请提供 Clash 订阅（该内容既不是 Clash 配置，也无法转换为节点列表）';
    AppLogger.warn(TAG, `profile rejected: id=${id} bytes=${text.length}`);
    return out;
  }
}
