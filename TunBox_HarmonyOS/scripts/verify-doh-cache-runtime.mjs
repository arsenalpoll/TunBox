// Executes the real resolver with an in-memory Preferences/HTTP boundary and virtual clock.
//
// 契约（2026-10-18 修正）：pin 的寿命由 **DoH 应答里的 DNS TTL** 决定，而不是固定 3h/6h。
//   · 只有 TTL ≥ 10min 的"稳定记录"才允许 pin（写进 YAML hosts:）；
//   · 短 TTL（机场入口域名普遍 60~300s）= 会轮换 = 一律不 pin，交给内核按 TTL 现解析；
//   · pin 寿命 = min(TTL, 60min)，过一半进 stale 队列，到期丢弃；
//   · 持久化三段式 ip|resolvedAt|lifetimeMs，旧版两段式加载即弃（脏 pin 必须洗掉）。
// 真机依据：飞鸟云 34 个 hysteria2 节点整屏「超时」= 旧 pin 钉在已轮换的 IP 上；
// 同一份 YAML 用同一内核在 PC 复现，删掉 pin 立刻 155~250ms。
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

const file = new URL('../entry/src/main/ets/commons/services/DoHResolver.ets', import.meta.url);
const source = fs.readFileSync(file, 'utf8')
  .replace(/^import .*;\r?\n/gm, '')
  .replace('export class DoHResolver', 'class DoHResolver')
  + '\nglobalThis.Resolver = DoHResolver;';
const js = stripTypeScriptTypes(source);

const MIN = 60 * 1000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
/** 稳定记录：TTL 1h → pin 寿命被 PIN_MAX_AGE_MS(60min) 截住 */
const STABLE_TTL_SEC = 3600;
const PIN_LIFETIME_MS = 60 * MIN;
/** 机场入口域名实测 TTL：60~300s */
const ROTATING_TTL_SEC = 60;

let passed = 0;
async function test(name, fn) {
  await fn();
  passed++;
  console.log('PASS ' + name);
}
function harness(persisted = {}, answerTtlSec = STABLE_TTL_SEC, answerIp = '203.0.113.2') {
  let now = 20 * DAY, reads = 0, requests = 0, saved = null, fail = false;
  const timers = new Map();
  let timer = 0;
  class Clock extends Date { static now() { return now; } }
  const context = vm.createContext({
    Date: Clock, console,
    setTimeout: (fn, delay) => { timers.set(++timer, { fn, delay }); return timer; },
    clearTimeout: id => timers.delete(id),
    SettingsService: {
      loadDohPins: async () => { reads++; return persisted; },
      saveDohPins: async value => { saved = value; }
    },
    AppLogger: { info() {}, warn() {}, errText: String },
    http: {
      RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 'STRING' },
      createHttp: () => ({
        destroy() {},
        request: async () => {
          requests++;
          if (fail) { throw new Error('offline'); }
          return {
            responseCode: 200,
            result: JSON.stringify({
              Status: 0,
              Answer: [{ type: 1, data: answerIp, TTL: answerTtlSec }]
            })
          };
        }
      })
    }
  });
  vm.runInContext(js, context);
  return {
    resolver: context.Resolver,
    get reads() { return reads; },
    get requests() { return requests; },
    get saved() { return saved; },
    get now() { return now; },
    set fail(v) { fail = v; },
    advance(ms) { now += ms; },
    async persist() {
      for (const [id, t] of [...timers]) if (t.delay === 2000) { timers.delete(id); t.fn(); }
      await Promise.resolve();
    }
  };
}

await test('concurrent loads share one read', async () => {
  const h = harness();
  await Promise.all([h.resolver.ensureLoaded(), h.resolver.ensureLoaded()]);
  assert.equal(h.reads, 1);
});

await test('stale (age > 寿命一半) 的 pin 会真的重解析', async () => {
  const h = harness({ 'old.example': `203.0.113.1|${20 * DAY - 40 * MIN}|${PIN_LIFETIME_MS}` });
  assert.equal((await h.resolver.resolveMany(['old.example']))['old.example'], '203.0.113.1');
  assert.equal(await h.resolver.refreshStale(), 1);
  assert.equal(h.requests, 1);
  assert.equal(await h.resolver.resolveA('OLD.EXAMPLE'), '203.0.113.2');
});

await test('寿命内的 pin 命中缓存、不发请求', async () => {
  const h = harness({ 'old.example': `203.0.113.1|${20 * DAY - 5 * MIN}|${PIN_LIFETIME_MS}` });
  assert.equal((await h.resolver.resolveMany(['old.example']))['old.example'], '203.0.113.1');
  assert.equal(h.requests, 0);
});

await test('保存新条目不会续期旧条目（三段式原样保留）', async () => {
  const ts = 20 * DAY - 5 * MIN;
  const h = harness({ 'old.example': `203.0.113.1|${ts}|${PIN_LIFETIME_MS}` });
  await h.resolver.resolveA('new.example');
  await h.persist();
  assert.equal(h.saved['old.example'], `203.0.113.1|${ts}|${PIN_LIFETIME_MS}`);
  assert.equal(h.saved['new.example'], `203.0.113.2|${h.now}|${PIN_LIFETIME_MS}`);
});

await test('长驻进程里 pin 到寿命即失效（不无限期使用）', async () => {
  const h = harness({ 'old.example': `203.0.113.1|${20 * DAY}|${PIN_LIFETIME_MS}` });
  await h.resolver.ensureLoaded();
  h.advance(61 * MIN);
  assert.equal(await h.resolver.resolveA('old.example'), '203.0.113.2');
  assert.equal(h.requests, 1);
});

await test('TTL 很长也只 pin 到 60min 上限', async () => {
  // 应答 TTL = 24h；寿命被 PIN_MAX_AGE_MS 截到 60min，1h 后必须重解析
  const h = harness({}, 24 * 3600);
  assert.equal(await h.resolver.resolveA('long.example'), '203.0.113.2');
  h.advance(61 * MIN);
  assert.equal(await h.resolver.resolveA('long.example'), '203.0.113.2');
  assert.equal(h.requests, 2);
});

await test('刷新失败会在下一次调用重试', async () => {
  const h = harness({ 'old.example': `203.0.113.1|${20 * DAY - 40 * MIN}|${PIN_LIFETIME_MS}` });
  h.fail = true;
  assert.equal(await h.resolver.refreshStale(), 0);
  h.fail = false;
  assert.equal(await h.resolver.refreshStale(), 1);
});

await test('预算为 0 时保留 stale 工作，下一轮再刷', async () => {
  const h = harness({ 'old.example': `203.0.113.1|${20 * DAY - 40 * MIN}|${PIN_LIFETIME_MS}` });
  assert.equal(await h.resolver.refreshStale(0), 0);
  assert.equal(h.requests, 0);
  assert.equal(await h.resolver.refreshStale(), 1);
});

await test('未来时间戳与坏值一律拒绝重解析', async () => {
  const h = harness({
    'old.example': `203.0.113.1|${21 * DAY}|${PIN_LIFETIME_MS}`,
    'bad.example': '203.0.113.1|NaN|3600000'
  });
  await h.resolver.resolveMany(['old.example', 'bad.example']);
  assert.equal(h.requests, 2);
});

await test('内存里的 pin 无需重启也会过期', async () => {
  const h = harness({ 'old.example': `203.0.113.1|${20 * DAY}|${PIN_LIFETIME_MS}` });
  await h.resolver.ensureLoaded();
  h.advance(40 * MIN);
  assert.equal(await h.resolver.refreshStale(), 1);
});

await test('并发刷新共享同一航班', async () => {
  const h = harness({ 'old.example': `203.0.113.1|${20 * DAY - 40 * MIN}|${PIN_LIFETIME_MS}` });
  await h.resolver.ensureLoaded();
  await Promise.all([h.resolver.refreshStale(), h.resolver.refreshStale()]);
  assert.equal(h.requests, 1);
});

// ── 2026-10-18 新增：短 TTL 记录不得 pin ──────────────────────────────────
await test('短 TTL（60s）记录不 pin、不落盘，也不写进 hosts', async () => {
  const h = harness({}, ROTATING_TTL_SEC);
  const hosts = await h.resolver.resolveMany(['sg02.example.xyz']);
  assert.deepEqual({ ...hosts }, {}, 'rotating server must NOT be pinned into hosts');
  await h.persist();
  assert.equal(h.saved, null, 'nothing to persist when no pin was created');
});

await test('短 TTL 结论有保留期：同一批域名不再重复查询', async () => {
  const h = harness({}, ROTATING_TTL_SEC);
  await h.resolver.resolveMany(['sg02.example.xyz']);
  assert.equal(h.requests, 1);
  // 立刻再解析一次（模拟同一进程内再次连接）：不应再发 DoH 查询
  await h.resolver.resolveMany(['sg02.example.xyz']);
  assert.equal(h.requests, 1, 'short-ttl verdict must suppress repeat queries');
});

await test('旧版两段式（ip|ts）脏 pin 加载即弃，并触发一次洗盘', async () => {
  const h = harness({ 'stale.example': `13.228.124.169|${20 * DAY - 40 * MIN}` });
  const hosts = await h.resolver.resolveMany(['stale.example']);
  assert.equal(h.requests, 1, 'legacy pin must not be trusted; must re-resolve');
  // 默认应答 TTL 1h → 这条新解析是稳定记录，允许 pin
  assert.equal(hosts['stale.example'], '203.0.113.2');
  await h.persist();
  assert.ok(h.saved !== null, 'dropping legacy entries must schedule a rewrite');
  assert.equal(h.saved['stale.example'], `203.0.113.2|${h.now}|${PIN_LIFETIME_MS}`);
});

await test('dropPin 立即摘掉 pin 并落盘（超时自愈路径）', async () => {
  const h = harness({ 'old.example': `203.0.113.1|${20 * DAY}|${PIN_LIFETIME_MS}` });
  await h.resolver.ensureLoaded();
  h.resolver.dropPin('OLD.example');
  h.advance(1);
  await h.persist();
  assert.equal(h.saved['old.example'], undefined, 'dropped pin must disappear from disk');
  assert.equal(await h.resolver.resolveA('old.example'), '203.0.113.2');
  assert.equal(h.requests, 1);
});

console.log(`${passed}/${passed} passed (real resolver, mocked SDK/clock; not a network test)`);
