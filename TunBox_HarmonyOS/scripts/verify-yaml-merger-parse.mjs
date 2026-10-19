#!/usr/bin/env node
/**
 * YamlMerger 订阅解析回归门禁（真机两个订阅故障的固化）。
 *
 * 它验证的是什么（2026-10-19 真机实证的两个用户可见故障）:
 *
 *   A. anytls 节点被整批丢弃 → 测速「全部超时/失败」
 *      订阅 dy5-8.fgqoq.online/lagg/... 共 41 节点 = 36 anytls + 5 hysteria2。
 *      36 个 anytls 因 `YamlMerger.STRUCTURED_TYPES` 未含 anytls 而走中继透传
 *      （relayMode），该分支只保留 name/type/server/port，password 落进 extraOpts；
 *      于是 ProxyNode.password 为空 → ClashConfigGenerator.dropReasonFor 判
 *      「缺必需字段：凭据缺失」→ 整批丢弃 → 内核代理表里没有这些节点 →
 *      /proxies/{name}/delay 返回 404「Resource not found」→ UI 全部标红，
 *      而节点实际完全可用。
 *
 *   B. 块式 YAML 订阅导入 0 节点
 *      订阅 mitce.io/modules/servers/v2Net/subscribe/... 的 proxies 段是
 *      **裸连字符块序列**（`  -` 单独一行，name/type/server 由更深缩进的键行承载）。
 *      切分器只认 `  - `（带尾随空格）→ 整份切出 0 个条目组 → 导入失败。
 *
 * 断言方式: Node 24 原生 TS type-stripping **直接加载 YamlMerger.ets 源文件本体**
 * （只把 SDK import 换成最小垫片，被测逻辑一行都不在垫片里重写），
 * 对真实的 proxyItemGroups / parseProxyItem 做行为断言。
 *
 * 用法: node scripts/verify-yaml-merger-parse.mjs [--file <path>]
 *   --file 用于负对照：指向修复前的 YamlMerger.ets 时，本脚本**必须失败**
 *   （块式条目数 0、anytls password 为空）。
 * 退出码: 0 = 全部断言通过；1 = 有断言失败或加载失败
 */
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

const here = dirname(fileURLToPath(import.meta.url));
const appRoot = resolve(here, '..');
const svcDir = join(appRoot, 'entry', 'src', 'main', 'ets', 'commons', 'services');
const fileArg = process.argv.indexOf('--file');
const targetFile = fileArg >= 0 && process.argv[fileArg + 1]
  ? resolve(process.argv[fileArg + 1])
  : join(svcDir, 'YamlMerger.ets');

let passed = 0;
const failures = [];
function record(label, okFlag, detail) {
  if (okFlag) { passed += 1; console.log('  ✓ ' + label); }
  else { failures.push(label + (detail ? ' -> ' + detail : '')); console.log('  ✗ ' + label + (detail ? ' — ' + detail : '')); }
}
function eq(label, actual, expected) {
  record(label, Object.is(actual, expected),
    'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}
function ok(label, cond, detail) {
  record(label, cond === true, detail || ('expected true, got ' + JSON.stringify(cond)));
}

// ── 加载沙箱：真实源码 + 最小垫片 ────────────────────────────────────
const sandbox = join(tmpdir(), 'tunbox-yamlmerge-verify-' + process.pid);
rmSync(sandbox, { recursive: true, force: true });
mkdirSync(sandbox, { recursive: true });
writeFileSync(join(sandbox, 'package.json'), JSON.stringify({ type: 'module' }), 'utf8');

writeFileSync(join(sandbox, 'shim_appkit.ts'), [
  'export const util = {',
  '  TextDecoder: class { constructor(_e?: string) {} decodeToString(_b: Uint8Array): string { return ""; } },',
  '  TextEncoder: class { encodeInto(_s: string): { read: number } { return { read: 0 }; } }',
  '};',
  'export const BusinessError = class extends Error { code: number = 0; };'
].join('\n'), 'utf8');
writeFileSync(join(sandbox, 'shim_logger.ts'), [
  'export class AppLogger {',
  '  static info(_t: string, _m: string): void {}',
  '  static warn(_t: string, _m: string): void {}',
  '  static error(_t: string, _m: string): void {}',
  '  static errText(e: Object): string { return e === null || e === undefined ? "unknown error" : String(e); }',
  '}'
].join('\n'), 'utf8');
writeFileSync(join(sandbox, 'shim_kitsystem.ts'), [
  'export const BusinessError = class extends Error { code: number = 0; };'
].join('\n'), 'utf8');

function stage(name) {
  const src = readFileSync(targetFile, 'utf8');
  const patched = src
    .replace(/from '@kit\.ArkTS'/g, "from './shim_appkit.ts'")
    .replace(/from '@kit\.AppKit'/g, "from './shim_appkit.ts'")
    .replace(/from '@kit\.BasicServicesKit'/g, "from './shim_kitsystem.ts'")
    .replace(/from '@ohos\.util'/g, "from './shim_appkit.ts'")
    .replace(/from '\.\.\/utils\/AppLogger'/g, "from './shim_logger.ts'");
  const out = join(sandbox, name + '.ts');
  writeFileSync(out, patched, 'utf8');
  return out;
}

const yamlMergerPath = stage('YamlMerger');
let YMC;
try {
  const mod = await import(pathToFileURL(yamlMergerPath).href);
  YMC = mod.YamlMerger;
  if (typeof YMC !== 'function' || typeof YMC.proxyItemGroups !== 'function') {
    console.error('FATAL: YamlMerger 导出结构异常: ' + Object.keys(mod).join(', '));
    process.exit(1);
  }
} catch (e) {
  console.error('FATAL: 加载 YamlMerger.ets 源码失败: ' + (e && e.stack ? e.stack : e));
  process.exit(1);
}

// ══════════════════════════════════════════════════════════════════════
// fixture 1: flow-map 风格订阅（含 anytls 与 hysteria2）—— 故障 A
// ══════════════════════════════════════════════════════════════════════
const flowMapSub = [
  'proxies:',
  "  - { name: '🇭🇰 香港Anytls 01', type: anytls, server: awfg-001.example.com, port: 21107, password: 2648d147-a038-47e9-922d-6d6e92290a93, udp: true, sni: hkt.example.com, skip-cert-verify: true }",
  "  - { name: '🇯🇵 日本Anytls 01', type: anytls, server: aw-22t.example.com, port: 21019, password: 2648d147-a038-47e9-922d-6d6e92290a93, udp: true, sni: jsjp.example.com }",
  "  - { name: '🇭🇰 香港hy2', type: hysteria2, server: akjp.example.com, port: 35426, sni: akjp.example.com, up: 100, down: 300, skip-cert-verify: true, password: 2648d147-a038-47e9-922d-6d6e92290a93 }"
].join('\n');

// ══════════════════════════════════════════════════════════════════════
// fixture 2: 裸连字符块序列订阅 —— 故障 B
// ══════════════════════════════════════════════════════════════════════
const blockStyleSub = [
  'port: 7890',
  'mode: rule',
  'proxies:',
  '  -',
  "    name: 'US-N-1 [P]'",
  '    type: vless',
  '    server: de152710bb8b70d108ec13c7.example.com',
  '    port: 33297',
  '    uuid: 7A3AA165-2E44-4408-AA3A-C37E48707754',
  '    udp: true',
  '    client-fingerprint: chrome',
  '    tls: true',
  '    skip-cert-verify: false',
  '    servername: de152710bb8b70d108ec13c7.example.com',
  '    reality-opts:',
  '      public-key: Z9GrfeYwreR9elewwmaw9OmLfttz1XP_tXl1dp6Xg_A',
  '      short-id: d2e2a63f7c6676ac',
  '    network: tcp',
  '    flow: xtls-rprx-vision',
  '  -',
  "    name: 'US-N-2 [P]'",
  '    type: vless',
  '    server: 9bc9d9086212beb0fe99faf9.example.com',
  '    port: 50659',
  '    uuid: 97EB4615-9842-4711-BC14-AF4526260DA8',
  '    tls: true',
  '    network: tcp',
  'proxy-groups:',
  '  - name: PROXY',
  '    type: select',
  '    proxies:',
  "      - 'US-N-1 [P]'",
  "      - 'US-N-2 [P]'"
].join('\n');

console.log('===== YamlMerger 订阅解析回归 =====');

// ── A. flow-map 风格：条目切分 + anytls 凭据 ─────────────────────────
const flowGroups = YMC.proxyItemGroups(flowMapSub);
eq('flow-map 条目数', flowGroups.length, 3);

const flowNodes = [];
for (const g of flowGroups) {
  try { flowNodes.push(YMC.parseProxyItem(g)); } catch (e) { flowNodes.push(null); }
}
ok('flow-map 全部条目解析成功', flowNodes.every((n) => n !== null),
  'null 数: ' + flowNodes.filter((n) => n === null).length);

const anytls = flowNodes.filter((n) => n !== null && n.type === 'anytls');
eq('anytls 节点数', anytls.length, 2);
// 故障 A 的核心断言：anytls 的 password 必须落在结构化槽位（不是 extraOpts）
ok('anytls password 已回填（不再走中继透传）',
  anytls.every((n) => n.password.length > 0),
  'password: ' + JSON.stringify(anytls.map((n) => n.password)));
ok('anytls password 值正确',
  anytls.every((n) => n.password === '2648d147-a038-47e9-922d-6d6e92290a93'));
ok('anytls sni 落在 servername 槽位',
  anytls.every((n) => n.servername.length > 0),
  'servername: ' + JSON.stringify(anytls.map((n) => n.servername)));
ok('anytls 不再把 password 塞进 extraOpts',
  anytls.every((n) => !n.extraOpts.includes('"password"')));

const hy2 = flowNodes.filter((n) => n !== null && n.type === 'hysteria2');
eq('hysteria2 节点数', hy2.length, 1);
ok('hysteria2 password 已回填', hy2.length === 1 && hy2[0].password.length > 0);
ok('hysteria2 up/down 已回填', hy2.length === 1 && hy2[0].hyUp.length > 0 && hy2[0].hyDown.length > 0);

// ── B. 块式（裸连字符）风格：条目切分 + 字段解析 ─────────────────────
const blockGroups = YMC.proxyItemGroups(blockStyleSub);
eq('块式条目数（修复前为 0）', blockGroups.length, 2);

const blockNodes = [];
for (const g of blockGroups) {
  try { blockNodes.push(YMC.parseProxyItem(g)); } catch (e) { blockNodes.push(null); }
}
ok('块式全部条目解析成功', blockNodes.every((n) => n !== null),
  'null 数: ' + blockNodes.filter((n) => n === null).length);
// 条目数为 0 时（修复前的行为）blockNodes[0] 为 undefined，断言必须优雅失败而不是崩栈
const b0 = blockNodes[0];
const b1 = blockNodes[1];
const b0s = b0 === null || b0 === undefined ? 'no-node' : JSON.stringify({
  name: b0.name, type: b0.type, server: b0.server, uuid: b0.uuid,
  realityPublicKey: b0.realityPublicKey, realityShortId: b0.realityShortId,
  flow: b0.flow, clientFingerprint: b0.clientFingerprint
});
ok('块式节点 name 正确', b0 !== null && b0 !== undefined && b0.name === 'US-N-1 [P]', b0s);
ok('块式节点 type=vless', b0 !== null && b0 !== undefined && b0.type === 'vless', b0s);
ok('块式节点 server 已回填',
  b0 !== null && b0 !== undefined && b0.server === 'de152710bb8b70d108ec13c7.example.com', b0s);
ok('块式节点 uuid 已回填',
  b0 !== null && b0 !== undefined && b0.uuid === '7A3AA165-2E44-4408-AA3A-C37E48707754', b0s);
ok('块式节点 reality-opts 未丢字段',
  b0 !== null && b0 !== undefined && b0.realityPublicKey.length > 0
  && b0.realityShortId.length > 0, b0s);
ok('块式节点 flow 已回填',
  b0 !== null && b0 !== undefined && b0.flow === 'xtls-rprx-vision', b0s);
ok('块式节点 client-fingerprint 已回填',
  b0 !== null && b0 !== undefined && b0.clientFingerprint === 'chrome', b0s);
ok('块式第 2 条独立成条（未与第 1 条粘连）',
  b1 !== null && b1 !== undefined && b1.name === 'US-N-2 [P]');

// ── C. 负对照：flow-map 风格不得被本次改动破坏 ─────────────────────
const flowOnlySub = [
  'proxies:',
  "  - { name: 'A', type: ss, server: a.example.com, port: 443, cipher: aes-128-gcm, password: pw1 }",
  "  - { name: 'B', type: vmess, server: b.example.com, port: 443, uuid: u-1, alterId: 0, cipher: auto }"
].join('\n');
const flowOnlyGroups = YMC.proxyItemGroups(flowOnlySub);
eq('负对照: flow-map 条目数不变', flowOnlyGroups.length, 2);
const s1 = YMC.parseProxyItem(flowOnlyGroups[0]);
ok('负对照: ss 节点 cipher/password 正常',
  s1 !== null && s1.cipher === 'aes-128-gcm' && s1.password === 'pw1');
const v1 = YMC.parseProxyItem(flowOnlyGroups[1]);
ok('负对照: vmess 节点 uuid 正常', v1 !== null && v1.uuid === 'u-1');

// 负对照：`- name: x`（连字符带首字段）这种最常见写法仍按旧语义切分
const dashKeySub = [
  'proxies:',
  "  - name: 'C'",
  '    type: trojan',
  '    server: c.example.com',
  '    port: 443',
  '    password: pw3'
].join('\n');
const dashKeyGroups = YMC.proxyItemGroups(dashKeySub);
eq('负对照: "- name: x" 写法切出 1 条', dashKeyGroups.length, 1);
const c1 = YMC.parseProxyItem(dashKeyGroups[0]);
ok('负对照: trojan 节点字段正常',
  c1 !== null && c1.name === 'C' && c1.type === 'trojan' && c1.password === 'pw3');

// ── D. 中继型协议（tuic / hysteria v1）的凭据回填 ────────────────────
// 遗留项：中继型协议走 relayMode，凭据只进 extraOpts → ProxyNode.password/uuid 为空
// → dropReasonFor 判「缺凭据」整批丢弃 → 内核 404 → 测速全红（与 anytls 同源）。
const relaySub = [
  'proxies:',
  // tuic v4：uuid + password
  "  - { name: 'tuic-v4', type: tuic, server: t4.example.com, port: 443, uuid: tuic-uuid-1, password: tuic-pw-1, sni: t4.example.com }",
  // tuic v5：只有 token（**不能**回填到 password 槽，否则内核 v5 收到它不认的键）
  "  - { name: 'tuic-v5', type: tuic, server: t5.example.com, port: 443, token: tuic-token-5, sni: t5.example.com }",
  // hysteria v1：凭据键是 auth-str（不是 password），protocol 是传输协议、up/down 是带宽
  "  - { name: 'hy1', type: hysteria, server: h1.example.com, port: 443, auth-str: hy-auth-1, up: 100, down: 200, protocol: udp, obfs: salamander, obfs-password: obfspw }",
  // hysteria v1 的 auth_str 下划线写法
  "  - { name: 'hy1b', type: hysteria, server: h1b.example.com, port: 443, auth_str: hy-auth-2, up: 50, down: 100 }"
].join('\n');
const relayGroups = YMC.proxyItemGroups(relaySub);
eq('中继协议条目数', relayGroups.length, 4);
const relayNodes = [];
for (const g of relayGroups) {
  try { relayNodes.push(YMC.parseProxyItem(g)); } catch (e) { relayNodes.push(null); }
}
ok('中继协议全部条目解析成功', relayNodes.every((n) => n !== null),
  'null 数: ' + relayNodes.filter((n) => n === null).length);

const tuicV4 = relayNodes.find((n) => n !== null && n.name === 'tuic-v4');
ok('tuic v4: uuid 已回填', tuicV4 !== undefined && tuicV4.uuid === 'tuic-uuid-1');
ok('tuic v4: password 已回填', tuicV4 !== undefined && tuicV4.password === 'tuic-pw-1');
const tuicV5 = relayNodes.find((n) => n !== null && n.name === 'tuic-v5');
ok('tuic v5: password 槽保持为空（token 不回填）',
  tuicV5 !== undefined && tuicV5.password.length === 0);
ok('tuic v5: token 原样透传在 extraOpts',
  tuicV5 !== undefined && tuicV5.extraOpts.includes('"token"'));
const hy1 = relayNodes.find((n) => n !== null && n.name === 'hy1');
ok('hysteria v1: auth-str 回填进 password 槽',
  hy1 !== undefined && hy1.password === 'hy-auth-1');
ok('hysteria v1: up/down 已回填',
  hy1 !== undefined && hy1.hyUp === '100' && hy1.hyDown === '200');
ok('hysteria v1: protocol(传输协议) 已回填',
  hy1 !== undefined && hy1.protocol === 'udp');
ok('hysteria v1: auth-str 仍保留在 extraOpts（透传不丢）',
  hy1 !== undefined && hy1.extraOpts.includes('auth-str'));
const hy1b = relayNodes.find((n) => n !== null && n.name === 'hy1b');
ok('hysteria v1: auth_str 下划线写法同样回填',
  hy1b !== undefined && hy1b.password === 'hy-auth-2');

// 负对照：snell 用 psk、wireguard 没有口令概念 —— 不该被塞 password 槽
const otherRelaySub = [
  'proxies:',
  "  - { name: 'snell', type: snell, server: s.example.com, port: 443, psk: snell-psk, version: 4 }"
].join('\n');
const otherRelayNodes = YMC.proxyItemGroups(otherRelaySub)
  .map((g) => { try { return YMC.parseProxyItem(g); } catch (e) { return null; } });
ok('负对照: snell 的 psk 不进 password 槽',
  otherRelayNodes[0] !== null && otherRelayNodes[0].password.length === 0,
  otherRelayNodes[0] === null ? 'null' : otherRelayNodes[0].password);
ok('负对照: snell 的 psk 原样透传',
  otherRelayNodes[0] !== null && otherRelayNodes[0].extraOpts.includes('psk'));

// ── E. 生成层规则（文本断言：锁定「判定 + 键名」，防止被改回去）──────
// 生成器依赖链含 enum（ProxyNodeType）与多层本地 import，Node 的 strip-only 模式
// 加载不了；这里按仓库既有 verify-*.mjs 的「文本断言 + 负对照」风格锁定规则。
// 解析层（本文件上半部分）已用**真实源码行为断言**覆盖这些规则的输入侧。
const genSrc = readFileSync(
  join(svcDir, 'ClashConfigGenerator.ets'), 'utf8').replace(/\r\n/g, '\n');
const genDropBody = (() => {
  const start = genSrc.indexOf('static dropReasonFor(');
  if (start < 0) { return ''; }
  const end = genSrc.indexOf('static countDroppedNodes(', start);
  return genSrc.substring(start, end > 0 ? end : start + 4000);
})();
ok('生成层: 能定位 dropReasonFor', genDropBody.length > 0);

ok('生成层: tuic 放行 token 凭据（tuic v5 只有 token）',
  /hasExtraKey\(n\.extraOpts,\s*'token'\)/.test(genDropBody));
ok('生成层: tuic 不再硬性要求 uuid（v5 无 uuid）',
  !/proxyType === 'tuic' && \(n\.password\.length === 0 \|\| n\.uuid\.length === 0\)/.test(genDropBody));
ok('生成层: hysteria 不再把 protocol/up/down 当必填凭据',
  !/proxyType === 'hysteria'\s*&&\s*\(\s*n\.password\.length === 0 \|\| n\.protocol\.length === 0/.test(genDropBody));
ok('生成层: hysteria 仍要求口令（auth-str 回填后的 password 槽）',
  /proxyType === 'hysteria' && n\.password\.length === 0/.test(genDropBody));
ok('生成层: hysteria 额外回写 auth-str（与 URI 路径同口径）',
  /proxyType === 'hysteria'[\s\S]{0,120}auth-str:/.test(genSrc));
ok('生成层: hasExtraKey 辅助方法存在',
  /private static hasExtraKey\(/.test(genSrc));

const ymSrc = readFileSync(
  join(svcDir, 'YamlMerger.ets'), 'utf8').replace(/\r\n/g, '\n');
ok('解析层: RELAY_CREDENTIAL_SLOTS 回填表存在',
  /RELAY_CREDENTIAL_SLOTS/.test(ymSrc));
ok('解析层: tuic 的 token 不在回填表里（否则内核 v5 收到它不认的 password 键）',
  !/\['token',\s*'password'\]/.test(ymSrc) && !/\['token',\s*'token'\]/.test(ymSrc));
ok('解析层: hysteria 的 auth-str 回填进 password 槽',
  /\['auth-str',\s*'password'\]/.test(ymSrc) && /\['auth_str',\s*'password'\]/.test(ymSrc));

console.log('\n-----------------------------------------');
console.log('PASSED=' + passed + '  FAILED=' + failures.length);
if (failures.length > 0) {
  failures.forEach((f) => console.log('  FAIL ' + f));
  console.log('RESULT: YAML MERGER PARSE CHECKS FAILED');
  process.exit(1);
}
console.log('RESULT: YAML MERGER PARSE CHECKS PASSED');
