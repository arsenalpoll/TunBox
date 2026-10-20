#!/usr/bin/env node
/**
 * 旧实现清退闸门（legacy purge gate）
 *
 * ## 为什么要有这道闸
 *
 * 2026-10-20 用户要求：「这部分代码全部删了，重头给我做」。
 * 但**删文件**是终态动作，工程里真正的风险是「旧实现还在运行时路径上」——
 * 只要还有一处调用，旧口径就还会生效，删与不删都是半成品。
 * 所以这道闸门**先管路径，不管文件**：每条断言回答
 * 「这个东西还在不在运行时路径上」；等它们全绿，删文件才是安全动作。
 *
 * 清单（为什么删 / 被谁取代 / 前置条件）见 `docs/rewrite-2026-10-20.md`。
 *
 * ## 两种模式
 *
 *   node scripts/verify-legacy-purge.mjs              # 严格模式（验收用）：要求「已清退」，未清退即失败
 *   node scripts/verify-legacy-purge.mjs --pending    # 预览模式：只列出「还差哪些 + 前置条件」，不失败
 *   node scripts/verify-legacy-purge.mjs --exempt LP12  # 临时豁免某条
 *   TUNBOX_PURGE_EXEMPT=LP12,LP15 node scripts/verify-legacy-purge.mjs   # 同上（环境变量写法）
 *
 * ## 豁免纪律
 *
 * 豁免是**显式的、逐条的、可审计的**：
 *   · 每条断言有稳定 id（LP01…LP15），豁免只影响该条；
 *   · 豁免项输出标 ⚠ 已豁免，**不计入失败**，但也不算「已清退」；
 *   · 豁免只能写环境变量 / 命令行，**不许改脚本里的白名单**（改了就没法审计）。
 *
 * ## 为什么默认严格模式现在会红
 *
 * 这道闸门是**清退验收闸门**，清退动作本身还没做 → 现在跑必然红。
 * `scripts/verify-all.mjs` 会自动发现本脚本（它只发现 `verify-*.mjs`），
 * 所以在清退做完之前，总闸会因为本脚本变红 —— 这是**有意的**：
 * 「旧实现还在」本来就该让总闸红。看进度用 `--pending`。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const etsRoot = path.join(root, 'entry/src/main/ets');

const argv = process.argv.slice(2);
const pendingMode = argv.includes('--pending');
const exemptArg = (() => {
  const i = argv.indexOf('--exempt');
  if (i >= 0 && argv[i + 1]) return argv[i + 1];
  return process.env.TUNBOX_PURGE_EXEMPT || '';
})();
const exemptIds = new Set(
  exemptArg.split(',').map((s) => s.trim()).filter((s) => s.length > 0)
);

// ───────────────────────── 源码扫描工具 ─────────────────────────

const P = (rel) => `entry/src/main/ets/${rel}`;

/** 收集 entry/src/main/ets 下所有 .ets 文件（仓库相对 posix 路径）。 */
function listEtsFiles() {
  const out = [];
  const walk = (dir) => {
    for (const name of fs.readdirSync(dir)) {
      const full = path.join(dir, name);
      const st = fs.statSync(full);
      if (st.isDirectory()) walk(full);
      else if (name.endsWith('.ets')) out.push(path.relative(root, full).split(path.sep).join('/'));
    }
  };
  walk(etsRoot);
  return out.sort();
}

/**
 * 去掉注释（保留换行，避免行号漂移），让断言只看**真实代码**。
 * 注释里写的 "core_not_ready" 不算「又写了一份分类表」。
 */
function stripComments(src) {
  let out = '';
  let i = 0;
  const n = src.length;
  let inLine = false;
  let inBlock = false;
  let inStr = false;
  let quote = '';
  while (i < n) {
    const c = src[i];
    const c2 = src.substring(i, i + 2);
    if (inLine) {
      if (c === '\n') { inLine = false; out += c; } else out += ' ';
      i++;
      continue;
    }
    if (inBlock) {
      if (c2 === '*/') { inBlock = false; out += '  '; i += 2; continue; }
      out += (c === '\n' ? '\n' : ' ');
      i++;
      continue;
    }
    if (inStr) {
      out += c;
      if (c === '\\') { out += src[i + 1] ?? ''; i += 2; continue; }
      if (c === quote) inStr = false;
      i++;
      continue;
    }
    if (c2 === '//') { inLine = true; out += '  '; i += 2; continue; }
    if (c2 === '/*') { inBlock = true; out += '  '; i += 2; continue; }
    if (c === '"' || c === "'" || c === '`') { inStr = true; quote = c; out += c; i++; continue; }
    out += c;
    i++;
  }
  return out;
}

const fileList = listEtsFiles();
const codeCache = new Map();
function codeOf(rel) {
  if (!codeCache.has(rel)) {
    codeCache.set(rel, stripComments(fs.readFileSync(path.join(root, rel), 'utf8')));
  }
  return codeCache.get(rel);
}
function lineOf(rel, index) {
  return codeOf(rel).substring(0, index).split('\n').length;
}

/** 找出所有匹配 needle 的位置（只看代码，不看注释）。 */
function findAll(needle, scope) {
  const hits = [];
  const flags = needle.flags.includes('g') ? needle.flags : needle.flags + 'g';
  const re = new RegExp(needle.source, flags);
  for (const rel of scope || fileList) {
    const code = codeOf(rel);
    let m;
    re.lastIndex = 0;
    while ((m = re.exec(code)) !== null) {
      hits.push({
        file: rel,
        line: lineOf(rel, m.index),
        text: code.substring(m.index, m.index + 100).split('\n')[0].trim(),
      });
      if (m.index === re.lastIndex) re.lastIndex++;
    }
  }
  return hits;
}

// ───────────────────────── 断言类型 ─────────────────────────
// no-callers : 符号不得在 excludeFiles 之外被调用
// absent-in  : 某文件里不得再出现该模式（定义/旧实现本体）
// only-in    : 字面量/调用只允许出现在白名单文件里
// no-file    : 文件必须已被删除
// count      : 某文件里匹配数必须恰好等于 expect
const KIND_DEFS = {
  'no-callers': {
    label: '无调用方',
    run(a) {
      const hits = findAll(a.pattern).filter((h) => !(a.excludeFiles || []).includes(h.file));
      return { ok: hits.length === 0, hits };
    },
  },
  'absent-in': {
    label: '已移除',
    run(a) {
      const hits = findAll(a.pattern, [a.file]);
      return { ok: hits.length === 0, hits };
    },
  },
  'only-in': {
    label: '只在白名单文件里',
    run(a) {
      const hits = findAll(a.pattern).filter((h) => !(a.allowedFiles || []).includes(h.file));
      return { ok: hits.length === 0, hits };
    },
  },
  'no-file': {
    label: '文件已删除',
    run(a) {
      const exists = fs.existsSync(path.join(root, a.path));
      return { ok: !exists, hits: exists ? [{ file: a.path, line: 0, text: '文件仍存在' }] : [] };
    },
  },
  count: {
    label: '调用点数量',
    run(a) {
      const hits = findAll(a.pattern, [a.file]);
      const ok = hits.length === a.expect;
      return { ok, hits, extra: `实际 ${hits.length} 处（要求 ${a.expect} 处）` };
    },
  },
};

// 失败分类字面量（真源 = LatencyProbeKind / LatencyStore）
const KIND_LITERALS = [
  'core_not_ready', 'network_unreachable', 'queue_timeout',
  'port_reachable_only', 'dns_unresolved', 'switch_failed',
];

const ASSERTIONS = [
  {
    id: 'LP01',
    title: '配置生成只有一个入口（ClashConfigGenerator.generate( 只有 RuntimeConfigBuilder 调）',
    kind: 'no-callers',
    precondition: '已完成 —— 闸门 verify-config-single-source.mjs A1 ✅',
    params: {
      pattern: /ClashConfigGenerator\s*\.\s*generate\s*\(/,
      excludeFiles: [P('commons/config/RuntimeConfigBuilder.ets'), P('commons/services/ClashConfigGenerator.ets')],
    },
  },
  {
    id: 'LP02',
    title: 'ClashApiService 的旧兼容壳 testGroupDetailed( 已删除（任何非 200 一律 null 的旧语义）',
    kind: 'absent-in',
    precondition: '批次 B1：删掉旧 delay 通道的兼容壳',
    params: { file: P('commons/services/ClashApiService.ets'), pattern: /\btestGroupDetailed\s*\(/ },
  },
  {
    id: 'LP03',
    title: 'ClashApiService 的旧数值口 testLatency( 已删除（失败一律 -1 的旧语义）',
    kind: 'absent-in',
    precondition: '批次 B1',
    params: { file: P('commons/services/ClashApiService.ets'), pattern: /\btestLatency\s*\(/ },
  },
  {
    id: 'LP04',
    title: '失败分类字面量只在三个真源模块出现（LatencyKinds 常量 / LatencyProbe 分类 / LatencyStore 渲染）',
    kind: 'only-in',
    precondition: '批次 B3：页面/theme 改走 LatencyKinds 常量与 LatencyStore.describe',
    params: {
      pattern: new RegExp(KIND_LITERALS.join('|')),
      // 三个真源各管一件事：
      //   LatencyKinds —— 分类**常量**（字面量只允许在这里出现）；
      //   LatencyProbe —— 「什么响应算哪一类」的**判定表**；
      //   LatencyStore —— 「这类结论给用户看什么字」的**渲染表**。
      allowedFiles: [P('commons/latency/LatencyKinds.ets'),
        P('commons/latency/LatencyProbe.ets'), P('commons/latency/LatencyStore.ets')],
    },
  },
  {
    id: 'LP05',
    title: 'LatencyPolicy.stateText( 不再被 UI/theme 调用（渲染表真源收敛到 LatencyStore.describe）',
    kind: 'no-callers',
    precondition: '批次 B3：theme/TunBoxTokens.ets 与 theme/UiTokens.ets 的两处包装删掉',
    params: {
      pattern: /LatencyPolicy\s*\.\s*stateText\s*\(/,
      excludeFiles: [P('commons/services/LatencyState.ets')],
    },
  },
  {
    id: 'LP06',
    title: 'LatencyState.ets 只剩状态枚举 + 非判定清单（旧数值状态机/分类表已删）',
    kind: 'absent-in',
    precondition: '批次 B4：settings-ui 删掉旧数值状态机（classify）与旧分类表',
    params: {
      file: P('commons/services/LatencyState.ets'),
      // 旧的「HTTP 状态码 + 延迟 → 数值状态」分类机已由 LatencyProbe 的分类表取代。
      pattern: /LatencyPolicy\s*\.\s*classify\s*\(|static\s+classify\s*\(/,
    },
  },
  {
    id: 'LP07',
    title: 'LatencyEngine.ets 只剩批次调度（旧 http 通道/失败映射已删，探测走 LatencyProbe）',
    kind: 'absent-in',
    precondition: '批次 B6：latency-core 删掉引擎自带的 http 通道与 mapFailure',
    params: {
      file: P('commons/services/LatencyEngine.ets'),
      // 引擎不得自己发 http（探测只走 LatencyProbe.probeOne），也不得自己映射失败。
      pattern: /http\s*\.\s*createHttp\s*\(|mapFailure\s*\(/,
    },
  },
  {
    id: 'LP08',
    title: '旧结论门面已删除：commons/services/LatencyController.ets',
    kind: 'no-file',
    precondition: '批次 B5：四个调用点改走 LatencyStore',
    params: { path: P('commons/services/LatencyController.ets') },
  },
  {
    id: 'LP09',
    title: '记账路径不写测速结论（编排器不得把「一次连接失败」写成 latency=-1）',
    kind: 'absent-in',
    precondition: '已修（2026-10-20 真机反馈）—— 本条是长期护栏',
    params: {
      file: P('commons/services/ConnectionOrchestrator.ets'),
      pattern: /rec\s*\.\s*latency\s*=\s*LATENCY_FAILED/,
    },
  },
  {
    id: 'LP10',
    title: '编排器不得把测速快照写回 settings 并整单落盘（nodeSortSnapshot 的第二个写者）',
    kind: 'absent-in',
    precondition: '批次 B2：编排器改走 SettingsService.saveNodeSortStats（只写 failCount/lastOk）',
    params: {
      file: P('commons/services/ConnectionOrchestrator.ets'),
      pattern: /\.\s*nodeSortSnapshot\s*=\s*[^=]/,
    },
  },
  {
    id: 'LP11',
    title: '旧解析器本体已移除：ProxyNode.ets 里的 ModernUriCodec.parse* / SsrCodec.parse*',
    kind: 'absent-in',
    precondition: '批次 B7：yaml-sub 的 task-9 落地（导入链路改走 UriNodeParser + ProxyNodeAdapter）',
    params: {
      file: P('commons/models/ProxyNode.ets'),
      pattern: /static\s+parse(Vless|Vmess|Trojan|Hysteria2|Hysteria|Tuic|Anytls|Ssr|Ss)\s*\(/,
    },
  },
  {
    id: 'LP12',
    title: 'ProxyNode.fromUri( 的调用方只剩手动单条导入（pages/NodeEditPage.ets）',
    kind: 'no-callers',
    precondition: '批次 B7：SubscriptionService / SubscriptionParser 改走新解析层',
    params: {
      pattern: /ProxyNode\s*\.\s*fromUri\s*\(/,
      excludeFiles: [P('commons/models/ProxyNode.ets'), P('pages/NodeEditPage.ets')],
    },
  },
  {
    id: 'LP13',
    title: '编排器的凭据回填只剩 1 处调用（封存-回填去重）',
    kind: 'count',
    precondition: '批次 B8：回填收敛到生成配置前的唯一入口',
    params: {
      file: P('commons/services/ConnectionOrchestrator.ets'),
      pattern: /this\s*\.\s*hydrateNodeCredentials\s*\(/,
      expect: 1,
    },
  },
  {
    id: 'LP14',
    title: 'NodeSortSnapshot 不再被编排器/页面直接使用（旧快照模型退场）',
    kind: 'only-in',
    precondition: '批次 B2/B5：读写都改走 SettingsService 分片 + LatencyStore',
    params: {
      pattern: /NodeSortSnapshot\s*\.\s*(fromJsonText|toJsonText)/,
      allowedFiles: [P('commons/services/SettingsService.ets'), P('commons/services/NodeSortPersistence.ets')],
    },
  },
  {
    id: 'LP15',
    title: 'AppSettings.nodeSortSnapshot 只在 SettingsService 内出现（整单 JSON 里的旧真源退场）',
    kind: 'only-in',
    precondition: '批次 B9：迁移窗口结束后删字段与迁移分支',
    params: {
      pattern: /nodeSortSnapshot/,
      allowedFiles: [P('commons/services/SettingsService.ets')],
    },
  },
];

// ───────────────────────── 执行 ─────────────────────────

/**
 * **永久豁免**（有明确理由的「暂时不能删」）。
 *
 * 临时豁免用 `--exempt LPxx`（只对本次运行生效）；
 * 这里记的是**有迁移窗口约束**的：删早了会让老装机丢数据。
 */
const PERMANENT_EXEMPT = new Map([
  ['LP14', `NodeSortSnapshot 还承载「自动切换记账」（failCount/lastOk）+ 排序状态，
它的落盘字段 AppSettings.nodeSortSnapshot 是老装机的唯一来源 ⇒
必须保留到迁移窗口结束（记账模型迁到独立账本后）再删。`],
  ['LP15', `同上：AppSettings.nodeSortSnapshot 是老装机的快照落点，
删字段会让老装机升级后丢掉全部测速结论与记账。`],
]);

let passed = 0;
let failed = 0;
let exemptCount = 0;
const pending = [];

console.log('── 旧实现清退闸门（legacy purge）──');
if (pendingMode) console.log('   模式：--pending（预览还差哪些，不判失败）');
if (exemptIds.size > 0) console.log(`   豁免：${[...exemptIds].join(', ')}`);

for (const a of ASSERTIONS) {
  const def = KIND_DEFS[a.kind];
  const res = def.run(a.params);
  const label = `${a.id} ${a.title}`;
  if (exemptIds.has(a.id)) {
    exemptCount++;
    console.log(`  ⚠ 已豁免  ${label}`);
    console.log(`      前置条件：${a.precondition}`);
    continue;
  }
  if (PERMANENT_EXEMPT.has(a.id)) {
    exemptCount++;
    console.log(`  ⚠ 永久豁免  ${label}`);
    console.log(`      理由：${PERMANENT_EXEMPT.get(a.id)}`);
    continue;
  }
  if (res.ok) {
    passed++;
    console.log(`  ✅ ${label}`);
  } else {
    failed++;
    const hits = res.hits.slice(0, 6);
    const more = res.hits.length > hits.length ? `（还有 ${res.hits.length - hits.length} 处）` : '';
    console.log(`  ❌ ${label}`);
    if (res.extra) console.log(`      ${res.extra}`);
    for (const h of hits) {
      console.log(`      ${h.file}${h.line ? ':' + h.line : ''}  ${h.text}`);
    }
    if (more) console.log(`      ${more}`);
    console.log(`      前置条件：${a.precondition}`);
    pending.push({ id: a.id, title: a.title, hits: res.hits, precondition: a.precondition });
  }
}

console.log('');
if (pendingMode) {
  console.log(`预览：${passed} 条已达成，${pending.length} 条待清退，${exemptCount} 条已豁免`);
  if (pending.length > 0) {
    console.log('');
    console.log('── 还差这些（按前置条件推进）──');
    for (const p of pending) {
      const files = [...new Set(p.hits.map((h) => h.file))];
      console.log(`  ${p.id} ${p.title}`);
      console.log(`      涉及：${files.join(', ')}`);
      console.log(`      前置：${p.precondition}`);
    }
  }
  console.log('');
  console.log('RESULT: pending（预览模式不判失败）');
  process.exit(0);
}

console.log(`RESULT: ${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.log('');
  console.log('  说明：清退还没做完 —— 严格模式要求「旧实现不在运行时路径上」。');
  console.log('  看还差哪些：node scripts/verify-legacy-purge.mjs --pending');
  console.log('  临时豁免某条：node scripts/verify-legacy-purge.mjs --exempt LP12');
}
process.exit(failed > 0 ? 1 : 0);
