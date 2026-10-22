/**
 * GeoDataInstaller —— 内置 geo 数据安装器。
 *
 * 职责：
 *  · 把随包携带的 `geoip.metadb` / `geosite.dat` 复制到内核的工作目录
 *    （`cacheDir`，也就是 mihomo 的 homeDir），供内核在启动时直接加载。
 *
 * 来源与事实依据（2026-10-22 真机取证）：
 *  · 全新安装（或清了数据）的设备上 cacheDir 里没有 geo 文件，内核日志停在
 *    `Geodata Loader mode: memconservative` → `Can't find MMDB, start download`，
 *    随后联网下载 MMDB 卡死，20s 硬超时 → 测速核/隧道核都起不来。
 *  · 外在表现就是用户报的两个现象：导入订阅后点测速「立刻返回测速完成」
 *    （0 个测速目标），以及启动 VPN 直接报错（内核启动失败）。
 *  · FlClash 之所以没这个问题，是因为它的安装包自带 geo 数据并在启动时落盘。
 *
 * 关键口径：
 *  · 幂等：文件存在且大小与随包资源一致才跳过；大小不符（历史残缺文件）重写。
 *  · 纯本地：不联网、不覆盖用户其它文件；也不删除任何东西。
 *  · 文件名必须与 mihomo 的查找名一致：`geoip.metadb`（MMDB）与 `geosite.dat`。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'GeoDataInstaller';

/** 随包资源名 → 落盘文件名（mihomo homeDir 内的固定查找名） */
interface GeoAsset {
  raw: string;
  target: string;
}

const GEO_ASSETS: GeoAsset[] = [
  { raw: 'geoip.metadb', target: 'geoip.metadb' },
  { raw: 'geosite.dat', target: 'geosite.dat' }
];

export class GeoDataInstaller {
  /** 本进程是否已检查过（复制 14MB 不该反复做） */
  private static installed: boolean = false;

  /**
   * 确保 geo 文件就位。任一文件缺失/大小不符才写盘。
   * 任何异常只记日志不抛出 —— geo 缺失最多让内核退回联网下载，不该阻断启动。
   */
  static ensure(context: common.Context): void {
    if (GeoDataInstaller.installed) {
      return;
    }
    GeoDataInstaller.installed = true;
    const dir = context.cacheDir;
    for (const asset of GEO_ASSETS) {
      const path = `${dir}/${asset.target}`;
      try {
        let raw: Uint8Array | null = null;
        try {
          raw = context.resourceManager.getRawFileContentSync(asset.raw);
        } catch (e) {
          AppLogger.warn(TAG, `raw asset missing: ${asset.raw}`);
          continue;
        }
        if (raw === null || raw.length === 0) {
          continue;
        }
        let existingSize = -1;
        try {
          existingSize = fs.statSync(path).size;
        } catch (e) {
          existingSize = -1;
        }
        // 只在「目标不存在 / 比随包资源小」时才写。
        // 反过来（existing 更大）说明用户已经更新过全量数据 —— 绝不能用随包的
        // 最小占位库把它覆盖回去（降级），那会让 GEOIP 分流范围突然缩水。
        if (existingSize >= raw.length) {
          continue;
        }
        const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(file.fd, raw.buffer as ArrayBuffer);
        } finally {
          fs.closeSync(file);
        }
        AppLogger.info(TAG, `geo installed: ${asset.target} ${raw.length} bytes (was ${existingSize})`);
      } catch (e) {
        AppLogger.warn(TAG, `install ${asset.target} failed: ${AppLogger.errText(e)}`);
      }
    }
  }

  /** 供测试/排障：重置本进程标记 */
  static resetForTest(): void {
    GeoDataInstaller.installed = false;
  }
}
