#!/usr/bin/env node
/**
 * 构建配置护栏（E 组）：`build-profile.json5` 不得再提交本机签名材料
 *
 * ## 守的是什么故障（2026-10-19 复盘）
 *
 * 0.4.0 把本机 DevEco「自动生成签名」写进 `build-profile.json5` 的内容提交进了 main：
 * 本机调试证书的绝对路径（`C:\Users\<user>\.ohos\config\…`）+ 加密后的
 * `storePassword` / `keyPassword` 串 + `products[].signingConfig: "default"`。后果三条：
 *
 *   ① 换机 / CI 构建直接失败或签名不匹配（路径与密钥只存在于那台机器）；
 *   ② 凭据类材料入库（即使只是加密串，也不该出现在被 git 跟踪的文件里）；
 *   ③ 与文件内**自己写着**的注释矛盾（注释说「signingConfigs 保持空」，字段却非空），
 *      于是没人再相信这段注释 —— 下一次还会照抄。
 *
 * 本文件被 git 跟踪，签名一律走仓库根 `sign-nexus-package.ps1`（材料在
 * `AGC通用证书` 目录，不入库）。DevEco 自动生成的 signingConfigs **只允许留在本地工作区**，
 * 提交前必须恢复成空数组。
 *
 * ⚠ 已知陷阱（本脚本已处理）：
 *   · Windows 上是 **CRLF 检出**：先 `replace(/\r\n/g, '\n')` 再处理，否则行级断言假阴性。
 *   · 本文件是 **JSON5（含注释）**：断言前必须剥注释再 `JSON.parse`。
 *   · 剥注释也顺带解决一个自相矛盾的陷阱：文件里的注释**正当地**提到了
 *     `signingConfigs` / `signingConfig` 来警告后来者。注释里提不算违规，
 *     只有**真正的字段**才算 —— 所以所有文本扫描都跑在剥注释后的视图上。
 *
 * 用法:
 *   node scripts/verify-build-profile.mjs
 *   node scripts/verify-build-profile.mjs --file <build-profile.json5>
 *   （--file 用于负对照：指向修复前的文件时本脚本**必须失败**）
 *
 * 退出码: 0 = 全部断言通过；1 = 有断言失败（并打印修复指引）
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

function argOf(flag) {
  const i = process.argv.indexOf(flag);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : null;
}

const filePath = argOf('--file')
  ? path.resolve(argOf('--file'))
  : path.resolve(here, '..', 'build-profile.json5');

let pass = 0;
const fails = [];
function ok(name, cond, extra) {
  if (cond) {
    pass += 1;
    console.log(`  ✓ ${name}`);
  } else {
    fails.push(name + (extra ? ` (${extra})` : ''));
    console.log(`  ✗ ${name}${extra ? ` — ${extra}` : ''}`);
  }
}

/** 剥注释（保留字符串内容与原始偏移）。JSON5 的注释在这里必须消失，
 *  否则注释里警告用的 `signingConfigs` 字样会被误判成真实字段。 */
function stripComments(src) {
  const out = src.split('');
  const n = src.length;
  const blank = (from, to) => {
    for (let k = from; k < to && k < n; k += 1) {
      if (out[k] !== '\n') out[k] = ' ';
    }
  };
  let i = 0;
  while (i < n) {
    const c = src[i];
    const d = src[i + 1];
    if (c === '/' && d === '/') {
      const s = i;
      while (i < n && src[i] !== '\n') i += 1;
      blank(s, i);
      continue;
    }
    if (c === '/' && d === '*') {
      const s = i;
      i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i += 1;
      i += 2;
      blank(s, Math.min(i, n));
      continue;
    }
    if (c === '"' || c === "'") {
      const q = c;
      i += 1;
      while (i < n && src[i] !== q) {
        if (src[i] === '\\') i += 1;
        i += 1;
      }
      i += 1;
      continue;
    }
    i += 1;
  }
  return out.join('');
}

console.log('===== build-profile.json5 签名材料护栏（E 组）=====');
console.log(`被测文件: ${filePath}`);
console.log('-----------------------------------------');

if (!fs.existsSync(filePath)) {
  console.log(`  ✗ file.exists — 找不到文件: ${filePath}`);
  console.log('RESULT: BUILD PROFILE CHECKS FAILED');
  process.exit(1);
}

// CRLF 归一：Windows 上是 CRLF 检出。
const raw = fs.readFileSync(filePath, 'utf8').replace(/\r\n/g, '\n');
const code = stripComments(raw);

ok('e.file-exists', true);

// ── 结构层：剥注释后必须仍是合法 JSON（JSON5 的注释是唯一非标准成分）──
let parsed = null;
try {
  parsed = JSON.parse(code);
  ok('e.json-parses', true);
} catch (e) {
  ok('e.json-parses', false, `剥注释后 JSON.parse 失败: ${e.message}`);
}

const app = parsed && typeof parsed === 'object' ? parsed.app : null;

// ── E15-a：signingConfigs 必须是空数组 ────────────────────────────────
// 守 0.4.0 把本机调试证书路径 + 加密口令串提交进 main 的那次事故。
ok('e.signingConfigs-key-exists', app !== null && Object.prototype.hasOwnProperty.call(app, 'signingConfigs'),
  'app.signingConfigs 字段缺失（应显式保留空数组，而不是删字段）');
ok('e.signingConfigs-empty',
  app !== null && Array.isArray(app.signingConfigs) && app.signingConfigs.length === 0,
  app && Array.isArray(app.signingConfigs)
    ? `signingConfigs 有 ${app.signingConfigs.length} 项（必须是 []）`
    : 'signingConfigs 不是数组');

// 文本层兜底：即使 JSON 解析失败也要能拦（负对照走的就是这条路）。
ok('e.signingConfigs-empty-text', /"signingConfigs"\s*:\s*\[\s*\]/.test(code),
  '文本层面找不到 `"signingConfigs": []`');

// ── E15-b：products 里不得出现 "signingConfig" 字段 ────────────────────
// 这个字段一旦存在，构建就会去引用上面的 material 块（路径/口令）。
ok('e.products-no-signingConfig-field',
  app !== null && Array.isArray(app.products)
    && app.products.every((p) => p === null || typeof p !== 'object'
      || !Object.prototype.hasOwnProperty.call(p, 'signingConfig')),
  'products[*] 里仍有 signingConfig 字段（会引用本机证书 material）');
ok('e.products-no-signingConfig-text', !/"signingConfig"\s*:/.test(code),
  '文本层面仍出现 `"signingConfig":` 字段');

// ── E15-c：不得出现本机路径与口令字段 ─────────────────────────────────
// `.ohos\config` = 本机 DevEco 证书目录；换机/CI 上不存在，构建必失败。
ok('e.no-ohos-config-path', !/\.ohos\\+config/.test(code) && !/\.ohos/.test(code),
  '仍出现本机 DevEco 证书目录路径（.ohos\\config）—— 换机/CI 构建必失败');
ok('e.no-storePassword', !/storePassword/.test(code),
  '仍出现 storePassword 字段（凭据材料不得入库）');
ok('e.no-keyPassword', !/keyPassword/.test(code),
  '仍出现 keyPassword 字段（凭据材料不得入库）');
// material 块里还有 certpath / storeFile / keyAlias / signAlg，signingConfigs 为空时都不该存在。
ok('e.no-material-block', !/["']?material["']?\s*:/.test(code),
  '仍出现 material 块（signingConfigs 为空时不该有任何签名材料）');
ok('e.no-certpath', !/certpath/i.test(code) && !/storeFile/.test(code),
  '仍出现 certpath / storeFile（本机证书文件路径）');

// ── 附加：不得留下加密口令串（≥32 位连续十六进制）─────────────────────
// DevEco 的加密口令是长十六进制串，很容易被肉眼漏过；单独拦一道。
ok('e.no-hex-secret', !/\b[0-9A-Fa-f]{32,}\b/.test(code),
  '出现 ≥32 位连续十六进制串（疑似 DevEco 加密口令串）');

// ── 汇总 + 修复指引 ──────────────────────────────────────────────────
console.log('-----------------------------------------');
console.log(`PASSED=${pass}  FAILED=${fails.length}  TOTAL=${pass + fails.length}`);
if (fails.length > 0) {
  for (const f of fails) console.log('  FAIL ' + f);
  console.log('');
  console.log('修复指引（build-profile.json5 被 git 跟踪，签名材料永不入库）：');
  console.log('  1) 把 app.signingConfigs 改回空数组：  "signingConfigs": [],');
  console.log('  2) 删除 products[*] 里的 "signingConfig": "default" 字段');
  console.log('  3) 删除整个 material 块（certpath / storeFile / keyAlias /');
  console.log('     keyPassword / storePassword / profile / signAlg）');
  console.log('  4) DevEco「自动生成签名」写进来的内容只允许留在**本地工作区**，');
  console.log('     提交前必须恢复为空数组（本脚本就是提交前的闸门）');
  console.log('  5) 签名一律走仓库根 sign-nexus-package.ps1，');
  console.log('     材料在 AGC通用证书 目录（不入库）');
  console.log('');
  console.log('  ⚠ 如果你现在是**本地 debug 模式**（想在 DevEco 里 Run 装真机），');
  console.log('    那这个失败是**预期行为**，不是故障：');
  console.log('      开： & C:\\Worker\\TunBox\\switch-signing.ps1 -Mode debug   （本地调试用，勿提交）');
  console.log('      关： & C:\\Worker\\TunBox\\switch-signing.ps1 -Mode release （提交前必须切回来）');
  console.log('    补充：DevEco 里 Run 只会打包 **unsigned** HAP 时，安装必然报');
  console.log('    "error: no signature file. (code:9568320)" —— unsigned 包装不上，必须先切 debug 模式。');
  console.log('RESULT: BUILD PROFILE CHECKS FAILED');
  process.exit(1);
}
console.log('RESULT: ALL BUILD PROFILE CHECKS PASSED');
