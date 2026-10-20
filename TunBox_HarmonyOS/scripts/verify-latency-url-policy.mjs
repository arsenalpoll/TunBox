#!/usr/bin/env node
/**
 * 测速 URL 策略验证（C2 / C3 / C6）—— 测速地址 https 化的**行为级**门禁。
 *
 * ## 为什么需要它（背景）
 *
 * 用户报障「订阅解析出来后，要么测速全部失败，要么启动代理失败」。测速侧的根因之一是
 * **测速地址全是 http**：
 *   · 明文地址会被机场/落地劫持（mihomo 官方点名 `provider.health-check.url` 与
 *     `group.url` 应使用 HTTPS）；
 *   · 5.6.0 真机基线本来就是 https（59 节点 13.14s 跑通），后来版本改回 http = 退化。
 *
 * 但**不能一刀切改成 https**（真机 commit a3fe45d）：个别出口掐 gstatic 的 TLS SNI，
 * 同一个出口 https Timeout 而 http 1158ms → **用户自填的 http 是合法配置**。
 * 于是策略是三条同时成立：
 *   ① 出厂默认与**历史默认值**升级为 HTTPS；
 *   ② **用户自填的 http 原样保留**；
 *   ③ **绝不**把用户手填的 https 悄悄改回 http（旧实现恰恰在做这件事 —— 罪魁祸首）。
 *
 * 本脚本沿用 `verify-proxy-name-uniqueness.mjs` 的手法：**从真源码里把函数抽出来
 * 在 Node 里跑**，而不是靠正则看源码长相。
 *
 * 跑法：node scripts/verify-latency-url-policy.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const P = {
  settings: path.join(root, 'entry/src/main/ets/commons/models/AppSettings.ets'),
  page: path.join(root, 'entry/src/main/ets/pages/NodeSelectionPage.ets'),
  bg: path.join(root, 'entry/src/main/ets/commons/services/BackgroundLatencyService.ets')
};
const settingsSrc = fs.readFileSync(P.settings, 'utf8');
const pageSrc = fs.readFileSync(P.page, 'utf8');
const bgSrc = fs.readFileSync(P.bg, 'utf8');

let passed = 0;
let failed = 0;
function ok(cond, label) {
  if (cond) { passed++; console.log(`  ✅ ${label}`); }
  else { failed++; console.log(`  ❌ ${label}`); }
}
function eq(actual, expected, label) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) { passed++; console.log(`  ✅ ${label}`); }
  else { failed++; console.log(`  ❌ ${label}\n       期望 ${e}\n       实际 ${a}`); }
}

/** 从真源码里抽一段（startMarker → endMarker 之前，含方法体的收尾大括号） */
function grab(src, startMarker, endMarker) {
  const start = src.indexOf(startMarker);
  if (start < 0) throw new Error(`找不到起点: ${startMarker}`);
  const end = src.indexOf(endMarker, start);
  if (end < 0) throw new Error(`找不到终点: ${endMarker}`);
  return src.slice(start, end);
}

/** 从真源码里读一个 static readonly 常量的字面值 */
function constOf(src, name) {
  const m = src.match(new RegExp(`static readonly ${name}: string = '([^']*)'`));
  return m === null ? null : m[1];
}

// ── 常量（必须来自真源码，不允许脚本里硬编码一份「期望值」冒充实现） ──────────
// 2026-10-20（ND06 收口）：测速地址常量的**唯一真源**是
// commons/latency/LatencyTestUrl.ets；AppSettings 只引用它们（不再各存一份字面量）。
const latencyTestUrlSrc = fs.readFileSync(path.join(root, 'entry/src/main/ets/commons/latency/LatencyTestUrl.ets'), 'utf8');
const DEFAULT_TEST_URL = constOf(latencyTestUrlSrc, 'DEFAULT_URL');
const LEGACY_GSTATIC = constOf(latencyTestUrlSrc, 'LEGACY_GSTATIC_HTTP');
const LEGACY_CLOUDFLARE = constOf(latencyTestUrlSrc, 'LEGACY_CLOUDFLARE_HTTP');
if (DEFAULT_TEST_URL === null || LEGACY_GSTATIC === null || LEGACY_CLOUDFLARE === null) {
  console.log('FAILED: LatencyTestUrl.ets 里找不到 DEFAULT_URL / LEGACY_*_HTTP 常量');
  process.exit(1);
}

// ── 抽出 upgradeLegacyTestUrl 的真实现 ────────────────────────────────────────
const upgradeSrc = grab(settingsSrc,
  'static upgradeLegacyTestUrl(value: string): string {', '\n  }');
const upgradeJs = upgradeSrc
  .replace(/^static /, '')
  .replace(/\(value: string\): string/, '(value)')
  .replace(/: string/g, '') + '}';
// 注入真源常量（升级函数内部引用 LatencyTestUrl.*）
const LatencyTestUrlStub = {
  DEFAULT_URL: DEFAULT_TEST_URL,
  ALT_URL: constOf(latencyTestUrlSrc, 'ALT_URL'),
  LEGACY_GSTATIC_HTTP: LEGACY_GSTATIC,
  LEGACY_CLOUDFLARE_HTTP: LEGACY_CLOUDFLARE,
};
const upgradeLegacyTestUrl = new Function(
  'LatencyTestUrl',
  'const AppSettings = {'
  + ` DEFAULT_TEST_URL: ${JSON.stringify(DEFAULT_TEST_URL)},`
  + ` LEGACY_TEST_URL_GSTATIC: ${JSON.stringify(LEGACY_GSTATIC)},`
  + ` LEGACY_TEST_URL_CLOUDFLARE: ${JSON.stringify(LEGACY_CLOUDFLARE)},`
  + ` ${upgradeJs}`
  + '};'
  + 'return AppSettings.upgradeLegacyTestUrl;')(LatencyTestUrlStub);

// ── 抽出 fromJson 里真正给 testLatencyUrl 赋值的那一句 ─────────────────────────
const fromJsonSrc = grab(settingsSrc, 'static fromJson(j: AppSettingsJson): AppSettings {', '\n  }');
const assignMatch = fromJsonSrc.match(/s\.testLatencyUrl\s*=\s*AppSettings\.upgradeLegacyTestUrl\([^;]*\);/);
if (assignMatch === null) {
  console.log('FAILED: fromJson 里找不到 s.testLatencyUrl = AppSettings.upgradeLegacyTestUrl(...) 赋值语句');
  process.exit(1);
}
const assignExpr = assignMatch[0].replace('s.testLatencyUrl =', 'return');
// 真实赋值语句 → 一个「喂 j、拿 testLatencyUrl」的函数
const fromJsonAssign = new Function('AppSettings', 'j', assignExpr);
const AppSettingsStub = { upgradeLegacyTestUrl };

// 测速地址规则已收口到 commons/latency/LatencyTestUrl.effective（唯一真源）；
// 本闸门把页面/后台的兜底函数抽出来单独 eval，故把该依赖按真实实现注入。
// 桩：本闸门把页面/后台的兜底函数抽出来单独 eval（见下面的 new Function），
// 所以必须注入它们依赖的 effectiveTestUrl。这里的语义**逐条对齐真实实现**
// commons/latency/LatencyTestUrl.effective（+ LatencyProbe.effectiveTestUrl 包装）：
//   - 空 / 非法 → 默认 https；
//   - 恰好等于两个历史 http 默认值 → 对应的 https（单向升级）；
//   - 其余（含用户自填的 http）→ **原样保留**（真机 a3fe45d：个别出口掐 TLS
//     SNI，https Timeout 而 http 1158ms，用户自填 http 是有意为之）。
// 「唯一真源」本身由 verify-latency-core-v2.mjs 的 A12 断言保证。
const LEGACY_GSTATIC_HTTP = 'http://www.gstatic.com/generate_204';
const LEGACY_CLOUDFLARE_HTTP = 'http://cp.cloudflare.com/generate_204';
const effectiveTestUrl = (settings) => {
  const raw = (settings && settings.testLatencyUrl) ? String(settings.testLatencyUrl).trim() : '';
  if (raw.length === 0) { return DEFAULT_TEST_URL; }
  if (raw === LEGACY_GSTATIC_HTTP) { return 'https://www.gstatic.com/generate_204'; }
  if (raw === LEGACY_CLOUDFLARE_HTTP) { return 'https://cp.cloudflare.com/generate_204'; }
  if (!/^https?:\/\/\S+$/.test(raw)) { return DEFAULT_TEST_URL; }
  return raw;
};
// ── 抽出页面 / 后台的兜底口径函数 ─────────────────────────────────────────────
const pageFnSrc = grab(pageSrc, 'private testUrlForLatency(): string {', '\n  }');
const pageFnJs = pageFnSrc
  .replace(/^private /, '')
  .replace(/\(\): string/, '()')
  .replace(/: string/g, '') + '}';
const pageFn = new Function('AppSettings', 'AppLogger', 'TAG', 'effectiveTestUrl',
  'return {' + pageFnJs + '}.testUrlForLatency;')(
  { DEFAULT_TEST_URL },
  { warn() {} },
  'verify',
  effectiveTestUrl);

const bgFnSrc = grab(bgSrc, 'static resolveTestUrl(settings: AppSettings): string {', '\n  }');
const bgFnJs = bgFnSrc
  .replace(/^static /, '')
  .replace(/\(settings: AppSettings\): string/, '(settings)')
  .replace(/: string/g, '') + '}';
const bgFn = new Function('AppSettings', 'AppLogger', 'TAG', 'effectiveTestUrl',
  'return {' + bgFnJs + '}.resolveTestUrl;')(
  { DEFAULT_TEST_URL },
  { warn() {} },
  'verify',
  effectiveTestUrl);

console.log('\n[1] 出厂默认测速地址必须是 https（两个默认位点）');
{
  // 2026-10-20（ND06 收口）：AppSettings 不再各存一份字面量，两个默认位点都引用真源。
  const defaults = [...settingsSrc.matchAll(/testLatencyUrl: string = (LatencyTestUrl\.DEFAULT_URL|'([^']*)')/g)]
    .map((m) => (m[1].startsWith('LatencyTestUrl.') ? DEFAULT_TEST_URL : m[2]));
  eq(defaults.length, 2, 'AppSettings.ets 里有 2 个默认位点（AppSettingsJson + AppSettings）');
  ok(defaults.every((u) => u.startsWith('https://')),
    `两个默认位点都是 https：${JSON.stringify(defaults)}`);
  ok(DEFAULT_TEST_URL.startsWith('https://'),
    `DEFAULT_TEST_URL 常量是 https：${DEFAULT_TEST_URL}`);
}

console.log('\n[2] 反序列化不再把 https 降级成 http');
{
  ok(!/http:\/\//.test(fromJsonSrc),
    'fromJson 里不再出现任何 http 字面量（旧的「https→http 强制降级」已删除）');
  ok(fromJsonSrc.includes('upgradeLegacyTestUrl'),
    'fromJson 走的是 upgradeLegacyTestUrl（单向升级）');
  eq(fromJsonAssign(AppSettingsStub, { testLatencyUrl: 'https://www.gstatic.com/generate_204' }),
    'https://www.gstatic.com/generate_204',
    '输入 https://www.gstatic.com/generate_204 → 输出仍是 https（不被降级）');
  eq(fromJsonAssign(AppSettingsStub, { testLatencyUrl: 'https://my.host/ping' }),
    'https://my.host/ping',
    '输入任意用户自填 https → 原样保留');
}

console.log('\n[3] 历史默认值单向升级为 https');
{
  eq(upgradeLegacyTestUrl('http://www.gstatic.com/generate_204'),
    'https://www.gstatic.com/generate_204',
    'http://www.gstatic.com/generate_204 → https://www.gstatic.com/generate_204');
  eq(upgradeLegacyTestUrl('http://cp.cloudflare.com/generate_204'),
    'https://cp.cloudflare.com/generate_204',
    'http://cp.cloudflare.com/generate_204 → https://cp.cloudflare.com/generate_204');
  eq(fromJsonAssign(AppSettingsStub, { testLatencyUrl: 'http://www.gstatic.com/generate_204' }),
    'https://www.gstatic.com/generate_204',
    '存量用户落盘的旧默认值在加载时被升级');
}

console.log('\n[4] 用户自填的其它 http 地址原样保留（不得一刀切改 https）');
{
  eq(upgradeLegacyTestUrl('http://example.com/generate_204'),
    'http://example.com/generate_204', 'http://example.com/generate_204 原样保留');
  eq(upgradeLegacyTestUrl('http://my.host:8080/ping'),
    'http://my.host:8080/ping', 'http://my.host:8080/ping 原样保留');
  eq(upgradeLegacyTestUrl('http://www.gstatic.com/generate_204?x=1'),
    'http://www.gstatic.com/generate_204?x=1',
    '带参数的历史默认值也算「用户自填」→ 原样保留');
  eq(fromJsonAssign(AppSettingsStub, { testLatencyUrl: 'http://my.host:8080/ping' }),
    'http://my.host:8080/ping', '反序列化同样不篡改用户自填的 http');
}

console.log('\n[5] 空串 / 非法值 → 走默认 https');
{
  eq(upgradeLegacyTestUrl(''), DEFAULT_TEST_URL, '空串 → 默认 https');
  eq(upgradeLegacyTestUrl('   '), DEFAULT_TEST_URL, '纯空白 → 默认 https');
  eq(upgradeLegacyTestUrl('not-a-url'), DEFAULT_TEST_URL, '无协议头的非法值 → 默认 https');
  eq(upgradeLegacyTestUrl('ftp://x/y'), DEFAULT_TEST_URL, '非 http(s) 协议 → 默认 https');
  eq(fromJsonAssign(AppSettingsStub, { testLatencyUrl: '' }), DEFAULT_TEST_URL, '反序列化：空串 → 默认 https');
}

console.log('\n[6] 两条通道（页面 / 后台静默批次）的兜底目标都是 https');
{
  const pageCtx = { settings: { testLatencyUrl: '' } };
  eq(pageFn.call(pageCtx), DEFAULT_TEST_URL, 'NodeSelectionPage：空值 → 默认 https');
  const pageCtx2 = { settings: { testLatencyUrl: '   ' } };
  eq(pageFn.call(pageCtx2), DEFAULT_TEST_URL, 'NodeSelectionPage：空白 → 默认 https');
  eq(pageFn.call({ settings: { testLatencyUrl: 'http://my.host:8080/ping' } }),
    'http://my.host:8080/ping',
    'NodeSelectionPage：用户自填 http 原样保留（唯一真源不改写用户合法配置）');
  eq(pageFn.call({ settings: { testLatencyUrl: 'https://my.host/ping' } }),
    'https://my.host/ping', 'NodeSelectionPage：用户自填 https 原样使用');

  eq(bgFn({ testLatencyUrl: '' }), DEFAULT_TEST_URL, 'BackgroundLatencyService：空值 → 默认 https');
  eq(bgFn({ testLatencyUrl: 'http://my.host:8080/ping' }),
    'http://my.host:8080/ping',
    'BackgroundLatencyService：用户自填 http 原样保留（唯一真源不改写用户合法配置）');
  eq(bgFn({ testLatencyUrl: 'https://my.host/ping' }),
    'https://my.host/ping', 'BackgroundLatencyService：用户自填 https 原样使用');
  ok(DEFAULT_TEST_URL.startsWith('https://'), '兜底目标本身确实是 https');
}

console.log('\n[6b] 页面 / 后台只**调用**唯一真源，不自带第二份规则（审计 F12）');
{
  ok(/effectiveTestUrl\(/.test(pageFnSrc),
    'NodeSelectionPage.testUrlForLatency 调的是唯一真源 effectiveTestUrl(...)');
  ok(!/startsWith\('http:\/\/'\)|replace\('http:\/\/'|toUpperCase\(\)|indexOf\('gstatic'\)/.test(pageFnSrc),
    'NodeSelectionPage：函数体里没有自己那套 URL 规则（无 http→https 改写 / 无域名硬编码）');
  ok(/effectiveTestUrl\(/.test(bgFnSrc),
    'BackgroundLatencyService.resolveTestUrl 调的是唯一真源 effectiveTestUrl(...)');
  ok(!/startsWith\('http:\/\/'\)|replace\('http:\/\/'|indexOf\('gstatic'\)/.test(bgFnSrc),
    'BackgroundLatencyService：函数体里没有自己那套 URL 规则');
  ok(!settingsSrc.includes('static effectiveTestUrl'),
    'SettingsService：不再自持一份 effectiveTestUrl（那会变成第二份规则）');
}

console.log('\n[7] 源码里不再存在与代码矛盾的注释 / 篡改用户值的表述');
{
  ok(!pageSrc.includes('is not https; falling back'),
    'NodeSelectionPage：旧日志「is not https; falling back」已删除（它会篡改用户自填值）');
  ok(!pageSrc.includes('用户若填了 http 就回落到默认 HTTPS'),
    'NodeSelectionPage：旧注释「用户若填了 http 就回落到默认 HTTPS」已删除（注释与代码长期相反）');
  ok(!pageSrc.includes('LATENCY_TEST_URL'),
    'NodeSelectionPage：不再引用 LatencyEngine 的 LATENCY_TEST_URL（兜底目标由本文件自持）');
  ok(!bgSrc.includes('LATENCY_TEST_URL'),
    'BackgroundLatencyService：不再引用 LatencyEngine 的 LATENCY_TEST_URL');
  ok(!bgSrc.includes('非 https'),
    'BackgroundLatencyService：不再有「非 https 一律回落」这类表述');
  ok(pageSrc.includes('兜底目标') && pageSrc.includes('HTTPS'),
    'NodeSelectionPage：兜底口径的注释写明「兜底目标 → HTTPS」');
  ok(bgSrc.includes('兜底目标') || bgSrc.includes('默认 https'),
    'BackgroundLatencyService：兜底口径的注释写明默认 https');
  ok(settingsSrc.includes('用户自填'),
    'AppSettings：注释写清「为什么只升级自己写过的默认值，而不是把所有 http 改 https」');
  ok(!/https:\/\/www\.gstatic\.com\/generate_204'\s*\?\s*'http/.test(settingsSrc),
    'AppSettings：不存在「https → http」的条件降级表达式');
}

console.log('\n[8]（附加）组测契约对账：ClashApiService 的 GroupLatencyResult 必须与我的调用点一致');
{
  // 为什么在这里加这一段：本脚本所在的工作包（C10b）依赖「504 = 全部节点超时、
  // 通道正常」这个语义。一旦 504 被改回 ok=true，我的页面分支
  // `!ok && !allTimedOut` 就会把 504 重新判成「内核不可用」—— 那正是 T5
  // （组测语义混淆）的老毛病，会静默回归。本段是**只读**对账，不改别人的文件。
  const apiPath = path.join(root, 'entry/src/main/ets/commons/services/ClashApiService.ets');
  const apiSrc = fs.readFileSync(apiPath, 'utf8');
  const clsIdx = apiSrc.indexOf('export class GroupLatencyResult');
  ok(clsIdx >= 0, 'ClashApiService 导出 GroupLatencyResult');
  if (clsIdx >= 0) {
    const clsBody = apiSrc.slice(clsIdx, apiSrc.indexOf('\n}', clsIdx));
    for (const f of ['ok', 'delays', 'httpCode', 'failKind', 'detail', 'allTimedOut']) {
      ok(new RegExp(`^\\s{2}${f}:\\s`, 'm').test(clsBody), `GroupLatencyResult.${f} 字段存在`);
    }
    ok(/delays:\s*Map<string,\s*number>/.test(clsBody), 'delays 是 Map<string, number>（ArkTS 显式泛型）');
  }
  ok(/async testGroupDetailedResult\(groupName: string, testUrl: string,\s*\n?\s*timeoutMs: number\):\s*Promise<GroupLatencyResult>/
    .test(apiSrc), 'testGroupDetailedResult 签名与我的调用点一致');
  const i504 = apiSrc.indexOf('responseCode === 504');
  ok(i504 >= 0, '存在 504（all proxies timeout）分支');
  if (i504 >= 0) {
    const win = apiSrc.slice(i504, i504 + 600);
    ok(/allTimedOut\s*=\s*true/.test(win), '504 分支把 allTimedOut 置为 true（通道正常，节点全不通）');
    ok(/ok\s*=\s*false/.test(win), '504 分支不把 ok 置为 true（否则会被误判成通道故障 = T5 回归）');
  }
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
