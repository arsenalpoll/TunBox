#!/usr/bin/env node
/**
 * 配置写盘前校验闸门（C23/C23b/C23c）验证 —— 跑**真源码**。
 *
 * 为什么要有这道闸门：mihomo 用 yaml.v3（**本机实测的那份构建是 gopkg.in/yaml.v3 v3.0.1**），
 * `uniqueKeys` 默认开启 → 同层级重复键 = TypeError → **整份配置拒载**（一个节点坏，整个 VPN 起不来）。
 * 用户报障原文「VPN 扩展启动异常: parse config:yaml: unmarshal errors:...」就是这个形态。
 *
 * 本脚本把真实 ArkTS 源码（ConfigValidator.ets）转成 Node 可执行的 .ts（只替换 import
 * 与系统能力 stub，校验逻辑一字不改），然后喂入一组**已知会拒载/已知应该合法**的样例，
 * 断言：
 *   1. 重复键（块式 / flow map / 嵌套 flow map）都能被检出；
 *   2. 降级层能把它们**就地修好**，修好后不再有阻塞问题；
 *   3. 合法配置**零假阳性**（不能把正常配置误判成坏配置）；
 *   4. 布尔字面量按**真实内核实测口径**处理：致命的是**带引号**的 "true"/"false"/"1"/"0"，
 *      不带引号的 yes/no/on/off 内核是接受的 → 不拦不改（详见 scripts/verify-config-validator-kernel.mjs）；
 *   5. rules 段的嵌套 seq 被检出。
 *
 * 跑法：node scripts/verify-config-validator.mjs
 * 退出码 0 = 全绿。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const src = path.join(root, 'entry/src/main/ets/commons/services/ConfigValidator.ets');

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

// ── 暂存真源码（只替换 import 与 AppLogger stub，逻辑一字不改） ─────────────
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'cfg-validator-'));
const code = fs.readFileSync(src, 'utf8')
  .replace(/import\s+\{\s*AppLogger\s*\}\s+from\s+'[^']+';\s*/,
    `const AppLogger = { warn() {}, info() {}, error() {} };\n`)
  .replace(/export\s+const\s+ConfigIssueKind/, 'export const ConfigIssueKind');
const staged = path.join(stage, 'ConfigValidator.ts');
fs.writeFileSync(staged, code, 'utf8');

const { ConfigValidator, ConfigIssueKind } = await import(pathToFileURL(staged).href);

const kinds = (r) => r.issues.map((i) => i.kind).sort();

console.log('── 1. 重复键检出（块式） ──');
{
  const text = [
    'mixed-port: 7890',
    'dns:',
    '  enable: true',
    '  enable: false',
    'proxies: []',
  ].join('\n');
  const r = ConfigValidator.validate(text);
  eq(kinds(r), [ConfigIssueKind.DUPLICATE_KEY], '同层级重复键被检出');
  eq(r.issues[0].key, 'enable', '重复键名正确');
  eq(r.issues[0].line, 4, '重复键行号正确');
  ok(!r.ok, '严格层判定为不通过');
}

console.log('── 2. flow map 内重复键（R0/R0b） ──');
{
  const text = [
    'proxies:',
    '  - {name: "E4 重复键", type: ss, server: e4.example.test, port: 8389,'
      + ' cipher: aes-256-gcm, cipher: aes-128-gcm, password: "REDACTED"}',
  ].join('\n');
  const r = ConfigValidator.validate(text);
  eq(kinds(r), [ConfigIssueKind.DUPLICATE_KEY_FLOW], 'flow map 重复 pair 被检出');
  ok(r.issues[0].key.includes('cipher'), '重复键名是 cipher');
}

console.log('── 3. 嵌套 flow map 重复键（R0b: ws-opts） ──');
{
  const text = [
    'proxies:',
    '  - {name: "n1", type: vless, server: a.test, port: 443, ws-opts: {path: /a, path: /b}}',
  ].join('\n');
  const r = ConfigValidator.validate(text);
  eq(kinds(r), [ConfigIssueKind.DUPLICATE_KEY_FLOW], '嵌套 flow map 重复 pair 被检出');
}

console.log('── 4. 顶层键重复（R2：覆盖层与生成段） ──');
{
  const text = [
    'mode: rule',
    'dns:',
    '  enable: true',
    'mode: global',
  ].join('\n');
  const r = ConfigValidator.validate(text);
  eq(kinds(r), [ConfigIssueKind.DUPLICATE_KEY], '顶层重复键被检出');
  eq(r.issues[0].line, 4, '行号指向**第二次**出现的位置（yaml.v3 的报错行号是首次出现）');
}

console.log('── 5. 合法配置零假阳性 ──');
{
  const text = [
    'mixed-port: 7890',
    'external-controller: 127.0.0.1:9090',
    'secret: "abc"',
    'mode: rule',
    'log-level: warning',
    'ipv6: false',
    'unified-delay: true',
    'dns:',
    '  enable: true',
    '  listen: 127.0.0.1:1053',
    '  enhanced-mode: fake-ip',
    '  fake-ip-filter:',
    '    - "*.lan"',
    '    - "*.local"',
    'sniffer:',
    '  enable: true',
    '  sniff:',
    '    HTTP: {}',
    '    TLS: {}',
    'profile:',
    '  store-selected: true',
    'proxies:',
    '  - {name: "n1", type: ss, server: a.test, port: 8389, cipher: aes-256-gcm, password: "p"}',
    '  - {name: "n2", type: ss, server: a.test, port: 8389, cipher: aes-256-gcm, password: "p"}',
    'proxy-groups:',
    '  - name: PROXY',
    '    type: select',
    '    proxies:',
    '      - "n1"',
    '      - "n2"',
    'rules:',
    '  - DOMAIN-SUFFIX,example.com,PROXY',
    '  - MATCH,PROXY',
  ].join('\n');
  const r = ConfigValidator.validate(text);
  eq(r.issues.length, 0, '合法配置零问题（两个同名 server 的节点不构成重复键）');
  ok(r.ok, '合法配置判定为通过');
}

console.log('── 6. 序列项之间的同名键不算重复（R7 与重复键是两回事） ──');
{
  const text = [
    'proxies:',
    '  - name: "a"',
    '    type: ss',
    '    server: x.test',
    '    port: 1',
    '  - name: "b"',
    '    type: ss',
    '    server: y.test',
    '    port: 2',
  ].join('\n');
  const r = ConfigValidator.validate(text);
  eq(r.issues.length, 0, '两个列表项各自的 name/type 不互相打架');
}

console.log('── 7. 布尔字面量：按**真实内核实测**口径 ──');
// ⚠ 口径来自真实内核（mihomo Meta 1.10.0，`mihomo.exe -t` 逐个实测），不是照抄方案文档：
//   不带引号的 yes/no/on/off  → 内核**接受**（yaml.v3 对 bool 目标有 YAML 1.1 兼容分支）
//   带引号的 "true"/"false"/"1"/"0" → 内核**整份拒载**（cannot unmarshal !!str `true` into bool）
{
  const fatal = ['allow-lan: "true"', 'dns:', '  enable: "false"'].join('\n');
  const r = ConfigValidator.validate(fatal);
  eq(kinds(r), [ConfigIssueKind.BOOL_AS_STR, ConfigIssueKind.BOOL_AS_STR], '带引号的布尔被检出');
  const rep = ConfigValidator.repair(fatal);
  ok(rep.ok, '降级后不再阻塞');
  ok(rep.text.includes('allow-lan: true'), 'allow-lan 的引号被去掉并归一为 true');
  ok(rep.text.includes('  enable: false'), 'dns.enable 的引号被去掉并归一为 false');
  const again = ConfigValidator.validate(rep.text);
  eq(again.issues.length, 0, '降级后重新校验零问题');
}

console.log('── 7b. 不带引号的 yes/no/on/off：内核接受 → 不拦、不改用户文本 ──');
{
  const text = ['allow-lan: yes', 'dns:', '  enable: on'].join('\n');
  const r = ConfigValidator.validate(text);
  eq(r.issues.length, 0, '不带引号的 yes/on 不算问题（内核吃得下）');
  const rep = ConfigValidator.repair(text);
  eq(rep.text, text, '原样保留，不擅自改写用户文本');
  ok(rep.ok, '判定通过');
}

console.log('── 7c. 带引号的 yes/on（yaml.v3 兼容表内）：内核接受 → 不拦 ──');
{
  const text = ['allow-lan: "yes"', 'dns:', '  enable: "off"'].join('\n');
  const r = ConfigValidator.validate(text);
  eq(r.issues.length, 0, '带引号的 yes/off 不算问题（内核兼容表内）');
}

console.log('── 7d. flow map 里的带引号布尔（`dns: {enable: "true"}`）同样致命 ──');
{
  const text = ['dns: {enable: "true", ipv6: false}'].join('\n');
  const r = ConfigValidator.validate(text);
  eq(kinds(r), [ConfigIssueKind.BOOL_AS_STR], 'flow map 内的带引号布尔被检出');
  const rep = ConfigValidator.repair(text);
  ok(rep.ok, '降级后不再阻塞');
  ok(rep.text.includes('enable: true'), 'flow map 内的引号被去掉');
  ok(rep.text.includes('ipv6: false'), '未受影响的兄弟键原样保留');
}

console.log('── 7e. 裸写数字落进 bool 字段（!!int into bool，内核实测同样拒载）──');
{
  const text = ['allow-lan: 1', 'dns:', '  enable: 0'].join('\n');
  const r = ConfigValidator.validate(text);
  eq(kinds(r), [ConfigIssueKind.BOOL_AS_STR, ConfigIssueKind.BOOL_AS_STR], '裸写 1/0 被检出');
  const rep = ConfigValidator.repair(text);
  ok(rep.ok, '降级后不再阻塞');
  ok(rep.text.includes('allow-lan: true'), '裸 1 归一为 true');
  ok(rep.text.includes('  enable: false'), '裸 0 归一为 false');
  eq(ConfigValidator.validate(rep.text).issues.length, 0, '降级后重新校验零问题');
}

console.log('── 7f. 裸写数字意图不明（如 allow-lan: 2）→ 不猜，判为阻塞 ──');
{
  const text = ['allow-lan: 2'].join('\n');
  const r = ConfigValidator.validate(text);
  eq(kinds(r), [ConfigIssueKind.BOOL_AS_STR], '被检出');
  ok(!r.ok, '严格层判为不通过');
  const rep = ConfigValidator.repair(text);
  ok(!rep.ok, '降级层也不放行（不擅自猜意图）');
  ok(rep.text.includes('allow-lan: 2'), '文本未被改写');
}

console.log('── 8. 非布尔路径上的 yes 原样保留（不擅自改用户文本） ──');
{
  const text = ['hosts:', '  "a.test": "1.2.3.4"', 'some-key: yes'].join('\n');
  const rep = ConfigValidator.repair(text);
  ok(rep.text.includes('some-key: yes'), '未知路径的 yes 未被改写');
  eq(ConfigValidator.validate(rep.text).issues.length, 0, '未知路径的 yes 不算问题');
}

console.log('── 9. rules 段嵌套 seq（R6） ──');
{
  const text = ['rules:', '  - - DOMAIN,example.com,PROXY'].join('\n');
  const r = ConfigValidator.validate(text);
  eq(kinds(r), [ConfigIssueKind.NESTED_SEQ], '嵌套 seq 被检出');
  ok(!r.ok, '严格层判定为不通过');
}

console.log('── 10. 受控降级：重复键被就地修好 ──');
{
  const text = [
    'proxies:',
    '  - {name: "n1", type: ss, server: a.test, port: 8389, cipher: aes-256-gcm,'
      + ' cipher: aes-128-gcm, password: "p"}',
    '  - {name: "n2", type: ss, server: b.test, port: 8389, cipher: aes-256-gcm, password: "p"}',
  ].join('\n');
  const rep = ConfigValidator.repair(text);
  ok(rep.ok, '降级后不阻塞');
  ok(rep.degraded, '标记为发生了降级');
  ok(rep.dropped > 0, `降级丢弃计数 > 0（实际 ${rep.dropped}）`);
  ok(!rep.text.includes('aes-128-gcm'), '重复的 cipher 已被删除');
  ok(rep.text.includes('aes-256-gcm'), '首个 cipher 被保留');
  ok(rep.text.includes('n2'), '其它节点未受影响（没有破坏其他节点）');
  eq(ConfigValidator.validate(rep.text).issues.length, 0, '降级产物零问题');
}

console.log('── 11. 块式重复键降级：删掉后一条及其子行 ──');
{
  const text = [
    'rule-providers:',
    '  my.provider:',
    '    type: http',
    '    behavior: classical',
    '  my.provider:',
    '    type: http',
    '    behavior: domain',
  ].join('\n');
  const rep = ConfigValidator.repair(text);
  ok(rep.ok, '降级后不阻塞');
  ok(!rep.text.includes('behavior: domain'), '后一条 provider 的字段被删除');
  ok(rep.text.includes('behavior: classical'), '首条 provider 的字段被保留');
}

console.log('── 12. 降级不误伤：没有重复键时文本不变 ──');
{
  const text = ['mixed-port: 7890', 'proxies: []'].join('\n');
  const rep = ConfigValidator.repair(text);
  eq(rep.text, text, '无问题时降级层原样返回文本');
  ok(rep.ok, '无问题时判定通过');
}

console.log('');
console.log(`RESULT: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
