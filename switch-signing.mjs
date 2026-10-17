#!/usr/bin/env node
/**
 * 签名模式切换：debug 证书 ↔ 发布证书（空签名 + sign-nexus-package.ps1）
 *
 * 用法（仓库根 C:\Worker\TunBox 下）：
 *   node switch-signing.mjs          # 交互选择（不带参数时）
 *   node switch-signing.mjs debug    # 写入 debug 签名 → DevEco 里直接 Run 到真机
 *   node switch-signing.mjs release  # 清空签名 → 构建出 unsigned 包，用 sign-nexus-package.ps1 签名
 *   node switch-signing.mjs status   # 只看当前模式
 *
 * 原理：改 TunBox_HarmonyOS/build-profile.json5 的 signingConfigs 段和
 * products 里的 "signingConfig" 引用。debug 材料是 DevEco 托管的加密串
 * （与 git 历史里 test 分支固化的一致），发布签名材料不入库（AGC通用证书目录）。
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createInterface } from 'node:readline';

const here = dirname(fileURLToPath(import.meta.url));
const profile = join(here, 'TunBox_HarmonyOS', 'build-profile.json5');

// debug 材料与 test 分支固化的一致（DevEco 加密串，仅本机 .ohos 下的文件有效）。
// 首行不带缩进（替换点前的缩进保留在原文里），尾行补 eol+缩进对齐 "products"。
const DEBUG_LINES = [
  '"signingConfigs": [',
  '      {',
  '        "name": "default",',
  '        "type": "HarmonyOS",',
  '        "material": {',
  '          "certpath": "C:\\\\Users\\\\Administrator\\\\.ohos\\\\config\\\\default_TunBox_HarmonyOS_dxKCNw3ssq7dB3_GqPmpFO39lRyYOC8zNAj-A_ubn-Y=.cer",',
  '          "keyAlias": "debugKey",',
  '          "keyPassword": "0000001B7AAF62F08F00E9DF5C1132E321DDB58AD426AB2E5FA888BD087977DF95773DB41EBAC65EF70C7F",',
  '          "profile": "C:\\\\Users\\\\Administrator\\\\.ohos\\\\config\\\\default_TunBox_HarmonyOS_dxKCNw3ssq7dB3_GqPmpFO39lRyYOC8zNAj-A_ubn-Y=.p7b",',
  '          "signAlg": "SHA256withECDSA",',
  '          "storeFile": "C:\\\\Users\\\\Administrator\\\\.ohos\\\\config\\\\default_TunBox_HarmonyOS_dxKCNw3ssq7dB3_GqPmpFO39lRyYOC8zNAj-A_ubn-Y=.p12",',
  '          "storePassword": "0000001BCE3C344DA55B022C78AB04AD95E2A78F45C181994993FF8A2BBB9592FAD891F0A032A1A85D13AA"',
  '        }',
  '      }',
  '    ],'
];

const RELEASE_LINES = ['"signingConfigs": [],'];

function currentMode(text) {
  if (text.includes('debugKey')) return 'debug';
  if (text.includes('"signingConfigs": []')) return 'release';
  return 'unknown';
}

function switchTo(text, mode) {
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const sIdx = text.indexOf('"signingConfigs"');
  const pIdx = text.indexOf('"products"');
  if (sIdx < 0 || pIdx < 0 || pIdx < sIdx) {
    throw new Error('build-profile.json5 结构不符合预期（找不到 signingConfigs/products 段）');
  }
  // 归一化 "signingConfigs" 行缩进为 4 空格（替换点前可能有历史坏缩进）
  const lineStart = text.lastIndexOf('\n', sIdx) + 1;
  const lines = mode === 'debug' ? DEBUG_LINES : RELEASE_LINES;
  const block = lines.join(eol) + eol + '    ';
  text = text.slice(0, lineStart) + '    ' + block + text.slice(pIdx);
  // products 里的 "signingConfig" 引用：debug 要有，release 要没有
  const hasRef = /"signingConfig"\s*:/.test(text);
  if (mode === 'debug' && !hasRef) {
    // 默认 product 的 "runtimeOS" 行后补引用（容忍历史残留的尾逗号）
    const m = text.match(/("runtimeOS": "HarmonyOS"),?(\r?\n)(\s*)\}/);
    if (!m) throw new Error('找不到 products 里的 runtimeOS 行，无法补 signingConfig 引用');
    text = text.replace(m[0], `${m[1]},${m[2]}${m[3]}"signingConfig": "default"${m[2]}${m[3]}}`);
  }
  if (mode === 'release' && hasRef) {
    // 连同行与其后缩进一起移除，不留空行也不留尾逗号
    text = text.replace(/("runtimeOS": "HarmonyOS"),(\r?\n\s*)"signingConfig"\s*:\s*"default"/, '$1');
  }
  // 清掉历史遗留的纯空白行（紧贴 product 闭合大括号前）
  text = text.replace(/\r?\n[ \t]+(?=\r?\n[ \t]*\})/g, '');
  return text;
}

async function main() {
  let text = readFileSync(profile, 'utf8');
  const cur = currentMode(text);
  const arg = (process.argv[2] || '').trim().toLowerCase();

  if (arg === 'status' || (!arg && !process.stdin.isTTY)) {
    console.log(`当前签名模式: ${cur}`);
    if (arg === 'status') return;
  }

  let mode = arg;
  if (!['debug', 'release'].includes(mode)) {
    console.log(`当前签名模式: ${cur}`);
    console.log('选择签名模式:');
    console.log('  1) debug   —— DevEco 里直接 Run 到真机（调试证书）');
    console.log('  2) release —— 构建发布包（空签名，走 sign-nexus-package.ps1）');
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    mode = await new Promise((resolve) => {
      rl.question('输入 1 或 2: ', (ans) => {
        rl.close();
        resolve(ans.trim() === '1' ? 'debug' : ans.trim() === '2' ? 'release' : '');
      });
    });
    if (!mode) {
      console.log('未选择，退出（未做任何修改）。');
      return;
    }
  }

  if (mode === cur) {
    // 幂等：模式相同时也重写一遍，把历史遗留的坏格式（塌缩行/尾逗号）归一化
    const before = text;
    text = switchTo(text, mode);
    if (text === before) {
      console.log(`已经是 ${mode} 模式，无需切换。`);
      return;
    }
    writeFileSync(profile, text, 'utf8');
    console.log(`已是 ${mode} 模式，但格式已归一化（修复塌缩行/尾逗号）。`);
    return;
  }
  text = switchTo(text, mode);
  writeFileSync(profile, text, 'utf8');

  // 落盘复核
  const after = readFileSync(profile, 'utf8');
  const afterMode = currentMode(after);
  if (afterMode !== mode) {
    throw new Error(`切换后复核失败：期望 ${mode}，实际 ${afterMode}（未提交任何 git 变更前请检查）`);
  }
  console.log(`已切换到 ${mode} 模式。`);
  if (mode === 'debug') {
    console.log('→ DevEco 里直接 Run 即可装到真机（entry-default-signed.hap 由命令行构建时同样带调试签名）。');
  } else {
    console.log('→ 命令行构建产出 unsigned 包；发布签名走仓库根 sign-nexus-package.ps1（需要 NEXUS_KEY_PASSWORD）。');
  }
}

main().catch((e) => {
  console.error(`[switch-signing] ${e.message}`);
  process.exit(1);
});
