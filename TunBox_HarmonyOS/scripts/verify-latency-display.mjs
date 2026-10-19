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

  // 必须仍然把失败落到 stateText（超时/失败）
  ok(`${t.ns}.recordText 失败走 LatencyPolicy.stateText`,
    /LatencyPolicy\.stateText\(rec\.state\)/.test(text));
  // 必须仍然保留离线 ≈ 前缀与"没数据 = --"语义
  ok(`${t.ns}.recordText 保留离线 ≈ 前缀`,
    /`≈\$\{body\}`/.test(text) || /≈/.test(text));
  ok(`${t.ns}.recordText 无记录时仍为 --`, /return\s*'--'/.test(text));
  // 失败配色必须是红色系（不再是中性）
  ok(`${t.ns}.recordColor 失败走红色`,
    /LatencyState\.TIMEOUT\s*\|\|\s*rec\.state\s*===\s*LatencyState\.FAILED/.test(color));
}

// 反例守护：确保 stateText 真的把 TIMEOUT 映射成「超时」
const stateSrc = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/commons/services/LatencyState.ets'), 'utf8');
ok('LatencyPolicy.stateText 中 TIMEOUT 映射为「超时」',
  /TIMEOUT[\s\S]{0,120}?超时/.test(stateSrc));

console.log(`\n延迟显示契约自检：${pass} 条通过，${fails.length} 条失败`);
if (fails.length > 0) {
  console.error('失败：' + fails.join(' | '));
  process.exit(1);
}
console.log('全部通过（失败一律显示超时/失败，不再有按来源改写的「未测」）');
process.exit(0);
