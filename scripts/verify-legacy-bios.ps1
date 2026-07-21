[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$BootSectorPath,
    [Parameter(Mandatory)] [string]$Stage1Path,
    [Parameter(Mandatory)] [string]$KernelPath,
    [Parameter(Mandatory)] [string]$FatVolumePath,
    [Parameter(Mandatory)] [string]$DiskImagePath
)

$ErrorActionPreference = 'Stop'
$python = Get-Command python -ErrorAction Stop | Select-Object -ExpandProperty Source
$verifier = Join-Path $PSScriptRoot 'verify-legacy-bios.py'
& $python $verifier `
    --boot $BootSectorPath `
    --stage1 $Stage1Path `
    --kernel $KernelPath `
    --fat $FatVolumePath `
    --image $DiskImagePath
if ($LASTEXITCODE -ne 0) { throw 'Capstone 11 legacy BIOS/FAT12 image verification failed.' }
