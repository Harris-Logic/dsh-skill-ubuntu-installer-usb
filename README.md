# DSH skill: make-ubuntu-installer-usb

在 Windows 上把 Ubuntu / Debian 系 ISO 写成一张**能启动、且被证明了写对**的安装 U 盘。

## 为什么需要这个 skill

「用 Rufus 点开始」是一条看似完成、实则没有验证的路径。这台机器上实测踩到三层假象：

| 假象 | 表现 |
|---|---|
| 写缓存假成功 | 6 GB 写入只用 2 秒（2542 MiB/s，USB 2.0 物理不可能），`FlushFileBuffers` 不阻塞，关句柄后数据被丢弃 |
| 设备 not ready | `mountvol X: /p` 之后 `diskpart clean` 报 "device is not ready"，裸盘写被静默丢弃 |
| 卷挂载拒写 | 盘上有卷时裸盘写返回 `ERROR_INVALID_FUNCTION` |

结论：**唯一的成功判据是"断电重连 + 无缓冲冷读 + 块级比对"**，不是"没报错"。

## 内容

```
SKILL.md                       判断 + 配方 + 陷阱 + 验收清单
scripts/make-ubuntu-usb.ps1    参数化脚本（按序列号定位、写穿透、冷校验）
```

SKILL.md 覆盖：

- 怎么从 ISO 扇区判断它能不能裸写（`55AA` + `0xEE` + `EFI PART` + GPT 里有没有 `EF00` 的 ESP + El Torito 双平台）
- 裸写 / Rufus ISO 模式 / Ventoy / 解压 FAT32 的取舍矩阵
- 8 步裸写配方
- 4 个 Windows 陷阱 + 2 个"不是故障"的现象（GPT 记账字段差异、Windows 读不了 ISO9660）
- 8 条验收清单、7 条反模式

## 安装

把本目录复制到 DSH 的用户技能目录：

```powershell
robocopy . "$env:USERPROFILE\.dsh\skills\make-ubuntu-installer-usb" /E
```

## 用法

```powershell
# 不给参数 = 只列出候选 USB 盘并退出，不写任何数据
pwsh -File scripts\make-ubuntu-usb.ps1

# 指定目标盘 + 官方哈希
pwsh -File scripts\make-ubuntu-usb.ps1 `
     -Iso 'F:\ubuntu-24.04.3-desktop-amd64.iso' `
     -ExpectSerial '<你的U盘序列号>' `
     -ExpectSha256 'faabcf33ae53976d2b8207a001ff32f4e5daae013505ac7188c9ea63988f8328'
```

`-ExpectSerial` 是唯一必填项；`-ExpectModel` / `-ExpectSize` 给了就一起校验；`-ExpectSha256` 不给则跳过哈希校验并告警。

## 实测记录（Ubuntu 24.04.3 desktop amd64 → SanDisk Cruzer Fit 16GB, USB 2.0）

- 写入：6,345,887,744 字节，22 分 34 秒，平均 **4.47 MiB/s**（写穿透，即物理速度）
- 冷校验：1513 个 4 MiB 块，1512 块位级一致；唯一差异块是 GPT 头 3 个记账字段（`headerCRC32` / `backupLBA` / `lastUsable`），由 Windows 按整盘尺寸修正，分区项数组 CRC 不变
- 结构验证：MBR 引导代码 `EB 63 90 90…` 与 ISO 一致、保护性分区项 `0xEE`、ESP 首扇区 `EB 3C 90`+`FAT`+`55AA` 且根目录含 `EFI`
- 该 ISO 的 GPT 布局：`ISO9660 (6046 MiB) + ESP (4.96 MiB, "Appended2") + Gap1` —— 那个 ESP 就是"解压到 FAT32 永远得不到"的东西

## 未覆盖

- Ventoy 多系统盘（只有方案对比，未实机验证 Secure Boot MOK 流程）
- Linux 侧 `dd` 流程（未实测）

未实测的分支不写进正文。
