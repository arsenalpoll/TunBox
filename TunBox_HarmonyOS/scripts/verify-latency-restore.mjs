#!/usr/bin/env node
/**
 * 冷启动「假超时」回归闸门（2026-10-20 真机用户反馈）。
 *
 * 现象：用户「刚打开软件还没测速，就显示超时；测完发现这个节点还是正常的，并没有超时」。
 *
 * 根因（两条，互相叠加）：
 *  1. **写入侧污染**：`ConnectionOrchestrator.updateNodeStats` 在「一次连接失败」
 *     （自动切换记账）时把 `rec.latency = LATENCY_FAILED(-1)` 写进**持久化测速快照**。
 *     「连接失败记账」与「测速结论」被塞进同一个字段 → 节点真实的测速延迟被抹掉。
 *  2. **读取侧伪装**：`HomePage` / `NodeSelectionPage` 用 `LatencyController.set(name, latency)`
 *     恢复快照，只收一个数字：
 *       · 失败分类（failKind）被丢掉 → 非判定失败（通道故障/没排上队/旧记账）
 *         全被压成同一种红色「超时」；
 *       · 时间戳用 `Date.now()` → **上一轮的旧结论被伪装成本次刚测出来的**。
 *
 * 修复后的口径（本闸门逐条锁死）：
 *  · 非判定失败（含空分类 = 旧版自动切换记账）→ 恢复成「未测」，显示 `--`；
 *  · 真实失败结论 → 保留分类与**真实**时间戳；过期后显示「超时·旧」并灰显；
 *  · 实测值 → 用快照的真实测速时间戳（超过 10 分钟自然显示「123ms·旧」）；
 *  · 自动切换记账**不再**覆写测速结论（评分口径由 candidateFromRecord 派生，保持不变）。
 *
 * 用法: node scripts/verify-latency-restore.mjs
 */
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

const appRoot = resolve(import.meta.dirname, '..');
const ets = join(appRoot, 'entry', 'src', 'main', 'ets');
const sandbox = join(tmpdir(), 'tunbox-latency-restore-' + process.pid);
rmSync(sandbox, { recursive: true, force: true });
mkdirSync(join(sandbox, 'commons', 'services'), { recursive: true });
mkdirSync(join(sandbox, 'theme'), { recursive: true });
writeFileSync(join(sandbox, 'package.json'), JSON.stringify({ type: 'module' }), 'utf8');

/** 暂存一个 .ets 为 .ts，并把无扩展名的相对 import 补成 .ts（Node ESM 要求显式扩展名） */
function stage(relPath, outRel) {
  const src = readFileSync(join(ets, relPath + '.ets'), 'utf8')
    .replace(/from '(\.\.?\/[A-Za-z0-9_\/]+)'/g, "from '$1.ts'");
  const out = join(sandbox, outRel + '.ts');
  writeFileSync(out, src, 'utf8');
}

stage('commons/services/LatencyState', 'commons/services/LatencyState');
stage('commons/services/LatencyController', 'commons/services/LatencyController');
stage('theme/UiTokens', 'theme/UiTokens');

const checks = [];
function check(label, ok, extra) {
  checks.push([label, !!ok, extra]);
}

/** 去掉注释（行注释 + 块注释），避免「解释性注释里写了旧代码」把断言骗过 */
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/[^\n]*/g, '$1');
}

const NOW = Date.now();
const OLD = NOW - 60 * 60 * 1000;   // 1 小时前
const RECENT = NOW - 30 * 1000;     // 30 秒前

// ArkUI 全局资源函数 $r 在 Node 下不存在 → 打成占位串（UiTokens 用它取主题色）
globalThis.$r = (name) => name;

try {
  const { LatencyController } =
    await import(pathToFileURL(join(sandbox, 'commons/services/LatencyController.ts')).href);
  const { LatencyState, LatencyPolicy, LatencyRecord, LatencyChannel } =
    await import(pathToFileURL(join(sandbox, 'commons/services/LatencyState.ts')).href);
  const { LatencyStyle } =
    await import(pathToFileURL(join(sandbox, 'theme/UiTokens.ts')).href);

  // ── 1. 非判定失败不得恢复成「超时」 ────────────────────────────────
  LatencyController.clearAll();
  LatencyController.restore('legacy-bookkeeping', -1, '', OLD);
  check('空分类（旧版自动切换记账）→ 未测，不是超时',
    LatencyController.stateFor('legacy-bookkeeping') === LatencyState.UNTESTED);
  check('空分类恢复后 latencyFor 为 null（UI 显示 --）',
    LatencyController.latencyFor('legacy-bookkeeping') === null);

  LatencyController.restore('core-not-ready', -1, 'core_not_ready', OLD);
  check('core_not_ready（通道故障）→ 未测',
    LatencyController.stateFor('core-not-ready') === LatencyState.UNTESTED);

  LatencyController.restore('queue-timeout', -1, 'queue_timeout', OLD);
  check('queue_timeout（根本没拨号）→ 未测',
    LatencyController.stateFor('queue-timeout') === LatencyState.UNTESTED);

  LatencyController.restore('port-only', -1, 'port_reachable_only', OLD);
  check('port_reachable_only → 未测',
    LatencyController.stateFor('port-only') === LatencyState.UNTESTED);

  // ── 2. 真实失败结论：保留分类与真实时间戳 ─────────────────────────
  LatencyController.restore('real-timeout', -1, 'timeout', OLD);
  check('真实超时恢复为 TIMEOUT',
    LatencyController.stateFor('real-timeout') === LatencyState.TIMEOUT);
  const rt = LatencyController.recordFor('real-timeout');
  check('真实超时保留 failKind', rt !== null && rt.failKind === 'timeout');
  check('真实超时保留**快照时间戳**（不得改写成 Date.now()）',
    rt !== null && rt.atMs === OLD, `atMs=${rt === null ? 'null' : rt.atMs}`);
  check('真实超时文案是「超时」（不塌成未测）',
    LatencyPolicy.stateText(rt.state, rt.failKind) === '超时');

  LatencyController.restore('not-effective', -1, 'switch_failed', OLD);
  const ne = LatencyController.recordFor('not-effective');
  check('switch_failed 保留分类（显示「未生效」而不是「超时」）',
    ne !== null && ne.failKind === 'switch_failed'
    && LatencyPolicy.stateText(ne.state, ne.failKind) === '未生效');

  // ── 3. 实测值：用快照的真实测速时间 ────────────────────────────────
  LatencyController.restore('measured', 123, '', OLD);
  const m = LatencyController.recordFor('measured');
  check('实测值恢复为 MEASURED', m !== null && m.state === LatencyState.MEASURED);
  check('实测值保留快照时间戳', m !== null && m.atMs === OLD);
  check('实测值 latencyFor 正确', LatencyController.latencyFor('measured') === 123);

  LatencyController.restore('untested', -2, '', OLD);
  check('latency=-2 → 未测',
    LatencyController.stateFor('untested') === LatencyState.UNTESTED);

  // ── 4. 陈旧结论判定 ────────────────────────────────────────────────
  const oldFail = LatencyRecord.failed('x', LatencyState.TIMEOUT, OLD, LatencyChannel.CORE, 'timeout');
  const freshFail = LatencyRecord.failed('y', LatencyState.TIMEOUT, RECENT, LatencyChannel.CORE, 'timeout');
  const noTimeFail = LatencyRecord.failed('z', LatencyState.TIMEOUT, 0, LatencyChannel.CORE, 'timeout');
  check('一小时前的失败判为陈旧', LatencyPolicy.isStaleConclusion(oldFail, NOW) === true);
  check('30 秒前的失败不算陈旧', LatencyPolicy.isStaleConclusion(freshFail, NOW) === false);
  check('无时间戳的失败按陈旧处理（年龄未知不得顶红字）',
    LatencyPolicy.isStaleConclusion(noTimeFail, NOW) === true);
  check('实测值不适用「结论陈旧」判定',
    LatencyPolicy.isStaleConclusion(LatencyRecord.measured('m', 10, LatencyChannel.CORE, OLD), NOW) === false);

  // ── 5. 渲染层：旧失败显示「超时·旧」，不再是一颗新鲜的红「超时」 ──
  check('陈旧失败文案是「超时·旧」',
    LatencyStyle.recordText(oldFail, NOW) === '超时·旧');
  check('新鲜失败文案仍是「超时」',
    LatencyStyle.recordText(freshFail, NOW) === '超时');
  check('陈旧失败配色为中性（不是红色）',
    LatencyStyle.recordColor(oldFail, NOW) === LatencyStyle.recordColor(
      LatencyRecord.untested('q'), NOW));
  check('新鲜失败仍为红色',
    LatencyStyle.recordColor(freshFail, NOW) !== LatencyStyle.recordColor(
      LatencyRecord.untested('q'), NOW));
  check('陈旧实测值显示「123ms·旧」',
    LatencyStyle.recordText(LatencyRecord.measured('m', 123, LatencyChannel.CORE, OLD), NOW) === '123ms·旧');

  // ── 6. 非判定判定表唯一真源 ────────────────────────────────────────
  check('isNonVerdictKind：通道故障类为非判定',
    LatencyPolicy.isNonVerdictKind('core_not_ready') === true
    && LatencyPolicy.isNonVerdictKind('queue_timeout') === true
    && LatencyPolicy.isNonVerdictKind('untested') === true
    && LatencyPolicy.isNonVerdictKind('unsupported') === true
    && LatencyPolicy.isNonVerdictKind('port_reachable_only') === true);
  check('isNonVerdictKind：真实失败不是非判定',
    LatencyPolicy.isNonVerdictKind('timeout') === false
    && LatencyPolicy.isNonVerdictKind('switch_failed') === false
    && LatencyPolicy.isNonVerdictKind('network_unreachable') === false
    // 空分类在**写快照**口径下是「一次没有分类的真实失败」= 节点结论（要写进快照），
    // 不属于这张表；只有恢复路径把它当非结论（旧版自动切换记账的残留）。
    && LatencyPolicy.isNonVerdictKind('') === false);
  check('恢复路径仍把空分类当非结论（旧版自动切换记账残留）',
    (() => {
      LatencyController.clearAll();
      LatencyController.restore('legacy-empty-kind', -1, '', OLD);
      return LatencyController.stateFor('legacy-empty-kind') === LatencyState.UNTESTED;
    })());
} catch (e) {
  check('运行时加载（type-stripping）失败', false, String(e));
}

// ── 7. 源码断言：写入侧不再污染测速结论 ──────────────────────────────
const orchSrc = readFileSync(join(ets, 'commons/services/ConnectionOrchestrator.ets'), 'utf8');
const orchCode = stripComments(orchSrc);
const updateBody = orchCode.slice(orchCode.indexOf('private async updateNodeStats'),
  orchCode.indexOf('private candidateFromRecord'));
check('updateNodeStats 不再把连接失败写成测速失败（rec.latency = LATENCY_FAILED）',
  !/rec\.latency\s*=\s*LATENCY_FAILED/.test(updateBody));
check('updateNodeStats 仍累加失败计数与 lastOk',
  /rec\.failCount\s*=\s*rec\.failCount\s*\+\s*1/.test(updateBody)
  && /rec\.lastOk\s*=\s*false/.test(updateBody));
check('updateNodeStats 成功时清理旧版记账残留（仅无分类的 -1）',
  /rec\.latency\s*<\s*0\s*&&\s*rec\.failKind\.length\s*===\s*0/.test(updateBody));

const candBody = orchCode.slice(orchCode.indexOf('private candidateFromRecord'),
  orchCode.indexOf('private buildCandidates'));
check('选点评分仍按失败记账降权（effective = LATENCY_FAILED）',
  /effective\s*=\s*LATENCY_FAILED/.test(candBody));
check('选点评分不再直接读被污染的 rec.latency',
  /NodeCandidate\.fromStats\(name,\s*effective/.test(candBody));

// ── 8. 源码断言：读取侧恢复必须带分类与真实时间戳 ────────────────────
for (const [file, label] of [
  ['pages/HomePage.ets', 'HomePage'],
  ['pages/NodeSelectionPage.ets', 'NodeSelectionPage'],
]) {
  const src = stripComments(readFileSync(join(ets, file), 'utf8'));
  check(`${label} 用 LatencyController.restore 恢复快照（不再用 set 丢分类）`,
    /LatencyController\.restore\(rec\.name,\s*rec\.latency,\s*rec\.failKind,\s*[A-Za-z]+\.testedAt\)/.test(src));
  check(`${label} 恢复路径不再调用 LatencyController.set(rec.name, rec.latency)`,
    !/LatencyController\.set\(rec\.name,\s*rec\.latency\)/.test(src));
}

const persistSrc = stripComments(
  readFileSync(join(ets, 'commons/services/NodeSortPersistence.ets'), 'utf8'));
check('快照缺 latency 字段时按「未测」处理（不是失败）',
  /Number\.isFinite\(r\.latency\)\s*\?\s*r\.latency\s*:\s*-2/.test(persistSrc));
check('非判定判定表收敛到 LatencyPolicy.isNonVerdictKind（唯一真源）',
  /return\s+LatencyPolicy\.isNonVerdictKind\(failKind\)/.test(persistSrc));

const tokensSrc = stripComments(readFileSync(join(ets, 'theme/TunBoxTokens.ets'), 'utf8'));
check('TunBoxPing.recordText 对陈旧失败标「·旧」',
  /isStaleConclusion\(rec,\s*nowMs\)/.test(tokensSrc));
const uiTokensSrc = stripComments(readFileSync(join(ets, 'theme/UiTokens.ets'), 'utf8'));
check('LatencyStyle.recordText 对陈旧失败标「·旧」',
  /isStaleConclusion\(rec,\s*nowMs\)/.test(uiTokensSrc));

// ── 输出 ──────────────────────────────────────────────────────────────
let pass = 0;
const fails = [];
for (const [label, ok, extra] of checks) {
  if (ok) { pass += 1; console.log(`  ✓ ${label}`); }
  else { fails.push(label + (extra ? ` (${extra})` : '')); console.log(`  ✗ ${label}${extra ? ' — ' + extra : ''}`); }
}
rmSync(sandbox, { recursive: true, force: true });
console.log(`\n冷启动「假超时」回归闸门：${pass} 条通过，${fails.length} 条失败`);
if (fails.length > 0) {
  console.error('失败：' + fails.join(' | '));
  process.exit(1);
}
console.log('全部通过（陈旧结论不再被渲染成新鲜的红「超时」）');
process.exit(0);
