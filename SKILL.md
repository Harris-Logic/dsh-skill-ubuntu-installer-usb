---
name: make-ubuntu-installer-usb
description: 在 Windows 上把 Ubuntu / Debian 系 ISO 写成一张**能启动、且被证明了写对**的安装 U 盘。先核官方 SHA256、再按序列号锁定目标盘、用写穿透裸写、断电重连后做无缓冲冷校验。当需要制作 Ubuntu/麒麟安装盘、要判断 Rufus ISO 模式与 DD 裸写该选哪个、遇到"盘显示 0 字节/提示格式化""能进 GRUB 进不了安装器""写完校验哈希对不上"，或怀疑写盘脚本被 Windows 写缓存骗了时使用。
whenToUse: 制作 Linux 安装 U 盘、排查启动盘写入失败、在 Rufus / Ventoy / 裸写之间选方案时。
---

# 写一张能启动、且能被证明写对的 Linux 安装 U 盘

**核心断言：在 Windows 上"写完"不等于"写进去"。**

裸盘写要穿过三层欺骗：写缓存假成功（实测 6 GB 只用 2 秒，2542 MiB/s）、设备卡在 `not ready` 后写入被静默丢弃、卷挂载状态下写入被内核拒绝（`ERROR_INVALID_FUNCTION`）。
唯一可信的结论来自**断电重连之后的无缓冲冷读校验**。

## 何时用

- 要把 Ubuntu / Debian / 麒麟 ISO 做成安装 U 盘
- 启动盘"能进 GRUB 菜单、进不了安装器"（`Unable to find a medium containing a live file system`）
- U 盘在 Windows 里显示 0 字节、或提示"需要格式化"
- 自己写的写盘脚本报告成功，但你怀疑它被缓存骗了
- 要在 Rufus ISO 模式 / Rufus DD / Ventoy / 裸写之间做选择

## 三条原则

1. **先验镜像，再动盘。** ISO 的 SHA256 必须对上官方 `SHA256SUMS`，否则后面全是白费。
2. **盘的身份用序列号认。** 不认盘符、不认盘号（重连后盘号会变，盘符可能被别的盘抢走）；型号 + 序列号 + 容量三重命中才动手。
3. **写用写穿透，验用冷读。** 写句柄必须 `FileOptions::WriteThrough`；校验必须"关闭句柄 → PnP 断电重连 → `NoBuffering` 读"。

## 第一步：判断这个 ISO 能不能裸写

裸写能否双启动，全看镜像扇区里有没有这几样：

```powershell
$fs=[IO.File]::Open($iso,'Open','Read','ReadWrite')
$b=New-Object byte[] 2048; $null=$fs.Read($b,0,2048); $fs.Close()
"MBR 签名       : 0x{0:X2}{1:X2}（需 55AA）" -f $b[510],$b[511]
"MBR 分区项类型 : 0x{0:X2}（0xEE = 保护性 MBR，说明是 GPT 混合镜像）" -f $b[450]
"LBA1          : '" + [Text.Encoding]::ASCII.GetString($b,512,8) + "'（需 'EFI PART'）"
```

| 证据 | 含义 | 缺失后果 |
|---|---|---|
| MBR `55AA` + 引导代码 `EB xx 90` | BIOS 能加载 GRUB | 老机器不启动 |
| MBR 分区项 `0xEE` + LBA1 `EFI PART` | GPT 混合布局 | — |
| GPT 里有 **ESP 分区（type `EF00`）** | UEFI 固件能找到启动文件 | UEFI 不启动 |
| El Torito 同时有 `0x00`(BIOS) 与 `0xEF`(EFI) 平台条目 | 双平台光盘启动 | 单平台 |

> 实测：Ubuntu 24.04.3 desktop ISO 的 GPT 是 `ISO9660 + ESP(4.96 MiB,"Appended2") + Gap1`。
> 那个 4.96 MiB 的 ESP 就是**解压到 FAT32 永远得不到的东西**，也是"必须裸写"的真正理由。
> 注意它最大单文件只有 1.66 GiB —— 所以"因为 4 GB 限制只能裸写"并不成立，**丢掉 BIOS 引导和 ESP 才是**。

## 第二步：三条路线怎么选

| 方案 | 布局 | 盘上可用空间 | 固件识别 | 进安装器 | 适用 |
|---|---|---|---|---|---|
| **裸写 / DD** | GPT：ISO9660 + ESP | 6.3 GB 只读，其余浪费 | 现代机器 100% | **最稳**（就是官方介质） | 专用安装盘、要确定性 |
| **Rufus ISO 模式** | MBR：单 FAT32 | 全盘可用 | 老固件略优 | 偶发 `no medium...` | 想盘上顺便存东西 |
| **Ventoy** | exFAT + 32 MB VTOYEFI | 全盘可用，可放多 ISO | 需处理 Secure Boot(MOK) | 稳 | 多系统工具盘 |
| ~~解压到 FAT32~~ | — | 全盘 | 只 UEFI | — | **不推荐**：丢 BIOS 引导，非官方介质 |

**Rufus 的坑（4.7 实测）**：对"纯保护性 MBR + GPT"这种较新布局，Rufus 不弹 `ISOHYBRID IMAGE DETECTED` 对话框，也就**没有 DD 选项**，只剩 ISO 模式。要位级复刻就只能自己裸写，或用 balenaEtcher / `dd`。

## 第三步：裸写配方

完整脚本：[scripts/make-ubuntu-usb.ps1](scripts/make-ubuntu-usb.ps1)
（也在 `%USERPROFILE%\.dsh\skills\make-ubuntu-installer-usb\scripts\make-ubuntu-usb.ps1`；按序列号定位、写前探测、写后冷校验）

```powershell
# 不给参数 = 只列出候选 USB 盘并退出，不写任何数据（安全的自查方式）
pwsh -File scripts\make-ubuntu-usb.ps1

# 指定目标盘 + 官方哈希后执行
pwsh -File scripts\make-ubuntu-usb.ps1 `
     -Iso 'F:\ubuntu-24.04.3-desktop-amd64.iso' `
     -ExpectSerial '<你的U盘序列号>' `
     -ExpectSha256 'faabcf33ae53976d2b8207a001ff32f4e5daae013505ac7188c9ea63988f8328'
```

`-ExpectSerial` 是唯一必填项；`-ExpectModel` / `-ExpectSize` 给了就一起校验（更安全）；`-ExpectSha256` 不给则跳过哈希校验并告警（不推荐）。

手工步骤：

```powershell
# 1) 验镜像
(Get-FileHash $iso -Algorithm SHA256).Hash.ToLower()   # 必须等于官方 SHA256SUMS

# 2) 按序列号定位目标盘（可移动盘的 Get-Disk TotalSize 常为空，容量从 WMI 取）
$d  = Get-Disk | Where-Object SerialNumber -eq $serial
$sz = (Get-CimInstance Win32_DiskDrive | Where-Object Index -eq $d.Number).Size
if ($d.FriendlyName -ne $model -or $d.BusType -ne 'USB' -or $d.IsSystem) { throw '拒绝' }

# 3) 清空分区表 —— 让盘上没有卷（关键，见陷阱 2/3）
@("select disk $($d.Number)", 'clean') | diskpart
@(Get-Partition -DiskNumber $d.Number).Count      # 必须为 0，否则中止

# 4) 写：写穿透 + 4 MiB 分块
$p   = '\\.\PhysicalDrive' + $d.Number
$dst = New-Object System.IO.FileStream($p,'Open','ReadWrite','ReadWrite',4MB,[IO.FileOptions]::WriteThrough)
# 循环 $dst.Write(...)；最后 $dst.Flush($true)

# 5) 验：关闭句柄 → 断电重连 → 无缓冲读
Disable-PnpDevice -InstanceId $usbstorDisk -Confirm:$false; Start-Sleep 3
Enable-PnpDevice  -InstanceId $usbstorDisk -Confirm:$false; Start-Sleep 6
$rd = New-Object System.IO.FileStream($p,'Open','Read','ReadWrite',4MB,[IO.FileOptions]::NoBuffering)
```

**速度判据**：USB 2.0 盘 **3~7 MiB/s** 才是真的。看到几百 MB/s 或 GB/s 就是缓存，不是写盘。

## 四个 Windows 陷阱（全是实测踩出来的）

1. **写缓存假成功**：普通句柄写 6 GB 只用 2 秒（2542 MiB/s），`FlushFileBuffers` 也拦不住，关闭句柄后数据被丢弃。
   → 必须 `FileOptions::WriteThrough`。

2. **`mountvol X: /p` 之后设备卡在 `not ready`**：随后 `diskpart clean` 报 "device is not ready"、裸盘写被静默丢弃。
   → 不要用 `mountvol` 摘盘符，直接 `diskpart clean`；已经踩了就用 PnP 断电重连恢复。

3. **卷挂载状态下写入被拒**：返回 `ERROR_INVALID_FUNCTION`（"函数不正确"）。
   → 写之前必须让盘上 `Get-Partition` 数量为 0。

4. **PnP 匹配别匹配到卷**：`InstanceId -like "*USBSTOR*<serial>*"` 会命中 `STORAGE\VOLUME\...`，禁用它会搞乱设备状态。
   → 用 `'USBSTOR\DISK*'` + 序列号定位磁盘设备。

另有两个"不是故障"的现象：

- **校验时 GPT 头会有 12 字节差异**：Windows 挂载后按整盘尺寸改写 `headerCRC32`@528、`backupLBA`@544、`lastUsable`@560 并重算 CRC。**分区项数组 CRC 不变 ⇒ 启动链完好**，按"块级比对 + 允许这 12 字节"判定，不要当损坏反复重写。
- **Windows 读不了这个 ISO9660 分区**（显示 0 字节 / 提示格式化）。正常，绝不要点格式化；用 `Remove-PartitionAccessPath -DiskNumber N -PartitionNumber 1 -AccessPath 'H:\'` 摘掉盘符以免误操作。

## 验收清单

- [ ] ISO SHA256 = 官方值；`.disk/info` 里的版本号与文件名一致
- [ ] 目标盘：型号 + 序列号 + 容量三重命中，`BusType=USB`，非系统盘/启动盘
- [ ] `diskpart clean` 成功且 `Get-Partition` 为 0
- [ ] 写入速度是物理速度（3~7 MiB/s 量级）
- [ ] 断电重连后 `NoBuffering` 冷读通过；差异块只含 GPT 记账字段
- [ ] MBR 首字节 = ISO 的引导代码（如 `EB 63 90 90…`）、`55AA`、分区项 `0xEE`
- [ ] ESP 首扇区是合法 FAT（`EB 3C 90` + `FAT` + `55AA`），根目录含 `EFI`
- [ ] 所有盘符已摘除，避免 Windows 弹"格式化"

## 装系统阶段

- 启动菜单键：华硕 F8 / 微星 F11 / 技嘉 F12 / 联想 F12 / 华擎 F11，选带 `UEFI:` 前缀那项
- Ubuntu 带微软签名 shim（`mmx64.efi`），**Secure Boot 不用关**
- 多硬盘机器：安装器里用**手动分区**明确指定目标盘，或干脆先拔掉数据盘数据线（"清除整个磁盘"选错盘 = 数据事故）
- 16 GB 盘裸写会浪费约 8.8 GiB；要"安装盘 + 存文件"两用请改选 Ventoy

## 反模式

- ❌ 不验哈希就开写（中途失败时分不清是盘坏还是镜像坏）
- ❌ 用盘符/盘号定位目标盘（重连后盘号会变）
- ❌ 相信"写完没报错"就是成功（缓存会给你 2.5 GB/s 的假象）
- ❌ 用 `mountvol` 摘盘符来"释放"设备
- ❌ 把 GPT 记账字段差异当成写入损坏
- ❌ 看到 Windows 提示"需要格式化"就点确定（那份 GPT 就是启动链）
- ❌ 笼统承诺裸写"兼容性最好"（老固件对 ISO9660+GPT 的 U 盘识别率确实不如 MBR+FAT32）
