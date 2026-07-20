[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$BootSectorPath,
    [Parameter(Mandatory)] [string]$Stage1Path,
    [Parameter(Mandatory)] [string]$KernelPath,
    [Parameter(Mandatory)] [string]$DiskImagePath
)

$ErrorActionPreference = 'Stop'
$boot = [IO.File]::ReadAllBytes((Resolve-Path $BootSectorPath))
$stage1 = [IO.File]::ReadAllBytes((Resolve-Path $Stage1Path))
$kernel = [IO.File]::ReadAllBytes((Resolve-Path $KernelPath))
$imagePath = (Resolve-Path $DiskImagePath).Path
$image = [IO.File]::ReadAllBytes($imagePath)

if ($boot.Length -ne 512) { throw "BIOS stage0 must be exactly 512 bytes; got $($boot.Length)." }
if ($boot[510] -ne 0x55 -or $boot[511] -ne 0xAA) { throw 'BIOS stage0 is missing the 0x55AA signature.' }
if ($stage1.Length -ne 4096) { throw "BIOS stage1 must be exactly 4096 bytes; got $($stage1.Length)." }
if ($kernel.Length -le 0 -or $kernel.Length -gt 65024) { throw "Kernel payload size is invalid: $($kernel.Length)." }
if ($image.Length -ne 1048576) { throw "Legacy disk image must be exactly 1 MiB; got $($image.Length)." }

$stage0Image = [byte[]]$image[0..511]
$stage1Image = [byte[]]$image[512..4607]
$kernelStart = 9 * 512
$kernelEnd = $kernelStart + $kernel.Length - 1
$kernelImage = [byte[]]$image[$kernelStart..$kernelEnd]
if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$boot, $stage0Image)) { throw 'Stage0 image bytes differ.' }
if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$stage1, $stage1Image)) { throw 'Stage1 image bytes differ.' }
if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$kernel, $kernelImage)) { throw 'Kernel image bytes differ.' }

$kernelSectors = [int][Math]::Ceiling($kernel.Length / 512.0)
Write-Host "Verified legacy BIOS image: $imagePath"
Write-Host '  stage0:       512 bytes, signature 0x55AA'
Write-Host '  stage1:       4096 bytes, LBA 1..8, address 0x00008000'
Write-Host "  kernel:       $($kernel.Length) bytes, $kernelSectors sector(s), LBA 9, address 0x00010000"
Write-Host "  image size:   $($image.Length) bytes"
Write-Host "  image sha256: $((Get-FileHash $imagePath -Algorithm SHA256).Hash)"
