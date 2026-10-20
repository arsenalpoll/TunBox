#!/usr/bin/env node
/**
 * 配置生成「完整性」验证 —— mihomo 启动失败（parse config: yaml: unmarshal errors）的回归门禁。
 *
 * 背景（2026-10-20 用户报障原文：Clash 内核启动失败: VPN 扩展启动异常:
 *       parse config:yaml: unmarshal errors:...）：
 *   mihomo 用 go.yaml.in/yaml/v3 v3.0.5，**uniqueKeys 默认开启**（decode.go:344）
 *   → 同一层级的重复键 = TypeError = **整份配置拒载**（全有全无：一个节点坏，
 *     整个 VPN 起不来），**不是**「后者覆盖前者」。
 *   yaml.v3 是 YAML 1.2 core schema：`yes/no/on/off` 解析为 **!!str**（不是 bool）
 *   → 落进 RawConfig 的 bool 字段就是 `cannot unmarshal !!str 'yes' into bool`。
 *
 * 本脚本**真跑**真实源码：
 *   ① 把 entry/src/main/ets + tools/true-chain-harness 复制到**临时目录**（不污染仓库，
 *      不改动 tools/true-chain-harness/generated 里的入库文件）；
 *   ② 跑真实的 tools/true-chain-harness/prepare.mjs（只重写 import 目标 + 注入系统能力 stub，
 *      解析/合并/映射逻辑一行不改），转译出可在 Node 里执行的 .ts；
 *   ③ 直接 import 转译后的**真实 ClashConfigGenerator / YamlMerger / SubscriptionService**，
 *      驱动真实的 ClashConfigGenerator.generate() 产出**真实内核配置**再断言。
 *
 * 覆盖场景（与《订阅解析内核化改造方案》§9.3 根因表一一对应）：
 *   1. flow-map 节点内重复键（R0/R0b，依赖 C15）→ 产物同 map 内不再出现重复键
 *   2. 点号 provider 名（R1）→ 键行保留为键行、字段仍归属它、RULE-SET 引用不再被丢弃
 *   3. 同名 provider（R4）→ 只出现一次，字段行没有落进上一条 provider
 *   4. 字段键名不同的同名 provider（R4'''）→ 整块被丢弃（不静默并错）
 *   5. 覆盖层写 dns:（R2）→ 产物顶层 dns: 只出现一次
 *   6. 覆盖层写 allow-lan: yes（R3）→ 产物是 allow-lan: true
 *   7. rules 行带 '- ' 前缀（R6）→ rules: 段没有嵌套 seq
 *   8. 产物含 store-selected: true（C22）且不含 store-selections
 *   9. safeGroupUrl('') 兜底是 https（C4）
 *  10. 产物「同层级重复键」扫描 → 0 问题
 *
 * 跑法：node scripts/verify-config-generation-integrity.mjs
 * 退出码 0 = 全绿。
 */
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');

// ── 0. .ets 里含 enum（ProxyDropReason），Node 的类型剥离模式不支持 enum，
//      必须用 --experimental-transform-types（整链转译）。本脚本自己带旗重启一次，
//      保证「node scripts/verify-config-generation-integrity.mjs」直接可跑。
if (!process.execArgv.includes('--experimental-transform-types')
  && process.env.TUNBOX_CFG_INTEGRITY_CHILD !== '1') {
  const res = spawnSync(
    process.execPath,
    ['--experimental-transform-types', '--no-warnings', fileURLToPath(import.meta.url)],
    { stdio: 'inherit', env: { ...process.env, TUNBOX_CFG_INTEGRITY_CHILD: '1' } },
  );
  process.exit(res.status === null ? 1 : res.status);
}

// ── 断言框架 ───────────────────────────────────────────────────────────────
let passed = 0;
let failed = 0;
let deferred = 0;

function ok(cond, label, detail) {
  if (cond) {
    passed++;
    console.log(`  ✅ ${label}`);
  } else {
    failed++;
    console.log(`  ❌ ${label}${detail ? `\n       ${detail}` : ''}`);
  }
}

function eq(actual, expected, label) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  ok(a === e, label, `期望 ${e}\n       实际 ${a}`);
}

function note(label, detail) {
  deferred++;
  console.log(`  ⏭ DEFERRED ${label}${detail ? `\n       ${detail}` : ''}`);
}

function section(title) {
  console.log(`\n${title}`);
}

// ── 1. 准备临时转译环境（真源码 → 真 .ts，不写仓库）─────────────────────────
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-cfg-integrity-'));
function cleanup() {
  try {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  } catch (e) {
    /* 临时目录清理失败不影响结论 */
  }
}

const harnessSrc = path.join(root, 'tools/true-chain-harness');
if (!fs.existsSync(harnessSrc)) {
  console.error(`FATAL: 找不到 tools/true-chain-harness（${harnessSrc}）`);
  process.exit(1);
}
fs.cpSync(path.join(root, 'entry/src/main/ets'), path.join(tmpRoot, 'entry/src/main/ets'),
  { recursive: true });
fs.cpSync(harnessSrc, path.join(tmpRoot, 'tools/true-chain-harness'), { recursive: true });
const prep = spawnSync(process.execPath,
  [path.join(tmpRoot, 'tools/true-chain-harness/prepare.mjs')],
  { encoding: 'utf8' });
if (prep.status !== 0) {
  console.error('FATAL: prepare.mjs 失败\n' + (prep.stdout || '') + (prep.stderr || ''));
  process.exit(1);
}
const genDir = path.join(tmpRoot, 'tools/true-chain-harness/generated');
const G = (name) => pathToFileURL(path.join(genDir, name)).href;

/**
 * 临时副本的 stubs 补丁：harness 的 stubs.ts 未必覆盖后来新增的 @kit.* 具名导出
 * （例如 @kit.BasicServicesKit 的 BusinessError）——缺一个具名导出就会让整个
 * import 链 SyntaxError。**只在临时副本里补最小替身**，不碰仓库里的任何文件。
 */
function patchTempStubs() {
  const stubsPath = path.join(genDir, 'stubs.ts');
  let stubs = fs.readFileSync(stubsPath, 'utf8');
  const needed = new Set();
  for (const file of fs.readdirSync(genDir)) {
    if (!file.endsWith('.ts')) {
      continue;
    }
    const text = fs.readFileSync(path.join(genDir, file), 'utf8');
    const re = /import\s+(?:type\s+)?\{([^}]*)\}\s+from\s*'\.\/stubs\.ts'/g;
    let m = re.exec(text);
    while (m !== null) {
      for (const raw of m[1].split(',')) {
        const name = raw.trim().split(/\s+as\s+/)[0].trim();
        if (name.length > 0) {
          needed.add(name);
        }
      }
      m = re.exec(text);
    }
  }
  const additions = [];
  for (const name of needed) {
    const exported = new RegExp(
      `export\\s+(?:const|class|function|let|var|interface|type|enum)\\s+${name}\\b`,
    );
    if (!exported.test(stubs)) {
      additions.push(`export class ${name} extends Error { code: number = 0; }`);
    }
  }
  if (additions.length > 0) {
    fs.writeFileSync(stubsPath,
      `${stubs}\n// [verify-config-generation-integrity] 临时补齐缺失的 @kit 具名导出\n`
      + `${additions.join('\n')}\n`, 'utf8');
    console.log(`（临时副本补齐 stubs 导出：${additions.length} 个）`);
  }
}
patchTempStubs();

const { ClashConfigGenerator } = await import(G('ClashConfigGenerator.ts'));
const { AppSettings } = await import(G('AppSettings.ts'));
const { ProxyNode } = await import(G('ProxyNode.ts'));
const { YamlMerger } = await import(G('YamlMerger.ts'));
const { SubscriptionService } = await import(G('SubscriptionService.ts'));

// ── 2. 通用工具 ────────────────────────────────────────────────────────────

/** 取第一行以 prefix 开头的行（缩进敏感）。 */
function findLine(lines, prefix) {
  for (const line of lines) {
    if (line.startsWith(prefix)) {
      return line;
    }
  }
  return null;
}

/** 统计「顶层键」出现次数（indent 0 的 key: 行）。 */
function countTopLevelKey(text, key) {
  let count = 0;
  for (const raw of text.split('\n')) {
    if (raw.length === 0 || raw.startsWith(' ') || raw.startsWith('\t')) {
      continue;
    }
    const t = raw.trim();
    if (t === key || t.startsWith(`${key}:`) || t.startsWith(`${key} `)) {
      count++;
    }
  }
  return count;
}

/** 在引号外找第一个冒号 → [key, value]；没有冒号返回 null。 */
function splitKey(content) {
  let quote = '';
  let depth = 0;
  for (let i = 0; i < content.length; i++) {
    const ch = content.charAt(i);
    if (quote.length > 0) {
      if (ch === quote) {
        quote = '';
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === '{' || ch === '[') {
      depth++;
      continue;
    }
    if (ch === '}' || ch === ']') {
      depth--;
      continue;
    }
    if (ch === ':' && depth === 0) {
      return { key: content.substring(0, i).trim(), value: content.substring(i + 1).trim() };
    }
  }
  return null;
}

/** 去掉尾部注释（引号感知）。 */
function stripComment(value) {
  const text = value.trim();
  if (text.startsWith('#')) {
    return '';
  }
  let quote = '';
  for (let i = 0; i < text.length; i++) {
    const ch = text.charAt(i);
    if (quote.length > 0) {
      if (ch === quote) {
        quote = '';
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === '#' && i > 0 && text.charAt(i - 1) === ' ') {
      return text.substring(0, i).trim();
    }
  }
  return text;
}

/** 按顶层分隔符切分（引号/括号感知）。 */
function splitTopLevel(text, sep) {
  const parts = [];
  let quote = '';
  let depth = 0;
  let current = '';
  for (let i = 0; i < text.length; i++) {
    const ch = text.charAt(i);
    if (quote.length > 0) {
      current += ch;
      if (ch === quote) {
        quote = '';
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      current += ch;
      continue;
    }
    if (ch === '{' || ch === '[') {
      depth++;
      current += ch;
      continue;
    }
    if (ch === '}' || ch === ']') {
      depth--;
      current += ch;
      continue;
    }
    if (ch === sep && depth === 0) {
      parts.push(current);
      current = '';
      continue;
    }
    current += ch;
  }
  parts.push(current);
  return parts;
}

/** 扫描 flow collection（{...} / [...]）里的重复键。 */
function scanFlow(text, lineNo, problems) {
  const trimmed = text.trim();
  if (trimmed.startsWith('[')) {
    const inner = trimmed.substring(1, trimmed.lastIndexOf(']'));
    for (const part of splitTopLevel(inner, ',')) {
      const p = part.trim();
      if (p.startsWith('{') || p.startsWith('[')) {
        scanFlow(p, lineNo, problems);
      }
    }
    return;
  }
  if (!trimmed.startsWith('{')) {
    return;
  }
  const inner = trimmed.substring(1, trimmed.lastIndexOf('}'));
  const keys = new Set();
  for (const part of splitTopLevel(inner, ',')) {
    const p = part.trim();
    if (p.length === 0) {
      continue;
    }
    const ki = splitKey(p);
    if (ki === null) {
      continue;
    }
    if (keys.has(ki.key)) {
      problems.push({ key: ki.key, line: lineNo, where: 'flow map' });
    } else {
      keys.add(ki.key);
    }
    const v = ki.value.trim();
    if (v.startsWith('{') || v.startsWith('[')) {
      scanFlow(v, lineNo, problems);
    }
  }
}

/**
 * 「同层级重复键」扫描 —— 模拟 yaml.v3 uniqueKeys 的判定：
 * 同一个 mapping 内出现两个同名键即问题（顶层 / 块内 / flow map 内都算）。
 */
function scanDuplicateKeys(text) {
  const problems = [];
  const lines = text.split('\n');
  const root = { indent: -1, keys: new Set() };
  const stack = [root];
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const trimmed = raw.trim();
    if (trimmed.length === 0 || trimmed.startsWith('#')) {
      continue;
    }
    const indent = raw.length - raw.trimStart().length;
    while (stack.length > 1 && stack[stack.length - 1].indent >= indent) {
      stack.pop();
    }
    let content = trimmed;
    let seqItem = false;
    if (content === '-' || content.startsWith('- ')) {
      seqItem = true;
      content = content === '-' ? '' : content.substring(2).trim();
    }
    if (content.length === 0) {
      continue;
    }
    if (content.startsWith('{') || content.startsWith('[')) {
      scanFlow(content, i + 1, problems);
      if (seqItem) {
        stack.push({ indent, keys: new Set() });
      }
      continue;
    }
    const ki = splitKey(content);
    if (ki === null) {
      continue;
    }
    const key = ki.key;
    const value = stripComment(ki.value);
    if (seqItem) {
      // 序列项本身是一个 map：键属于这个 item 自己的层级
      const itemFrame = { indent, keys: new Set() };
      itemFrame.keys.add(key);
      stack.push(itemFrame);
      continue;
    }
    const frame = stack[stack.length - 1];
    if (frame.keys.has(key)) {
      problems.push({ key, line: i + 1, where: `indent ${indent}` });
    } else {
      frame.keys.add(key);
    }
    if (value.length === 0) {
      stack.push({ indent, keys: new Set() });
    } else if (value.startsWith('{') || value.startsWith('[')) {
      scanFlow(value, i + 1, problems);
    }
  }
  return problems;
}

/** 构造一个可写入内核的 vless 节点。 */
function makeNode(name, extra) {
  const n = new ProxyNode();
  n.id = `id-${name}`;
  n.subscriptionId = 'sub-1';
  n.originalName = name;
  n.name = name;
  n.server = 'example.invalid';
  n.port = 443;
  n.proxyType = 'vless';
  n.uuid = '11111111-2222-3333-4444-555555555555';
  n.tls = true;
  if (extra) {
    Object.assign(n, extra);
  }
  return n;
}

/** 基础设置（默认全开规则、关去广告、关双轨）。 */
function baseSettings() {
  const s = new AppSettings();
  s.rulesEnabled = true;
  s.hyperAdRulesEnabled = false;
  s.useRawProviderConfig = false;
  s.customRuleSets = [];
  s.customRules = [];
  s.yamlOverride = '';
  return s;
}

/** 驱动**真实** generate()。 */
function generateConfig(opts) {
  const o = opts || {};
  const settings = o.settings || baseSettings();
  const nodes = o.nodes || [makeNode('node-A')];
  const selected = o.selected || nodes[0];
  return ClashConfigGenerator.generate(
    selected, nodes, settings,
    o.mixedPort === undefined ? 7890 : o.mixedPort,
    o.apiPort === undefined ? 9090 : o.apiPort,
    o.dnsPort === undefined ? 1053 : o.dnsPort,
    o.apiSecret === undefined ? 'secret' : o.apiSecret,
    o.useGeoip === undefined ? false : o.useGeoip,
    o.ipv6Enabled === undefined ? false : o.ipv6Enabled,
    o.proxyHosts || {},
    o.tunEnabled === undefined ? true : o.tunEnabled,
    o.proxyGroups || [],
    o.ruleProviderReady === undefined ? true : o.ruleProviderReady,
    o.useSmart === undefined ? false : o.useSmart,
    o.subscriptionRules || [],
    o.subscriptionRuleProviders || '',
  );
}

console.log('配置生成完整性验证（mihomo yaml uniqueKeys / YAML 1.2 布尔）');
console.log(`临时转译环境：${tmpRoot}`);

// ── 真实内核（可选但强烈建议）：mihomo.exe -t -d <dir> -f <cfg> = 真判决 ──
// 本机路径：C:\Worker\TunBox\mihomo-build\<build>\mihomo.exe（与 App 内置同一份构建）。
// 找不到就整段降级为「跳过」（不判失败），保证脚本在别的机器上也能跑。
const MIHOMO_CANDIDATES = [
  'C:/Worker/TunBox/mihomo-build/mihomo-smart-8d4c8c70faedc27fda176ee18742ab86b5835a83/mihomo.exe',
];
function findMihomo() {
  for (const p of MIHOMO_CANDIDATES) {
    if (fs.existsSync(p)) {
      return p;
    }
  }
  const buildRoot = path.join(root, '..', 'mihomo-build');
  if (fs.existsSync(buildRoot)) {
    for (const dir of fs.readdirSync(buildRoot)) {
      const candidate = path.join(buildRoot, dir, 'mihomo.exe');
      if (fs.existsSync(candidate)) {
        return candidate;
      }
    }
  }
  return '';
}
const MIHOMO = findMihomo();
console.log(MIHOMO.length > 0
  ? `真实内核：${MIHOMO}`
  : '真实内核：未找到 mihomo.exe（真实内核判定将跳过，不影响其余断言）');

/** 用真实内核判定配置是否被接受（mihomo -t）。 */
function kernelAccepts(cfgText) {
  if (MIHOMO.length === 0) {
    return { skipped: true, ok: false, output: '' };
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-kernel-'));
  const cfgPath = path.join(dir, 'config.yaml');
  fs.writeFileSync(cfgPath, cfgText, 'utf8');
  const res = spawnSync(MIHOMO, ['-t', '-d', dir, '-f', cfgPath], { encoding: 'utf8' });
  const output = `${res.stdout || ''}${res.stderr || ''}`;
  try {
    fs.rmSync(dir, { recursive: true, force: true });
  } catch (e) {
    /* 临时目录清理失败不影响结论 */
  }
  return { skipped: false, ok: res.status === 0, output };
}

/** 真实内核判定（找不到内核则跳过，不判失败）。 */
function kernelOk(cfgText, label) {
  const res = kernelAccepts(cfgText);
  if (res.skipped) {
    note(`${label}：真实内核判定（跳过：未找到 mihomo.exe）`);
    return;
  }
  ok(res.ok, `${label}：真实内核 mihomo -t 接受该配置`,
    res.ok ? '' : res.output.split('\n')
      .filter((l) => l.includes('error') || l.includes('cannot') || l.includes('failed'))
      .slice(0, 4).join('\n       '));
}

// ── 场景 1：flow-map 节点内重复键（R0 / R0b，依赖 C15）──────────────────
section('[1] flow-map 节点内重复键 → 产物同 map 内不再出现重复键（R0/R0b）');
{
  const body = [
    'proxies:',
    '  - {name: "dup-cipher", type: vless, server: ex1.invalid, port: 443, uuid: u1, cipher: aes-128-gcm, cipher: chacha20-ietf-poly1305}',
    '  - {name: "dup-nested", type: vless, server: ex2.invalid, port: 443, uuid: u2, ws-opts: {path: /a, path: /b}}',
  ].join('\n');
  const merged = YamlMerger.merge([body], 'sub', 'sub-1');
  const nodes = SubscriptionService['mergedToNodes'](merged, 'sub-1');
  ok(nodes.length === 2, `真实合并链解析出 2 个节点（实际 ${nodes.length}）`);
  const cfg = generateConfig({ nodes });
  const problems = scanDuplicateKeys(cfg);
  const dupInProxies = problems.filter((p) => p.key === 'cipher' || p.key === 'path');
  if (dupInProxies.length === 0) {
    ok(true, '产物中 flow-map 内不再出现重复键（cipher / path 各只出现一次）');
  } else {
    ok(false, '产物中 flow-map 内不再出现重复键（cipher / path 各只出现一次）',
      `仍有重复：${JSON.stringify(dupInProxies)}`);
  }
  const cipherCount = (cfg.match(/\bcipher:/g) || []).length;
  ok(cipherCount <= 2, `cipher 键出现次数 ${cipherCount}（两个节点各至多一个）`);
  const allProblems = scanDuplicateKeys(cfg);
  ok(allProblems.length === 0, '整份产物同层级重复键扫描 → 0 问题',
    JSON.stringify(allProblems));
}

// ── 场景 2：点号 provider 名（R1）────────────────────────────────────────
section('[2] 点号 provider 名（my.provider:）→ 键行保留、字段归属它、RULE-SET 不被丢弃');
{
  const providers = [
    '  my.provider:',
    '    type: http',
    '    behavior: classical',
    '    format: yaml',
    '    url: "https://example.invalid/my.provider.yaml"',
  ].join('\n');
  const cfg = generateConfig({
    subscriptionRuleProviders: providers,
    subscriptionRules: ['RULE-SET,my.provider,DIRECT'],
  });
  const lines = cfg.split('\n');
  ok(findLine(lines, '  my.provider:') !== null, '点号名的键行被保留为**键行**（2 空格）');
  ok(findLine(lines, '    type: http') !== null, '它的字段行仍是 4 空格字段行');
  const keyIdx = lines.findIndex((l) => l === '  my.provider:');
  const fieldIdx = lines.findIndex((l) => l === '    type: http');
  ok(keyIdx >= 0 && fieldIdx > keyIdx, '字段行紧跟在键行之后（没有变成兄弟键）');
  ok(cfg.includes('  - RULE-SET,my.provider,DIRECT'), '引用该 provider 的 RULE-SET 规则**未被丢弃**');
  ok(ClashConfigGenerator.lastSkippedUserRules === 0,
    `跳过的用户规则数 = 0（实际 ${ClashConfigGenerator.lastSkippedUserRules}）`);
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
  kernelOk(cfg, '含点号 provider 名 + RULE-SET 引用的配置');
}

// ── 场景 3：同名 provider（R4）───────────────────────────────────────────
section('[3] 同名 provider → 只出现一次，字段行没有落进上一条 provider');
{
  const providers = [
    '  dup:',
    '    type: http',
    '    behavior: classical',
    '  dup:',
    '    type: http',
    '    interval: 3600',
  ].join('\n');
  const cfg = generateConfig({ subscriptionRuleProviders: providers });
  const lines = cfg.split('\n');
  const dupKeys = lines.filter((l) => l === '  dup:').length;
  eq(dupKeys, 1, '同名 provider 的键行只出现一次');
  ok(!cfg.includes('    interval: 3600'), '重复块的字段行被**整块丢弃**（没落进上一条）');
  ok(cfg.includes('    behavior: classical'), '第一条 provider 的字段完好保留');
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
  kernelOk(cfg, '同名 provider 去重后的配置');
}

// ── 场景 4：字段键名不同的同名 provider（R4''' 静默并错）────────────────
section('[4] 字段键名与上一条不同的同名 provider → 整块被丢弃（不静默并错）');
{
  const providers = [
    '  other:',
    '    type: http',
    '    behavior: classical',
    '  dup:',
    '    type: http',
    '    behavior: classical',
    '  dup:',
    '    type: http',
    '    interval: 3600',
    '    url: "https://example.invalid/dup.yaml"',
  ].join('\n');
  const cfg = generateConfig({ subscriptionRuleProviders: providers });
  const lines = cfg.split('\n');
  eq(lines.filter((l) => l === '  dup:').length, 1, '同名 provider 只出现一次');
  ok(!cfg.includes('    interval: 3600'), '第二条 dup 的字段（interval）被整块丢弃');
  ok(!cfg.includes('https://example.invalid/dup.yaml'), '第二条 dup 的字段（url）被整块丢弃');
  ok(cfg.includes('    behavior: classical'), '第一条 dup 的字段完好保留');
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
}

// ── 场景 5：覆盖层写 dns:（R2）──────────────────────────────────────────
section('[5] 覆盖层写 dns: → 产物顶层 dns: 只出现一次（R2）');
{
  const settings = baseSettings();
  settings.yamlOverride = [
    'dns:',
    '  enable: true',
    '  ipv6: false',
    '  listen: "0.0.0.0:1053"',
  ].join('\n');
  const cfg = generateConfig({ settings });
  eq(countTopLevelKey(cfg, 'dns'), 1, '顶层 dns: 只出现一次');
  ok(cfg.includes('  listen: "0.0.0.0:1053"'), '覆盖层的 dns 内容被保留（用户能力不丢）');
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
  kernelOk(cfg, '覆盖层写 dns: 之后的配置');
}

// ── 场景 6：覆盖层布尔字面量（R3，按真实内核实测口径）──────────────────
section('[6] 覆盖层布尔字面量：带引号的 "true"/"1" 等致命写法必须被改写（R3）');
{
  const settings = baseSettings();
  settings.yamlOverride = [
    'allow-lan: yes',            // 裸写：内核本来就吃（实测），这里只做规范化
    'unified-delay: on',
    'tcp-concurrent: OFF',
    'ipv6: "true"',              // 带引号的 true：**致命**（!!str into bool）→ 必须改写
    'dns:',
    '  enable: "yes"',           // 带引号的 yes：内核能吃 → 保持原样
    '  respect-rules: "0"',      // 带引号的 "0"：**致命** → 必须改写
    '  ipv6: 1',                 // 裸写 1（!!int into bool）：**致命** → 必须改写
  ].join('\n');
  const cfg = generateConfig({ settings });
  ok(cfg.includes('allow-lan: true'), '裸写 allow-lan: yes → allow-lan: true（规范化）');
  ok(cfg.includes('unified-delay: true'), '裸写 unified-delay: on → true（规范化）');
  ok(cfg.includes('tcp-concurrent: false'), '裸写 tcp-concurrent: OFF → false（规范化）');
  ok(cfg.includes('ipv6: true'), '带引号的 ipv6: "true" → 裸 true（去掉引号）');
  ok(!cfg.includes('"true"'), '产物里不再残留带引号的 "true"（!!str into bool 会整份拒载）');
  ok(cfg.includes('  respect-rules: false'), '带引号的 dns.respect-rules: "0" → 裸 false');
  ok(cfg.includes('  ipv6: true'), '裸写的 dns.ipv6: 1 → 裸 true（!!int into bool 同样致命）');
  ok(cfg.includes('  enable: "yes"'), '带引号的 "yes" 内核能吃 → 保持原样（不擅自改写）');
  ok(!/: "1"/.test(cfg) && !/: "0"/.test(cfg), '产物里不再残留带引号的 "1"/"0"');
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
  kernelOk(cfg, '含各种布尔写法的覆盖层配置');
}

// ── 场景 7：rules 行带 '- ' 前缀（R6）───────────────────────────────────
section('[7] rules 行带 "- " 前缀 → rules: 段没有嵌套 seq（R6）');
{
  const cfg = generateConfig({
    subscriptionRules: [
      '- DOMAIN-SUFFIX,example.invalid,DIRECT',
      'DOMAIN,foo.invalid,DIRECT',
    ],
  });
  const lines = cfg.split('\n');
  const rulesIdx = lines.findIndex((l) => l === 'rules:');
  ok(rulesIdx >= 0, '找到 rules: 段');
  const ruleLines = lines.slice(rulesIdx + 1).filter((l) => l.trim().startsWith('- '));
  ok(ruleLines.length > 0, `rules: 段有 ${ruleLines.length} 条规则`);
  ok(!ruleLines.some((l) => l.trim().startsWith('- - ')), 'rules: 段没有 "- - "（嵌套 seq）');
  ok(cfg.includes('  - DOMAIN-SUFFIX,example.invalid,DIRECT'),
    '带 "- " 前缀的规则被剥离后正常写入');
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
  kernelOk(cfg, '规则带 "- " 前缀被剥离后的配置');
}

// ── 场景 8：store-selected（C22）────────────────────────────────────────
section('[8] profile: store-selected: true（C22，键名不是 store-selections）');
{
  const cfg = generateConfig({});
  ok(cfg.includes('  store-selected: true'), '产物含 store-selected: true');
  ok(!cfg.includes('store-selections'), '产物不含 store-selections（错键已清除）');
}

// ── 场景 9：组测速 URL 兜底（C4）───────────────────────────────────────
section('[9] safeGroupUrl("") 兜底是 https（C4）');
{
  eq(ClashConfigGenerator.safeGroupUrl(''), 'https://www.gstatic.com/generate_204',
    '空串兜底 = https://www.gstatic.com/generate_204');
  ok(ClashConfigGenerator.safeGroupUrl('http://example.invalid/x').includes('http://example.invalid/x'),
    '用户自填的 http 地址保持原样（不被改写）');
  ok(ClashConfigGenerator.safeGroupUrl('https://example.invalid/x').includes('https://example.invalid/x'),
    '用户自填的 https 地址保持原样');
}

// ── 场景 10：整链综合产物扫描 ───────────────────────────────────────────
section('[10] 综合场景：订阅 provider + 覆盖层 + 自定义规则集 → 同层级重复键 0 问题');
{
  const settings = baseSettings();
  settings.yamlOverride = [
    'dns:',
    '  enable: true',
    '  ipv6: false',
    'allow-lan: yes',
  ].join('\n');
  const cfg = generateConfig({
    settings,
    subscriptionRuleProviders: [
      '  my.provider:',
      '    type: http',
      '    behavior: classical',
      '  my.provider:',
      '    type: http',
      '    interval: 3600',
    ].join('\n'),
    subscriptionRules: [
      'RULE-SET,my.provider,DIRECT',
      '- DOMAIN-SUFFIX,example.invalid,DIRECT',
    ],
  });
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '综合产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
  eq(countTopLevelKey(cfg, 'dns'), 1, '顶层 dns: 仍只出现一次');
  eq(countTopLevelKey(cfg, 'rule-providers'), 1, '顶层 rule-providers: 只有 1 个');
  eq(countTopLevelKey(cfg, 'rules'), 1, '顶层 rules: 只有 1 个');
  eq(countTopLevelKey(cfg, 'profile'), 1, '顶层 profile: 只有 1 个');
  ok(cfg.includes('  - RULE-SET,my.provider,DIRECT'), 'RULE-SET 引用仍在（没被静默丢弃）');
  kernelOk(cfg, '综合场景（订阅 provider + 重复 provider + 覆盖层 dns/allow-lan）的配置');
}

// ── 场景 11：覆盖层空段不得抹掉生成器的同名段 ──────────────────────────
section('[11] 覆盖层空段（rules: 只有注释）→ 不抹掉生成器的规则、也不产生重复键');
{
  const settings = baseSettings();
  settings.yamlOverride = [
    'rules:',
    '  # 这里本来想写规则',
  ].join('\n');
  const cfg = generateConfig({ settings });
  eq(countTopLevelKey(cfg, 'rules'), 1, '顶层 rules: 仍只有 1 个');
  ok(cfg.includes('  - MATCH,PROXY'), '生成器的兜底规则没有被空段抹掉');
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
}

// ── 场景 12：覆盖层自身重复顶层键 → 整段去重（保留首个）─────────────────
section('[12] 覆盖层自身重复顶层键 → 保留首个，不产生重复顶层键');
{
  const settings = baseSettings();
  settings.yamlOverride = [
    'custom-x: 1',
    'custom-x: 2',
  ].join('\n');
  const cfg = generateConfig({ settings });
  eq(countTopLevelKey(cfg, 'custom-x'), 1, '顶层 custom-x: 只出现一次');
  ok(cfg.includes('custom-x: 1'), '保留的是首个值');
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
}

// ── 场景 13：真实内核的阴性对照（证明内核判定不是「永远通过」）────────────
section('[13] 真实内核阴性对照：手工造坏的配置必须被内核拒载');
{
  const broken = [
    'mixed-port: 7890',
    'mode: rule',
    'dns:',
    '  enable: true',
    'dns:',                       // ← 重复顶层键（uniqueKeys → 整份拒载）
    '  enable: false',
    'allow-lan: "true"',          // ← 带引号的 bool（!!str into bool → 整份拒载）
    'rules:',
    '  - MATCH,DIRECT',
  ].join('\n');
  const res = kernelAccepts(broken);
  if (res.skipped) {
    note('阴性对照：真实内核判定（跳过：未找到 mihomo.exe）');
  } else {
    ok(!res.ok, '坏配置（重复顶层键 + 带引号布尔）被真实内核拒载（判定有牙齿）',
      res.output.split('\n').filter((l) => l.includes('error') || l.includes('cannot')).slice(0, 4).join('\n       '));
  }
}

console.log(`\n${passed} passed, ${failed} failed, ${deferred} deferred`);
if (failed === 0) {
  cleanup();
  process.exit(0);
}
console.log(`（失败时保留临时转译环境便于排查：${tmpRoot}）`);
process.exit(1);
