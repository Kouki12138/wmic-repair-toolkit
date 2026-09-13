<#
    WMIC 修复脚本（通用版）
    - 优先从本机 WinSxS 组件库还原被删除的 WMIC 文件（版本自动匹配）
    - 组件库里没有时，自动改用脚本同目录下的 payload 离线修复包
    - 最后自动测试 wmic 是否可用
    用法：右键本文件 -> 使用 PowerShell 运行；或双击同目录的 run-repair.cmd
#>
[CmdletBinding()]
param(
    [switch]$DryRun,     # 只检查不修改
    [switch]$NoPause,    # 结束后不等待按键
    [switch]$ForceBundle,# 强制使用离线包（不用本机组件库）
    [string]$BundleRoot
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { }

if (-not $BundleRoot) {
    if ($PSScriptRoot) { $BundleRoot = $PSScriptRoot } else { $BundleRoot = (Get-Location).Path }
}

$script:LogPaths = New-Object System.Collections.Generic.List[string]
if ($BundleRoot -and (Test-Path -LiteralPath $BundleRoot)) {
    [void]$script:LogPaths.Add((Join-Path $BundleRoot 'wmic-repair-log.txt'))
}
$desktop = [Environment]::GetFolderPath('Desktop')
if ($desktop) { [void]$script:LogPaths.Add((Join-Path $desktop 'wmic-repair-log.txt')) }

function Say([string]$m) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line
    foreach ($p in $script:LogPaths) {
        try { Add-Content -LiteralPath $p -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$isAdmin = Test-Admin

if (-not $isAdmin -and -not $DryRun) {
    Write-Host '正在请求管理员权限，请在弹窗中点“是”...' -ForegroundColor Yellow
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argString = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    if ($NoPause) { $argString += ' -NoPause' }
    try {
        Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $argString -ErrorAction Stop
    }
    catch {
        Write-Host ('提权失败：' + $_.Exception.Message) -ForegroundColor Red
        if (-not $NoPause) { [void](Read-Host '按回车键退出') }
    }
    exit
}

foreach ($p in $script:LogPaths) { try { Add-Content -LiteralPath $p -Value ('=== 运行 {0} ===' -f (Get-Date)) -Encoding UTF8 -ErrorAction Stop } catch { } }

Say '===== WMIC 修复脚本 ====='
Say ('电脑名称 : {0}' -f $env:COMPUTERNAME)
Say ('管理员   : {0}' -f $isAdmin)
if ($DryRun) { Say '模式     : 仅检查（不修改任何文件）' }

$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Say ('系统版本 : {0} {1} (Build {2}.{3})' -f $os.ProductName, $os.DisplayVersion, $os.CurrentBuild, $os.UBR)
Say ('处理器架构 : {0}' -f $env:PROCESSOR_ARCHITECTURE)

if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
    Say '警告：本机是 ARM64 架构，离线包里的 x64 文件不适用，只能用本机组件库还原。'
}

$sys32 = Join-Path $env:SystemRoot 'System32\wbem'
$sysWow = Join-Path $env:SystemRoot 'SysWOW64\wbem'
$hasWowDir = Test-Path -LiteralPath $sysWow

$neutralFiles = @('cli.mof', 'cliegaliases.mof', 'rawxml.xsl', 'texttable.xsl', 'textvaluelist.xsl', 'xsl-mappings.xml')
$langXslFiles = @('csv.xsl', 'hform.xsl', 'htable.xsl', 'mof.xsl', 'xml.xsl')

function Get-StoreFileList([string]$name) {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($d in $script:StoreDirs) {
        $p1 = [IO.Path]::Combine($d, $name)
        if ([IO.File]::Exists($p1)) { [void]$list.Add($p1) }
        $p2 = [IO.Path]::Combine($d, 'r', $name)
        if ([IO.File]::Exists($p2)) { [void]$list.Add($p2) }
    }
    return $list
}

function Get-VersionKey([string]$path) {
    $m = [regex]::Match($path, '10\.0\.\d+\.(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}

function Get-BestFile([string[]]$paths) {
    if (-not $paths -or $paths.Count -eq 0) { return $null }
    return ($paths | Sort-Object @{Expression = { Get-VersionKey $_ }; Descending = $true } | Select-Object -First 1)
}

$storeRoot = Join-Path $env:SystemRoot 'WinSxS'
$script:StoreDirs = @()
if (Test-Path -LiteralPath $storeRoot) {
    try { $script:StoreDirs = [IO.Directory]::GetDirectories($storeRoot) } catch { $script:StoreDirs = @() }
}
Say ('组件库目录数量 : {0}' -f $script:StoreDirs.Count)

$payloadRoot = Join-Path $BundleRoot 'payload'
$hasBundle = Test-Path -LiteralPath $payloadRoot
if ($hasBundle) {
    $bundleCount = @(Get-ChildItem -LiteralPath $payloadRoot -Recurse -File -ErrorAction SilentlyContinue).Count
    Say ('离线包   : 已找到，共 {0} 个文件' -f $bundleCount)
}
else { Say '离线包   : 未找到（只使用本机组件库）' }

function Get-BundleSource([string]$relativePath) {
    if (-not $hasBundle) { return $null }
    $p = Join-Path $payloadRoot $relativePath
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

# ---------- 1. WMIC.exe ----------
$exeAll = Get-StoreFileList 'WMIC.exe' | Where-Object { ([IO.FileInfo]$_).Length -gt 200000 }
$exe64 = Get-BestFile @($exeAll | Where-Object { $_ -notmatch '\\wow64_microsoft' })
$exe32 = Get-BestFile @($exeAll | Where-Object { $_ -match '\\wow64_microsoft' })

# ---------- 2. 语言资源 WMIC.exe.mui ----------
$muiAll = Get-StoreFileList 'WMIC.exe.mui'
$muiByLang = @{}
foreach ($f in $muiAll) {
    $m = [regex]::Match($f, '\.resources_31bf3856ad364e35_10\.0\.\d+\.\d+_([a-z]{2}-[a-z]{2})_', 'IgnoreCase')
    if (-not $m.Success) { continue }
    $lang = $m.Groups[1].Value
    if (-not $muiByLang.ContainsKey($lang)) { $muiByLang[$lang] = New-Object System.Collections.Generic.List[string] }
    [void]$muiByLang[$lang].Add($f)
}

# ---------- 3. 基础文件（xsl / mof） ----------
$baseSources64 = @{}
$baseSources32 = @{}
foreach ($n in $neutralFiles) {
    $cand = @(Get-StoreFileList $n | Where-Object { $_ -match 'utility' -and $_ -notmatch '\.resources_' })
    $neutralOnly = @($cand | Where-Object { $_ -notmatch '\\r\\' })
    if ($neutralOnly.Count -gt 0) { $cand = $neutralOnly }
    $baseSources64[$n] = Get-BestFile @($cand | Where-Object { $_ -notmatch '\\wow64_' })
    $baseSources32[$n] = Get-BestFile @($cand | Where-Object { $_ -match '\\wow64_' })
    if (-not $baseSources64[$n]) { $baseSources64[$n] = $baseSources32[$n] }
    if (-not $baseSources32[$n]) { $baseSources32[$n] = $baseSources64[$n] }
}

# ---------- 4. 语言 xsl ----------
$langXslByLang = @{}
foreach ($n in $langXslFiles) {
    $cand = Get-StoreFileList $n | Where-Object { $_ -match '\.resources_31bf3856ad364e35_10\.0\.\d+\.\d+_[a-z]{2}-[a-z]{2}_' }
    foreach ($f in $cand) {
        $m = [regex]::Match($f, '\.resources_31bf3856ad364e35_10\.0\.\d+\.\d+_([a-z]{2}-[a-z]{2})_', 'IgnoreCase')
        if (-not $m.Success) { continue }
        $lang = $m.Groups[1].Value
        if (-not $langXslByLang.ContainsKey($lang)) { $langXslByLang[$lang] = @{} }
        if (-not $langXslByLang[$lang].ContainsKey($n)) { $langXslByLang[$lang][$n] = New-Object System.Collections.Generic.List[string] }
        [void]$langXslByLang[$lang][$n].Add($f)
    }
}

function Get-LangXsl([string]$lang, [string]$name) {
    if (-not $langXslByLang.ContainsKey($lang)) { return $null }
    if (-not $langXslByLang[$lang].ContainsKey($name)) { return $null }
    return (Get-BestFile @($langXslByLang[$lang][$name]))
}

Say '----- 组件库中找到的素材 -----'
Say ('WMIC.exe (64位) : {0}' -f $exe64)
Say ('WMIC.exe (32位) : {0}' -f $exe32)
foreach ($k in ($muiByLang.Keys | Sort-Object)) {
    Say ('WMIC.exe.mui [{0}] : {1} 个' -f $k, $muiByLang[$k].Count)
}
foreach ($n in $neutralFiles) { Say ('{0} : 64位={1} | 32位={2}' -f $n, $baseSources64[$n], $baseSources32[$n]) }

# ---------- 5. 生成目标清单 ----------
$plan = New-Object System.Collections.ArrayList

function Add-Plan([string]$dest, [string]$storeSrc, [string]$bundleRel) {
    $src = $null
    $from = ''
    if (-not $ForceBundle -and $storeSrc -and (Test-Path -LiteralPath $storeSrc)) { $src = $storeSrc; $from = '组件库' }
    elseif ($hasBundle) {
        $b = Get-BundleSource $bundleRel
        if ($b) { $src = $b; $from = '离线包' }
    }
    [void]$plan.Add([pscustomobject]@{ Dest = $dest; Src = $src; From = $from })
}

if ($exe64) { Add-Plan (Join-Path $sys32 'wmic.exe') $exe64 'System32\wbem\wmic.exe' }
else { Add-Plan (Join-Path $sys32 'wmic.exe') $null 'System32\wbem\wmic.exe' }

if ($hasWowDir) {
    if ($exe32) { Add-Plan (Join-Path $sysWow 'wmic.exe') $exe32 'SysWOW64\wbem\wmic.exe' }
    else { Add-Plan (Join-Path $sysWow 'wmic.exe') $null 'SysWOW64\wbem\wmic.exe' }
}

foreach ($n in $neutralFiles) {
    Add-Plan (Join-Path $sys32 $n) $baseSources64[$n] ('System32\wbem\' + $n)
    if ($hasWowDir) { Add-Plan (Join-Path $sysWow $n) $baseSources32[$n] ('SysWOW64\wbem\' + $n) }
}

# 需要处理的语言：组件库里能找到资源的语言 + 离线包里的语言
$langSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($k in $muiByLang.Keys) { [void]$langSet.Add($k) }
if ($hasBundle) {
    foreach ($base in @('System32\wbem', 'SysWOW64\wbem')) {
        $lb = Join-Path $payloadRoot $base
        if (Test-Path -LiteralPath $lb) {
            foreach ($d in (Get-ChildItem -LiteralPath $lb -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[a-zA-Z]{2}-[a-zA-Z]{2,4}$' })) {
                [void]$langSet.Add($d.Name)
            }
        }
    }
}
if ($langSet.Count -eq 0) { foreach ($k in @('zh-CN', 'en-US')) { [void]$langSet.Add($k) } }

$langDirs = @()
foreach ($k in $langSet) {
    $existingName = $k
    if (Test-Path -LiteralPath $sys32) {
        $hit = Get-ChildItem -LiteralPath $sys32 -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $k } | Select-Object -First 1
        if ($hit) { $existingName = $hit.Name }
    }
    $langDirs += [pscustomobject]@{ Key = $k; Name = $existingName }
}

foreach ($ld in $langDirs) {
    $lang = $ld.Key
    $dirName = $ld.Name
    $muiSrc = $null
    if ($muiByLang.ContainsKey($lang)) { $muiSrc = Get-BestFile @($muiByLang[$lang]) }

    $d64 = Join-Path $sys32 $dirName
    Add-Plan (Join-Path $d64 'wmic.exe.mui') $muiSrc ('System32\wbem\' + $dirName + '\wmic.exe.mui')
    foreach ($n in $langXslFiles) { Add-Plan (Join-Path $d64 $n) (Get-LangXsl $lang $n) ('System32\wbem\' + $dirName + '\' + $n) }

    if ($hasWowDir) {
        $d32 = Join-Path $sysWow $dirName
        Add-Plan (Join-Path $d32 'wmic.exe.mui') $muiSrc ('SysWOW64\wbem\' + $dirName + '\wmic.exe.mui')
        foreach ($n in $langXslFiles) { Add-Plan (Join-Path $d32 $n) (Get-LangXsl $lang $n) ('SysWOW64\wbem\' + $dirName + '\' + $n) }
    }
}

# ---------- 6. 执行复制 ----------
Say '----- 处理结果 -----'
$copied = 0; $kept = 0; $missing = 0; $failed = 0

foreach ($item in $plan) {
    $dest = $item.Dest
    $dir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $dir)) {
        if ($DryRun) { Say ('[需要新建目录] ' + $dir) }
        else {
            try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            catch { Say ('[无法创建目录] {0} : {1}' -f $dir, $_.Exception.Message); $failed++; continue }
        }
    }

    if (-not $item.Src) {
        if (Test-Path -LiteralPath $dest) { Say ('[已存在] ' + $dest); $kept++ }
        else { Say ('[缺源文件] ' + $dest + '  <-- 组件库和离线包都没有这个文件'); $missing++ }
        continue
    }

    $srcSize = ([IO.FileInfo]$item.Src).Length
    $needCopy = $true
    if (Test-Path -LiteralPath $dest) {
        $dstSize = ([IO.FileInfo]$dest).Length
        if ($dstSize -eq $srcSize) { $needCopy = $false }
    }

    if (-not $needCopy) { Say ('[无需处理] ' + $dest); $kept++; continue }

    if ($DryRun) { Say ('[将复制] {0}  <-  {1} ({2})' -f $dest, $item.Src, $item.From); $copied++; continue }

    try {
        Copy-Item -LiteralPath $item.Src -Destination $dest -Force -ErrorAction Stop
        $newSize = ([IO.FileInfo]$dest).Length
        if ($newSize -eq $srcSize) { Say ('[已还原] {0}  ({1} 字节, 来源: {2})' -f $dest, $newSize, $item.From); $copied++ }
        else { Say ('[大小不符] ' + $dest); $failed++ }
    }
    catch {
        Say ('[复制失败] {0} : {1}' -f $dest, $_.Exception.Message); $failed++
    }
}

Say ('统计：还原 {0} 个，已正常 {1} 个，缺源 {2} 个，失败 {3} 个' -f $copied, $kept, $missing, $failed)

# ---------- 7. 兜底：向系统申请安装 WMIC 可选功能 ----------
$wmicExe = Join-Path $sys32 'wmic.exe'
if (-not (Test-Path -LiteralPath $wmicExe) -and -not $DryRun) {
    Say '----- 组件库与离线包都没有 wmic.exe，尝试向 Windows 申请安装 WMIC 可选功能 -----'
    try {
        $cap = Get-WindowsCapability -Online -Name 'WMIC*' -ErrorAction Stop
        foreach ($c in $cap) { Say ('可选功能 {0} 状态 = {1}' -f $c.Name, $c.State) }
        foreach ($c in $cap) {
            if ($c.State -ne 'Installed') {
                Say ('正在安装 {0} （需要联网，可能需要几分钟）...' -f $c.Name)
                try { $r = Add-WindowsCapability -Online -Name $c.Name -ErrorAction Stop; Say ('安装完成，RestartNeeded={0}' -f $r.RestartNeeded) }
                catch { Say ('安装失败：' + $_.Exception.Message) }
            }
        }
    }
    catch { Say ('查询可选功能失败：' + $_.Exception.Message) }
}

# ---------- 8. 验证 ----------
Say '----- 功能验证 -----'
$ok = $false
if (Test-Path -LiteralPath $wmicExe) {
    try {
        $out = & $wmicExe os get caption 2>&1 | Out-String
        $code = $LASTEXITCODE
        Say ('wmic os get caption -> 退出码 {0}' -f $code)
        Say ('输出：' + ($out.Trim()))
        if ($out -match '(?i)caption' -and $out -notmatch 'Invalid XSL|Access denied|拒绝访问') { $ok = $true }
    }
    catch { Say ('执行 wmic 出错：' + $_.Exception.Message) }

    try {
        $out2 = & $wmicExe csproduct get uuid 2>&1 | Out-String
        Say ('wmic csproduct get uuid -> 输出：' + ($out2.Trim()))
    }
    catch { }
}
else { Say '找不到 wmic.exe' }

Say '----- 结果 -----'
if ($ok) {
    Say '√ WMIC 已可正常使用。请重新打开之前报错的软件再试。'
    Say ('验证命令：wmic os get caption  ->  {0}' -f ($out.Trim()))
}
else {
    Say '× WMIC 仍不可用，请把本日志（桌面上的 wmic-repair-log.txt）发给我。'
}
Say ('日志文件： ' + ($script:LogPaths -join '  |  '))
Say '===== 结束 ====='

if (-not $NoPause -and -not $DryRun) {
    Write-Host ''
    [void](Read-Host '按回车键关闭此窗口')
}
