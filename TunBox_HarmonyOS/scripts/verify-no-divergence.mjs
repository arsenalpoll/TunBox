#!/usr/bin/env node
/**
 * verify-no-divergence.mjs —— 「单一真源」残留分叉闸门
 *
 * ## 口径（本闸门只认这一条）
 *
 * **一条判定规则只能有一个实现。**
 *
 * - 允许「写入路径」与「渲染路径」各有一份代码（那是两种不同用途，不是分叉）；
 * - 但下面这些**判定规则**一旦有两套实现，就是分叉，必须红：
 *   哪些失败算「节点结论」、什么算「陈旧」、测速地址怎么派生、
 *   节点能不能写进内核代理表、结论落在哪个分片、测速核用哪个端口。
 *
 * ## 与既有闸门的关系
 *
 * - `scripts/verify-config-single-source.mjs` 管「一个生成入口 + 两份 YAML 白名单差异」；
 * - 本闸门管**规则级**分叉（判定表/文案表/阈值/写者/端点口径），两者互补不重叠。
 * - `scripts/verify-legacy-purge.mjs`（LP01–LP15）管「旧实现是否已删除」；
 *   本闸门在旧实现删掉之前就能报「同一规则还有几份实现」，删完即自动转绿。
 *
 * ## 用法
 *
 * ```bash
 * node scripts/verify-no-divergence.mjs              # 验收闸门：有残留分叉即红（exit 1）
 * node scripts/verify-no-divergence.mjs --pending    # 预览：打印残留清单，exit 0
 * node scripts/verify-no-divergence.mjs --self-test  # 负对照：注入分叉必须判红（exit 0/1）
 * ```
 *
 * ## 负对照（--self-test）：每条断言都要证明自己有牙齿
 *
 * 对每条断言依次做三步：
 *  1. 把当前树里**这条断言**的违例修掉 → 该断言必须转绿（证明它不是恒红）；
 *  2. 在临时副本里**注入一处同类分叉** → 该断言必须转红（证明它抓得住）；
 *  3. 临时副本全程不碰工作树。
 *
 * 注入点与断言一一对应（见 `NEGATIVE_CONTROLS`），注入的都是「同一类错误」，
 * 而不是「随便加点垃圾」—— 否则闸门可能只是靠噪声在响。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');

// ── 扫描范围 ────────────────────────────────────────────────────────────────
const SCAN_DIRS = ['entry/src/main/ets', 'scripts'];

/**
 * 白名单（逐条说明理由 —— 白名单本身是「豁免」，必须能被审计）。
 *
 * `scripts/**`：其它闸门脚本里必然出现被禁字面量 —— 它们**就是**用来断言
 * 「代码里不该有这些字面量」的，脚本自身必须把字面量写出来才能扫。
 * 代价：闸门脚本里藏一份真源不会被本闸门发现 —— 这是有意接受的边界，
 * 闸门脚本不是运行时路径，抄错不会影响用户。
 */
const SCRIPTS_WHITELIST_REASON = '闸门脚本自身样板（不是运行时路径）';

const SELF_PATH = 'scripts/verify-no-divergence.mjs';

// ── 断言框架 ────────────────────────────────────────────────────────────────
/** @typedef {{rel:string,line:number,text:string,kind:string}} Violation */

/** 递归列出目录下的文件（相对 root 的 posix 路径）。 */
function listFiles(rootDir, relDir) {
  const abs = path.join(rootDir, relDir);
  const out = [];
  if (!fs.existsSync(abs)) {
    return out;
  }
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (entry.isFile() && (entry.name.endsWith('.ets') || entry.name.endsWith('.mjs'))) {
        out.push(path.relative(rootDir, full).split(path.sep).join('/'));
      }
    }
  };
  walk(abs);
  return out.sort();
}

/**
 * 去掉注释（保留字符串字面量里的内容），并保持行号不变。
 *
 * 为什么必须去注释：本仓库的注释里大量出现「这里以前调过 XXX」这类
 * 调用形态（文档、迁移说明、待删清单），直接 grep 会把注释算成实现。
 */
function stripComments(text) {
  let out = '';
  let i = 0;
  let quote = '';
  while (i < text.length) {
    const ch = text.charAt(i);
    const next = i + 1 < text.length ? text.charAt(i + 1) : '';
    if (quote.length > 0) {
      out += ch;
      if (ch === '\\') {
        if (next.length > 0) {
          out += next;
          i += 2;
          continue;
        }
      } else if (ch === quote) {
        quote = '';
      }
      i++;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === '`') {
      quote = ch;
      out += ch;
      i++;
      continue;
    }
    if (ch === '/' && next === '/') {
      while (i < text.length && text.charAt(i) !== '\n') {
        i++;
      }
      if (i < text.length) {
        out += '\n';
        i++;
      }
      continue;
    }
    if (ch === '/' && next === '*') {
      i += 2;
      while (i < text.length && !(text.charAt(i) === '*' && text.charAt(i + 1) === '/')) {
        if (text.charAt(i) === '\n') {
          out += '\n';
        }
        i++;
      }
      i += 2;
      continue;
    }
    out += ch;
    i++;
  }
  return out;
}

/** 建立扫描上下文。 */
function buildCtx(rootDir) {
  const rels = [];
  for (const dir of SCAN_DIRS) {
    for (const rel of listFiles(rootDir, dir)) {
      rels.push(rel);
    }
  }
  const files = new Map();
  for (const rel of rels) {
    const raw = fs.readFileSync(path.join(rootDir, rel), 'utf8');
    files.set(rel, { raw, code: stripComments(raw) });
  }
  return { rootDir, rels, files };
}

/** 在某文件里找全部命中（行号按去注释后的代码对齐原始行）。 */
function hits(ctx, rel, re) {
  const f = ctx.files.get(rel);
  if (!f) {
    return [];
  }
  const out = [];
  const rx = new RegExp(re.source, re.flags.includes('g') ? re.flags : re.flags + 'g');
  let m = rx.exec(f.code);
  while (m !== null) {
    const line = f.code.slice(0, m.index).split('\n').length;
    const rawLine = f.raw.split('\n')[line - 1] || '';
    out.push({ rel, line, text: rawLine.trim() });
    if (m.index === rx.lastIndex) {
      rx.lastIndex++;
    }
    m = rx.exec(f.code);
  }
  return out;
}

/** 该文件是否属于「闸门脚本样板」白名单。 */
function isScriptSample(rel) {
  return rel.startsWith('scripts/');
}

/**
 * 取某个 static 方法的函数体（粗略：到下一个同缩进的 '}' 为止）。
 *
 * 用途：区分「**派生/转调**（体内调用唯一真源）」与「**自带第二份清单**」。
 */
function methodBody(ctx, rel, signatureRe) {
  const f = ctx.files.get(rel);
  if (!f) {
    return '';
  }
  const m = f.code.match(signatureRe);
  if (!m) {
    return '';
  }
  const rest = f.code.slice(m.index + m[0].length);
  const end = rest.indexOf('\n  }');
  return end < 0 ? rest.slice(0, 600) : rest.slice(0, end);
}

/**
 * 体内是不是**转调**了内核分类表（而不是自带第二份清单）。
 *
 * - 内核分类表本体（LatencyKinds.ets）里的正表：体内引用 `isNonVerdictKind(` 即可；
 * - 其它文件：必须写成 `LatencyProbeKind.isVerdictKind(` / `LatencyProbeKind.isNonVerdictKind(`。
 */
function delegatesToKernel(body, name) {
  if (body.includes(`LatencyProbeKind.${name}(`)) {
    return true;
  }
  if (name === 'isVerdictKind' && body.includes('isNonVerdictKind(')) {
    return true;
  }
  return false;
}

// ── 断言定义 ────────────────────────────────────────────────────────────────
/**
 * 每条断言：
 *  - id       稳定编号（报告与排期按它引用）
 *  - title    一句话说清「什么规则只能有一份」
 *  - rule     为什么这条规则只能有一份（用户可见症状）
 *  - check    (ctx) => Violation[]
 *  - repair   (ctx, v) => void   把一处违例修掉（负对照第 1 步用；默认删整行）
 */
const ASSERTS = [
  {
    id: 'ND01',
    title: '失败分类字面量只能出现在三个真源模块（LatencyKinds 常量 / LatencyProbe 判定 / LatencyStore 渲染）',
    rule: '同一类失败在多个文件各写一遍字面量 → 改一处、别处还是旧话术，'
      + '用户会看到「有的卡片说超时、有的说失败」「未生效」与「内核未就绪」混用。',
    check(ctx) {
      const literals = [
        'switch_failed', 'network_unreachable', 'core_not_ready', 'queue_timeout',
        'port_reachable_only', 'untested', 'unsupported',
      ];
      const allowed = new Set([
        // 三个真源各管一件事：LatencyKinds=分类**常量**（字面量只允许在这里）、
        // LatencyProbe=「什么响应算哪一类」的**判定表**、LatencyStore=**渲染表**。
        'entry/src/main/ets/commons/latency/LatencyKinds.ets',
        'entry/src/main/ets/commons/latency/LatencyProbe.ets',
        'entry/src/main/ets/commons/latency/LatencyStore.ets',
      ]);
      // 在途豁免：settings-ui 正在给 LatencyState.stateText 加 dns_unresolved 行
      // （见 lead 交办「在途」清单②）。它只被允许出现在 LatencyState.ets，
      // 且**不得**再扩散到第三个文件。
      const inFlight = new Map([
        ['entry/src/main/ets/commons/services/LatencyState.ets', new Set(['dns_unresolved'])],
      ]);
      const out = [];
      for (const rel of ctx.rels) {
        if (isScriptSample(rel) || allowed.has(rel)) {
          continue;
        }
        for (const lit of literals) {
          const extra = inFlight.get(rel);
          if (extra && extra.has(lit)) {
            continue;
          }
          for (const h of hits(ctx, rel, new RegExp(`['"\`]${lit}['"\`]`))) {
            out.push({ ...h, kind: `字面量 '${lit}' 出现在第 ${out.length + 1} 份实现里` });
          }
        }
      }
      return out;
    },
  },

  {
    id: 'ND02',
    title: '「算不算节点结论」的判定表只能有一份实现（真源 = LatencyKinds）',
    rule: '两张判定表对同一分类给出相反答案 → 同一轮测速在 live 路径与恢复路径结论相反。',
    check(ctx) {
      const out = [];
      // 2026-10-20 lead 拍板：唯一判定表下沉到**零 import**的内核分类表
      // （LatencyKinds.isNonVerdictKind）；正表 isVerdictKind 只能是它的**派生视图**。
      const kernel = 'entry/src/main/ets/commons/latency/LatencyKinds.ets';
      for (const rel of ctx.rels) {
        if (isScriptSample(rel)) {
          continue;
        }
        // 正表：只允许出现在内核分类表与结论落盘仓，且**必须派生**（不得自带分类清单）
        for (const h of hits(ctx, rel, /static\s+isVerdictKind\s*\(/)) {
          if (rel !== kernel && rel !== 'entry/src/main/ets/commons/latency/LatencyStore.ets') {
            out.push({ ...h, kind: 'isVerdictKind 的第 2 份实现（只能在内核分类表/结论落盘仓）' });
            continue;
          }
          const body = methodBody(ctx, rel, /static\s+isVerdictKind\s*\([^)]*\)\s*:\s*boolean\s*\{/);
          if (!delegatesToKernel(body, 'isVerdictKind')) {
            out.push({ ...h, kind: 'isVerdictKind 必须派生自唯一判定表（不得自带分类清单）' });
          }
        }
        // 反表：真源只允许在内核分类表；别处出现只能是**转调**
        for (const h of hits(ctx, rel, /static\s+isNonVerdictKind\s*\(/)) {
          if (rel === kernel) {
            continue;
          }
          const body = methodBody(ctx, rel, /static\s+isNonVerdictKind\s*\([^)]*\)\s*:\s*boolean\s*\{/);
          if (!delegatesToKernel(body, 'isNonVerdictKind')) {
            out.push({ ...h, kind: 'isNonVerdictKind 的第 2 份实现（必须转调 LatencyProbeKind.isNonVerdictKind）' });
          }
        }
      }
      return out;
    },
  },

  {
    id: 'ND03',
    title: '失败文案表只能有一张（describe / stateText 各一份）',
    rule: '两张文案表 → 同一个失败在节点页与首页显示不同话术。',
    check(ctx) {
      const out = [];
      for (const rel of ctx.rels) {
        if (isScriptSample(rel)) {
          continue;
        }
        const describeOk = rel === 'entry/src/main/ets/commons/latency/LatencyStore.ets';
        const stateTextOk = rel === 'entry/src/main/ets/commons/services/LatencyState.ets';
        for (const h of hits(ctx, rel, /static\s+describe\s*\(/)) {
          if (!describeOk) {
            out.push({ ...h, kind: 'describe 的第 2 份实现' });
          }
        }
        for (const h of hits(ctx, rel, /static\s+stateText\s*\(/)) {
          if (!stateTextOk) {
            out.push({ ...h, kind: 'stateText 的第 2 份实现' });
          }
        }
      }
      return out;
    },
  },

  {
    id: 'ND04',
    title: 'theme / pages 层不得自带失败文案包装',
    rule: '两个 theme 文件各写一份一模一样的话术包装 → 改一处，另一处仍是旧话术。',
    check(ctx) {
      const out = [];
      for (const rel of ctx.rels) {
        if (isScriptSample(rel)) {
          continue;
        }
        if (!rel.startsWith('entry/src/main/ets/theme/') && !rel.startsWith('entry/src/main/ets/pages/')) {
          continue;
        }
        for (const h of hits(ctx, rel, /LatencyPolicy\.stateText\s*\(/)) {
          out.push({ ...h, kind: 'theme/pages 直接调用旧文案表' });
        }
      }
      return out;
    },
  },

  {
    id: 'ND05',
    title: '「结论已陈旧」的阈值只能定义一次',
    rule: '两份阈值 → 「·旧」灰显口径分裂：同一份结论在两处一个说旧一个说新。',
    check(ctx) {
      const out = [];
      // 2026-10-20 lead 拍板：阈值本体下沉到**零 import**的内核分类表
      // （LatencyKinds.STALE_MS）；别处只允许「转调别名」。
      const source = 'entry/src/main/ets/commons/latency/LatencyKinds.ets';
      const defs = [];
      for (const rel of ctx.rels) {
        if (isScriptSample(rel)) {
          continue;
        }
        for (const h of hits(ctx, rel, /static\s+readonly\s+STALE_MS\s*[:=]/)) {
          defs.push(h);
        }
      }
      // 转调别名（`= LatencyProbeKind.STALE_MS`）**不是**第二份定义
      const real = defs.filter((d) => !d.text.includes('LatencyProbeKind.STALE_MS'));
      const files = new Set(real.map((d) => d.rel));
      if (files.size <= 1 && files.has(source)) {
        return out;
      }
      for (const d of real) {
        if (d.rel === source) {
          continue;
        }
        out.push({ ...d, kind: 'STALE_MS 的第 2 份定义' });
      }
      if (!files.has(source)) {
        out.push({
          rel: source,
          line: 1,
          text: '(缺失) 内核分类表未定义 STALE_MS',
          kind: '陈旧阈值的唯一真源缺失',
        });
      }
      return out;
    },
  },

  {
    id: 'ND06',
    title: '测速地址的规则常量只能有一处',
    rule: '两个默认地址常量 → 设置页占位符与实际生效的地址不是同一个，'
      + '用户填的地址在一处被升级、在另一处被原样保留。',
    check(ctx) {
      const out = [];
      const allowed = new Set(['entry/src/main/ets/commons/latency/LatencyTestUrl.ets']);
      /**
       * 逐文件豁免（每条都写清理由 —— 豁免就是「这里不是分叉」）：
       *  - ConnectionOrchestrator.ets：出口连通性自检（checkEgressReachable），
       *    与「节点测速地址」不是同一件事；仍建议改为引用 LatencyTestUrl.DEFAULT_URL，
       *    免得两处默认值各自漂移。
       *  - RawSubscriptionStore.ets：mihomo raw provider 的 health-check url，
       *    是给内核 provider 用的，与 App 自己的测速地址是不同事实。
       *  - LatencyEngine.ets：**在途**（latency-core 正在把 LatencyEngine 接到
       *    LatencyProbe），接线完成后本豁免即可删除。
       */
      const exempt = new Set([
        'entry/src/main/ets/commons/services/ConnectionOrchestrator.ets',
        'entry/src/main/ets/commons/services/RawSubscriptionStore.ets',
        'entry/src/main/ets/commons/services/LatencyEngine.ets',
      ]);
      const re = /['"`][^'"`]*gstatic\.com\/generate_204['"`]|['"`][^'"`]*cp\.cloudflare\.com\/generate_204['"`]/;
      for (const rel of ctx.rels) {
        if (isScriptSample(rel) || allowed.has(rel) || exempt.has(rel)) {
          continue;
        }
        for (const h of hits(ctx, rel, re)) {
          out.push({ ...h, kind: '测速地址规则常量的第 2 份' });
        }
      }
      return out;
    },
  },

  {
    id: 'ND07',
    title: '测速快照（nodeSortSnapshot）的写者唯一：编排器记账必须走 saveNodeSortStats',
    rule: '记账路径再写一次整单快照 → 后写者把测速路径刚写的新结论盖回旧值'
      + '（审计 F2 的机制，只是被包进了分片 API 里）。',
    check(ctx) {
      const out = [];
      const allowed = new Set([
        'entry/src/main/ets/commons/services/SettingsService.ets',
        'entry/src/main/ets/commons/models/AppSettings.ets',
        'entry/src/main/ets/commons/services/NodeSortPersistence.ets',
        'entry/src/main/ets/commons/latency/LatencyStore.ets',
        'entry/src/main/ets/pages/NodeSelectionPage.ets',
        'entry/src/main/ets/pages/HomePage.ets',
      ]);
      for (const rel of ctx.rels) {
        if (isScriptSample(rel) || allowed.has(rel)) {
          continue;
        }
        for (const h of hits(ctx, rel, /nodeSortSnapshot/)) {
          out.push({ ...h, kind: 'nodeSortSnapshot 的第 N 个写者' });
        }
      }
      // 记账路径必须真的走分片入口
      const orch = 'entry/src/main/ets/commons/services/ConnectionOrchestrator.ets';
      const calls = hits(ctx, orch, /SettingsService\.saveNodeSortStats\s*\(/);
      if (calls.length === 0) {
        const any = hits(ctx, orch, /nodeSortSnapshot/);
        if (any.length > 0) {
          out.push({
            rel: orch,
            line: any[0].line,
            text: any[0].text,
            kind: '记账路径未走 SettingsService.saveNodeSortStats()（分片写入口）',
          });
        }
      }
      return out;
    },
  },

  {
    id: 'ND08',
    title: '测速结论的 live 真源唯一：pages/ 不得直接读旧 LatencyController',
    rule: '节点页读旧 Map、首页读新 LatencyStore → 同一节点两处显示不同延迟；'
      + '冷启动恢复时旧 Map 还会盖掉更新的结论。',
    check(ctx) {
      const out = [];
      for (const rel of ctx.rels) {
        if (isScriptSample(rel)) {
          continue;
        }
        if (!rel.startsWith('entry/src/main/ets/pages/')) {
          continue;
        }
        for (const h of hits(ctx, rel, /LatencyController\./)) {
          out.push({ ...h, kind: 'pages 直接读旧结论门面（真源应是 LatencyStore）' });
        }
      }
      return out;
    },
  },

  {
    id: 'ND09',
    title: '测速核的 controller 端点必须用它自己的端口',
    rule: 'YAML 里的 external-controller 用测速核探测到的端口，'
      + '而客户端 setEndpoint 用隧道共享端口 → 探活 401/不可达，整批显示「内核未就绪」。',
    check(ctx) {
      const out = [];
      const orch = 'entry/src/main/ets/commons/services/ConnectionOrchestrator.ets';
      for (const h of hits(ctx, orch, /setEndpoint\(\s*this\.apiPort\s*,\s*this\.testCoreSecret\s*\)/)) {
        out.push({ ...h, kind: '测速核端点用了隧道共享端口 this.apiPort' });
      }
      return out;
    },
  },

  {
    id: 'ND10',
    title: '「节点能不能写进内核代理表」只能有一个判定实现',
    rule: '两份判定 → 诊断里的丢弃计数与实际写进内核的行会漂移。',
    check(ctx) {
      const out = [];
      const gen = 'entry/src/main/ets/commons/services/ClashConfigGenerator.ets';
      // ① ProxyDropReason 只能定义一次
      for (const rel of ctx.rels) {
        if (isScriptSample(rel)) {
          continue;
        }
        for (const h of hits(ctx, rel, /ProxyDropReason\s*\{|export\s+class\s+ProxyDropReason/)) {
          if (rel !== gen) {
            out.push({ ...h, kind: 'ProxyDropReason 的第 2 份定义' });
          }
        }
      }
      // ② proxyYamlLine 必须走 dropReasonFor（不得自己再实现一套）
      const defs = hits(ctx, gen, /static\s+proxyYamlLine\s*\(/);
      const body = ctx.files.get(gen).code;
      for (const d of defs) {
        const start = body.split('\n').slice(0, d.line).join('\n').length;
        const window = body.slice(start, start + 600);
        if (!/dropReasonFor\s*\(/.test(window)) {
          out.push({ ...d, kind: 'proxyYamlLine 没有走 dropReasonFor（出现第 2 套判定）' });
        }
      }
      // ③ 全仓不得有第二个 proxyYamlLine 实现
      for (const rel of ctx.rels) {
        if (isScriptSample(rel) || rel === gen) {
          continue;
        }
        for (const h of hits(ctx, rel, /static\s+proxyYamlLine\s*\(/)) {
          out.push({ ...h, kind: 'proxyYamlLine 的第 2 份实现' });
        }
      }
      return out;
    },
  },

  {
    id: 'ND11',
    title: 'DoH 固定 IP（hosts）只有一个来源',
    rule: '隧道与测速核各自解析一遍 → 同一域名在两份 YAML 钉到不同 IP，'
      + '表现为「同一节点隧道里能用、测速失败」。',
    check(ctx) {
      const out = [];
      const allowed = new Set(['entry/src/main/ets/commons/config/RuntimeConfigBuilder.ets']);
      for (const rel of ctx.rels) {
        if (isScriptSample(rel) || allowed.has(rel)) {
          continue;
        }
        for (const h of hits(ctx, rel, /DoHResolver\.resolveMany\s*\(/)) {
          out.push({ ...h, kind: 'DoH 预解析的第 2 个调用点（hosts 真源必须唯一）' });
        }
      }
      return out;
    },
  },

  {
    id: 'ND13',
    title: '「算不算节点结论」只能有一张表（正表与反表不得并存）',
    rule: '正表（isVerdictKind）与反表（isNonVerdictKind）各写一份 → '
      + '新增一类失败只登记到一张表时，live 路径与恢复路径结论相反'
      + '（live 说「是结论」、恢复说「不是结论」）。',
    check(ctx) {
      const out = [];
      // 2026-10-20 lead 拍板：只保留**一张**表 = 内核分类表的 isNonVerdictKind；
      // 正表 isVerdictKind 只能是它的**派生视图**（不得自带分类清单）。
      const kernel = 'entry/src/main/ets/commons/latency/LatencyKinds.ets';
      let nonVerdictTable = 0;
      for (const rel of ctx.rels) {
        if (isScriptSample(rel)) {
          continue;
        }
        for (const h of hits(ctx, rel, /static\s+isVerdictKind\s*\(/)) {
          const body = methodBody(ctx, rel, /static\s+isVerdictKind\s*\([^)]*\)\s*:\s*boolean\s*\{/);
          if (!delegatesToKernel(body, 'isVerdictKind')) {
            out.push({ ...h, kind: '正表 isVerdictKind 自带清单（必须派生自唯一判定表）' });
          }
        }
        for (const h of hits(ctx, rel, /static\s+isNonVerdictKind\s*\(/)) {
          nonVerdictTable++;
          if (rel === kernel) {
            continue;
          }
          const body = methodBody(ctx, rel, /static\s+isNonVerdictKind\s*\([^)]*\)\s*:\s*boolean\s*\{/);
          if (!delegatesToKernel(body, 'isNonVerdictKind')) {
            out.push({ ...h, kind: '反表 isNonVerdictKind 与正表并存（两张判定表）' });
          }
        }
      }
      if (nonVerdictTable === 0) {
        out.push({
          rel: kernel,
          line: 1,
          text: '(缺失) 唯一判定表 isNonVerdictKind 未定义',
          kind: '唯一判定表缺失',
        });
      }
      return out;
    },
  },

  {
    id: 'ND14',
    title: '「结论已陈旧」只能有一张判定表',
    rule: '两张陈旧表 → 同一份失败结论在一处标「·旧」、另一处当新鲜显示。',
    check(ctx) {
      const out = [];
      // 2026-10-20 lead 拍板：陈旧判定下沉到零 import 的内核分类表
      // （LatencyKinds.isStale）：有时间戳按 TTL 判；年龄未知时**失败结论**算陈旧
      // （冷启动假红防线）。别处只允许**转调**。
      const source = 'entry/src/main/ets/commons/latency/LatencyKinds.ets';
      let found = 0;
      for (const rel of ctx.rels) {
        if (isScriptSample(rel)) {
          continue;
        }
        for (const h of hits(ctx, rel, /static\s+isStale\s*\(/)) {
          found++;
          if (rel === source) {
            continue;
          }
          const body = methodBody(ctx, rel, /static\s+isStale\s*\([^)]*\)\s*:\s*boolean\s*\{/);
          if (!body.includes('isStale(')) {
            out.push({ ...h, kind: '陈旧判定表的第 2 份实现（必须转调 LatencyProbeKind.isStale）' });
          } else if (body.includes('nowMs -')) {
            out.push({ ...h, kind: '陈旧判定表的第 2 份实现（自己又算了一遍年龄）' });
          }
        }
        for (const h of hits(ctx, rel, /static\s+isStaleConclusion\s*\(/)) {
          found++;
          if (rel === source) {
            continue;
          }
          const body = methodBody(ctx, rel, /static\s+isStaleConclusion\s*\([^)]*\)\s*:\s*boolean\s*\{/);
          if (!body.includes('isStale(')) {
            out.push({ ...h, kind: '陈旧判定表的第 2 份实现（必须转调 LatencyProbeKind.isStale）' });
          } else if (body.includes('nowMs -')) {
            out.push({ ...h, kind: '陈旧判定表的第 2 份实现（自己又算了一遍年龄）' });
          }
        }
      }
      if (found === 0) {
        out.push({
          rel: source,
          line: 1,
          text: '(缺失) 内核分类表未定义 isStale',
          kind: '陈旧判定表的唯一真源缺失',
        });
      }
      return out;
    },
  },

  {
    id: 'ND12',
    title: '凭据回填的调用点唯一（生成配置前只回填一次）',
    rule: '三条路径各回填一次、各自 try/catch → 漏一条就把「缺凭据」的节点'
      + '整条写进内核 → 节点存在但握手必失败。',
    check(ctx) {
      const out = [];
      const orch = 'entry/src/main/ets/commons/services/ConnectionOrchestrator.ets';
      // 只数「调用点」，函数定义本身不算
      const calls = hits(ctx, orch, /await\s+this\.hydrateNodeCredentials\s*\(/);
      if (calls.length !== 1) {
        for (const c of calls.slice(1)) {
          out.push({ ...c, kind: `凭据回填有 ${calls.length} 个调用点（应为 1）` });
        }
        if (calls.length === 0) {
          out.push({
            rel: orch,
            line: 1,
            text: '(缺失) 没有任何凭据回填调用点',
            kind: '凭据回填调用点缺失',
          });
        }
      }
      return out;
    },
  },
];

// ── 负对照：每条断言的注入点（注入的是「同一类错误」） ─────────────────────
const NEGATIVE_CONTROLS = {
  ND01: { rel: 'entry/src/main/ets/pages/HomePage.ets', add: "    const __ndProbe: string = 'switch_failed';" },
  ND02: { rel: 'entry/src/main/ets/pages/HomePage.ets', add: '  static isNonVerdictKind(k: string): boolean { return k.length > 0; }' },
  ND03: { rel: 'entry/src/main/ets/pages/HomePage.ets', add: '  static describe(a: number): string { return String(a); }' },
  ND04: { rel: 'entry/src/main/ets/theme/UiTokens.ets', add: "    return LatencyPolicy.stateText(0, '');" },
  ND05: { rel: 'entry/src/main/ets/pages/HomePage.ets', add: '  static readonly STALE_MS: number = 12345;' },
  ND06: { rel: 'entry/src/main/ets/pages/HomePage.ets', add: "    const __ndUrl: string = 'https://www.gstatic.com/generate_204';" },
  ND07: { rel: 'entry/src/main/ets/commons/services/ConnectionOrchestrator.ets', add: "    settings.nodeSortSnapshot = 'probe';" },
  ND08: { rel: 'entry/src/main/ets/pages/HomePage.ets', add: "    const __ndRec = LatencyController.recordFor('probe');" },
  ND09: { rel: 'entry/src/main/ets/commons/services/ConnectionOrchestrator.ets', add: '    api.setEndpoint(this.apiPort, this.testCoreSecret);' },
  ND10: { rel: 'entry/src/main/ets/pages/HomePage.ets', add: '  static proxyYamlLine(n: ProxyNode): string { return String(n.name); }' },
  ND11: { rel: 'entry/src/main/ets/commons/services/ConnectionOrchestrator.ets', add: '    const __ndHosts = await DoHResolver.resolveMany(domains, 6000, []);' },
  ND12: { rel: 'entry/src/main/ets/commons/services/ConnectionOrchestrator.ets', add: '      await this.hydrateNodeCredentials(subs);' },
  ND13: { rel: 'entry/src/main/ets/pages/HomePage.ets', add: '  static isNonVerdictKind(k: string): boolean { return k.length === 0; }' },
  ND14: { rel: 'entry/src/main/ets/pages/HomePage.ets', add: '  static isStaleConclusion(a: number, b: number): boolean { return a < b; }' },
};

// ── 执行 ────────────────────────────────────────────────────────────────────

/** 默认修掉一处违例：删掉那一行（扫描器不做语法校验，删行足够让断言转绿）。 */
function defaultRepair(ctx, v) {
  const f = ctx.files.get(v.rel);
  if (!f) {
    return;
  }
  const lines = f.raw.split('\n');
  lines.splice(v.line - 1, 1);
  const raw = lines.join('\n');
  f.raw = raw;
  f.code = stripComments(raw);
  // 必须落盘：下一步会重建扫描上下文（重新读盘），只改内存等于没改。
  fs.writeFileSync(path.join(ctx.rootDir, v.rel), raw, 'utf8');
}

function runAsserts(ctx) {
  const results = [];
  for (const a of ASSERTS) {
    const violations = a.check(ctx);
    results.push({ id: a.id, title: a.title, rule: a.rule, violations });
  }
  return results;
}

function copyTree(rootDir, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const dir of SCAN_DIRS) {
    const src = path.join(rootDir, dir);
    if (!fs.existsSync(src)) {
      continue;
    }
    fs.cpSync(src, path.join(dest, dir), { recursive: true });
  }
}

function selftest() {
  console.log('\n=== 负对照自检（每条断言：修掉→必须转绿，注入→必须转红）===');
  let failed = 0;
  for (const a of ASSERTS) {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-nd-'));
    const dest = path.join(tmp, 'repo');
    try {
      copyTree(root, dest);
      let ctx = buildCtx(dest);
      let res = runAsserts(ctx).find((r) => r.id === a.id);

      // 步骤 1：把当前违例修掉 → 必须转绿
      if (res.violations.length > 0) {
        // 倒序删行：先删靠后的，前面行号才不会被顶歪
        const ordered = res.violations.slice().sort((a, b) => (
          a.rel === b.rel ? b.line - a.line : (a.rel < b.rel ? 1 : -1)
        ));
        for (const v of ordered) {
          defaultRepair(ctx, v);
        }
        ctx = buildCtx(dest);
        res = runAsserts(ctx).find((r) => r.id === a.id);
      }
      const greenOk = res.violations.length === 0;
      if (!greenOk) {
        failed++;
        console.log(`  ❌ ${a.id} 修掉违例后仍判红 —— 断言可能恒红（违例 ${res.violations.length} 处）`);
        console.log(`       ${res.violations[0].rel}:${res.violations[0].line} ${res.violations[0].kind}`);
        continue;
      }

      // 步骤 2：注入一处同类分叉 → 必须转红
      const inject = NEGATIVE_CONTROLS[a.id];
      const target = path.join(dest, inject.rel);
      if (!fs.existsSync(target)) {
        failed++;
        console.log(`  ❌ ${a.id} 注入点不存在：${inject.rel}`);
        continue;
      }
      const text = fs.readFileSync(target, 'utf8');
      fs.writeFileSync(target, `${text}\n${inject.add}\n`, 'utf8');
      ctx = buildCtx(dest);
      res = runAsserts(ctx).find((r) => r.id === a.id);
      const redOk = res.violations.length > 0;
      if (!redOk) {
        failed++;
        console.log(`  ❌ ${a.id} 注入分叉后仍判绿 —— 断言没有牙齿`);
      } else {
        console.log(`  ✅ ${a.id} 修掉→绿 / 注入→红（命中 ${res.violations[0].rel}:${res.violations[0].line}）`);
      }
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  }
  return failed;
}

function main() {
  const args = process.argv.slice(2);
  const pending = args.includes('--pending');
  const selfTest = args.includes('--self-test');

  if (selfTest) {
    const failed = selftest();
    console.log(failed === 0
      ? '\n✅ 负对照自检全部通过：每条断言都证明了「修掉即绿、注入即红」'
      : `\n❌ 负对照自检失败 ${failed} 条`);
    process.exit(failed === 0 ? 0 : 1);
  }

  const ctx = buildCtx(root);
  const results = runAsserts(ctx);

  console.log('\n=== 单一真源 · 残留分叉扫描 ===');
  console.log(`扫描范围：${SCAN_DIRS.join(' , ')}（共 ${ctx.rels.length} 个文件）`);
  console.log(`白名单：scripts/** —— ${SCRIPTS_WHITELIST_REASON}`);

  let bad = 0;
  for (const r of results) {
    if (r.violations.length === 0) {
      console.log(`  ✅ ${r.id} ${r.title}`);
      continue;
    }
    bad++;
    console.log(`  ❌ ${r.id} ${r.title} —— ${r.violations.length} 处违例`);
    console.log(`       规则：${r.rule}`);
    for (const v of r.violations) {
      console.log(`       · ${v.rel}:${v.line}  ${v.kind}`);
      console.log(`         ${v.text}`);
    }
  }

  console.log(`\n合计：${results.length} 条断言，${results.length - bad} 绿 / ${bad} 红`);
  if (bad > 0) {
    console.log('残留清单另见 docs/divergence-audit-2026-10-20.md（按 ND 编号对账）。');
    if (pending) {
      console.log('（--pending 模式：只预览，不判失败）');
      process.exit(0);
    }
    process.exit(1);
  }
  console.log('全部收敛：每条判定规则只剩一份实现。');
  process.exit(0);
}

main();
