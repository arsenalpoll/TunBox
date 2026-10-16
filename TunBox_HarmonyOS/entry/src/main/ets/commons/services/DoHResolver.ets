/** 代理入口 DoH 预解析。每条 pin 独立计时，允许有界 stale 使用，不在命中或落盘时续期。 */
import { http } from '@kit.NetworkKit';
import { AppLogger } from '../utils/AppLogger';
import { SettingsService } from './SettingsService';

const TAG = 'DoHResolver';
const ENDPOINTS: string[] = ['https://doh.pub/dns-query', 'https://dns.alidns.com/resolve'];
const FRESH_TTL_MS = 12 * 60 * 60 * 1000;
const USABLE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const PERSIST_DEBOUNCE_MS = 2000;

interface DoHAnswer {
  name: string;
  type: number;
  data: string;
}
interface DoHResponse {
  Status: number;
  Answer?: DoHAnswer[];
}
class DoHPin {
  ip: string;
  resolvedAt: number;
  constructor(ip: string, resolvedAt: number) {
    this.ip = ip;
    this.resolvedAt = resolvedAt;
  }
}

export class DoHResolver {
  private static cache: Map<string, DoHPin> = new Map<string, DoHPin>();
  private static readonly CACHE_MAX_ENTRIES: number = 512;
  private static readonly WORKERS: number = 16;
  private static loaded: boolean = false;
  private static loading: Promise<void> | null = null;
  private static refreshing: Promise<number> | null = null;
  private static persistTimer: number = -1;
  private static staleQueue: Set<string> = new Set<string>();

  /** 并发调用共享同一载入任务；失败允许下一次重试。 */
  static async ensureLoaded(): Promise<void> {
    if (DoHResolver.loaded) {
      return;
    }
    if (DoHResolver.loading !== null) {
      return DoHResolver.loading;
    }
    const task = DoHResolver.loadPersisted();
    DoHResolver.loading = task;
    try {
      await task;
    } finally {
      DoHResolver.loading = null;
    }
  }

  private static async loadPersisted(): Promise<void> {
    try {
      const persisted = await SettingsService.loadDohPins();
      const now = Date.now();
      for (const domain of Object.keys(persisted)) {
        const packed = persisted[domain];
        if (typeof packed !== 'string') {
          continue;
        }
        const bar = packed.indexOf('|');
        const ip = bar > 0 ? packed.substring(0, bar) : '';
        const ts = bar > 0 ? Number(packed.substring(bar + 1)) : 0;
        if (!DoHResolver.looksLikeIPv4(ip) || !Number.isFinite(ts) || ts <= 0
          || ts > now || now - ts > USABLE_TTL_MS) {
          continue;
        }
        DoHResolver.cachePut(domain.toLowerCase(), ip, false, ts);
      }
      DoHResolver.loaded = true;
    } catch (e) {
      AppLogger.warn(TAG, `doh pin cache load failed: ${AppLogger.errText(e)}`);
    }
  }

  /** 命中时同样检查年龄；长驻进程不能无限使用已经失效的 IP。 */
  private static cachedIp(domain: string): string {
    const pin = DoHResolver.cache.get(domain);
    if (pin === undefined) {
      return '';
    }
    const age = Date.now() - pin.resolvedAt;
    if (age < 0 || age > USABLE_TTL_MS) {
      DoHResolver.cache.delete(domain);
      DoHResolver.staleQueue.delete(domain);
      return '';
    }
    if (age > FRESH_TTL_MS) {
      DoHResolver.staleQueue.add(domain);
    }
    DoHResolver.cache.delete(domain);
    DoHResolver.cache.set(domain, pin);
    return pin.ip;
  }

  static async resolveMany(domains: string[], budgetMs: number = 6000,
    priorityDomains: string[] = []): Promise<Record<string, string>> {
    await DoHResolver.ensureLoaded();
    const result: Record<string, string> = {};
    const seen = new Set<string>();
    let pending: string[] = [];
    const priority = new Set<string>();
    for (const raw of priorityDomains) {
      priority.add(raw.toLowerCase());
    }
    for (const raw of domains) {
      const d = raw.toLowerCase();
      if (seen.has(d)) {
        continue;
      }
      seen.add(d);
      const cached = DoHResolver.cachedIp(d);
      if (cached.length > 0) {
        result[d] = cached;
      } else {
        pending.push(d);
      }
    }
    pending = DoHResolver.sortByPriority(pending, priority);
    const deadline = Date.now() + Math.max(0, budgetMs);
    for (let pass = 0; pass < 2 && pending.length > 0; pass++) {
      const current = pending;
      const remaining: string[] = [];
      const workers: Promise<void>[] = [];
      let idx = 0;
      for (let w = 0; w < DoHResolver.WORKERS; w++) {
        workers.push((async (): Promise<void> => {
          while (Date.now() < deadline && idx < current.length) {
            const d = current[idx++];
            const ip = await DoHResolver.resolveANoCache(d, deadline);
            if (ip.length > 0) {
              result[d] = ip;
            } else {
              remaining.push(d);
            }
          }
        })());
      }
      await Promise.all(workers);
      if (Date.now() >= deadline) {
        break;
      }
      pending = remaining;
    }
    return result;
  }

  /** 在编排器允许的预连接窗口调用；失败/未处理项留队，成功查询才移除。 */
  static async refreshStale(budgetMs: number = 20000): Promise<number> {
    await DoHResolver.ensureLoaded();
    if (DoHResolver.refreshing !== null) {
      return DoHResolver.refreshing;
    }
    const task = DoHResolver.refreshQueued(budgetMs);
    DoHResolver.refreshing = task;
    try {
      return await task;
    } finally {
      DoHResolver.refreshing = null;
    }
  }

  private static async refreshQueued(budgetMs: number): Promise<number> {
    // 即使没有 resolveMany，也要发现长驻进程中新过期的条目。
    const keys: string[] = Array.from(DoHResolver.cache.keys());
    for (const domain of keys) {
      DoHResolver.cachedIp(domain);
    }
    const todo: string[] = Array.from(DoHResolver.staleQueue);
    const deadline = Date.now() + Math.max(0, budgetMs);
    let idx = 0;
    let updated = 0;
    const workers: Promise<void>[] = [];
    for (let w = 0; w < 4; w++) {
      workers.push((async (): Promise<void> => {
        while (Date.now() < deadline && idx < todo.length) {
          const d = todo[idx++];
          if ((await DoHResolver.resolveANoCache(d, deadline)).length > 0) {
            updated++;
          }
        }
      })());
    }
    await Promise.all(workers);
    return updated;
  }

  private static sortByPriority(list: string[], priority: Set<string>): string[] {
    const head: string[] = [];
    const tail: string[] = [];
    for (const d of list) {
      if (priority.has(d)) {
        head.push(d);
      } else {
        tail.push(d);
      }
    }
    return head.concat(tail);
  }

  static async resolveA(domain: string): Promise<string> {
    await DoHResolver.ensureLoaded();
    const d = domain.toLowerCase();
    const cached = DoHResolver.cachedIp(d);
    return cached.length > 0 ? cached : DoHResolver.resolveANoCache(d, Date.now() + 10000);
  }

  private static async resolveANoCache(domain: string, deadline: number): Promise<string> {
    for (const ep of ENDPOINTS) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) {
        break;
      }
      const req = http.createHttp();
      // SDK 的连接/读取 timeout 不是共同截止时间，额外定时销毁覆盖完整请求预算。
      const deadlineTimer = setTimeout((): void => { req.destroy(); }, remaining);
      try {
        const resp = await req.request(ep + '?name=' + encodeURIComponent(domain) + '&type=A', {
          method: http.RequestMethod.GET,
          header: { 'Accept': 'application/dns-json', 'User-Agent': 'TunBox' } as Record<string, string>,
          connectTimeout: Math.min(2500, remaining),
          readTimeout: Math.min(2500, remaining),
          expectDataType: http.HttpDataType.STRING,
          usingCache: false
        } as http.HttpRequestOptions);
        if (Date.now() >= deadline || resp.responseCode !== 200 || typeof resp.result !== 'string') {
          continue;
        }
        const parsed = JSON.parse(resp.result as string) as DoHResponse;
        if (parsed.Status !== 0 || !Array.isArray(parsed.Answer)) {
          continue;
        }
        for (const a of parsed.Answer) {
          if (a.type === 1 && typeof a.data === 'string' && DoHResolver.looksLikeIPv4(a.data)) {
            DoHResolver.cachePut(domain, a.data, true, Date.now());
            return a.data;
          }
        }
      } catch (e) {
        AppLogger.info(TAG, `DoH query failed: ${AppLogger.errText(e)}`);
      } finally {
        clearTimeout(deadlineTimer);
        req.destroy();
      }
    }
    return '';
  }

  private static looksLikeIPv4(s: string): boolean {
    const parts = s.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (const p of parts) {
      const n = Number(p);
      if (!Number.isInteger(n) || n < 0 || n > 255 || `${n}` !== p) {
        return false;
      }
    }
    return true;
  }

  private static cachePut(domain: string, ip: string, schedule: boolean, resolvedAt: number): void {
    DoHResolver.cache.delete(domain);
    DoHResolver.cache.set(domain, new DoHPin(ip, resolvedAt));
    if (Date.now() - resolvedAt > FRESH_TTL_MS) {
      DoHResolver.staleQueue.add(domain);
    } else {
      DoHResolver.staleQueue.delete(domain);
    }
    while (DoHResolver.cache.size > DoHResolver.CACHE_MAX_ENTRIES) {
      const oldest = DoHResolver.cache.keys().next();
      if (oldest.done) {
        break;
      }
      DoHResolver.cache.delete(oldest.value);
      DoHResolver.staleQueue.delete(oldest.value);
    }
    if (schedule) {
      DoHResolver.schedulePersist();
    }
  }

  private static schedulePersist(): void {
    if (DoHResolver.persistTimer >= 0) {
      return;
    }
    DoHResolver.persistTimer = setTimeout((): void => {
      DoHResolver.persistTimer = -1;
      const out: Record<string, string> = {};
      const now = Date.now();
      for (const domain of DoHResolver.cache.keys()) {
        const pin = DoHResolver.cache.get(domain);
        if (pin !== undefined && now >= pin.resolvedAt && now - pin.resolvedAt <= USABLE_TTL_MS) {
          out[domain] = `${pin.ip}|${pin.resolvedAt}`;
        }
      }
      SettingsService.saveDohPins(out).catch((e: Error): void => {
        AppLogger.warn(TAG, `doh pin persist failed: ${AppLogger.errText(e)}`);
      });
    }, PERSIST_DEBOUNCE_MS);
  }
}
