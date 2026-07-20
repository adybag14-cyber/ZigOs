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
    '-m', '32M',
    '-machine', 'pc',
    '-cpu', 'qemu32',
    '-boot', 'c',
    '-drive', "file=$image,format=raw,if=ide,index=0",
    '-display', 'none',
    '-serial', 'none',
    '-monitor', 'none',
    '-no-reboot',
    '-no-shutdown',
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
        if ($output.Contains('ZigOs BIOS stage0 verified: drive 0x80 EDD yes signature 0x55AA')) { break }
        if ($process.HasExited) { break }
    }
} finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
}

$output = [IO.File]::ReadAllText($debugPath)
if (-not $output.Contains('ZigOs legacy BIOS stage0 online')) {
    throw 'The legacy BIOS stage0 entry marker was not observed.'
}
if (-not $output.Contains('ZigOs BIOS stage0 verified: drive 0x80 EDD yes signature 0x55AA')) {
    throw "The legacy BIOS drive/EDD/signature marker was not observed. Output: $output"
}

Write-Host $output.Trim()
Write-Host 'Legacy BIOS stage0 QEMU test passed.'
