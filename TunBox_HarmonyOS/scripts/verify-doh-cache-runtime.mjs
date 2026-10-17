// Executes the real resolver with an in-memory Preferences/HTTP boundary and virtual clock.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
const file = new URL('../entry/src/main/ets/commons/services/DoHResolver.ets', import.meta.url);
const source = fs.readFileSync(file, 'utf8').replace(/^import .*;\r?\n/gm, '').replace('export class DoHResolver', 'class DoHResolver') + '\nglobalThis.Resolver = DoHResolver;';
const js = stripTypeScriptTypes(source);
const DAY = 86400000;
// pin TTL 契约（加固③c）：3h 起进 stale 队列（FRESH_TTL_MS），6h 硬过期（USABLE_TTL_MS）。
// 测试前提统一用 4h 龄的 pin（处于 3h..6h 的 stale-but-usable 窗口内）。
const STALE_AGE_MS = 4 * 3600000;
let passed = 0;
function harness(persisted = {}) {
  let now = 20 * DAY, reads = 0, requests = 0, saved = null, fail = false;
  const timers = new Map(); let timer = 0;
  class Clock extends Date { static now() { return now; } }
  const context = vm.createContext({
    Date: Clock, console,
    setTimeout: (fn, delay) => { timers.set(++timer, {fn, delay}); return timer; },
    clearTimeout: id => timers.delete(id),
    SettingsService: {
      loadDohPins: async () => { reads++; return persisted; },
      saveDohPins: async value => { saved = value; }
    },
    AppLogger: {info() {}, warn() {}, errText: String},
    http: {
      RequestMethod: {GET: 'GET'}, HttpDataType: {STRING: 'STRING'},
      createHttp: () => ({destroy() {}, request: async () => {
        requests++; if (fail) throw new Error('offline');
        return {responseCode: 200, result: JSON.stringify({Status: 0, Answer: [{type: 1, data: '203.0.113.2'}]})};
      }})
    }
  });
  vm.runInContext(js, context);
  return {
    resolver: context.Resolver, get reads() {return reads;}, get requests() {return requests;},
    get saved() {return saved;}, set fail(v) {fail=v;}, advance(ms) {now += ms;},
    async persist() {for (const [id,t] of [...timers]) if (t.delay === 2000) {timers.delete(id); t.fn();} await Promise.resolve();}
  };
}
async function test(name, fn) {await fn(); passed++; console.log('PASS '+name);}
await test('concurrent loads share one read', async () => {
  const h=harness(); await Promise.all([h.resolver.ensureLoaded(), h.resolver.ensureLoaded()]); assert.equal(h.reads,1);
});
await test('stale disk entries actually refresh', async () => {
  const h=harness({'old.example':`203.0.113.1|${20*DAY - STALE_AGE_MS}`});
  assert.equal((await h.resolver.resolveMany(['old.example']))['old.example'],'203.0.113.1');
  assert.equal(await h.resolver.refreshStale(),1); assert.equal(h.requests,1);
  assert.equal(await h.resolver.resolveA('OLD.EXAMPLE'),'203.0.113.2');
});
await test('saving fresh entry does not renew old entry', async () => {
  const ts=19.75*DAY, h=harness({'old.example':`203.0.113.1|${ts}`});
  await h.resolver.resolveA('new.example'); await h.persist();
  assert.equal(h.saved['old.example'],`203.0.113.1|${ts}`);
});
await test('long-lived memory enforces hard expiry', async () => {
  const h=harness({'old.example':`203.0.113.1|${20*DAY}`}); await h.resolver.ensureLoaded(); h.advance(8*DAY);
  assert.equal(await h.resolver.resolveA('old.example'),'203.0.113.2'); assert.equal(h.requests,1);
});
await test('failed stale refresh retries next call', async () => {
  const h=harness({'old.example':`203.0.113.1|${20*DAY - STALE_AGE_MS}`}); h.fail=true;
  assert.equal(await h.resolver.refreshStale(),0); h.fail=false;
  assert.equal(await h.resolver.refreshStale(),1);
});
await test('zero budget preserves stale work', async () => {
  const h=harness({'old.example':`203.0.113.1|${20*DAY - STALE_AGE_MS}`});
  assert.equal(await h.resolver.refreshStale(0),0); assert.equal(h.requests,0);
  assert.equal(await h.resolver.refreshStale(),1);
});
await test('future and malformed disk timestamps are rejected', async () => {
  const h=harness({'old.example':`203.0.113.1|${21*DAY}`,'bad.example':'203.0.113.1|NaN'});
  await h.resolver.resolveMany(['old.example','bad.example']); assert.equal(h.requests,2);
});
await test('fresh memory becomes stale without restarting', async () => {
  const h=harness({'old.example':`203.0.113.1|${20*DAY}`}); await h.resolver.ensureLoaded(); h.advance(STALE_AGE_MS);
  assert.equal(await h.resolver.refreshStale(),1);
});
await test('concurrent stale refresh shares a flight', async () => {
  const h=harness({'old.example':`203.0.113.1|${20*DAY - STALE_AGE_MS}`}); await h.resolver.ensureLoaded();
  await Promise.all([h.resolver.refreshStale(),h.resolver.refreshStale()]); assert.equal(h.requests,1);
});
console.log(`${passed}/${passed} passed (real resolver, mocked SDK; not a network/device test)`);
