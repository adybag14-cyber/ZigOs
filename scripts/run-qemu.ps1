[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$efiRoot = Join-Path $repoRoot 'zig-out'
$buildDir = Join-Path $repoRoot 'build'

if (-not (Test-Path (Join-Path $efiRoot 'EFI\BOOT\BOOTX64.EFI'))) {
    & (Join-Path $PSScriptRoot 'build.ps1')
}

$qemuCandidates = @(
    (Get-Command qemu-system-x86_64 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    'C:\Program Files\qemu\qemu-system-x86_64.exe'
) | Where-Object { $_ -and (Test-Path $_) }
$qemu = $qemuCandidates | Select-Object -First 1
if (-not $qemu) {
    throw 'qemu-system-x86_64 was not found. Install QEMU, then run this script again.'
}

$shareDir = Join-Path (Split-Path -Parent $qemu) 'share'
$codeSource = @(
    (Join-Path $shareDir 'edk2-x86_64-code.fd'),
    (Join-Path $shareDir 'edk2-x86_64-secure-code.fd'),
    (Join-Path $shareDir 'OVMF_CODE.fd')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
$varsSource = @(
    (Join-Path $shareDir 'edk2-i386-vars.fd'),
    (Join-Path $shareDir 'OVMF_VARS.fd')
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $codeSource -or -not $varsSource) {
    throw 'No compatible split OVMF/EDK2 code and vars images were found.'
}

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$codeImage = Join-Path $buildDir 'ovmf-code.fd'
$varsImage = Join-Path $buildDir 'ovmf-vars.fd'
Copy-Item $codeSource $codeImage -Force
Copy-Item $varsSource $varsImage -Force

$fatPath = $efiRoot.Replace('\', '/')
$codePath = $codeImage.Replace('\', '/')
$varsPath = $varsImage.Replace('\', '/')

& $qemu `
    -machine q35 `
    -m 256M `
    -cpu max `
    -smp 4 `
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$codePath" `
    -drive "if=pflash,format=raw,unit=1,file=$varsPath" `
    -drive "format=raw,file=fat:rw:$fatPath" `
    -global isa-debugcon.iobase=0xe9
