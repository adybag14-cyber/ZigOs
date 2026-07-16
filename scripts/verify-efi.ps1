[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'zig-out\EFI\BOOT\BOOTX64.EFI')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Path)) {
    throw "EFI image not found: $Path"
}

$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $Path))
if ($bytes.Length -lt 256) {
    throw 'EFI image is unexpectedly small.'
}
if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
    throw 'Missing DOS MZ header.'
}

$peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
if ($peOffset -lt 0 -or ($peOffset + 24) -gt $bytes.Length) {
    throw 'Invalid PE header offset.'
}
if ($bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45 -or $bytes[$peOffset + 2] -ne 0 -or $bytes[$peOffset + 3] -ne 0) {
    throw 'Missing PE signature.'
}

$machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
$optionalHeader = $peOffset + 24
$magic = [BitConverter]::ToUInt16($bytes, $optionalHeader)
$subsystem = [BitConverter]::ToUInt16($bytes, $optionalHeader + 68)

if ($machine -ne 0x8664) { throw ('Wrong machine type: 0x{0:X4}' -f $machine) }
if ($magic -ne 0x020B) { throw ('Not PE32+: 0x{0:X4}' -f $magic) }
if ($subsystem -ne 10) { throw "Wrong PE subsystem: $subsystem (expected 10 / EFI application)" }

$hash = (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host ('Verified EFI application: {0}' -f (Resolve-Path $Path))
Write-Host ('  size:       {0} bytes' -f $bytes.Length)
Write-Host ('  machine:    AMD64 (0x8664)')
Write-Host ('  format:     PE32+')
Write-Host ('  subsystem:  EFI application (10)')
Write-Host ('  sha256:     {0}' -f $hash)
