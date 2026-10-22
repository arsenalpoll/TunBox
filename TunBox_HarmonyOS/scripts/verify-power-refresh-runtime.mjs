import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { harness, deferred, flush } from './orchestrator-runtime-harness.mjs';
const base = new URL('../entry/src/main/ets/', import.meta.url);
const source = name => fs.readFileSync(new URL(name, base), 'utf8').replace(/\r\n/g, '\n');
const strip = s => stripTypeScriptTypes(s, { mode: 'transform' });
function method(text, name) {
  const head = text.match(new RegExp('^  (?:private )?(?:static )?(?:async )?' + name + '\\([^\\n]*\\{[^\\n]*', 'm'));
  assert.ok(head, name);
  if (head[0].trimEnd().endsWith('}')) return head[0];
  const start = head.index, end = text.indexOf('\n  }', start);
  assert.ok(end > start, name + ' end'); return text.slice(start, end + 4);
}
let passed = 0;
async function test(name, fn) { await fn(); passed++; console.log('PASS ' + name); }
function apiFixture() {
  let now = 1000000;
  const h = { gets: 0, destroyed: 0, gates: [], code: 200, body: {
    uploadTotal: 100, downloadTotal: 200,
    connections: [{ id: 'one', upload: 10, download: 20, chains: ['PROXY', 'node'], metadata: { host: 'example.test' } }]
  } };
  class Clock extends Date { static now() { return now; } }
  const context = vm.createContext({
    Date: Clock, http: { RequestMethod: { GET: 'GET', PUT: 'PUT', DELETE: 'DELETE', PATCH: 'PATCH' },
      createHttp() { return {
        async request(url, options) {
          if (options.method === 'GET' && url.endsWith('/connections')) {
            h.gets++; const code = h.code, result = JSON.stringify(h.body), gate = h.gates.shift();
            if (gate) await gate.promise;
            return { responseCode: code, result };
          }
          return { responseCode: 204, result: '' };
        }, destroy() { h.destroyed++; }
      }; } },
    util: { TextDecoder: { create: () => new TextDecoder() } },
    AppLogger: { info() {}, warn() {}, errText: String }
  });
  const code = source('commons/services/ClashApiService.ets').replace(/^import\b[\s\S]*?;\n/gm, '').replace(/^export /gm, '');
  const Api = vm.runInContext(strip('(() => {' + code + '; return ClashApiService; })()'), context);
  h.api = new Api(); h.api.setEndpoint(9090, 'test-secret');
  h.advance = ms => { now += ms; }; return h;
}
await test('traffic, connection list and active-node requests share one controller read', async () => {
  const h = apiFixture(), gate = deferred(); h.gates.push(gate);
  const a = h.api.traffic(), b = h.api.listConnections(['node']), c = h.api.smartActiveNodes('PROXY', ['node']);
  await flush(); assert.equal(h.gets, 1); gate.resolve();
  const [traffic, list, active] = await Promise.all([a, b, c]);
  assert.equal(traffic.uploadBytes, 100); assert.equal(list[0].id, 'one'); assert.equal(active[0], 'node');
  assert.equal(h.destroyed, 1);
});
await test('short cache expires after 500 milliseconds', async () => {
  const h = apiFixture(); await h.api.listConnections();
  h.advance(499); await h.api.traffic(); assert.equal(h.gets, 1);
  h.advance(1); await h.api.listConnections(); assert.equal(h.gets, 2);
});
await test('10-second traffic samples calculate speeds using real elapsed time', async () => {
  const h = apiFixture(); await h.api.traffic();
  h.advance(10000); h.body.uploadTotal = 1100; h.body.downloadTotal = 2200;
  const t = await h.api.traffic(); assert.equal(t.uploadSpeed, 100); assert.equal(t.downloadSpeed, 200);
});
await test('endpoint replacement rejects old results and preserves the newer in-flight request', async () => {
  const h = apiFixture(), old = deferred(), fresh = deferred(); h.gates.push(old);
  const a = h.api.listConnections(); await flush();
  h.api.setEndpoint(19090, 'new-secret'); h.body.connections[0].id = 'new'; h.gates.push(fresh);
  const b = h.api.listConnections(); await flush(); old.resolve(); assert.equal(await a, null);
  const c = h.api.listConnections(); await flush(); assert.equal(h.gets, 2);
  fresh.resolve(); assert.equal((await b)[0].id, 'new'); assert.equal((await c)[0].id, 'new');
});
await test('failed reads are not cached or mistaken for an empty live connection list', async () => {
  const h = apiFixture(); h.code = 503;
  assert.equal(await h.api.listConnections(), null); assert.equal(await h.api.listConnections(), null); assert.equal(h.gets, 2);
  h.code = 200; h.body.connections = []; assert.equal((await h.api.listConnections()).length, 0);
});
await test('explicit connection deletion and baseline reset invalidate cached connections', async () => {
  const h = apiFixture(); await h.api.listConnections();
  assert.equal(await h.api.closeConnection('one'), true); await h.api.listConnections(); assert.equal(h.gets, 2);
  h.api.resetTrafficBaseline(); await h.api.traffic(); assert.equal(h.gets, 3);
});
await test('malformed connection arrays do not break the active-node view', async () => {
  const h = apiFixture(); h.body.connections = {};
  assert.equal((await h.api.listConnections()).length, 0);
  assert.equal((await h.api.smartActiveNodes('PROXY', ['node'])).length, 0);
});
function trafficHarness(foreground = true) {
  const h = harness(foreground); h.trafficCalls = 0; h.liveCalls = 0;
  h.orch.notifyNodeText = text => text;
  h.orch.api.traffic = async () => {
    h.trafficCalls++; return { uploadBytes: 100, downloadBytes: 200, uploadSpeed: 1, downloadSpeed: 2 };
  };
  h.platform.TaskProgressUpdater.updateLive = () => { h.liveCalls++; };
  return h;
}
await test('foreground and background perform 30 and 6 scheduled samples per minute', async () => {
  for (const [foreground, step, count] of [[true, 2000, 30], [false, 10000, 6]]) {
    const h = trafficHarness(foreground); h.orch.startMonitors();
    const monitor = h.orch.monitorGeneration, start = h.orch.startedAt;
    for (let i = 0; i < count; i++) {
      h.advance(step); const timer = [...h.timers.values()].find(t => t.delay === step);
      assert.ok(timer); timer.fn(); await flush();
    }
    assert.equal(h.trafficCalls, count); assert.equal(h.liveCalls, count);
    assert.equal(h.orch.monitorGeneration, monitor); assert.equal(h.orch.startedAt, start); h.stop();
  }
});
await test('returning foreground refreshes immediately without replacing liveness monitoring', async () => {
  const h = trafficHarness(false); h.orch.startMonitors();
  const monitor = h.orch.monitorGeneration, start = h.orch.startedAt;
  h.orch.setUiForeground(true); await flush();
  assert.equal(h.trafficCalls, 1); assert.equal(h.orch.monitorGeneration, monitor); assert.equal(h.orch.startedAt, start);
  assert.equal([...h.timers.values()].filter(t => t.delay === 2000).length, 1);
  assert.equal([...h.timers.values()].filter(t => t.delay === 3000).length, 1);
  h.orch.setUiForeground(true); await flush(); assert.equal(h.trafficCalls, 1); h.stop();
});
await test('a pending statistics response cannot update state after user disconnect', async () => {
  const h = trafficHarness(), gate = deferred(), before = h.orch.traffic;
  h.orch.api.traffic = async () => { await gate.promise; return { uploadBytes: 999, downloadBytes: 999, uploadSpeed: 1, downloadSpeed: 1 }; };
  h.orch.startMonitors(); [...h.timers.values()].find(t => t.delay === 2000).fn(); await flush();
  h.orch.disconnectRequested = true; h.stop(); gate.resolve(); await flush();
  assert.equal(h.orch.traffic, before); assert.equal(h.liveCalls, 0);
});
await test('a newer background sample cannot be overwritten by a late foreground sample', async () => {
  const h = trafficHarness(), gate = deferred(); let calls = 0;
  h.orch.api.traffic = async () => {
    if (++calls === 1) { await gate.promise; return { uploadBytes: 1, downloadBytes: 1 }; }
    return { uploadBytes: 9, downloadBytes: 9, uploadSpeed: 0, downloadSpeed: 0 };
  };
  h.orch.startMonitors(); [...h.timers.values()].find(t => t.delay === 2000).fn(); await flush();
  h.orch.setUiForeground(false); [...h.timers.values()].find(t => t.delay === 10000).fn(); await flush();
  gate.resolve(); await flush(); assert.equal(h.orch.traffic.uploadBytes, 9); h.stop();
});
function homeFixture() {
  let now = 1000000, id = 0; const timers = new Map();
  const context = vm.createContext({
    Date: class extends Date { static now() { return now; } }, ConnState: { CONNECTED: 'connected' },
    NexusSizes: { ratePoints: 26 }, CONN_PREVIEW_POLL_MS: 2000, CONN_PREVIEW_MAX: 5,
    setInterval(fn, delay) { timers.set(++id, { fn, delay }); return id; }, clearInterval(i) { timers.delete(i); },
    AppLogger: { warn() {}, errText: String }
  });
  const methods = ['canRefreshPage', 'onRefreshVisibilityChanged', 'knownNodeNames', 'refreshConnPreview',
    'startConnPreview', 'stopConnPreview', 'syncConnectionTimer', 'stopConnectionTimer'].map(n => method(source('pages/HomePage.ets'), n)).join('\n');
  const Page = vm.runInContext(strip('class Page {' + methods + '} Page'), context);
  const p = new Page(); Object.assign(p, { isActive: true, appForeground: true, pageReady: true, connCardOpen: true,
    connPreviewTimer: -1, connectionTimer: -1, previewGeneration: 0, connPreviewBusy: false, isConnected: true,
    connPreview: [], connPreviewReachable: true, ratePoints: [], subs: { nodes: [] },
    orchestrator: { state: 'connected', startedAt: 940000, traffic: { uploadSpeed: 0, downloadSpeed: 0, uploadBytes: 10, downloadBytes: 20 },
      api: { async listConnections() { return []; } } } });
  return { p, timers, advance(ms) { now += ms; } };
}
await test('hidden home stops chart and preview timers while uptime resumes from its original start', async () => {
  const h = homeFixture(); h.p.onRefreshVisibilityChanged(); await flush(); assert.equal(h.timers.size, 2);
  assert.equal(h.p.connectionDuration, 60); const tick = [...h.timers.values()].find(t => t.delay === 1000).fn;
  h.p.isActive = false; h.p.onRefreshVisibilityChanged(); assert.equal(h.timers.size, 0);
  h.advance(120000); tick(); assert.equal(h.p.ratePoints.length, 0);
  h.p.isActive = true; h.p.onRefreshVisibilityChanged(); assert.equal(h.p.connectionDuration, 180);
  assert.equal(h.p.orchestrator.startedAt, 940000);
  h.p.appForeground = false; h.p.onRefreshVisibilityChanged(); assert.equal(h.timers.size, 0);
});
await test('hidden home ignores a late connection-preview response', async () => {
  const h = homeFixture(), gate = deferred();
  h.p.orchestrator.api.listConnections = async () => { await gate.promise; return [{ id: 'late', upload: 1, download: 2 }]; };
  const task = h.p.refreshConnPreview(); await flush();
  h.p.isActive = false; h.p.onRefreshVisibilityChanged(); gate.resolve(); await task;
  assert.equal(h.p.connPreview.length, 0);
});
await test('identical notification payloads are deduplicated and detach permits a fresh publication', async () => {
  let calls = 0;
  const context = vm.createContext({ SsrvpnNotifier: { async update() { calls++; } }, clearInterval() {} });
  const code = source('commons/services/TaskProgressUpdater.ets').replace(/^import\b[\s\S]*?;\n/gm, '').replace(/^export /gm, '');
  const T = vm.runInContext(strip('(() => {' + code + '; return TaskProgressUpdater; })()'), context);
  T.updateLive('node', '0 B/s', '00:01'); T.updateLive('node', '0 B/s', '00:01'); assert.equal(calls, 1);
  T.updateLive('node', '1 B/s', '00:02'); assert.equal(calls, 2);
  T.detach(); T.updateLive('node', '1 B/s', '00:02'); assert.equal(calls, 3);
});
function connectionsPageFixture() {
  let id = 0, reads = 0, inits = 0; const timers = new Map(), initGate = deferred();
  const context = vm.createContext({
    getContext: () => ({}), POLL_INTERVAL_MS: 2000, AppLogger: { warn() {}, errText: String },
    setTimeout(fn, delay) { timers.set(++id, { fn, delay }); return id; },
    clearTimeout(i) { timers.delete(i); },
    setInterval(fn, delay) { timers.set(++id, { fn, delay }); return id; },
    clearInterval(i) { timers.delete(i); }
  });
  const methods = ['onPageShow', 'onPageHide', 'canPoll', 'onForegroundChanged', 'aboutToDisappear',
    'bootstrap', 'startPoll', 'stopPoll', 'refreshOnce'].map(n => method(source('pages/ConnectionsPage.ets'), n)).join('\n');
  const Page = vm.runInContext(strip('class Page {' + methods + '} Page'), context), p = new Page();
  Object.assign(p, { pageShown: false, appForeground: true, pollGeneration: 0, bootstrapTimer: -1,
    pollTimer: -1, refreshing: false, entries: [], reachable: true,
    orchestrator: { init() { inits++; }, api: { async listConnections() { reads++; return []; } } },
    subs: { nodes: [], async init() { await initGate.promise; } } });
  return { p, timers, initGate, reads: () => reads, inits: () => inits };
}
await test('a delayed connections-page bootstrap cannot start after the page is hidden', async () => {
  const h = connectionsPageFixture(); h.p.onPageShow();
  const delayed = [...h.timers.values()][0].fn; h.p.onPageHide(); delayed(); await flush();
  assert.equal(h.inits(), 0); assert.equal(h.reads(), 0); assert.equal(h.timers.size, 0);
});
await test('connections-page initialization cannot restart polling after leaving during a read', async () => {
  const h = connectionsPageFixture(); h.p.pageShown = true;
  const task = h.p.bootstrap(); await flush(); assert.equal(h.inits(), 1);
  h.p.onPageHide(); h.initGate.resolve(); await task;
  assert.equal(h.reads(), 0); assert.equal(h.timers.size, 0);
});
await test('information cards use a 10-second timer while the state-reconciliation interval stays 3 seconds', async () => {
  const text = source('commons/services/FormStateSync.ets'), timers = new Map(); let id = 0;
  const interval = text.match(/^const INFO_REFRESH_INTERVAL_MS = [0-9]+;/m)[0];
  const context = vm.createContext({ setInterval(fn, delay) { timers.set(++id, { fn, delay }); return id; } });
  const code = interval + " const INFO_FORM_NAME = 'SsrvpnInfoCard'; class FormStateSync {"
    + 'static infoRefreshContext = null; static infoRefreshTimer = -1; static infoRefreshRunning = false;'
    + 'static stopInfoRefresh() {} static async refreshInfoForms() {} '
    + method(text, 'reconcileInfoRefresh') + '} FormStateSync';
  const F = vm.runInContext(strip(code), context);
  F.reconcileInfoRefresh({}, [{ formName: 'SsrvpnInfoCard' }]);
  assert.equal([...timers.values()][0].delay, 10000);
  assert.match(text, /const RECONCILE_INTERVAL_MS = 3000;/);
});
console.log(JSON.stringify({ passed, failed: 0, scope: 'production API, orchestrator and page logic; platform boundaries and clock replaced; no battery claim' }));
