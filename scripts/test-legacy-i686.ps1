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
$serialPath = Join-Path $root 'build\legacy-i686-serial.log'
[IO.File]::WriteAllText($debugPath, '')
[IO.File]::WriteAllText($serialPath, '')

$arguments = @(
    '-m', '32M', '-machine', 'pc', '-cpu', 'qemu32', '-boot', 'c',
    '-drive', "file=$image,format=raw,if=ide,index=0",
    '-display', 'none', '-serial', "file:$serialPath", '-monitor', 'none',
    '-no-reboot', '-no-shutdown',
    '-debugcon', "file:$debugPath",
    '-global', 'isa-debugcon.iobase=0xe9'
)

$process = Start-Process -FilePath $qemu -ArgumentList $arguments -PassThru
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$output = ''
$interruptMarker = 'ZigOs i686 interrupts verified: IDT 0x00000100 limit 0x000007FF IRQ0 0x20 PIC 0x20/0x28 masks 0xFE/0xFF PIT-Hz 0x00000064 divisor 0x00002E9C ticks 0x00000005'
$frameMarker = 'ZigOs i686 frame allocator verified: managed-limit 0x04000000 frame-size 0x00001000 free-before 0x00001EE0 first 0x00100000 second 0x00101000 third 0x00102000 reuse 0x00101000 free-after 0x00001EE0 kernel-end-below-1M yes'
$finalMarker = 'ZigOs i686 paging verified: CR3 0x00100000 CR0 0x80000011 identity-MiB 0x00000010 tables 0x00000004 alias 0xC0000000 physical 0x00106000 value 0xA5A55A5A free-frames 0x00001ED9'
try {
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        try { $output = [IO.File]::ReadAllText($debugPath) } catch { continue }
        if ($output.Contains($finalMarker)) { break }
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
    'ZigOs BIOS stage1 E820 boot contract ready: info 0x00005000 entries 0x00005200',
    'ZigOs BIOS stage1 loaded kernel: LBA 9 address 0x00010000',
    'ZigOs BIOS stage1 protected mode verified: CS 0x0008 CR0.PE yes kernel 0x00010000',
    'ZigOs i686 freestanding kernel image built',
    'ZigOs i686 runtime verified: vendor GenuineIntel max-leaf 0x00000004 CR0 0x00000011 PE yes stack 0x0009F000 aligned16 yes BSS64 zero yes VGA yes COM1 yes',
    'ZigOs i686 exceptions verified: vectors 0x00000020 breakpoint-count 0x00000002 last-vector 0x00000003 error 0x00000000 eip-nonzero yes',
    'ZigOs i686 keyboard waiting: IRQ1 0x21 controller-command 0xD2 expected-make 0x1E',
    'ZigOs i686 keyboard verified: IRQ1 0x21 make-count 0x00000001 last-make 0x1E irq-count-nonzero yes',
    $interruptMarker,
    $frameMarker,
    $finalMarker
)
foreach ($marker in $required) {
    if (-not $output.Contains($marker)) { throw "Missing legacy marker: $marker. Output: $output" }
}

$e820Pattern = 'ZigOs i686 E820 verified: boot-info 0x00005000 version 0x00000001 entries 0x00000006 usable-regions 0x00000002 usable-bytes 0x0000000001F7FC00 highest 0x0000000100000000 drive 0x80 kernel 0x00010000/0x[0-9A-F]{8}/0x[0-9A-F]{8}'
if (-not [regex]::IsMatch($output, $e820Pattern)) { throw "E820 debugcon contract missing. Output: $output" }
$serial = [IO.File]::ReadAllText($serialPath)
if (-not [regex]::IsMatch($serial, $e820Pattern)) { throw "E820 COM1 contract missing. Serial: $serial" }
foreach ($marker in @(
    'ZigOs i686 runtime verified: vendor GenuineIntel',
    'PE yes stack 0x0009F000 aligned16 yes BSS64 zero yes VGA yes COM1 yes',
    'ZigOs i686 exceptions verified: vectors 0x00000020 breakpoint-count 0x00000002 last-vector 0x00000003 error 0x00000000 eip-nonzero yes',
    'ZigOs i686 keyboard verified: IRQ1 0x21 make-count 0x00000001 last-make 0x1E irq-count-nonzero yes',
    $interruptMarker,
    $frameMarker,
    $finalMarker
)) {
    if (-not $serial.Contains($marker)) { throw "COM1 marker missing: $marker. Serial: $serial" }
}

Write-Host $output.Trim()
Write-Host '--- COM1 ---'
Write-Host $serial.Trim()
Write-Host 'Legacy BIOS i686 QEMU test passed.'
