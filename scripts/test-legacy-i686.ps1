[CmdletBinding()]
param(
    [ValidateRange(5, 60)]
    [int]$TimeoutSeconds = 20
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
    '-display', 'none', '-serial', 'stdio', '-monitor', 'none',
    '-no-reboot', '-no-shutdown',
    '-debugcon', "file:$debugPath",
    '-global', 'isa-debugcon.iobase=0xe9'
)

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $qemu
$startInfo.Arguments = $arguments -join ' '
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
if (-not $process.Start()) { throw 'Unable to start qemu-system-i386.' }
$serialBuilder = [Text.StringBuilder]::new()
$stdoutReadTask = $process.StandardOutput.ReadLineAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()

$readyMarker = 'ZigOs i686 shell ready: prompt zigos> commands help ls mem ticks disk cat HELLO.TXT run INIT.ELF ps exit'
$finalMarker = 'ZigOs i686 shell verified: commands 0x00000008 unknown 0x00000000 exit yes'
$commandPlan = @(
    @{ Command = 'help'; Expect = 'commands: help ls mem ticks disk cat HELLO.TXT run INIT.ELF ps exit' },
    @{ Command = 'ls'; Expect = 'INIT.ELF 0x000001A7' },
    @{ Command = 'mem'; Expect = 'frames-free 0x00001ECF heap-free 0x00007FF0 heap-base 0x00107000' },
    @{ Command = 'ticks'; Expect = 'ticks 0x0000000C PIT-Hz 0x00000064' },
    @{ Command = 'disk'; Expect = 'model QEMU HARDDISK sectors 0x00001000 FAT12 yes HELLO.TXT-bytes 0x00000056 INIT.ELF-bytes 0x000001A7' },
    @{ Command = 'cat HELLO.TXT'; Expect = 'Loaded through ATA PIO by the i686 kernel.' },
    @{ Command = 'run INIT.ELF'; Expect = 'process PID 0x00000002 INIT.ELF exited 0x00000033 syscalls 0x00000003' },
    @{ Command = 'ps'; Expect = 'PID 0x00000002 EXITED 0x00000033 INIT.ELF' },
    @{ Command = 'exit'; Expect = $finalMarker }
)
$nextCommand = 0
$commandInFlight = $false
$commandsSent = 0
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$debug = ''
try {
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($stdoutReadTask.IsCompleted) {
            $line = $stdoutReadTask.Result
            if ($null -ne $line) {
                [void]$serialBuilder.Append($line)
                [void]$serialBuilder.Append("`r`n")
                $stdoutReadTask = $process.StandardOutput.ReadLineAsync()
            }
        }
        $serialNow = $serialBuilder.ToString()
        if ($nextCommand -lt $commandPlan.Count) {
            $canSend = if ($nextCommand -eq 0) {
                $serialNow.Contains($readyMarker)
            } else {
                $serialNow.Contains($commandPlan[$nextCommand - 1].Expect)
            }
            if (-not $commandInFlight -and $canSend) {
                $process.StandardInput.WriteLine($commandPlan[$nextCommand].Command)
                $process.StandardInput.Flush()
                $commandInFlight = $true
                $commandsSent += 1
            }
            if ($commandInFlight -and $serialNow.Contains($commandPlan[$nextCommand].Expect)) {
                $nextCommand += 1
                $commandInFlight = $false
            }
        }
        if ($serialNow.Contains($finalMarker)) { break }
        Start-Sleep -Milliseconds 10
    }
} finally {
    try { $process.StandardInput.Close() } catch {}
    if (-not $process.HasExited) {
        $process.Kill()
        $process.WaitForExit()
    }
}

$serial = $serialBuilder.ToString()
$qemuError = $stderrTask.Result
$process.Dispose()
[IO.File]::WriteAllText($serialPath, $serial)
$debug = [IO.File]::ReadAllText($debugPath)
if ($commandsSent -ne $commandPlan.Count) { throw "Only $commandsSent of $($commandPlan.Count) COM1 commands were sent. QEMU stderr: $qemuError" }

$runtimeMarker = 'ZigOs i686 runtime verified: vendor GenuineIntel max-leaf 0x00000004 CR0 0x00000011 PE yes stack 0x0009F000 aligned16 yes BSS64 zero yes VGA yes COM1 yes'
$exceptionMarker = 'ZigOs i686 exceptions verified: vectors 0x00000020 breakpoint-count 0x00000002 last-vector 0x00000003 error 0x00000000 eip-nonzero yes'
$keyboardMarker = 'ZigOs i686 keyboard verified: IRQ1 0x21 make-count 0x00000001 last-make 0x1E irq-count-nonzero yes'
$interruptMarker = 'ZigOs i686 interrupts verified: IDT 0x00000100 limit 0x000007FF IRQ0 0x20 PIC 0x20/0x28 masks 0xFE/0xFF PIT-Hz 0x00000064 divisor 0x00002E9C ticks 0x00000005'
$frameMarker = 'ZigOs i686 frame allocator verified: managed-limit 0x04000000 frame-size 0x00001000 free-before 0x00001EE0 first 0x00100000 second 0x00101000 third 0x00102000 reuse 0x00101000 free-after 0x00001EE0 kernel-end-below-1M yes'
$pagingMarker = 'ZigOs i686 paging verified: CR3 0x00100000 CR0 0x80000011 identity-MiB 0x00000010 tables 0x00000004 alias 0xC0000000 physical 0x00106000 value 0xA5A55A5A free-frames 0x00001ED9'
$heapMarker = 'ZigOs i686 heap verified: base 0x00107000 bytes 0x00008000 free-before 0x00007FF0 first 0x00107010 second 0x00107060 third 0x00107470 reuse 0x00107060 coalesced 0x00007FF0 frames-left 0x00001ED1'
$ataMarker = 'ZigOs i686 ATA verified: primary-master yes model QEMU HARDDISK LBA28 yes sectors 0x00001000 MBR 0x55AA kernel-LBA 0x00000009 sector-match yes buffer 0x00107010 heap-restored yes'
$fatMarker = 'ZigOs i686 FAT12 verified: volume-LBA 0x00000100 sectors 0x00000B40 bytes-sector 0x00000200 root-start 0x00000113 data-start 0x00000121 file HELLO.TXT cluster 0x00000002 bytes 0x00000056 hash 0xA9F660F2 chain-end 0x00000FFF heap-restored yes'
$schedulerMarker = 'ZigOs i686 scheduler verified: policy round-robin tasks 0x00000003 task-a-quanta 0x00000003 task-b-quanta 0x00000003 switches 0x00000007 tick-delta 0x00000007 bootstrap-restored yes'
$ring3Marker = 'ZigOs i686 ring3 verified: GDT entries 0x00000006 TSS selector 0x00000028 CS 0x0000001B SS 0x00000023 user-ESP 0x00402000 code 0x00400000 stack 0x00402000 sentinel 0xCAFEBABE kernel-user-bit no user-pages yes'
$syscallMarker = 'ZigOs i686 syscalls verified: vector 0x00000080 calls 0x00000004 write-bytes 0x00000025 getpid 0x00000001 rejected 0x00000001 errno 0xFFFFFFF2 exit-code 0x0000002A kernel-pointer-denied yes'
$elfMarker = 'ZigOs i686 ELF verified: file INIT.ELF cluster 0x00000003 bytes 0x000001A7 entry 0x00400000 PT_LOAD-filesz 0x000000A7 memsz 0x00000200 flags 0x00000005 pid 0x00000001 exit 0x00000033 BSS-zero yes heap-restored yes'
$vfsReadyMarker = 'ZigOs i686 VFS/process ready: mount FAT12 root-files 0x00000002 fd-capacity 0x00000004 probe-fd 0x00000000 split-read 0x00000020/0x00000036 process-capacity 0x00000004 PID1 exited 0x00000033'
$vfsFinalMarker = 'ZigOs i686 VFS/process verified: opens 0x00000003 reads 0x00000004 closes 0x00000003 processes 0x00000002 last-pid 0x00000002 last-exit 0x00000033 descriptors-closed yes'

$debugMarkers = @(
    'ZigOs legacy BIOS stage0 online',
    'ZigOs BIOS stage0 verified: drive 0x80 EDD yes signature 0x55AA',
    'ZigOs BIOS stage0 loaded stage1: LBA 1 sectors 8 address 0x00008000',
    'ZigOs BIOS stage1 online: real mode address 0x00008000',
    'ZigOs BIOS stage1 E820 boot contract ready: info 0x00005000 entries 0x00005200',
    'ZigOs BIOS stage1 kernel verified: chunked-EDD yes max-chunk 0x0040 checksum16 yes FAT-LBA 0x00000100',
    'ZigOs BIOS stage1 loaded kernel: LBA 9 address 0x00010000',
    'ZigOs BIOS stage1 protected mode verified: CS 0x0008 CR0.PE yes kernel 0x00010000',
    'ZigOs i686 freestanding kernel image built',
    $runtimeMarker, $exceptionMarker,
    'ZigOs i686 keyboard waiting: IRQ1 0x21 controller-command 0xD2 expected-make 0x1E',
    $keyboardMarker, $interruptMarker, $frameMarker, $pagingMarker, $heapMarker, $ataMarker, $fatMarker, $schedulerMarker, $ring3Marker,
    'ZigOs ring3 syscall write verified.', $syscallMarker,
    'INIT.ELF executed in ring3 via FAT12.', $elfMarker, $vfsReadyMarker,
    $readyMarker,
    'commands: help ls mem ticks disk cat HELLO.TXT run INIT.ELF ps exit',
    'HELLO.TXT 0x00000056', 'INIT.ELF 0x000001A7',
    'frames-free 0x00001ECF heap-free 0x00007FF0 heap-base 0x00107000',
    'ticks 0x0000000C PIT-Hz 0x00000064',
    'model QEMU HARDDISK sectors 0x00001000 FAT12 yes HELLO.TXT-bytes 0x00000056 INIT.ELF-bytes 0x000001A7',
    'ZigOs legacy FAT12 filesystem is online.',
    'Loaded through ATA PIO by the i686 kernel.',
    'process PID 0x00000002 INIT.ELF exited 0x00000033 syscalls 0x00000003',
    'PID 0x00000001 EXITED 0x00000033 INIT.ELF', 'PID 0x00000002 EXITED 0x00000033 INIT.ELF',
    $vfsFinalMarker, $finalMarker
)
foreach ($marker in $debugMarkers) {
    if (-not $debug.Contains($marker)) { throw "Missing debugcon marker: $marker. Output: $debug" }
}

$e820Pattern = 'ZigOs i686 E820 verified: boot-info 0x00005000 version 0x00000002 entries 0x00000006 usable-regions 0x00000002 usable-bytes 0x0000000001F7FC00 highest 0x0000000100000000 drive 0x80 kernel 0x00010000/0x[0-9A-F]{8}/0x[0-9A-F]{8} loader checksum16 0x[0-9A-F]{8} entry-checksum yes FAT-LBA 0x00000100 flags 0x07'
if (-not [regex]::IsMatch($debug, $e820Pattern)) { throw "E820 debugcon contract missing. Output: $debug" }
if (-not [regex]::IsMatch($serial, $e820Pattern)) { throw "E820 COM1 contract missing. Serial: $serial" }

$serialMarkers = @(
    $runtimeMarker, $exceptionMarker, $keyboardMarker, $interruptMarker, $frameMarker,
    $pagingMarker, $heapMarker, $ataMarker, $fatMarker, $schedulerMarker, $ring3Marker,
    'ZigOs ring3 syscall write verified.', $syscallMarker, 'INIT.ELF executed in ring3 via FAT12.', $elfMarker, $vfsReadyMarker, $readyMarker,
    'help', 'commands: help ls mem ticks disk cat HELLO.TXT run INIT.ELF ps exit',
    'ls', 'HELLO.TXT 0x00000056', 'INIT.ELF 0x000001A7',
    'mem', 'frames-free 0x00001ECF heap-free 0x00007FF0 heap-base 0x00107000',
    'ticks', 'ticks 0x0000000C PIT-Hz 0x00000064',
    'disk', 'model QEMU HARDDISK sectors 0x00001000 FAT12 yes HELLO.TXT-bytes 0x00000056 INIT.ELF-bytes 0x000001A7',
    'cat HELLO.TXT', 'ZigOs legacy FAT12 filesystem is online.',
    'Loaded through ATA PIO by the i686 kernel.',
    'run INIT.ELF', 'process PID 0x00000002 INIT.ELF exited 0x00000033 syscalls 0x00000003',
    'ps', 'PID 0x00000001 EXITED 0x00000033 INIT.ELF', 'PID 0x00000002 EXITED 0x00000033 INIT.ELF',
    'exit', $vfsFinalMarker, $finalMarker
)
foreach ($marker in $serialMarkers) {
    if (-not $serial.Contains($marker)) { throw "Missing COM1 marker: $marker. Serial: $serial" }
}

Write-Host $debug.Trim()
Write-Host '--- COM1 SESSION ---'
Write-Host $serial.Trim()
Write-Host 'Legacy BIOS i686 QEMU test passed.'
