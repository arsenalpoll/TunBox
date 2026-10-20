#!/usr/bin/env node
/**
 * 订阅解析「完整性」验证 —— C14 / C15 / C16 的回归门禁。
 *
 * 背景（真机报障原文：`Clash 内核启动失败: VPN 扩展启动异常:
 *       parse config:yaml: unmarshal errors:...`）：
 *   mihomo 用 go.yaml.in/yaml/v3 v3.0.5，**uniqueKeys 默认开启**（decode.go:344）
 *   → 同一层级的重复键 = TypeError = **整份配置拒载**（全有全无：一个节点坏，
 *     整个 VPN 起不来），**不是**「后者覆盖前者」。
 *
 * 本脚本**真跑**真实源码（不是复制逻辑）：
 *   ① 把 entry/src/main/ets + tools/true-chain-harness 复制到**临时目录**（不污染仓库，
 *      不改动 tools/true-chain-harness/generated 里的入库文件）；
 *   ② 跑真实的 tools/true-chain-harness/prepare.mjs（只重写 import 目标 + 注入系统能力 stub，
 *      解析/合并/映射逻辑一行不改），转译出可在 Node 里执行的 .ts；
 *   ③ 直接 import 转译后的**真实 YamlMerger / SubscriptionService**，
 *     驱动真实的 YamlMerger.merge() 与真实的 SubscriptionService
 *     .subscriptionRuleProvidersBlock() 再断言。
 *
 * 覆盖场景（与《订阅解析内核化改造方案》§9.4 的 C14/C15/C16 一一对应）：
 *   1. 【C14】anytls 订阅节点 → MergedProxy.password 非空、type 仍是 anytls
 *      （块式 / flow-map / 块式+flow-map 三种写法各一个）
 *   2. 【C15】flow-map 节点内重复键 → rawTemplate 里该 key 只出现一次
 *      **且** 诊断被记录（lastDuplicateKeyCount / lastDuplicateKeyReasons）
 *   2b.【C15/R0b】嵌套 map 内重复键（ws-opts: {path: /a, path: /b}）→ 同样去重
 *   3. 【C16】点号 provider 名（my.provider:）→ 合并后的 rule-providers 文本里
 *      只出现一次，且它的字段行**没有**降级成兄弟键
 *   4. 【C16】同名 provider → 只保留一条，且它的字段行**没有**并进上一条 provider
 *      （两种变体：字段键名相同 / 字段键名不同）
 *   5. 不回归：块式写法的节点解析结果与预期一致（节点数 / type / server / port / password）
 *
 * 跑法：node scripts/verify-subscription-parse-integrity.mjs
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
//      保证「node scripts/verify-subscription-parse-integrity.mjs」直接可跑。
if (!process.execArgv.includes('--experimental-transform-types')
  && process.env.TUNBOX_SUBPARSE_CHILD !== '1') {
  const res = spawnSync(
    process.execPath,
    ['--experimental-transform-types', '--no-warnings', fileURLToPath(import.meta.url)],
    { stdio: 'inherit', env: { ...process.env, TUNBOX_SUBPARSE_CHILD: '1' } },
  );
  process.exit(res.status === null ? 1 : res.status);
}

// ── 断言框架 ───────────────────────────────────────────────────────────────
let passed = 0;
let failed = 0;

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

function section(title) {
  console.log(`\n${title}`);
}

// ── 1. 准备临时转译环境（真源码 → 真 .ts，不写仓库）─────────────────────────
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-subparse-'));
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
 * —— 缺一个具名导出就会让整个 import 链 SyntaxError。**只在临时副本里补最小替身**。
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
      `${stubs}\n// [verify-subscription-parse-integrity] 临时补齐缺失的 @kit 具名导出\n`
      + `${additions.join('\n')}\n`, 'utf8');
    console.log(`（临时副本补齐 stubs 导出：${additions.length} 个）`);
  }
}
patchTempStubs();

const { YamlMerger } = await import(G('YamlMerger.ts'));
const { SubscriptionService } = await import(G('SubscriptionService.ts'));
const { Subscription } = await import(G('Subscription.ts'));
const { ClashConfigGenerator } = await import(G('ClashConfigGenerator.ts'));

// ── 2. 测试侧小工具（只做「字符串统计」，不复制被测的解析逻辑）──────────────

/** 统计一段文本里「缩进恰好为 indent 且内容以 prefix 开头」的行出现的次数。 */
function countIndented(text, indent, prefix) {
  const pad = ' '.repeat(indent);
  let n = 0;
  for (const raw of text.split('\n')) {
    if (!raw.startsWith(pad) || raw.startsWith(pad + ' ')) {
      continue; // 缩进不是恰好 indent（更深一层）
    }
    if (raw.trim().startsWith(prefix)) {
      n++;
    }
  }
  return n;
}

/** 取一行去掉首尾空白后的内容（用于比较 provider 键行）。 */
function trimmedLines(text) {
  return text.split('\n').map((l) => l.trim()).filter((l) => l.length > 0);
}

/**
 * 统计 flow-map 文本（`k: v, k2: v2`）里某个 key 出现了几次。
 * 只在**顶层**逗号处切分（花括号/方括号/引号内的逗号不算），逐段取冒号前的 key。
 */
function countFlowMapKey(flowText, key) {
  const parts = [];
  let depth = 0;
  let quote = '';
  let current = '';
  for (let i = 0; i < flowText.length; i++) {
    const ch = flowText.charAt(i);
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
    } else if (ch === '}' || ch === ']') {
      depth--;
    }
    if (ch === ',' && depth === 0) {
      parts.push(current);
      current = '';
      continue;
    }
    current += ch;
  }
  parts.push(current);
  let n = 0;
  for (const part of parts) {
    const t = part.trim();
    if (!t.startsWith(key + ':') && t !== key) {
      continue;
    }
    n++;
  }
  return n;
}

/** 合并真实 YamlMerger 的结果（先清统计，便于逐例断言）。 */
function mergeNodes(yaml) {
  YamlMerger.resetSkipStats();
  return YamlMerger.merge([yaml], 'verify-subscription-parse-integrity', '');
}

function nodeByName(nodes, name) {
  for (const n of nodes) {
    if (n.name === name) {
      return n;
    }
  }
  return null;
}

// ── 3. C14：anytls 凭据回填 ────────────────────────────────────────────────
section('【C14】anytls 订阅节点 → password 非空且 type 仍是 anytls');
{
  const yaml = [
    'proxies:',
    '  - {name: "anytls-flow", type: anytls, server: a.example.test, port: 8444,',
    '     password: "pw-anytls-flow", sni: "a.example.test"}',
    '  - name: "anytls-blockstyle"',
    '    type: anytls',
    '    server: b.example.test',
    '    port: 8445',
    '    password: "pw-anytls-blockstyle"',
    '  - {name: "anytls-plain", type: anytls, server: c.example.test, port: 8446,',
    '     password: "pw-anytls-plain"}',
    '',
  ].join('\n');
  const nodes = mergeNodes(yaml);
  eq(nodes.length, 3, 'anytls 三个节点都解析成功（未被整批丢弃）');
  for (const [name, want] of [['anytls-flow', 'pw-anytls-flow'],
    ['anytls-blockstyle', 'pw-anytls-blockstyle'],
    ['anytls-plain', 'pw-anytls-plain']]) {
    const n = nodeByName(nodes, name);
    ok(n !== null, `节点 ${name} 存在`);
    if (n === null) {
      continue;
    }
    eq(n.type, 'anytls', `${name} 的 type 仍是 anytls`);
    ok(n.password.length > 0, `${name} 的 password 非空`,
      `实际 password="${n.password}"`);
    eq(n.password, want, `${name} 的 password 值正确`);
  }
  // C14 的显式要求：anytls 必须**逐个类型**列进回填表（精确匹配，不靠同族推断）
  const relayCred = YamlMerger.RELAY_CREDENTIAL_TYPES;
  ok(relayCred !== undefined && relayCred.has('anytls'),
    'RELAY_CREDENTIAL_TYPES 显式包含 anytls（精确匹配，不靠「同族」推断）');
  ok(relayCred !== undefined && relayCred.has('naive'),
    'RELAY_CREDENTIAL_TYPES 仍包含 naive（两个类型必须各自列出）');
}

// ── 4. C15：flow-map 重复键去重 + 诊断 ────────────────────────────────────
section('【C15】flow-map 重复键 → rawTemplate 只留首个 + 诊断被记录');
{
  const yaml = [
    'proxies:',
    '  - {name: "dup-cipher", type: ss, server: s1.example.test, port: 8389,',
    '     cipher: aes-256-gcm, cipher: aes-128-gcm, password: "pw-dup-cipher"}',
    '  - {name: "dup-nested", type: vless, server: s2.example.test, port: 443,',
    '     uuid: "uuid-dup-nested", servername: s2.example.test, network: ws,',
    '     ws-opts: {path: /dup, path: /dup2}}',
    '',
  ].join('\n');
  const nodes = mergeNodes(yaml);
  eq(nodes.length, 2, '两个含重复键的节点都解析成功（没被整条丢弃）');

  const cipherNode = nodeByName(nodes, 'dup-cipher');
  ok(cipherNode !== null, '节点 dup-cipher 存在');
  if (cipherNode !== null) {
    eq(countFlowMapKey(cipherNode.rawTemplate, 'cipher'), 1,
      'dup-cipher 的 rawTemplate 里 cipher 只出现一次');
    ok(!cipherNode.rawTemplate.includes('aes-128-gcm'),
      'dup-cipher 的 rawTemplate 不含被丢弃的第二个 cipher 值',
      `rawTemplate=${cipherNode.rawTemplate}`);
    ok(cipherNode.rawTemplate.includes('aes-256-gcm'),
      'dup-cipher 的 rawTemplate 保留了首次出现的 cipher 值',
      `rawTemplate=${cipherNode.rawTemplate}`);
    eq(cipherNode.cipher, 'aes-256-gcm',
      'dup-cipher 的结构化 cipher 也是首次出现（解析口径与模板一致）');
    eq(cipherNode.password, 'pw-dup-cipher', 'dup-cipher 的 password 未受影响');
  }

  const nestedNode = nodeByName(nodes, 'dup-nested');
  ok(nestedNode !== null, '节点 dup-nested 存在');
  if (nestedNode !== null) {
    eq(countFlowMapKey(nestedNode.rawTemplate, 'ws-opts'), 1,
      'dup-nested 的 rawTemplate 里 ws-opts 只出现一次');
    ok(nestedNode.rawTemplate.includes('path: /dup'),
      'dup-nested 的嵌套 map 保留了首次出现的 path',
      `rawTemplate=${nestedNode.rawTemplate}`);
    ok(!nestedNode.rawTemplate.includes('/dup2'),
      'dup-nested 的嵌套 map 里被丢弃的第二个 path 不在了',
      `rawTemplate=${nestedNode.rawTemplate}`);
    eq(countFlowMapKey(nestedNode.rawTemplate, 'path'), 0,
      'dup-nested 顶层没有独立的 path 键（path 只存在于嵌套 map 内）');
  }

  // 诊断通道 = YamlMerger 的静态统计机制（lastDuplicateKeyCount / lastDuplicateKeyReasons）
  eq(YamlMerger.lastDuplicateKeyCount, 2, 'lastDuplicateKeyCount = 2（两个节点受影响）');
  const reasons = (YamlMerger.lastDuplicateKeyReasons || []).join(' | ');
  ok(reasons.includes('dup-cipher') && reasons.includes('cipher'),
    '诊断里记下了节点名 dup-cipher 与被去重的 key cipher', reasons);
  ok(reasons.includes('dup-nested') && reasons.includes('path'),
    '诊断里记下了节点名 dup-nested 与被去重的 key path', reasons);
  ok(/首次出现|保留/.test(reasons),
    '诊断写明了降级策略（按首次出现保留）', reasons);
}

// ── 5. C16：provider 块去重（点号名 / 同名 / 孤儿行）────────────────────────
section('【C16】rule-providers 合并 → 点号名识别 + 同名整块丢弃');
{
  const svc = SubscriptionService.instance();
  svc.subscriptions = [];

  // 5.1 点号 provider 名（**两个订阅里同名** —— 旧实现用 /^[A-Za-z0-9_-]+:$/
  //     认不出点号名 ⇒ 不去重 ⇒ 合并结果里出现两次 ⇒ 顶层重复键 ⇒ 整份拒载）
  const dotted1 = Subscription.newSubscription('sub-dotted-1', '点号名1', 'https://x.example.test/a');
  dotted1.subRuleProviders = [
    '  my.provider:',
    '    type: http',
    '    behavior: classical',
    '    path: ./ruleset/my.provider.mrs',
  ].join('\n');
  const dotted2 = Subscription.newSubscription('sub-dotted-2', '点号名2', 'https://x.example.test/a2');
  dotted2.subRuleProviders = [
    '  my.provider:',
    '    type: http',
    '    interval: 3600',
  ].join('\n');
  svc.subscriptions = [dotted1, dotted2];
  let block = svc.subscriptionRuleProvidersBlock();
  let lines = block.split('\n');
  eq(countIndented(block, 2, 'my.provider:'), 1,
    '点号 provider 名 my.provider: 在合并结果里只出现一次（同名跨订阅也去重）');
  eq(countIndented(block, 2, 'type:'), 0,
    '点号 provider 的字段行没有降级成兄弟键（indent=2 的 type: 不存在）');
  eq(countIndented(block, 4, 'type:'), 1,
    '点号 provider 的字段行仍是 indent=4 的字段行');
  eq(countIndented(block, 4, 'behavior:'), 1, 'behavior 字段仍归属 my.provider');
  eq(countIndented(block, 4, 'path:'), 1, 'path 字段仍归属 my.provider');
  eq(countIndented(block, 4, 'interval:'), 0, '后到的同名点号 provider 整块被丢弃');
  ok(lines.every((l) => l.length === 0 || l.startsWith('  ')),
    '合并结果里没有 indent=0 的裸键行（不会有顶层重复键）', JSON.stringify(lines));
  // 用**真实的**生成器解析 API 回读合并结果：证明键行仍被认成键行、
  // 字段行仍归属它（没有降级成兄弟键 / 没有变成孤儿行）
  {
    const reparsed = ClashConfigGenerator.parseProviderBlocks(block.split('\n'));
    eq(reparsed.orphanLines.length, 0, '回读：没有孤儿字段行');
    eq(reparsed.blocks.length, 1, '回读：只剩 1 个 provider 块');
    if (reparsed.blocks.length === 1) {
      eq(reparsed.blocks[0].name, 'my.provider', '回读：provider 名是 my.provider');
      eq(reparsed.blocks[0].fieldLines.length, 3, '回读：3 个字段行都归属它');
      ok(reparsed.blocks[0].fieldLines.some((f) => f.trim() === 'type: http'),
        '回读：type 字段归属 my.provider', JSON.stringify(reparsed.blocks[0].fieldLines));
    }
  }

  // 5.2 同名 provider（字段键名相同）—— 变体 A
  const sameA = Subscription.newSubscription('sub-same-a', '同名A', 'https://x.example.test/b');
  sameA.subRuleProviders = [
    '  dup:',
    '    type: http',
    '    behavior: classical',
    '  dup:',
    '    type: http',
    '    interval: 3600',
  ].join('\n');
  svc.subscriptions = [sameA];
  block = svc.subscriptionRuleProvidersBlock();
  eq(countIndented(block, 2, 'dup:'), 1, '同名 provider（字段键名相同）只保留一条');
  eq(countIndented(block, 4, 'interval:'), 0,
    '同名 provider 的第二块字段行被整块丢弃（没并进第一条）');
  eq(countIndented(block, 4, 'behavior:'), 1, '第一条 provider 的字段仍在');
  ok(!block.includes('3600'), '第二块的 interval 值没被留下', block);

  // 5.3 同名 provider（字段键名不同）—— 变体 B（更隐蔽：不报错、静默并错 provider）
  const sameB = Subscription.newSubscription('sub-same-b', '同名B', 'https://x.example.test/c');
  sameB.subRuleProviders = [
    '  dup2:',
    '    type: http',
    '    behavior: classical',
    '  dup2:',
    '    url: "https://x.example.test/a.mrs"',
    '    path: ./ruleset/dup2.mrs',
  ].join('\n');
  svc.subscriptions = [sameB];
  block = svc.subscriptionRuleProvidersBlock();
  eq(countIndented(block, 2, 'dup2:'), 1, '同名 provider（字段键名不同）只保留一条');
  eq(countIndented(block, 4, 'url:'), 0, '第二块的 url 字段没有并进第一条 provider');
  eq(countIndented(block, 4, 'path:'), 0, '第二块的 path 字段没有并进第一条 provider');
  ok(!block.includes('a.mrs'), '第二块的内容整体没出现在合并结果里', block);

  // 5.4 跨订阅同名 provider → 也只保留一条（先到先得）
  const cross1 = Subscription.newSubscription('sub-cross-1', '跨订阅1', 'https://x.example.test/d');
  cross1.subRuleProviders = ['  shared:', '    type: http', '    behavior: classical'].join('\n');
  const cross2 = Subscription.newSubscription('sub-cross-2', '跨订阅2', 'https://x.example.test/e');
  cross2.subRuleProviders = ['  shared:', '    type: http', '    interval: 3600'].join('\n');
  svc.subscriptions = [cross1, cross2];
  block = svc.subscriptionRuleProvidersBlock();
  eq(countIndented(block, 2, 'shared:'), 1, '跨订阅的同名 provider 只保留一条');
  eq(countIndented(block, 4, 'interval:'), 0, '跨订阅同名 provider 的后到字段行被丢弃');

  // 5.5 孤儿字段行（任何键行之前）→ 丢弃 + 计数，不塞进任何 provider
  const orphan = Subscription.newSubscription('sub-orphan', '孤儿行', 'https://x.example.test/f');
  orphan.subRuleProviders = [
    '    type: http',
    '    behavior: classical',
    '  good:',
    '    type: http',
  ].join('\n');
  svc.subscriptions = [orphan];
  block = svc.subscriptionRuleProvidersBlock();
  eq(countIndented(block, 2, 'good:'), 1, '孤儿行之后的正常 provider 仍然保留');
  eq(countIndented(block, 4, 'behavior:'), 0,
    '孤儿字段行没有被塞进后面的 provider（更没有塞进上一条）');
  ok(svc.lastProviderOrphanLineCount === 2,
    '孤儿字段行被计数（lastProviderOrphanLineCount = 2）',
    `实际 ${svc.lastProviderOrphanLineCount}`);

  svc.subscriptions = [];
}

// ── 6. 不回归：块式写法的解析结果 ─────────────────────────────────────────
section('不回归：块式写法的节点解析结果（节点数 / type / server / port / password）');
{
  const yaml = [
    'proxies:',
    '  - name: "block-ss"',
    '    type: ss',
    '    server: s3.example.test',
    '    port: 8389',
    '    cipher: aes-256-gcm',
    '    password: "pw-block-style"',
    '  - name: "block-trojan"',
    '    type: trojan',
    '    server: s4.example.test',
    '    port: 443',
    '    password: "pw-block-trojan"',
    '    sni: "s4.example.test"',
    '',
  ].join('\n');
  const nodes = mergeNodes(yaml);
  eq(nodes.length, 2, '块式写法解析出 2 个节点');
  const ss = nodeByName(nodes, 'block-ss');
  ok(ss !== null, '节点 block-ss 存在');
  if (ss !== null) {
    eq(ss.type, 'ss', 'block-ss 的 type');
    eq(ss.server, 's3.example.test', 'block-ss 的 server');
    eq(ss.port, 8389, 'block-ss 的 port');
    eq(ss.password, 'pw-block-style', 'block-ss 的 password');
    eq(ss.cipher, 'aes-256-gcm', 'block-ss 的 cipher');
    eq(ss.rawTemplate, '', '块式写法没有 rawTemplate（回退结构化生成路径）');
  }
  const trojan = nodeByName(nodes, 'block-trojan');
  ok(trojan !== null, '节点 block-trojan 存在');
  if (trojan !== null) {
    eq(trojan.type, 'trojan', 'block-trojan 的 type');
    eq(trojan.server, 's4.example.test', 'block-trojan 的 server');
    eq(trojan.port, 443, 'block-trojan 的 port');
    eq(trojan.password, 'pw-block-trojan', 'block-trojan 的 password');
    eq(trojan.servername, 's4.example.test', 'block-trojan 的 servername');
  }
  eq(YamlMerger.lastDuplicateKeyCount, 0,
    '块式写法不产生重复键诊断（lastDuplicateKeyCount = 0）');
}

// ── 7. 汇总 ────────────────────────────────────────────────────────────────
console.log(`\n${passed} passed, ${failed} failed`);
if (failed === 0) {
  cleanup();
  process.exit(0);
}
console.log(`（失败时保留临时转译环境便于排查：${tmpRoot}）`);
process.exit(1);
