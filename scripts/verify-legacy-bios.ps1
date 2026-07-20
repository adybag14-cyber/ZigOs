[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$BootSectorPath,
    [Parameter(Mandatory)] [string]$Stage1Path,
    [Parameter(Mandatory)] [string]$KernelPath,
    [Parameter(Mandatory)] [string]$FatVolumePath,
    [Parameter(Mandatory)] [string]$DiskImagePath
)

$ErrorActionPreference = 'Stop'
$boot = [IO.File]::ReadAllBytes((Resolve-Path $BootSectorPath))
$stage1 = [IO.File]::ReadAllBytes((Resolve-Path $Stage1Path))
$kernel = [IO.File]::ReadAllBytes((Resolve-Path $KernelPath))
$fatVolume = [IO.File]::ReadAllBytes((Resolve-Path $FatVolumePath))
$imagePath = (Resolve-Path $DiskImagePath).Path
$image = [IO.File]::ReadAllBytes($imagePath)

if ($boot.Length -ne 512) { throw "BIOS stage0 must be exactly 512 bytes; got $($boot.Length)." }
if ($boot[510] -ne 0x55 -or $boot[511] -ne 0xAA) { throw 'BIOS stage0 is missing the 0x55AA signature.' }
if ($stage1.Length -ne 4096) { throw "BIOS stage1 must be exactly 4096 bytes; got $($stage1.Length)." }
if ($kernel.Length -le 0 -or $kernel.Length -gt (247 * 512)) { throw "Kernel payload size is invalid: $($kernel.Length)." }
if ($fatVolume.Length -ne 1474560) { throw "FAT12 volume must be exactly 1.44 MiB; got $($fatVolume.Length)." }
if ($image.Length -ne 2097152) { throw "Legacy disk image must be exactly 2 MiB; got $($image.Length)." }

if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$boot[0..445], [byte[]]$image[0..445])) { throw 'Stage0 boot-code bytes differ.' }
if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$boot[462..509], [byte[]]$image[462..509])) { throw 'Stage0 post-partition bytes differ.' }
if ($image[510] -ne 0x55 -or $image[511] -ne 0xAA) { throw 'Disk MBR signature differs.' }

$stage1Image = [byte[]]$image[512..4607]
$kernelStart = 9 * 512
$kernelEnd = $kernelStart + $kernel.Length - 1
$kernelImage = [byte[]]$image[$kernelStart..$kernelEnd]
$fatStart = 256 * 512
$fatEnd = $fatStart + $fatVolume.Length - 1
$fatImage = [byte[]]$image[$fatStart..$fatEnd]
if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$stage1, $stage1Image)) { throw 'Stage1 image bytes differ.' }
if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$kernel, $kernelImage)) { throw 'Kernel image bytes differ.' }
if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$fatVolume, $fatImage)) { throw 'FAT12 image bytes differ.' }

$partition = 446
if ($image[$partition + 4] -ne 0x01) { throw 'The first MBR partition is not FAT12 type 0x01.' }
if ([BitConverter]::ToUInt32($image, $partition + 8) -ne 256) { throw 'The FAT12 partition does not start at LBA 256.' }
if ([BitConverter]::ToUInt32($image, $partition + 12) -ne 2880) { throw 'The FAT12 partition length is not 2,880 sectors.' }

if ($fatVolume[510] -ne 0x55 -or $fatVolume[511] -ne 0xAA) { throw 'FAT12 boot sector signature is invalid.' }
if ([BitConverter]::ToUInt16($fatVolume, 11) -ne 512) { throw 'FAT12 bytes-per-sector is invalid.' }
if ($fatVolume[13] -ne 1) { throw 'FAT12 sectors-per-cluster is invalid.' }
if ([BitConverter]::ToUInt16($fatVolume, 14) -ne 1) { throw 'FAT12 reserved-sector count is invalid.' }
if ($fatVolume[16] -ne 2) { throw 'FAT12 copy count is invalid.' }
if ([BitConverter]::ToUInt16($fatVolume, 17) -ne 224) { throw 'FAT12 root-entry count is invalid.' }
if ([BitConverter]::ToUInt16($fatVolume, 19) -ne 2880) { throw 'FAT12 total-sector count is invalid.' }
if ([BitConverter]::ToUInt16($fatVolume, 22) -ne 9) { throw 'FAT12 sectors-per-FAT is invalid.' }
if ([BitConverter]::ToUInt32($fatVolume, 28) -ne 256) { throw 'FAT12 hidden-sector count is invalid.' }

$fat1 = [byte[]]$fatVolume[(1 * 512)..((1 + 9) * 512 - 1)]
$fat2 = [byte[]]$fatVolume[(10 * 512)..((10 + 9) * 512 - 1)]
if (-not [Linq.Enumerable]::SequenceEqual($fat1, $fat2)) { throw 'FAT12 copies differ.' }
if ($fat1[0] -ne 0xF0 -or $fat1[1] -ne 0xFF -or $fat1[2] -ne 0xFF) { throw 'FAT12 media/reserved entries are invalid.' }
$cluster2 = $fat1[3] -bor (($fat1[4] -band 0x0F) -shl 8)
if ($cluster2 -ne 0x0FFF) { throw ('FAT12 cluster 2 is not end-of-chain: 0x{0:X3}' -f $cluster2) }
$cluster3 = ((([int]$fat1[4]) -shr 4) -bor (([int]$fat1[5]) -shl 4)) -band 0x0FFF
if ($cluster3 -ne 0x0FFF) { throw ('FAT12 cluster 3 is not end-of-chain: 0x{0:X3}' -f $cluster3) }
$cluster4 = (([int]$fat1[6]) -bor ((([int]$fat1[7]) -band 0x0F) -shl 8)) -band 0x0FFF
if ($cluster4 -ne 0x0FFF) { throw ('FAT12 cluster 4 is not end-of-chain: 0x{0:X3}' -f $cluster4) }

$rootOffset = 19 * 512
$name = [Text.Encoding]::ASCII.GetString($fatVolume, $rootOffset, 11)
if ($name -ne 'HELLO   TXT') { throw "Unexpected FAT12 root name: '$name'" }
if ($fatVolume[$rootOffset + 11] -ne 0x20) { throw 'HELLO.TXT does not have the archive attribute.' }
if ([BitConverter]::ToUInt16($fatVolume, $rootOffset + 26) -ne 2) { throw 'HELLO.TXT does not begin at cluster 2.' }
$fileLength = [BitConverter]::ToUInt32($fatVolume, $rootOffset + 28)
$expected = [Text.Encoding]::ASCII.GetBytes("ZigOs legacy FAT12 filesystem is online.`r`nLoaded through ATA PIO by the i686 kernel.`r`n")
if ($fileLength -ne $expected.Length) { throw 'HELLO.TXT length is invalid.' }
$fileBytes = [byte[]]$fatVolume[(33 * 512)..(33 * 512 + $fileLength - 1)]
if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$expected, $fileBytes)) { throw 'HELLO.TXT content differs.' }

$initRoot = $rootOffset + 32
$initName = [Text.Encoding]::ASCII.GetString($fatVolume, $initRoot, 11)
if ($initName -ne 'INIT    ELF') { throw "Unexpected second FAT12 root name: '$initName'" }
if ($fatVolume[$initRoot + 11] -ne 0x20) { throw 'INIT.ELF does not have the archive attribute.' }
if ([BitConverter]::ToUInt16($fatVolume, $initRoot + 26) -ne 3) { throw 'INIT.ELF does not begin at cluster 3.' }
$initLength = [BitConverter]::ToUInt32($fatVolume, $initRoot + 28)
if ($initLength -le 256 -or $initLength -gt 512) { throw "INIT.ELF length is invalid: $initLength" }
$initOffset = 34 * 512
$init = [byte[]]$fatVolume[$initOffset..($initOffset + $initLength - 1)]
if ($init[0] -ne 0x7F -or $init[1] -ne 0x45 -or $init[2] -ne 0x4C -or $init[3] -ne 0x46) { throw 'INIT.ELF magic is invalid.' }
if ($init[4] -ne 1 -or $init[5] -ne 1 -or $init[6] -ne 1) { throw 'INIT.ELF class/data/version is invalid.' }
if ([BitConverter]::ToUInt16($init, 16) -ne 2 -or [BitConverter]::ToUInt16($init, 18) -ne 3) { throw 'INIT.ELF type or machine is invalid.' }
if ([BitConverter]::ToUInt32($init, 24) -ne 0x00400000) { throw 'INIT.ELF entry is invalid.' }
if ([BitConverter]::ToUInt32($init, 28) -ne 52 -or [BitConverter]::ToUInt16($init, 42) -ne 32 -or [BitConverter]::ToUInt16($init, 44) -ne 1) { throw 'INIT.ELF program-header geometry is invalid.' }
if ([BitConverter]::ToUInt32($init, 52) -ne 1 -or [BitConverter]::ToUInt32($init, 56) -ne 0x100 -or [BitConverter]::ToUInt32($init, 60) -ne 0x00400000) { throw 'INIT.ELF PT_LOAD identity is invalid.' }
if ([BitConverter]::ToUInt32($init, 72) -ne 0x200 -or [BitConverter]::ToUInt32($init, 76) -ne 5) { throw 'INIT.ELF memory size or flags are invalid.' }

$catRoot = $rootOffset + 64
$catName = [Text.Encoding]::ASCII.GetString($fatVolume, $catRoot, 11)
if ($catName -ne 'CAT     ELF') { throw "Unexpected third FAT12 root name: '$catName'" }
if ($fatVolume[$catRoot + 11] -ne 0x20) { throw 'CAT.ELF does not have the archive attribute.' }
if ([BitConverter]::ToUInt16($fatVolume, $catRoot + 26) -ne 4) { throw 'CAT.ELF does not begin at cluster 4.' }
$catLength = [BitConverter]::ToUInt32($fatVolume, $catRoot + 28)
if ($catLength -ne 510) { throw "CAT.ELF length is invalid: $catLength" }
$catOffset = 35 * 512
$cat = [byte[]]$fatVolume[$catOffset..($catOffset + $catLength - 1)]
if ($cat[0] -ne 0x7F -or $cat[1] -ne 0x45 -or $cat[2] -ne 0x4C -or $cat[3] -ne 0x46) { throw 'CAT.ELF magic is invalid.' }
if ($cat[4] -ne 1 -or $cat[5] -ne 1 -or $cat[6] -ne 1) { throw 'CAT.ELF class/data/version is invalid.' }
if ([BitConverter]::ToUInt16($cat, 16) -ne 2 -or [BitConverter]::ToUInt16($cat, 18) -ne 3) { throw 'CAT.ELF type or machine is invalid.' }
if ([BitConverter]::ToUInt32($cat, 24) -ne 0x00400000) { throw 'CAT.ELF entry is invalid.' }
if ([BitConverter]::ToUInt32($cat, 28) -ne 52 -or [BitConverter]::ToUInt16($cat, 42) -ne 32 -or [BitConverter]::ToUInt16($cat, 44) -ne 1) { throw 'CAT.ELF program-header geometry is invalid.' }
if ([BitConverter]::ToUInt32($cat, 52) -ne 1 -or [BitConverter]::ToUInt32($cat, 56) -ne 0x100 -or [BitConverter]::ToUInt32($cat, 60) -ne 0x00400000) { throw 'CAT.ELF PT_LOAD identity is invalid.' }
if ([BitConverter]::ToUInt32($cat, 68) -ne 0xFE -or [BitConverter]::ToUInt32($cat, 72) -ne 0x200 -or [BitConverter]::ToUInt32($cat, 76) -ne 5) { throw 'CAT.ELF segment geometry or flags are invalid.' }
$nameBytes = [Text.Encoding]::ASCII.GetString($cat, 0x100 + 0x90, 11)
if ($nameBytes -ne 'HELLO   TXT') { throw 'CAT.ELF embedded FAT name is invalid.' }

$kernelSectors = [int][Math]::Ceiling($kernel.Length / 512.0)

$paddedKernel = New-Object byte[] ($kernelSectors * 512)
[Array]::Copy($kernel, $paddedKernel, $kernel.Length)
$kernelChecksum = 0
for ($offset = 0; $offset -lt $paddedKernel.Length; $offset += 2) {
    $word = [int]$paddedKernel[$offset] -bor (([int]$paddedKernel[$offset + 1]) -shl 8)
    $kernelChecksum = ($kernelChecksum + $word) -band 0xFFFF
}
$kernelEndLba = 9 + $kernelSectors - 1
if ($kernelEndLba -ge 256) { throw "Kernel overlaps FAT12 partition at LBA256." }
for ($offset = (9 + $kernelSectors) * 512; $offset -lt 256 * 512; $offset++) {
    if ($image[$offset] -ne 0) { throw "Non-zero byte found in protected kernel/FAT gap at image offset $offset." }
}
Write-Host "Verified legacy BIOS/FAT12 image: $imagePath"
Write-Host '  stage0:       512 bytes, signature 0x55AA, partition type 0x01'
Write-Host '  stage1:       4096 bytes, LBA 1..8, address 0x00008000'
Write-Host "  kernel:       $($kernel.Length) bytes, $kernelSectors sector(s), LBA 9..$kernelEndLba, checksum16 0x$('{0:X4}' -f $kernelChecksum), address 0x00010000"
Write-Host "  FAT12:        LBA 256, 2880 sectors, HELLO.TXT cluster 2, INIT.ELF cluster 3 ($initLength bytes), CAT.ELF cluster 4 ($catLength bytes)"
Write-Host "  image size:   $($image.Length) bytes"
Write-Host "  image sha256: $((Get-FileHash $imagePath -Algorithm SHA256).Hash)"
