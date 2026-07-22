[CmdletBinding()]
param(
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')]
    [string]$Optimize = 'ReleaseSmall',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$version = (Get-Content (Join-Path $repoRoot '.toolchain-version') -Raw).Trim()
$zigExe = Join-Path $repoRoot ".toolchains\zig-canonical\zig-x86_64-windows-$version\zig.exe"
$buildDir = Join-Path $repoRoot 'build'
$outputDir = Join-Path $repoRoot 'zig-out\EFI\BOOT'
$asmObject = Join-Path $buildDir 'cpu.obj'
$userPayload = Join-Path $buildDir 'service-user.bin'
$userElf = Join-Path $buildDir 'service-user.elf'
$processPayload = Join-Path $buildDir 'process-user.bin'
$processExecPayload = Join-Path $buildDir 'process-exec.bin'
$processElf = Join-Path $buildDir 'process-user.elf'
$processExecElf = Join-Path $buildDir 'process-exec.elf'
$generatedDir = Join-Path $repoRoot 'src\generated'
$apTrampoline = Join-Path $generatedDir 'ap_trampoline.bin'
$embeddedUserElf = Join-Path $generatedDir 'service_user.elf'
$embeddedProcessElf = Join-Path $generatedDir 'process_user.elf'
$embeddedProcessExecElf = Join-Path $generatedDir 'process_exec.elf'
$efiImage = Join-Path $outputDir 'BOOTX64.EFI'

if ($Clean) {
    Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $repoRoot 'zig-out') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $repoRoot '.zig-cache') -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path $zigExe)) {
    & (Join-Path $PSScriptRoot 'bootstrap-toolchain.ps1')
}
if (-not (Get-Command nasm -ErrorAction SilentlyContinue)) {
    throw 'NASM is required and was not found in PATH.'
}

$actualVersion = (& $zigExe version).Trim()
if ($actualVersion -ne $version) {
    throw "Refusing to build with non-canonical Zig. Expected $version, got $actualVersion."
}

New-Item -ItemType Directory -Force -Path $buildDir, $outputDir, $generatedDir | Out-Null

Write-Host '[1/9] Checking canonical Zig formatting'
& $zigExe fmt --check (Join-Path $repoRoot 'src')
if ($LASTEXITCODE -ne 0) { throw "Canonical Zig formatting check failed with exit code $LASTEXITCODE" }

Write-Host '[2/9] Assembling deterministic x86-64 userspace payload'
& nasm -w+error -f bin (Join-Path $repoRoot 'src\user\service.asm') -o $userPayload
if ($LASTEXITCODE -ne 0) { throw "NASM userspace payload failed with exit code $LASTEXITCODE" }
& python (Join-Path $PSScriptRoot 'create-x86-64-user-elf.py') --payload $userPayload --output $userElf
if ($LASTEXITCODE -ne 0) { throw "ELF64 userspace image generation failed with exit code $LASTEXITCODE" }
& python (Join-Path $PSScriptRoot 'verify-x86-64-user-elf.py') $userElf
if ($LASTEXITCODE -ne 0) { throw "ELF64 userspace image verification failed with exit code $LASTEXITCODE" }
Copy-Item $userElf $embeddedUserElf -Force

Write-Host '[3/9] Assembling deterministic x86-64 multiprocess workloads'
& nasm -w+error -f bin (Join-Path $repoRoot 'src\user\process.asm') -o $processPayload
if ($LASTEXITCODE -ne 0) { throw "NASM main process payload failed with exit code $LASTEXITCODE" }
& nasm -w+error -f bin (Join-Path $repoRoot 'src\user\process-exec.asm') -o $processExecPayload
if ($LASTEXITCODE -ne 0) { throw "NASM exec process payload failed with exit code $LASTEXITCODE" }
& python (Join-Path $PSScriptRoot 'create-x86-64-process-elf.py') --payload $processPayload --output $processElf --kind main
if ($LASTEXITCODE -ne 0) { throw "Main process ELF64 generation failed with exit code $LASTEXITCODE" }
& python (Join-Path $PSScriptRoot 'create-x86-64-process-elf.py') --payload $processExecPayload --output $processExecElf --kind exec
if ($LASTEXITCODE -ne 0) { throw "Exec process ELF64 generation failed with exit code $LASTEXITCODE" }
& python (Join-Path $PSScriptRoot 'verify-x86-64-process-elf.py') $processElf --kind main
if ($LASTEXITCODE -ne 0) { throw "Main process ELF64 verification failed with exit code $LASTEXITCODE" }
& python (Join-Path $PSScriptRoot 'verify-x86-64-process-elf.py') $processExecElf --kind exec
if ($LASTEXITCODE -ne 0) { throw "Exec process ELF64 verification failed with exit code $LASTEXITCODE" }
Copy-Item $processElf $embeddedProcessElf -Force
Copy-Item $processExecElf $embeddedProcessExecElf -Force

Write-Host '[4/9] Assembling x86-64 hardware layer with NASM'
& nasm -w+error -f win64 (Join-Path $repoRoot 'src\arch\x86_64\cpu.asm') -o $asmObject
if ($LASTEXITCODE -ne 0) { throw "NASM hardware layer failed with exit code $LASTEXITCODE" }

Write-Host '[5/9] Assembling 16-to-64-bit AP startup trampoline'
& nasm -f bin (Join-Path $repoRoot 'src\arch\x86_64\ap_trampoline.asm') -o $apTrampoline
if ($LASTEXITCODE -ne 0) { throw "NASM AP trampoline failed with exit code $LASTEXITCODE" }
$trampolineSize = (Get-Item $apTrampoline).Length
if ($trampolineSize -ne 4096) {
    throw "AP trampoline must be exactly one 4096-byte page; got $trampolineSize bytes."
}

Write-Host "[6/9] Compiling UEFI image with canonical Zig $actualVersion"
$zigArgs = @(
    'build-exe',
    (Join-Path $repoRoot 'src\main.zig'),
    $asmObject,
    '-target', 'x86_64-uefi-msvc',
    '-O', $Optimize,
    '-fstrip',
    '-fno-omit-frame-pointer',
    '-fno-stack-check',
    '-fno-stack-protector',
    "-femit-bin=$efiImage"
)
& $zigExe @zigArgs
if ($LASTEXITCODE -ne 0) { throw "Canonical Zig failed with exit code $LASTEXITCODE" }

Write-Host '[7/9] Verifying PE/COFF UEFI image'
& (Join-Path $PSScriptRoot 'verify-efi.ps1') -Path $efiImage

Write-Host '[8/9] Re-verifying embedded service ELF identity'
& python (Join-Path $PSScriptRoot 'verify-x86-64-user-elf.py') $userElf
if ($LASTEXITCODE -ne 0) { throw "Post-build ELF64 userspace verification failed with exit code $LASTEXITCODE" }

Write-Host '[9/9] Re-verifying embedded multiprocess ELF identities'
& python (Join-Path $PSScriptRoot 'verify-x86-64-process-elf.py') $processElf --kind main
if ($LASTEXITCODE -ne 0) { throw "Post-build main process ELF64 verification failed with exit code $LASTEXITCODE" }
& python (Join-Path $PSScriptRoot 'verify-x86-64-process-elf.py') $processExecElf --kind exec
if ($LASTEXITCODE -ne 0) { throw "Post-build exec process ELF64 verification failed with exit code $LASTEXITCODE" }

Write-Host "USB layout ready at: $(Join-Path $repoRoot 'zig-out')"
