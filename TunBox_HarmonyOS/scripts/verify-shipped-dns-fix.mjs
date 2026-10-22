// 校验：DNS 修复是否真的编进了已签名 HAP 里的 abc 字节码。
// 逐文件按字节搜索子串（abc 里保存的是 ArkTS 源码中的字符串字面量）。
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const DEFAULT_HAP = path.join(process.cwd(), 'entry', 'build', 'default', 'outputs', 'default',
  'entry-default-signed.hap');
const hap = process.argv[2] || DEFAULT_HAP;
if (!fs.existsSync(hap)) {
  console.error(`找不到 HAP：${hap}
用法：node scripts/verify-shipped-dns-fix.mjs [entry-default-signed.hap]`
    + '（先在 TunBox_HarmonyOS 下构建，或在仓库根显式传包路径）');
  process.exit(1);
}
const tmp = path.join(process.env.TEMP, 'nxabc-' + Date.now());
fs.mkdirSync(tmp, { recursive: true });
try {
  execFileSync('powershell', [
    '-NoProfile', '-Command',
    `Add-Type -AssemblyName System.IO.Compression.FileSystem;` +
    `[System.IO.Compression.ZipFile]::ExtractToDirectory('${hap}','${tmp}')`
  ]);

  const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap(
    (e) => (e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]));
  const abcs = walk(tmp).filter((f) => f.endsWith('.abc'));
  console.log('abc files: ' + abcs.length);

  const needles = [
    ['tls://223.5.5.5:853', true],
    ['tls://1.12.12.12:853', true],
    ['tls://1.1.1.1:853', true],
    ['direct-nameserver', true],
    ['respect-rules: true', false],
    ['https://1.1.1.1/dns-query', false],
    ['https://8.8.8.8/dns-query', false],
  ];

  let allOk = true;
  for (const [needle, want] of needles) {
    const pat = Buffer.from(needle, 'utf8');
    let found = false;
    for (const f of abcs) {
      const buf = fs.readFileSync(f);
      if (buf.includes(pat)) { found = true; break; }
    }
    const ok = found === want;
    if (!ok) { allOk = false; }
    console.log(
      `${ok ? 'OK  ' : 'BAD '} ${needle.padEnd(26)} ${found ? 'PRESENT' : 'absent '} ` +
      `(expected ${want ? 'present' : 'absent'})`);
  }
  console.log(allOk ? '\nRESULT: DNS fix IS compiled into the shipped HAP'
                    : '\nRESULT: MISMATCH — shipped binary does not match source');
  process.exitCode = allOk ? 0 : 1;
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}