# 2.4G 接收器 HID 探针
# 只用只读方式监听厂商自定义接口（Usage Page >= 0xFF00），绝不打开键鼠本体（0x0001）。
param(
    [int]$Seconds = 10,
    [string]$Vid = '',
    [int]$Upage = 0,
    [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'

$cs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class HidProbe
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
    public static extern IntPtr SetupDiGetClassDevsW(ref GUID ClassGuid, IntPtr Enumerator, IntPtr hwndParent, int Flags);
    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern bool SetupDiEnumDeviceInterfaces(IntPtr hDevInfo, IntPtr devInfo, ref GUID interfaceClassGuid, int memberIndex, ref SP_DEVICE_INTERFACE_DATA deviceInterfaceData);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr hDevInfo, ref SP_DEVICE_INTERFACE_DATA did, IntPtr detail, int detailSize, out int requiredSize, IntPtr devInfoData);
    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);
    [DllImport("hid.dll")]
    public static extern void HidD_GetHidGuid(out GUID guid);
    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetAttributes(IntPtr device, ref HIDD_ATTRIBUTES attributes);
    [DllImport("hid.dll", CharSet = CharSet.Unicode)]
    public static extern bool HidD_GetProductString(IntPtr device, IntPtr buffer, int bufferLength);
    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetPreparsedData(IntPtr hidDeviceObject, out IntPtr preparsedData);
    [DllImport("hid.dll")]
    public static extern int HidP_GetCaps(IntPtr preparsedData, byte[] capabilities);
    [DllImport("hid.dll")]
    public static extern bool HidD_FreePreparsedData(IntPtr preparsedData);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string fileName, uint desiredAccess, int shareMode, IntPtr securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadFile(IntPtr hFile, byte[] buffer, int numberOfBytesToRead, out int numberOfBytesRead, IntPtr lpOverlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateEventW(IntPtr attr, bool manualReset, bool initialState, IntPtr name);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetOverlappedResult(IntPtr hFile, IntPtr lpOverlapped, out int transferred, bool wait);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CancelIoEx(IntPtr hFile, IntPtr lpOverlapped);

    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const int FILE_SHARE_READ = 1;
    const int FILE_SHARE_WRITE = 2;
    const uint OPEN_EXISTING = 3;
    const uint FILE_FLAG_OVERLAPPED = 0x40000000;
    const int DIGCF_PRESENT = 2;
    const int DIGCF_DEVICEINTERFACE = 0x10;
    static readonly IntPtr INVALID = new IntPtr(-1);

    public class Dev
    {
        public string Path; public string Product = "";
        public ushort Vid; public ushort Pid;
        public int Upage; public int Usage;
        public int InLen; public int OutLen; public int FeatLen;
    }

    public static List<Dev> Enumerate()
    {
        var list = new List<Dev>();
        GUID guid; HidD_GetHidGuid(out guid);
        IntPtr set = SetupDiGetClassDevsW(ref guid, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (set == INVALID) return list;
        try
        {
            int idx = 0;
            while (true)
            {
                var did = new SP_DEVICE_INTERFACE_DATA();
                did.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref guid, idx, ref did)) break;
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

                    var dev = new Dev { Path = path };
                    IntPtr h = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                    if (h == INVALID) continue;
                    try
                    {
                        var attr = new HIDD_ATTRIBUTES();
                        attr.Size = Marshal.SizeOf(typeof(HIDD_ATTRIBUTES));
                        if (HidD_GetAttributes(h, ref attr)) { dev.Vid = attr.VendorID; dev.Pid = attr.ProductID; }
                        IntPtr sbuf = Marshal.AllocHGlobal(512);
                        try { if (HidD_GetProductString(h, sbuf, 512)) dev.Product = Marshal.PtrToStringUni(sbuf); }
                        finally { Marshal.FreeHGlobal(sbuf); }

                        IntPtr pp;
                        if (HidD_GetPreparsedData(h, out pp) && pp != IntPtr.Zero)
                        {
                            try
                            {
                                byte[] caps = new byte[256];
                                if (HidP_GetCaps(pp, caps) == 0x00110000)
                                {
                                    // HIDP_CAPS: Usage 在 0，UsagePage 在 2（别读反）
                                    dev.Usage = BitConverter.ToUInt16(caps, 0);
                                    dev.Upage = BitConverter.ToUInt16(caps, 2);
                                    dev.InLen = BitConverter.ToUInt16(caps, 4);
                                    dev.OutLen = BitConverter.ToUInt16(caps, 6);
                                    dev.FeatLen = BitConverter.ToUInt16(caps, 8);
                                }
                            }
                            finally { HidD_FreePreparsedData(pp); }
                        }
                    }
                    finally { CloseHandle(h); }
                    list.Add(dev);
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
        return list;
    }

    // 只读监听；返回每帧的十六进制字符串（第一帧相对时间 + 出现次数）
    public static List<string> Listen(string path, int inLen, int seconds)
    {
        var lines = new List<string>();
        if (inLen <= 0) inLen = 65;
        // 必须用 FILE_FLAG_OVERLAPPED 打开，否则 ReadFile 传 OVERLAPPED 会直接挂住
        IntPtr h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);
        if (h == INVALID) { lines.Add("OPEN-FAILED err=" + Marshal.GetLastWin32Error()); return lines; }
        try
        {
            var buf = new byte[inLen];
            var count = new Dictionary<string, int>();
            var first = new Dictionary<string, double>();
            var order = new List<string>();
            var sw = System.Diagnostics.Stopwatch.StartNew();
            DateTime end = DateTime.Now.AddSeconds(seconds);
            while (DateTime.Now < end)
            {
                int got = ReadWithTimeout(h, buf, 400);
                if (got > 0)
                {
                    var sb = new StringBuilder();
                    for (int i = 0; i < got; i++) sb.Append(buf[i].ToString("X2")).Append(' ');
                    string key = sb.ToString().TrimEnd();
                    if (!count.ContainsKey(key)) { count[key] = 0; first[key] = sw.Elapsed.TotalSeconds; order.Add(key); }
                    count[key]++;
                }
            }
            foreach (var k in order)
                lines.Add(string.Format("t={0,6:F1}s  x{1,-3}  {2}", first[k], count[k], k));
        }
        catch (Exception ex) { lines.Add("LISTEN-ERROR " + ex.Message); }
        finally { CloseHandle(h); }
        return lines;
    }

    // 实时监听：每出现一种新帧就立刻追加到 outFile，外部可以随时读取进度
    public static string ListenLive(string path, int inLen, int seconds, string outFile)
    {
        if (inLen <= 0) inLen = 65;
        IntPtr h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);
        if (h == INVALID) return "OPEN-FAILED err=" + Marshal.GetLastWin32Error();
        int frames = 0;
        try
        {
            System.IO.File.AppendAllText(outFile, "LISTEN-START " + path + Environment.NewLine);
            var buf = new byte[inLen];
            var seen = new Dictionary<string, int>();
            var sw = System.Diagnostics.Stopwatch.StartNew();
            DateTime end = DateTime.Now.AddSeconds(seconds);
            while (DateTime.Now < end)
            {
                int got = ReadWithTimeout(h, buf, 400);
                if (got <= 0) continue;
                frames++;
                var sb = new StringBuilder();
                for (int i = 0; i < got; i++) sb.Append(buf[i].ToString("X2")).Append(' ');
                string key = sb.ToString().TrimEnd();
                if (!seen.ContainsKey(key)) seen[key] = 0;
                seen[key]++;
                System.IO.File.AppendAllText(outFile, string.Format("t={0,6:F1}s  GET  {1}{2}",
                    sw.Elapsed.TotalSeconds, key, Environment.NewLine));
            }
            System.IO.File.AppendAllText(outFile, "LISTEN-END frames=" + frames + Environment.NewLine);
            return "frames=" + frames + " distinct=" + seen.Count;
        }
        catch (Exception ex) { return "LISTEN-ERROR " + ex.Message; }
        finally { CloseHandle(h); }
    }

    static int ReadWithTimeout(IntPtr h, byte[] buf, int ms)
    {
        IntPtr ev = CreateEventW(IntPtr.Zero, true, false, IntPtr.Zero);
        if (ev == IntPtr.Zero) return -1;
        IntPtr ovPtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(OVERLAPPED)));
        try
        {
            var ov = new OVERLAPPED(); ov.hEvent = ev;
            Marshal.StructureToPtr(ov, ovPtr, false);
            int read;
            bool ok = ReadFile(h, buf, buf.Length, out read, ovPtr);
            if (!ok && Marshal.GetLastWin32Error() != 997) return -1;
            if (WaitForSingleObject(ev, (uint)ms) != 0) { CancelIoEx(h, ovPtr); return 0; }
            int got;
            if (!GetOverlappedResult(h, ovPtr, out got, false)) return -1;
            return got;
        }
        finally { Marshal.FreeHGlobal(ovPtr); CloseHandle(ev); }
    }
}
'@

Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop

$devs = [HidProbe]::Enumerate()
"共 $($devs.Count) 个 HID 接口"
""
foreach ($d in $devs) {
    $tag = if ($Vid -and ('{0:X4}' -f $d.Vid) -ne $Vid) { '   ' } else { ' * ' }
    "{0}{1:X4}:{2:X4}  usagePage=0x{3:X4} usage=0x{4:X4}  in={5} out={6} feat={7}  {8}" -f `
        $tag, $d.Vid, $d.Pid, $d.Upage, $d.Usage, $d.InLen, $d.OutLen, $d.FeatLen, $d.Product
}
""
"=== 只监听厂商自定义接口（usagePage >= 0xFF00），$Seconds 秒 ==="
$vendor = @($devs | Where-Object {
    $_.Upage -ge 0xFF00 -and
    ((-not $Vid) -or (('{0:X4}' -f $_.Vid) -eq $Vid)) -and
    ((-not $Upage) -or ($_.Upage -eq $Upage))
})
if (-not $vendor) { "没有厂商自定义接口 —— 这个接收器可能只暴露标准键鼠接口"; exit }

$report = New-Object System.Collections.ArrayList
foreach ($d in $vendor) {
    $hdr = '--- {0:X4}:{1:X4} usagePage=0x{2:X4} usage=0x{3:X4} in={4} ---' -f $d.Vid, $d.Pid, $d.Upage, $d.Usage, $d.InLen
    [void]$report.Add($hdr)
    [void]$report.Add('    ' + $d.Path)
    if ($OutFile) {
        # 实时模式：逐帧追加写文件，随时可读
        $r = [HidProbe]::ListenLive($d.Path, $d.InLen, $Seconds, $OutFile)
        [void]$report.Add('    live: ' + $r)
    }
    else {
        $lines = [HidProbe]::Listen($d.Path, $d.InLen, $Seconds)
        if (-not $lines -or $lines.Count -eq 0) { [void]$report.Add('    （这段时间没有收到任何报告）') }
        else { foreach ($ln in ($lines | Select-Object -First 40)) { [void]$report.Add('    ' + $ln) } }
    }
}
$report | ForEach-Object { $_ }
