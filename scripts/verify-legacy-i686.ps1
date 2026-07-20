[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ElfPath,
    [Parameter(Mandatory)]
    [string]$BinaryPath
)

$ErrorActionPreference = 'Stop'
$elf = [IO.File]::ReadAllBytes((Resolve-Path $ElfPath))
if ($elf.Length -lt 52) { throw "ELF32 image is truncated: $($elf.Length) bytes." }
if ($elf[0] -ne 0x7F -or $elf[1] -ne 0x45 -or $elf[2] -ne 0x4C -or $elf[3] -ne 0x46) {
    throw 'Legacy kernel does not contain an ELF signature.'
}
if ($elf[4] -ne 1) { throw "Legacy kernel is not ELF32; class is $($elf[4])." }
if ($elf[5] -ne 1) { throw "Legacy kernel is not little-endian; data encoding is $($elf[5])." }
if ([BitConverter]::ToUInt16($elf, 16) -ne 2) { throw 'Legacy kernel is not an executable ELF image.' }
if ([BitConverter]::ToUInt16($elf, 18) -ne 3) { throw 'Legacy kernel machine is not Intel 80386.' }
$entry = [BitConverter]::ToUInt32($elf, 24)
if ($entry -ne 0x00010000) { throw ('Legacy kernel entry must be 0x00010000; got 0x{0:X8}.' -f $entry) }

$binary = Get-Item (Resolve-Path $BinaryPath)
if ($binary.Length -le 0) { throw 'Legacy raw kernel is empty.' }
if ($binary.Length -gt 65024) {
    throw "Legacy raw kernel exceeds the initial 127-sector BIOS loader ceiling: $($binary.Length) bytes."
}
$hash = (Get-FileHash $binary.FullName -Algorithm SHA256).Hash

Write-Host "Verified legacy i686 kernel: $($binary.FullName)"
Write-Host "  ELF class:  32-bit"
Write-Host "  machine:    Intel 80386 (3)"
Write-Host ('  entry:      0x{0:X8}' -f $entry)
Write-Host "  raw size:   $($binary.Length) bytes"
Write-Host "  raw sha256: $hash"
