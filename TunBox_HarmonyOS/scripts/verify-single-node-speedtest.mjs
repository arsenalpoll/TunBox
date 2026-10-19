/**
 * 单节点分组（DIRECT_GROUP_ID）可测速 —— 修复自检（结构断言 + 负对照）。
 *
 * 用户报障：通过 vless:// 等直链导入的节点落在默认「单节点」分组里，
 * 而该分组头**没有闪电测速按钮**，展开区提示文字却写着「点行头闪电图标测速」
 * —— 于是单节点永远无法测速。
 *
 * 根因（两处同样口径的拦截，必须同时拆掉，缺一仍是死按钮）:
 *   1) speedTestSub() 开头 `if (subId === DIRECT_GROUP_ID || ...) return;`
 *      → 即使按钮画出来，点下去也是静默 no-op。
 *   2) 分组头闪电 Stack 外面包着 `if (sub.id !== DIRECT_GROUP_ID) { ... }`
 *      → 单节点分组根本不渲染这个按钮。
 *
 * 本脚本不做完整 ArkTS 解析（无 DevEco SDK），只对源码做结构断言，
 * 与仓库既有 verify-*.mjs 的「文本断言 + 负对照」风格一致。
 *
 * ⚠ 两个已知陷阱（本脚本已正确处理，勿改回去）:
 *   · 源码是 CRLF：跨行正则必须写 \r?\n，否则永不命中。
 *   · 守卫里有**嵌套括号**（`this.speedTestingIds.includes(subId)`），
 *     用 `[^)]*` 抓参数会停在第一个 `)` 上导致永不命中；必须用懒惰
 *     `([\s\S]*?)`。同理，取函数体不能切固定长度窗口（会溢进下一个函数，
 *     把 refreshOne 里合法的 DIRECT_GROUP_ID 误判成本函数的）。
 *
 * 用法: node scripts/verify-single-node-speedtest.mjs [--file <path>]
 *   --file 用于负对照：指向修复前的文件时，本脚本**必须失败**。
 * 退出码: 0 = 全部断言通过；1 = 有断言失败
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const argIdx = process.argv.indexOf('--file');
const file = argIdx >= 0 && process.argv[argIdx + 1]
  ? path.resolve(process.argv[argIdx + 1])
  : path.join(here, '..', 'entry', 'src', 'main', 'ets', 'pages', 'SubscriptionPage.ets');
const src = fs.readFileSync(file, 'utf8');

let pass = 0;
const fails = [];
function ok(name, cond, extra) {
  if (cond) { pass += 1; console.log(`  ✓ ${name}`); }
  else { fails.push(name + (extra ? ` (${extra})` : '')); console.log(`  ✗ ${name}${extra ? ` — ${extra}` : ''}`); }
}

/** 1-based 行号，便于定位 */
function lineOf(index) {
  return index < 0 ? -1 : src.slice(0, index).split('\n').length;
}

/** 去掉注释与字符串字面量（用于「注释里提到不算数」的断言） */
function stripComments(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\r\n]*/g, '');
}

/**
 * 单遍状态机：返回 code 掩码（1=代码，0=注释/字符串/正则字面量内部）。
 * 只有掩码为 1 的位置参与括号匹配，避免 ArkUI 链式属性与正则里的 (){}[] 误判。
 */
function codeMask(text) {
  const mask = new Uint8Array(text.length);
  let i = 0;
  let prev = '';
  const mark = (n) => { for (let k = 0; k < n && i + k < text.length; k += 1) mask[i + k] = 1; };
  while (i < text.length) {
    const ch = text[i];
    const nx = text[i + 1];
    if (ch === '/' && nx === '/') { while (i < text.length && text[i] !== '\n') i += 1; continue; }
    if (ch === '/' && nx === '*') {
      i += 2;
      while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) i += 1;
      i += 2;
      continue;
    }
    if (ch === "'" || ch === '"' || ch === '`') {
      const q = ch;
      i += 1;
      while (i < text.length && text[i] !== q) { if (text[i] === '\\') i += 1; i += 1; }
      i += 1;
      prev = 'str';
      continue;
    }
    if (ch === '/' && nx !== undefined && !/\s/.test(nx) && nx !== '/' && nx !== '*') {
      if (prev === '' || '=(,:;[!&|?{+return'.includes(prev)) {
        i += 1;
        let inClass = false;
        while (i < text.length) {
          const c = text[i];
          if (c === '\\') { i += 2; continue; }
          if (c === '[') inClass = true;
          else if (c === ']') inClass = false;
          else if (c === '/' && !inClass) break;
          else if (c === '\n') break;
          i += 1;
        }
        i += 1;
        while (i < text.length && /[gimsuyd]/.test(text[i])) i += 1;
        prev = 're';
        continue;
      }
    }
    mark(1);
    if (!/\s/.test(ch)) prev = ch;
    i += 1;
  }
  return mask;
}

const MASK = codeMask(src);

/** 从 openIdx（必须是 '{' 且在代码区）扫到匹配的 '}'，返回其下标；失败返回 -1 */
function matchBrace(openIdx) {
  const OPEN = { '{': '}', '(': ')', '[': ']' };
  const CLOSE = { '}': '{', ')': '(', ']': '[' };
  const stack = [];
  for (let i = openIdx; i < src.length; i += 1) {
    if (MASK[i] !== 1) continue;
    const ch = src[i];
    if (OPEN[ch]) stack.push(ch);
    else if (CLOSE[ch]) {
      if (stack.pop() !== CLOSE[ch]) return -1;
      if (stack.length === 0) return i;
    }
  }
  return -1;
}

/** 全文件括号配平（逐字符状态机；朴素计数在 ArkUI 里是假失败） */
function balancedReport() {
  const PAIRS = { ')': '(', '}': '{', ']': '[' };
  const stack = [];
  for (let i = 0; i < src.length; i += 1) {
    if (MASK[i] !== 1) continue;
    const ch = src[i];
    if (PAIRS[ch]) {
      const top = stack.pop();
      const line = lineOf(i);
      if (top === undefined) return { ok: false, msg: `第 ${line} 行多余 '${ch}'` };
      if (top.ch !== PAIRS[ch]) return { ok: false, msg: `第 ${line} 行 '${ch}' 与第 ${top.line} 行 '${top.ch}' 不匹配` };
    } else if ('({['.includes(ch)) {
      stack.push({ ch, line: lineOf(i) });
    }
  }
  if (stack.length > 0) {
    return { ok: false, msg: `末尾仍有 ${stack.length} 个未闭合括号，首个在第 ${stack[0].line} 行 '${stack[0].ch}'` };
  }
  return { ok: true, msg: '括号全部配平' };
}

console.log(`\n单节点分组可测速修复自检${argIdx >= 0 ? `（--file ${file}）` : ''}`);

// ── 0. 文件与行尾格式前提 ──────────────────────────────────────────────
ok('源码存在且非空', src.length > 1000, `len=${src.length}`);

// ── 1. speedTestSub：早退守卫不再拦截 direct（修复第 1 部分）────────────
const FN_SIG = 'private async speedTestSub(subId: string): Promise<void> {';
const fnIdx = src.indexOf(FN_SIG);
ok('speedTestSub 存在', fnIdx > 0, `idx=${fnIdx}`);
// 函数体必须按**真实右花括号**截取；固定长度窗口会溢进 refreshOne（负对照会假过）
const fnOpen = fnIdx < 0 ? -1 : src.indexOf('{', fnIdx);
const fnClose = fnOpen < 0 ? -1 : matchBrace(fnOpen);
const fnBody = (fnOpen >= 0 && fnClose > fnOpen) ? src.slice(fnOpen, fnClose + 1) : '';
ok('speedTestSub 函数体可完整截取（按花括号配对，非定长窗口）',
  fnBody.length > 0 && fnBody.length < 2000, `len=${fnBody.length}`);

const fnCode = stripComments(fnBody);
// 守卫参数含嵌套括号，必须懒惰匹配到 `) {`，不能用 [^)]*
const guardMatch = fnCode.match(/if\s*\(([\s\S]*?)\)\s*\{\s*return;\s*\}/);
const guard = guardMatch ? guardMatch[1] : '';
ok('speedTestSub 首个守卫可截取（嵌套括号安全）', guardMatch !== null, `guard=${JSON.stringify(guard)}`);
ok('守卫仍包含 speedTestingIds（重入保护保留）',
  /this\.speedTestingIds\.includes\(subId\)/.test(guard), guard);
ok('守卫不再包含 subId === DIRECT_GROUP_ID（负对照）',
  !/subId\s*===\s*DIRECT_GROUP_ID/.test(guard), guard);
// 整个函数体内不得再出现任何 DIRECT_GROUP_ID 拦截
ok('speedTestSub 函数体内无任何 DIRECT_GROUP_ID 拦截',
  !/DIRECT_GROUP_ID/.test(fnCode), 'function body still references DIRECT_GROUP_ID');
ok('speedTestSub 仍调用 BackgroundLatencyService.testSubscription',
  /await BackgroundLatencyService\.testSubscription\(getContext\(this\) as Context, subId\)/.test(fnCode));
ok('speedTestSub 仍在 finally 里清理 speedTestingIds',
  /finally\s*\{[\s\S]{0,200}?this\.speedTestingIds = this\.speedTestingIds\.filter\(\(x: string\) => x !== subId\)/.test(fnCode));

// ── 2. 分组头闪电按钮：不再被 direct 判定包裹（修复第 2 部分）───────────
const ironIdx = src.indexOf('// ── 铁律：纯图标闪电测速按钮');
const refreshIdx = src.indexOf('// 单个刷新', ironIdx);
ok('「铁律」注释存在', ironIdx > 0);
ok('「单个刷新」注释存在', refreshIdx > ironIdx);
// 行头按钮窗口 = 铁律注释 → 单个刷新注释
const boltRegion = (ironIdx > 0 && refreshIdx > ironIdx) ? src.slice(ironIdx, refreshIdx) : '';
// 注释里提到 DIRECT_GROUP_ID 不算「闸门」：判定必须看去注释后的代码视图
const boltCode = stripComments(boltRegion);
ok('闪电按钮窗口可截取', boltRegion.length > 0 && boltRegion.length < 1200, `len=${boltRegion.length}`);

ok('闪电按钮窗口内不再有 sub.id !== DIRECT_GROUP_ID（负对照）',
  boltRegion.length > 0 && !/sub\.id\s*!==\s*DIRECT_GROUP_ID/.test(boltRegion));
ok('闪电按钮窗口内代码区无任何 DIRECT_GROUP_ID 判定（注释提及不算）',
  boltRegion.length > 0 && !/DIRECT_GROUP_ID/.test(boltCode));

// 结构完整性：Stack 属性链仍然挂在同一对象上
ok('闪电按钮为 Stack({ alignContent: Alignment.Center })',
  /Stack\(\{ alignContent: Alignment\.Center \}\)/.test(boltRegion));
ok('闪电按钮仍绑定 speedTestSub(sub.id)',
  /\.onClick\(\(\) => this\.speedTestSub\(sub\.id\)\)/.test(boltRegion));
ok('闪电按钮仍带 accessibilityText(闪电测速)',
  /\.accessibilityText\('闪电测速'\)/.test(boltRegion));
ok('闪电按钮尺寸/圆角链完整',
  /\.width\(28\)\.height\(28\)[\s\S]{0,120}?\.borderRadius\(TunBoxGeometry\.pillRadius\)/.test(boltRegion));

// 重入保护在 UI 上保留：测速中显示 LoadingProgress
ok('闪电按钮测速中显示 LoadingProgress',
  /this\.speedTestingIds\.includes\(sub\.id\)[\s\S]{0,200}?LoadingProgress\(\)\.width\(15\)\.height\(15\)/.test(boltRegion));

// 「铁律」：纯图标、无文字标签
ok('闪电按钮无文字标签（仅 Image/LoadingProgress）',
  !/\bText\(/.test(boltCode), 'bolt region must stay icon-only');

// ── 3. 位置：闪电必须在刷新之前 ────────────────────────────────────────
const boltStackIdx = src.indexOf('Stack({ alignContent: Alignment.Center })', ironIdx);
ok('闪电 Stack 位于铁律注释之后', boltStackIdx > ironIdx);
ok('闪电 Stack 在「单个刷新」之前（顺序未变）',
  boltStackIdx > 0 && boltStackIdx < refreshIdx, `bolt=${boltStackIdx} refresh=${refreshIdx}`);
ok('闪电 Stack 在刷新 Stack 之前（按代码位置复核）',
  src.indexOf('.onClick(() => this.speedTestSub(sub.id))') <
  src.indexOf('.onClick(() => this.refreshOne(sub))'));
ok('闪电按钮仍位于行头 Row 内（其后紧跟刷新按钮）',
  /\.onClick\(\(\) => this\.speedTestSub\(sub\.id\)\)[\s\S]{0,40}?\/\/ 单个刷新/.test(src));

// ── 4. 括号/大括号配平（本文件结构未被改坏）────────────────────────────
const bal = balancedReport();
ok('全文件括号配平', bal.ok, bal.msg);

// ── 5. DIRECT_GROUP_ID 仍被使用（无死 import）+ 存活合法闸门盘点 ────────
ok('DIRECT_GROUP_ID 仍从 SubscriptionService 导入',
  src.includes("import { SubscriptionService, DIRECT_GROUP_ID }"));
const occ = [];
{
  const re = /DIRECT_GROUP_ID/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    occ.push({ line: lineOf(m.index), index: m.index });
  }
}
ok('DIRECT_GROUP_ID 在文件内仍有实际使用（非死 import）', occ.length > 1, `occurrences=${occ.length}`);
// 注意：这里只统计**代码区**出现（MASK===1）。修复说明的注释里会出现常量名，
// 注释不是闸门；真正的闸门判定由上面的裸文本负对照负责。窗口用真实起止下标，
// 不用定长窗口（定长窗口会溢进相邻函数，把 refreshOne 的合法闸门误判进来）。
ok('speedTestSub 函数体内未出现 DIRECT_GROUP_ID（真实起止下标 + 仅代码区）',
  !occ.some((o) => o.index >= fnOpen && o.index <= fnClose && MASK[o.index] === 1),
  'unexpected DIRECT_GROUP_ID inside speedTestSub');
ok('行头闪电按钮窗口内未出现 DIRECT_GROUP_ID（真实区间 + 仅代码区）',
  !occ.some((o) => o.index >= ironIdx && o.index < refreshIdx && MASK[o.index] === 1),
  'unexpected DIRECT_GROUP_ID inside bolt button region');

// 存活的合法闸门（人工分类，脚本只负责如实报出，防止「拆错闸门」）
console.log(`  ℹ DIRECT_GROUP_ID 出现 ${occ.length} 处：`);
for (const o of occ) {
  const lineStart = src.lastIndexOf('\n', o.index) + 1;
  const lineEnd = src.indexOf('\n', o.index);
  const lineText = src.slice(lineStart, lineEnd < 0 ? src.length : lineEnd).trim();
  console.log(`      L${o.line}: ${lineText.slice(0, 96)}`);
}

// 明确断言：本次修复**不得**误伤其它合法闸门
ok('删除按钮闸门保留（常驻分组不可删）',
  /if \(sub\.id !== DIRECT_GROUP_ID\) \{\r?\n\s*Stack\(\{ alignContent: Alignment\.Center \}\) \{\r?\n\s*Image\(\$r\('app\.media\.ic_delete'\)\)/.test(src));
ok('refreshOne 的 direct 早退保留（本次修复范围外，刷新语义不变）',
  /if \(sub\.id === DIRECT_GROUP_ID \|\| this\.isRefreshing \|\| this\.isRefreshingSub\(sub\.id\)\) \{\r?\n\s*return;/.test(src));
ok('reload 的 direct 空组过滤保留',
  /s\.id !== DIRECT_GROUP_ID \|\| s\.nodeCount > 0\);/.test(src));
ok('doDelete 常驻分组守卫保留', src.includes('单节点分组为常驻分组，不能删除'));

// ── 6. 提示文案与按钮能力一致（回归防线）──────────────────────────────
ok('展开区提示文字仍指引「点行头闪电图标测速」',
  src.includes('点行头闪电图标测速'));

// ── 汇总 ──────────────────────────────────────────────────────────────
console.log(`\n单节点测速自检：${pass} 条通过，${fails.length} 条失败`);
if (fails.length > 0) {
  console.error('失败：' + fails.join(' | '));
  process.exit(1);
}
console.log('全部通过（单节点分组已有闪电按钮，speedTestSub 不再拦截 direct，'
  + '重入保护 / 位置 / 纯图标 / 删除闸门均未受影响）');
process.exit(0);
