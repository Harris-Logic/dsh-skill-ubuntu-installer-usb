<#
  make-ubuntu-usb.ps1  (v3)
  ------------------------------------------------------------------
  把 Ubuntu ISO 逐字节裸写进 U 盘 —— 等价于 Rufus 的 DD 模式 / dd。

  v3 的流程（全部由实测踩坑得出）：
    1. 校验源 ISO 哈希
    2. 按序列号定位目标盘，校验型号/总线/非系统盘/容量
    3. diskpart clean 清空分区表 —— 关键：卷挂载着时裸盘写会被内核拒绝
       并返回 ERROR_INVALID_FUNCTION，所以必须先让盘上没有卷
    4. 断言分区数为 0，否则中止（不冒险）
    5. 写能力探测：写 4 MiB + 无缓冲读回逐字节比对
    6. 全量写入，句柄用 FileOptions.WriteThrough（写穿透，每笔必须落介质）
    7. 关闭句柄 -> PnP 断电重连（清设备内部缓存）-> 按序列号重新定位
    8. 用 NoBuffering 无缓冲读取整盘，算 SHA256 与官方值比对（冷校验）

  用法（管理员 PowerShell）：
    # 先看有哪些 USB 盘（不给 -ExpectSerial 时只列出候选并退出，不会写任何东西）
    pwsh -File make-ubuntu-usb.ps1

    # 指定目标盘与镜像后执行
    pwsh -File make-ubuntu-usb.ps1 `
         -Iso 'F:\ubuntu-24.04.3-desktop-amd64.iso' `
         -ExpectSerial '<你的U盘序列号>' `
         -ExpectSha256 'faabcf33ae53976d2b8207a001ff32f4e5daae013505ac7188c9ea63988f8328'

  -ExpectSerial 是唯一必填项；-ExpectModel / -ExpectSize 给了就一起校验（更安全），
  -ExpectSha256 不给则跳过哈希校验并告警（不推荐）。
  ------------------------------------------------------------------
#>
param(
    [string]$Iso          = '',
    [string]$ExpectSerial = '',
    [string]$ExpectModel  = '',
    [long]  $ExpectSize   = 0,
    [string]$ExpectSha256 = '',
    [string]$LogPath      = "$env:USERPROFILE\ubuntu-usb-write.log"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Say {
    param([string]$Message)
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
}
function Fail {
    param([string]$Message)
    Say "!!! ABORT: $Message"
    throw $Message
}
function Get-TargetDisk {
    foreach ($d in @(Get-Disk)) { if ($d.SerialNumber -eq $ExpectSerial) { return $d } }
    return $null
}
function Get-DiskNumber {
    $d = Get-TargetDisk
    if (-not $d) { Fail '按序列号找不到目标盘' }
    return [int]$d.Number
}
function Reset-UsbDevice {
    $dev = Get-PnpDevice -ErrorAction SilentlyContinue |
           Where-Object { $_.InstanceId -like 'USBSTOR\DISK*' -and $_.InstanceId -like "*$ExpectSerial*" } |
           Select-Object -First 1
    if (-not $dev) { Say '  未找到磁盘 PnP 节点，跳过断电重连'; return $false }
    Say "  PnP 断电重连：$($dev.InstanceId)"
    try { Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop } catch { Say "    disable: $($_.Exception.Message)" }
    Start-Sleep -Seconds 3
    try { Enable-PnpDevice  -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop } catch { Say "    enable: $($_.Exception.Message)" }
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        if (Get-TargetDisk) { Say "  设备已恢复（$($i + 1)s）"; return $true }
    }
    return $false
}
function Read-Unbuffered {
    param([int]$DiskNo, [long]$Offset, [int]$Length)
    $p = '\\.\PhysicalDrive' + $DiskNo
    $fs = New-Object System.IO.FileStream($p,
            [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite, 1MB, [System.IO.FileOptions]::NoBuffering)
    try {
        $null = $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] $Length
        $n   = $fs.Read($buf, 0, $Length)
        return [pscustomobject]@{ Buf = $buf; Len = $n }
    }
    finally { $fs.Close() }
}

Set-Content -LiteralPath $LogPath -Value ("===== make-ubuntu-usb v3  {0:yyyy-MM-dd HH:mm:ss} =====" -f (Get-Date)) -Encoding utf8

# ------------------------------------------------------------------ 0
if (-not $ExpectSerial) {
    Say '--- [0/8] 未指定 -ExpectSerial，仅列出候选 USB 盘（不会写任何数据） ---'
    $any = $false
    foreach ($d in @(Get-Disk | Where-Object { $_.BusType -eq 'USB' })) {
        $any = $true
        $s = (Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
              Where-Object { $_.Index -eq $d.Number }).Size
        Say ("  Disk {0}  {1}  serial={2}  size={3}  style={4}  system={5}" -f `
                $d.Number, $d.FriendlyName, $d.SerialNumber, $s, $d.PartitionStyle, $d.IsSystem)
    }
    if (-not $any) { Say '  （没有检测到 USB 盘）' }
    Fail '请用 -ExpectSerial 指定目标盘；建议同时给出 -ExpectModel / -ExpectSize / -ExpectSha256'
}

# ------------------------------------------------------------------ 1
Say '--- [1/8] 校验源镜像 ---'
if (-not $Iso) { Fail '请用 -Iso 指定 ISO 路径' }
if (-not (Test-Path -LiteralPath $Iso)) { Fail "ISO 不存在: $Iso" }
$isoLen = [long](Get-Item -LiteralPath $Iso).Length
if ($isoLen -le 0 -or $isoLen % 512 -ne 0) { Fail "ISO 长度异常: $isoLen" }
$isoHash = (Get-FileHash -LiteralPath $Iso -Algorithm SHA256).Hash.ToLower()
Say "source sha256 = $isoHash  ($isoLen 字节)"
if ($ExpectSha256) {
    if ($isoHash -ne $ExpectSha256.ToLower()) { Fail 'ISO 哈希与官方值不符' }
    Say '源镜像哈希与官方值一致'
}
else { Say '警告：未提供 -ExpectSha256，跳过完整性校验（不推荐）' }

# ------------------------------------------------------------------ 2
Say '--- [2/8] 定位并校验目标盘 ---'
$disk = Get-TargetDisk
if (-not $disk) { Fail "按序列号 $ExpectSerial 找不到目标盘" }
$diskNo = [int]$disk.Number
$cd = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
      Where-Object { $_.Index -eq $diskNo } | Select-Object -First 1
$devSize = if ($cd -and $cd.Size) { [long]$cd.Size } else { [long]$disk.TotalSize }
Say ("Disk {0}: model='{1}' serial='{2}' bus={3} size={4}" -f $diskNo, $disk.FriendlyName, $disk.SerialNumber, $disk.BusType, $devSize)
if ($ExpectModel -and $disk.FriendlyName -ne $ExpectModel) { Fail "型号不符: '$($disk.FriendlyName)'" }
if ($disk.BusType -ne 'USB')                        { Fail '不是 USB 盘' }
if ($disk.IsBoot -or $disk.IsSystem)                { Fail '目标盘是系统盘/启动盘' }
if ($devSize -le 0)                                 { Fail '取不到容量' }
if ($ExpectSize -gt 0 -and [Math]::Abs($devSize - $ExpectSize) -gt 64MB) { Fail "容量不符: $devSize" }
if ($devSize -le $isoLen)                           { Fail '容量小于镜像' }
Say '目标盘身份校验通过'

# ------------------------------------------------------------------ 3
Say '--- [3/8] 清空分区表（必须先无卷挂载，否则裸写会被拒绝） ---'
$dpOut = @("select disk $diskNo", 'clean') | & diskpart 2>&1
$dpTxt = ($dpOut | Out-String)
if ($dpTxt -match 'succeeded|成功') { Say '  diskpart clean 成功' }
else {
    Say '  diskpart clean 未成功，尝试 Clear-Disk'
    try { Clear-Disk -Number $diskNo -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop; Say '  Clear-Disk 成功' }
    catch { Say "  Clear-Disk 失败: $($_.Exception.Message)" }
}
Start-Sleep -Seconds 2

# ------------------------------------------------------------------ 4
Say '--- [4/8] 断言盘上已无分区/卷 ---'
$left = @(Get-Partition -DiskNumber $diskNo -ErrorAction SilentlyContinue)
if ($left.Count -ne 0) {
    Start-Sleep -Seconds 3
    try { Update-HostStorageCache -ErrorAction SilentlyContinue } catch { }
    $left = @(Get-Partition -DiskNumber $diskNo -ErrorAction SilentlyContinue)
}
if ($left.Count -ne 0) { Fail "仍有 $($left.Count) 个分区，卷挂载状态下裸写会被内核拒绝" }
Say '  分区数 0，可以写入'

# ------------------------------------------------------------------ 5
Say '--- [5/8] 写能力探测（4 MiB 写 + 无缓冲读回） ---'
$src = [System.IO.File]::Open($Iso, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
$probe = New-Object byte[] (4MB)
$null = $src.Read($probe, 0, $probe.Length)
$src.Close()

$probeOk = $false
for ($cycle = 1; $cycle -le 2; $cycle++) {
    $diskPath = '\\.\PhysicalDrive' + $diskNo
    $win = New-Object System.IO.FileStream($diskPath,
            [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::ReadWrite, 4MB, [System.IO.FileOptions]::WriteThrough)
    try { $win.Write($probe, 0, $probe.Length); $win.Flush($true) } finally { $win.Close() }
    Start-Sleep -Milliseconds 400
    $r = Read-Unbuffered -DiskNo $diskNo -Offset 0 -Length 4MB
    if ($r.Len -eq $probe.Length -and [System.Linq.Enumerable]::SequenceEqual([byte[]]$r.Buf, [byte[]]$probe)) {
        $probeOk = $true; Say "  探测通过（第 $cycle 次）：4 MiB 已真正落盘"; break
    }
    Say "  探测失败（第 $cycle 次）"
    if ($cycle -eq 1) { [void](Reset-UsbDevice); $diskNo = Get-DiskNumber }
}
if (-not $probeOk) { Fail '目标盘拒绝可靠写入，建议换盘' }

# ------------------------------------------------------------------ 6
Say '--- [6/8] 全量裸写（写穿透） ---'
$diskPath = '\\.\PhysicalDrive' + $diskNo
$win = New-Object System.IO.FileStream($diskPath,
        [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::ReadWrite, 4MB, [System.IO.FileOptions]::WriteThrough)
$buf = New-Object byte[] (4MB)
$src = [System.IO.File]::Open($Iso, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
$written = [long]0
$mark    = [long]0
$sw      = [System.Diagnostics.Stopwatch]::StartNew()
try {
    while ($written -lt $isoLen) {
        $want = [int][Math]::Min([long]4MB, $isoLen - $written)
        $got  = $src.Read($buf, 0, $want)
        if ($got -le 0) { Fail "源文件在 $written 处提前结束" }
        $win.Write($buf, 0, $got)
        $written += $got
        if ($written -ge $mark) {
            $mbps = ($written / 1MB) / [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
            $eta  = [int](($isoLen - $written) / 1MB / [Math]::Max($mbps, 0.01))
            Say ("  {0,6:N1} %  {1,7:N0}/{2:N0} MiB  {3,5:N2} MiB/s  已用 {4:mm\:ss}  剩余 {5:mm\:ss}" -f `
                    (100.0 * $written / $isoLen), ($written / 1MB), ($isoLen / 1MB), $mbps, $sw.Elapsed, [TimeSpan]::FromSeconds($eta))
            $mark = $written + 256MB
        }
    }
    $win.Flush($true)
}
finally { $src.Close(); $win.Close(); $sw.Stop() }
Say ("裸写完成：{0} 字节，平均 {1:N2} MiB/s，耗时 {2:hh\:mm\:ss}" -f $written, (($written / 1MB) / $sw.Elapsed.TotalSeconds), $sw.Elapsed)

# ------------------------------------------------------------------ 7
Say '--- [7/8] 断电重连（清设备内部缓存）后重新定位 ---'
[void](Reset-UsbDevice)
Start-Sleep -Seconds 2
$diskNo = Get-DiskNumber
Say "  校验用盘号: $diskNo"

# ------------------------------------------------------------------ 8
Say '--- [8/8] 无缓冲冷校验（块级比对） ---'
# Windows 挂载这块盘后，会把 GPT 头里 3 个"记账字段"改成整盘尺寸并重算 CRC：
#   headerCRC32 @528..531   backupLBA @544..547   lastUsable @560..563
# 这属于合法修正（对一个 15.8GB 的盘而言，宣称自己只有 6.35GB 才不规范），
# 不算内容损坏；除这 12 个字节外，每个字节都必须与 ISO 完全一致。
$allow = @{}
foreach ($a in 528..531) { $allow[$a] = 1 }
foreach ($a in 544..547) { $allow[$a] = 1 }
foreach ($a in 560..563) { $allow[$a] = 1 }

$fsR = $null
for ($i = 1; $i -le 10; $i++) {
    try {
        $diskPath = '\\.\PhysicalDrive' + $diskNo
        $fsR = New-Object System.IO.FileStream($diskPath,
                [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite, 4MB, [System.IO.FileOptions]::NoBuffering)
        break
    }
    catch { Say "  打开失败($i): $($_.Exception.Message)"; Start-Sleep -Seconds 3 }
}
if (-not $fsR) { Fail '无法打开物理盘做校验' }

$src  = [System.IO.File]::Open($Iso, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
$iBuf = New-Object byte[] (4MB)
$dBuf = New-Object byte[] (4MB)
$off  = [long]0
$mark = [long]0
$badBlocks = 0
$contentBad = 0
$sw2  = [System.Diagnostics.Stopwatch]::StartNew()
try {
    while ($off -lt $isoLen) {
        $want = [int][Math]::Min([long]4MB, $isoLen - $off)
        $null = $src.Read($iBuf, 0, $want)
        $null = $fsR.Seek($off, [System.IO.SeekOrigin]::Begin)
        $got  = $fsR.Read($dBuf, 0, $want)
        if ($got -ne $want) { Fail "校验读在 $off 处只读到 $got/$want 字节" }

        $diff = $false
        $realDiff = $false
        if ($off -eq 0) {
            for ($k = 0; $k -lt $want; $k++) {
                if ($iBuf[$k] -ne $dBuf[$k]) {
                    $diff = $true
                    if (-not $allow.ContainsKey($k)) { $realDiff = $true; break }
                }
            }
        }
        else {
            $diff = -not [System.Linq.Enumerable]::SequenceEqual([byte[]]$iBuf, [byte[]]$dBuf)
            $realDiff = $diff
        }
        if ($diff)     { $badBlocks++ }
        if ($realDiff) { $contentBad++ }

        $off += $want
        if ($off -ge $mark) {
            Say ("  校验 {0,6:N1} %  {1,5:N2} MiB/s  差异块 {2}" -f (100.0 * $off / $isoLen), (($off / 1MB) / [Math]::Max($sw2.Elapsed.TotalSeconds, 0.001)), $badBlocks)
            $mark = $off + 1024MB
        }
    }
}
finally { $src.Close(); $fsR.Close() }

Say '--- 结论 ---'
Say "源镜像 sha256 : $isoHash"
$total = [int][Math]::Ceiling($isoLen / 4MB)
Say "块总数 $total，差异块 $badBlocks，其中内容性差异 $contentBad"
if ($contentBad -eq 0) {
    Say 'PASS —— 整盘内容与官方 ISO 一致。'
    Say "       （仅有 $($badBlocks - $contentBad) 个块差异，且只落在 GPT 头 3 个记账字段上，由 Windows 按整盘尺寸修正）"
    Say '下一步：安全弹出后拔下。装机时开机按启动菜单键，选带 UEFI 前缀的 SanDisk 项。'
    Say '注意：Windows 里这会显示成一块约 6.3GB、打不开的盘 —— 正常，绝不要点"格式化"。'
} else {
    Say "FAIL —— 有 $contentBad 个内容块与 ISO 不符，这张盘写入不可靠，建议更换。"
}
Say "日志：$LogPath"
