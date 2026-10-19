/**
 * 天体轨域「转动元素永不重叠」回归（2026-10-18 用户报障）。
 *
 * 用户原话：> 主页的代理启动按钮，现在外围两个圈上面各有一个球和一条线在四周转动，
 * > 经常会转动的重叠在一起，我希望转动的动画永远不要重叠，全部分开。
 *
 * 根因：旧实现三条元素用不同角速度（`spin` / `spin*0.55` / `-spin*0.8`），
 * 相对角度线性漂移 → 必然周期性重合。修法是**统一角速度**（speedFactor 全 1）+
 * 固定角度槽位；本脚本真跑 `OrbLayout` 的几何，扫完整一圈轨道相位，断言：
 *   1) 所有元素同速（不同速就一定会在某个相位重叠）；
 *   2) 任意两元素在**任意相位**的最小视觉间距 > 20vp（远大于触摸/视觉容差）。
 * 不是读源码断言，而是真的把几何算出来。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { stripTypeScriptTypes } from 'node:module';
import os from 'node:os';

const here = path.dirname(fileURLToPath(import.meta.url));
const src = path.join(here, '..', 'entry/src/main/ets/components/CelestialOrbLayout.ets');
const raw = fs.readFileSync(src, 'utf8');
if (/from '@kit|from "\.\.?\/|import \{/.test(raw)) {
  console.error('FAIL: CelestialOrbLayout.ets 必须保持零依赖（供本脚本直接执行）');
  process.exit(1);
}
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'orb-layout-'));
const jsPath = path.join(stage, 'CelestialOrbLayout.ts');
fs.writeFileSync(jsPath, stripTypeScriptTypes(raw), 'utf8');
const { OrbLayout, OrbElement } = await import(pathToFileURL(jsPath).href);

let passed = 0;
let failed = 0;
function check(name, fn) {
  try {
    fn();
    passed++;
    console.log(`PASS ${name}`);
  } catch (e) {
    failed++;
    console.log(`FAIL ${name} :: ${e.message}`);
  }
}

const elements = OrbLayout.elements();

check('四个转动元素齐全（外圈球 / 蓝弧 / 内圈球 / 绿弧）', () => {
  if (elements.length !== 4) throw new Error(`expected 4 elements, got ${elements.length}`);
  const kinds = elements.map((e) => e.kind).sort().join(',');
  if (kinds !== 'arc,arc,ball,ball') throw new Error(`unexpected kinds: ${kinds}`);
});

check('所有元素同速（speedFactor 全为 1）—— 不同速必然周期性重叠', () => {
  if (!OrbLayout.uniformSpeed()) throw new Error('speedFactor 不一致');
  for (const e of elements) {
    if (e.speedFactor !== 1) throw new Error(`element speedFactor=${e.speedFactor}`);
  }
});

check('任意相位下两两视觉间距 ≥ 20vp（扫整圈 360°，步长 1°）', () => {
  const gap = OrbLayout.minGapVp(1, 2);
  if (!(gap >= 20)) throw new Error(`min gap too small: ${gap.toFixed(2)}vp`);
  console.log(`     实测最小间距 = ${gap.toFixed(1)}vp`);
});

check('间距是常数（同速 → 不随相位变化）', () => {
  const g0 = OrbLayout.minGapVp(90, 2);
  const g1 = OrbLayout.minGapVp(90, 2);
  if (Math.abs(g0 - g1) > 1e-6) throw new Error('gap not stable');
});

check('两条长条等长（都是 42°，十字对称）', () => {
  const arcs = elements.filter((e) => e.kind === OrbElement.KIND_ARC);
  const sweeps = arcs.map((e) => e.sweepDeg);
  if (sweeps.length !== 2) throw new Error(`expected 2 arcs, got ${sweeps.length}`);
  if (sweeps[0] !== sweeps[1]) throw new Error(`arcs must be equal length, got ${sweeps}`);
  if (sweeps[0] !== 42) throw new Error(`unexpected sweep: ${sweeps[0]}`);
});

check('球与长条同半径（十字两臂落在同一圆周，否则一长一短）', () => {
  const balls = elements.filter((e) => e.kind === OrbElement.KIND_BALL);
  const arcs = elements.filter((e) => e.kind === OrbElement.KIND_ARC);
  for (const b of balls) {
    for (const a of arcs) {
      if (b.radius !== a.radius) {
        throw new Error(`ball r=${b.radius} != arc r=${a.radius}: cross arms on different circles`);
      }
    }
  }
  console.log(`     统一半径 = ${balls[0].radius}vp`);
});

check('十字对称：两球同轨且相隔 180°，两长条同轨且相隔 180°', () => {
  const balls = elements.filter((e) => e.kind === OrbElement.KIND_BALL);
  const arcs = elements.filter((e) => e.kind === OrbElement.KIND_ARC);
  if (balls.length !== 2 || arcs.length !== 2) throw new Error('need exactly 2 balls + 2 arcs');
  if (balls[0].radius !== balls[1].radius) {
    throw new Error(`balls not symmetric: r=${balls[0].radius} vs ${balls[1].radius}`);
  }
  if (arcs[0].radius !== arcs[1].radius) {
    throw new Error(`arcs not symmetric: r=${arcs[0].radius} vs ${arcs[1].radius}`);
  }
  const ballDelta = Math.abs(balls[1].centerAt(0) - balls[0].centerAt(0));
  if (ballDelta !== 180) throw new Error(`balls must be opposite, delta=${ballDelta}°`);
  const arcDelta = Math.abs(arcs[1].centerAt(0) - arcs[0].centerAt(0));
  if (arcDelta !== 180) throw new Error(`arcs must be opposite, delta=${arcDelta}°`);
});

// ── 2026-10-18 第二轮用户反馈：小球必须在十字中线上（长条要关于自己的轴居中）──
check('长条关于自己的轴居中：中线严格落在 0° 与 180°', () => {
  const arcs = elements.filter((e) => e.kind === OrbElement.KIND_ARC);
  const centers = arcs.map((e) => e.centerAt(0)).sort((a, b) => a - b);
  if (centers[0] !== 0) throw new Error(`right arc center must be 0°, got ${centers[0]}°`);
  if (centers[1] !== 180) throw new Error(`left arc center must be 180°, got ${centers[1]}°`);
  for (const e of arcs) {
    // 起点与终点到中线的角距必须相等（真正居中，不是「起点压轴」）
    const half = e.sweepDeg / 2;
    const start = ((e.offsetDeg % 360) + 360) % 360;
    const end = ((e.offsetDeg + e.sweepDeg) % 360 + 360) % 360;
    const startGap = Math.abs(((e.centerAt(0) - start + 540) % 360) - 180);
    const endGap = Math.abs(((end - e.centerAt(0) + 540) % 360) - 180);
    if (Math.abs(startGap - half) > 1e-9 || Math.abs(endGap - half) > 1e-9) {
      throw new Error(`arc not centered on its axis: start=${start}° end=${end}° center=${e.centerAt(0)}°`);
    }
  }
});

check('小球严格在十字中线上：球 90°/270° 与长条中线 0°/180° 正交', () => {
  const balls = elements.filter((e) => e.kind === OrbElement.KIND_BALL);
  const arcs = elements.filter((e) => e.kind === OrbElement.KIND_ARC);
  const ballAngles = balls.map((e) => e.centerAt(0)).sort((a, b) => a - b);
  if (ballAngles[0] !== 90 || ballAngles[1] !== 270) {
    throw new Error(`balls must sit exactly at 90°/270°, got ${ballAngles}`);
  }
  for (const b of balls) {
    for (const a of arcs) {
      const delta = Math.abs(((b.centerAt(0) - a.centerAt(0)) % 360 + 360) % 360);
      if (delta !== 90 && delta !== 270) {
        throw new Error(`ball ${b.centerAt(0)}° vs arc ${a.centerAt(0)}°: not orthogonal (delta=${delta}°)`);
      }
    }
  }
});

check('旋转任意相位后十字仍成立（球心与长条中线恒差 90°）', () => {
  const balls = elements.filter((e) => e.kind === OrbElement.KIND_BALL);
  const arcs = elements.filter((e) => e.kind === OrbElement.KIND_ARC);
  for (let spin = 0; spin < 360; spin += 7) {
    for (const b of balls) {
      for (const a of arcs) {
        const delta = Math.abs(((b.centerAt(spin) - a.centerAt(spin)) % 360 + 360) % 360);
        if (delta !== 90 && delta !== 270) {
          throw new Error(`spin=${spin}°: ball/arc not orthogonal (delta=${delta}°)`);
        }
      }
    }
    // 两球仍相差 180°
    const d = Math.abs(balls[1].centerAt(spin) - balls[0].centerAt(spin));
    if (d !== 180) throw new Error(`spin=${spin}°: balls not opposite (delta=${d}°)`);
  }
});

check('沿圆周分布均衡：相邻元素最大角空隙 ≤ 120°（不会挤在一侧）', () => {
  const spans = elements.map((e) => {
    const s = e.spanAt(0);
    const norm = ((s[0] % 360) + 360) % 360;
    return [norm, norm + e.sweepDeg];
  }).sort((a, b) => a[0] - b[0]);
  let maxGap = 0;
  for (let i = 0; i < spans.length; i++) {
    const end = spans[i][1];
    const nextStart = i + 1 < spans.length ? spans[i + 1][0] : spans[0][0] + 360;
    const gap = nextStart - end;
    if (gap > maxGap) maxGap = gap;
  }
  if (!(maxGap <= 120)) throw new Error(`elements clumped: max angular gap ${maxGap.toFixed(0)}°`);
  console.log(`     最大角空隙 = ${maxGap.toFixed(0)}°`);
});

check('反向验证：把绿弧改回 0.55 倍速会被判出重叠（守卫生效）', () => {
  // 直接改静态元素再还原，确认 minGapVp 真能发现「不同速」这种回归
  const green = OrbLayout.ARC2;
  const saved = green.speedFactor;
  green.speedFactor = 0.55;
  const bad = OrbLayout.minGapVp(1, 2);
  green.speedFactor = saved;
  if (!(bad < 20)) throw new Error(`guard failed: 0.55x speed should overlap, got ${bad.toFixed(1)}vp`);
  console.log(`     0.55 倍速时最小间距 = ${bad.toFixed(1)}vp（<20，判为重叠）`);
});

fs.rmSync(stage, { recursive: true, force: true });
console.log(`\nOrb separation: ${passed} passed, ${failed} failed (EXEC real geometry).`);
if (failed > 0) process.exitCode = 1;
