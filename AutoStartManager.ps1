<#
    自启管家 · AutoStart Manager
    单文件 PowerShell 5.1 + WPF 的 Windows 启动项管理器
    管理范围：注册表 Run/RunOnce、启动文件夹、登录计划任务、自动服务
    功能：查看 / 启用 / 禁用 / 移除（可恢复）/ 拖拽添加 / 回收站
    作者：由 Doubao 生成；无第三方依赖
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$DiagScan,
    [switch]$PreviewShot,
    [string]$PreviewPath = '',
    [switch]$AllowSecondInstance
)

$ErrorActionPreference = 'Continue'

$script:WindowTitle = '自启管家 · 启动项管理器'
$script:AppPath     = $MyInvocation.MyCommand.Path
if ($PSScriptRoot) { $script:AppDir = $PSScriptRoot } else { $script:AppDir = Split-Path -Parent $script:AppPath }
$script:DataDir       = Join-Path $env:LOCALAPPDATA 'AutoStartManager'
$script:QuarantineDir = Join-Path $script:DataDir 'Quarantine'
$script:QuarantineFile= Join-Path $script:DataDir 'quarantine.json'
$script:ServiceFile   = Join-Path $script:DataDir 'services-changed.json'
$script:LogFile       = Join-Path $script:DataDir 'app.log'
$script:IconCache     = @{}
$script:CompanyCache  = @{}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Drawing

if (-not ('AutoStartNative.Win' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace AutoStartNative {
    public class Win {
        public delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
        [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr hObject);

        public static IntPtr ByTitle(string title) {
            IntPtr found = IntPtr.Zero;
            EnumWindows(delegate(IntPtr h, IntPtr l) {
                if (!IsWindowVisible(h)) return true;
                StringBuilder sb = new StringBuilder(256);
                GetWindowText(h, sb, 256);
                if (sb.ToString() == title) { found = h; return false; }
                return true;
            }, IntPtr.Zero);
            return found;
        }
    }
}
'@
}

foreach ($d in @($script:DataDir, $script:QuarantineDir)) {
    if (-not (Test-Path -LiteralPath $d)) {
        try { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null } catch { }
    }
}

function Write-Log {
    param([string]$Message)
    try { Add-Content -LiteralPath $script:LogFile -Value ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $Message) -Encoding UTF8 } catch { }
}

# ------------------------------------------------------------------
# 基础工具
# ------------------------------------------------------------------
function Get-ColorBrush {
    param([string]$Hex)
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    $b = New-Object System.Windows.Media.SolidColorBrush($c)
    $b.Freeze()
    return $b
}
function Get-GradientBrush {
    param([string]$From, [string]$To)
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.StartPoint = New-Object System.Windows.Point(0, 0)
    $b.EndPoint   = New-Object System.Windows.Point(1, 1)
    $b.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.ColorConverter]::ConvertFromString($From), 0)))
    $b.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.ColorConverter]::ConvertFromString($To), 1)))
    $b.Freeze()
    return $b
}

$script:BrushGreen  = Get-ColorBrush '#45DFA0'
$script:BrushAmber  = Get-ColorBrush '#F0B457'
$script:BrushMuted  = Get-ColorBrush '#9CABC2'
$script:BrushBlue   = Get-ColorBrush '#7FB4FF'
$script:BrushRed    = Get-ColorBrush '#F27983'
$script:GsReg       = Get-GradientBrush '#3B82F6' '#1D4ED8'
$script:GsFolder    = Get-GradientBrush '#14B8A6' '#0F766E'
$script:GsTask      = Get-GradientBrush '#F59E0B' '#B45309'
$script:GsService   = Get-GradientBrush '#64748B' '#334155'
$script:GsTrash     = Get-GradientBrush '#4B5563' '#1F2937'

function Test-Admin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
$script:IsAdmin = Test-Admin

function Get-HiveRoot {
    param([string]$Hive)
    if ($Hive -eq 'HKCU') { return [Microsoft.Win32.Registry]::CurrentUser }
    return [Microsoft.Win32.Registry]::LocalMachine
}

function New-Entry {
    param([string]$Kind, [string]$Id, [string]$Name, [string]$Sub, [string]$Badge, [bool]$Enabled)
    return [pscustomobject]@{
        Id = $Id; Kind = $Kind; Name = $Name; Sub = $Sub; Badge = $Badge
        Enabled = $Enabled; IsSystem = $false; Missing = $false; Time = ''; Command = ''; NoteNotRunnable = $false
        Hive = ''; RegSub = ''; RegName = ''; RegKind = ''; ApprovedHive = ''; ApprovedSub = ''
        FilePath = ''; TargetPath = ''; TaskName = ''; TaskPath = ''; ServiceName = ''; Qid = ''
        StatusText = ''; StatusColor = '#9CABC2'
        ToggleVis = 'Collapsed'; OpenVis = 'Collapsed'; RemoveVis = 'Collapsed'
        RestoreVis = 'Collapsed'; PurgeVis = 'Collapsed'
        IconSource = $null; IconVis = 'Collapsed'; Letter = ''; LetterVis = 'Visible'
    }
}

function Update-EntryVisual {
    param($Entry)
    $e = $Entry
    if (-not $e.Letter) {
        if ($e.Name) { $e.Letter = ([string]$e.Name).Substring(0, 1).ToUpperInvariant() } else { $e.Letter = '?' }
    }

    if ($e.Kind -eq 'Trash') {
        $e.StatusText  = '已移除 ' + $e.Time
        $e.StatusColor = '#9CABC2'
    }
    elseif ($e.Kind -eq 'RunOnce') {
        $e.StatusText  = '一次性启动'
        $e.StatusColor = '#7FB4FF'
    }
    elseif ($e.Kind -eq 'Service') {
        if ($e.Enabled) { $e.StatusText = '自动启动'; $e.StatusColor = '#45DFA0' }
        else            { $e.StatusText = '手动启动'; $e.StatusColor = '#9CABC2' }
    }
    elseif ($e.Kind -eq 'Task') {
        if ($e.Enabled) { $e.StatusText = '随登录启动'; $e.StatusColor = '#45DFA0' }
        else            { $e.StatusText = '已禁用';     $e.StatusColor = '#9CABC2' }
    }
    elseif ($e.NoteNotRunnable) {
        $e.StatusText  = '不会自启'
        $e.StatusColor = '#F0B457'
    }
    elseif ($e.Missing) {
        $e.StatusText  = '目标缺失'
        $e.StatusColor = '#F0B457'
    }
    elseif ($e.Enabled) {
        $e.StatusText  = '已启用'
        $e.StatusColor = '#45DFA0'
    }
    else {
        $e.StatusText  = '已禁用'
        $e.StatusColor = '#9CABC2'
    }

    $e.ToggleVis = 'Collapsed'; $e.OpenVis = 'Collapsed'; $e.RemoveVis = 'Collapsed'
    $e.RestoreVis = 'Collapsed'; $e.PurgeVis = 'Collapsed'

    if ($e.Kind -eq 'Trash') {
        $e.RestoreVis = 'Visible'
        $e.PurgeVis   = 'Visible'
        $e.OpenVis    = 'Visible'
    }
    elseif ($e.Kind -eq 'Run' -or $e.Kind -eq 'Folder' -or $e.Kind -eq 'Task' -or $e.Kind -eq 'Service') {
        $e.ToggleVis = 'Visible'
        $e.OpenVis   = 'Visible'
        if ($e.Kind -ne 'Service') { $e.RemoveVis = 'Visible' }
    }
    else {
        $e.OpenVis   = 'Visible'
        $e.RemoveVis = 'Visible'
    }

    if ($e.IconSource) { $e.IconVis = 'Visible'; $e.LetterVis = 'Collapsed' }
    else               { $e.IconVis = 'Collapsed'; $e.LetterVis = 'Visible' }
}

# ------------------------------------------------------------------
# 图标与命令解析
# ------------------------------------------------------------------
try { $script:Shell = New-Object -ComObject WScript.Shell } catch { $script:Shell = $null }

function Get-ExecutablePath {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return '' }
    $c = $Command.Trim()
    try { $c = [Environment]::ExpandEnvironmentVariables($c) } catch { }
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -gt 0) {
            $p = $c.Substring(1, $end - 1)
            if ($p -match '^[,]') { $p = $p.Substring(1) }
            return $p.Trim()
        }
    }
    $parts = $c -split ' '
    $cand = ''
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($i -eq 0) { $cand = $parts[0] } else { $cand = $cand + ' ' + $parts[$i] }
        if ($cand -match '^[,]') { $cand = $cand.Substring(1) }
        if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
    }
    $first = $parts[0]
    if ($first -match ',') { $first = $first.Split(',')[0] }
    return $first
}

function Get-ShortcutInfo {
    param([string]$LnkPath)
    if (-not $script:Shell) { return $null }
    try {
        $sc = $script:Shell.CreateShortcut($LnkPath)
        return [pscustomobject]@{
            Target = [string]$sc.TargetPath
            Args   = [string]$sc.Arguments
            WorkDir= [string]$sc.WorkingDirectory
        }
    } catch { return $null }
}

function Get-FileIcon {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $key = $Path.ToLowerInvariant()
    if ($script:IconCache.ContainsKey($key)) { return $script:IconCache[$key] }
    $img = $null
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($Path)
            if ($ico) {
                $bmp = $ico.ToBitmap()
                $hb  = $bmp.GetHbitmap()
                $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap(
                    $hb, [IntPtr]::Zero,
                    [System.Windows.Int32Rect]::Empty,
                    [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
                [AutoStartNative.Win]::DeleteObject($hb) | Out-Null
                $bmp.Dispose(); $ico.Dispose()
                $src.Freeze()
                $img = $src
            }
        }
    } catch { $img = $null }
    $script:IconCache[$key] = $img
    return $img
}

function Get-ApprovedBytes {
    param([string]$Hive, [string]$Sub, [string]$Name)
    try {
        $root = Get-HiveRoot $Hive
        $k = $root.OpenSubKey($Sub, $false)
        if ($null -eq $k) { return $null }
        $v = $k.GetValue($Name, $null)
        $k.Close()
        if ($null -eq $v) { return $null }
        return ,$v
    } catch { return $null }
}

function Test-ApprovedEnabled {
    param($Bytes)
    if ($null -eq $Bytes) { return $true }
    $arr = $null
    if ($Bytes -is [byte[]]) { $arr = $Bytes }
    elseif ($Bytes -is [array]) { $arr = $Bytes }
    if ($null -ne $arr -and $arr.Length -ge 1) {
        return ((([byte]$arr[0]) -band 1) -eq 0)
    }
    return $true
}

function Set-ApprovedState {
    param([string]$Hive, [string]$Sub, [string]$Name, [bool]$Enabled)
    $root = Get-HiveRoot $Hive
    $k = $null
    try { $k = $root.OpenSubKey($Sub, $true) } catch { $k = $null }
    if ($null -eq $k) {
        $k = $root.CreateSubKey($Sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree)
    }
    if ($null -eq $k) { throw '无法写入启动项状态（权限不足）' }
    $bytes = New-Object 'byte[]' 12
    for ($i = 0; $i -lt 12; $i++) { $bytes[$i] = 0 }
    if ($Enabled) { $bytes[0] = 2 } else { $bytes[0] = 3 }
    $k.SetValue($Name, $bytes, [Microsoft.Win32.RegistryValueKind]::Binary)
    $k.Close()
}

# ------------------------------------------------------------------
# 扫描
# ------------------------------------------------------------------
$script:RegSources = @(
    @{ Hive='HKCU'; Sub='Software\Microsoft\Windows\CurrentVersion\Run';          Label='注册表 · 当前用户'; ApprovedHive='HKCU'; ApprovedSub='Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';       Once=$false },
    @{ Hive='HKCU'; Sub='Software\Microsoft\Windows\CurrentVersion\RunOnce';     Label='注册表 · 当前用户 RunOnce'; ApprovedHive=''; ApprovedSub=''; Once=$true },
    @{ Hive='HKLM'; Sub='Software\Microsoft\Windows\CurrentVersion\Run';          Label='注册表 · 所有用户'; ApprovedHive='HKLM'; ApprovedSub='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';   Once=$false },
    @{ Hive='HKLM'; Sub='Software\Microsoft\Windows\CurrentVersion\RunOnce';     Label='注册表 · 所有用户 RunOnce'; ApprovedHive=''; ApprovedSub=''; Once=$true },
    @{ Hive='HKLM'; Sub='Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Label='注册表 · 32 位'; ApprovedHive='HKLM'; ApprovedSub='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; Once=$false }
)

$script:RunableExt = @('.lnk','.exe','.bat','.cmd','.vbs','.vbe','.js','.jse','.wsf','.url','.com','.ps1','.msc','.pif')

function Read-ServiceTouched {
    $map = @{}
    try {
        if (Test-Path -LiteralPath $script:ServiceFile) {
            $raw = [IO.File]::ReadAllText($script:ServiceFile, [Text.Encoding]::UTF8)
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = ConvertFrom-Json -InputObject $raw
                foreach ($p in $obj.PSObject.Properties) {
                    if ($p.Value -eq $true) { $map[[string]$p.Name] = $true }
                }
            }
        }
    } catch { }
    return $map
}

function Save-ServiceTouched {
    param($Map)
    $obj = @{}
    foreach ($k in @($Map.Keys)) { if ($Map[$k]) { $obj[[string]$k] = $true } }
    try {
        $json = ConvertTo-Json -InputObject $obj -Depth 3
        if ([string]::IsNullOrWhiteSpace($json)) { $json = '{}' }
        [IO.File]::WriteAllText($script:ServiceFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Log ('保存服务变更记录失败: ' + $_.Exception.Message) }
}

function Get-FileCompany {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $key = $Path.ToLowerInvariant()
    if ($script:CompanyCache.ContainsKey($key)) { return $script:CompanyCache[$key] }
    $company = ''
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $company = [string](Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo.CompanyName
        }
    } catch { }
    $script:CompanyCache[$key] = $company
    return $company
}

function Get-StartupEntries {
    $result = New-Object System.Collections.ArrayList

    # --- 注册表 ---
    foreach ($src in $script:RegSources) {
        $root = Get-HiveRoot $src.Hive
        $key = $null
        try { $key = $root.OpenSubKey($src.Sub, $false) } catch { $key = $null }
        if ($null -eq $key) { continue }
        $names = @()
        try { $names = @($key.GetValueNames()) } catch { }
        foreach ($name in $names) {
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            try {
                $raw  = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $kind = $key.GetValueKind($name)
            } catch { continue }
            $cmd = ''
            if ($raw -is [byte[]]) { $cmd = '<二进制数据>' } else { $cmd = [string]$raw }
            $enabled = $true
            if (-not $src.Once -and $src.ApprovedSub) {
                $enabled = Test-ApprovedEnabled (Get-ApprovedBytes $src.ApprovedHive $src.ApprovedSub $name)
            }
            $e = New-Entry -Kind $(if ($src.Once) { 'RunOnce' } else { 'Run' }) `
                           -Id ('reg|' + $src.Hive + '|' + $src.Sub + '|' + $name) `
                           -Name $name -Sub $cmd -Badge $src.Label -Enabled $enabled
            $e.Command      = $cmd
            $e.Hive         = $src.Hive
            $e.RegSub       = $src.Sub
            $e.RegName      = $name
            $e.RegKind      = [string]$kind
            $e.ApprovedHive = $src.ApprovedHive
            $e.ApprovedSub  = $src.ApprovedSub
            $e.TargetPath   = Get-ExecutablePath $cmd
            if ($e.TargetPath -and -not (Test-Path -LiteralPath $e.TargetPath -PathType Leaf)) { $e.Missing = $true }
            if ($e.TargetPath -and (Test-Path -LiteralPath $e.TargetPath -PathType Leaf)) {
                $e.IconSource = Get-FileIcon $e.TargetPath
            }
            Update-EntryVisual $e
            [void]$result.Add($e)
        }
        $key.Close()
    }

    # --- 启动文件夹 ---
    $folders = @(
        @{ Path=[Environment]::GetFolderPath('Startup');       Label='启动文件夹 · 当前用户'; Hive='HKCU'; Sub='Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' },
        @{ Path=[Environment]::GetFolderPath('CommonStartup'); Label='启动文件夹 · 所有用户'; Hive='HKLM'; Sub='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
    )
    foreach ($f in $folders) {
        if (-not $f.Path -or -not (Test-Path -LiteralPath $f.Path)) { continue }
        $files = @()
        try { $files = @(Get-ChildItem -LiteralPath $f.Path -File -Force -ErrorAction Stop) } catch { }
        foreach ($file in $files) {
            if ($file.Name -ieq 'desktop.ini' -or $file.Name -ieq 'thumbs.db') { continue }
            $ext = [IO.Path]::GetExtension($file.Name).ToLowerInvariant()
            $cmd = $file.FullName
            $target = $file.FullName
            if ($ext -eq '.lnk') {
                $info = Get-ShortcutInfo $file.FullName
                if ($info) {
                    $target = $info.Target
                    if ($info.Args) { $cmd = ('"' + $info.Target + '" ' + $info.Args) } else { $cmd = '"' + $info.Target + '"' }
                }
            }
            $enabled = Test-ApprovedEnabled (Get-ApprovedBytes $f.Hive $f.Sub $file.Name)
            $e = New-Entry -Kind 'Folder' -Id ('folder|' + $file.FullName) -Name $file.Name -Sub $cmd -Badge $f.Label -Enabled $enabled
            $e.Command      = $cmd
            $e.FilePath     = $file.FullName
            $e.TargetPath   = $target
            $e.ApprovedHive = $f.Hive
            $e.ApprovedSub  = $f.Sub
            if ($ext -notin $script:RunableExt) {
                $e.NoteNotRunnable = $true
            }
            if ($target -and -not (Test-Path -LiteralPath $target -PathType Leaf) -and $ext -eq '.lnk') { $e.Missing = $true }
            if ($ext -eq '.lnk' -and $target) { $e.IconSource = Get-FileIcon $target }
            elseif ($ext -eq '.exe' -or $ext -eq '.bat' -or $ext -eq '.cmd') { $e.IconSource = Get-FileIcon $file.FullName }
            Update-EntryVisual $e
            [void]$result.Add($e)
        }
    }

    # --- 计划任务（登录 / 开机触发）---
    $tasks = @()
    try {
        if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
            $tasks = @(Get-ScheduledTask -ErrorAction Stop)
        }
    } catch { Write-Log ('读取计划任务失败: ' + $_.Exception.Message) }
    foreach ($t in $tasks) {
        $logonTriggers = @()
        try {
            $logonTriggers = @($t.Triggers | Where-Object { $null -ne $_ -and $_.CimClass.CimClassName -match 'LogonTrigger|BootTrigger' })
        } catch { }
        if ($logonTriggers.Count -eq 0) { continue }
        $kindText = '登录时启动'
        $isBoot = $false
        foreach ($tr in $logonTriggers) {
            if ($tr.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger') { $isBoot = $true }
        }
        if ($isBoot) { $kindText = '开机时启动' }
        $delayText = ''
        try { if ($logonTriggers[0].Delay) { $delayText = ' · 延迟 ' + $logonTriggers[0].Delay } } catch { }
        $cmd = ''
        $exe = ''
        try {
            $act = @($t.Actions)[0]
            if ($act) {
                $exe = [string]$act.Execute
                $cmd = $exe
                if ($act.Arguments) { $cmd = $cmd + ' ' + $act.Arguments }
            }
        } catch { }
        $enabled = $true
        if ($t.State -eq 'Disabled') { $enabled = $false }
        $isSystem = $false
        if ($t.TaskPath -like '\Microsoft\*') { $isSystem = $true }
        if (-not $isSystem) {
            try {
                if ([string]$t.Author -match 'Microsoft') { $isSystem = $true }
            } catch { }
        }
        $e = New-Entry -Kind 'Task' -Id ('task|' + $t.TaskPath + '|' + $t.TaskName) -Name $t.TaskName `
                       -Sub ($kindText + $delayText + '  ·  ' + $cmd) -Badge '计划任务' -Enabled $enabled
        $e.Command    = $cmd
        $e.TaskName   = $t.TaskName
        $e.TaskPath   = $t.TaskPath
        $e.IsSystem   = $isSystem
        $e.TargetPath = Get-ExecutablePath $cmd
        if ($e.TargetPath -and -not (Test-Path -LiteralPath $e.TargetPath -PathType Leaf)) { $e.Missing = $true }
        if ($e.TargetPath -and (Test-Path -LiteralPath $e.TargetPath -PathType Leaf)) { $e.IconSource = Get-FileIcon $e.TargetPath }
        Update-EntryVisual $e
        [void]$result.Add($e)
    }

    # --- 自动启动服务（含本工具改成的“手动”，保证可回开）---
    $services = @()
    try { $services = @(Get-CimInstance Win32_Service -ErrorAction Stop) } catch { }
    $touched = Read-ServiceTouched
    $touchedChanged = $false
    foreach ($s in $services) {
        $isAuto = ([string]$s.StartMode -eq 'Auto')
        $wasDisabled = $touched.ContainsKey([string]$s.Name)
        if (-not $isAuto -and -not $wasDisabled) { continue }
        if ($isAuto -and $wasDisabled) {
            $touched.Remove([string]$s.Name)
            $touchedChanged = $true
        }
        $path = [string]$s.PathName
        $target = Get-ExecutablePath $path
        $isSystem = $false
        if ($target) {
            $company = Get-FileCompany $target
            if ($company -match 'Microsoft') { $isSystem = $true }
        }
        $badge = '自动服务'
        if (-not $isAuto) { $badge = '自动服务 · 已停用' }
        $e = New-Entry -Kind 'Service' -Id ('svc|' + $s.Name) -Name ([string]$s.DisplayName) -Sub $path -Badge $badge -Enabled $isAuto
        $e.Command     = $path
        $e.ServiceName = [string]$s.Name
        $e.TargetPath  = $target
        $e.IsSystem    = $isSystem
        if ($s.State -ne 'Running') { $e.Sub = $path + '  ·  当前已停止' }
        if ($target -and -not (Test-Path -LiteralPath $target -PathType Leaf)) { $e.Missing = $true }
        if ($target -and (Test-Path -LiteralPath $target -PathType Leaf)) { $e.IconSource = Get-FileIcon $target }
        Update-EntryVisual $e
        [void]$result.Add($e)
    }
    if ($touchedChanged) { Save-ServiceTouched $touched }

    return $result
}

# ------------------------------------------------------------------
# 回收站
# ------------------------------------------------------------------
function Read-Quarantine {
    if (-not (Test-Path -LiteralPath $script:QuarantineFile)) { return @() }
    try {
        $raw = [IO.File]::ReadAllText($script:QuarantineFile, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $d = ConvertFrom-Json -InputObject $raw
        if ($null -eq $d) { return @() }
        return @($d)
    } catch { return @() }
}
function Save-Quarantine {
    param($List)
    try {
        $json = ConvertTo-Json -InputObject @($List) -Depth 6
        if ($null -eq $json) { $json = '[]' }
        [IO.File]::WriteAllText($script:QuarantineFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Log ('保存回收站失败: ' + $_.Exception.Message) }
}

function Get-TrashEntries {
    $out = New-Object System.Collections.ArrayList
    $list = Read-Quarantine
    foreach ($q in $list) {
        $subText = ''
        switch ([string]$q.Kind) {
            'Run'     { $subText = '原位置：注册表 ' + $q.Hive + '\' + $q.RegSub + ' → ' + $q.RegName }
            'RunOnce' { $subText = '原位置：注册表 ' + $q.Hive + '\' + $q.RegSub + ' → ' + $q.RegName }
            'Folder'  { $subText = '原文件：' + $q.FilePath }
            'Task'    { $subText = '原任务：' + $q.TaskPath + $q.TaskName }
            default   { $subText = [string]$q.Command }
        }
        $e = New-Entry -Kind 'Trash' -Id ('trash|' + [string]$q.Qid) -Name ([string]$q.Name) -Sub $subText -Badge '回收站' -Enabled $false
        $e.Time         = [string]$q.Time
        $e.Command      = [string]$q.Command
        $e.FilePath     = [string]$q.QuarantineFile
        $e.TargetPath   = [string]$q.QuarantineFile
        $e.Qid          = [string]$q.Qid
        if ($e.TargetPath -and (Test-Path -LiteralPath $e.TargetPath -PathType Leaf)) {
            $e.IconSource = Get-FileIcon $e.TargetPath
        }
        Update-EntryVisual $e
        [void]$out.Add($e)
    }
    return $out
}

# ------------------------------------------------------------------
# 操作
# ------------------------------------------------------------------
function Set-EntryEnabled {
    param($Entry, [bool]$Enabled)
    $e = $Entry
    if ($e.Kind -eq 'Run' -or $e.Kind -eq 'RunOnce') {
        if ($e.Kind -eq 'RunOnce') { throw 'RunOnce 是一次性启动项，不支持启用/禁用，只能移除' }
        Set-ApprovedState $e.ApprovedHive $e.ApprovedSub $e.RegName $Enabled
    }
    elseif ($e.Kind -eq 'Folder') {
        Set-ApprovedState $e.ApprovedHive $e.ApprovedSub (Split-Path -Leaf $e.FilePath) $Enabled
    }
    elseif ($e.Kind -eq 'Task') {
        if ($Enabled) {
            Enable-ScheduledTask -TaskName $e.TaskName -TaskPath $e.TaskPath -ErrorAction Stop | Out-Null
        } else {
            Disable-ScheduledTask -TaskName $e.TaskName -TaskPath $e.TaskPath -ErrorAction Stop | Out-Null
        }
    }
    elseif ($e.Kind -eq 'Service') {
        if ($Enabled) { Set-Service -Name $e.ServiceName -StartupType Automatic -ErrorAction Stop }
        else          { Set-Service -Name $e.ServiceName -StartupType Manual    -ErrorAction Stop }
        $touched = Read-ServiceTouched
        if ($Enabled) { $touched.Remove([string]$e.ServiceName) }
        else          { $touched[[string]$e.ServiceName] = $true }
        Save-ServiceTouched $touched
        if ($Enabled) { $e.Badge = '自动服务' } else { $e.Badge = '自动服务 · 已停用' }
    }
    else { throw '该类项目不支持开关操作' }
    $e.Enabled = $Enabled
    Update-EntryVisual $e
}

function Remove-Entry {
    param($Entry)
    $e = $Entry
    $q = @{
        Qid = [Guid]::NewGuid().ToString('N')
        Time = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Kind = $e.Kind; Name = $e.Name; Command = $e.Command; Badge = $e.Badge
        Hive = $e.Hive; RegSub = $e.RegSub; RegName = $e.RegName; RegKind = $e.RegKind
        FilePath = $e.FilePath; QuarantineFile = ''; IsBinary = $false; RegValue = ''
        TaskName = $e.TaskName; TaskPath = $e.TaskPath; TaskXml = ''
    }
    if ($e.Kind -eq 'Run' -or $e.Kind -eq 'RunOnce') {
        $root = Get-HiveRoot $e.Hive
        $k = $root.OpenSubKey($e.RegSub, $true)
        if ($null -eq $k) { throw '无法打开注册表项（可能需要管理员权限）' }
        $raw  = $k.GetValue($e.RegName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = $k.GetValueKind($e.RegName)
        if ($raw -is [byte[]]) {
            $q.IsBinary = $true
            $q.RegValue = [Convert]::ToBase64String([byte[]]$raw)
        } else {
            $q.RegValue = [string]$raw
        }
        $q.RegKind = [string]$kind
        $k.DeleteValue($e.RegName, $false)
        $k.Close()
    }
    elseif ($e.Kind -eq 'Folder') {
        if (-not (Test-Path -LiteralPath $e.FilePath)) { throw '启动文件不存在，可能已被删除' }
        $target = Join-Path $script:QuarantineDir ($q.Qid + '_' + (Split-Path -Leaf $e.FilePath))
        Move-Item -LiteralPath $e.FilePath -Destination $target -Force -ErrorAction Stop
        $q.QuarantineFile = $target
    }
    elseif ($e.Kind -eq 'Task') {
        try {
            $q.TaskXml = Export-ScheduledTask -TaskName $e.TaskName -TaskPath $e.TaskPath -ErrorAction Stop
        } catch { $q.TaskXml = '' }
        Unregister-ScheduledTask -TaskName $e.TaskName -TaskPath $e.TaskPath -Confirm:$false -ErrorAction Stop
    }
    else { throw '该类项目不支持移除' }

    $list = Read-Quarantine
    $list = @($list) + @([pscustomobject]$q)
    Save-Quarantine $list
}

function Restore-Entry {
    param($TrashEntry)
    $list = @(Read-Quarantine)
    $found = $null
    foreach ($q in $list) {
        if ([string]$q.Qid -eq [string]$TrashEntry.Qid) { $found = $q; break }
    }
    if ($null -eq $found) { throw '回收站记录已丢失' }
    switch ([string]$found.Kind) {
        'Run' {
            $root = Get-HiveRoot $found.Hive
            $k = $null
            try { $k = $root.OpenSubKey($found.RegSub, $true) } catch { $k = $null }
            if ($null -eq $k) { $k = $root.CreateSubKey($found.RegSub) }
            if ($null -eq $k) { throw '无法写入注册表（可能需要管理员权限）' }
            $vk = [Microsoft.Win32.RegistryValueKind]::String
            try { $vk = [Enum]::Parse([Microsoft.Win32.RegistryValueKind], [string]$found.RegKind) } catch { }
            if ($found.IsBinary) {
                $bytes = [Convert]::FromBase64String([string]$found.RegValue)
                $k.SetValue([string]$found.RegName, $bytes, [Microsoft.Win32.RegistryValueKind]::Binary)
            } else {
                $k.SetValue([string]$found.RegName, [string]$found.RegValue, $vk)
            }
            $k.Close()
        }
        'RunOnce' {
            $root = Get-HiveRoot $found.Hive
            $k = $root.CreateSubKey([string]$found.RegSub)
            $k.SetValue([string]$found.RegName, [string]$found.RegValue, [Microsoft.Win32.RegistryValueKind]::String)
            $k.Close()
        }
        'Folder' {
            if (-not (Test-Path -LiteralPath $found.QuarantineFile)) { throw '备份文件已丢失' }
            $dir = Split-Path -Parent ([string]$found.FilePath)
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $dest = [string]$found.FilePath
            if (Test-Path -LiteralPath $dest) { throw '原位置已存在同名文件，未覆盖' }
            Move-Item -LiteralPath $found.QuarantineFile -Destination $dest -ErrorAction Stop
        }
        'Task' {
            if ([string]::IsNullOrWhiteSpace([string]$found.TaskXml)) { throw '任务备份缺失，无法恢复' }
            Register-ScheduledTask -Xml ([string]$found.TaskXml) -TaskName ([string]$found.TaskName) -TaskPath ([string]$found.TaskPath) -Force -ErrorAction Stop | Out-Null
        }
        default { throw '该记录不支持恢复' }
    }
    $list = @($list | Where-Object { [string]$_.Qid -ne [string]$TrashEntry.Qid })
    Save-Quarantine $list
}

function Remove-QuarantineEntry {
    param($TrashEntry)
    $list = @(Read-Quarantine)
    foreach ($q in $list) {
        if ([string]$q.Qid -eq [string]$TrashEntry.Qid) {
            $qf = [string]$q.QuarantineFile
            if ($qf -and (Test-Path -LiteralPath $qf)) { Remove-Item -LiteralPath $qf -Force -ErrorAction SilentlyContinue }
        }
    }
    $list = @($list | Where-Object { [string]$_.Qid -ne [string]$TrashEntry.Qid })
    Save-Quarantine $list
}

function Open-EntryTarget {
    param($Entry)
    $e = $Entry
    if ($e.Kind -eq 'Trash') {
        if ($e.FilePath -and (Test-Path -LiteralPath $e.FilePath)) {
            Start-Process explorer.exe -ArgumentList ('/select,"' + $e.FilePath + '"')
            return
        }
    }
    if ($e.FilePath -and (Test-Path -LiteralPath $e.FilePath)) {
        Start-Process explorer.exe -ArgumentList ('/select,"' + $e.FilePath + '"')
        return
    }
    if ($e.TargetPath -and (Test-Path -LiteralPath $e.TargetPath)) {
        Start-Process explorer.exe -ArgumentList ('/select,"' + $e.TargetPath + '"')
        return
    }
    if ($e.Command) {
        Set-Clipboard -Value $e.Command
        Show-Toast '目标文件不存在，启动命令已复制到剪贴板'
        return
    }
    Show-Toast '没有可定位的目标'
}

# ------------------------------------------------------------------
# 添加
# ------------------------------------------------------------------
function Get-UniquePath {
    param([string]$Dir, [string]$FileName)
    $full = Join-Path $Dir $FileName
    if (-not (Test-Path -LiteralPath $full)) { return $full }
    $base = [IO.Path]::GetFileNameWithoutExtension($FileName)
    $ext  = [IO.Path]::GetExtension($FileName)
    $i = 2
    while ($true) {
        $cand = Join-Path $Dir ($base + ' (' + $i + ')' + $ext)
        if (-not (Test-Path -LiteralPath $cand)) { return $cand }
        $i++
        if ($i -gt 99) { return $cand }
    }
}

function Add-StartupFiles {
    param([string[]]$Paths)
    $added = 0; $skipped = @(); $failed = @()
    $folder = [Environment]::GetFolderPath('Startup')
    foreach ($p in $Paths) {
        try {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if (-not (Test-Path -LiteralPath $p)) { $failed += (Split-Path -Leaf $p) + '（路径不存在）'; continue }
            $item = Get-Item -LiteralPath $p -ErrorAction Stop
            if ($item.PSIsContainer) {
                if ($script:AddMode -eq 'reg') {
                    # 文件夹没有可执行入口，跳过
                    $skipped += ($item.Name + '（文件夹不能直接作为启动项）')
                } else {
                    $skipped += ($item.Name + '（文件夹不能直接作为启动项）')
                }
                continue
            }
            if ($script:AddMode -eq 'reg') {
                $name = [IO.Path]::GetFileNameWithoutExtension($item.Name)
                $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
                if ($null -eq $key) { throw '无法写入注册表' }
                $exists = $false
                try { $exists = ($key.GetValueNames() -contains $name) } catch { }
                if ($exists) { $name = $name + ' (' + (Get-Date -Format 'HHmmss') + ')' }
                $key.SetValue($name, ('"' + $item.FullName + '"'), [Microsoft.Win32.RegistryValueKind]::String)
                $key.Close()
                $added++
            } else {
                if ($item.Extension -ieq '.lnk') {
                    $dest = Get-UniquePath $folder $item.Name
                    Copy-Item -LiteralPath $item.FullName -Destination $dest -ErrorAction Stop
                    $added++
                } elseif ($item.Extension -ieq '.exe' -or $item.Extension -ieq '.bat' -or $item.Extension -ieq '.cmd' -or
                          $item.Extension -ieq '.vbs' -or $item.Extension -ieq '.vbe' -or $item.Extension -ieq '.js' -or
                          $item.Extension -ieq '.wsf' -or $item.Extension -ieq '.url' -or $item.Extension -ieq '.com') {
                    $lnk = Get-UniquePath $folder (([IO.Path]::GetFileNameWithoutExtension($item.Name)) + '.lnk')
                    $sc = $script:Shell.CreateShortcut($lnk)
                    $sc.TargetPath = $item.FullName
                    $sc.WorkingDirectory = $item.DirectoryName
                    $sc.Description = '由自启管家添加'
                    $sc.Save()
                    $added++
                } elseif ($item.Extension -ieq '.ps1') {
                    $lnk = Get-UniquePath $folder (([IO.Path]::GetFileNameWithoutExtension($item.Name)) + '.lnk')
                    $sc = $script:Shell.CreateShortcut($lnk)
                    $sc.TargetPath = 'powershell.exe'
                    $sc.Arguments  = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $item.FullName + '"'
                    $sc.WorkingDirectory = $item.DirectoryName
                    $sc.Description = '由自启管家添加'
                    $sc.Save()
                    $added++
                } else {
                    $skipped += ($item.Name + '（该类型不会随系统自启）')
                }
            }
        } catch {
            $failed += ((Split-Path -Leaf $p) + '（' + $_.Exception.Message + '）')
        }
    }
    return [pscustomobject]@{ Added = $added; Skipped = $skipped; Failed = $failed }
}

# ------------------------------------------------------------------
# 界面工具
# ------------------------------------------------------------------
function Set-Status {
    param([string]$Text)
    try { $script:UI.StatusText.Text = $Text } catch { }
}
function Show-Toast {
    param([string]$Text)
    try {
        $script:UI.ToastText.Text = $Text
        $script:UI.Toast.Opacity = 1
        $script:ToastTimer.Stop()
        $script:ToastTimer.Start()
    } catch { }
}
function Update-GuiPump {
    try {
        $script:Window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render, [System.Action]{})
    } catch { }
}

function Show-Confirm {
    param([string]$Title, [string]$Message, [string]$OkText = '确定', [string]$CancelText = '取消', [switch]$Danger)
    $dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        SizeToContent="WidthAndHeight" MaxWidth="520" FontFamily="Microsoft YaHei UI">
  <Window.Resources>
    <Style x:Key="DlgBtn" TargetType="{x:Type Button}">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Width" Value="92"/>
      <Setter Property="Foreground" Value="#B9C8DE"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Button}">
            <Border x:Name="bg" CornerRadius="9" Background="#1A2230">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bg" Property="Background" Value="#243043"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DlgPrimary" TargetType="{x:Type Button}">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Width" Value="92"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Button}">
            <Border x:Name="bg" CornerRadius="9">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                  <GradientStop Color="#3B82F6" Offset="0"/>
                  <GradientStop Color="#2E6FE0" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bg" Property="Opacity" Value="0.86"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border x:Name="DlgFrame" Margin="16" CornerRadius="14" Background="#0E131B" BorderBrush="#26324A" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect BlurRadius="26" ShadowDepth="0" Opacity="0.6" Color="#000000"/>
    </Border.Effect>
    <StackPanel Margin="24,22,24,22" Width="420">
      <TextBlock x:Name="DlgTitle" Text="确认操作" Foreground="#EDF3FC" FontSize="15" FontWeight="SemiBold"/>
      <TextBlock x:Name="DlgMsg" Foreground="#95A6BF" FontSize="12.5" TextWrapping="Wrap" Margin="0,10,0,0" LineHeight="21"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
        <Button x:Name="DlgCancel" Content="取消" Style="{StaticResource DlgBtn}"/>
        <Button x:Name="DlgOk" Content="确定" Style="{StaticResource DlgPrimary}" Margin="0"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($dlgXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))
    $dlg.FindName('DlgTitle').Text   = $Title
    $dlg.FindName('DlgMsg').Text     = $Message
    $dlg.FindName('DlgOk').Content   = $OkText
    $dlg.FindName('DlgCancel').Content = $CancelText
    if ($Danger) {
        $dlg.FindName('DlgOk').Foreground = $script:BrushRed
    }
    $dlg.Owner = $script:Window
    $script:DlgResult = $false
    $script:DlgWindow = $dlg
    $dlg.FindName('DlgOk').Add_Click({    $script:DlgResult = $true;  $script:DlgWindow.Close() })
    $dlg.FindName('DlgCancel').Add_Click({ $script:DlgResult = $false; $script:DlgWindow.Close() })
    $dlg.FindName('DlgFrame').Add_MouseLeftButtonDown({
        try { $script:DlgWindow.DragMove() } catch { }
    })
    $dlg.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Escape') { $script:DlgResult = $false; $script:DlgWindow.Close() }
    })
    $null = $dlg.ShowDialog()
    return [bool]$script:DlgResult
}

# ------------------------------------------------------------------
# XAML 主界面
# ------------------------------------------------------------------
$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="自启管家 · 启动项管理器"
        Width="1180" Height="756" MinWidth="900" MinHeight="560"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" WindowStartupLocation="Manual"
        FontFamily="Microsoft YaHei UI" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display" SnapsToDevicePixels="True">

  <Window.Resources>

    <LinearGradientBrush x:Key="TileReg" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#4A8CF7" Offset="0"/><GradientStop Color="#1D4ED8" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="TileFolder" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#21C4AE" Offset="0"/><GradientStop Color="#0F766E" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="TileTask" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#F8B84E" Offset="0"/><GradientStop Color="#B45309" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="TileService" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#7B8CA6" Offset="0"/><GradientStop Color="#334155" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="TileTrash" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#5C6675" Offset="0"/><GradientStop Color="#1F2937" Offset="1"/>
    </LinearGradientBrush>

    <Style x:Key="HiddenRepeat" TargetType="{x:Type RepeatButton}">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type RepeatButton}">
            <Border Background="Transparent"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ScrollThumb" TargetType="{x:Type Thumb}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Thumb}">
            <Border x:Name="t" CornerRadius="4" Background="#26303F" Margin="1"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="t" Property="Background" Value="#3B4961"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="{x:Type ScrollBar}">
      <Setter Property="Width" Value="9"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ScrollBar}">
            <Border Background="Transparent" Padding="1,0">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Style="{StaticResource HiddenRepeat}"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Style="{StaticResource ScrollThumb}"/>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Style="{StaticResource HiddenRepeat}"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GhostButton" TargetType="{x:Type Button}">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Foreground" Value="#A9BAD3"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Button}">
            <Border x:Name="bg" CornerRadius="9" Background="#141C29" BorderBrush="#232F42" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#1B2637"/>
                <Setter TargetName="bg" Property="BorderBrush" Value="#2F405A"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="{x:Type Button}">
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Button}">
            <Border x:Name="bg" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                  <GradientStop Color="#3B82F6" Offset="0"/>
                  <GradientStop Color="#2563EB" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Opacity" Value="0.88"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bg" Property="Opacity" Value="0.72"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="MiniButton" TargetType="{x:Type Button}">
      <Setter Property="Height" Value="27"/>
      <Setter Property="Foreground" Value="#9CAEC8"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Button}">
            <Border x:Name="bg" CornerRadius="7" Background="#18202E" BorderBrush="#232E40" BorderThickness="1" Padding="9,0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#212C3F"/>
                <Setter TargetName="bg" Property="BorderBrush" Value="#31415A"/>
                <Setter Property="Foreground" Value="#D6E3F6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DangerMiniButton" TargetType="{x:Type Button}" BasedOn="{StaticResource MiniButton}">
      <Setter Property="Foreground" Value="#E2A0A8"/>
    </Style>

    <Style x:Key="SwitchStyle" TargetType="{x:Type ToggleButton}">
      <Setter Property="Width" Value="40"/>
      <Setter Property="Height" Value="22"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ToggleButton}">
            <Border x:Name="track" CornerRadius="11" Background="#232C3C" BorderBrush="#2C374A" BorderThickness="1">
              <Border x:Name="knob" Width="15" Height="15" CornerRadius="7.5" Background="#6E7E96"
                      HorizontalAlignment="Left" Margin="3,0,0,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#153226"/>
                <Setter TargetName="track" Property="BorderBrush" Value="#1E4A36"/>
                <Setter TargetName="knob" Property="Background" Value="#35D07F"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="knob" Property="Margin" Value="0,0,3,0"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="track" Property="BorderBrush" Value="#3A4C66"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ChipToggle" TargetType="{x:Type ToggleButton}">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Foreground" Value="#8FA2BD"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ToggleButton}">
            <Border x:Name="bg" CornerRadius="9" Background="#141C29" BorderBrush="#232F42" BorderThickness="1" Padding="12,0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#1B2637"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#152C45"/>
                <Setter TargetName="bg" Property="BorderBrush" Value="#2A4E78"/>
                <Setter Property="Foreground" Value="#CBDFFA"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="NavItem" TargetType="{x:Type RadioButton}">
      <Setter Property="Height" Value="42"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
      <Setter Property="Foreground" Value="#8392AA"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type RadioButton}">
            <Border x:Name="bg" CornerRadius="9" Background="Transparent">
              <Grid>
                <Border x:Name="bar" Width="3" Height="16" CornerRadius="2" Background="#3B82F6"
                        HorizontalAlignment="Left" VerticalAlignment="Center" Opacity="0"/>
                <ContentPresenter Margin="16,0,12,0" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#121924"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#141C29"/>
                <Setter TargetName="bar" Property="Opacity" Value="1"/>
                <Setter Property="Foreground" Value="#E5EEFB"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="WinBtn" TargetType="{x:Type Button}">
      <Setter Property="Width" Value="34"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="Foreground" Value="#8B9AB2"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Button}">
            <Border x:Name="bg" CornerRadius="7" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#1A2331"/>
                <Setter Property="Foreground" Value="#DDE8F7"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CloseBtn" TargetType="{x:Type Button}" BasedOn="{StaticResource WinBtn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Button}">
            <Border x:Name="bg" CornerRadius="7" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#D6455D"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="RowContainer" TargetType="{x:Type ListBoxItem}">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Margin" Value="0,0,0,9"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ListBoxItem}">
            <Border x:Name="host" CornerRadius="12" Background="#101722">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="host" Property="Background" Value="#151E2C"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="host" Property="Background" Value="#151E2C"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <DataTemplate x:Key="EntryTemplate">
      <Border Background="Transparent" BorderBrush="#1B2333" BorderThickness="1" CornerRadius="12" Padding="14,11">
        <DockPanel LastChildFill="True">

          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center" Margin="14,0,0,0">
            <ToggleButton Tag="toggle" Style="{StaticResource SwitchStyle}"
                          IsChecked="{Binding Enabled, Mode=OneWay}"
                          Visibility="{Binding ToggleVis}"
                          ToolTip="打开/关闭：是否随系统启动"/>
            <Button Tag="open" Content="定位" Style="{StaticResource MiniButton}" Visibility="{Binding OpenVis}"/>
            <Button Tag="remove" Content="移除" Style="{StaticResource DangerMiniButton}" Visibility="{Binding RemoveVis}"/>
            <Button Tag="restore" Content="恢复" Style="{StaticResource MiniButton}" Visibility="{Binding RestoreVis}"/>
            <Button Tag="purge" Content="彻底删除" Style="{StaticResource DangerMiniButton}" Visibility="{Binding PurgeVis}" Margin="0"/>
          </StackPanel>

          <Border DockPanel.Dock="Left" Width="42" Height="42" CornerRadius="11"
                  VerticalAlignment="Center" Margin="0,0,14,0">
            <Border.Style>
              <Style TargetType="{x:Type Border}">
                <Setter Property="Background" Value="{StaticResource TileReg}"/>
                <Style.Triggers>
                  <DataTrigger Binding="{Binding Kind}" Value="Folder">
                    <Setter Property="Background" Value="{StaticResource TileFolder}"/>
                  </DataTrigger>
                  <DataTrigger Binding="{Binding Kind}" Value="Task">
                    <Setter Property="Background" Value="{StaticResource TileTask}"/>
                  </DataTrigger>
                  <DataTrigger Binding="{Binding Kind}" Value="Service">
                    <Setter Property="Background" Value="{StaticResource TileService}"/>
                  </DataTrigger>
                  <DataTrigger Binding="{Binding Kind}" Value="Trash">
                    <Setter Property="Background" Value="{StaticResource TileTrash}"/>
                  </DataTrigger>
                </Style.Triggers>
              </Style>
            </Border.Style>
            <Grid ClipToBounds="True">
              <TextBlock Text="{Binding Letter}" Foreground="#FFFFFF" FontSize="15" FontWeight="SemiBold"
                         HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="{Binding LetterVis}"/>
              <Image Source="{Binding IconSource}" Width="24" Height="24" Stretch="Uniform"
                     HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="{Binding IconVis}"/>
            </Grid>
          </Border>

          <StackPanel VerticalAlignment="Center">
            <DockPanel LastChildFill="True">
              <Border DockPanel.Dock="Right" Background="#17202F" CornerRadius="6" Padding="7,2"
                      VerticalAlignment="Center" Margin="10,0,0,0">
                <TextBlock Text="{Binding Badge}" Foreground="#8296B4" FontSize="10.5"/>
              </Border>
              <TextBlock Text="{Binding Name}" Foreground="#E8F0FB" FontSize="14" FontWeight="SemiBold"
                         TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
            </DockPanel>
            <DockPanel LastChildFill="True" Margin="0,5,0,0">
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" Margin="12,0,0,0" VerticalAlignment="Center">
                <Border Background="#161F2D" CornerRadius="6" Padding="8,2.5,8,2.5">
                  <StackPanel Orientation="Horizontal">
                    <Ellipse Width="6" Height="6" Fill="{Binding StatusColor}" VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <TextBlock Text="{Binding StatusText}" Foreground="{Binding StatusColor}" FontSize="11.5" FontWeight="SemiBold"/>
                  </StackPanel>
                </Border>
              </StackPanel>
              <TextBlock Text="{Binding Sub}" Foreground="#6C7B93" FontSize="11.5"
                         TextTrimming="CharacterEllipsis" ToolTip="{Binding Sub}" VerticalAlignment="Center"/>
            </DockPanel>
          </StackPanel>

        </DockPanel>
      </Border>
    </DataTemplate>

  </Window.Resources>

  <Border x:Name="RootFrame" Margin="16" CornerRadius="18" Background="#0C0F15"
          BorderBrush="#242E3E" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect BlurRadius="28" ShadowDepth="0" Opacity="0.55" Color="#000000"/>
    </Border.Effect>

    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="62"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="40"/>
      </Grid.RowDefinitions>

      <!-- 标题栏 -->
      <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent">
        <DockPanel Margin="22,0,12,0" LastChildFill="False" VerticalAlignment="Center">
          <Border DockPanel.Dock="Left" Width="34" Height="34" CornerRadius="10" VerticalAlignment="Center">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#3B82F6" Offset="0"/>
                <GradientStop Color="#22D3EE" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <TextBlock Text="启" Foreground="#FFFFFF" FontSize="16" FontWeight="Bold"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel DockPanel.Dock="Left" Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="自启管家" Foreground="#F2F7FF" FontSize="16.5" FontWeight="SemiBold"/>
            <TextBlock Text="AUTOSTART MANAGER" Foreground="#54627A" FontSize="9.5" Margin="0,2,0,0"/>
          </StackPanel>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnAdmin" Content="标准权限" Style="{StaticResource GhostButton}" Height="28" FontSize="11"
                    Padding="10,0" Margin="0,0,10,0" ToolTip="点击以管理员身份重启"/>
            <Button x:Name="BtnMin" Content="—" Style="{StaticResource WinBtn}" Margin="0,0,2,0"/>
            <Button x:Name="BtnClose" Content="×" Style="{StaticResource CloseBtn}" FontSize="15"/>
          </StackPanel>
        </DockPanel>
      </Grid>

      <!-- 主体 -->
      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="212"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- 左侧导航 -->
        <Border Grid.Column="0" Background="#090C11" BorderBrush="#161E2B" BorderThickness="0,0,1,0" CornerRadius="0,0,0,17">
          <DockPanel Margin="14,14,14,16" LastChildFill="False">

            <TextBlock DockPanel.Dock="Top" Text="管理范围" Foreground="#4B586E" FontSize="10.5" Margin="6,0,0,10"/>
            <Border DockPanel.Dock="Top" Height="1" Background="#151D2A" Margin="4,0,4,12"/>

            <StackPanel DockPanel.Dock="Top" x:Name="NavPanel">
              <RadioButton x:Name="NavAll" Style="{StaticResource NavItem}" GroupName="nav" IsChecked="True">
                <DockPanel LastChildFill="True">
                  <Border DockPanel.Dock="Right" Background="#18202E" CornerRadius="6" Padding="7,1" VerticalAlignment="Center">
                    <TextBlock x:Name="CntAll" Text="0" Foreground="#7E92AE" FontSize="10.5"/>
                  </Border>
                  <TextBlock Text="常规启动" VerticalAlignment="Center"/>
                </DockPanel>
              </RadioButton>
              <RadioButton x:Name="NavReg" Style="{StaticResource NavItem}" GroupName="nav">
                <DockPanel LastChildFill="True">
                  <Border DockPanel.Dock="Right" Background="#18202E" CornerRadius="6" Padding="7,1" VerticalAlignment="Center">
                    <TextBlock x:Name="CntReg" Text="0" Foreground="#7E92AE" FontSize="10.5"/>
                  </Border>
                  <TextBlock Text="注册表启动" VerticalAlignment="Center"/>
                </DockPanel>
              </RadioButton>
              <RadioButton x:Name="NavFolder" Style="{StaticResource NavItem}" GroupName="nav">
                <DockPanel LastChildFill="True">
                  <Border DockPanel.Dock="Right" Background="#18202E" CornerRadius="6" Padding="7,1" VerticalAlignment="Center">
                    <TextBlock x:Name="CntFolder" Text="0" Foreground="#7E92AE" FontSize="10.5"/>
                  </Border>
                  <TextBlock Text="启动文件夹" VerticalAlignment="Center"/>
                </DockPanel>
              </RadioButton>
              <RadioButton x:Name="NavTask" Style="{StaticResource NavItem}" GroupName="nav">
                <DockPanel LastChildFill="True">
                  <Border DockPanel.Dock="Right" Background="#18202E" CornerRadius="6" Padding="7,1" VerticalAlignment="Center">
                    <TextBlock x:Name="CntTask" Text="0" Foreground="#7E92AE" FontSize="10.5"/>
                  </Border>
                  <TextBlock Text="计划任务" VerticalAlignment="Center"/>
                </DockPanel>
              </RadioButton>
              <RadioButton x:Name="NavSvc" Style="{StaticResource NavItem}" GroupName="nav">
                <DockPanel LastChildFill="True">
                  <Border DockPanel.Dock="Right" Background="#18202E" CornerRadius="6" Padding="7,1" VerticalAlignment="Center">
                    <TextBlock x:Name="CntSvc" Text="0" Foreground="#7E92AE" FontSize="10.5"/>
                  </Border>
                  <TextBlock Text="自动服务" VerticalAlignment="Center"/>
                </DockPanel>
              </RadioButton>
              <RadioButton x:Name="NavTrash" Style="{StaticResource NavItem}" GroupName="nav">
                <DockPanel LastChildFill="True">
                  <Border DockPanel.Dock="Right" Background="#18202E" CornerRadius="6" Padding="7,1" VerticalAlignment="Center">
                    <TextBlock x:Name="CntTrash" Text="0" Foreground="#7E92AE" FontSize="10.5"/>
                  </Border>
                  <TextBlock Text="回收站" VerticalAlignment="Center"/>
                </DockPanel>
              </RadioButton>
            </StackPanel>

            <Border DockPanel.Dock="Top" Height="1" Background="#151D2A" Margin="4,14,4,12"/>
            <StackPanel DockPanel.Dock="Top">
              <TextBlock Text="状态说明" Foreground="#4B586E" FontSize="10.5" Margin="6,0,0,8"/>
              <DockPanel Margin="6,0,0,6">
                <Ellipse Width="6" Height="6" Fill="#38D996" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <TextBlock Text="正在随系统启动" Foreground="#64748B" FontSize="10.5"/>
              </DockPanel>
              <DockPanel Margin="6,0,0,6">
                <Ellipse Width="6" Height="6" Fill="#7D8CA5" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <TextBlock Text="已禁用，可随时恢复" Foreground="#64748B" FontSize="10.5"/>
              </DockPanel>
              <DockPanel Margin="6,0,0,0">
                <Ellipse Width="6" Height="6" Fill="#E5A84B" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <TextBlock Text="目标缺失或不会生效" Foreground="#64748B" FontSize="10.5"/>
              </DockPanel>
            </StackPanel>

            <StackPanel DockPanel.Dock="Bottom">
              <Border Height="1" Background="#151D2A" Margin="4,0,4,12"/>
              <Button x:Name="BtnElevate" Content="以管理员身份重启" Style="{StaticResource GhostButton}"
                      Height="32" FontSize="11.5" Margin="0,0,0,10"/>
              <TextBlock Text="开关只控制是否随系统启动，不会删除程序；移除的项目可在回收站恢复。"
                         Foreground="#4A576D" FontSize="10.5" TextWrapping="Wrap" LineHeight="16" Margin="4,0,4,0"/>
            </StackPanel>

          </DockPanel>
        </Border>

        <!-- 右侧内容 -->
        <Grid Grid.Column="1">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <!-- 工具栏 -->
          <Grid Grid.Row="0" Margin="22,18,22,14">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Width="310" Height="36" CornerRadius="10" Background="#111823"
                    BorderBrush="#202A3A" BorderThickness="1" Padding="12,0">
              <Grid>
                <TextBlock x:Name="SearchHint" Text="搜索名称、命令或路径…" Foreground="#4D5B71"
                           FontSize="12" VerticalAlignment="Center" IsHitTestVisible="False"/>
                <TextBox x:Name="SearchBox" Background="Transparent" BorderThickness="0" Padding="0"
                         Foreground="#E4EDFA" FontSize="12.5" VerticalAlignment="Center" CaretBrush="#5B9DFF"
                         FocusVisualStyle="{x:Null}"/>
              </Grid>
            </Border>

            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
              <ToggleButton x:Name="ChkSystem" Content="含系统项" Style="{StaticResource ChipToggle}"
                            Visibility="Collapsed" Margin="0,0,10,0"/>
              <Button x:Name="BtnMode" Content="拖入 → 启动文件夹" Style="{StaticResource GhostButton}"
                      Height="36" Padding="12,0" Margin="0,0,10,0" ToolTip="点击切换拖拽添加的目标位置"/>
              <Button x:Name="BtnRefresh" Content="刷新" Style="{StaticResource GhostButton}"
                      Height="36" Width="66" Margin="0,0,10,0"/>
              <Button x:Name="BtnAdd" Content="＋ 添加启动项" Style="{StaticResource PrimaryButton}" Width="132" Height="36"/>
            </StackPanel>
          </Grid>

          <!-- 列表 -->
          <Grid Grid.Row="1" Margin="22,0,22,14">
            <ListBox x:Name="ItemList" Background="Transparent" BorderThickness="0"
                     ItemTemplate="{StaticResource EntryTemplate}"
                     ItemContainerStyle="{StaticResource RowContainer}"
                     ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                     ScrollViewer.VerticalScrollBarVisibility="Auto"
                     SelectionMode="Single" Padding="0,0,6,0"/>

            <StackPanel x:Name="EmptyState" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed">
              <Border Width="60" Height="60" CornerRadius="30" Background="#121924" BorderBrush="#222E40" BorderThickness="1">
                <TextBlock Text="✓" Foreground="#3C4E68" FontSize="24" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <TextBlock x:Name="EmptyTitle" Text="这里没有项目" Foreground="#8FA2BC" FontSize="13.5"
                         HorizontalAlignment="Center" Margin="0,14,0,0"/>
              <TextBlock x:Name="EmptyHint" Text="试试切换左侧分类，或把程序拖进窗口" Foreground="#57657C"
                         FontSize="11.5" HorizontalAlignment="Center" Margin="0,6,0,0"/>
            </StackPanel>

            <Border x:Name="DropZone" Visibility="Collapsed" IsHitTestVisible="False" Background="#F00A0D12"
                    CornerRadius="12">
              <Grid>
                <Rectangle RadiusX="14" RadiusY="14" Stroke="#3B82F6" StrokeThickness="2"
                           StrokeDashArray="5 3" Margin="10" Fill="Transparent"/>
                <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                  <TextBlock Text="＋" FontSize="30" Foreground="#5B9DFF" HorizontalAlignment="Center"/>
                  <TextBlock x:Name="DropZoneText" Text="松开鼠标，添加到启动文件夹" Foreground="#CBD9ED"
                             FontSize="14" HorizontalAlignment="Center" Margin="0,10,0,0"/>
                  <TextBlock Text="支持 .exe / .lnk / .bat / .cmd / .vbs" Foreground="#66758D"
                             FontSize="11.5" HorizontalAlignment="Center" Margin="0,8,0,0"/>
                </StackPanel>
              </Grid>
            </Border>

            <Border x:Name="Toast" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,16"
                    CornerRadius="9" Background="#17202E" BorderBrush="#2C3A50" BorderThickness="1"
                    Padding="16,8" Opacity="0" IsHitTestVisible="False">
              <TextBlock x:Name="ToastText" Foreground="#D8E5F7" FontSize="12"/>
            </Border>
          </Grid>
        </Grid>
      </Grid>

      <!-- 底部状态 -->
      <Border Grid.Row="2" Background="#090C11" CornerRadius="0,0,17,17">
        <DockPanel Margin="22,0,22,0" LastChildFill="True">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0,0,0">
            <Ellipse Width="6" Height="6" Fill="#38D996" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBlock x:Name="StatText" Text="启用 0 · 禁用 0" Foreground="#68778E" FontSize="11"/>
          </StackPanel>
          <TextBlock x:Name="StatusText" Text="就绪" Foreground="#76859C" FontSize="11.5"
                     VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        </DockPanel>
      </Border>

    </Grid>
  </Border>
</Window>
'@

$doc = New-Object System.Xml.XmlDocument
try {
    $doc.LoadXml($script:Xaml)
} catch {
    Write-Host ('XAML 解析失败：' + $_.Exception.Message)
    exit 1
}
try {
    $script:Window = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))
} catch {
    Write-Host ('界面加载失败：' + $_.Exception.Message)
    exit 1
}

if ($SelfTest) {
    Write-Host 'SelfTest OK'
    exit 0
}

# 单实例
if (-not $AllowSecondInstance) {
    try {
        $script:Mutex = New-Object System.Threading.Mutex($false, 'Local\AutoStartManager.Desktop.v1')
        if (-not $script:Mutex.WaitOne(0)) {
            $handle = [AutoStartNative.Win]::ByTitle($script:WindowTitle)
            if ($handle -ne [IntPtr]::Zero) {
                [AutoStartNative.Win]::ShowWindow($handle, 9) | Out-Null
                [AutoStartNative.Win]::SetForegroundWindow($handle) | Out-Null
            }
            exit 0
        }
    } catch { }
}

try { [AutoStartNative.Win]::SetCurrentProcessExplicitAppUserModelID('AutoStartManager.Desktop') | Out-Null } catch { }

# 应用图标
$iconPath = Join-Path $script:AppDir 'app.ico'
if (Test-Path -LiteralPath $iconPath) {
    try {
        $stream = [System.IO.File]::OpenRead($iconPath)
        $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
            $stream,
            [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $best = @($decoder.Frames) | Sort-Object PixelWidth -Descending | Select-Object -First 1
        if ($best) {
            $best.Freeze()
            $script:Window.Icon = $best
        }
        $stream.Close()
    } catch { Write-Log ('载入图标失败: ' + $_.Exception.Message) }
}

# 状态
$script:Items      = @()
$script:TrashItems = @()
$script:View       = 'all'
$script:Search     = ''
$script:ShowSystem = $false
$script:AddMode    = 'folder'

$script:UI = @{
    StatusText = $script:Window.FindName('StatusText')
    StatText   = $script:Window.FindName('StatText')
    Toast      = $script:Window.FindName('Toast')
    ToastText  = $script:Window.FindName('ToastText')
    ItemList   = $script:Window.FindName('ItemList')
    EmptyState = $script:Window.FindName('EmptyState')
    EmptyTitle = $script:Window.FindName('EmptyTitle')
    EmptyHint  = $script:Window.FindName('EmptyHint')
    SearchBox  = $script:Window.FindName('SearchBox')
    SearchHint = $script:Window.FindName('SearchHint')
    ChkSystem  = $script:Window.FindName('ChkSystem')
    DropZone   = $script:Window.FindName('DropZone')
    DropZoneText = $script:Window.FindName('DropZoneText')
    CntAll     = $script:Window.FindName('CntAll')
    CntReg     = $script:Window.FindName('CntReg')
    CntFolder  = $script:Window.FindName('CntFolder')
    CntTask    = $script:Window.FindName('CntTask')
    CntSvc     = $script:Window.FindName('CntSvc')
    CntTrash   = $script:Window.FindName('CntTrash')
    BtnMode    = $script:Window.FindName('BtnMode')
    BtnAdd     = $script:Window.FindName('BtnAdd')
    BtnRefresh = $script:Window.FindName('BtnRefresh')
    BtnClose   = $script:Window.FindName('BtnClose')
    BtnMin     = $script:Window.FindName('BtnMin')
    BtnAdmin   = $script:Window.FindName('BtnAdmin')
    BtnElevate = $script:Window.FindName('BtnElevate')
    RootFrame  = $script:Window.FindName('RootFrame')
    TitleBar   = $script:Window.FindName('TitleBar')
    NavAll     = $script:Window.FindName('NavAll')
    NavReg     = $script:Window.FindName('NavReg')
    NavFolder  = $script:Window.FindName('NavFolder')
    NavTask    = $script:Window.FindName('NavTask')
    NavSvc     = $script:Window.FindName('NavSvc')
    NavTrash   = $script:Window.FindName('NavTrash')
}

if ($DiagScan) {
    foreach ($key in @($script:UI.Keys)) {
        if ($null -eq $script:UI[$key]) { Write-Host ('MISSING UI: ' + $key) }
    }
}

$script:ToastTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ToastTimer.Interval = [TimeSpan]::FromSeconds(2.8)
$script:ToastTimer.Add_Tick({
    try {
        $script:UI.Toast.Opacity = 0
        $script:ToastTimer.Stop()
    } catch { }
})

# ------------------------------------------------------------------
# 列表渲染
# ------------------------------------------------------------------
function Test-EntryVisible {
    param($Entry)
    if ($null -eq $Entry) { return $false }
    switch ($script:View) {
        'all'    { if ($Entry.Kind -ne 'Run' -and $Entry.Kind -ne 'RunOnce' -and $Entry.Kind -ne 'Folder') { return $false } }
        'reg'    { if ($Entry.Kind -ne 'Run' -and $Entry.Kind -ne 'RunOnce') { return $false } }
        'folder' { if ($Entry.Kind -ne 'Folder') { return $false } }
        'task'   { if ($Entry.Kind -ne 'Task') { return $false }
                   if (-not $script:ShowSystem -and $Entry.IsSystem) { return $false } }
        'svc'    { if ($Entry.Kind -ne 'Service') { return $false }
                   if (-not $script:ShowSystem -and $Entry.IsSystem) { return $false } }
        'trash'  { if ($Entry.Kind -ne 'Trash') { return $false } }
    }
    if ($script:Search -ne '') {
        $q = $script:Search.ToLowerInvariant()
        $hay = (([string]$Entry.Name) + ' ' + ([string]$Entry.Sub) + ' ' + ([string]$Entry.Badge) + ' ' + ([string]$Entry.Command)).ToLowerInvariant()
        if (-not $hay.Contains($q)) { return $false }
    }
    return $true
}

function Update-List {
    $visible = @()
    if ($script:View -eq 'trash') {
        $visible = @($script:TrashItems | Where-Object { Test-EntryVisible $_ })
        $visible = @($visible | Sort-Object @{Expression={ [string]$_.Time }; Descending=$true})
    } else {
        $visible = @($script:Items | Where-Object { Test-EntryVisible $_ })
        $visible = @($visible | Sort-Object @{Expression={ [bool]$_.Missing }; Descending=$false},
                                          @{Expression={ [string]$_.Name }})
    }

    $script:UI.ItemList.ItemsSource = $null
    $script:UI.ItemList.ItemsSource = $visible

    $enabledCount = 0
    foreach ($v in $visible) { if ($v.Enabled) { $enabledCount++ } }
    $disabledCount = $visible.Count - $enabledCount
    $script:UI.StatText.Text = ('本页 ' + $visible.Count + ' 项 · 启用 ' + $enabledCount + ' · 禁用 ' + $disabledCount)

    if ($visible.Count -eq 0) {
        $script:UI.EmptyState.Visibility = 'Visible'
        if ($script:Search -ne '') {
            $script:UI.EmptyTitle.Text = '没有匹配的项目'
            $script:UI.EmptyHint.Text  = '换个关键词试试'
        } else {
            $script:UI.EmptyTitle.Text = '这里很干净'
            $script:UI.EmptyHint.Text  = '试试切换左侧分类，或把程序拖进窗口'
        }
    } else {
        $script:UI.EmptyState.Visibility = 'Collapsed'
    }
}

function Update-Counts {
    $u = $script:UI
    $reg   = @($script:Items | Where-Object { $_.Kind -eq 'Run' -or $_.Kind -eq 'RunOnce' }).Count
    $fold  = @($script:Items | Where-Object { $_.Kind -eq 'Folder' }).Count
    $task  = @($script:Items | Where-Object { $_.Kind -eq 'Task' -and ($script:ShowSystem -or -not $_.IsSystem) }).Count
    $svc   = @($script:Items | Where-Object { $_.Kind -eq 'Service' -and ($script:ShowSystem -or -not $_.IsSystem) }).Count
    $trash = @($script:TrashItems).Count
    $u.CntAll.Text    = [string]($reg + $fold)
    $u.CntReg.Text    = [string]$reg
    $u.CntFolder.Text = [string]$fold
    $u.CntTask.Text   = [string]$task
    $u.CntSvc.Text    = [string]$svc
    $u.CntTrash.Text  = [string]$trash
}

function Set-View {
    param([string]$View)
    $script:View = $View
    if ($View -eq 'task' -or $View -eq 'svc') {
        $script:UI.ChkSystem.Visibility = 'Visible'
    } else {
        $script:UI.ChkSystem.Visibility = 'Collapsed'
    }
    Update-List
    if (($View -eq 'task' -or $View -eq 'svc') -and -not $script:ShowSystem) {
        Set-Status '已隐藏系统自带项目，勾选右上角「含系统项」可查看全部'
    }
}

function Invoke-Scan {
    Set-Status '正在扫描启动项…'
    $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    Update-GuiPump
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $script:Items = @(Get-StartupEntries)
        $script:TrashItems = @(Get-TrashEntries)
    } catch {
        Write-Log ('扫描失败: ' + $_.Exception.Message)
        Set-Status ('扫描出错：' + $_.Exception.Message)
    }
    $script:Window.Cursor = [System.Windows.Input.Cursors]::Arrow
    $sw.Stop()
    Update-Counts
    Update-List
    Set-Status ('已扫描 ' + $script:Items.Count + ' 个自启项 · 用时 ' + [string]::Format('{0:0.0}', $sw.Elapsed.TotalSeconds) + ' 秒')
}

# ------------------------------------------------------------------
# 事件绑定
# ------------------------------------------------------------------
$script:UI.BtnClose.Add_Click({ try { $script:Window.Close() } catch { } })
$script:UI.BtnMin.Add_Click({ try { $script:Window.WindowState = 'Minimized' } catch { } })
$script:UI.TitleBar.Add_MouseLeftButtonDown({ try { $script:Window.DragMove() } catch { } })

$script:UI.SearchBox.Add_TextChanged({
    try {
        $script:Search = [string]$script:UI.SearchBox.Text
        if ($script:Search -ne '') { $script:UI.SearchHint.Visibility = 'Collapsed' }
        else { $script:UI.SearchHint.Visibility = 'Visible' }
        Update-List
    } catch { }
})

$script:UI.NavAll.Add_Checked({ try { Set-View 'all' } catch { } })
$script:UI.NavReg.Add_Checked({ try { Set-View 'reg' } catch { } })
$script:UI.NavFolder.Add_Checked({ try { Set-View 'folder' } catch { } })
$script:UI.NavTask.Add_Checked({ try { Set-View 'task' } catch { } })
$script:UI.NavSvc.Add_Checked({ try { Set-View 'svc' } catch { } })
$script:UI.NavTrash.Add_Checked({ try { Set-View 'trash' } catch { } })

$script:UI.ChkSystem.Add_Click({
    try {
        $script:ShowSystem = [bool]$script:UI.ChkSystem.IsChecked
        Update-Counts
        Update-List
    } catch { Write-Log ('切换系统项失败: ' + $_.Exception.Message) }
})

$script:UI.BtnMode.Add_Click({
    try {
        if ($script:AddMode -eq 'folder') {
            $script:AddMode = 'reg'
            $script:UI.BtnMode.Content = '拖入 → 注册表 Run'
            $script:UI.DropZoneText.Text = '松开鼠标，写入注册表 Run（当前用户）'
            Show-Toast '拖入的文件将写入注册表启动项'
        } else {
            $script:AddMode = 'folder'
            $script:UI.BtnMode.Content = '拖入 → 启动文件夹'
            $script:UI.DropZoneText.Text = '松开鼠标，添加到启动文件夹'
            Show-Toast '拖入的文件将放到启动文件夹'
        }
    } catch { }
})

$script:UI.BtnRefresh.Add_Click({
    try { Invoke-Scan } catch { Set-Status ('刷新失败：' + $_.Exception.Message) }
})

$script:UI.BtnAdd.Add_Click({
    try {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = '选择要开机启动的程序'
        $dlg.Filter = '可执行与快捷方式|*.exe;*.lnk;*.bat;*.cmd;*.vbs;*.url;*.ps1|所有文件|*.*'
        $dlg.Multiselect = $true
        $dlg.CheckFileExists = $true
        if ($dlg.ShowDialog($script:Window) -eq $true) {
            $res = Add-StartupFiles -Paths @($dlg.FileNames)
            if ($res.Added -gt 0) { Show-Toast ('已添加 ' + $res.Added + ' 项') }
            if ($res.Skipped.Count -gt 0) { Set-Status ('跳过：' + ($res.Skipped -join '；') ) }
            if ($res.Failed.Count -gt 0)  { Set-Status ('失败：' + ($res.Failed  -join '；') ) }
            Invoke-Scan
        }
    } catch { Set-Status ('添加失败：' + $_.Exception.Message) }
})

$script:UI.BtnAdmin.Add_Click({
    try {
        if ($script:IsAdmin) { Show-Toast '当前已是管理员权限'; return }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.UseShellExecute = $true
        $psi.Verb = 'runas'
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:AppPath + '" -AllowSecondInstance'
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        Start-Sleep -Milliseconds 400
        $script:Window.Close()
    } catch {
        Set-Status '提权被取消或失败'
    }
})

$script:UI.BtnElevate.Add_Click({
    try {
        if ($script:IsAdmin) { Show-Toast '当前已是管理员权限'; return }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.UseShellExecute = $true
        $psi.Verb = 'runas'
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:AppPath + '" -AllowSecondInstance'
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        Start-Sleep -Milliseconds 400
        $script:Window.Close()
    } catch {
        Set-Status '提权被取消或失败'
    }
})

# 列表内按钮（统一在 ListBox 上接住冒泡的 Click）
function Find-RowButton {
    param($Element)
    $el = $Element
    $guard = 0
    while ($null -ne $el -and $guard -lt 24) {
        $guard++
        if ($el -is [System.Windows.Controls.Primitives.ButtonBase]) { return $el }
        if (-not ($el -is [System.Windows.Media.Visual])) { return $null }
        $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el)
    }
    return $null
}

$script:UI.ItemList.AddHandler(
    [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
    [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        try {
            $btn = Find-RowButton $e.OriginalSource
            if ($null -eq $btn) { $btn = Find-RowButton $e.Source }
            if ($null -eq $btn) { return }
            $tag = ''
            try { $tag = [string]$btn.Tag } catch { }
            if ([string]::IsNullOrEmpty($tag)) { return }
            $entry = $null
            try { $entry = $btn.DataContext } catch { }
            if ($null -eq $entry) { return }

            switch ($tag) {
                'toggle' {
                    $desired = -not [bool]$entry.Enabled
                    if ($entry.Kind -eq 'RunOnce') { Show-Toast '一次性启动项不支持开关，只能移除'; return }
                    if ($entry.Kind -eq 'Task' -and -not $script:IsAdmin) {
                        Show-Toast '修改计划任务需要管理员权限'; return
                    }
                    if ($entry.Kind -eq 'Service' -and -not $script:IsAdmin) {
                        Show-Toast '修改服务启动类型需要管理员权限'; return
                    }
                    try {
                        Set-EntryEnabled -Entry $entry -Enabled $desired
                        if ($desired) { Show-Toast ('已启用：' + $entry.Name) } else { Show-Toast ('已禁用：' + $entry.Name) }
                        Update-List
                    } catch {
                        $msg = $_.Exception.Message
                        if ($msg -match '拒绝访问|Access|权限') { $msg = '权限不足，请点击左下角「以管理员身份重启」' }
                        Show-Toast ('操作失败：' + $msg)
                        $script:UI.ItemList.ItemsSource = $null
                        Update-List
                    }
                }
                'open' {
                    Open-EntryTarget -Entry $entry
                }
                'remove' {
                    $body = '将从开机启动中移除：' + $entry.Name
                    if ($entry.Kind -eq 'Service') { $body = '服务不支持移除，请使用开关将其改为手动启动：' + $entry.Name }
                    $ok = Show-Confirm -Title '移除启动项' -Message ($body + "`n`n项目会被放入回收站，可随时恢复。") -OkText '移除' -Danger
                    if (-not $ok) { return }
                    try {
                        Remove-Entry -Entry $entry
                        Show-Toast ('已移除：' + $entry.Name)
                        Invoke-Scan
                    } catch {
                        $msg = $_.Exception.Message
                        if ($msg -match '拒绝访问|Access|权限') { $msg = '权限不足，请点击左下角「以管理员身份重启」' }
                        Show-Toast ('移除失败：' + $msg)
                    }
                }
                'restore' {
                    try {
                        Restore-Entry -TrashEntry $entry
                        Show-Toast ('已恢复：' + $entry.Name)
                        Invoke-Scan
                    } catch {
                        $msg = $_.Exception.Message
                        if ($msg -match '拒绝访问|Access|权限') { $msg = '权限不足，请点击左下角「以管理员身份重启」' }
                        Show-Toast ('恢复失败：' + $msg)
                    }
                }
                'purge' {
                    $ok = Show-Confirm -Title '彻底删除' -Message ('将永久删除回收站中的「' + $entry.Name + '」及其备份文件，无法再恢复。') -OkText '永久删除' -Danger
                    if (-not $ok) { return }
                    try {
                        Remove-QuarantineEntry -TrashEntry $entry
                        Show-Toast '已彻底删除'
                        Invoke-Scan
                    } catch { Show-Toast ('删除失败：' + $_.Exception.Message) }
                }
            }
        } catch {
            Write-Log ('列表操作异常: ' + $_.Exception.Message)
            Set-Status ('操作异常：' + $_.Exception.Message)
        }
    })

# 双击卡片定位文件
$script:UI.ItemList.AddHandler(
    [System.Windows.Controls.Control]::MouseDoubleClickEvent,
    [System.Windows.Input.MouseButtonEventHandler]{
        param($sender, $e)
        try {
            if ($null -ne (Find-RowButton $e.OriginalSource)) { return }
            $el = $e.OriginalSource
            while ($null -ne $el) {
                if ($el -is [System.Windows.Controls.ListBoxItem]) { break }
                if (-not ($el -is [System.Windows.Media.Visual])) { $el = $null; break }
                $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el)
            }
            if ($null -eq $el) { return }
            $entry = $el.DataContext
            if ($null -eq $entry) { return }
            Open-EntryTarget -Entry $entry
        } catch { }
    })

# 拖拽
$script:UI.RootFrame.AllowDrop = $true
$script:UI.RootFrame.Add_DragEnter({
    try {
        if ($_.Data.GetDataPresent('FileDrop')) {
            $_.Effects = 'Copy'
            $script:UI.DropZone.Visibility = 'Visible'
            $_.Handled = $true
        }
    } catch { }
})
$script:UI.RootFrame.Add_DragOver({
    try {
        if ($_.Data.GetDataPresent('FileDrop')) {
            $_.Effects = 'Copy'
            $script:UI.DropZone.Visibility = 'Visible'
            $_.Handled = $true
        }
    } catch { }
})
$script:UI.RootFrame.Add_DragLeave({
    try { $script:UI.DropZone.Visibility = 'Collapsed' } catch { }
})
$script:UI.RootFrame.Add_Drop({
    try {
        $script:UI.DropZone.Visibility = 'Collapsed'
        if (-not $_.Data.GetDataPresent('FileDrop')) { return }
        $paths = @($_.Data.GetData('FileDrop'))
        if ($paths.Count -eq 0) { return }
        $res = Add-StartupFiles -Paths $paths
        if ($res.Added -gt 0) { Show-Toast ('已添加 ' + $res.Added + ' 项到' + $(if ($script:AddMode -eq 'reg') { '注册表' } else { '启动文件夹' })) }
        if ($res.Skipped.Count -gt 0) { Show-Toast ('未添加：' + ($res.Skipped -join '；')) }
        if ($res.Failed.Count -gt 0)  { Show-Toast ('失败：' + ($res.Failed -join '；')) }
        if ($res.Added -gt 0) { Invoke-Scan }
        $_.Handled = $true
    } catch {
        Write-Log ('拖拽添加失败: ' + $_.Exception.Message)
        Set-Status ('添加失败：' + $_.Exception.Message)
    }
})

# 快捷键
$script:Window.Add_KeyDown({
    param($sender, $e)
    try {
        if ($e.Key -eq 'F5') { Invoke-Scan; $e.Handled = $true }
        elseif ($e.Key -eq 'Escape') {
            if ($script:UI.SearchBox.Text -ne '') {
                $script:UI.SearchBox.Text = ''
                $script:UI.SearchHint.Visibility = 'Visible'
                $e.Handled = $true
            }
        }
        elseif ($e.Key -eq 'F' -and [System.Windows.Input.Keyboard]::Modifiers -eq 'Control') {
            $script:UI.SearchBox.Focus() | Out-Null
            $e.Handled = $true
        }
    } catch { }
})

# 窗口尺寸自适应（在显示前定位，避免启动时闪跳）
$wa = [System.Windows.SystemParameters]::WorkArea
$w = [Math]::Max(900, [Math]::Min(1180, $wa.Width - 60))
$h = [Math]::Max(560, [Math]::Min(756,  $wa.Height - 60))
$script:Window.Width  = $w
$script:Window.Height = $h
$script:Window.Left = $wa.Left + [Math]::Floor(($wa.Width - $w) / 2)
$script:Window.Top  = $wa.Top  + [Math]::Floor(($wa.Height - $h) / 2)

# 窗口尺寸自适应
$script:Window.Add_Loaded({
    try {
        if ($script:IsAdmin) {
            $script:UI.BtnAdmin.Content = '管理员'
            $script:UI.BtnAdmin.Foreground = $script:BrushGreen
            $script:UI.BtnAdmin.ToolTip = '已获得管理员权限'
            $script:UI.BtnElevate.IsEnabled = $false
        } else {
            $script:UI.BtnAdmin.Content = '标准权限'
            $script:UI.BtnAdmin.Foreground = $script:BrushAmber
            $script:UI.BtnAdmin.ToolTip = '部分操作（所有用户启动项 / 计划任务 / 服务）需要管理员权限，点击重启'
        }

        if ($DiagScan) {
            Invoke-Scan
            $out = @()
            $out += ('items=' + $script:Items.Count)
            $out += ('trash=' + $script:TrashItems.Count)
            foreach ($g in ($script:Items | Group-Object Kind)) { $out += ($g.Name + '=' + $g.Count) }
            Write-Host ($out -join ' | ')
            $script:Window.Close()
            return
        }

        Invoke-Scan
        Set-Status ('就绪 · 共 ' + $script:Items.Count + ' 个自启项（注册表 / 启动文件夹 / 计划任务 / 服务）')
    } catch {
        Write-Log ('初始化失败: ' + $_.Exception.Message)
        Set-Status ('初始化失败：' + $_.Exception.Message)
    }
})

if ($PreviewShot) {
    try {
        Invoke-Scan
        $content = $script:Window.Content
        $pw = 1180
        $ph = 756
        $content.Measure((New-Object System.Windows.Size($pw, $ph)))
        $content.Arrange((New-Object System.Windows.Rect(0, 0, $pw, $ph)))
        $content.UpdateLayout()

        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($pw, $ph, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $dv = New-Object System.Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $dc.DrawRectangle((New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString('#05080D'))), $null, (New-Object System.Windows.Rect(0, 0, $pw, $ph)))
        $dc.Close()
        $rtb.Render($dv)
        $rtb.Render($content)

        if ([string]::IsNullOrWhiteSpace($PreviewPath)) { $PreviewPath = Join-Path $script:AppDir 'preview.png' }
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [System.IO.File]::Create($PreviewPath)
        $enc.Save($fs)
        $fs.Close()
        Write-Host ('PREVIEW ' + $PreviewPath)
    } catch {
        Write-Host ('PREVIEW FAILED: ' + $_.Exception.Message)
    }
    exit 0
}

$script:Window.ShowDialog() | Out-Null
try { if ($script:Mutex) { $script:Mutex.ReleaseMutex() } } catch { }
