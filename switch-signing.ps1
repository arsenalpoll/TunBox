param([string]$Mode = '')
$ErrorActionPreference = 'Stop'
# 签名模式切换：debug 证书（DevEco Run 直装真机）↔ 发布证书（空签名 + sign-nexus-package.ps1）
# 用法: .\switch-signing.ps1 [-Mode debug|release]  不带参数时交互选择
$profilePath = Join-Path $PSScriptRoot 'TunBox_HarmonyOS\build-profile.json5'
$text = [System.IO.File]::ReadAllText($profilePath)

# debug 材料与 test 分支固化的一致（DevEco 加密串，仅本机 .ohos 下的文件有效）。
# PS 单引号串里反斜杠是字面量；JSON5 要求路径为双反斜杠（下面的 \ 是字面两个）。
$debugLines = @(
  '"signingConfigs": [',
  '      {',
  '        "name": "default",',
  '        "type": "HarmonyOS",',
  '        "material": {',
  '          "certpath": "C:\\Users\\Administrator\\.ohos\\config\\default_TunBox_HarmonyOS_dxKCNw3ssq7dB3_GqPmpFO39lRyYOC8zNAj-A_ubn-Y=.cer",',
  '          "keyAlias": "debugKey",',
  '          "keyPassword": "0000001B7AAF62F08F00E9DF5C1132E321DDB58AD426AB2E5FA888BD087977DF95773DB41EBAC65EF70C7F",',
  '          "profile": "C:\\Users\\Administrator\\.ohos\\config\\default_TunBox_HarmonyOS_dxKCNw3ssq7dB3_GqPmpFO39lRyYOC8zNAj-A_ubn-Y=.p7b",',
  '          "signAlg": "SHA256withECDSA",',
  '          "storeFile": "C:\\Users\\Administrator\\.ohos\\config\\default_TunBox_HarmonyOS_dxKCNw3ssq7dB3_GqPmpFO39lRyYOC8zNAj-A_ubn-Y=.p12",',
  '          "storePassword": "0000001BCE3C344DA55B022C78AB04AD95E2A78F45C181994993FF8A2BBB9592FAD891F0A032A1A85D13AA"',
  '        }',
  '      }',
  '    ],'
)

function Get-CurrentMode([string]$t) {
  if ($t.Contains('debugKey')) { return 'debug' }
  if ($t.Contains('"signingConfigs": []')) { return 'release' }
  return 'unknown'
}

function Switch-Signing([string]$t, [string]$m) {
  $sIdx = $t.IndexOf('"signingConfigs"')
  $pIdx = $t.IndexOf('"products"')
  if ($sIdx -lt 0 -or $pIdx -lt 0 -or $pIdx -lt $sIdx) { throw 'build-profile.json5 结构不符合预期' }
  $nl = $t.LastIndexOf("`n", $sIdx) + 1
  if ($m -eq 'debug') { $block = ($debugLines -join "`r`n") + "`r`n    " }
  else { $block = '"signingConfigs": [],' + "`r`n    " }
  $t = $t.Substring(0, $nl) + '    ' + $block + $t.Substring($pIdx)
  $hasRef = $t -match '"signingConfig"\s*:'
  if ($m -eq 'debug' -and -not $hasRef) {
    $rep = '"runtimeOS": "HarmonyOS",' + "`r`n" + '$1"signingConfig": "default"' + "`r`n" + '$1}'
    $t = $t -replace '"runtimeOS": "HarmonyOS",?\r?\n(\s*)\}', $rep
  }
  if ($m -eq 'release' -and $hasRef) {
    $t = $t -replace '"runtimeOS": "HarmonyOS",\r?\n\s*"signingConfig"\s*:\s*"default"', '"runtimeOS": "HarmonyOS"'
  }
  $t = $t -replace '\r?\n[ \t]+\r?\n(\s*)\}', ("`r`n" + '$1}')
  return $t
}

$cur = Get-CurrentMode $text
if ($Mode -eq 'status') { Write-Host ('当前签名模式: ' + $cur); exit 0 }
if ($Mode -notin @('debug', 'release')) {
  Write-Host ('当前签名模式: ' + $cur)
  Write-Host '选择签名模式:  1) debug（DevEco Run 直装）  2) release（发布包，走 sign-nexus-package.ps1）'
  $ans = Read-Host '输入 1 或 2'
  if ($ans.Trim() -eq '1') { $Mode = 'debug' } elseif ($ans.Trim() -eq '2') { $Mode = 'release' }
  if ($Mode -notin @('debug', 'release')) { Write-Host '未选择，退出。'; exit 0 }
}

if ($Mode -eq $cur) {
  $before = $text
  $text = Switch-Signing $text $Mode
  if ($text -eq $before) { Write-Host ('已经是 ' + $Mode + ' 模式，无需切换。'); exit 0 }
  [System.IO.File]::WriteAllText($profilePath, $text)
  Write-Host ('已是 ' + $Mode + ' 模式，格式已归一化。')
  exit 0
}
$text = Switch-Signing $text $Mode
[System.IO.File]::WriteAllText($profilePath, $text)
$after = [System.IO.File]::ReadAllText($profilePath)
$afterMode = Get-CurrentMode $after
if ($afterMode -ne $Mode) { throw '切换后复核失败' }
Write-Host ('已切换到 ' + $Mode + ' 模式。')
if ($Mode -eq 'debug') { Write-Host '→ DevEco 里直接 Run 即可装到真机；命令行构建同样出带调试签名的 hap。' }
else { Write-Host '→ 命令行构建产出 unsigned 包；发布签名走仓库根 sign-nexus-package.ps1（需要 NEXUS_KEY_PASSWORD）。' }
