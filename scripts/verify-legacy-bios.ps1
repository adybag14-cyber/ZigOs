[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BootSectorPath,
    [Parameter(Mandatory)]
    [string]$DiskImagePath
)

$ErrorActionPreference = 'Stop'
$boot = [IO.File]::ReadAllBytes((Resolve-Path $BootSectorPath))
if ($boot.Length -ne 512) { throw "BIOS stage0 must be exactly 512 bytes; got $($boot.Length)." }
if ($boot[510] -ne 0x55 -or $boot[511] -ne 0xAA) { throw 'BIOS stage0 is missing the 0x55AA signature.' }

$image = Get-Item (Resolve-Path $DiskImagePath)
if ($image.Length -ne 1048576) { throw "Legacy disk image must be exactly 1 MiB; got $($image.Length)." }
$stream = [IO.File]::OpenRead($image.FullName)
try {
    $firstSector = New-Object byte[] 512
    if ($stream.Read($firstSector, 0, 512) -ne 512) { throw 'Unable to read the image boot sector.' }
} finally {
    $stream.Dispose()
}
if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$boot, [byte[]]$firstSector)) {
    throw 'The disk image does not begin with the verified BIOS stage0.'
}

Write-Host "Verified legacy BIOS image: $($image.FullName)"
Write-Host '  stage0:     512 bytes'
Write-Host '  signature:  0x55AA'
Write-Host "  image size: $($image.Length) bytes"
Write-Host "  sha256:     $((Get-FileHash $image.FullName -Algorithm SHA256).Hash)"
