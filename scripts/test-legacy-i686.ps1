[CmdletBinding()]
param(
    [ValidateRange(2, 60)]
    [int]$TimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'build-legacy-i686.ps1')

$qemuCandidates = @(
    (Get-Command qemu-system-i386 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    'C:\Program Files\qemu\qemu-system-i386.exe'
) | Where-Object { $_ -and (Test-Path $_) }
$qemu = $qemuCandidates | Select-Object -First 1
if (-not $qemu) { throw 'qemu-system-i386 was not found.' }

$image = Join-Path $root 'zig-out\legacy\i686\ZIGOS386.IMG'
$debugPath = Join-Path $root 'build\legacy-i686-debug.log'
[IO.File]::WriteAllText($debugPath, '')

$arguments = @(
    '-m', '32M', '-machine', 'pc', '-cpu', 'qemu32', '-boot', 'c',
    '-drive', "file=$image,format=raw,if=ide,index=0",
    '-display', 'none', '-serial', 'none', '-monitor', 'none',
    '-no-reboot', '-no-shutdown',
    '-debugcon', "file:$debugPath",
    '-global', 'isa-debugcon.iobase=0xe9'
)

$process = Start-Process -FilePath $qemu -ArgumentList $arguments -PassThru
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$output = ''
try {
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        try { $output = [IO.File]::ReadAllText($debugPath) } catch { continue }
        if ($output.Contains('ZigOs i686 freestanding kernel image built')) { break }
        if ($process.HasExited) { break }
    }
} finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
}

$output = [IO.File]::ReadAllText($debugPath)
$required = @(
    'ZigOs legacy BIOS stage0 online',
    'ZigOs BIOS stage0 verified: drive 0x80 EDD yes signature 0x55AA',
    'ZigOs BIOS stage0 loaded stage1: LBA 1 sectors 8 address 0x00008000',
    'ZigOs BIOS stage1 online: real mode address 0x00008000',
    'ZigOs BIOS stage1 loaded kernel: LBA 9 address 0x00010000',
    'ZigOs BIOS stage1 protected mode verified: CS 0x0008 CR0.PE yes kernel 0x00010000',
    'ZigOs i686 freestanding kernel image built'
)
foreach ($marker in $required) {
    if (-not $output.Contains($marker)) { throw "Missing legacy marker: $marker. Output: $output" }
}

Write-Host $output.Trim()
Write-Host 'Legacy BIOS i686 QEMU test passed.'
