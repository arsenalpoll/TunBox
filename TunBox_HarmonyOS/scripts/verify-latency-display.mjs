/**
 * 延迟显示契约自检（2026-10-18 用户裁定）。
 *
 * 契约：节点行只允许出现「实测延迟（含离线 ≈ms）」或「超时/失败」，
 * **不允许**把已经测出的失败按来源改写成中性「未测」。
 *
 * 背景：`TunBoxPing.recordText` / `LatencyStyle.recordText` 曾对
 * `source === 'auto'`（冷启动、进入节点页、导入订阅后的静默批）的失败返回
 * 「未测」。真机表现为「导入订阅后一大片未测」，用户明确指出这会误导
 * （以为根本没测速），要求「要么显示延迟多少、要么显示超时」。
 *
 * 本脚本读源码做结构断言，防止这条契约被无意改回去。
 * 用法: node scripts/verify-latency-display.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');

let pass = 0;
const fails = [];
function ok(name, cond, extra) {
  if (cond) { pass += 1; console.log(`  ✓ ${name}`); }
  else { fails.push(name + (extra ? ` (${extra})` : '')); console.log(`  ✗ ${name}${extra ? ` — ${extra}` : ''}`); }
}

/** 取出「静态方法名(」到其方法体结束的粗略区段（用于逐渲染器断言） */
function methodBody(src, signature) {
  const i = src.indexOf(signature);
  if (i < 0) return '';
  // 向后找到下一个同级方法声明作为终点，避免跨方法误判
  const rest = src.slice(i + signature.length);
  const next = rest.search(/\r?\n  static [A-Za-z]/);
  return next < 0 ? rest : rest.slice(0, next);
}

const targets = [
  { file: 'entry/src/main/ets/theme/TunBoxTokens.ets', ns: 'TunBoxPing' },
  { file: 'entry/src/main/ets/theme/UiTokens.ets', ns: 'LatencyStyle' },
];

console.log('\n延迟显示契约自检（失败一律显示超时/失败，不得按来源改写为未测）');

for (const t of targets) {
  const full = path.join(root, t.file);
  const src = fs.readFileSync(full, 'utf8');
  const text = methodBody(src, 'static recordText(rec: LatencyRecord | null, nowMs: number): string {');
  const color = methodBody(src, 'static recordColor(rec: LatencyRecord | null, nowMs: number): ResourceColor {');

  ok(`${t.ns}.recordText 存在`, text.length > 0);
  ok(`${t.ns}.recordColor 存在`, color.length > 0);

  // 核心契约：不得再有 "source === 'auto'" 的失败特判
  ok(`${t.ns}.recordText 不再按 source==='auto' 改写成未测`,
    !/source\s*===\s*'auto'/.test(text), 'auto-source failure special-case came back');
  ok(`${t.ns}.recordText 不再返回「未测」字面量`,
    !/return\s*'未测'/.test(text));
  ok(`${t.ns}.recordColor 不再按 source==='auto' 走中性色`,
    !/source\s*===\s*'auto'/.test(color));

  // 必须仍然把失败落到 stateText（超时/失败），并且**必须带上 failKind**：
  // 2026-10-19 起 state 只有「失败」一档，分不出「内核里没这个节点」(switch_failed)
  // 与「真超时」(timeout)。不带 failKind 就会退回"404 和 504 在 UI 上完全一样"。
  ok(`${t.ns}.recordText 失败走 LatencyPolicy.stateText`,
    /LatencyPolicy\.stateText\(rec\.state,\s*rec\.failKind\)/.test(text));
  // 必须仍然保留离线 ≈ 前缀与"没数据 = --"语义
  ok(`${t.ns}.recordText 保留离线 ≈ 前缀`,
    /`≈\$\{body\}`/.test(text) || /≈/.test(text));
  ok(`${t.ns}.recordText 无记录时仍为 --`, /return\s*'--'/.test(text));
  // 失败配色必须是红色系（不再是中性）
  ok(`${t.ns}.recordColor 失败走红色`,
    /LatencyState\.TIMEOUT\s*\|\|\s*rec\.state\s*===\s*LatencyState\.FAILED/.test(color));
  // 「节点未生效」（内核里没它）必须走警告色，不能和"节点坏了"一样红
  ok(`${t.ns}.recordColor 对未生效用警告色`,
    /isNotEffective\(rec\.failKind\)[\s\S]{0,120}?warning/.test(color));
}

// 反例守护：确保 stateText 真的把 TIMEOUT 映射成「超时」
const stateSrc = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/commons/services/LatencyState.ets'), 'utf8');
ok('LatencyPolicy.stateText 中 TIMEOUT 映射为「超时」',
  /TIMEOUT[\s\S]{0,120}?超时/.test(stateSrc));

// ── 失败分类必须一路带到 UI（2026-10-19 新增契约）────────────────────
// 反例守护：分类若在运行时被丢掉，switch_failed（节点没进内核配置）与 timeout
// （真超时）会再次在用户侧完全一样 —— 真机教训：36 个 anytls 被丢弃 → 内核 404
// → UI 全红，用户以为节点坏了（实际节点可用、代理正常）。
ok('LatencyRecord 带 failKind 字段',
  /class LatencyRecord[\s\S]{0,2000}?failKind\s*:\s*string\s*=\s*''/.test(stateSrc));
ok('LatencyPolicy.stateText 接受 failKind 参数',
  /static stateText\(state:\s*number,\s*failKind:\s*string\s*=\s*''\)/.test(stateSrc));
ok('LatencyPolicy.stateText 对 switch_failed 显示「未生效」',
  /isNotEffective\(failKind\)[\s\S]{0,200}?'未生效'/.test(stateSrc));
ok('LatencyPolicy.isNotEffective 判定 switch_failed',
  /isNotEffective[\s\S]{0,200}?'switch_failed'/.test(stateSrc));

const engineSrc = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/commons/services/LatencyEngine.ets'), 'utf8');
ok('LatencyEngine 把 probe.failKind 写进记录',
  /LatencyRecord\.failed\([^;]*probe\.failKind/.test(engineSrc));

const persistSrc = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/pages/NodeSelectionPage.ets'), 'utf8');
ok('持久化转换优先使用 rec.failKind（不再从 state 重新盖章）',
  /toPersistRecord[\s\S]{0,600}?rec\.failKind\.length\s*>\s*0/.test(persistSrc));

// ── 「测全部」走组测路径，组接口不返回状态码 → 必须靠内核代理表区分 ────
// 契约：组测后用 proxyTableNames() 判断"节点在不在内核里"，
// 不在 → switch_failed（未生效）；在 → 真超时。否则「测全部」看到的仍是全红。
ok('组测路径用内核代理表区分「未生效」',
  /proxyTableNames\(\)/.test(persistSrc));
ok('组测路径把不在代理表的失败节点标为 switch_failed',
  /notInCore[\s\S]{0,400}?LatencyFailKind\.SWITCH_FAILED/.test(persistSrc));
ok('测速完成提示单独报「未生效」计数',
  /未生效 \$\{progress\.failed\}/.test(persistSrc));

const apiSrc = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/commons/services/ClashApiService.ets'), 'utf8');
ok('ClashApiService 提供 proxyTableNames（内核代理表全名）',
  /async proxyTableNames\(\): Promise<string\[\] \| null>/.test(apiSrc));

// ── 测速超时与并发度（2026-10-19 用户要求：超时 5s、并发 88 → 2026-10-20 整改为 50）──
// 契约：单节点超时、组测预算、并发度三者必须一致 —— 同一节点在「测全部」
// 和「单节点测速」里用不同尺子，结论会相反。
//
// 2026-10-20（订阅解析内核化整改 C8b）：并发度由 88 收敛为 50。
//   88 是「并发 worker 数」口径下的旧值，与 FlClash 的核内批量限流数值对齐但机制不同；
//   50 = worker 数（队列深度），**在途请求数**由 C7 的闸门单独限制为 LATENCY_INFLIGHT=8
//   （= OHOS 同 host 连接池容量；5.6.0 真机基线：https + 并发 8 → 59 节点 13.14s、unavailable=false）。
//   另注：C7 之后「排队等待」不再计入单请求超时预算，故并发度不再是超时算术的前提。
ok('单节点测速超时为 5000ms', /DEFAULT_TIMEOUT_MS:\s*number\s*=\s*5000/.test(stateSrc));
ok('并发测速数为 50（C8b：由 88 收敛，worker 口径）', /LATENCY_CONCURRENCY\s*=\s*50/.test(engineSrc));
ok('在途并发上限为 8（C7 闸门：同 host 连接池容量）', /LATENCY_INFLIGHT\s*=\s*8/.test(engineSrc));
ok('组测每节点预算与单节点一致（5000ms）', /GROUP_TEST_TIMEOUT_MS\s*=\s*5000/.test(engineSrc));
ok('内核延迟探测默认超时同步为 5000ms',
  /testLatencyDetailed\(nodeName: string, testUrl: string,\s*\n?\s*timeoutMs: number = 5000/.test(apiSrc));
ok('离线探测的阶段预算同步为 5s（不被 2.5s 截断）',
  /QUIC_TIMEOUT_MS\s*=\s*5000/.test(fs.readFileSync(
    path.join(root, 'entry/src/main/ets/commons/services/DirectLatencyTester.ets'), 'utf8')));
ok('批次硬截止可注入（回归测试不再依赖并发算术巧合）',
  /batchDeadlineMs:\s*number\s*=\s*BATCH_DEADLINE_MS/.test(engineSrc));

console.log(`\n延迟显示契约自检：${pass} 条通过，${fails.length} 条失败`);
if (fails.length > 0) {
  console.error('失败：' + fails.join(' | '));
  process.exit(1);
}
console.log('全部通过（失败一律显示超时/失败，不再有按来源改写的「未测」）');
process.exit(0);
