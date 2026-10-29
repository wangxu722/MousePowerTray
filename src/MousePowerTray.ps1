<#
.SYNOPSIS
    蓝牙鼠标电量托盘（通用版）
.DESCRIPTION
    自动识别本机所有通过蓝牙 LE 连接、且暴露标准电池服务的输入设备
    （鼠标 / 键盘 / 手柄），把电量画在 Windows 任务栏托盘上。

    数据来源：Windows 从 BLE 电池服务 (GATT 0x180F / 0x2A19) 采集后
    缓存的设备属性 DEVPKEY_Bluetooth_Battery。只读，不逆向任何厂商协议。

    设计思路参考 Tan-TanZi/InphicBatteryTray。
.PARAMETER SelfTest
    不开界面，扫描一次设备并把结果 / 图标预览写到 preview 目录后退出。
.PARAMETER Diagnose
    不开界面，生成诊断报告到桌面（压缩包），用于排查别人的设备为什么读不到电量。
.PARAMETER Capture
    配合 -Diagnose 使用：抓取厂商 HID 通道的原始帧若干秒，期间按提示操作鼠标。
.PARAMETER CaptureSeconds
    抓包时长，默认 60 秒。
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$Diagnose,
    [switch]$Capture,
    [int]$CaptureSeconds = 60
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------- 常量 ----
$script:AppName = '鼠标电量'
$script:AppId = 'MousePowerTray'
$script:AppVersion = '1.2.0'
$script:DevKey = '{104EA319-6EE2-4701-BD47-8DDBF425BBE5}'   # DEVPKEY_Bluetooth_Battery
$script:RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunName = $script:AppId
$script:LogMaxBytes = 262144
$script:OfflineMs = 20000

# ------------------------------------------------------------- 目录 ----
if ($PSScriptRoot) { $script:Root = $PSScriptRoot }
else { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script:AppDir = $PSScriptRoot
if ($script:AppDir -and (Split-Path -Leaf $script:AppDir) -eq 'src') { $script:AppDir = Split-Path -Parent $script:AppDir }
if (-not $script:AppDir) { $script:AppDir = $script:Root }

# 用户数据统一放 %LOCALAPPDATA%，避免程序目录只读时写不进去
$script:DataDir = Join-Path $env:LOCALAPPDATA $script:AppId
if (-not (Test-Path -LiteralPath $script:DataDir)) {
    try { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null } catch { $script:DataDir = $script:AppDir }
}
$script:LogPath = Join-Path $script:DataDir 'tray.log'
$script:CfgPath = Join-Path $script:DataDir 'config.json'

# ------------------------------------------------------------- 工具 ----
function Write-Log {
    param([string]$Message)
    try {
        if (Test-Path -LiteralPath $script:LogPath) {
            if ((Get-Item -LiteralPath $script:LogPath).Length -gt $script:LogMaxBytes) {
                Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.old') -Force
            }
        }
        Add-Content -LiteralPath $script:LogPath -Encoding UTF8 `
            -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    }
    catch { }
}

function Get-DefaultConfig {
    [pscustomobject]@{
        DeviceId       = ''
        DeviceName     = ''
        NameFilter     = ''      # 为空 = 所有能读电量的蓝牙设备
        RefreshSeconds = 10
        LowPercent     = 15
        LowNotify      = $true
        Debug          = $false
        # 2.4G 接收器（厂商私有通道）
        # 默认留空：不猜、不去碰别人的接收器。诊断报告会给出该填什么。
        UsbVid         = ''
        UsbPid         = ''
        UsbUsagePage   = ''
        # 帧结构：帧类型字节（十六进制，空=不过滤所有帧）、电量字节下标、链路标志下标
        # D1 是 AULA 089D:062F 的状态帧；不过滤的话 D2 帧会被误当成电量
        UsbFrameType   = 'D1'
        UsbLevelIndex  = 3
        UsbLinkIndex   = 2
        LastUsbLevel   = -1
        Version        = 3
    }
}

function Get-Config {
    if (Test-Path -LiteralPath $script:CfgPath) {
        try {
            $raw = Get-Content -LiteralPath $script:CfgPath -Raw -Encoding UTF8
            $obj = $raw | ConvertFrom-Json
            $cfg = Get-DefaultConfig
            foreach ($p in $cfg.PSObject.Properties) {
                if ($obj.PSObject.Properties.Name -contains $p.Name) { $cfg.($p.Name) = $obj.($p.Name) }
            }
            return $cfg
        }
        catch { Write-Log ('CFG-READ-ERR ' + $_.Exception.Message) }
    }
    return (Get-DefaultConfig)
}

function Save-Config {
    try {
        ($script:Cfg | ConvertTo-Json) | Set-Content -LiteralPath $script:CfgPath -Encoding UTF8 -Force
    }
    catch { Write-Log ('CFG-WRITE-ERR ' + $_.Exception.Message) }
}

function Get-RoundPath {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($R -le 0) { $p.AddRectangle((New-Object System.Drawing.RectangleF($X, $Y, $W, $H))); return $p }
    $d = $R * 2
    if ($d -gt $W) { $d = $W }
    if ($d -gt $H) { $d = $H }
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Get-StatusColor {
    param([int]$Level, [bool]$Online)
    if (-not $Online -or $Level -lt 0) { return [System.Drawing.Color]::FromArgb(145, 155, 170) }
    $low = if ($script:Cfg -and $script:Cfg.LowPercent) { $script:Cfg.LowPercent } else { 15 }
    if ($Level -le $low) { return [System.Drawing.Color]::FromArgb(255, 40, 75) }
    if ($Level -le 40) { return [System.Drawing.Color]::FromArgb(255, 175, 20) }
    return [System.Drawing.Color]::FromArgb(0, 240, 210)
}

# --------------------------------------------------------- 图标（现画）----
function New-MouseBitmap {
    param([int]$Size, [int]$Level, [bool]$Online)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    $s = [single]$Size
    # 扩大鼠标外廓至 76% 宽度，极大提升 16x16 / 32x32 托盘下的可见性与饱满度
    $x0 = [single]([math]::Round($s * 0.12))
    $x1 = [single]([math]::Round($s * 0.88))
    $y0 = [single]([math]::Round($s * 0.05))
    $y1 = [single]([math]::Round($s * 0.95))
    $w = $x1 - $x0
    $h = $y1 - $y0
    $radius = [single]($w * 0.46)
    $path = Get-RoundPath $x0 $y0 $w $h $radius

    $low = if ($script:Cfg -and $script:Cfg.LowPercent) { $script:Cfg.LowPercent } else { 15 }
    $lvl = [math]::Max(0, [math]::Min(100, $Level))
    $fillTop = $y1 - ($h * ($lvl / 100.0))

    # 电竞赛博风：双色渐变流光与专属暗色仓底
    if (-not $Online -or $Level -lt 0) {
        $cTop = [System.Drawing.Color]::FromArgb(115, 125, 140)
        $cBot = [System.Drawing.Color]::FromArgb(65, 72, 85)
        $cCap = [System.Drawing.Color]::FromArgb(150, 160, 175)
        $bgTank = [System.Drawing.Color]::FromArgb(35, 40, 48)
    }
    elseif ($Level -le $low) {
        $cTop = [System.Drawing.Color]::FromArgb(255, 30, 70)
        $cBot = [System.Drawing.Color]::FromArgb(210, 0, 40)
        $cCap = [System.Drawing.Color]::FromArgb(255, 120, 150)
        $bgTank = [System.Drawing.Color]::FromArgb(50, 20, 26)
    }
    elseif ($Level -le 40) {
        $cTop = [System.Drawing.Color]::FromArgb(255, 205, 0)
        $cBot = [System.Drawing.Color]::FromArgb(255, 90, 0)
        $cCap = [System.Drawing.Color]::FromArgb(255, 240, 120)
        $bgTank = [System.Drawing.Color]::FromArgb(48, 38, 20)
    }
    else {
        $cTop = [System.Drawing.Color]::FromArgb(0, 255, 200)
        $cBot = [System.Drawing.Color]::FromArgb(0, 140, 255)
        $cCap = [System.Drawing.Color]::FromArgb(170, 255, 240)
        $bgTank = [System.Drawing.Color]::FromArgb(20, 36, 45)
    }

    # 绘制高对比度背景仓
    $bTank = New-Object System.Drawing.SolidBrush($bgTank)
    $g.FillPath($bTank, $path)
    $bTank.Dispose()

    # 绘制赛博流光液面与发光波峰线
    if ($lvl -gt 0) {
        $fillH = ($y1 - $fillTop) + 0.5
        $rectFill = New-Object System.Drawing.RectangleF($x0, $fillTop, $w, $fillH)
        $lgb = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.PointF($x0, $fillTop)), (New-Object System.Drawing.PointF($x0, $y1)), $cTop, $cBot
        $g.SetClip($path)
        $g.FillRectangle($lgb, $rectFill)
        if ($lvl -lt 100) {
            $penCap = New-Object System.Drawing.Pen($cCap, [single]1.0)
            $g.DrawLine($penCap, $x0, $fillTop, $x1, $fillTop)
            $penCap.Dispose()
        }
        $g.ResetClip()
        $lgb.Dispose()
    }

    # 双层边缘光圈：外层微光亮边（浅色/暗黑任务栏极佳适应） + 内层硬核防混线
    $outGlowColor = if ($Online) { [System.Drawing.Color]::FromArgb(140, 220, 240, 255) } else { [System.Drawing.Color]::FromArgb(80, 180, 190, 200) }
    $penOut = New-Object System.Drawing.Pen($outGlowColor, [single]1.0)
    $penIn = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(18, 20, 24), [single]1.4)
    $g.DrawPath($penOut, $path)
    $g.DrawPath($penIn, $path)
    $penOut.Dispose()
    $penIn.Dispose()

    # 机械滚轮与中缝刻线
    $darkColor = [System.Drawing.Color]::FromArgb(15, 18, 22)
    $wheelW = [single]([math]::Max(2.0, [math]::Round($s * 0.16)))
    $wheelH = [single]([math]::Max(3.0, [math]::Round($s * 0.22)))
    $wheelX = [single]($s * 0.5 - $wheelW / 2.0)
    $wheelY = [single]($y0 + $h * 0.12)
    $wheelPath = Get-RoundPath $wheelX $wheelY $wheelW $wheelH ($wheelW / 2.0)

    $bWheel = New-Object System.Drawing.SolidBrush($darkColor)
    $g.FillPath($bWheel, $wheelPath)
    $penWheelRim = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70, 255, 255, 255), [single]0.8)
    $g.DrawPath($penWheelRim, $wheelPath)

    $penSeam = New-Object System.Drawing.Pen($darkColor, [single]1.0)
    $g.DrawLine($penSeam, [single]($s * 0.5), [single]($wheelY + $wheelH + 0.5), [single]($s * 0.5), [single]($y0 + $h * 0.40))

    $bWheel.Dispose()
    $penWheelRim.Dispose()
    $penSeam.Dispose()
    $wheelPath.Dispose()
    $path.Dispose()
    $g.Dispose()

    return $bmp
}

function ConvertTo-TrayIcon {
    param([System.Drawing.Bitmap]$Bitmap)
    $pngMs = New-Object System.IO.MemoryStream
    $Bitmap.Save($pngMs, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $pngMs.ToArray(); $pngMs.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $w = $Bitmap.Width; $h = $Bitmap.Height
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)
    $bw.Write([byte]$(if ($w -ge 256) { 0 } else { $w }))
    $bw.Write([byte]$(if ($h -ge 256) { 0 } else { $h }))
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$png.Length); $bw.Write([uint32]22)
    $bw.Write($png); $bw.Flush()
    $ms.Position = 0
    $icon = New-Object System.Drawing.Icon($ms)
    return @{ Icon = $icon; Stream = $ms }
}

# ----------------------------------------------------------- 设备探测 ----
# 放后台 Runspace 跑：单次 1.5–4s，绝不能占 UI 线程。
$script:ProbeBlock = {
    param($cfg)
    $ProgressPreference = 'SilentlyContinue'
    $ErrorActionPreference = 'Stop'
    $out = @{ Ok = $false; Error = ''; Devices = @(); BleCount = 0; Skipped = @() }

    function Read-Node([string]$id, $key, [string]$fallback) {
        $props = @{}
        foreach ($p in (Get-PnpDeviceProperty -InstanceId $id -ErrorAction Stop)) { $props[$p.KeyName] = $p.Data }
        $k2 = "$key 2"
        if (-not $props.ContainsKey($k2)) { return $null }
        $k7 = "$key 7"
        $mac = ''
        if ($id -match 'DEV_([0-9A-Fa-f]{12})') { $mac = $Matches[1] }
        # 这个 cmdlet 对友好名返回的是别名串，不是 GUID 形式
        $name = ([string]$props['DEVPKEY_Device_FriendlyName']).Trim()
        if (-not $name) { $name = ([string]$fallback).Trim() }
        if (-not $name -and $mac) { $name = 'Bluetooth ' + $mac.Substring(8) }
        return @{
            Id      = $id
            Mac     = $mac
            Name    = $name
            Level   = [int]$props[$k2]
            Updated = $(if ($props.ContainsKey($k7)) { [datetime]$props[$k7] } else { $null })
            Online  = $false
        }
    }

    try {
        if ($cfg.Scan) {
            $nodes = @(Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue |
                       Where-Object { $_.InstanceId -like 'BTHLE\*' })
            $out.BleCount = $nodes.Count

            # 在线判定只能看真正的 HID 设备实例（InstanceId 以 HID\ 开头）。
            # 注意 HID 实例的 Class 是 Mouse / Keyboard，不在 HIDClass 里；
            # 而 BTHLEDEVICE\{00001812}（HOGP 服务节点，Class 才叫 HIDClass）断电后不会消失，
            # BTHLE\DEV_xxx（配对记录）更是常在 —— 拿它们判在线会永远"已连接"。
            $hidIndex = (@(Get-PnpDevice -Class Mouse, Keyboard, HIDClass -PresentOnly -ErrorAction SilentlyContinue |
                           Where-Object { $_.InstanceId -like 'HID\*' } |
                           ForEach-Object { $_.InstanceId }) -join '|').ToUpperInvariant()
            $list = New-Object System.Collections.ArrayList
            $skipped = New-Object System.Collections.ArrayList
            foreach ($n in $nodes) {
                $nm = ([string]$n.FriendlyName).Trim()
                $dev = $null
                try { $dev = Read-Node $n.InstanceId $cfg.DevKey $n.FriendlyName } catch { }
                if (-not $dev) {
                    # 有 BLE 节点却没有电量属性 = 设备没实现标准电池服务
                    [void]$skipped.Add($(if ($nm) { $nm } else { '（未命名 BLE 设备）' }))
                    continue
                }
                if ($cfg.NameFilter) {
                    if ($dev.Name -notmatch $cfg.NameFilter) {
                        [void]$skipped.Add($dev.Name + '（被名字过滤排除）')
                        continue
                    }
                }
                if ($dev.Mac) {
                    $dev.Online = $hidIndex.Contains($dev.Mac.ToUpperInvariant())
                }
                [void]$list.Add($dev)
            }
            $out.Devices = @($list | Sort-Object @{ Expression = 'Online'; Descending = $true }, @{ Expression = 'Level'; Descending = $true })
            $out.Skipped = @($skipped)
            $out.Ok = $true
        }
        elseif ($cfg.Id) {
            $dev = $null
            try { $dev = Read-Node $cfg.Id $cfg.DevKey $cfg.Name } catch { }
            if ($dev -and $dev.Mac) {
                $hit = @(Get-PnpDevice -Class Mouse, Keyboard, HIDClass -PresentOnly -ErrorAction SilentlyContinue |
                         Where-Object {
                             $_.InstanceId -like 'HID\*' -and
                             $_.InstanceId.IndexOf($dev.Mac, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                         })
                $dev.Online = ($hit.Count -gt 0)
            }
            $out.Devices = @($dev)
            $out.Ok = [bool]$dev
            if (-not $dev) { $out.Error = 'node-gone' }
        }
        else { $out.Error = 'no-id' }
    }
    catch { $out.Error = $_.Exception.Message }
    $out
}

# ------------------------------------------------- 2.4G 接收器（USB HID）----
# 2.4G 模式下系统没有任何电量属性，只能听厂商私有通道：
#   usage page 0xFF02 / 33 字节输入报告，格式实测为
#     00 D1 <connected 01|00> <level 0-100> 00 01 11 01 00 ...
#   00 D2 ... 是另一种状态帧，与本工具无关。
# 只读：只打开 GENERIC_READ + 共享方式，绝不写 Output/Feature 报告。
$script:UsbCSharp = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class HidBat
{
    [StructLayout(LayoutKind.Sequential)]
    public struct GUID { public uint Data1; public ushort Data2; public ushort Data3; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)] public byte[] Data4; }
    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public GUID InterfaceClassGuid; public int Flags; public IntPtr Reserved; }
    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVINFO_DATA { public int cbSize; public GUID ClassGuid; public int DevInst; public IntPtr Reserved; }
    [StructLayout(LayoutKind.Sequential)]
    public struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID; public ushort ProductID; public ushort VersionNumber; }
    [StructLayout(LayoutKind.Sequential)]
    public struct OVERLAPPED { public IntPtr Internal; public IntPtr InternalHigh; public int Offset; public int OffsetHigh; public IntPtr hEvent; }

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr SetupDiGetClassDevsW(ref GUID g, IntPtr e, IntPtr p, int f);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref GUID g, int i, ref SP_DEVICE_INTERFACE_DATA x);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr s, ref SP_DEVICE_INTERFACE_DATA x, IntPtr b, int n, out int r, IntPtr d);
    [DllImport("setupapi.dll", EntryPoint = "SetupDiGetDeviceInterfaceDetailW", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiGetDeviceInterfaceDetailX(IntPtr s, ref SP_DEVICE_INTERFACE_DATA x, IntPtr b, int n, out int r, ref SP_DEVINFO_DATA d);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiGetDeviceInstanceIdW(IntPtr s, ref SP_DEVINFO_DATA d, StringBuilder id, int n, out int req);
    [DllImport("hid.dll", CharSet = CharSet.Unicode)]
    static extern bool HidD_GetProductString(IntPtr h, StringBuilder s, int n);
    [DllImport("hid.dll")]
    static extern void HidD_GetHidGuid(out GUID g);
    [DllImport("hid.dll", SetLastError = true)]
    static extern bool HidD_GetAttributes(IntPtr h, ref HIDD_ATTRIBUTES a);
    [DllImport("hid.dll", SetLastError = true)]
    static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pp);
    [DllImport("hid.dll")]
    static extern int HidP_GetCaps(IntPtr pp, byte[] caps);
    [DllImport("hid.dll")]
    static extern bool HidD_FreePreparsedData(IntPtr pp);
    [DllImport("hid.dll", SetLastError = true)]
    static extern bool HidD_SetOutputReport(IntPtr h, byte[] reportBuffer, int reportBufferLength);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string f, uint acc, int share, IntPtr sa, uint disp, uint flags, IntPtr t);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr h, byte[] b, int n, out int read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateEventW(IntPtr a, bool m, bool i, IntPtr n);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetOverlappedResult(IntPtr h, IntPtr ov, out int got, bool w);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CancelIoEx(IntPtr h, IntPtr ov);

    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const int FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2;
    const uint OPEN_EXISTING = 3, FILE_FLAG_OVERLAPPED = 0x40000000;
    const int DIGCF_PRESENT = 2, DIGCF_DEVICEINTERFACE = 0x10;
    static readonly IntPtr INVALID = new IntPtr(-1);

    static readonly ConcurrentQueue<string> queue = new ConcurrentQueue<string>();
    static Thread worker;
    static volatile bool running;
    public static string Path = "";
    public static string Error = "";

    // 罗技 HID++ 协议状态机
    static bool isLogitechMode = false;
    static byte logiDevIdx = 0x01;
    static byte featUnifiedBattery = 0;
    static byte featBatteryLevel = 0;
    static DateTime logiLastQuery = DateTime.MinValue;

    public static bool Start(int upage, int vid, int pid)
    {
        if (worker != null)
        {
            if (running) { return true; }
            try { worker.Join(400); } catch { }
            worker = null;
        }
        string path = Find(upage, vid, pid);
        if (path == null) return false;
        Path = path;
        Error = "";
        isLogitechMode = (vid == 0x046D || upage == 0xFF00 || upage == 0xFF43);
        featUnifiedBattery = 0;
        featBatteryLevel = 0;
        logiLastQuery = DateTime.MinValue;
        running = true;
        worker = new Thread(Loop);
        worker.IsBackground = true;
        worker.Start();
        return true;
    }

    public static void Stop()
    {
        running = false;
        if (worker != null)
        {
            try { worker.Join(600); } catch { }
            worker = null;
        }
    }

    public static bool IsRunning { get { return running; } }
    public static int InputReportLength = 33;

    public static string Find(int upage, int vid, int pid)
    {
        GUID g; HidD_GetHidGuid(out g);
        IntPtr set = SetupDiGetClassDevsW(ref g, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (set == INVALID) return null;
        string found = null;
        try
        {
            int idx = 0;
            while (true)
            {
                var did = new SP_DEVICE_INTERFACE_DATA();
                did.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, idx, ref did)) break;
                idx++;
                int need;
                SetupDiGetDeviceInterfaceDetailW(set, ref did, IntPtr.Zero, 0, out need, IntPtr.Zero);
                if (need <= 0) continue;
                IntPtr buf = Marshal.AllocHGlobal(need);
                try
                {
                    Marshal.WriteInt32(buf, 0, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetailW(set, ref did, buf, need, out need, IntPtr.Zero)) continue;
                    string path = Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + 4));
                    if (string.IsNullOrEmpty(path)) continue;
                    IntPtr h = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                    if (h == INVALID) continue;
                    try
                    {
                        var attr = new HIDD_ATTRIBUTES();
                        attr.Size = Marshal.SizeOf(typeof(HIDD_ATTRIBUTES));
                        if (!HidD_GetAttributes(h, ref attr)) continue;
                        if (vid > 0 && attr.VendorID != vid) continue;
                        if (pid > 0 && attr.ProductID != pid) continue;
                        IntPtr pp;
                        if (!HidD_GetPreparsedData(h, out pp) || pp == IntPtr.Zero) continue;
                        try
                        {
                            byte[] caps = new byte[256];
                            if (HidP_GetCaps(pp, caps) != 0x00110000) continue;
                            int up = BitConverter.ToUInt16(caps, 2);
                            if (up != upage) continue;
                            int inLen = BitConverter.ToUInt16(caps, 4);
                            if (inLen <= 0) continue;
                            InputReportLength = inLen;
                            found = path;
                        }
                        finally { HidD_FreePreparsedData(pp); }
                    }
                    finally { CloseHandle(h); }
                    if (found != null) break;
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
        return found;
    }

    static void SendLogiBatteryQuery(IntPtr h)
    {
        try
        {
            if (featUnifiedBattery == 0 && featBatteryLevel == 0)
            {
                // 1. 查询 0x1004 (Unified Battery) 特征索引
                byte[] q1004 = new byte[20];
                q1004[0] = 0x11; q1004[1] = logiDevIdx; q1004[2] = 0x00; q1004[3] = 0x00;
                q1004[4] = 0x10; q1004[5] = 0x04;
                HidD_SetOutputReport(h, q1004, q1004.Length);

                // 2. 同时查询 0x1000 (Battery Level Status) 特征索引
                byte[] q1000 = new byte[20];
                q1000[0] = 0x11; q1000[1] = logiDevIdx; q1000[2] = 0x00; q1000[3] = 0x00;
                q1000[4] = 0x10; q1000[5] = 0x00;
                HidD_SetOutputReport(h, q1000, q1000.Length);

                // 3. 同时发送 HID++ 1.0 短报文（兼容旧款 G304 / M590 等）
                byte[] qShort = new byte[7] { 0x10, logiDevIdx, 0x0D, 0x00, 0x00, 0x00, 0x00 };
                HidD_SetOutputReport(h, qShort, qShort.Length);
            }
            else if (featUnifiedBattery != 0)
            {
                // 向 0x1004 发送 Function 0 (GetStatus)
                byte[] q = new byte[20];
                q[0] = 0x11; q[1] = logiDevIdx; q[2] = featUnifiedBattery; q[3] = 0x00;
                HidD_SetOutputReport(h, q, q.Length);
            }
            else if (featBatteryLevel != 0)
            {
                // 向 0x1000 发送 Function 0 (GetBatteryLevelStatus)
                byte[] q = new byte[20];
                q[0] = 0x11; q[1] = logiDevIdx; q[2] = featBatteryLevel; q[3] = 0x00;
                HidD_SetOutputReport(h, q, q.Length);
            }
        }
        catch { }
    }

    static void Loop()
    {
        IntPtr h = INVALID;
        if (isLogitechMode)
        {
            // 罗技优先以读写模式打开下发查询命令；若写权限被独占则平滑降级为只读
            h = CreateFileW(Path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                            IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);
        }
        if (h == INVALID)
        {
            h = CreateFileW(Path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero,
                            OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);
        }
        if (h == INVALID) { Error = "open-failed " + Marshal.GetLastWin32Error(); running = false; return; }

        int len = InputReportLength > 0 ? InputReportLength : (isLogitechMode ? 64 : 33);
        var buf = new byte[Math.Max(128, len)];
        try
        {
            if (isLogitechMode)
            {
                SendLogiBatteryQuery(h);
                logiLastQuery = DateTime.Now;
            }

            while (running)
            {
                if (isLogitechMode && (DateTime.Now - logiLastQuery).TotalSeconds >= 25)
                {
                    SendLogiBatteryQuery(h);
                    logiLastQuery = DateTime.Now;
                }

                int got = ReadWithTimeout(h, buf, len, 500);
                if (got > 0)
                {
                    if (isLogitechMode)
                    {
                        if (buf[0] == 0x11) // Long Report
                        {
                            if (buf[2] == 0x00 && buf[3] == 0x00)
                            {
                                byte idx = buf[4];
                                if (idx > 0)
                                {
                                    if (featUnifiedBattery == 0) { featUnifiedBattery = idx; }
                                    else if (featBatteryLevel == 0) { featBatteryLevel = idx; }
                                    SendLogiBatteryQuery(h);
                                }
                            }
                            else if ((featUnifiedBattery != 0 && buf[2] == featUnifiedBattery) ||
                                     (featBatteryLevel != 0 && buf[2] == featBatteryLevel) ||
                                     (buf[4] > 0 && buf[4] <= 100 && buf[2] > 0 && buf[2] < 0x20))
                            {
                                int lvl = (int)buf[4];
                                int chg = ((buf[6] >= 1 && buf[6] <= 3) || (buf[5] >= 1 && buf[5] <= 3)) ? 1 : 0;
                                if (lvl >= 0 && lvl <= 100)
                                {
                                    queue.Enqueue(string.Format("HIDPP|{0}|{1}|{2}", lvl, chg, DateTime.Now.ToString("HH:mm:ss")));
                                }
                            }
                        }
                        else if (buf[0] == 0x10) // Short Report
                        {
                            if (buf[2] == 0x0D || buf[2] == 0x0F)
                            {
                                int lvl = (int)buf[3];
                                if (lvl <= 0 || lvl > 100) lvl = (int)buf[4];
                                if (lvl >= 0 && lvl <= 100)
                                {
                                    queue.Enqueue(string.Format("HIDPP|{0}|0|{1}", lvl, DateTime.Now.ToString("HH:mm:ss")));
                                }
                            }
                        }
                    }

                    var sb = new StringBuilder();
                    for (int i = 0; i < got; i++) sb.Append(buf[i].ToString("X2"));
                    queue.Enqueue(sb.ToString() + "|" + DateTime.Now.ToString("HH:mm:ss"));
                }
                else if (got < 0 && running)
                {
                    Error = "read-failed " + Marshal.GetLastWin32Error();
                    running = false;
                }
            }
        }
        finally { CloseHandle(h); }
    }

    static int ReadWithTimeout(IntPtr h, byte[] buf, int len, int ms)
    {
        IntPtr ev = CreateEventW(IntPtr.Zero, true, false, IntPtr.Zero);
        if (ev == IntPtr.Zero) return -1;
        IntPtr ov = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(OVERLAPPED)));
        try
        {
            var o = new OVERLAPPED(); o.hEvent = ev;
            Marshal.StructureToPtr(o, ov, false);
            int read;
            bool ok = ReadFile(h, buf, len, out read, ov);
            if (!ok && Marshal.GetLastWin32Error() != 997) return -1;
            if (WaitForSingleObject(ev, (uint)ms) != 0)
            {
                CancelIoEx(h, ov);
                int dummy;
                GetOverlappedResult(h, ov, out dummy, true); // 等待内核取消彻底完成，防止悬挂指针破坏内存
                return 0;
            }
            int got;
            if (!GetOverlappedResult(h, ov, out got, false)) return -1;
            return got;
        }
        finally { Marshal.FreeHGlobal(ov); CloseHandle(ev); }
    }

    public static string[] Poll()
    {
        var list = new List<string>();
        string s;
        while (queue.TryDequeue(out s)) list.Add(s);
        return list.ToArray();
    }

    // ---- 诊断用：枚举本机全部 HID 接口，不限 VID / usage page ----
    // 每行格式：VID|PID|UsagePage|Usage|In|Out|Feat|Product|InstanceId
    public static string[] Enumerate()
    {
        var rows = new List<string>();
        GUID g; HidD_GetHidGuid(out g);
        IntPtr set = SetupDiGetClassDevsW(ref g, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (set == INVALID) return new string[] { "ENUM-FAILED" };
        try
        {
            int idx = 0;
            while (true)
            {
                var did = new SP_DEVICE_INTERFACE_DATA();
                did.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, idx, ref did)) break;
                idx++;
                int need;
                SetupDiGetDeviceInterfaceDetailW(set, ref did, IntPtr.Zero, 0, out need, IntPtr.Zero);
                if (need <= 0) continue;
                IntPtr buf = Marshal.AllocHGlobal(need);
                try
                {
                    Marshal.WriteInt32(buf, 0, IntPtr.Size == 8 ? 8 : 6);
                    var devInfo = new SP_DEVINFO_DATA();
                    devInfo.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
                    if (!SetupDiGetDeviceInterfaceDetailX(set, ref did, buf, need, out need, ref devInfo)) continue;
                    // DevicePath 偏移随位数变化，两种布局都试一次，认 \?\ 开头的那份
                    string path = Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + 8));
                    if (string.IsNullOrEmpty(path) || path.IndexOf(@"\\?\") < 0)
                        path = Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + 4));
                    if (string.IsNullOrEmpty(path)) continue;

                    string inst = "";
                    var sbId = new StringBuilder(512);
                    int req;
                    if (SetupDiGetDeviceInstanceIdW(set, ref devInfo, sbId, 512, out req)) inst = sbId.ToString().Trim();

                    IntPtr h = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                    if (h == INVALID) continue;
                    try
                    {
                        var attr = new HIDD_ATTRIBUTES();
                        attr.Size = Marshal.SizeOf(typeof(HIDD_ATTRIBUTES));
                        if (!HidD_GetAttributes(h, ref attr)) continue;
                        var sbName = new StringBuilder(256);
                        string prod = "";
                        if (HidD_GetProductString(h, sbName, 256)) prod = sbName.ToString().Trim();
                        int up = -1, usg = -1, inLen = 0, outLen = 0, featLen = 0;
                        IntPtr pp;
                        if (HidD_GetPreparsedData(h, out pp) && pp != IntPtr.Zero)
                        {
                            try
                            {
                                byte[] caps = new byte[256];
                                if (HidP_GetCaps(pp, caps) == 0x00110000)
                                {
                                    usg = BitConverter.ToUInt16(caps, 0);
                                    up = BitConverter.ToUInt16(caps, 2);
                                    inLen = BitConverter.ToUInt16(caps, 4);
                                    outLen = BitConverter.ToUInt16(caps, 6);
                                    featLen = BitConverter.ToUInt16(caps, 8);
                                }
                            }
                            finally { HidD_FreePreparsedData(pp); }
                        }
                        rows.Add(string.Format("{0:X4}|{1:X4}|{2:X4}|{3:X4}|{4}|{5}|{6}|{7}|{8}",
                            attr.VendorID, attr.ProductID, up, usg, inLen, outLen, featLen,
                            prod.Replace("|", "/"), inst));
                    }
                    finally { CloseHandle(h); }
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
        return rows.ToArray();
    }

    // ---- 诊断用：同时监听多条厂商通道，把每一帧带时间戳交给回调 ----
    static volatile bool capturing = false;
    static int captureGen = 0;
    static readonly List<Thread> capThreads = new List<Thread>();
    public static string CapError = "";

    public static int CaptureStart(string[] targets)
    {
        StopCapture();
        int gen = ++captureGen;      // 代际令牌：让上一轮的旧线程自己退出
        capturing = true;
        capThreads.Clear();
        int ok = 0;
        foreach (var t in targets)
        {
            var parts = t.Split(':');
            int upage = int.Parse(parts[0]), len = int.Parse(parts[1]);
            int vid = parts.Length > 2 ? int.Parse(parts[2]) : 0;
            int pid = parts.Length > 3 ? int.Parse(parts[3]) : 0;
            string path = Find(upage, vid, pid);
            if (path == null) { CapError = CapError + "find " + upage.ToString("X4") + " not-found; "; continue; }
            IntPtr h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero,
                                   OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);
            if (h == INVALID) { CapError += "open " + upage.ToString("X4") + " err=" + Marshal.GetLastWin32Error() + "; "; continue; }
            var arg = new object[] { h, len, upage, gen };
            var th = new Thread(CaptureLoop);
            th.IsBackground = true;
            th.Start(arg);
            capThreads.Add(th);
            ok++;
        }
        if (ok == 0) capturing = false;
        return ok;
    }

    public static bool IsCapturing { get { return capturing; } }

    static void CaptureLoop(object arg)
    {
        var a = (object[])arg;
        IntPtr h = (IntPtr)a[0];
        int len = (int)a[1];
        int upage = (int)a[2];
        int myGen = (int)a[3];
        var buf = new byte[4096];
        try
        {
            while (capturing && myGen == captureGen)
            {
                int got = ReadWithTimeout(h, buf, len == 0 ? 64 : len, 400);
                if (got > 0)
                {
                    var sb = new StringBuilder();
                    for (int i = 0; i < got; i++) sb.Append(buf[i].ToString("X2"));
                    queue.Enqueue(string.Format("CAP|{0:X4}|{1}|{2}", upage, sb.ToString(), DateTime.Now.ToString("HH:mm:ss.fff")));
                }
            }
        }
        catch (Exception ex) { CapError = CapError + ex.Message + "; "; }
        finally { CloseHandle(h); }
    }

    public static void StopCapture()
    {
        capturing = false;
        foreach (var th in capThreads)
        {
            try { th.Join(500); } catch { }
        }
        capThreads.Clear();
    }
}
'@

# --------------------------------------------- 2.4G 主流品牌预设库 ----
$script:UsbPresets = @(
    # 罗技 Logitech 全系 (Lightspeed / Unifying / Bolt)
    @{ Brand = 'Logitech'; Vid = '046D'; UsagePage = 'FF00'; FrameType = 'HIDPP'; LevelIdx = -1; LinkIdx = -1 }
    @{ Brand = 'Logitech'; Vid = '046D'; UsagePage = 'FF43'; FrameType = 'HIDPP'; LevelIdx = -1; LinkIdx = -1 }
    # 小米 Xiaomi (无线键鼠套装 3 / 双模无线鼠标 / 便携鼠标 / Lite 等)
    @{ Brand = 'Xiaomi';   Vid = '2717'; UsagePage = 'FFEF'; FrameType = '';      LevelIdx = -1; LinkIdx = -1 }
    @{ Brand = 'Xiaomi';   Vid = '2717'; UsagePage = 'FF01'; FrameType = '';      LevelIdx = -1; LinkIdx = -1 }
    @{ Brand = 'Xiaomi';   Vid = '2717'; UsagePage = 'FF02'; FrameType = 'D1';    LevelIdx = 3;  LinkIdx = 2 }
    @{ Brand = 'Xiaomi';   Vid = '2717'; UsagePage = 'FF00'; FrameType = '';      LevelIdx = -1; LinkIdx = -1 }
    # 狼蛛 AULA (SC580 / F87 等)
    @{ Brand = 'AULA';     Vid = '089D'; UsagePage = 'FF02'; FrameType = 'D1';    LevelIdx = 3;  LinkIdx = 2 }
    # VGN / ATK (蜻蜓 F1 系列 / ATK A9 / 烈空等)
    @{ Brand = 'VGN/ATK';  Vid = '341A'; UsagePage = 'FF02'; FrameType = 'D1';    LevelIdx = 3;  LinkIdx = 2 }
    @{ Brand = 'VGN/ATK';  Vid = '341A'; UsagePage = 'FF00'; FrameType = '';      LevelIdx = 3;  LinkIdx = -1 }
    # 达尔优 DAREU (A950 / A980 等中颖方案)
    @{ Brand = 'DAREU';    Vid = '258A'; UsagePage = 'FF02'; FrameType = 'D1';    LevelIdx = 3;  LinkIdx = 2 }
    @{ Brand = 'DAREU';    Vid = '258A'; UsagePage = 'FF00'; FrameType = '';      LevelIdx = 3;  LinkIdx = -1 }
    # 雷柏 Rapoo (VT9 / VT9S / VT9Pro 系列)
    @{ Brand = 'Rapoo';    Vid = '24AE'; UsagePage = 'FF00'; FrameType = '';      LevelIdx = 3;  LinkIdx = -1 }
    @{ Brand = 'Rapoo';    Vid = '24AE'; UsagePage = 'FF02'; FrameType = 'D1';    LevelIdx = 3;  LinkIdx = 2 }
    # 迈从 MCHOSE (A5 / AX5 / G3 等)
    @{ Brand = 'MCHOSE';   Vid = '3554'; UsagePage = 'FF02'; FrameType = 'D1';    LevelIdx = 3;  LinkIdx = 2 }
    # 英菲克 Inphic (IN9 / PG6 / PM6 等原相方案)
    @{ Brand = 'Inphic';   Vid = '093A'; UsagePage = 'FF00'; FrameType = '';      LevelIdx = 3;  LinkIdx = -1 }
    @{ Brand = 'Inphic';   Vid = '093A'; UsagePage = 'FF02'; FrameType = 'D1';    LevelIdx = 3;  LinkIdx = 2 }
    # 漫步者 HECATE (G3M Pro / G4M Pro 等)
    @{ Brand = 'HECATE';   Vid = '2E8A'; UsagePage = 'FF02'; FrameType = 'D1';    LevelIdx = 3;  LinkIdx = 2 }
    @{ Brand = 'HECATE';   Vid = '2E8A'; UsagePage = 'FF00'; FrameType = '';      LevelIdx = 3;  LinkIdx = -1 }
    # 多彩 DeLUX (M800 Pro / M618 人体工学系列)
    @{ Brand = 'DeLUX';    Vid = '248A'; UsagePage = 'FF00'; FrameType = '';      LevelIdx = 3;  LinkIdx = -1 }
    @{ Brand = 'DeLUX';    Vid = '248A'; UsagePage = 'FF02'; FrameType = 'D1';    LevelIdx = 3;  LinkIdx = 2 }
    # 黑爵 AJAZZ (AJ199 / AJ139 / AJ159 等)
    @{ Brand = 'AJAZZ';    Vid = '0C45'; UsagePage = 'FF02'; FrameType = 'D1';    LevelIdx = 3;  LinkIdx = 2 }
    @{ Brand = 'AJAZZ';    Vid = '0C45'; UsagePage = 'FF00'; FrameType = '';      LevelIdx = 3;  LinkIdx = -1 }
    # 红魔 RedMagic (电竞无线系列)
    @{ Brand = 'RedMagic'; Vid = '3537'; UsagePage = 'FF02'; FrameType = 'D1';    LevelIdx = 3;  LinkIdx = 2 }
    # 双飞燕 A4Tech / 血手幽灵
    @{ Brand = 'A4Tech';   Vid = '09DA'; UsagePage = 'FF00'; FrameType = '';      LevelIdx = 3;  LinkIdx = -1 }
)
$script:ActivePreset = $null

function Find-UsbPreset {
    try {
        if (-not ('HidBat' -as [type])) {
            Add-Type -TypeDefinition $script:UsbCSharp -Language CSharp -ErrorAction Stop
        }
        $enumRows = [HidBat]::Enumerate()
        if (-not $enumRows -or $enumRows[0] -eq 'ENUM-FAILED') { return $null }

        # 第一轮：优先匹配预设品牌库（要求具备 InLen > 0 可读端点）
        foreach ($row in $enumRows) {
            $parts = $row -split '\|'
            if ($parts.Count -lt 9) { continue }
            $vid = $parts[0]; $pid = $parts[1]; $upage = $parts[2]
            $inLen = 0
            try { $inLen = [int]$parts[4] } catch { }
            if ($inLen -le 0) { continue }

            $upageInt = 0
            try { $upageInt = [Convert]::ToInt32($upage, 16) } catch { }
            if ($upageInt -lt 0xFF00) { continue }

            foreach ($p in $script:UsbPresets) {
                if ($p.Vid.ToUpperInvariant() -eq $vid.ToUpperInvariant()) {
                    if (-not $p.UsagePage -or $p.UsagePage.ToUpperInvariant() -eq $upage.ToUpperInvariant()) {
                        return @{
                            Brand       = $p.Brand
                            Vid         = $vid
                            Pid         = $pid
                            UsagePage   = $upage
                            FrameType   = $p.FrameType
                            LevelIdx    = $p.LevelIdx
                            LinkIdx     = $p.LinkIdx
                            ProductName = $parts[7]
                            InLen       = $inLen
                        }
                    }
                }
            }
        }

        # 第二轮：通用 2.4G 接收器自动识别（产品名含 Mouse/Combo/Wireless 且具备厂商私有通道）
        foreach ($row in $enumRows) {
            $parts = $row -split '\|'
            if ($parts.Count -lt 9) { continue }
            $vid = $parts[0]; $pid = $parts[1]; $upage = $parts[2]
            $inLen = 0
            try { $inLen = [int]$parts[4] } catch { }
            if ($inLen -le 0) { continue }
            $upageInt = 0
            try { $upageInt = [Convert]::ToInt32($upage, 16) } catch { }
            if ($upageInt -lt 0xFF00) { continue }
            $prod = $parts[7]
            if ($prod -match 'Mouse|Combo|Wireless|Keyboard') {
                return @{
                    Brand       = 'Generic USB'
                    Vid         = $vid
                    Pid         = $pid
                    UsagePage   = $upage
                    FrameType   = ''
                    LevelIdx    = -1
                    LinkIdx     = -1
                    ProductName = $prod
                    InLen       = $inLen
                }
            }
        }
    }
    catch { }
    return $null
}

function Start-UsbListener {
    if ($script:UsbWorker) { return }

    $vid = 0; $pid_ = 0; $upage = 0
    if ($script:Cfg.UsbUsagePage) {
        if ($script:Cfg.UsbVid) { $vid = [Convert]::ToInt32(('0x' + $script:Cfg.UsbVid), 16) }
        if ($script:Cfg.UsbPid) { $pid_ = [Convert]::ToInt32(('0x' + $script:Cfg.UsbPid), 16) }
        $upage = [Convert]::ToInt32(('0x' + $script:Cfg.UsbUsagePage), 16)
    }
    else {
        # 自动从主流预设库中识别已连接的接收器
        $preset = Find-UsbPreset
        if ($preset) {
            $vid = [Convert]::ToInt32(('0x' + $preset.Vid), 16)
            $pid_ = [Convert]::ToInt32(('0x' + $preset.Pid), 16)
            $upage = [Convert]::ToInt32(('0x' + $preset.UsagePage), 16)
            $script:ActivePreset = $preset
            Write-Log ('USB-PRESET-MATCH brand={0} vid:pid={1}:{2} upage=0x{3}' -f $preset.Brand, $preset.Vid, $preset.Pid, $preset.UsagePage)
        }
        else {
            return
        }
    }

    try {
        if (-not ('HidBat' -as [type])) {
            Add-Type -TypeDefinition $script:UsbCSharp -Language CSharp -ErrorAction Stop
        }
        if ([HidBat]::Start($upage, $vid, $pid_)) {
            $script:UsbWorker = $true
            Write-Log ('USB-START ' + [HidBat]::Path)
        }
        else { if ($script:Cfg.Debug) { Write-Log 'USB-NOTFOUND' } }
    }
    catch { Write-Log ('USB-INIT-ERR ' + $_.Exception.Message) }
}

function Update-UsbState {
    if (-not $script:UsbWorker) { return }
    # 接收器被拔掉 / 读失败 → 线程自己会退出，这里同步状态，之后由定时器重试
    try {
        if (-not [HidBat]::IsRunning) {
            $script:UsbWorker = $false
            $script:Usb.HasData = $false
            $script:Usb.Online = $false
            Write-Log ('USB-STOPPED ' + [HidBat]::Error)
            Update-Tray
            # 立刻试着重连一次：接收器刚插回来就能用，不用干等 30 秒
            Start-UsbListener
            return
        }
    }
    catch { }
    $frames = [HidBat]::Poll()
    $changed = $false
    # 帧格式做成可配置的：换一个品牌的接收器时，多数情况只要改
    # UsbFrameType / UsbLevelIndex / UsbLinkIndex 就能用，不必改代码。
    $typeWant = -1
    $frameTypeStr = if ($script:Cfg.UsbFrameType) { $script:Cfg.UsbFrameType }
                    elseif ($script:ActivePreset -and $script:ActivePreset.FrameType) { $script:ActivePreset.FrameType }
                    else { '' }
    if ($frameTypeStr -and $frameTypeStr -ne 'HIDPP') {
        try { $typeWant = [Convert]::ToInt32($frameTypeStr, 16) } catch { $typeWant = -1 }
    }
    $lvIdx = if ($null -ne $script:Cfg.UsbLevelIndex) { [int]$script:Cfg.UsbLevelIndex }
             elseif ($script:ActivePreset -and $null -ne $script:ActivePreset.LevelIdx) { [int]$script:ActivePreset.LevelIdx }
             else { 3 }
    $lkIdx = if ($null -ne $script:Cfg.UsbLinkIndex) { [int]$script:Cfg.UsbLinkIndex }
             elseif ($script:ActivePreset -and $null -ne $script:ActivePreset.LinkIdx) { [int]$script:ActivePreset.LinkIdx }
             else { 2 }

    foreach ($f in $frames) {
        # 罗技 HID++ 专用高层帧处理
        if ($f -like 'HIDPP|*') {
            $p = $f -split '\|'
            if ($p.Count -ge 3) {
                $lv = [int]$p[1]
                $chg = ($p[2] -eq '1')
                if ($lv -ge 0 -and $lv -le 100) {
                    if (-not $script:Usb.HasData -or $script:Usb.Level -ne $lv) { $changed = $true }
                    $script:Usb.HasData = $true
                    $script:Usb.Level = $lv
                    $script:Usb.At = Get-Date
                    if (-not $script:Usb.Online) { $changed = $true }
                    $script:Usb.Online = $true
                    $script:Usb.Idle = $false
                    if ($script:Cfg.Debug) {
                        Write-Log ('LOGI-HIDPP level={0} charging={1}' -f $lv, $chg)
                    }
                    if ($script:Cfg.LastUsbLevel -ne $lv) { $script:Cfg.LastUsbLevel = $lv; Save-Config }
                }
            }
            continue
        }

        $hex, $ts = $f -split '\|'
        if ($hex.Length -lt 4) { continue }
        $b = @()
        for ($i = 0; $i -lt $hex.Length; $i += 2) { $b += [Convert]::ToByte($hex.Substring($i, 2), 16) }
        if ($b.Count -lt 2) { continue }

        # 始终记录收到的原始帧，方便诊断捕获与协议排查
        Write-Log ('USB-FRAME len={0} raw={1}' -f $b.Count, $hex)

        $lv = -1
        $link = 1

        if ($typeWant -ge 0 -and $b.Count -gt 1 -and $b[1] -eq $typeWant -and $lvIdx -ge 0 -and $lvIdx -lt $b.Count) {
            # 命中标准厂商帧类型（如 00 D1 ...）
            $cand = [int]$b[$lvIdx]
            if ($cand -ge 0 -and $cand -le 100) { $lv = $cand }
            if ($lkIdx -ge 0 -and $lkIdx -lt $b.Count) { $link = [int]$b[$lkIdx] }
        }
        elseif ($lvIdx -ge 0 -and $lvIdx -lt $b.Count) {
            # 命中指定索引
            $cand = [int]$b[$lvIdx]
            if ($cand -ge 0 -and $cand -le 100) { $lv = $cand }
            if ($lkIdx -ge 0 -and $lkIdx -lt $b.Count) { $link = [int]$b[$lkIdx] }
        }
        else {
            # 自适应嗅探：在非首字节中寻找合法电量候选（1..100）
            for ($idx = 1; $idx -lt [math]::Min(8, $b.Count); $idx++) {
                $val = [int]$b[$idx]
                if ($val -ge 1 -and $val -le 100) {
                    if ($lv -lt 0 -or ($val -gt 5 -and $lv -le 5)) {
                        $lv = $val
                    }
                }
            }
            if ($lv -ge 0) {
                Write-Log ('USB-SNIFF-LEVEL level={0}%' -f $lv)
            }
        }

        # 只要接收器有有效帧上报，即表明设备活跃连接
        if (-not $script:Usb.Online) { $changed = $true }
        $script:Usb.Online = $true
        $script:Usb.Idle = ($link -eq 0)
        $script:Usb.At = Get-Date

        if ($lv -ge 0) {
            if (-not $script:Usb.HasData -or $script:Usb.Level -ne $lv) { $changed = $true }
            $script:Usb.HasData = $true
            $script:Usb.Level = $lv
            if ($script:Cfg.LastUsbLevel -ne $lv) { $script:Cfg.LastUsbLevel = $lv; Save-Config }
        }
    }

    # 2.4G 离线判定：放宽至 1800 秒（30分钟）。
    # 很多 2.4G 鼠标（如狼蛛 SC580）仅在电量跳变或开机唤醒时推帧，正常使用中电量长时间未降属于正常物理现象，
    # 只要 USB 接收器未被拔除且仍在监听，维持在线与最后电量，避免误判断开。
    if ($script:Usb.HasData -and $script:Usb.Online) {
        if (((Get-Date) - $script:Usb.At).TotalSeconds -gt 1800) {
            $script:Usb.Online = $false
            $changed = $true
            Write-Log 'USB-OFFLINE (no frame in 1800s)'
        }
    }

    if ($changed) { Update-Tray }
}


# ------------------------------------------------------------- 状态 ----
$script:Cfg = Get-Config
$script:State = @{
    Mode = 'none'; Level = -1; LastLevel = -1; Online = $false; Connected = $false
    Updated = $null; Name = ''; Mac = ''; Id = ''; Error = ''
    LastSeen = $null; LastGoodUpdate = $null
    Devices = @()
    # 扫描时"看到了但读不到电量"的设备，用于在选择框里解释为什么没列出来
    Skipped = @(); BleCount = 0
}
# 2.4G 接收器状态（独立于 BLE）
$script:UsbWorker = $false
$script:UsbTryAt = [datetime]::MinValue
$script:Usb = @{ HasData = $false; Level = -1; Online = $false; At = $null; Idle = $false }
$script:Worker = $null
$script:WorkerHandle = $null
$script:WorkerStart = [datetime]::MinValue
$script:WorkerScan = $false
$script:NeedScan = $false
$script:ForceRescan = $false
$script:PendingRefresh = $false        # 刷新时正好有探测在跑 → 排队，别丢掉这次点击
$script:VerifyAt = $null               # 手动刷新或断连防抖的二次确认时刻（PnP 移除有延迟）
$script:PendingOffline = $false        # 离线确认中标志，防止瞬时抖动跳灰
$script:PickerPending = $false
$script:FailCount = 0
$script:MissStreak = 0                # 连续读不到设备的次数（成功即清零）
$script:LastPainted = ''
$script:IconStream = $null
$script:PopupUntil = [datetime]::MinValue
$script:LowWarned = $false

function Start-Probe {
    param([switch]$Scan)
    if ($script:Worker) { return }
    $isScan = $Scan -or $script:NeedScan -or $script:ForceRescan -or (-not $script:Cfg.DeviceId)

    $cfg = @{
        DevKey      = $script:DevKey
        Scan        = [bool]$isScan
        Id          = $(if ($isScan) { '' } else { $script:Cfg.DeviceId })
        Name        = $script:Cfg.DeviceName
        NameFilter  = $script:Cfg.NameFilter
    }
    $script:NeedScan = $false
    $script:ForceRescan = $false

    $ps = [powershell]::Create()
    $null = $ps.AddScript($script:ProbeBlock.ToString()).AddArgument($cfg)
    try {
        $script:WorkerHandle = $ps.BeginInvoke()
        $script:Worker = $ps
        $script:WorkerStart = Get-Date
        $script:WorkerScan = $isScan
    }
    catch {
        Write-Log ('PROBE-START-FAIL ' + $_.Exception.Message)
        $ps.Dispose()
        $script:Worker = $null
    }
}

function Complete-Probe {
    if (-not $script:Worker) { return }
    if ($script:Worker.InvocationStateInfo.State -eq 'Running') { return }

    $res = $null
    try {
        $out = $script:Worker.EndInvoke($script:WorkerHandle)
        if ($out -and $out.Count -gt 0) { $res = $out[0] }
        $err = $script:Worker.Streams.Error
        if ($err -and $err.Count -gt 0) { Write-Log ('PROBE-STDERR ' + [string]$err[0]) }
    }
    catch { $res = @{ Ok = $false; Error = $_.Exception.Message; Devices = @() } }
    finally {
        $script:Worker.Dispose()
        $script:Worker = $null
        $script:WorkerHandle = $null
    }
    if ($res) { Apply-ProbeResult $res }
}

function Apply-ProbeResult {
    param($res)

    if ($script:WorkerScan) {
        $devs = @($res.Devices | Where-Object { $_ })
        $script:State.Devices = $devs
        $script:State.Skipped = @($res.Skipped)
        $script:State.BleCount = [int]$res.BleCount
        Write-Log ('SCAN ok={0} ble={1} usable={2} skipped={3} -> {4}' -f $res.Ok, $res.BleCount, $devs.Count, @($res.Skipped).Count,
            (($devs | ForEach-Object { "$($_.Name)=$($_.Level)%/online=$($_.Online)" }) -join ', '))

        if ($script:PickerPending) {
            $script:PickerPending = $false
            Show-Picker
            return
        }

        if (-not $script:Cfg.DeviceId) {
            $pick = $null
            if ($devs.Count -eq 1) { $pick = $devs[0] }
            elseif ($devs.Count -gt 1) {
                $online = @($devs | Where-Object { $_.Online })
                if ($online.Count -eq 1) { $pick = $online[0] }
            }
            if ($pick) {
                $script:Cfg.DeviceId = $pick.Id
                $script:Cfg.DeviceName = $pick.Name
                Save-Config
                Write-Log ('AUTO-PICK ' + $pick.Id)
            }
            elseif ($devs.Count -gt 1) {
                Write-Log 'MULTI-DEVICE -> picker'
                Show-Picker
                return
            }
        }
    }

    $dev = $null
    if ($res.Devices -and @($res.Devices).Count -gt 0) {
        # 扫描结果是排序过的，优先取配置里那台，别因为排序换成了别的设备
        if ($script:Cfg.DeviceId) {
            $dev = @($res.Devices) | Where-Object { $_.Id -eq $script:Cfg.DeviceId } | Select-Object -First 1
            if (-not $dev) {
                # 配置里那台不在了：多半是重新配对导致 InstanceId 变了。
                # 换到唯一可用的一台，并把配置一起更新，否则永远读不到。
                $alt = @($res.Devices | Where-Object { $_ })[0]
                if ($alt) {
                    Write-Log ('DEVICE-SWITCH {0} -> {1} ({2})' -f $script:Cfg.DeviceId, $alt.Id, $alt.Name)
                    $script:Cfg.DeviceId = $alt.Id
                    $script:Cfg.DeviceName = $alt.Name
                    Save-Config
                    $dev = $alt
                }
            }
        }
        if (-not $dev) { $dev = @($res.Devices | Where-Object { $_ })[0] }
    }

    if ($dev) {
        $script:FailCount = 0
        $script:MissStreak = 0
        if ($script:Cfg.Debug) {
            Write-Log ('POLL {0} {1}% online={2}' -f $dev.Name, $dev.Level, $dev.Online)
        }
        # 从在线翻成离线时补验一次，避免一次瞬时抖动就把图标判灰
        if ($script:State.Online -and -not $dev.Online) {
            if (-not $script:PendingOffline) {
                $script:PendingOffline = $true
                $script:VerifyAt = (Get-Date).AddSeconds(3)
                Write-Log 'STATE online -> offline (defer verify in 3s)'
                $dev.Online = $true  # 保持当前在线状态，等待二次确认
            }
            else {
                $script:PendingOffline = $false
                $script:VerifyAt = $null
            }
        }
        else {
            $script:PendingOffline = $false
        }
        $script:State.Id = $dev.Id
        $script:State.Name = $dev.Name
        $script:State.Mac = $dev.Mac
        $script:State.Mode = 'ble'
        $script:State.Level = [int]$dev.Level
        $script:State.LastLevel = [int]$dev.Level
        $script:State.Connected = [bool]$dev.Online
        $script:State.Online = [bool]$dev.Online
        if ($dev.Updated) { $script:State.Updated = $dev.Updated; $script:State.LastGoodUpdate = $dev.Updated }
        if ($dev.Online) { $script:State.LastSeen = Get-Date }
        if ($dev.Online -and $script:Cfg.DeviceName -ne $dev.Name) {
            $script:Cfg.DeviceName = $dev.Name
            Save-Config
        }
    }
    else {
        $script:FailCount++
        $script:MissStreak++
        Write-Log ("PROBE-MISS {0} (连续 {1})" -f $res.Error, $script:MissStreak)
        $script:State.Connected = $false
        $script:State.Online = $false
        # 连续读不到超过 15 次（约 2.5 分钟）就重扫一次。
        # 设备重新配对后 InstanceId 会变，只查旧 Id 是永远查不到的。
        # 这里不清配置里的设备 —— 鼠标切到 2.4G 时也会读不到，不能因此把选择弄丢。
        if ($script:MissStreak -ge 15) {
            $script:MissStreak = 0
            $script:ForceRescan = $true
            Write-Log 'RESCAN after repeated misses'
        }
    }

    Update-Tray
}

# 统一决定「现在该显示谁」——托盘和浮层都走这里，避免两处逻辑跑偏
# 优先级：蓝牙在线 > 2.4G 有数据 > 2.4G 接收器在但还没上报 > 蓝牙（离线态）
function Get-DisplayState {
    $s = $script:State
    $bleOnline = [bool]$s.Online
    $usbOnline = $script:UsbWorker -and [bool]$script:Usb.Online
    $usbReady = $script:UsbWorker -and $script:Usb.HasData
    $nmBle = if ($s.Name) { $s.Name } else { $script:AppName }
    $presetName = if ($script:ActivePreset) { $script:ActivePreset.Brand + ' 鼠标' } else { '' }
    $nmUsb = if ($script:Cfg.DeviceName) { $script:Cfg.DeviceName } elseif ($presetName) { $presetName } elseif ($s.Name) { $s.Name } else { $script:AppName }

    # 1. 优先展示在线设备
    if ($bleOnline) {
        return @{ Mode = 'ble'; Online = $true; Level = $s.Level; LastLevel = $s.LastLevel
                  Name = $nmBle; Idle = $false; At = $s.LastGoodUpdate }
    }
    if ($usbOnline) {
        return @{ Mode = 'usb'; Online = $true; Level = $script:Usb.Level
                  LastLevel = $script:Usb.Level; Name = $nmUsb; Idle = [bool]$script:Usb.Idle; At = $script:Usb.At }
    }

    # 2. 用户在配置中明确指定了 2.4G 接收器通道：主用 2.4G，离线时不被蓝牙历史电量覆盖
    if ($script:Cfg.UsbUsagePage -and $script:UsbWorker) {
        $lv = if ($script:Usb.HasData) { $script:Usb.Level }
              elseif ($script:Cfg.LastUsbLevel -ge 0) { [int]$script:Cfg.LastUsbLevel }
              else { -1 }
        return @{ Mode = 'usb'; Online = $false; Level = $lv; LastLevel = $lv
                  Name = $nmUsb; Idle = $false; At = $script:Usb.At }
    }

    # 3. 自动模式（都离线时）：比较哪个设备是最近活跃的
    $hasBleLast = ($s.LastLevel -ge 0)
    $hasUsbLast = ($usbReady -and $script:Usb.Level -ge 0)

    if ($hasUsbLast -and (-not $hasBleLast -or ($script:Usb.At -and $s.LastSeen -and $script:Usb.At -ge $s.LastSeen))) {
        return @{ Mode = 'usb'; Online = $false; Level = $script:Usb.Level
                  LastLevel = $script:Usb.Level; Name = $nmUsb; Idle = [bool]$script:Usb.Idle; At = $script:Usb.At }
    }
    if ($hasBleLast) {
        return @{ Mode = 'ble'; Online = $false; Level = $s.LastLevel; LastLevel = $s.LastLevel
                  Name = $nmBle; Idle = $false; At = $s.LastGoodUpdate }
    }
    if ($script:UsbWorker -and $script:Cfg.LastUsbLevel -ge 0) {
        return @{ Mode = 'usb'; Online = $false; Level = [int]$script:Cfg.LastUsbLevel; LastLevel = [int]$script:Cfg.LastUsbLevel
                  Name = $nmUsb; Idle = $false; At = $null }
    }
    return @{ Mode = $s.Mode; Online = $false; Level = $s.LastLevel; LastLevel = $s.LastLevel
              Name = $nmBle; Idle = $false; At = $s.LastGoodUpdate }
}

function Update-Tray {
    $s = $script:State
    $d = Get-DisplayState
    $mode = $d.Mode
    $online = $d.Online
    $level = $d.Level
    $lastLevel = $d.LastLevel
    $nm = $d.Name

    $sig = '{0}|{1}|{2}' -f $mode, $level, $online
    if ($sig -ne $script:LastPainted) {
        $script:LastPainted = $sig
        try {
            $size = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
            if ($size -lt 16) { $size = 16 }
            $bmp = New-MouseBitmap -Size $size -Level $level -Online $online
            $pack = ConvertTo-TrayIcon -Bitmap $bmp
            $bmp.Dispose()
            $old = $script:NotifyIcon.Icon
            $script:NotifyIcon.Icon = $pack.Icon
            if ($old) { $old.Dispose() }
            if ($script:IconStream) { $script:IconStream.Dispose() }
            $script:IconStream = $pack.Stream
        }
        catch { Write-Log ('ICON-ERR ' + $_.Exception.Message) }
    }

    $tag = if ($mode -eq 'usb') { '（2.4G）' } else { '' }
    if ($online) { $tip = '{0} · 电量 {1}%{2}' -f $nm, $level, $tag }
    elseif ($lastLevel -ge 0) { $tip = '{0} · 已断开（最后 {1}%）' -f $nm, $lastLevel }
    else { $tip = '{0} · 未检测到设备' -f $script:AppName }
    if ($tip.Length -gt 60) { $tip = $tip.Substring(0, 60) }
    try { $script:NotifyIcon.Text = $tip } catch { }

    try {
        if ($online) { $script:MenuHeader.Text = '  {0} · {1}%{2}' -f $nm, $level, $tag }
        elseif ($lastLevel -ge 0) { $script:MenuHeader.Text = '  {0} · 已断开（最后 {1}%）' -f $nm, $lastLevel }
        elseif ($mode -eq 'none') { $script:MenuHeader.Text = '  未检测到可用设备' }
        else { $script:MenuHeader.Text = '  {0} · 已断开' -f $nm }
    }
    catch { }

    if ($online -and $level -ge 0 -and $script:Cfg.LowNotify) {
        if ($level -le $script:Cfg.LowPercent -and -not $script:LowWarned) {
            $script:LowWarned = $true
            try {
                $script:NotifyIcon.ShowBalloonTip(6000, ($nm + ' 电量低'),
                    ('剩余 {0}%，该充电了。' -f $level), [System.Windows.Forms.ToolTipIcon]::Warning)
            }
            catch { }
        }
        elseif ($level -gt ($script:Cfg.LowPercent + 5)) { $script:LowWarned = $false }
    }

    if ($script:Popup -and $script:Popup.Visible) { $script:Popup.Invalidate() }
}

# ------------------------------------------------------------ 选择设备 ----
function Start-DiagnoseProcess {
    # 起独立进程跑诊断：抓包要几十秒，不能占着托盘的消息循环
    $ps1 = Join-Path $script:Root 'MousePowerTray.ps1'
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ps1 + '"'),
            '-Diagnose', '-Capture', '-CaptureSeconds', '30')
        Write-Log 'DIAGNOSE launched'
        return $true
    }
    catch {
        Write-Log ('DIAGNOSE-LAUNCH-ERR ' + $_.Exception.Message)
        return $false
    }
}

function Show-Picker {
    $devs = @($script:State.Devices)
    $usbPreset = Find-UsbPreset
    if ($usbPreset) {
        $usbItemName = if ($usbPreset.ProductName) { $usbPreset.ProductName } else { $usbPreset.Brand + ' 2.4G 接收器' }
        $usbDev = @{
            IsUsb = $true
            Name = ('[2.4G] ' + $usbItemName)
            Level = if ($script:Usb.Level -ge 0) { $script:Usb.Level } else { -1 }
            Online = [bool]$script:Usb.Online
            Preset = $usbPreset
            Id = ('USB:' + $usbPreset.Vid + ':' + $usbPreset.Pid)
        }
        $devs = @($usbDev) + @($devs)
    }
    $skipList = @($script:State.Skipped)
    $empty = ($devs.Count -eq 0)

    $f = New-Object System.Windows.Forms.Form
    $f.Text = '选择要显示电量的设备'
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $f.ClientSize = New-Object System.Drawing.Size(440, 274)
    $f.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $lb = New-Object System.Windows.Forms.ListBox
    $lb.SetBounds(14, 14, 412, 142)
    $lb.IntegralHeight = $false
    foreach ($d in $devs) {
        $state = if ($d.Online) { '已连接' } else { '未连接' }
        $item = '{0}   —   {1}%   ({2})' -f $d.Name, $d.Level, $state
        [void]$lb.Items.Add($item)
    }
    if ($lb.Items.Count -gt 0) { $lb.SelectedIndex = 0 }

    $tip = New-Object System.Windows.Forms.Label
    if ($empty) {
        # 空列表最需要解释：是"没有 BLE 设备"还是"有设备但读不到电量"，
        # 这两种情况的处理方式完全不同。
        if ($script:State.BleCount -eq 0) {
            $tip.Text = '没有检测到任何蓝牙 LE 设备。' + "`r`n" +
                        '鼠标可能走 2.4G 接收器，或是经典蓝牙 —— 这两类都不会出现在这里。'
        }
        elseif ($skipList.Count -gt 0) {
            $tip.Text = ('找到 {0} 台蓝牙 LE 设备，但都读不到电量：' -f $script:State.BleCount) + "`r`n" +
                        '  ' + ($skipList -join '、') + "`r`n" +
                        '它们没有暴露标准电池服务（0x180F），系统里就没有电量可读。'
        }
        else {
            $tip.Text = '没有找到能读电量的蓝牙设备。' + "`r`n" + '请确认设备已通过蓝牙连接，然后点“重新扫描”。'
        }
        $tip.ForeColor = [System.Drawing.Color]::FromArgb(160, 60, 50)
    }
    else {
        $tip.Text = '选择后会自动记住，下次直接显示。'
        if ($skipList.Count -gt 0) {
            $tip.Text += ('  另有 {0} 台读不到电量（没暴露电池服务）。' -f $skipList.Count)
        }
        $tip.ForeColor = [System.Drawing.Color]::Gray
    }
    $tip.SetBounds(14, 160, 412, 62)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = $(if ($empty) { '收集诊断信息' } else { '确定' })
    $btnOk.SetBounds(242, 234, 100, 26)

    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Text = '重新扫描'
    $btnScan.SetBounds(134, 234, 100, 26)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '关闭'
    $btnCancel.SetBounds(350, 234, 76, 26)

    $btnOk.Add_Click({
        if ($empty) {
            # 列表空着时这个按钮就是"收集诊断信息"，一键把问题变成可分析的报告
            $f.Close()
            if (-not (Start-DiagnoseProcess)) {
                [void][System.Windows.Forms.MessageBox]::Show(
                    ('诊断进程启动失败。可以手动运行：' + "`r`n" + (Join-Path $script:Root 'MousePowerTray.ps1') + ' -Diagnose'),
                    '收集诊断信息', 'OK', 'Warning')
            }
            return
        }
        $i = $lb.SelectedIndex
        if ($i -ge 0 -and $i -lt $devs.Count) {
            $d = $devs[$i]
            if ($d.IsUsb) {
                $script:Cfg.DeviceId = ''
                $script:Cfg.DeviceName = $d.Preset.ProductName
                $script:Cfg.UsbVid = $d.Preset.Vid
                $script:Cfg.UsbPid = $d.Preset.Pid
                $script:Cfg.UsbUsagePage = $d.Preset.UsagePage
                $script:Cfg.UsbFrameType = $d.Preset.FrameType
                $script:Cfg.UsbLevelIndex = $d.Preset.LevelIdx
                $script:Cfg.UsbLinkIndex = $d.Preset.LinkIdx
                Save-Config
                Write-Log ('PICK-USB ' + $d.Preset.Brand + ' ' + $d.Preset.Vid + ':' + $d.Preset.Pid + ' upage=0x' + $d.Preset.UsagePage)
                Start-UsbListener
                Update-Tray
            }
            else {
                $script:Cfg.DeviceId = $d.Id
                $script:Cfg.DeviceName = $d.Name
                $script:Cfg.UsbUsagePage = ''
                Save-Config
                Write-Log ('PICK ' + $d.Id)
                $script:State.Mode = 'ble'
                $script:State.Name = $d.Name
                $script:State.Id = $d.Id
                $script:State.Mac = $d.Mac
                $script:State.Level = [int]$d.Level
                $script:State.LastLevel = [int]$d.Level
                $script:State.Online = [bool]$d.Online
                $script:State.Connected = [bool]$d.Online
                $script:State.LastGoodUpdate = $d.Updated
                $script:LastPainted = ''
                Update-Tray
            }
        }
        $f.Close()
    })
    $btnScan.Add_Click({
        $script:PickerPending = $true
        $script:NeedScan = $true
        $f.Close()
        # 立刻扫一次，别让用户干等到下一个轮询周期
        if ($script:Worker) { $script:PendingRefresh = $true } else { Start-Probe -Scan }
    })
    $btnCancel.Add_Click({ $f.Close() })

    [void]$f.Controls.Add($lb)
    [void]$f.Controls.Add($tip)
    [void]$f.Controls.Add($btnOk)
    [void]$f.Controls.Add($btnScan)
    [void]$f.Controls.Add($btnCancel)
    [void]$f.ShowDialog()
    $f.Dispose()

    if (-not $script:Cfg.DeviceId -and $devs.Count -eq 0) {
        # 用户关掉了选择框且还没有设备：保持灰显，靠"立即刷新"再扫
    }
}

# ------------------------------------------------------------- 详情浮层 ----
$script:Popup = $null

function New-Popup {
    $script:Popup = New-Object System.Windows.Forms.Form
    $script:Popup.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $script:Popup.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $script:Popup.ShowInTaskbar = $false
    $script:Popup.TopMost = $true
    $script:Popup.ClientSize = New-Object System.Drawing.Size(304, 142)
    $script:Popup.BackColor = [System.Drawing.Color]::FromArgb(28, 30, 34)
    $script:Popup.Region = New-Object System.Drawing.Region((Get-RoundPath 0 0 304 142 12))

    $script:Popup.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $s = $script:State
        $d = Get-DisplayState
        $online = $d.Online
        $level = $d.Level
        $modeTag = $d.Mode
        $updAt = $d.At
        if ($level -lt 0) { $level = 0 }
        $accent = Get-StatusColor -Level $level -Online $online
        $brAccent = New-Object System.Drawing.SolidBrush($accent)

        $name = $d.Name
        if ($name.Length -gt 18) { $name = $name.Substring(0, 17) + '…' }
        $g.DrawString($name, $script:FntTitle, $script:BrText, [single]18, [single]14)

        if ($modeTag -eq 'ble') {
            $modeText = if ($online) { '蓝牙 LE · 已连接' } else { '蓝牙 LE · 已断开' }
        }
        elseif ($modeTag -eq 'usb') {
            if (-not $online) { $modeText = '2.4G 接收器 · 已断开' }
            elseif ($d.Idle) { $modeText = '2.4G 接收器 · 待机' }
            else { $modeText = '2.4G 接收器 · 已连接' }
        }
        else { $modeText = '未检测到设备' }
        $g.DrawString($modeText, $script:FntSub, $script:BrSub, [single]18, [single]38)

        # 百分比用原始读数判断：$level 已经被夹到 0，拿它判空会把"没数据"显示成 0%
        $pctText = if ($d.Level -ge 0) { '{0}%' -f $d.Level } else { '--' }
        $sz = $g.MeasureString($pctText, $script:FntBig)
        $g.DrawString($pctText, $script:FntBig, $brAccent, [single](286 - $sz.Width), [single]10)

        $trackPath = Get-RoundPath 18 68 268 10 5
        $g.FillPath($script:BrTrack, $trackPath)
        if ($level -gt 0) {
            $fillW = [single](268 * ($level / 100.0))
            if ($fillW -lt 10) { $fillW = 10 }
            $g.SetClip($trackPath)
            $g.FillRectangle($brAccent, 18, 68, $fillW, 10)
            $g.ResetClip()
        }
        $trackPath.Dispose()

        $upd = if ($updAt) { $updAt.ToString('MM-dd HH:mm') } else { '—' }
        $refreshText = if ($modeTag -eq 'usb') { '事件上报' } else { ('{0} 秒' -f $script:Cfg.RefreshSeconds) }
        $g.DrawString(('数据更新 {0}   ·   {1}' -f $upd, $refreshText),
            $script:FntSub, $script:BrSub, [single]18, [single]88)

        if ($modeTag -eq 'ble' -and $s.Mac) {
            $mac = $s.Mac -replace '(..)(..)(..)(..)(..)(..)', '$1:$2:$3:$4:$5:$6'
            $g.DrawString(('设备 {0}' -f $mac), $script:FntHint, $script:BrSub, [single]18, [single]106)
        }
        elseif ($modeTag -eq 'usb' -and $script:Cfg.UsbVid) {
            $g.DrawString(('接收器 {0}:{1}   通道 0x{2}' -f $script:Cfg.UsbVid, $script:Cfg.UsbPid, $script:Cfg.UsbUsagePage),
                $script:FntHint, $script:BrSub, [single]18, [single]106)
        }
        $g.DrawString('点击任意处关闭', $script:FntHint, $script:BrSub, [single]206, [single]120)
        $brAccent.Dispose()
    })
    $script:Popup.Add_Click({
        $script:Popup.Hide(); $script:PopupUntil = [datetime]::MinValue
    })
    $script:Popup.Add_Deactivate({
        $script:Popup.Hide(); $script:PopupUntil = [datetime]::MinValue
    })
}

function Show-Popup {
    $curPt = [System.Windows.Forms.Cursor]::Position
    $scr = [System.Windows.Forms.Screen]::FromPoint($curPt)
    $wa = $scr.WorkingArea
    $x = [int]($wa.Right - $script:Popup.Width - 10)
    $y = [int]($wa.Bottom - $script:Popup.Height - 10)
    if ($curPt.Y -lt ($wa.Top + 100) -and $scr.Bounds.Top -lt $wa.Top) {
        $y = [int]($wa.Top + 10)
    }
    $script:Popup.Location = New-Object System.Drawing.Point($x, $y)
    $script:Popup.Show()
    $script:Popup.BringToFront()
    $script:Popup.Activate()
    $script:PopupUntil = (Get-Date).AddSeconds(4)
}

# ------------------------------------------------------------- 自启 ----
function Get-Autostart {
    try {
        $v = (Get-ItemProperty -Path $script:RunKey -Name $script:RunName -ErrorAction Stop).$($script:RunName)
        return [bool]$v
    }
    catch { return $false }
}

function Set-Autostart {
    param([bool]$Enable)
    try {
        if ($Enable) {
            $vbs = Join-Path $script:AppDir 'MousePowerTray.vbs'
            $ps1 = Join-Path $script:Root 'MousePowerTray.ps1'
            $sysRoot = $env:SystemRoot
            if (-not $sysRoot) { $sysRoot = 'C:\Windows' }
            $wscriptExe = Join-Path $sysRoot 'System32\wscript.exe'
            $psExe = Join-Path $sysRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

            $cmd = if (Test-Path -LiteralPath $vbs) { '"{0}" "{1}"' -f $wscriptExe, $vbs }
                   else { '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"' -f $psExe, $ps1 }
            New-ItemProperty -Path $script:RunKey -Name $script:RunName -Value $cmd -PropertyType String -Force | Out-Null
            Write-Log ('AUTOSTART-ON ' + $cmd)
        }
        else {
            Remove-ItemProperty -Path $script:RunKey -Name $script:RunName -Force -ErrorAction SilentlyContinue
            Write-Log 'AUTOSTART-OFF'
        }
    }
    catch { Write-Log ('AUTOSTART-ERR ' + $_.Exception.Message) }
}

function Stop-App {
    try { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() } catch { }
    try { if ($script:Popup) { $script:Popup.Dispose() } } catch { }
    # 收掉后台 Runspace
    try {
        if ($script:Worker) {
            $script:Worker.Stop()
            $script:Worker.Dispose()
            $script:Worker = $null
        }
    } catch { }
    # 收掉 HID 读线程，别让它占着设备句柄不放
    try { if ('HidBat' -as [type]) { [HidBat]::Stop(); [HidBat]::StopCapture() } } catch { }
    try { if ($script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch { }
    Write-Log 'EXIT'
    [System.Windows.Forms.Application]::ExitThread()
}

# ------------------------------------------------------------- 诊断 ----
# 目的：别人的鼠标在这个工具上不工作时，一次性收集足够判定"能不能支持、
# 怎么支持"的信息，而不是让对方在命令行里瞎试。
function Initialize-HidType {
    if ('HidBat' -as [type]) { return $true }
    try {
        Add-Type -TypeDefinition $script:UsbCSharp -Language CSharp -ErrorAction Stop
        return $true
    }
    catch {
        Write-Log ('HID-TYPE-ERR ' + $_.Exception.Message)
        return $false
    }
}

function Get-DiagBle {
    $rows = New-Object System.Collections.ArrayList
    $devs = @(Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue |
              Where-Object { $_.InstanceId -like 'BTHLE\*' })
    foreach ($d in $devs) {
        $lv = ''; $up = ''; $name = $d.FriendlyName
        try {
            $p = Get-PnpDeviceProperty -InstanceId $d.InstanceId -ErrorAction SilentlyContinue
            $k2 = $script:DevKey + ' 2'
            $k7 = $script:DevKey + ' 7'
            $lv = ($p | Where-Object { $_.KeyName -eq $k2 }).Data
            $up = ($p | Where-Object { $_.KeyName -eq $k7 }).Data
            $fn = ($p | Where-Object { $_.KeyName -eq 'DEVPKEY_Device_FriendlyName' }).Data
            if ($fn) { $name = ([string]$fn).Trim() }
        }
        catch { }
        $mac = ''
        if ($d.InstanceId -match 'DEV_([0-9A-Fa-f]{12})') { $mac = $Matches[1] }
        [void]$rows.Add([pscustomobject]@{
            Name = $name
            Mac = $mac
            Level = $(if ($lv -eq '' -or $lv -eq $null) { $null } else { [int]$lv })
            Updated = $up
        })
    }
    return $rows
}

function Get-DiagUsb {
    # 返回全部 HID 接口（含键鼠本体），供人眼判断哪个是接收器的厂商通道
    $rows = New-Object System.Collections.ArrayList
    $script:DiagUsbOk = $false
    if (-not (Initialize-HidType)) { return $rows }
    $raw = [HidBat]::Enumerate()
    if (-not $raw -or $raw[0] -eq 'ENUM-FAILED') { return $rows }
    foreach ($line in $raw) {
        if ($line -eq 'ENUM-FAILED') { continue }
        $f = $line -split '\|'
        if ($f.Count -lt 9) { continue }
        $inst = $f[8]
        # 只有 USB HID 才可能是 2.4G 接收器；触摸板/蓝牙/I2C 直连都不是
        $bus = 'other'
        if ($inst -like 'USB\*' -or $inst -like 'HID\VID_*') { $bus = 'usb' }
        elseif ($inst -like 'HIDI2C\*' -or $inst -like 'ACPI\*') { $bus = 'i2c' }
        elseif ($inst -like 'BTHLE\*' -or $inst -like 'BTHLEDEVICE\*' -or $inst -like 'BTHENUM\*') { $bus = 'ble' }
        if ($f[0] -eq '0000' -and $f[1] -eq '0000') { $bus = 'novid' }
        [void]$rows.Add([pscustomobject]@{
            Vid = $f[0]; Pid = $f[1]; Upage = $f[2]; Usage = $f[3]
            In = [int]$f[4]; Out = [int]$f[5]; Feat = [int]$f[6]
            Product = $f[7]; InstanceId = $inst; Bus = $bus
        })
    }
    $script:DiagUsbOk = ($rows.Count -gt 0)
    return $rows
}

function Get-DiagConclusion {
    param($Ble, $Usb)

    $bleWithLevel = @($Ble | Where-Object { $null -ne $_.Level })
    $bleNoLevel = @($Ble | Where-Object { $null -eq $_.Level })
    # 厂商自定义通道：usage page 0xFF00 以上。
    # 但只有走 USB 的才算 2.4G 接收器 —— 触摸板也常带 0xFF00 通道，
    # 不排除掉的话笔记本上会误判成"检测到接收器"。
    $allVendor = @($Usb | Where-Object { [Convert]::ToInt32($_.Upage, 16) -ge 0xFF00 })
    $vendor = @($allVendor | Where-Object { $_.Bus -eq 'usb' })
    $otherVendor = @($allVendor | Where-Object { $_.Bus -ne 'usb' })
    # 按 VID:PID 归组，一个接收器通常有多个接口
    $vendorGroups = @($vendor | Group-Object { '{0}:{1}' -f $_.Vid, $_.Pid })

    $out = New-Object System.Collections.ArrayList

    if ($bleWithLevel.Count -gt 0) {
        [void]$out.Add('结论：蓝牙模式下【本来就能用】，不需要适配。')
        [void]$out.Add('')
        [void]$out.Add('系统里已经存在可读的蓝牙电量：')
        foreach ($d in $bleWithLevel) {
            [void]$out.Add(('  {0}  {1}%  更新于 {2}' -f $d.Name, $d.Level, $d.Updated))
        }
        [void]$out.Add('')
        if ($vendorGroups.Count -gt 0) {
            $vn = (($vendorGroups | ForEach-Object { $_.Name }) -join ', ')
            [void]$out.Add(('注意：同时还插着 2.4G 接收器（{0}）。' -f $vn))
            [void]$out.Add('两种模式只能各读各的：切到 2.4G 后需要按「2.4G 适配」那一节单独处理。')
            [void]$out.Add('')
        }
        [void]$out.Add('如果托盘仍显示"未检测到设备"或数字不动，按顺序排查：')
        [void]$out.Add('  1. 右键托盘 →「选择设备…」，看有没有列出这台鼠标')
        [void]$out.Add('  2. 右键托盘 →「立即刷新」')
        [void]$out.Add('  3. 确认鼠标是蓝牙连接（不是插着 2.4G 接收器）')
        [void]$out.Add('  4. 数字不变属于正常：只有鼠标主动上报时系统才更新缓存')
        return $out
    }

    if ($vendorGroups.Count -gt 0) {
        [void]$out.Add('结论：检测到【2.4G 接收器】，需要针对厂商协议适配。')
        [void]$out.Add('')
        [void]$out.Add('蓝牙侧没有可读电量，但 USB 侧存在厂商自定义通道：')
        foreach ($g in $vendorGroups) {
            $first = @($g.Group)[0]
            [void]$out.Add(('  {0}  "{1}"  {2} 条厂商通道' -f $g.Name, $first.Product, $g.Count))
            foreach ($u in $g.Group) {
                [void]$out.Add(('     usagePage 0x{0}  in={1} out={2} feature={3}' -f $u.Upage, $u.In, $u.Out, $u.Feat))
            }
        }
        [void]$out.Add('')
        [void]$out.Add('这属于"能适配"的情况，但必须先抓到帧。请在收集时加抓包参数：')
        [void]$out.Add('  MousePowerTray.ps1 -Diagnose -Capture')
        [void]$out.Add('抓包期间按提示操作鼠标（开关电源 / 按 DPI 键），抓到的原始帧在')
        [void]$out.Add('capture.txt 里，据此可以定位电量字节。')
        [void]$out.Add('')
        $first = @($vendorGroups[0].Group)[0]
        [void]$out.Add('适配后 config.json 需要写：')
        foreach ($g in $vendorGroups) {
            $u0 = @($g.Group)[0]
            [void]$out.Add(('  "UsbVid": "{0}",  "UsbPid": "{1}",  "UsbUsagePage": "{2}"   ({3})' -f
                $u0.Vid, $u0.Pid, $u0.Upage, $u0.Product))
        }
        [void]$out.Add('（多个接收器时，填你实际在用的那个）')
        return $out
    }

    if ($bleNoLevel.Count -gt 0) {
        [void]$out.Add('结论：这是蓝牙 LE 设备，但【没有暴露标准电池服务】，无法支持。')
        [void]$out.Add('')
        [void]$out.Add('系统识别到了 BLE 设备，但读不到电池服务 0x180F：')
        foreach ($d in $bleNoLevel) {
            [void]$out.Add(('  {0}  {1}' -f $d.Name, $d.Mac))
        }
        [void]$out.Add('')
        [void]$out.Add('有的设备有 0x180F 服务节点却没被系统采到值，这种情况可以试：')
        [void]$out.Add('  1. 在系统设置里断开再重连设备')
        [void]$out.Add('  2. 重启蓝牙服务（管理员）：Restart-Service bthserv')
        [void]$out.Add('  3. 重新收集一次本报告，看电量是否出现')
        return $out
    }

    [void]$out.Add('结论：既没有蓝牙电量，也没有厂商自定义通道 —— 无法支持。')
    [void]$out.Add('')
    if (-not $script:DiagUsbOk) {
        [void]$out.Add('注意：本次 HID 接口枚举失败，所以"没有厂商通道"这一条不能确定。')
        [void]$out.Add('请重新收集一次；如果还是失败，多半是某个设备驱动独占了 HID 接口。')
        [void]$out.Add('')
    }
    [void]$out.Add('可能原因：')
    [void]$out.Add('  · 鼠标当前没连上（蓝牙未连接、接收器没插）')
    [void]$out.Add('  · 鼠标走纯经典蓝牙（BR/EDR），电量只在 HFP 通道里')
    [void]$out.Add('  · 设备用了专用驱动，HID 接口被独占')
    if ($otherVendor.Count -gt 0) {
        [void]$out.Add('')
        [void]$out.Add('（另有 ' + $otherVendor.Count + ' 条非 USB 的厂商通道，通常来自触摸板，与本问题无关）')
    }
    return $out
}

function Get-FrameDigest {
    # 把抓到的 CAP 行整理成"人＋机器都能读"的摘要。
    # 关键：不同类型的状态帧（D1/D2/…）字节含义完全不同，
    # 必须按「通道 + 长度 + 前两字节」先分组，组内统计才有意义。
    param($Cap)
    $out = New-Object System.Collections.ArrayList
    if (-not $Cap -or @($Cap).Count -eq 0) { return $out }

    $groups = @{}
    foreach ($f in $Cap) {
        $p = $f -split '\|'
        if ($p.Count -lt 3) { continue }
        $up = $p[1]; $hex = $p[2]
        $n = [int]($hex.Length / 2)
        if ($n -eq 0) { continue }
        $head = if ($hex.Length -ge 4) { $hex.Substring(0, 4) } else { $hex }
        $key = '{0}|{1}|{2}' -f $up, $n, $head
        if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object System.Collections.ArrayList }
        [void]$groups[$key].Add($hex)
    }

    $rank = 0
    foreach ($k in ($groups.Keys | Sort-Object)) {
        $parts = $k -split '\|'
        $frames = $groups[$k]
        $rank++
        [void]$out.Add(('  [类型{0}] 通道 0x{1}  {2} 字节  首 2 字节 0x{3}  共 {4} 帧' -f
            $rank, $parts[0], $parts[1], $parts[2], $frames.Count))
        $byteCount = [int]$parts[1]

        if ($frames.Count -le 1) {
            $first = $frames[0]
            $pretty = ''
            for ($q = 0; $q -lt $first.Length; $q += 2) { $pretty += $first.Substring($q, 2) + ' ' }
            [void]$out.Add('      只出现 1 次，无法比对：' + $pretty.Trim())
            continue
        }

        $fixedShown = 0
        for ($bi = 0; $bi -lt $byteCount; $bi++) {
            $mn = 255; $mx = 0
            foreach ($hf in $frames) {
                if ($hf.Length -lt ($bi * 2 + 2)) { continue }
                $v = [Convert]::ToByte($hf.Substring($bi * 2, 2), 16)
                if ($v -lt $mn) { $mn = $v }
                if ($v -gt $mx) { $mx = $v }
            }
            if ($mn -gt $mx) { continue }
            # 判定顺序很重要：先排除开关位，再谈电量候选
            $note = ''
            if ($mn -eq $mx) {
                if ($mn -eq 0 -or $mn -gt 100) { continue }
                if ($fixedShown -ge 3) { continue }
                $fixedShown++
                $note = '  固定值（本次没变，仅供参考）'
            }
            elseif ($mx -le 1) { $note = '  0/1 开关位（连接状态之类）' }
            elseif ($mx -le 100) { $note = '  值域 0-100  <<< 最可能是电量' }
            [void]$out.Add(('      [{0,2}]  0x{1:X2}..0x{2:X2}  ({3,3}..{4,3}){5}' -f $bi, $mn, $mx, $mn, $mx, $note))
        }
    }
    return $out
}

function Invoke-Diagnose {
    param([int]$CaptureSeconds = 0)

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop) { $desktop = $script:DataDir }
    $outDir = Join-Path $desktop ('MousePowerTray-诊断-' + $stamp)
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    $L = New-Object System.Collections.ArrayList
    # 用户名脱敏：报告要发给别人，路径里的账户名没必要带出去
    $uname = $env:USERNAME
    $add = {
        param($t)
        $s = [string]$t
        if ($uname) { $s = $s.Replace($uname, '***') }
        [void]$L.Add($s)
    }

    & $add '================ MousePowerTray 诊断报告 ================'
    & $add ('生成时间   : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    & $add ('计算机名   : ' + $env:COMPUTERNAME)
    & $add ('Windows    : ' + [System.Environment]::OSVersion.VersionString)
    & $add ('PowerShell : ' + $PSVersionTable.PSVersion.ToString())
    & $add ('程序版本   : ' + $script:AppVersion)
    & $add ('配置       : ' + $script:CfgPath)
    & $add ('当前模式   : ' + $(if ($script:Cfg.UsbVid) { '已配置 2.4G (' + $script:Cfg.UsbVid + ':' + $script:Cfg.UsbPid + ' usage 0x' + $script:Cfg.UsbUsagePage + ')' } else { '未配置 2.4G' }))
    & $add ''
    & $add '--- 配置内容 ---'
    try {
        foreach ($line in (Get-Content -LiteralPath $script:CfgPath -Raw -Encoding UTF8) -split "`r?`n") {
            & $add ('  ' + $line)
        }
    }
    catch { & $add '  （读取失败）' }
    & $add ''

    # ---- 蓝牙 ----
    & $add '--- 一、蓝牙 LE 设备（BTHLE 节点）---'
    $ble = @(Get-DiagBle)
    if ($ble.Count -eq 0) { & $add '  （没有找到任何 BLE 设备节点）' }
    else {
        foreach ($d in $ble) {
            $lvTxt = if ($null -ne $d.Level) { ('{0}%' -f $d.Level) } else { '(无电量属性)' }
            & $add ('  {0,-26} {1,-12} {2}   更新: {3}' -f $d.Name, $d.Mac, $lvTxt, $d.Updated)
        }
    }
    & $add ''

    # ---- 经典蓝牙 ----
    & $add '--- 二、经典蓝牙设备（BTHENUM 节点，仅列出名字）---'
    $enum = @(Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue |
              Where-Object { $_.InstanceId -like 'BTHENUM\*' })
    if ($enum.Count -eq 0) { & $add '  （无）' }
    else { foreach ($d in $enum) { & $add ('  ' + $d.FriendlyName + '   [' + $d.Status + ']') } }
    & $add ''

    # ---- HID ----
    & $add '--- 三、HID 接口清单 ---'
    $usb = @(Get-DiagUsb)
    if ($usb.Count -eq 0) {
        & $add ('  （枚举失败：' + $(if ($script:DiagUsbOk) { '没有可用接口' } else { 'HID 接口列表拿不到' }) + '）')
    }
    else {
        & $add '  总线  VID:PID   UsagePage Usage  In Out Feat  产品名'
        foreach ($u in $usb) {
            $mark = ''
            if ([Convert]::ToInt32($u.Upage, 16) -ge 0xFF00) {
                if ($u.Bus -eq 'usb') { $mark = '  <= 厂商通道(USB)' }
                else { $mark = '  <= 厂商通道(' + $u.Bus + '，非接收器)' }
            }
            elseif ($u.Bus -eq 'novid') { $mark = '  （蓝牙 HID，无 VID）' }
            & $add ('  {0,-5} {1}:{2}  0x{3,-6} 0x{4,-4} {5,3} {6,3} {7,4}  {8}{9}' -f
                $u.Bus, $u.Vid, $u.Pid, $u.Upage, $u.Usage, $u.In, $u.Out, $u.Feat, $u.Product, $mark)
        }
        & $add ''
        & $add '  厂商通道的设备实例（适配 2.4G 时要用到的）:'
        $anyUsb = $false
        foreach ($u in $usb) {
            if ([Convert]::ToInt32($u.Upage, 16) -ge 0xFF00 -and $u.Bus -eq 'usb') {
                & $add ('    0x{0}  {1}' -f $u.Upage, $u.InstanceId)
                $anyUsb = $true
            }
        }
        if (-not $anyUsb) { & $add '    （没有 USB 厂商通道）' }
    }
    & $add ''

    # ---- 结论 ----
    & $add '--- 四、自动判定 ---'
    foreach ($line in (Get-DiagConclusion -Ble $ble -Usb $usb)) { & $add $line }
    & $add ''

    # ---- 抓包 ----
    if ($CaptureSeconds -gt 0) {
        & $add ('--- 五、厂商通道抓包（{0} 秒）---' -f $CaptureSeconds)
        $vendor = @($usb | Where-Object { [Convert]::ToInt32($_.Upage, 16) -ge 0xFF00 -and $_.Bus -eq 'usb' })
        if ($vendor.Count -eq 0) {
            & $add '  没有 USB 厂商通道，跳过抓包。'
        }
        elseif (-not (Initialize-HidType)) {
            & $add '  HID 类型加载失败，跳过。'
        }
        else {
            $targets = @()
            foreach ($v in $vendor) {
                $inc = if ($v.In -gt 0) { $v.In } else { 64 }
                $targets += ('{0}:{1}:{2}:{3}' -f [Convert]::ToInt32($v.Upage, 16), $inc,
                    [Convert]::ToInt32($v.Vid, 16), [Convert]::ToInt32($v.Pid, 16))
            }
            $n = [HidBat]::CaptureStart($targets)
            & $add ('  已启动 {0} 条通道：{1}' -f $n, ($targets -join ', '))
            if ([HidBat]::CapError) { & $add ('  错误: ' + [HidBat]::CapError) }

            Write-Host ''
            Write-Host '  抓包中…… 请现在操作鼠标：' -ForegroundColor Cyan
            Write-Host '    · 关掉鼠标电源，等 3 秒，再打开（最重要）' -ForegroundColor Cyan
            Write-Host '    · 按几下 DPI 键 / 模式切换键' -ForegroundColor Cyan
            Write-Host ''

            $cap = New-Object System.Collections.ArrayList
            $end = (Get-Date).AddSeconds($CaptureSeconds)
            while ((Get-Date) -lt $end) {
                Start-Sleep -Milliseconds 400
                foreach ($f in [HidBat]::Poll()) {
                    if ($f -like 'CAP|*') { [void]$cap.Add($f) }
                }
                $left = [int]($end - (Get-Date)).TotalSeconds
                Write-Progress -Activity '抓包中' -Status ("剩余 {0} 秒，已收到 {1} 帧" -f [Math]::Max(0, $left), $cap.Count) `
                    -PercentComplete ([Math]::Min(100, 100 * $cap.Count / 20))
            }
            Write-Progress -Activity '抓包中' -Completed
            [HidBat]::StopCapture()

            & $add ('  共收到 {0} 帧' -f $cap.Count)
            if ($cap.Count -eq 0) {
                & $add '  一帧都没有。该设备可能只在主机主动查询时才回应（需要发命令，另议）。'
            }
            else {
                # 帧格式初判交给 Get-FrameDigest，便于单独验证
                & $add ''
                & $add '  —— 帧格式初判（同一类帧内，按字节位置统计取值范围）——'
                foreach ($dl in (Get-FrameDigest -Cap $cap)) { & $add $dl }
                & $add ''
                & $add '  判读方法：关掉鼠标电源时归零、开机后回到几十的那个字节就是电量。'
                & $add '  若所有字节都固定不动，说明这次没抓到状态变化，需要重抓。'
                & $add '  同一个类型里出现多个 0-100 的候选时，对照系统设置页显示的电量'
                & $add '  数字就能锁定是哪一个 —— 发送报告时把那个数字一起说明即可。'
            }
            $capFile = Join-Path $outDir 'capture.txt'
            $cap | Set-Content -LiteralPath $capFile -Encoding UTF8
            & $add ('  原始帧     : capture.txt')
        }
    }

    # ---- 日志 ----
    if (Test-Path -LiteralPath $script:LogPath) {
        Copy-Item -LiteralPath $script:LogPath -Destination (Join-Path $outDir 'tray.log') -Force
        & $add ''
        & $add '--- 六、日志 ---'
        & $add '  已附带 tray.log（最近的运行记录）'
    }

    $reportPath = Join-Path $outDir '诊断报告.txt'
    $L | Set-Content -LiteralPath $reportPath -Encoding UTF8

    # 控制台也打一份，方便命令行直接看
    $L | ForEach-Object { Write-Host $_ }

    # 打包，方便直接发出去
    $zip = $outDir + '.zip'
    try {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zip -CompressionLevel Optimal
        if (Test-Path -LiteralPath $zip) {
            Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
            $outDir = $zip
        }
    }
    catch { }

    return $outDir
}

# ------------------------------------------------------------- 诊断路由 ----
if ($Diagnose) {
    $secs = if ($Capture) { [Math]::Max(5, $CaptureSeconds) } else { 0 }
    Write-Log ('DIAGNOSE start capture={0}s' -f $secs)
    $path = Invoke-Diagnose -CaptureSeconds $secs
    Write-Host ''
    Write-Host ('诊断包已生成：' + $path) -ForegroundColor Green
    Write-Host '把这个文件发给开发者即可，里面不含任何个人数据。' -ForegroundColor DarkGray
    try { Start-Process explorer.exe ('/select,"' + $path + '"') } catch { }
    exit 0
}

# ------------------------------------------------------------- 自检 ----
if ($SelfTest) {
    Write-Log 'SELFTEST start'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = & $script:ProbeBlock @{ DevKey = $script:DevKey
                                  Scan = $true; Id = ''; Name = ''; NameFilter = $script:Cfg.NameFilter }
    "scan elapsed : $($sw.ElapsedMilliseconds) ms"
    "ble nodes    : $($res.BleCount)"
    "usable       : $(@($res.Devices).Count)"
    foreach ($d in @($res.Devices)) {
        '  {0,-24} {1,3}%  online={2,-5} updated={3}  {4}' -f $d.Name, $d.Level, $d.Online, $d.Updated, $d.Mac
    }
    if ($res.Error) { "error        : $($res.Error)" }
    Write-Log ('SELFTEST ble={0} usable={1}' -f $res.BleCount, @($res.Devices).Count)

    $outDir = Join-Path $script:AppDir 'preview'
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
    $levels = 100, 75, 45, 30, 10
    $cell = 128
    $sheet = New-Object System.Drawing.Bitmap(($cell * ($levels.Count + 1)), ($cell + 28))
    $gg = [System.Drawing.Graphics]::FromImage($sheet)
    $gg.Clear([System.Drawing.Color]::FromArgb(28, 30, 34))
    $gg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $gg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $ef = New-Object System.Drawing.Font('Segoe UI', 9)
    $eb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 156, 166))
    $efm = New-Object System.Drawing.StringFormat
    $efm.Alignment = [System.Drawing.StringAlignment]::Center

    $i = 0
    foreach ($lv in $levels) {
        $gg.DrawString(('{0}%' -f $lv), $ef, $eb,
            (New-Object System.Drawing.RectangleF(($i * $cell), ($cell + 4), $cell, 20)), $efm)
        $i++
    }
    $gg.DrawString('离线', $ef, $eb,
        (New-Object System.Drawing.RectangleF(($i * $cell), ($cell + 4), $cell, 20)), $efm)

    $i = 0
    foreach ($lv in $levels) {
        $b = New-MouseBitmap -Size 16 -Level $lv -Online $true
        $gg.DrawImage($b, ($i * $cell), 0, $cell, $cell)
        $b.Save((Join-Path $outDir ("icon-{0}.png" -f $lv)), [System.Drawing.Imaging.ImageFormat]::Png)
        $b.Dispose()
        $i++
    }
    $b = New-MouseBitmap -Size 16 -Level 45 -Online $false
    $gg.DrawImage($b, ($i * $cell), 0, $cell, $cell)
    $b.Dispose()
    $gg.Dispose()
    $sheet.Save((Join-Path $outDir 'icon-sheet.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $sheet.Dispose()
    $ef.Dispose(); $eb.Dispose(); $efm.Dispose()

    $tb = New-MouseBitmap -Size 16 -Level 88 -Online $true
    $pack = ConvertTo-TrayIcon -Bitmap $tb
    "icon ico ok   : $($null -ne $pack.Icon)"
    $pack.Icon.Dispose(); $pack.Stream.Dispose(); $tb.Dispose()
    "data dir      : $script:DataDir"
    exit 0
}

# ------------------------------------------------------------- 启动 ----
[void][System.Windows.Forms.Application]::EnableVisualStyles()

$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\MousePowerTray')
if (-not $script:Mutex.WaitOne(0)) {
    Write-Log 'EXIT duplicate instance'
    $alertMsg = "鼠标电量托盘已经在后台运行中。`r`n`r`n请查看任务栏右下角托盘图标（可能在折叠箭头 ^ 内部）。`r`n如需完全重新启动，请先右键托盘图标选择[退出]。"
    [void][System.Windows.Forms.MessageBox]::Show(
        $alertMsg,
        $script:AppName,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
    exit 0
}

$script:FntTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
$script:FntBig = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold)
$script:FntSub = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$script:FntHint = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$script:BrText = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(236, 239, 244))
$script:BrSub = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(138, 146, 156))
$script:BrTrack = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(52, 56, 63))

$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:NotifyIcon.Visible = $true
$script:NotifyIcon.Text = $script:AppName
# 初始图标：Icon 是从流里惰性读数据的，流必须一直留着，
# 否则被 GC 回收后托盘图标会变成空白。
$bmp0 = New-MouseBitmap -Size 16 -Level -1 -Online $false
$pack0 = ConvertTo-TrayIcon -Bitmap $bmp0
$bmp0.Dispose()
$script:NotifyIcon.Icon = $pack0.Icon
$script:IconStream = $pack0.Stream

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:MenuHeader = New-Object System.Windows.Forms.ToolStripMenuItem('  正在识别设备…')
$script:MenuHeader.Enabled = $false
[void]$menu.Items.Add($script:MenuHeader)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miDetail = $menu.Items.Add('显示详情')
$miPick = $menu.Items.Add('选择设备…')
$miRefresh = $menu.Items.Add('立即刷新')
$miAuto = $menu.Items.Add('开机自动启动')
$miAuto.CheckOnClick = $true
$miAuto.Checked = Get-Autostart
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miDiag = $menu.Items.Add('读不到电量？收集诊断信息…')
$miLog = $menu.Items.Add('打开日志')
$miExit = $menu.Items.Add('退出')
$script:NotifyIcon.ContextMenuStrip = $menu

New-Popup

$miDetail.Add_Click({ Show-Popup })
$script:NotifyIcon.Add_MouseDoubleClick({ Show-Popup })
$script:NotifyIcon.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Popup }
})
$miPick.Add_Click({
    if (@($script:State.Devices).Count -gt 0) { Show-Picker }
    else { $script:PickerPending = $true; $script:NeedScan = $true; Start-Probe }
})
$miRefresh.Add_Click({
    $script:State.Devices = @()
    if ($script:Cfg.DeviceId) { $script:ForceRescan = $true }
    else { $script:NeedScan = $true }
    $script:State.LastSeen = $null
    # 断电/断连后系统移除 PnP 节点有几秒延迟，先立刻探一次，4 秒后再确认一次
    $script:VerifyAt = (Get-Date).AddSeconds(4)
    if ($script:Worker) { $script:PendingRefresh = $true } else { Start-Probe }
})
$miAuto.Add_Click({ Set-Autostart -Enable ([bool]$miAuto.Checked) })
$miDiag.Add_Click({
    $msg = @"
这会把本机的蓝牙 / HID 设备信息和最近日志打包成一个 zip 放到桌面，
其中不含个人文件，账户名已打码。

如果鼠标走的是 2.4G 接收器，还会监听 30 秒设备通道 —— 期间请：
  1. 关掉鼠标电源，等 3 秒，再打开
  2. 按几下 DPI 键

会打开一个窗口显示进度，不要关它。

继续吗？
"@
    $r = [System.Windows.Forms.MessageBox]::Show($msg, '收集诊断信息',
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Information)
    if ($r -ne 'OK') { return }
    if (-not (Start-DiagnoseProcess)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            ('启动失败。可以手动运行：' + "`r`n" + (Join-Path $script:Root 'MousePowerTray.ps1') + ' -Diagnose'),
            '收集诊断信息', 'OK', 'Warning')
    }
})
$miLog.Add_Click({ if (Test-Path -LiteralPath $script:LogPath) { Start-Process notepad.exe $script:LogPath } })
$miExit.Add_Click({ Stop-App })

Write-Log ('START pid={0} cfg={1}' -f $PID, $(if ($script:Cfg.DeviceId) { $script:Cfg.DeviceName } else { '(none)' }))

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    Update-UsbState
    # 接收器可能后插上来，未启动时每 30 秒探测一次（支持用户配置或预设库匹配）
    if (-not $script:UsbWorker -and ((Get-Date) - $script:UsbTryAt).TotalSeconds -ge 30) {
        $script:UsbTryAt = Get-Date
        Start-UsbListener
    }
    # 看门狗：后台探测超过 15 秒判定为驱动/PnP 阻塞，强制重置
    if ($script:Worker) {
        if (((Get-Date) - $script:WorkerStart).TotalSeconds -gt 15) {
            Write-Log 'PROBE-TIMEOUT worker hung > 15s, resetting'
            try { $script:Worker.Stop() } catch { }
            try { $script:Worker.Dispose() } catch { }
            $script:Worker = $null
            $script:WorkerHandle = $null
        }
        else {
            Complete-Probe
        }
    }
    elseif ($script:PendingRefresh) { $script:PendingRefresh = $false; Start-Probe }
    elseif ($script:VerifyAt -and (Get-Date) -ge $script:VerifyAt) { $script:VerifyAt = $null; Start-Probe }
    elseif (((Get-Date) - $script:WorkerStart).TotalMilliseconds -ge ($script:Cfg.RefreshSeconds * 1000)) {
        Start-Probe
    }
    if ($script:Popup -and $script:Popup.Visible -and (Get-Date) -gt $script:PopupUntil) {
        $script:Popup.Hide()
    }
})
$timer.Start()

Start-UsbListener
Start-Probe

try {
    [System.Windows.Forms.Application]::Run()
}
finally {
    try { $timer.Stop(); $timer.Dispose() } catch { }
    try { $script:FntTitle.Dispose(); $script:FntBig.Dispose(); $script:FntSub.Dispose(); $script:FntHint.Dispose() } catch { }
    try { $script:BrText.Dispose(); $script:BrSub.Dispose(); $script:BrTrack.Dispose() } catch { }
    try { if ($script:IconStream) { $script:IconStream.Dispose() } } catch { }
    Write-Log 'LOOP end'
}
