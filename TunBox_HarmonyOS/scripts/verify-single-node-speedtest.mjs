/**
 * 单节点分组（DIRECT_GROUP_ID）可测速 —— 修复自检（结构断言 + 负对照）。
 *
 * ## 被守护的不变量（始终有效）
 *
 * 通过 vless:// 等直链导入的节点落在默认「单节点」分组里，该分组**必须也能测速**。
 * 历史上它测不了，根因是两处同样口径的拦截，必须同时拆掉，缺一仍是死按钮：
 *   1) speedTestSub() 开头 `if (subId === DIRECT_GROUP_ID || ...) return;`
 *      → 即使按钮画出来，点下去也是静默 no-op。
 *   2) 闪电按钮外面包着 `if (sub.id !== DIRECT_GROUP_ID) { ... }`
 *      → 单节点分组根本不渲染这个按钮。
 *
 * ## 2026-10-19 设计变更（用户要求，本脚本随之调整断言）
 *
 * 用户把订阅卡改版：
 *   · 行头**只保留刷新**（原来行头有 闪电/刷新/编辑/删除 四个按钮，把订阅名挤没了）；
 *   · 闪电测速 / 编辑 / 删除 三个操作下移到展开区，放在原「点击选用节点…」提示行；
 *   · 顺序要求：闪电在编辑左边；原提示文字去掉；节点下方的编辑/删除行去掉。
 *
 * 于是闪电按钮的**位置**从行头变到展开区，但**不变量不变**：
 * 它必须仍然渲染于 DIRECT_GROUP_ID 分组（即不被 `sub.id !== DIRECT_GROUP_ID` 包裹），
 * 且 speedTestSub 仍不得拦截 direct。本脚本断言的正是这个不变量，
 * 以及「行头确实瘦身了」这个新增的负对照。
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

// ── 区间锚点（2026-10-19 改版后的结构）──────────────────────────────────
// 展开区操作行：用改版注释定位，再取其后第一个 Row() ——
// 不用 `Row({ space: 16 })` 之类布局细节做锚点（间距实现换过一次就失效）。
// 2026-10-21：改为稳定锚点标记，UI 文案/布局再改也不会把区间截空。
const ACTION_COMMENT = '// [anchor] 订阅展开区操作行';
const actionCommentIdx = src.indexOf(ACTION_COMMENT);
const actionRowIdx = actionCommentIdx >= 0 ? src.indexOf('Row() {', actionCommentIdx) : -1;
// 该行之后第一个 GridRow 即节点网格 —— 操作行区间右界
const gridIdx = src.indexOf('GridRow({ columns: this.nodeColumns', actionRowIdx);
// 展开区内唯一的 DIRECT 判定：编辑/删除闸门（闪电在其之前，故不被包裹）
const gateIdx = src.indexOf('if (sub.id !== DIRECT_GROUP_ID)', actionRowIdx);

// 闪电按钮区间 = 操作行起点 → 编辑/删除闸门起点（不含闸门）
const boltRegion = (actionRowIdx >= 0 && gateIdx > actionRowIdx) ? src.slice(actionRowIdx, gateIdx) : '';
const boltCode = stripComments(boltRegion);

// 行头区间 = 改版注释 → 展开箭头
const headerAnchor = src.indexOf('// 2026-10-19 用户要求（订阅卡片改版）');
const headerArrow = src.indexOf("Image($r('app.media.ic_arrow_right')).width(14).height(14)", headerAnchor);
const headerRegion = (headerAnchor >= 0 && headerArrow > headerAnchor)
  ? src.slice(headerAnchor, headerArrow) : '';

console.log(`\n单节点分组可测速修复自检${argIdx >= 0 ? `（--file ${file}）` : ''}`);

// ── 0. 文件与行尾格式前提 ──────────────────────────────────────────────
ok('源码存在且非空', src.length > 1000, `len=${src.length}`);

// ── 1. speedTestSub：早退守卫不再拦截 direct（不变量第 1 部分）──────────
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
  // 允许第三个可选参数（通道就绪回调，2026-10-20 测速通道预热整改引入）：
  // 锁定的是「仍走 BackgroundLatencyService.testSubscription(…, subId)」这件事，
  // 不是参数个数。
  /await BackgroundLatencyService\.testSubscription\(getContext\(this\) as Context, subId\s*[,\)]/.test(fnCode));
ok('speedTestSub 仍在 finally 里清理 speedTestingIds',
  /finally\s*\{[\s\S]{0,200}?this\.speedTestingIds = this\.speedTestingIds\.filter\(\(x: string\) => x !== subId\)/.test(fnCode));

// ── 2. 闪电按钮（2026-10-19 起位于展开区操作行）：仍不被 direct 判定包裹 ──
//    不变量第 2 部分 —— 位置变了，但「单节点分组必须有闪电」没变。
ok('展开区操作行可截取（Row({ space: 16 }) → 编辑/删除闸门）',
  boltRegion.length > 0 && boltRegion.length < 1200, `len=${boltRegion.length}`);
ok('操作行之后确实紧跟节点网格（区间右界有效）', gridIdx > actionRowIdx, `grid=${gridIdx}`);
ok('闪电按钮位于编辑/删除闸门**之前**（即不被 sub.id !== DIRECT_GROUP_ID 包裹）',
  actionRowIdx >= 0 && gateIdx > actionRowIdx, `actionRow=${actionRowIdx} gate=${gateIdx}`);
ok('闪电按钮窗口内代码区无任何 DIRECT_GROUP_ID 判定（注释提及不算）',
  boltRegion.length > 0 && !/DIRECT_GROUP_ID/.test(boltCode));

// 结构完整性：属性链仍然挂在同一对象上
ok('闪电按钮绑定 speedTestSub(sub.id)',
  /\.onClick\(\(\) => this\.speedTestSub\(sub\.id\)\)/.test(boltRegion));
ok('闪电按钮仍带 accessibilityText(闪电测速)',
  /\.accessibilityText\('闪电测速'\)/.test(boltRegion));
ok('闪电按钮测速中显示 LoadingProgress',
  /this\.speedTestingIds\.includes\(sub\.id\)[\s\S]{0,220}?LoadingProgress\(\)/.test(boltRegion));
ok('闪电按钮无「测速中」以外的其它图标（仍是 ic_bolt）',
  /Image\(\$r\('app\.media\.ic_bolt'\)\)/.test(boltRegion));

// ── 3. 顺序：闪电 → 编辑 → 删除（用户 2026-10-19 明确要求「闪电在编辑左边」）──
const boltA11y = src.indexOf(".accessibilityText('闪电测速')");
const editA11y = src.indexOf(".accessibilityText('编辑订阅')");
const delA11y = src.indexOf(".accessibilityText('删除订阅')");
ok('闪电 / 编辑 / 删除 三个入口都存在', boltA11y > 0 && editA11y > 0 && delA11y > 0,
  `bolt=${boltA11y} edit=${editA11y} del=${delA11y}`);
ok('闪电在编辑左边（用户明确要求）', boltA11y > 0 && boltA11y < editA11y,
  `bolt=${boltA11y} edit=${editA11y}`);
ok('编辑在删除左边', editA11y > 0 && editA11y < delA11y, `edit=${editA11y} del=${delA11y}`);

// 分布：测速居左 / 编辑居中 / 删除居右（2026-10-21 用户要求：
// 「测速放左边，编辑放中间，删除放右边」+ 字号加大一号 + 图标加大 + 补点击热区）
const actionRegion = (actionRowIdx >= 0 && gridIdx > actionRowIdx)
  ? src.slice(actionRowIdx, gridIdx) : '';
const blankPos = actionRegion.indexOf('Blank()');
const boltInRow = actionRegion.indexOf(".accessibilityText('闪电测速')");
const editInRow = actionRegion.indexOf(".accessibilityText('编辑订阅')");
const delInRow = actionRegion.indexOf(".accessibilityText('删除订阅')");
ok('测速在最左（第一次 Blank() 出现在测速之后）',
  boltInRow > 0 && blankPos > boltInRow, `blank=${blankPos} bolt=${boltInRow}`);
ok('编辑居中（测速与编辑之间、编辑与删除之间各有 Blank()）',
  (actionRegion.match(/Blank\(\)/g) || []).length === 2
    && editInRow > boltInRow && delInRow > editInRow,
  `blanks=${(actionRegion.match(/Blank\(\)/g) || []).length}`);
ok('三个入口字号统一为 13（原 12，用户要求加大一号）',
  (actionRegion.match(/fontSize\(13\)/g) || []).length === 3,
  `count=${(actionRegion.match(/fontSize\(13\)/g) || []).length}`);
ok('三个入口图标统一 14（原 13；测速中的 LoadingProgress 也是 14）',
  (actionRegion.match(/Image\(\$r\('app\.media\.ic_(bolt|tune|delete)'\)\)\.width\(14\)\.height\(14\)/g) || []).length === 3,
  `count=${(actionRegion.match(/Image\(\$r\('app\.media\.ic_\w+'\)\)\.width\(14\)\.height\(14\)/g) || []).length}`);
ok('每个入口都有上下内边距放大点击热区',
  (actionRegion.match(/top: 6, bottom: 6/g) || []).length === 3,
  `count=${(actionRegion.match(/top: 6, bottom: 6/g) || []).length}`);
// 编辑图标曾经是坏的（ic_tune.svg 里 `<path d="<rect…` 让整个 SVG 解析失败 → 真机空白）
const tuneSvg = fs.readFileSync(path.join(here, '..', 'entry/src/main/resources/base/media/ic_tune.svg'), 'utf8');
ok('ic_tune.svg 是完整 SVG 文档（无被 <rect> 截断的 <path d="）',
  tuneSvg.startsWith('<svg') && !tuneSvg.includes('<path d="<'), 'ic_tune.svg 结构损坏');
ok('ic_tune.svg 含三条滑杆 + 三个旋钮',
  (tuneSvg.match(/<rect /g) || []).length === 3 && (tuneSvg.match(/<circle /g) || []).length === 3,
  `rect=${(tuneSvg.match(/<rect /g) || []).length} circle=${(tuneSvg.match(/<circle /g) || []).length}`);

// ── 4. 行头瘦身（2026-10-19 新增负对照）──────────────────────────────
//    用户报障「订阅名字会被遮住」：行头必须只剩刷新 + 展开箭头，
//    闪电 / 编辑 / 删除 都不得再出现在行头。
ok('行头区间可截取', headerRegion.length > 0 && headerRegion.length < 1600, `len=${headerRegion.length}`);
ok('行头保留刷新按钮', /Image\(\$r\('app\.media\.ic_refresh'\)\)/.test(headerRegion));
ok('行头已无闪电按钮（负对照）', !/ic_bolt/.test(headerRegion), 'header must not contain ic_bolt');
ok('行头已无编辑按钮（负对照）', !/ic_tune/.test(headerRegion), 'header must not contain ic_tune');
ok('行头已无删除按钮（负对照）', !/ic_delete/.test(headerRegion), 'header must not contain ic_delete');

// ── 5. 括号/大括号配平（本文件结构未被改坏）────────────────────────────
const bal = balancedReport();
ok('全文件括号配平', bal.ok, bal.msg);

// ── 6. DIRECT_GROUP_ID 仍被使用（无死 import）+ 存活合法闸门盘点 ────────
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
ok('闪电按钮区间内未出现 DIRECT_GROUP_ID（真实区间 + 仅代码区）',
  !occ.some((o) => o.index >= actionRowIdx && o.index < gateIdx && MASK[o.index] === 1),
  'unexpected DIRECT_GROUP_ID inside bolt button region');

// 存活的合法闸门（人工分类，脚本只负责如实报出，防止「拆错闸门」）
console.log(`  ℹ DIRECT_GROUP_ID 出现 ${occ.length} 处：`);
for (const o of occ) {
  const lineStart = src.lastIndexOf('\n', o.index) + 1;
  const lineEnd = src.indexOf('\n', o.index);
  const lineText = src.slice(lineStart, lineEnd < 0 ? src.length : lineEnd).trim();
  console.log(`      L${o.line}: ${lineText.slice(0, 96)}`);
}

// 明确断言：本次改版**不得**误伤其它合法闸门
ok('编辑/删除闸门保留（常驻分组不可编辑/不可删）',
  /if \(sub\.id !== DIRECT_GROUP_ID\) \{\r?\n\s*Row\(\{ space: 4 \}\) \{\r?\n\s*Image\(\$r\('app\.media\.ic_tune'\)\)/.test(src));
ok('删除入口仍受同一闸门保护（ic_delete 在闸门之后、网格之前）',
  gateIdx > 0 && src.indexOf('ic_delete', gateIdx) > gateIdx
  && src.indexOf('ic_delete', gateIdx) < gridIdx,
  `gate=${gateIdx} del=${src.indexOf('ic_delete', gateIdx)} grid=${gridIdx}`);
ok('refreshOne 的 direct 早退保留（本次改版范围外，刷新语义不变）',
  /if \(sub\.id === DIRECT_GROUP_ID \|\| this\.isRefreshing \|\| this\.isRefreshingSub\(sub\.id\)\) \{\r?\n\s*return;/.test(src));
ok('reload 的 direct 空组过滤保留',
  /s\.id !== DIRECT_GROUP_ID \|\| s\.nodeCount > 0\);/.test(src));
ok('doDelete 常驻分组守卫保留', src.includes('单节点分组为常驻分组，不能删除'));

// ── 7. 旧「点击选用节点…」提示文字必须从代码里消失（只在注释里说明历史）──
const srcCode = stripComments(src);
ok('旧提示文字「点行头闪电图标测速」已从代码中移除',
  !srcCode.includes('点行头闪电图标测速'), 'hint text still present in code');
ok('旧提示文字「点击选用节点」已从代码中移除',
  !srcCode.includes('点击选用节点'), 'hint text still present in code');

// ── 汇总 ──────────────────────────────────────────────────────────────
console.log(`\n单节点测速自检：${pass} 条通过，${fails.length} 条失败`);
if (fails.length > 0) {
  console.error('失败：' + fails.join(' | '));
  process.exit(1);
}
console.log('全部通过（单节点分组仍有闪电按钮、speedTestSub 不拦截 direct、'
  + '闪电在编辑左边、行头已瘦身、旧提示文字已移除、合法闸门未被误伤）');
process.exit(0);
