// tools/true-parser-harness/verify-rules-emission.mjs
// 本地关卡：用真实 YamlMerger.ts（ArkTS 源码转换）+ 真实 ClashConfigGenerator 的
// normalizeProviderBlock / isValidUserRuleLine（grab 自 .ets 源码），按生成器的
// 发射流程产出 rule-providers + rules 段，拼进真机拉回的完整配置，交给 python
// yaml.safe_load 验证 —— 上真机前先把「生成的配置 YAML 合法」钉死。
//
// 运行: node tools/true-parser-harness/verify-rules-emission.mjs <订阅yaml> <真机配置>
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const { YamlMerger } = await import(pathToFileURL(join(here, 'YamlMerger.ts')).href);

const subPath = process.argv[2];
const baseCfgPath = process.argv[3];
const rawSub = readFileSync(subPath, 'utf8');
const baseCfg = readFileSync(baseCfgPath, 'utf8');

// ---- 与 ClashConfigGenerator 逐字同逻辑的两个 static（纯 JS 内置；生成器源码若改动需同步）----
function normalizeProviderBlock(rawLines) {
  const out = [];
  for (const raw of rawLines) {
    const line = raw.replace(/\t/g, '  ').replace(/\r$/, '');
    const t = line.trim();
    if (t.length === 0 || t.startsWith('#')) continue;
    const m = t.match(/^([A-Za-z0-9_-]+):\s*$/);
    if (m !== null) out.push('  ' + t);
    else out.push('    ' + t);
  }
  return out;
}

function isValidUserRuleLine(rule, providerNames, groupTargets) {
  const text = rule.trim();
  if (text.length === 0 || text.length > 1024 || text.includes('\n') || text.includes('\r')) return false;
  const parts = [];
  for (const p of text.split(',')) {
    const t = p.trim();
    if (t.length > 0) parts.push(t);
  }
  if (parts.length < 2) return false;
  let policy = parts[parts.length - 1];
  if (policy.toUpperCase() === 'NO-RESOLVE' && parts.length >= 3) policy = parts[parts.length - 2];
  if (!groupTargets.has(policy)) return false;
  const type = parts[0].toUpperCase();
  if (type === 'RULE-SET') return parts.length >= 3 && providerNames.has(parts[1]);
  return true;
}

// 覆盖层 proxy-groups 解析（与 ClashConfigGenerator.parseOverrideProxyGroups 同逻辑）
function unquoteScalar(v) {
  let s = v.trim();
  if (s.length >= 2 && ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'")))) {
    s = s.slice(1, -1).trim();
  }
  return s;
}

function parseOverrideProxyGroups(section) {
  const out = [];
  const seen = new Set();
  let cur = null;
  let inProxies = false;
  for (const rawLine of section.split('\n')) {
    const line = rawLine.endsWith(String.fromCharCode(13)) ? rawLine.slice(0, -1) : rawLine;
    const t = line.trim();
    if (t.length === 0 || t.startsWith('#')) continue;
    const m = t.match(/^-\s+name:\s*(.+)$/);
    if (m !== null) {
      if (cur !== null) { out.push(cur); cur = null; }
      const name = unquoteScalar(m[1]);
      if (name.length === 0 || name === 'PROXY' || seen.has(name)) continue;
      cur = { name, type: '', members: [], url: '', interval: 0, tolerance: 0, expectedStatus: '' };
      seen.add(name);
      inProxies = false;
      continue;
    }
    if (cur === null) continue;
    if (t === 'proxies:' || t.startsWith('proxies:')) { inProxies = true; continue; }
    if (t.startsWith('- ') && inProxies) {
      const mem = unquoteScalar(t.slice(2));
      if (mem.length > 0 && !cur.members.includes(mem)) cur.members.push(mem);
      continue;
    }
    if (t.startsWith('- ')) continue;
    inProxies = false;
    const ci = t.indexOf(':');
    if (ci <= 0) continue;
    const key = t.slice(0, ci).trim().toLowerCase();
    const value = unquoteScalar(t.slice(ci + 1));
    if (key === 'type') cur.type = value.toLowerCase();
    else if (key === 'url') cur.url = value;
    else if (key === 'interval') cur.interval = Math.floor(Number(value)) || 0;
    else if (key === 'tolerance') cur.tolerance = Math.floor(Number(value)) || 0;
    else if (key === 'expected-status') cur.expectedStatus = value;
  }
  if (cur !== null) out.push(cur);
  return out;
}

// ---- 复刻生成器发射流程 ----
// 设备状态模拟：订阅 yaml（用户提供，含 rules+rule-providers）；覆盖层 = 真机拉回配置里的
// rule-providers 原文（用户粘贴进覆盖层的部分）；customRuleSets/单条规则 = 空。
// 基座无覆盖层标记时（纯真机配置）覆盖层按空处理（与 generate() 的缺失语义一致），
// 避免把整份配置体误当覆盖层重复解析/发射。
const overrideMarkerIdx = baseCfg.indexOf('# ---- user override (P2) ----');
const overrideText = overrideMarkerIdx >= 0 ? baseCfg.slice(overrideMarkerIdx + 30).trim() : '';

// 1) 覆盖层预解析（与 generate() 同逻辑）
let overrideRuleLines = [];
let overrideProviderLines = [];
let overrideGroups = [];
let overrideBody = '';
{
  const orules = YamlMerger.extractSection(overrideText, 'rules').trim();
  if (orules.length > 0) {
    for (const line of orules.split('\n')) {
      const t = line.trim();
      if (t.length === 0 || t.startsWith('#') || !t.startsWith('- ')) continue;
      overrideRuleLines.push(t.substring(2).trim());
    }
  }
  const oprovs = YamlMerger.extractSection(overrideText, 'rule-providers').trim();
  if (oprovs.length > 0) {
    for (const line of oprovs.split('\n')) {
      const t = line.trim();
      if (t.length === 0 || t.startsWith('#')) continue;
      overrideProviderLines.push(line);
    }
  }
  // 覆盖层自定义 proxy-groups 同样提取（与 generate() 新语义一致）
  overrideGroups = parseOverrideProxyGroups(YamlMerger.extractSection(overrideText, 'proxy-groups').trim());
  overrideBody = (overrideRuleLines.length > 0 || overrideProviderLines.length > 0 || overrideGroups.length > 0)
    ? YamlMerger.removeSection(YamlMerger.removeSection(
      YamlMerger.removeSection(overrideText, 'rules'), 'rule-providers'), 'proxy-groups').trim()
    : overrideText;
}

// 2) 订阅自带 rules/rule-providers（与 SubscriptionService.applyRulesSections 同逻辑）
const subRulesSection = YamlMerger.extractSection(rawSub, 'rules').trim();
const subProvidersSection = YamlMerger.extractSection(rawSub, 'rule-providers').trim();
const subscriptionRules = subRulesSection.split('\n')
  .map(l => {
    // 与 SubscriptionService.subscriptionRulesLines 同逻辑：剥掉 yaml 序列项 "- " 前缀，
    // 否则外层再加一层会变成 "- - RULE"（嵌套 seq），内核报 cannot unmarshal !!seq 拒载。
    let t = l.trim();
    if (t.startsWith('- ')) t = t.substring(2).trim();
    return t;
  })
  .filter(l => l.length > 0 && !l.startsWith('#') && !l.startsWith('- '));

// 3) provider 单一合并段（与 generate() 同逻辑：hyper 关、customRuleSets 空）
const emittedProviderNames = new Set();
const providerEntryLines = [];
for (const line of (subProvidersSection.length > 0
  ? normalizeProviderBlock(subProvidersSection.split('\n')) : [])) {
  providerEntryLines.push(line);
}
for (const line of (overrideProviderLines.length > 0 ? normalizeProviderBlock(overrideProviderLines) : [])) {
  providerEntryLines.push(line);
}
const finalProviderLines = [];
for (const line of providerEntryLines) {
  const m = line.match(/^  ([A-Za-z0-9_-]+):$/);
  if (m !== null) {
    if (emittedProviderNames.has(m[1])) continue;
    emittedProviderNames.add(m[1]);
  }
  finalProviderLines.push(line);
}

// 4) rules 段（订阅 rules → 覆盖层 rules；组目标含订阅组 + 覆盖层组 + 内置）
const groupNames = new Set(['DIRECT', 'PROXY', 'REJECT', 'REJECT-DROP', 'PASS', 'GLOBAL', 'COMPATIBLE']);
for (const g of parseOverrideProxyGroups(YamlMerger.extractSection(rawSub, 'proxy-groups').trim())) {
  groupNames.add(g.name);
}
for (const g of overrideGroups) {
  groupNames.add(g.name);
}
const ruleLines = [];
let skipped = 0;
// 与生成器一致：metadb 缺失时（useGeoip=false）订阅/覆盖层 GEOIP 规则同降级。
// 传 USE_GEOIP=false 环境变量可模拟 metadb 缺失场景（默认 true）。
const useGeoip = process.env.USE_GEOIP !== 'false';
for (const ruleLine of [...subscriptionRules, ...overrideRuleLines]) {
  if (!useGeoip && ruleLine.toUpperCase().startsWith('GEOIP,')) { skipped++; continue; }
  if (isValidUserRuleLine(ruleLine, emittedProviderNames, groupNames)) ruleLines.push(`  - ${ruleLine}`);
  else skipped++;
}

// 5) 拼装完整配置：替换基座配置的 rules/override 段；覆盖层组聚合进 proxy-groups
const lines = baseCfg.split('\n');
if (overrideGroups.length > 0) {
  const pgIdx = lines.findIndex(l => l.trim() === 'proxy-groups:');
  let pgEnd = lines.length;
  for (let i = pgIdx + 1; i < lines.length; i++) {
    if (!lines[i].startsWith(' ') && !lines[i].startsWith('\t') && lines[i].trim().length > 0
      && !lines[i].trim().startsWith('- ') && !lines[i].trim().startsWith('#')) { pgEnd = i; break; }
  }
  const block = [];
  for (const g of overrideGroups) {
    block.push(`  - name: "${g.name}"`);
    block.push(`    type: ${g.type.length > 0 ? g.type : 'select'}`);
    const isLatencyType = g.type === 'url-test' || g.type === 'fallback' || g.type === 'load-balance';
    if (isLatencyType && g.url.length > 0) block.push(`    url: "${g.url}"`);
    if (isLatencyType && g.interval > 0) block.push(`    interval: ${g.interval}`);
    if (g.tolerance > 0) block.push(`    tolerance: ${g.tolerance}`);
    if (g.expectedStatus.length > 0) block.push(`    expected-status: "${g.expectedStatus}"`);
    block.push('    proxies:');
    for (const mem of g.members) block.push(`      - "${mem}"`);
  }
  lines.splice(pgEnd, 0, ...block);
}
const rulesIdx = lines.findIndex(l => l.trim() === 'rules:');
let endIdx = lines.length;
for (let i = rulesIdx + 1; i < lines.length; i++) {
  if (!lines[i].startsWith(' ') && !lines[i].startsWith('\t') && lines[i].trim().length > 0
    && !lines[i].trim().startsWith('- ') && !lines[i].trim().startsWith('#')) { endIdx = i; break; }
}
const head = lines.slice(0, rulesIdx);
const out = [...head];
if (finalProviderLines.length > 0) {
  out.push('', 'rule-providers:', ...finalProviderLines);
}
out.push('', 'rules:', ...ruleLines, '', '  - MATCH,PROXY  # baseline tail (模拟)');
if (overrideBody.length > 0) {
  out.push('', '# ---- user override (P2) ----', overrideBody);
}
const finalCfg = out.join('\n');
writeFileSync('C:/Users/Administrator/tmp/emitted-config.yaml', finalCfg);
console.log(`providers=${finalProviderLines.length} rules=${ruleLines.length} skipped=${skipped} overrideTail=${overrideBody.length} totalLines=${out.length}`);
console.log('WROTE C:/Users/Administrator/tmp/emitted-config.yaml');
