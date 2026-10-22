#!/usr/bin/env node
/**
 * FlClash 同构验证：订阅原文 + overlay 合并 → 真实内核接受。
 *
 * 覆盖：
 *   [1] ProfileConfigMerger：overlay 的运行期键保留、原文 proxies/proxy-groups/rules 接管
 *   [2] 原文显式 dns（enable: true）整段覆盖 overlay dns（FlClash isEnableDns 语义）
 *   [3] 原文未启 dns 时保留 overlay dns
 *   [4] rules 顺序：overlay 在前、原文在后（FlClash appendRules）
 *   [5] 原文的 tun / mixed-port / external-controller 不得外泄（被 overlay 覆盖）
 *   [6] 合并结果交给**真实 mihomo** `-t` 判定（找不到内核则跳过并说明）
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

if (!process.execArgv.includes('--experimental-transform-types')
  && process.env.TUNBOX_FLC_PROFILE_CHILD !== '1') {
  const res = spawnSync(
    process.execPath,
    ['--experimental-transform-types', '--no-warnings', fileURLToPath(import.meta.url)],
    { stdio: 'inherit', env: { ...process.env, TUNBOX_FLC_PROFILE_CHILD: '1' } },
  );
  process.exit(res.status === null ? 1 : res.status);
}

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const genDir = path.join(root, 'tools/true-chain-harness/generated');
const G = (name) => pathToFileURL(path.join(genDir, name)).href;

const { ProfileConfigMerger } = await import(G('ProfileConfigMerger.ts'));

let failed = 0;
const ok = (cond, label, detail = '') => {
  if (cond) {
    console.log(`  ok   ${label}`);
  } else {
    failed++;
    console.log(`  FAIL ${label}${detail ? ` — ${detail}` : ''}`);
  }
};

console.log('[1] merge：overlay 运行期键 + 原文代理段');
const overlay = `mixed-port: 7890
external-controller: 127.0.0.1:9090
secret: "s3cret"
mode: rule
log-level: warning
ipv6: true
unified-delay: true
tcp-concurrent: true
dns:
  enable: true
  enhanced-mode: redir-host
  nameserver:
    - 223.5.5.5
tun:
  enable: true
  stack: gvisor
rules:
  - DOMAIN-SUFFIX,local,DIRECT
  - MATCH,PROXY
`;
const profile = `mixed-port: 1234
external-controller: 0.0.0.0:9999
tun:
  enable: true
  stack: system
proxies:
  - name: A
    type: ss
    server: a.example.com
    port: 443
    cipher: aes-128-gcm
    password: p
  - name: B
    type: trojan
    server: b.example.com
    port: 443
    password: p
    sni: b.example.com
proxy-groups:
  - name: 🔰 选择节点
    type: select
    proxies: [A, B]
  - name: ♻️ 自动选择
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 300
    proxies: [A, B]
rules:
  - DOMAIN-SUFFIX,google.com,🔰 选择节点
  - MATCH,🔰 选择节点
`;
const r = ProfileConfigMerger.merge(overlay, profile);
ok(r.ok, 'merge 成功');
ok(r.profileProxyItems === 2, '原文节点条目数 = 2', String(r.profileProxyItems));
ok(/^mixed-port: 7890$/m.test(r.yaml), 'overlay mixed-port 保留');
ok(!/1234/.test(r.yaml), '原文 mixed-port 未外泄');
ok(!/0\.0\.0\.0:9999/.test(r.yaml), '原文 external-controller 未外泄');
ok(/stack: gvisor/.test(r.yaml) && !/stack: system/.test(r.yaml), 'overlay tun.stack 优先');
ok(/name: 🔰 选择节点/.test(r.yaml), '原文组进入配置');
ok(/type: url-test/.test(r.yaml), '原文 url-test 组进入配置');

const rulesIdx = r.yaml.indexOf('rules:');
const rulesBlock = r.yaml.slice(rulesIdx);
const localIdx = rulesBlock.indexOf('DOMAIN-SUFFIX,local,DIRECT');
const googleIdx = rulesBlock.indexOf('DOMAIN-SUFFIX,google.com');
ok(localIdx >= 0 && googleIdx >= 0, '两段 rules 都在');
ok(localIdx < googleIdx, 'rules 顺序：overlay 在前、原文在后', `local=${localIdx} google=${googleIdx}`);

console.log('[2] 原文 dns.enable=true → 整段 dns 用原文');
const profileWithDns = `${profile}dns:
  enable: true
  nameserver:
    - https://doh.example/dns-query
`;
const r2 = ProfileConfigMerger.merge(overlay, profileWithDns);
ok(r2.ok, 'merge 成功(dns)');
ok(/doh\.example\/dns-query/.test(r2.yaml), '原文 dns 生效');
ok(!/223\.5\.5\.5/.test(r2.yaml), 'overlay dns 被原文替换');
ok((r2.yaml.match(/^dns:/gm) || []).length === 1, 'dns 键只出现一次');

console.log('[3] 原文未启 dns → 保留 overlay dns');
const profileNoDns = profile;
const r3 = ProfileConfigMerger.merge(overlay, profileNoDns);
ok(/223\.5\.5\.5/.test(r3.yaml), 'overlay dns 保留');
ok(!/doh\.example/.test(r3.yaml), '没有凭空出现的原文 dns');

console.log('[4] 原文 proxy-providers 段搬入');
const profileProvider = `proxies: []
proxy-groups:
  - name: PROXY
    type: select
    use: [airport]
proxy-providers:
  airport:
    type: http
    url: https://example.com/sub.yaml
    path: ./providers/airport.yaml
    interval: 3600
`;
const r4 = ProfileConfigMerger.merge(overlay, profileProvider);
ok(r4.ok, 'merge 成功(provider)');
ok(/proxy-providers:/.test(r4.yaml), 'proxy-providers 段进入配置');
ok(/use: \[airport\]/.test(r4.yaml), '组的 use 引用保留');

console.log('[5] 原文不是 Clash 配置 → 明确拒绝（不覆盖 overlay）');
const r5 = ProfileConfigMerger.merge(overlay, 'hello world\nrandom text');
ok(!r5.ok, '非法原文被拒');
ok(r5.yaml === '', '拒绝时不产出 yaml');

// ── [6] 真实内核判定 ────────────────────────────────────────────────
console.log('[6] 真实 mihomo -t 判定');
const candidates = [
  process.env.MIHOMO_BIN,
  'C:/Users/Administrator/AppData/Local/hermes/cache/scratch/mh/mihomo-windows-amd64.exe',
  path.join(root, 'scratch/mh/mihomo-windows-amd64.exe'),
].filter(Boolean);
const bin = candidates.find((p) => {
  try { return fs.statSync(p).isFile(); } catch { return false; }
});
if (!bin) {
  console.log('  skip 未找到 mihomo 内核（设 MIHOMO_BIN 后重跑）');
} else {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'flc-merge-'));
  // overlay 已带 external-controller / mixed-port，直接喂内核（重复键会让内核整份拒载）
  const cfg = r.yaml;
  fs.writeFileSync(path.join(dir, 'config.yaml'), cfg, 'utf8');
  try {
    const out = execFileSync(bin, ['-t', '-d', dir, '-f', path.join(dir, 'config.yaml')], { encoding: 'utf8' });
    const pass = /configuration file .* test is successful|test is successful/i.test(out);
    ok(pass, '内核接受合并后的配置', out.trim().split('\n').slice(-3).join(' | '));
    if (!pass) console.log(out);
  } catch (e) {
    ok(false, '内核接受合并后的配置', String(e.stdout || e.message).slice(0, 400));
  }
}

console.log(failed === 0 ? '\nALL PASS' : `\n${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
