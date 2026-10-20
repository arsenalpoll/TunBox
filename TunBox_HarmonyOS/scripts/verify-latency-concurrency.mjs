/**
 * 测速并发闸门 + 组测失败分类的**行为**验证（跑真代码，不是读源码）。
 *
 * 对应方案 §9.4 的 C7 / C8 / C8b / C10 / C10b 与 §9.9 的验收门槛：
 *   「实测 HTTP 在途请求不超过 8；排队等待不被计入单请求网络超时」
 *   「504、404、503、连接失败、请求超时分别处理，不把非 200 一律判为内核不可用」
 *
 * 做法与 verify-latency-engine-runtime.mjs 同构：把真实现暂存为 .ts 后 import，
 * 只把「不可控的外部世界」换成桩：
 *   - LatencyEngine（真） + 可编程的 api 桩（记录在途数 / lanes / 发起时刻）
 *   - ClashApiService（真） + 假 http 层（可编程返回 200/401/404/503/504/抛异常）
 *
 * 分两组：
 *   A. 引擎侧：在途上限、lanes 语义、排队不计预算、排队超时的分类
 *   B. 组测侧：504/401/404/503/传输异常/200 各自的分类，以及旧接口行为不变
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.join(here, '..');
const svc = path.join(appRoot, 'entry/src/main/ets/commons/services/');

let passed = 0;
let failed = 0;
const failures = [];
function check(name, fn) {
  try {
    fn();
    passed++;
    console.log(`PASS ${name}`);
  } catch (e) {
    failed++;
    failures.push(`${name} :: ${e.message}`);
    console.log(`FAIL ${name} :: ${e.message}`);
  }
}
async function checkAsync(name, fn) {
  try {
    await fn();
    passed++;
    console.log(`PASS ${name}`);
  } catch (e) {
    failed++;
    failures.push(`${name} :: ${e.message}`);
    console.log(`FAIL ${name} :: ${e.message}`);
  }
}
function eq(a, b, label) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`${label}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
  }
}
function ok(c, label) {
  if (!c) throw new Error(label);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const URL_ = 'https://www.gstatic.com/generate_204';

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'latency-conc-'));
const w = (dir, name, s) => fs.writeFileSync(path.join(dir, name), s, 'utf8');

// ── 公共依赖（真实现 + 桩） ───────────────────────────────────────────────
function writeDeps(dir) {
  // 真实实现（真跑）：LatencyState / LatencyController
  for (const f of ['LatencyState', 'LatencyController']) {
    const src = fs.readFileSync(path.join(svc, f + '.ets'), 'utf8')
      .replace(/from '(\.\/[A-Za-z0-9_]+)'/g, "from '$1.ts'");
    w(dir, f + '.ts', src);
  }
  // 桩：AppLogger
  w(dir, 'AppLogger.ts', `
export class AppLogger {
  static info(_t: string, _m: string): void {}
  static warn(_t: string, _m: string): void {}
  static error(_t: string, _m: string): void {}
  static errText(e: Object): string { return String(e); }
}
`);
  // 桩：ProxyNode
  w(dir, 'ProxyNode.ts', `
export class ProxyNode {
  name: string = '';
  type: string = 'ss';
  server: string = '';
  port: number = 443;
  constructor(name: string = '', server: string = '') {
    this.name = name; this.server = server;
  }
}
`);
  // 桩：ConnectionOrchestrator（记录自愈/回收调用）
  w(dir, 'ConnectionOrchestrator.ts', `
export class ConnectionOrchestrator {
  static recycles = [];
  static recoverCalls = 0;
  static recoverResult = true;
  static reset() {
    ConnectionOrchestrator.recycles = [];
    ConnectionOrchestrator.recoverCalls = 0;
    ConnectionOrchestrator.recoverResult = true;
  }
  static instance(): ConnectionOrchestrator { return new ConnectionOrchestrator(); }
  scheduleTestCoreRecycle(_ms: number): void { ConnectionOrchestrator.recycles.push(_ms); }
  async refreshLatencyEndpoint(_api: Object): Promise<boolean> {
    ConnectionOrchestrator.recoverCalls++;
    return ConnectionOrchestrator.recoverResult;
  }
}
`);
  // 桩：DirectLatencyTester（离线通道，本文件用不到）
  w(dir, 'DirectLatencyTester.ts', `
export class DirectLatencyTester {
  static async testNode(_node: Object, _timeoutMs: number): Promise<number> { return 30; }
}
`);
  // 桩：DoHResolver
  w(dir, 'DoHResolver.ts', `
export class DoHResolver {
  static dropped = [];
  static dropPin(domain: string): void { DoHResolver.dropped.push(domain); }
}
`);
}

/**
 * 引擎侧的可编程 api 桩：记录**在途数**、lanes（引擎传下来的语义参数）、
 * 每次请求的发起/结束时刻（用来证明「排队期间没有请求在飞」）。
 */
const API_STUB = `
export class LatencyFailKind {
  static readonly NONE: string = '';
  static readonly CORE_NOT_READY: string = 'core_not_ready';
  static readonly SWITCH_FAILED: string = 'switch_failed';
  static readonly NETWORK_UNREACHABLE: string = 'network_unreachable';
  static readonly TIMEOUT: string = 'timeout';
  static readonly UNSUPPORTED: string = 'unsupported';
  static readonly PORT_ONLY: string = 'port_reachable_only';
  static readonly UNTESTED: string = 'untested';
  static readonly CANCELLED: string = 'cancelled';
  static readonly QUEUE_TIMEOUT: string = 'queue_timeout';
}
export class LatencyProbeResult {
  delayMs: number = -1;
  failKind: string = '';
  httpCode: number = 0;
  detail: string = '';
}
export function probeResult(delayMs, failKind = '', httpCode = 0) {
  const r = new LatencyProbeResult();
  r.delayMs = delayMs; r.failKind = failKind; r.httpCode = httpCode;
  return r;
}
export class ClashApiService {
  static handler = null;
  static calls = [];
  static maxInflight = 0;
  static _inflight = 0;
  static reset() {
    ClashApiService.handler = null;
    ClashApiService.calls = [];
    ClashApiService.maxInflight = 0;
    ClashApiService._inflight = 0;
  }
  async testLatencyDetailed(name, url, timeoutMs, lanes = 1) {
    const c = { name: name, url: url, timeoutMs: timeoutMs, lanes: lanes, start: Date.now(), end: 0 };
    ClashApiService.calls.push(c);
    ClashApiService._inflight++;
    if (ClashApiService._inflight > ClashApiService.maxInflight) {
      ClashApiService.maxInflight = ClashApiService._inflight;
    }
    try {
      const h = ClashApiService.handler;
      if (h === null) { throw new Error('no handler'); }
      return await h(name, url, timeoutMs);
    } finally {
      c.end = Date.now();
      ClashApiService._inflight--;
    }
  }
  cancelInflight() { return 0; }
}
`;

function stageEngine(dir, queueWaitMs) {
  fs.mkdirSync(dir, { recursive: true });
  writeDeps(dir);
  w(dir, 'ClashApiService.ts', API_STUB);
  let eng = fs.readFileSync(path.join(svc, 'LatencyEngine.ets'), 'utf8');
  eng = eng
    .replace(/from '\.\.\/utils\/AppLogger'/g, "from './AppLogger.ts'")
    .replace(/from '\.\/ClashApiService'/g, "from './ClashApiService.ts'")
    .replace(/from '\.\/ConnectionOrchestrator'/g, "from './ConnectionOrchestrator.ts'")
    .replace(/from '\.\/LatencyState'/g, "from './LatencyState.ts'")
    .replace(/from '\.\/LatencyController'/g, "from './LatencyController.ts'")
    .replace(/from '\.\.\/models\/ProxyNode'/g, "from './ProxyNode.ts'")
    .replace(/from '\.\/DirectLatencyTester'/g, "from './DirectLatencyTester.ts'")
    .replace(/from '\.\/DoHResolver'/g, "from './DoHResolver.ts'");
  if (queueWaitMs !== undefined) {
    // 排队上限改小，才能确定性地触发「排队超时」这条路径
    eng = eng.replace(/export const LATENCY_QUEUE_WAIT_MAX_MS = \d+;/,
      `export const LATENCY_QUEUE_WAIT_MAX_MS = ${queueWaitMs};`);
  }
  w(dir, 'LatencyEngine.ts', eng);
}

// A 组：默认排队上限（60s）
const dirA = path.join(root, 'a');
stageEngine(dirA);
// B 组：排队上限 300ms（确定性地触发排队超时）
const dirB = path.join(root, 'b');
stageEngine(dirB, 300);

const A = await import(pathToFileURL(path.join(dirA, 'LatencyEngine.ts')).href);
const AC = await import(pathToFileURL(path.join(dirA, 'ClashApiService.ts')).href);
const ALC = await import(pathToFileURL(path.join(dirA, 'LatencyController.ts')).href);
const ALState = await import(pathToFileURL(path.join(dirA, 'LatencyState.ts')).href);
const B = await import(pathToFileURL(path.join(dirB, 'LatencyEngine.ts')).href);
const BC = await import(pathToFileURL(path.join(dirB, 'ClashApiService.ts')).href);
const BLC = await import(pathToFileURL(path.join(dirB, 'LatencyController.ts')).href);

const { ProxyNode } = await import(pathToFileURL(path.join(dirA, 'ProxyNode.ts')).href);

function nodes(n) {
  const out = [];
  for (let i = 0; i < n; i++) out.push(new ProxyNode('node-' + i, '1.2.3.' + (i % 250 + 1)));
  return out;
}
function opts(over) {
  const o = new A.LatencyRunOptions();
  o.force = true;
  o.timeoutMs = 5000;
  o.onResult = null;
  o.onProgress = null;
  if (over && over.batchDeadlineMs !== undefined) o.batchDeadlineMs = over.batchDeadlineMs;
  return o;
}

// ── A1. 常量契约 ───────────────────────────────────────────────────────────
check('常量契约：worker 并发=50、在途请求=8、排队上限=60s', () => {
  eq(A.LATENCY_CONCURRENCY, 50, 'LATENCY_CONCURRENCY（worker 数 / 队列深度）');
  eq(A.LATENCY_INFLIGHT, 8, 'LATENCY_INFLIGHT（同时在途的 HTTP 请求数）');
  eq(A.LATENCY_QUEUE_WAIT_MAX_MS, 60000, 'LATENCY_QUEUE_WAIT_MAX_MS');
  ok(A.LATENCY_INFLIGHT <= 8, '在途数不得超过 OHOS 同 host 连接池容量 8');
  ok(A.LATENCY_INFLIGHT < A.LATENCY_CONCURRENCY,
    '在途数必须小于 worker 数（否则闸门形同虚设）');
});

// ── A2. lanes 语义：传给 testLatencyDetailed 的是「在途数」= 8 ───────────
await checkAsync('lanes 语义：传下去的是同时在途的 HTTP 请求数（8），不是 worker 数', async () => {
  AC.ClashApiService.reset();
  ALC.LatencyController.clearAll();
  AC.ClashApiService.handler = async () => AC.probeResult(120, '', 200);
  const run = A.LatencyEngine.start(new AC.ClashApiService(), nodes(30), URL_, opts());
  await run.run();
  A.LatencyEngine.release(run);
  ok(AC.ClashApiService.calls.length === 30, `每节点一次探测（got ${AC.ClashApiService.calls.length}）`);
  for (const c of AC.ClashApiService.calls) {
    eq(c.lanes, 8, 'lanes 必须是 8（在途数），不是 worker 数 50、也不是队列深度');
  }
});

// ── A3. 真跑一批：峰值在途 ≤ 8（且确实并行） ──────────────────────────────
await checkAsync('在途上限：真跑 40 节点，峰值在途请求数 ≤ 8', async () => {
  AC.ClashApiService.reset();
  ALC.LatencyController.clearAll();
  const perRequest = 250;
  AC.ClashApiService.handler = async () => {
    await sleep(perRequest);
    return AC.probeResult(120, '', 200);
  };
  const t0 = Date.now();
  const run = A.LatencyEngine.start(new AC.ClashApiService(), nodes(40), URL_, opts());
  const p = await run.run();
  const elapsed = Date.now() - t0;
  A.LatencyEngine.release(run);
  ok(AC.ClashApiService.maxInflight <= 8,
    `峰值在途必须 ≤ 8（实得 ${AC.ClashApiService.maxInflight}）`);
  ok(AC.ClashApiService.maxInflight >= 2,
    `必须真的并行（峰值 ${AC.ClashApiService.maxInflight}）`);
  console.log(`  · 峰值在途请求数 = ${AC.ClashApiService.maxInflight}（上限 8）`);
  // 闸门真的在限流：40 节点 / 8 在途 = 5 波，单请求 250ms → 整批至少 1.2s
  ok(elapsed >= 1000,
    `闸门应把 40 节点压成 5 波（≥1.2s），实得 ${elapsed}ms`);
  eq(p.measured, 40, '全部测出');
  eq(p.failed, 0, '无失败');
});

// ── A4. 排队等待不计入单请求网络超时 ─────────────────────────────────────
await checkAsync('排队等待不计入请求超时：排队后发起的请求仍拿到完整预算', async () => {
  AC.ClashApiService.reset();
  ALC.LatencyController.clearAll();
  const perRequest = 250;
  AC.ClashApiService.handler = async () => {
    await sleep(perRequest);
    return AC.probeResult(120, '', 200);
  };
  const t0 = Date.now();
  const run = A.LatencyEngine.start(new AC.ClashApiService(), nodes(40), URL_, opts());
  const p = await run.run();
  A.LatencyEngine.release(run);
  const calls = AC.ClashApiService.calls;
  ok(calls.length === 40, '每节点一次探测');
  const queued = calls.filter((c) => c.start - t0 > 200);
  ok(queued.length > 0, '本轮必须真的发生过排队（否则这条断言没有意义）');
  for (const c of calls) {
    eq(c.timeoutMs, 5000, '每个请求的预算都必须是完整的 5000ms（排队不许扣预算）');
    ok(c.end - c.start < 5000,
      `单请求实际耗时必须 < 预算（${c.end - c.start}ms）——排队没被算进超时`);
  }
  eq(p.measured, 40, '排队中的节点最终都测出了结果（没有被排队拖死）');
  eq(p.timeout, 0, '没有节点因为排队而被判超时');
});

// ── A5. 排队超时 = 节点级「排队超时」，绝不是 CORE_NOT_READY ─────────────
await checkAsync('排队超时：节点被标为排队超时（queue_timeout），不是内核不可用', async () => {
  BC.ClashApiService.reset();
  BLC.LatencyController.clearAll();
  // 8 个在途请求占满名额 1.2s，其余节点只能排队；排队上限 300ms → 必然超时
  BC.ClashApiService.handler = async () => {
    await sleep(1200);
    return BC.probeResult(120, '', 200);
  };
  const run = B.LatencyEngine.start(new BC.ClashApiService(), nodes(20), URL_, opts());
  const p = await run.run();
  B.LatencyEngine.release(run);
  ok(BC.ClashApiService.calls.length <= 8,
    `名额满时不得再发请求（实发 ${BC.ClashApiService.calls.length}）`);
  ok(p.queueTimeout > 0, `必须有节点被判排队超时（实得 ${p.queueTimeout}）`);
  eq(p.queueTimeout, 20 - BC.ClashApiService.calls.length, '排队超时的节点数');
  eq(p.coreNotReady, 0, '排队超时绝不能计入「通道不可用」');
  eq(p.coreUnavailable, false, '排队超时绝不能作废整批');
  for (const n of nodes(20)) {
    const rec = BLC.LatencyController.recordFor(n.name);
    if (rec === null) continue;
    ok(rec.failKind !== 'core_not_ready', '不得出现 core_not_ready 的节点结论');
    if (rec.failKind === 'queue_timeout') {
      eq(rec.state, ALState.LatencyState.TIMEOUT, '排队超时的状态档位');
    }
  }
  const qt = [];
  for (const n of nodes(20)) {
    const rec = BLC.LatencyController.recordFor(n.name);
    if (rec !== null && rec.failKind === 'queue_timeout') qt.push(n.name);
  }
  ok(qt.length > 0, '必须有节点的 failKind 落成 queue_timeout');
});

// ── B 组：真实 ClashApiService 的组测分类 ─────────────────────────────────
const dirC = path.join(root, 'c');
fs.mkdirSync(dirC, { recursive: true });
writeDeps(dirC);
w(dirC, 'fakeHttp.ts', `
export const RequestMethod = { GET: 0, POST: 1, PUT: 2, DELETE: 3 };
export class FakeRequest {
  async request(url, options) {
    return await globalThis.__fakeHttp__(url, options);
  }
  destroy() {}
}
export function createHttp() { return new FakeRequest(); }
export const http = { createHttp: createHttp, RequestMethod: RequestMethod };
`);
w(dirC, 'fakeUtil.ts', `
export const util = {
  TextDecoder: {
    create: (_enc) => ({
      decodeToString: (u8) => Buffer.from(u8).toString('utf8')
    })
  }
};
`);
let apiSrc = fs.readFileSync(path.join(svc, 'ClashApiService.ets'), 'utf8');
apiSrc = apiSrc
  .replace(/from '@kit\.NetworkKit'/g, "from './fakeHttp.ts'")
  .replace(/from '@kit\.ArkTS'/g, "from './fakeUtil.ts'")
  .replace(/from '\.\.\/utils\/AppLogger'/g, "from './AppLogger.ts'")
  .replace(/from '\.\/LatencyState'/g, "from './LatencyState.ts'");
ok(!/@kit\./.test(apiSrc), 'staged ClashApiService 不得残留 @kit 导入');
w(dirC, 'ClashApiService.ts', apiSrc);

const C = await import(pathToFileURL(path.join(dirC, 'ClashApiService.ts')).href);
const { ClashApiService: RealApi, LatencyFailKind: RealKind } = C;
let lastUrl = '';
function fakeHttp(status, body) {
  globalThis.__fakeHttp__ = async (url) => {
    lastUrl = url;
    if (status === 'throw') throw new Error('connect refused');
    return { responseCode: status, result: body };
  };
}

await checkAsync('组测 504（全部成员超时）= 通道正常、节点全不通，不是内核不可用', async () => {
  fakeHttp(504, 'get delay: all proxies timeout');
  const res = await new RealApi().testGroupDetailedResult('PROXY', URL_, 5000);
  eq(res.httpCode, 504, 'httpCode');
  eq(res.allTimedOut, true, '504 必须标 allTimedOut');
  eq(res.failKind, RealKind.TIMEOUT, '504 的分类是 TIMEOUT');
  ok(res.failKind !== RealKind.CORE_NOT_READY, '504 绝不能是 CORE_NOT_READY');
  eq(res.ok, false, '504 不是「有可用响应」');
  eq(res.delays.size, 0, '504 没有成功节点');
  ok(lastUrl.includes('/group/PROXY/delay?url='), `请求路径必须是 /group/{name}/delay（实得 ${lastUrl}）`);
  ok(lastUrl.includes('&timeout=5000'), '请求必须带 timeout 参数');
});

await checkAsync('组测 401（secret 错配）= CORE_NOT_READY', async () => {
  fakeHttp(401, 'unauthorized');
  const res = await new RealApi().testGroupDetailedResult('PROXY', URL_, 5000);
  eq(res.httpCode, 401, 'httpCode');
  eq(res.failKind, RealKind.CORE_NOT_READY, '401 的分类');
  eq(res.allTimedOut, false, '401 不是全部超时');
  eq(res.ok, false, '401 没有可用响应');
});

await checkAsync('组测 404（组不存在）= SWITCH_FAILED', async () => {
  fakeHttp(404, 'not found');
  const res = await new RealApi().testGroupDetailedResult('NOPE', URL_, 5000);
  eq(res.httpCode, 404, 'httpCode');
  eq(res.failKind, RealKind.SWITCH_FAILED, '404 的分类');
  eq(res.allTimedOut, false, '404 不是全部超时');
});

await checkAsync('组测 503 = TIMEOUT（单节点拨号失败语义）', async () => {
  fakeHttp(503, 'service unavailable');
  const res = await new RealApi().testGroupDetailedResult('PROXY', URL_, 5000);
  eq(res.httpCode, 503, 'httpCode');
  eq(res.failKind, RealKind.TIMEOUT, '503 的分类');
  eq(res.allTimedOut, false, '503 不是「全部成员超时」');
});

await checkAsync('组测传输异常（本机没拿到响应）= CORE_NOT_READY', async () => {
  fakeHttp('throw', '');
  const res = await new RealApi().testGroupDetailedResult('PROXY', URL_, 5000);
  eq(res.httpCode, 0, '传输异常没有 httpCode');
  eq(res.failKind, RealKind.CORE_NOT_READY, '传输异常的分类');
  eq(res.allTimedOut, false, '传输异常不是全部超时');
  eq(res.ok, false, '传输异常没有可用响应');
});

await checkAsync('组测 200：ok=true，delays 只含 delay>0 的成员', async () => {
  fakeHttp(200, JSON.stringify({ 'node-a': 120, 'node-b': 0, 'node-c': 45 }));
  const res = await new RealApi().testGroupDetailedResult('PROXY', URL_, 5000);
  eq(res.httpCode, 200, 'httpCode');
  eq(res.ok, true, '200 = 有可用响应');
  eq(res.failKind, '', '200 没有失败分类');
  eq(res.allTimedOut, false, '200 不是全部超时');
  eq(res.delays.size, 2, '只收 delay>0 的成员');
  eq(res.delays.get('node-a'), 120, 'node-a 延迟');
  eq(res.delays.get('node-c'), 45, 'node-c 延迟');
  eq(res.delays.get('node-b'), undefined, 'node-b（delay=0）必须被过滤');
});

await checkAsync('兼容接口 testGroupDetailed 行为不变：非 200 一律 null', async () => {
  fakeHttp(504, 'get delay: all proxies timeout');
  const m504 = await new RealApi().testGroupDetailed('PROXY', URL_, 5000);
  eq(m504, null, '504 → null（旧行为）');
  fakeHttp(401, 'unauthorized');
  const m401 = await new RealApi().testGroupDetailed('PROXY', URL_, 5000);
  eq(m401, null, '401 → null（旧行为）');
  fakeHttp(200, JSON.stringify({ 'node-a': 120, 'node-b': 0 }));
  const m200 = await new RealApi().testGroupDetailed('PROXY', URL_, 5000);
  ok(m200 !== null && m200.size === 1, '200 → 只含成功节点的 Map');
});

console.log('');
if (failed === 0) {
  console.log(`Latency concurrency verification: ${passed} passed, 0 failed.`);
  process.exit(0);
}
console.log(`Latency concurrency verification: ${passed} passed, ${failed} failed.`);
for (const f of failures) console.log(`  - ${f}`);
process.exit(1);
