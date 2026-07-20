[CmdletBinding()]
param(
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')]
    [string]$Optimize = 'ReleaseSmall'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content (Join-Path $root '.toolchain-version') -Raw).Trim()
$zig = Join-Path $root ".toolchains\zig-canonical\zig-x86_64-windows-$version\zig.exe"
$source = Join-Path $root 'src\legacy\i686'
$build = Join-Path $root 'build\legacy-i686'
$output = Join-Path $root 'zig-out\legacy\i686'
New-Item -ItemType Directory -Force -Path $build, $output | Out-Null

$object = Join-Path $build 'entry.o'
$elf = Join-Path $output 'ZIGOS386.ELF'
$binary = Join-Path $output 'ZIGOS386.BIN'
$bootSector = Join-Path $output 'BOOTSECT.BIN'
$stage1 = Join-Path $output 'STAGE1.BIN'
$fatVolume = Join-Path $output 'FAT12VOL.BIN'
$diskImage = Join-Path $output 'ZIGOS386.IMG'

Write-Host '[1/10] Checking i686 source formatting'
& $zig fmt --check (Join-Path $source 'kernel.zig')
if ($LASTEXITCODE -ne 0) { throw 'i686 formatting check failed.' }

Write-Host '[2/10] Assembling ELF32 entry'
& nasm -f elf32 (Join-Path $source 'entry.asm') -o $object
if ($LASTEXITCODE -ne 0) { throw 'i686 entry assembly failed.' }

Write-Host '[3/10] Linking freestanding i686 ELF'
$args = @(
    'build-exe', (Join-Path $source 'kernel.zig'), $object,
    '-target', 'x86-freestanding-none', '-mcpu', 'i686',
    '-O', $Optimize, '-fno-entry', '-fstrip',
    '-fno-omit-frame-pointer', '-fno-stack-check', '-fno-stack-protector',
    '-T', (Join-Path $source 'linker.ld'), "-femit-bin=$elf"
)
& $zig @args
if ($LASTEXITCODE -ne 0) { throw 'i686 ELF link failed.' }

Write-Host '[4/10] Extracting raw kernel'
& $zig objcopy --output-target=binary $elf $binary
if ($LASTEXITCODE -ne 0) { throw 'i686 raw extraction failed.' }

Write-Host '[5/10] Verifying legacy kernel contracts'
& (Join-Path $PSScriptRoot 'verify-legacy-i686.ps1') -ElfPath $elf -BinaryPath $binary
$kernelBytes = [IO.File]::ReadAllBytes($binary)
$kernelSectors = [int][Math]::Ceiling($kernelBytes.Length / 512.0)
if ($kernelSectors -lt 1 -or $kernelSectors -gt 55) {
    throw "Kernel sector count overlaps the FAT12 partition or is invalid: $kernelSectors"
}

Write-Host "[6/10] Assembling the 8-sector stage1 for $kernelSectors kernel sector(s)"
& nasm -f bin "-DKERNEL_SECTORS=$kernelSectors" "-DKERNEL_BYTES=$($kernelBytes.Length)" (Join-Path $source 'stage1.asm') -o $stage1
if ($LASTEXITCODE -ne 0) { throw 'BIOS stage1 assembly failed.' }

Write-Host '[7/10] Assembling the 512-byte BIOS stage0'
& nasm -f bin (Join-Path $source 'boot_sector.asm') -o $bootSector
if ($LASTEXITCODE -ne 0) { throw 'BIOS boot-sector assembly failed.' }

Write-Host '[8/10] Generating deterministic FAT12 data volume'
$python = Get-Command python -ErrorAction Stop | Select-Object -ExpandProperty Source
& $python (Join-Path $PSScriptRoot 'create-legacy-fat12.py') --output $fatVolume
if ($LASTEXITCODE -ne 0) { throw 'FAT12 volume generation failed.' }
$fatBytes = [IO.File]::ReadAllBytes($fatVolume)
if ($fatBytes.Length -ne 1474560) { throw "FAT12 volume size is invalid: $($fatBytes.Length)" }

Write-Host '[9/10] Creating partitioned stage0/stage1/kernel/FAT12 disk layout'
$imageBytes = New-Object byte[] (2 * 1024 * 1024)
$bootBytes = [IO.File]::ReadAllBytes($bootSector)
$stage1Bytes = [IO.File]::ReadAllBytes($stage1)
[Array]::Copy($bootBytes, 0, $imageBytes, 0, $bootBytes.Length)
[Array]::Copy($stage1Bytes, 0, $imageBytes, 512, $stage1Bytes.Length)
[Array]::Copy($kernelBytes, 0, $imageBytes, 9 * 512, $kernelBytes.Length)
[Array]::Copy($fatBytes, 0, $imageBytes, 64 * 512, $fatBytes.Length)

$partition = 446
$imageBytes[$partition + 0] = 0x00
$imageBytes[$partition + 1] = 0xFE
$imageBytes[$partition + 2] = 0xFF
$imageBytes[$partition + 3] = 0xFF
$imageBytes[$partition + 4] = 0x01
$imageBytes[$partition + 5] = 0xFE
$imageBytes[$partition + 6] = 0xFF
$imageBytes[$partition + 7] = 0xFF
[BitConverter]::GetBytes([uint32]64).CopyTo($imageBytes, $partition + 8)
[BitConverter]::GetBytes([uint32]2880).CopyTo($imageBytes, $partition + 12)
[IO.File]::WriteAllBytes($diskImage, $imageBytes)

Write-Host '[10/10] Verifying complete legacy BIOS/FAT12 image'
& (Join-Path $PSScriptRoot 'verify-legacy-bios.ps1') -BootSectorPath $bootSector -Stage1Path $stage1 -KernelPath $binary -FatVolumePath $fatVolume -DiskImagePath $diskImage
