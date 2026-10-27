# MousePowerTray · 蓝牙鼠标电量托盘

![封面](docs/assets/thumb-dark.png)

给 Windows 任务栏加一个**蓝牙鼠标电量图标**。双击就用，零配置、零依赖、免编译。
支持任何实现了标准 BLE 电池服务的输入设备。

> 只读、不装驱动、不联网。只是把 Windows 已经采好的电量画到托盘上。

- 官网 / 宣传页：**https://wangxu722.github.io/MousePowerTray/**
- 下载：[`dist/MousePowerTray.zip`](dist/MousePowerTray.zip)（12.7 KB）

---

## 一个图标就够了

图标是运行时用 GDI+ 现画的，不依赖任何图片素材：竖直胶囊体（鼠标）+ 滚轮 + 按键缝，按电量从下往上填充。

![电量图标](preview/icon-sheet.png)

| 颜色 | 含义 |
| --- | --- |
| 青绿 `#19FAC6` | 40% 以上 |
| 黄 `#FFC036` | 16% – 40% |
| 红 `#F0503C` | 15% 及以下，弹一次气泡 |
| 灰 | 断开 / 无设备，仍保留最后读数 |

---

## 快速开始

1. 解压 `MousePowerTray.zip` 到任意目录
2. 双击 **`MousePowerTray.vbs`**（wscript 静默启动，不闪黑窗）
3. 右键托盘 → 勾「开机自动启动」

右键菜单：显示详情 / 选择设备… / 立即刷新 / 开机自动启动 / 打开日志 / 退出。

配置与日志在 `%LOCALAPPDATA%\MousePowerTray\`，不写程序目录。

---

## 原理

```
鼠标 ──BLE──▶ GATT 0x180F ──▶ 0x2A19 ──▶ Windows 缓存 ──▶ DEVPKEY_Bluetooth_Battery ──▶ 托盘
              标准电池服务      电量 uint8     系统自己采        只读，无需抓包            GDI+ 现画
```

不逆向任何厂商协议。Windows 自己已经在订阅标准 BLE 电池服务并把值缓存进设备属性，
本工具只是把那个数字读出来画在托盘上 —— 所以换品牌不用改一行代码。

### 三个工程决定

1. **探测放后台 Runspace。** `Get-PnpDeviceProperty` 单次 1.1s、`Get-CimInstance` 0.8s，
   同步跑会把托盘菜单卡出明显迟滞。UI 线程只做 1 秒一跳的调度与收结果。
2. **图标走内存 ICO（PNG 载荷）。** `Icon.FromHandle` 每换一次图标漏一个 HICON，
   跑几天能耗光 GDI 句柄；用流构造的 `Icon` 在 `Dispose()` 时是真释放。
3. **在线判定看 HID 子节点是否存在**，不看电量时间戳 —— 设备断开时节点立刻消失，比等超时可靠。

---

## 边界（说清楚做不到什么）

| 支持 | 不支持 |
| --- | --- |
| 标准 BLE 电池服务的输入设备 | **2.4G 接收器** —— 厂商私有协议，一家一套 |
| 鼠标 / 键盘 / 部分手柄，多台可切换 | **纯经典蓝牙耳机** —— 电量只在 HFP 通道里，不进系统 |
| 断开重连自动识别 | **手环** —— 私有服务 + 需要 auth key |

精度就是 1%（BLE 的 `0x2A19` 是一个 uint8）；刷新节奏由设备上报决定，
所以详情浮层里给了「数据更新」时间 —— 那个数字不变，往往只是电量没变。

---

## 宣传物料

同一套内容的两种排版，都是 16:9 三页：

| 物料 | 文件 |
| --- | --- |
| 宣传册 · 终端诊断卡（深色） | [`docs/pdf/MousePowerTray-terminal-dark.pdf`](docs/pdf/MousePowerTray-terminal-dark.pdf) |
| 宣传册 · 点阵打印版（浅色） | [`docs/pdf/MousePowerTray-paper-terminal.pdf`](docs/pdf/MousePowerTray-paper-terminal.pdf) |
| 24 秒宣传片（1280×720 / 60fps） | [`docs/video/MousePowerTray-promo.mp4`](docs/video/MousePowerTray-promo.mp4) |
| 镜头表 | [`docs/video/镜头表.md`](docs/video/镜头表.md) |

视频是**逐帧捕获**的，不是屏幕录像：Playwright 驱动本机 Edge，按 1/60 秒推进 GSAP 时间轴逐帧截图，
再交给 ffmpeg 编码，所以没有掉帧和时间抖动。

```bash
# 重新出片
npm i playwright-core ffmpeg-static
NODE_PATH=./node_modules node docs/video/capture.js
./node_modules/ffmpeg-static/ffmpeg.exe -framerate 60 -i docs/video/frames/%05d.png \
  -c:v libx264 -crf 20 -pix_fmt yuv420p docs/video/MousePowerTray-promo.mp4
```

---

## 仓库结构

```
MousePowerTray/
├─ MousePowerTray.vbs / .cmd      启动器（wscript 静默 / 备用）
├─ src/MousePowerTray.ps1         全部逻辑，单文件 PowerShell 5.1
├─ dist/MousePowerTray.zip        分发包（含使用说明）
├─ docs/                          GitHub Pages 站点
│  ├─ index.html                  宣传页
│  ├─ deck-dark.html              宣传册源文件（深色）
│  ├─ deck-paper.html             宣传册源文件（浅色）
│  ├─ pdf/                        导出的 PDF
│  ├─ video/                      宣传片播放器 + MP4 + 镜头表 + 捕获脚本
│  └─ download/                   站点上的下载包
├─ preview/icon-sheet.png         图标预览（自检输出）
└─ reference/InphicBatteryTray/   参考项目克隆，仅作对照
```

自检（不开界面，扫描一次并输出图标预览）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\MousePowerTray.ps1 -SelfTest
```

---

## 致谢

思路起点是 [Tan-TanZi/InphicBatteryTray](https://github.com/Tan-TanZi/InphicBatteryTray) —— 它用
`hid.dll` 直接监听英菲克鼠标的私有 HID 报告（IN10 被动收 5 字节帧、IN9 主动查 Feature Report），
把"托盘即仪表"这套交互做得很完整。本项目沿用了它的设计哲学（只读、超时判离线、图标本身就是仪表），
但因为目标设备换成标准 BLE HID，数据源和实现是完全独立的一条路。

宣传物料遵循开源社区 **花叔（alchaincyf）** 的 `huashu-design` 与 `huashu-motion` 规范。

MIT License.
