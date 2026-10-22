#!/usr/bin/env node
/**
 * 订阅转换自检（LocalSubConverter）—— 纯逻辑真跑 + 真实内核判定。
 *
 * 覆盖：
 *   [1] 单条分享链接 → 生成 mihomo 配置（proxies + PROXY 组 + MATCH）
 *   [2] 多行链接（一行一条，含空行/注释）→ 节点数与行数一致
 *   [3] 整体 base64 的链接列表 → 能解出来
 *   [4] Clash 输入 → 明确拒绝并给「直接导入」提示（不做二次转换）
 *   [5] 乱码 / 空串 → 可读失败原因，不抛异常
 *   [6] 本地伪链接：isLocalUrl / idOf / urlOf 往返一致
 *   [7] 生成的配置交给**真实内核** `mihomo -t` 判（找不到内核则跳过）
 *
 * 为什么要有这一套：转换器是「用户输入什么就生成什么」的组件 —— 一旦生成的 YAML
 * 不合法，用户表现为「导入了订阅但连不上」，而且错误在解析层看不出来（内核整份拒载）。
 * 所以必须有真实内核判定这一关。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

// 生成链里有 enum（ProxyNodeType），Node 的类型剥离不支持 enum ⇒ 自带旗重启一次，
// 保证「node scripts/verify-local-sub-convert.mjs」直接可跑
if (!process.execArgv.includes('--experimental-transform-types')
  && process.env.TUNBOX_LOCALSUB_CHILD !== '1') {
  const res = spawnSync(
    process.execPath,
    ['--experimental-transform-types', '--no-warnings', fileURLToPath(import.meta.url)],
    { stdio: 'inherit', env: { ...process.env, TUNBOX_LOCALSUB_CHILD: '1' } },
  );
  process.exit(res.status === null ? 1 : res.status);
}

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const genDir = path.join(root, 'tools/true-chain-harness/generated');
const G = (name) => pathToFileURL(path.join(genDir, name)).href;

let passed = 0;
const fails = [];
function ok(cond, label, detail = '') {
  if (cond) {
    passed++;
    console.log(`  ✅ ${label}`);
  } else {
    fails.push(label);
    console.log(`  ❌ ${label}${detail ? ' — ' + detail : ''}`);
  }
}

console.log('订阅转换自检（LocalSubConverter · 真跑真源码）');

// ── 前置：影子副本必须包含本模块 ────────────────────────────────────────
if (!fs.existsSync(path.join(genDir, 'LocalSubConverter.ts'))) {
  console.log('  ❌ 缺少 tools/true-chain-harness/generated/LocalSubConverter.ts');
  console.log('     先跑：node tools/true-chain-harness/prepare.mjs');
  process.exit(1);
}
const mod = await import(G('LocalSubConverter.ts'));
const { LocalSubConverter } = mod;

const VLESS = 'vless://11111111-2222-4333-8444-555555555555@1.2.3.4:443'
  + '?encryption=none&security=tls&sni=example.com&type=ws&path=%2Fws#%E9%A6%99%E6%B8%AF-01';
const TROJAN = 'trojan://pass123@5.6.7.8:8443?sni=example.org#%E6%97%A5%E6%9C%AC-02';

// ── [1] 单条链接 ────────────────────────────────────────────────────────
console.log('\n[1] 单条分享链接');
{
  const out = LocalSubConverter.convert(VLESS, '测试');
  ok(out.ok, '单条 vless 链接转换成功', out.reason);
  ok(out.count === 1, `节点数 = 1（实际 ${out.count}）`);
  ok(/^proxies:/m.test(out.yaml), 'YAML 含 proxies: 段');
  ok(/- name: "PROXY"/.test(out.yaml), 'YAML 含 PROXY 选择组');
  ok(/- MATCH,PROXY/.test(out.yaml), 'YAML 含 MATCH,PROXY 兜底');
  ok(out.yaml.includes('香港-01'), '节点名按 fragment 解码保留中文');
}

// ── [2] 多行链接 ────────────────────────────────────────────────────────
console.log('\n[2] 多行链接（含空行与注释）');
{
  const body = ['# 我的节点', '', VLESS, '', TROJAN, '   ', '# end'].join('\n');
  const out = LocalSubConverter.convert(body, '');
  ok(out.ok, '多行转换成功', out.reason);
  ok(out.count === 2, `节点数 = 2（实际 ${out.count}）`);
  ok(out.kind === 'links', `识别形态 = links（实际 ${out.kind}）`);
}

// ── [3] 整体 base64 链接列表 ────────────────────────────────────────────
console.log('\n[3] 整体 base64 的链接列表');
{
  const raw = [VLESS, TROJAN].join('\n');
  const b64 = Buffer.from(raw, 'utf8').toString('base64');
  const out = LocalSubConverter.convert(b64, '');
  ok(out.ok, 'base64 链接列表转换成功', out.reason);
  ok(out.count === 2, `节点数 = 2（实际 ${out.count}）`);
  ok(out.kind === 'base64', `识别形态 = base64（实际 ${out.kind}）`);
}

// ── [4] 已经是 Clash ────────────────────────────────────────────────────
console.log('\n[4] 已经是 Clash 配置');
{
  const clash = 'proxies:\n  - name: "a"\n    type: ss\n    server: 1.1.1.1\n'
    + '    port: 443\n    cipher: aes-128-gcm\n    password: pw\n';
  const out = LocalSubConverter.convert(clash, '');
  ok(!out.ok, 'Clash 输入不重复转换（ok=false）');
  ok(out.kind === 'clash', `识别形态 = clash（实际 ${out.kind}）`);
  ok(out.reason.includes('直接'), '失败原因指引「直接导入」', out.reason);
}

// ── [5] 乱码 / 空串 ─────────────────────────────────────────────────────
console.log('\n[5] 无效输入');
{
  const empty = LocalSubConverter.convert('   ', '');
  ok(!empty.ok && empty.kind === 'empty', '空串判定为 empty');
  const junk = LocalSubConverter.convert('这不是链接，也不是 base64', '');
  ok(!junk.ok && junk.kind === 'unknown', '乱码判定为 unknown');
  ok(junk.reason.length > 0, '给出可读原因', junk.reason);
}

// ── [6] 本地伪链接往返 ──────────────────────────────────────────────────
console.log('\n[6] 本地伪链接（127.0.0.1）');
{
  const url = LocalSubConverter.urlOf('abc123def456');
  ok(LocalSubConverter.isLocalUrl(url), `isLocalUrl(${url}) = true`);
  ok(LocalSubConverter.idOf(url) === 'abc123def456', 'idOf 能取回 id');
  ok(!LocalSubConverter.isLocalUrl('https://example.com/x.yaml'), '普通订阅链接不会被误判');
  ok(LocalSubConverter.idOf('http://127.0.0.1:65530/localsub/../x.yaml') === '',
    '路径穿越/非法 id 被拒');
}

// ── [7] 真实内核判定 ────────────────────────────────────────────────────
console.log('\n[7] 真实内核 mihomo -t 判定生成的配置');
{
  let kernel = '';
  const buildRoot = path.join(root, '..', 'mihomo-build');
  if (fs.existsSync(buildRoot)) {
    for (const d of fs.readdirSync(buildRoot)) {
      const cand = path.join(buildRoot, d, 'mihomo.exe');
      if (fs.existsSync(cand)) {
        kernel = cand;
        break;
      }
    }
  }
  if (kernel.length === 0) {
    console.log('  ⏭️  未找到 mihomo.exe，跳过真实内核判定');
  } else {
    const out = LocalSubConverter.convert([VLESS, TROJAN].join('\n'), '');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'localsub-k-'));
    const cfg = path.join(dir, 'c.yaml');
    // 补最小骨架：订阅正文只给节点，连接时由生成器补 DNS/TUN
    const full = 'mixed-port: 17898\nmode: rule\n' + out.yaml;
    fs.writeFileSync(cfg, full, 'utf8');
    let log = '';
    let code = 0;
    try {
      log = execFileSync(kernel, ['-t', '-d', dir, '-f', cfg], { encoding: 'utf8' });
    } catch (e) {
      log = String((e.stdout || '') + (e.stderr || '') + (e.message || ''));
      code = e.status === undefined ? 1 : e.status;
    }
    ok(code === 0 && /test is successful/.test(log), '真实内核接受转换产物',
      code === 0 ? '' : log.split('\n').slice(0, 4).join(' | '));
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

console.log(`\n${passed} passed, ${fails.length} failed`);
if (fails.length > 0) {
  console.log('失败：' + fails.join(' | '));
  process.exit(1);
}
