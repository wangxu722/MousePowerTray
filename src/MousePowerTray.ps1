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
#>
[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------- 常量 ----
$script:AppName = '鼠标电量'
$script:AppId = 'MousePowerTray'
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
        # 2.4G 接收器（厂商私有通道）—— 换鼠标改这三项
        UsbVid         = '089D'
        UsbPid         = '062F'
        UsbUsagePage   = 'FF02'
        LastUsbLevel   = -1
        Version        = 2
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
    if (-not $Online -or $Level -lt 0) { return [System.Drawing.Color]::FromArgb(154, 163, 173) }
    if ($Level -le $script:Cfg.LowPercent) { return [System.Drawing.Color]::FromArgb(240, 60, 60) }
    if ($Level -le 40) { return [System.Drawing.Color]::FromArgb(255, 192, 54) }
    return [System.Drawing.Color]::FromArgb(25, 250, 198)
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
    $x0 = $s * 0.19; $x1 = $s * 0.81
    $y0 = $s * 0.06; $y1 = $s * 0.94
    $w = $x1 - $x0; $h = $y1 - $y0
    $path = Get-RoundPath $x0 $y0 $w $h ($w / 2.0)

    $accent = Get-StatusColor -Level $Level -Online $Online
    if ($Online) { $empty = [System.Drawing.Color]::FromArgb(150, 156, 166) }
    else { $empty = [System.Drawing.Color]::FromArgb(118, 124, 134); $accent = [System.Drawing.Color]::FromArgb(152, 159, 169) }

    $lvl = [math]::Max(0, [math]::Min(100, $Level))
    $fillTop = $y1 - ($h * ($lvl / 100.0))

    $bEmpty = New-Object System.Drawing.SolidBrush($empty)
    $bFill = New-Object System.Drawing.SolidBrush($accent)
    $g.SetClip($path)
    $g.FillRectangle($bEmpty, $x0, $y0, $w, $h)
    if ($lvl -gt 0) { $g.FillRectangle($bFill, $x0, $fillTop, $w, ($y1 - $fillTop) + 0.5) }
    $g.ResetClip()

    $penW = [single]([math]::Max(1.0, $s * 0.075))
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(38, 42, 48), $penW)
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawPath($pen, $path)

    $dark = [System.Drawing.Color]::FromArgb(38, 42, 48)
    $penSeam = New-Object System.Drawing.Pen($dark, [single]([math]::Max(1.0, $s * 0.055)))

    $wheelW = $s * 0.16; $wheelH = $s * 0.20
    $wheelX = $s * 0.5 - $wheelW / 2
    $wheelY = $y0 + $h * 0.13
    $wheelPath = Get-RoundPath $wheelX $wheelY $wheelW $wheelH ($wheelW / 2)
    $bDark = New-Object System.Drawing.SolidBrush($dark)
    $g.FillPath($bDark, $wheelPath)
    $g.DrawLine($penSeam, $s * 0.5, ($wheelY + $wheelH + 0.6), $s * 0.5, ($y0 + $h * 0.42))

    $pen.Dispose(); $penSeam.Dispose(); $bEmpty.Dispose(); $bFill.Dispose(); $bDark.Dispose()
    $wheelPath.Dispose(); $path.Dispose(); $g.Dispose()
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
    $out = @{ Ok = $false; Error = ''; Devices = @(); BleCount = 0 }

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
            foreach ($n in $nodes) {
                $dev = $null
                try { $dev = Read-Node $n.InstanceId $cfg.DevKey $n.FriendlyName } catch { }
                if (-not $dev) { continue }
                if ($cfg.NameFilter) {
                    if ($dev.Name -notmatch $cfg.NameFilter) { continue }
                }
                if ($dev.Mac) {
                    $dev.Online = $hidIndex.Contains($dev.Mac.ToUpperInvariant())
                }
                [void]$list.Add($dev)
            }
            $out.Devices = @($list | Sort-Object @{ Expression = 'Online'; Descending = $true }, @{ Expression = 'Level'; Descending = $true })
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
    public struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID; public ushort ProductID; public ushort VersionNumber; }
    [StructLayout(LayoutKind.Sequential)]
    public struct OVERLAPPED { public IntPtr Internal; public IntPtr InternalHigh; public int Offset; public int OffsetHigh; public IntPtr hEvent; }

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr SetupDiGetClassDevsW(ref GUID g, IntPtr e, IntPtr p, int f);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref GUID g, int i, ref SP_DEVICE_INTERFACE_DATA x);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr s, ref SP_DEVICE_INTERFACE_DATA x, IntPtr b, int n, out int r, IntPtr d);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
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
    const int FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2;
    const uint OPEN_EXISTING = 3, FILE_FLAG_OVERLAPPED = 0x40000000;
    const int DIGCF_PRESENT = 2, DIGCF_DEVICEINTERFACE = 0x10;
    static readonly IntPtr INVALID = new IntPtr(-1);

    static readonly ConcurrentQueue<string> queue = new ConcurrentQueue<string>();
    static Thread worker;
    static volatile bool running;
    public static string Path = "";
    public static string Error = "";

    public static bool Start(int upage, int vid, int pid)
    {
        if (worker != null) return true;
        string path = Find(upage, vid, pid);
        if (path == null) return false;
        Path = path;
        running = true;
        worker = new Thread(Loop);
        worker.IsBackground = true;
        worker.Start();
        return true;
    }

    public static void Stop() { running = false; }

    public static bool IsRunning { get { return running; } }

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
                        if (vid > 0 && (attr.VendorID != vid || attr.ProductID != pid)) continue;
                        IntPtr pp;
                        if (!HidD_GetPreparsedData(h, out pp) || pp == IntPtr.Zero) continue;
                        try
                        {
                            byte[] caps = new byte[256];
                            if (HidP_GetCaps(pp, caps) != 0x00110000) continue;
                            int up = BitConverter.ToUInt16(caps, 2);
                            if (up != upage) continue;
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

    static void Loop()
    {
        IntPtr h = CreateFileW(Path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero,
                               OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);
        if (h == INVALID) { Error = "open-failed " + Marshal.GetLastWin32Error(); running = false; return; }
        int len = 33;
        var buf = new byte[65];
        try
        {
            while (running)
            {
                int got = ReadWithTimeout(h, buf, len, 500);
                if (got > 0)
                {
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
            if (WaitForSingleObject(ev, (uint)ms) != 0) { CancelIoEx(h, ov); return 0; }
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
}
'@

function Start-UsbListener {
    if ($script:UsbWorker) { return }
    try {
        if (-not ('HidBat' -as [type])) {
            Add-Type -TypeDefinition $script:UsbCSharp -Language CSharp -ErrorAction Stop
        }
        $vid = 0; $pid_ = 0
        if ($script:Cfg.UsbVid) { $vid = [Convert]::ToInt32(('0x' + $script:Cfg.UsbVid), 16) }
        if ($script:Cfg.UsbPid) { $pid_ = [Convert]::ToInt32(('0x' + $script:Cfg.UsbPid), 16) }
        $upage = [Convert]::ToInt32(('0x' + $script:Cfg.UsbUsagePage), 16)
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
            return
        }
    }
    catch { }
    $frames = [HidBat]::Poll()
    $changed = $false
    foreach ($f in $frames) {
        $hex, $ts = $f -split '\|'
        if ($hex.Length -lt 8) { continue }
        $b = @()
        for ($i = 0; $i -lt $hex.Length; $i += 2) { $b += [Convert]::ToByte($hex.Substring($i, 2), 16) }
        if ($b.Count -lt 4) { continue }
        if ($b[1] -ne 0xD1) {
            if ($script:Cfg.Debug) { Write-Log ('USB-FRAME(ignored) ' + $hex) }
            continue
        }
        $lv = [int]$b[3]
        if ($lv -lt 0 -or $lv -gt 100) { continue }
        if (-not $script:Usb.HasData -or $script:Usb.Level -ne $lv) { $changed = $true }
        $script:Usb.HasData = $true
        $script:Usb.Level = $lv
        $script:Usb.At = Get-Date
        # 收到任何 D1 帧就说明设备活着；[2]=0 只是待机/链路挂起，不当作断连
        if (-not $script:Usb.Online) { $changed = $true }
        $script:Usb.Online = $true
        $script:Usb.Idle = ($b[2] -eq 0)
        if ($script:Cfg.Debug) {
            Write-Log ('USB-FRAME level={0} link={1} raw={2}' -f $lv, $b[2], $hex)
        }
        if ($script:Cfg.LastUsbLevel -ne $lv) { $script:Cfg.LastUsbLevel = $lv; Save-Config }
    }

    # 连续 180 秒没有任何帧，才认为真的关了 / 走远了（上报间隔实测约 1–1.5 分钟）
    if ($script:Usb.HasData -and $script:Usb.Online) {
        if (((Get-Date) - $script:Usb.At).TotalSeconds -gt 180) {
            $script:Usb.Online = $false
            $changed = $true
            Write-Log 'USB-OFFLINE (no frame in 180s)'
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
$script:VerifyAt = $null               # 手动刷新后的二次确认时刻（PnP 移除有延迟）
$script:PickerPending = $false
$script:FailCount = 0
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
        Write-Log ('SCAN ok={0} ble={1} usable={2} -> {3}' -f $res.Ok, $res.BleCount, $devs.Count,
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
        }
        if (-not $dev) { $dev = @($res.Devices)[0] }
    }

    if ($dev) {
        $script:FailCount = 0
        if ($script:Cfg.Debug) {
            Write-Log ('POLL {0} {1}% online={2}' -f $dev.Name, $dev.Level, $dev.Online)
        }
        # 从在线翻成离线时补验一次，避免一次瞬时抖动就把图标判灰
        if ($script:State.Online -and -not $dev.Online) {
            $script:VerifyAt = (Get-Date).AddSeconds(2)
            Write-Log 'STATE online -> offline (verify in 2s)'
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
        Write-Log ("PROBE-MISS {0} ({1})" -f $res.Error, $script:FailCount)
        $script:State.Connected = $false
        $script:State.Online = $false
        if ($script:FailCount -ge 3) {
            # 连续 3 次读不到电量（蓝牙断开、或鼠标切到了 2.4G）：
            # 只触发一次重扫，不要清掉配置里的设备——切回蓝牙时还得靠它
            $script:FailCount = 0
            if (-not $script:Cfg.DeviceId) { $script:NeedScan = $true }
        }
    }

    Update-Tray
}

# 统一决定「现在该显示谁」——托盘和浮层都走这里，避免两处逻辑跑偏
# 优先级：蓝牙在线 > 2.4G 有数据 > 2.4G 接收器在但还没上报 > 蓝牙（离线态）
function Get-DisplayState {
    $s = $script:State
    $bleOnline = [bool]$s.Online
    $usbReady = $script:UsbWorker -and $script:Usb.HasData
    $nmBle = if ($s.Name) { $s.Name } else { $script:AppName }
    $nmUsb = if ($script:Cfg.DeviceName) { $script:Cfg.DeviceName } elseif ($s.Name) { $s.Name } else { $script:AppName }

    if ($bleOnline) {
        return @{ Mode = 'ble'; Online = $true; Level = $s.Level; LastLevel = $s.LastLevel
                  Name = $nmBle; Idle = $false; At = $s.LastGoodUpdate }
    }
    if ($usbReady) {
        return @{ Mode = 'usb'; Online = [bool]$script:Usb.Online; Level = $script:Usb.Level
                  LastLevel = $script:Usb.Level; Name = $nmUsb; Idle = [bool]$script:Usb.Idle; At = $script:Usb.At }
    }
    if ($script:UsbWorker) {
        $lv = if ($script:Cfg.LastUsbLevel -ge 0) { [int]$script:Cfg.LastUsbLevel } else { -1 }
        return @{ Mode = 'usb'; Online = $false; Level = $lv; LastLevel = $lv
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
function Show-Picker {
    $devs = @($script:State.Devices)

    $f = New-Object System.Windows.Forms.Form
    $f.Text = '选择要显示电量的设备'
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $f.ClientSize = New-Object System.Drawing.Size(420, 232)
    $f.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $lb = New-Object System.Windows.Forms.ListBox
    $lb.SetBounds(14, 14, 392, 150)
    $lb.IntegralHeight = $false
    foreach ($d in $devs) {
        $state = if ($d.Online) { '已连接' } else { '未连接' }
        $item = '{0}   —   {1}%   ({2})' -f $d.Name, $d.Level, $state
        [void]$lb.Items.Add($item)
    }
    if ($lb.Items.Count -gt 0) { $lb.SelectedIndex = 0 }

    $tip = New-Object System.Windows.Forms.Label
    if ($devs.Count -eq 0) {
        $tip.Text = '没有找到能读电量蓝牙设备。' + "`r`n" + '请确认设备已通过蓝牙连接（不是 2.4G 接收器），然后点“重新扫描”。'
        $tip.ForeColor = [System.Drawing.Color]::FromArgb(160, 60, 50)
    }
    else {
        $tip.Text = '选择后会自动记住，下次直接显示。'
        $tip.ForeColor = [System.Drawing.Color]::Gray
    }
    $tip.SetBounds(14, 168, 392, 34)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '确定'
    $btnOk.SetBounds(222, 200, 88, 26)
    $btnOk.Enabled = ($devs.Count -gt 0)

    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Text = '重新扫描'
    $btnScan.SetBounds(126, 200, 88, 26)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.SetBounds(318, 200, 88, 26)

    $btnOk.Add_Click({
        $i = $lb.SelectedIndex
        if ($i -ge 0 -and $i -lt $devs.Count) {
            $d = $devs[$i]
            $script:Cfg.DeviceId = $d.Id
            $script:Cfg.DeviceName = $d.Name
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
        $f.Close()
    })
    $btnScan.Add_Click({
        $script:PickerPending = $true
        $script:NeedScan = $true
        $f.Close()
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

        $pctText = if ($level -ge 0 -and $s.Mode -eq 'ble') { '{0}%' -f $level } else { '--' }
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

        if ($s.Mac) {
            $mac = $s.Mac -replace '(..)(..)(..)(..)(..)(..)', '$1:$2:$3:$4:$5:$6'
            $g.DrawString(('设备 {0}' -f $mac), $script:FntHint, $script:BrSub, [single]18, [single]106)
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
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $script:Popup.Location = New-Object System.Drawing.Point(
        ($wa.Right - $script:Popup.Width - 10), ($wa.Bottom - $script:Popup.Height - 10))
    $script:Popup.Show()
    $script:Popup.BringToFront()
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
            $cmd = if (Test-Path -LiteralPath $vbs) { 'wscript.exe "{0}"' -f $vbs }
                   else { 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $ps1 }
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
    try { if ($script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch { }
    Write-Log 'EXIT'
    [System.Windows.Forms.Application]::ExitThread()
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
$script:NotifyIcon.Icon = (ConvertTo-TrayIcon -Bitmap (New-MouseBitmap -Size 16 -Level -1 -Online $false)).Icon

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
$miLog.Add_Click({ if (Test-Path -LiteralPath $script:LogPath) { Start-Process notepad.exe $script:LogPath } })
$miExit.Add_Click({ Stop-App })

Write-Log ('START pid={0} cfg={1}' -f $PID, $(if ($script:Cfg.DeviceId) { $script:Cfg.DeviceName } else { '(none)' }))

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    Update-UsbState
    # 接收器可能后插上来，没启动过就每 30 秒试一次
    if (-not $script:UsbWorker -and ((Get-Date) - $script:UsbTryAt).TotalSeconds -ge 30) {
        $script:UsbTryAt = Get-Date
        Start-UsbListener
    }
    if ($script:Worker) { Complete-Probe }
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
