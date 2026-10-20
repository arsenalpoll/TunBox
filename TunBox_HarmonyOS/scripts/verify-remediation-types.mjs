#!/usr/bin/env node
/**
 * 整改期类型校验（仓库文件口径）—— 只报**本仓库**的类型错误。
 *
 * ## 为什么要有这道闸门
 *
 * ① hvigor 的 CompileArkTS 只编译「从 entry 可达的 import 图」：
 *    新增/未引用模块即使写错类型，`assembleHap` 依然 BUILD SUCCESSFUL。
 *    所以「构建通过」**不能**证明整改代码类型正确。
 *
 * ② `scripts/verify-types.mjs` 的 [A] 段目前是**基线失败**：
 *    DevEco SDK 自带的 `@ohos.annotation.d.ets` 自身有语法错误
 *    （TS1128/TS1146/TS1434），tsc 必然非零退出。
 *    那道闸门验证的是**别的**模块，不能用它证明本次整改的类型正确性。
 *
 * 本脚本的口径不同：
 *   · 覆盖范围 = `entry/src/main/ets/commons/**` + `entry/src/main/ets/core/**`
 *     （本次整改全部落在这两个目录；pages/widgets 是 ArkUI，`struct` 不是合法 TS，
 *      单独走**语法解析**检查，见 [B] 段）；
 *   · 诊断过滤 = **只保留指向仓库文件的错误**，SDK 自带 d.ts 的错误一律忽略
 *     （那是 SDK 缺陷，不是我们的代码）；
 *   · 因此本脚本的退出码 0 = 「仓库代码零类型错误」，可以直接当 CI 闸门。
 *
 * 用法: node scripts/verify-remediation-types.mjs
 * 退出码: 0 = 仓库文件零类型错误；1 = 有仓库类型错误
 */
import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync, readdirSync, statSync, copyFileSync } from 'node:fs';
import { dirname, join, resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const appRoot = resolve(here, '..');
const etsRoot = join(appRoot, 'entry', 'src', 'main', 'ets');

const DEVECO = process.env.DEVECO_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio';
const SDK = process.env.DEVECO_SDK_HOME || join(DEVECO, 'sdk');
const ETS = join(SDK, 'default', 'openharmony', 'ets');
const KITS = join(ETS, 'kits');
const API = join(ETS, 'api');
const ETS_LOADER = join(ETS, 'build-tools', 'ets-loader');
const TSC = join(ETS_LOADER, 'node_modules', 'typescript', 'lib', 'tsc.js');

for (const [label, p] of [['typescript(tsc.js)', TSC], ['ets/kits', KITS], ['ets/api', API]]) {
  if (!existsSync(p)) {
    console.error('FATAL: 找不到 ' + label + ': ' + p + '（可用环境变量 DEVECO_HOME / DEVECO_SDK_HOME 覆盖）');
    process.exit(1);
  }
}

const sandbox = join(tmpdir(), 'tunbox-remediation-types-' + process.pid);
rmSync(sandbox, { recursive: true, force: true });
mkdirSync(sandbox, { recursive: true });
writeFileSync(join(sandbox, 'package.json'), JSON.stringify({ type: 'module' }), 'utf8');

/** 递归收集目录下所有 .ets → 暂存为同名 .ts（保留目录结构，相对 import 才能解析） */
function stageTree(dir, outRoot) {
  const staged = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) {
      staged.push(...stageTree(p, outRoot));
    } else if (name.endsWith('.ets')) {
      const rel = relative(dir, p).replace(/\.ets$/, '.ts');
      const dest = join(outRoot, rel);
      mkdirSync(dirname(dest), { recursive: true });
      writeFileSync(dest, readFileSync(p, 'utf8'), 'utf8');
      staged.push(dest);
    }
  }
  return staged;
}

const srcDirs = [join(etsRoot, 'commons'), join(etsRoot, 'core')];
const staged = [];
for (const d of srcDirs) {
  if (existsSync(d)) {
    staged.push(...stageTree(d, join(sandbox, 'src')));
  }
}
if (staged.length === 0) {
  console.error('FATAL: 没有暂存到任何 .ets 文件');
  process.exit(1);
}

const tsconfig = {
  compilerOptions: {
    target: 'ES2021',
    module: 'ESNext',
    moduleResolution: 'node',
    lib: ['ES2021'],
    strict: true,
    noEmit: true,
    skipLibCheck: true,
    forceConsistentCasingInFileNames: true,
    baseUrl: '.',
    paths: {
      '@kit.*': [join(KITS, '@kit.*')],
      '@ohos.*': [join(API, '@ohos.*')]
    },
    types: []
  },
  files: staged.map((p) => relative(sandbox, p).replace(/\\/g, '/'))
};
writeFileSync(join(sandbox, 'tsconfig.json'), JSON.stringify(tsconfig, null, 2), 'utf8');

const ts = createRequire(import.meta.url);
let tsLib = null;
try {
  tsLib = ts(TSC.replace(/[\\/]lib[\\/]tsc\.js$/, ''));
} catch (e) {
  tsLib = null;
}

/** 读 git 对象（HEAD 版本的文件内容）；读不到返回 null */
function gitShow(spec) {
  try {
    return execFileSync('git', ['show', spec], { encoding: 'utf8', cwd: appRoot, maxBuffer: 16 * 1024 * 1024 });
  } catch (e) {
    return null;
  }
}

let failures = 0;

/**
 * 括号/引号配平检查（跳过注释与字符串内容）。
 * @returns null = 配平；否则返回人类可读的问题描述。
 */
function balanceCheck(src) {
  const stack = [];
  const pairs = { '}': '{', ')': '(', ']': '[' };
  let line = 1;
  let i = 0;
  const n = src.length;
  while (i < n) {
    const ch = src.charAt(i);
    if (ch === '\n') { line++; i++; continue; }
    if (ch === '/' && src.charAt(i + 1) === '/') {
      while (i < n && src.charAt(i) !== '\n') { i++; }
      continue;
    }
    if (ch === '/' && src.charAt(i + 1) === '*') {
      i += 2;
      while (i < n && !(src.charAt(i) === '*' && src.charAt(i + 1) === '/')) {
        if (src.charAt(i) === '\n') { line++; }
        i++;
      }
      i += 2;
      continue;
    }
    if (ch === '"' || ch === '\'' || ch === '`') {
      const quote = ch;
      i++;
      while (i < n) {
        const c = src.charAt(i);
        if (c === '\\') { i += 2; continue; }
        if (c === '\n') { line++; }
        if (c === quote) { i++; break; }
        i++;
      }
      continue;
    }
    if (ch === '{' || ch === '(' || ch === '[') {
      stack.push({ c: ch, line });
      i++;
      continue;
    }
    if (ch === '}' || ch === ')' || ch === ']') {
      const top = stack.pop();
      if (!top || top.c !== pairs[ch]) {
        return `第 ${line} 行出现多余的 ${ch}`;
      }
      i++;
      continue;
    }
    i++;
  }
  if (stack.length > 0) {
    const top = stack[stack.length - 1];
    return `第 ${top.line} 行的 ${top.c} 没有闭合`;
  }
  return null;
}

console.log('===== TunBox 整改期类型校验（仓库文件口径） =====');
console.log('[INFO] 暂存文件: ' + staged.length + ' 个（commons/ + core/）');
console.log('[INFO] tsc: ' + TSC);

// ── A. commons/ + core/ 严格类型检查（只报仓库文件） ─────────────────────
console.log('-----------------------------------------');
console.log('[A] strict tsc --noEmit（诊断只保留仓库文件，SDK d.ts 的自身缺陷忽略）');
let out = '';
let code = 0;
try {
  out = execFileSync(process.execPath, [TSC, '-p', join(sandbox, 'tsconfig.json')],
    { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
} catch (e) {
  code = typeof e.status === 'number' ? e.status : 1;
  out = String(e.stdout || '') + String(e.stderr || '');
}
const lines = out.split('\n').filter((l) => l.trim().length > 0);
const repoErrors = [];
let sdkErrors = 0;
for (const raw of lines) {
  // tsc 的输出是 CRLF：行尾的 \r 会被 `.` 吃掉吗？—— 不会，JS 的 `.` 不匹配 \r，
  // 于是 `(...)$` 匹配不上、整行被当成「无法解析的诊断」误报成仓库错误。
  // 所以这里必须先把行尾 \r 去掉。
  const l = raw.replace(/\r$/, '');
  // tsc 单行格式： path(line,col): error TSxxxx: message
  const m = /^(.*?)\((\d+),(\d+)\): (error|warning) (TS\d+): (.*)$/.exec(l);
  if (!m) {
    if (/error/i.test(l)) {
      repoErrors.push(l);
    }
    continue;
  }
  const file = m[1];
  const abs = resolve(sandbox, file);
  if (abs.startsWith(sandbox)) {
    repoErrors.push(`${relative(sandbox, abs).replace(/\\/g, '/')}:${m[2]}:${m[3]} error ${m[5]}: ${m[6]}`);
  } else {
    sdkErrors++;
  }
}
if (repoErrors.length > 0) {
  failures++;
  console.log('[A] FAIL: 仓库文件类型错误 ' + repoErrors.length + ' 条');
  for (const l of repoErrors.slice(0, 60)) {
    console.log('    ' + l);
  }
  if (repoErrors.length > 60) {
    console.log('    ...（其余 ' + (repoErrors.length - 60) + ' 条省略）');
  }
} else {
  console.log('[A] PASS: 仓库文件 0 类型错误（SDK 自身诊断 ' + sdkErrors + ' 条已忽略）');
}

// ── B. ArkUI 文件（pages/widgets）括号/引号配对检查 ──────────────────────
console.log('-----------------------------------------');
console.log('[B] 配对检查：pages/ widgets/ widget/（ArkUI：struct 不是合法 TS，'
  + '故不做 TS 解析，只查括号/引号是否配平 —— 这正是编辑最容易弄坏的地方）');
console.log('     口径：只报**相对 HEAD 的新增破缺**（HEAD 本身就有的历史怪癖不算本次回归）');
{
  const arkDirs = ['pages', 'widgets', 'widget'].map((d) => join(etsRoot, d)).filter((d) => existsSync(d));
  let checked = 0;
  let bad = 0;
  let preexisting = 0;
  for (const dir of arkDirs) {
    for (const name of readdirSync(dir)) {
      const p = join(dir, name);
      if (!name.endsWith('.ets') || !statSync(p).isFile()) {
        continue;
      }
      const src = readFileSync(p, 'utf8');
      const now = balanceCheck(src);
      if (now === null) {
        checked++;
        continue;
      }
      const old = gitShow('HEAD:./' + relative(appRoot, p).replace(/\\/g, '/'));
      if (old === null) {
        bad++;
        console.log('    [UNBALANCED] ' + name + ' → ' + now + '（新文件）');
      } else if (balanceCheck(old) === null) {
        // HEAD 配平、现在不配平 → 本次改动弄坏了
        bad++;
        console.log('    [REGRESSION] ' + name + ' → ' + now + '（HEAD 版本是配平的）');
      } else {
        preexisting++;
      }
      checked++;
    }
  }
  if (bad === 0) {
    console.log('[B] PASS: ' + checked + ' 个 ArkUI 文件无新增配对破缺'
      + '（历史既有 ' + preexisting + ' 处未计入）');
  } else {
    failures++;
    console.log('[B] FAIL: ' + bad + ' 个 ArkUI 文件出现新的配对破缺');
  }
}

rmSync(sandbox, { recursive: true, force: true });
console.log('-----------------------------------------');
console.log(failures === 0 ? 'RESULT: REPO TYPE/SYNTAX CHECK PASSED' : 'RESULT: REPO TYPE/SYNTAX CHECK FAILED');
process.exit(failures === 0 ? 0 : 1);
