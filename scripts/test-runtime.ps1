[CmdletBinding()]
param(
    [ValidateRange(30, 300)]
    [int]$TimeoutSeconds = 90,
    [switch]$Network
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $repoRoot 'build'
$efiImage = Join-Path $repoRoot 'zig-out\EFI\BOOT\BOOTX64.EFI'
$debugLog = Join-Path $repoRoot 'runtime-debug.log'
$serialLog = Join-Path $repoRoot 'runtime-serial.log'
$qemuStdout = Join-Path $repoRoot 'runtime-qemu-stdout.log'
$qemuStderr = Join-Path $repoRoot 'runtime-qemu-stderr.log'
$nvmeImage = Join-Path $buildDir 'runtime-nvme.img'
$nvmeMetadata = Join-Path $buildDir 'runtime-nvme.json'
$tftpRoot = Join-Path $buildDir 'runtime-tftp-root'
$tftpFile = Join-Path $tftpRoot 'zigos.bin'
$mutex = [System.Threading.Mutex]::new($false, 'Local\ZigOsQemuTestHarness')
$acquired = $false
$process = $null
$client = $null
try {
    try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(30)) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'The shared ZigOs QEMU harness remained busy for 30 seconds.' }

    & (Join-Path $PSScriptRoot 'build.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'The x86-64 build failed.' }
    if (-not (Test-Path $efiImage)) { throw 'The current x86-64 build produced no installed EFI image.' }

    $qemuCandidates = @(
        (Get-Command qemu-system-x86_64 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
        'C:\Program Files\qemu\qemu-system-x86_64.exe'
    ) | Where-Object { $_ -and (Test-Path $_) }
    $qemu = $qemuCandidates | Select-Object -First 1
    if (-not $qemu) { throw 'qemu-system-x86_64 was not found.' }

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
    if (-not $codeSource -or -not $varsSource) { throw 'Compatible split OVMF images were not found.' }

    New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
    if ($Network) {
        New-Item -ItemType Directory -Force -Path $tftpRoot | Out-Null
        $tftpBytes = [byte[]]::new(2304)
        for ($index = 0; $index -lt $tftpBytes.Length; $index++) {
            $tftpBytes[$index] = [byte](($index * 37 + 11) -band 0xFF)
        }
        [System.IO.File]::WriteAllBytes($tftpFile, $tftpBytes)
        $tftpHash = (Get-FileHash -Path $tftpFile -Algorithm SHA256).Hash
        if ($tftpHash -ne '03652909284ACDFA888C1815EFC062536C671574EB7761413F6E2F2385F5F822') {
            throw "The runtime TFTP fixture hash was invalid: $tftpHash"
        }
    }
    $codeImage = Join-Path $buildDir 'runtime-ovmf-code.fd'
    $varsImage = Join-Path $buildDir 'runtime-ovmf-vars.fd'
    Copy-Item $codeSource $codeImage -Force
    Copy-Item $varsSource $varsImage -Force
    Remove-Item $debugLog, $serialLog, $qemuStdout, $qemuStderr, $nvmeImage, $nvmeMetadata -Force -ErrorAction SilentlyContinue

    & python (Join-Path $PSScriptRoot 'create-nvme-test-image.py') --output $nvmeImage --efi $efiImage --block-size 512 --metadata $nvmeMetadata | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The runtime NVMe image builder failed.' }

    $portProbe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $portProbe.Start()
    $serialPort = ([System.Net.IPEndPoint]$portProbe.LocalEndpoint).Port
    $portProbe.Stop()

    $debugPath = $debugLog.Replace('\', '/')
    $nvmePath = $nvmeImage.Replace('\', '/')
    $codePath = $codeImage.Replace('\', '/')
    $varsPath = $varsImage.Replace('\', '/')
    $tftpPath = $tftpRoot.Replace('\', '/')
    $arguments = @(
        '-machine', 'q35,i8042=off,hpet=off',
        '-m', '256M',
        '-cpu', 'max',
        '-smp', '1',
        '-device', 'qemu-xhci,id=xhci',
        '-drive', "file=$nvmePath,if=none,id=nvme0,format=raw,cache=unsafe",
        '-device', 'nvme,drive=nvme0,serial=ZIGOSNVME,logical_block_size=512,physical_block_size=512',
        '-drive', "if=pflash,format=raw,unit=0,readonly=on,file=$codePath",
        '-drive', "if=pflash,format=raw,unit=1,file=$varsPath",
        '-debugcon', "file:$debugPath",
        '-global', 'isa-debugcon.iobase=0xe9',
        '-display', 'none',
        '-vga', 'none',
        '-serial', "tcp:127.0.0.1:$serialPort,server=on,wait=off",
        '-monitor', 'none',
        '-no-reboot'
    )
    if ($Network) {
        $arguments += @('-netdev', "user,id=net0,tftp=$tftpPath", '-device', 'e1000e,netdev=net0,mac=52:54:00:12:34:56')
    } else {
        $arguments += @('-net', 'none')
    }

    $process = Start-Process -FilePath $qemu -ArgumentList $arguments -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr -PassThru -WindowStyle Hidden
    try { $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}

    $connectDeadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $connectDeadline -and -not $client) {
        $candidate = [System.Net.Sockets.TcpClient]::new()
        try {
            $candidate.Connect('127.0.0.1', $serialPort)
            $client = $candidate
        } catch {
            $candidate.Dispose()
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $client) { throw 'Could not connect to the QEMU COM1 TCP endpoint.' }
    $stream = $client.GetStream()
    $stream.ReadTimeout = 100
    $stream.WriteTimeout = 2000
    $serialBytes = [System.Collections.Generic.List[byte]]::new()
    $readBuffer = [byte[]]::new(8192)

    function Read-SerialAvailable {
        while ($stream.DataAvailable) {
            $count = $stream.Read($readBuffer, 0, $readBuffer.Length)
            if ($count -le 0) { break }
            for ($index = 0; $index -lt $count; $index++) { $serialBytes.Add($readBuffer[$index]) }
        }
    }

    function Current-SerialText {
        Read-SerialAvailable
        return [System.Text.Encoding]::ASCII.GetString($serialBytes.ToArray())
    }

    function Send-SerialLine([string]$Line) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($Line + "`r")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        Start-Sleep -Milliseconds 140
        Read-SerialAvailable
    }

    function Send-SerialBytes([byte[]]$Bytes) {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush()
        Start-Sleep -Milliseconds 140
        Read-SerialAvailable
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $promptObserved = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
        $text = Current-SerialText
        if ($text.Contains('ZigOs persistent runtime online') -and $text.Contains('root@zigos:/home/root# ')) {
            $promptObserved = $true
            break
        }
        $process.Refresh()
        if ($process.HasExited) { throw "QEMU exited before the persistent prompt with code $($process.ExitCode)." }
    }
    if (-not $promptObserved) { throw 'The persistent serial prompt was not observed.' }

    $pingCommand = if ($Network) { 'ping 10.0.2.2' } else { 'ping 192.0.2.1' }
    $dnsCommand = if ($Network) { 'dns localhost' } else { 'dns example.test' }
    $commands = @(
        'pwd',
        'ls /',
        'mkdir /home/root/demo',
        'cd /home/root/demo',
        'pwd',
        'write note.txt persistent runtime',
        'cat note.txt',
        'wc < note.txt',
        'echo alpha beta gamma | wc',
        'echo alpha | grep alpha > match.txt',
        'cat match.txt',
        'stat note.txt',
        'mount',
        'ls /boot',
        'cat /boot/README.TXT',
        'ls /boot/EFI/BOOT',
        'cat /boot/EFI/BOOT/BOOT.CFG',
        'stat /boot/EFI/BOOT/BOOTX64.EFI',
        'df',
        'elf /bin/hello.elf',
        'run /bin/hello.elf one two',
        'exec /bin/sleep.elf',
        'crash',
        'pipex',
        'spawn /bin/sleep.elf',
        'wait 8',
        'spawn /bin/spin.elf',
        'ps',
        'jobs',
        'kill 9',
        'wait 9',
        'exec /bin/wait.elf',
        'exec /bin/vm.elf',
        'exec /bin/io.elf',
        'exec /bin/tty.elf',
        'exec /bin/sdk.elf alpha beta',
        'exec /bin/c-sdk.elf alpha beta',
        'devices',
        'ifconfig',
        $pingCommand,
        $dnsCommand,
        'netstat',
        'routes',
        'arp',
        'writeback /bin/sdk.elf',
        'sleep 1',
        'writeback status',
        'cachepressure',
        'sync',
        'fsck',
        'history',
        'fdtest',
        'fds',
        'shutdown'
    )
    if ($Network) {
        $deviceIndex = [Array]::IndexOf($commands, 'devices')
        $commands = @($commands[0..($deviceIndex - 1)] + @('exec /bin/socket.elf', 'exec /bin/dns.elf') + $commands[$deviceIndex..($commands.Length - 1)])
    }
    foreach ($command in $commands) {
        Send-SerialLine $command
        if ($command -eq 'exec /bin/tty.elf') {
            Start-Sleep -Milliseconds 300
            $ttyInput = [System.Collections.Generic.List[byte]]::new()
            foreach ($byte in [System.Text.Encoding]::ASCII.GetBytes('zigtx')) { $ttyInput.Add($byte) }
            $ttyInput.Add(0x7F)
            foreach ($byte in [System.Text.Encoding]::ASCII.GetBytes("ty`r")) { $ttyInput.Add($byte) }
            Send-SerialBytes $ttyInput.ToArray()
        }
        if ($command -like 'sleep *' -or $command -like 'exec *' -or $command -eq 'pipex' -or $command -like 'wait *' -or ($Network -and ($command -like 'ping *' -or $command -like 'dns *'))) { Start-Sleep -Milliseconds 600; Read-SerialAvailable }
    }

    $shutdownObserved = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
        $text = Current-SerialText
        if ($text.Contains('ZigOs x86-64 Capstone 19 verified:') -and $text.Contains('network-facades-removed yes cleanup yes')) {
            $shutdownObserved = $true
            break
        }
        $process.Refresh()
        if ($process.HasExited) { break }
    }
    Read-SerialAvailable
    $serialText = [System.Text.Encoding]::ASCII.GetString($serialBytes.ToArray())
    [System.IO.File]::WriteAllText($serialLog, $serialText, [System.Text.Encoding]::ASCII)
    if (-not $shutdownObserved) { throw 'The explicit persistent-runtime shutdown marker was not observed.' }

    $required = @(
        'ZigOs persistent runtime online',
        'init PID 1; serial shell PID 2; APIC scheduling 100 Hz',
        '/home/root/demo',
        'persistent runtime',
        '1 2 19',
        '1 3 18',
        'alpha',
        'kind file size 19',
        'ramfs on / type ramfs (rw)',
        'nvme0p1 on /boot type boot_fat (ro)',
        'ZigOs block-backed FAT16 runtime mount',
        'source=nvme0p1',
        'mode=readonly',
        'mode 0444 mount 2 links 1 readonly yes',
        'ELF64 entry 0x8000000000 segments 2 bytes 12288',
        'exec: mapped VFS ELF bytes 12288',
        'hello from VFS-loaded CPL3 ELF64',
        'exec: PID 3 state zombie status 0x2A',
        'sleep: before',
        'sleep: after',
        'exec: PID 4 state zombie status 0x7',
        'crash: real page fault follows',
        'crash: contained genuine CPL3 exception in PID 5 vector 14 CR2 0x8000180000',
        'PIPE-CPL',
        'pipex: real CPL3 reader blocked; real CPL3 writer woke it; payload PIPE-CPL; pipe reclaimed',
        '[8] CPL3 started /bin/sleep.elf',
        '[9] CPL3 started /bin/spin.elf',
        'PID PPID STATE',
        'PID 8 status 0x7 state zombie',
        '[9] runnable /bin/spin.elf',
        'forced termination signal 9 sent to real PID 9 state zombie',
        'PID 9 status 0x89 state zombie',
        'wait-api: start',
        'wait-api: concurrent wait-any ordering passed',
        'exec: PID 10 state zombie status 0x31',
        'vm-api: start',
        'vm-api: ABI/mmap/mprotect/munmap/brk passed',
        'exec: PID 13 state zombie status 0x52',
        'io-api: start',
        'io-api: open/read/fstat/getdents/poll passed',
        'exec: PID 14 state zombie status 0x53',
        'tty-api: start',
        'tty-api: blocking read/poll/line discipline passed',
        'exec: PID 15 state zombie status 0x55',
        'zig-sdk: start',
        'zig-sdk: argc/argv passed',
        'zig-sdk: envp/auxv passed',
        'zig-sdk: ABI discovery passed',
        'zig-sdk: shared file mmap coherence passed',
        'zig-sdk: tmpfs mount/umount isolation, statfs and busy policy passed',
        'zig-sdk: timestamp precision/data/namespace/access ordering passed',
        'zig-sdk: uid/gid creation and hard-link ownership passed',
        'zig-sdk: process umask file/directory creation passed',
        'zig-sdk: setuid/setgid metadata inert-exec policy passed',
        'zig-sdk: advisory whole-file flock passed',
        'zig-sdk: advisory byte-range lock passed',
        'zig-sdk: directory watch notifications passed',
        'zig-sdk: startup/argv/abi/files/vm/file-mmap/errno/fsync/fdatasync/readv/writev/mount/umount/tmpfs/statfs/stattimes/statowner/umask/setid-metadata/flock/lockrange/watchdir passed',
        'exec: PID 16 state zombie status 0x56',
        'c-sdk: start',
        'c-sdk: argc/argv passed',
        'c-sdk: ABI 1.20 discovery passed',
        'c-sdk: process umask creation passed',
        'c-sdk: setuid/setgid metadata passed',
        'c-sdk: advisory whole-file flock passed',
        'c-sdk: advisory byte-range lock passed',
        'c-sdk: directory watch notifications passed',
        'c-sdk: generated header/library/device/ioctl/stat/statfs/stattimes/statowner/umask/setid-metadata/flock/lockrange/watchdir/directory-openat/fsync/fdatasync/symlink/readlink/link/nlink/fallocate/sparse/readv/writev passed',
        'exec: PID 17 state zombie status 0x57',
        'serial COM1 online',
        'fsck ramfs/persist: clean',
        'writeback scheduled: node ',
        'writeback: active no requests/completions/passes 1/1/1 immediate/durable/clean/unsupported/failures/stale 1/0/0/0/0/0 pages queued/completed 6/6',
        'cache pressure: free before/after ',
        $(if ($Network) { 'entries before/after 16/10 reclaimed 6 dirty retained 10' } else { 'entries before/after 15/8 reclaimed 7 dirty retained 8' }),
        ' pressure checks/events/evictions ',
        ' backing alloc/release ',
        'sync complete: writable mounts 2 immediate 1 durable 1; ramfs mutations ',
        'fdtest: descriptors 3 open 3 pipes 0 shared-offset yes clone yes cloexec yes read-block yes write-block yes eof yes broken-pipe yes ring yes clean yes',
        $(if ($Network) { 'fdtest counters: dup 5 inherited 62 cloexec 1 blocked 3/1 wakeups 3/1' } else { 'fdtest counters: dup 5 inherited 56 cloexec 1 blocked 3/1 wakeups 3/1' }),
        'FD KIND       MODE OFD      REFS FLAGS OFFSET/BUFFERED',
        '0 terminal',
        '1 terminal',
        '2 terminal',
        $(if ($Network) { 'ZigOs persistent runtime shutdown: commands 56 failed 0' } else { 'ZigOs persistent runtime shutdown: commands 54 failed 0' }),
        'ZigOs shutdown drain:',
        'ZigOs persistent VFS:',
        'cache entries/refs ',
        ' hit/miss ',
        ' acquire/release ',
        ' page-cache entries ',
        ' dirty/ledger ',
        ' marks/sync-clear/discard ',
        $(if ($Network) { ' backing alloc/release/fail 60/60/0/0' } else { ' backing alloc/release/fail 55/55/0/0' }),
        $(if ($Network) { '/1/6 shutdown-release 10' } else { '/1/7 shutdown-release 8' }),
        ' mapped refs/pin/unpin/refresh/fail 0/1/1/1/0',
        ' lock tickets/outstanding ',
        ' data-lock tickets/outstanding ',
        ' page-write tickets/outstanding 186/0',
        ' pool-lock tickets/outstanding ',
        ' blocks/bytes/holes ',
        'ZigOs persistent processes:',
        'faults 1',
        $(if ($Network) { 'ZigOs persistent descriptors: namespaces 1 fds 3 open 3 terminals 3 vfs 0 pipes 0 dup/inherited/cloexec 5/62/1 blocked 3/1 wakeups 3/1' } else { 'ZigOs persistent descriptors: namespaces 1 fds 3 open 3 terminals 3 vfs 0 pipes 0 dup/inherited/cloexec 5/56/1 blocked 3/1 wakeups 3/1' }),
        'ZigOs permanent TTY: foreground group/session 1/1 buffered/edit/eof 0/0/0 lines 1 bytes submitted/read 7/7 blocked/wakeups 1/1 erase/interrupt/overflow 1/0/0 clean yes',
        'ZigOs boot FAT: block-backed yes files/directories 3/2 bytes 5632068 metadata/file/block reads 111/4/113 failures 0 clusters claimed/free/loop/cross/range 11004/5107/0/0/0 lock tickets/outstanding 5/0 quarantine state/reason/events no/none/0 clean yes',
        'ZigOs live pseudo filesystems: dev/proc/net registrations 3/5/4 publications 3/5/4 withdrawals 0/0/0 failures 0/0/0 clean yes',
        'ZigOs persistent storage: mounted yes generation/slot 1/0 records/payload 0/4 mounts/syncs/checks/recoveries 1/1/1/0 global/mount/immediate/durable/reject 1/2/1/1/0 writeback active no request/complete/pass 1/1/1 immediate/durable/clean/unsupported/failure/stale 1/0/0/0/0/0 pages queued/completed 6/6 payload/header/flush 1/1/2 NVMe read/write/flush ',
        ' errors 0/0 clean yes',
        'broken 1 clean yes',
        'Post-bootstrap physical memory manager active:',
        'bootstrap allocator sealed',
        'ZigOs post-bootstrap physical memory: total ',
        $(if ($Network) { 'alloc/free 344/344 failed/rejected 0/0 clean yes' } else { 'alloc/free 308/308 failed/rejected 0/0 clean yes' }),
        'ZigOs permanent userspace: page-limit 4096 used 0',
        ' file-mappings 0 launches/exits/faults ',
        $(if ($Network) { 'launches/exits/faults 17/15/1' } else { 'launches/exits/faults 15/13/1' }),
        $(if ($Network) { 'reclaimed 284 stale-contexts-swept 0 allocator alloc/release/retains 284/284/0' } else { 'reclaimed 253 stale-contexts-swept 0 allocator alloc/release/retains 253/253/0' }),
        'ZigOs x86-64 Capstone 18 verified: goals 0x000001D1',
        'ZigOs x86-64 Capstone 19 verified: goals 0x000001F1 new-goals 0x00000020 vfs-elf yes private-cr3 yes retained-contexts yes timer-preemption yes real-fault yes executable-pipes yes frame-reclamation yes network-facades-removed yes cleanup yes'
    )
    if ($Network) {
        $required += @(
            'socket-api: start',
            'socket-api: sendto/recvfrom/getpeername/nonblocking passed',
            'exec: PID 18 state zombie status 0x54',
            'dns-sdk: start',
            'dns-sdk: userspace resolver localhost -> 127.0.0.1 passed',
            'exec: PID 19 state zombie status 0x5A',
            'serial COM1 online; framebuffer no; USB keyboard no; NVMe yes; AHCI no; e1000e yes',
            'e1000e0: up mac 52:54:00:12:34:56 ipv4 10.0.2.15 netmask 255.255.255.0 gateway 10.0.2.2 dns 10.0.2.3',
            'reply from 10.0.2.2: bytes=16',
            'localhost A 127.0.0.1',
            'UDP endpoints active/readable/connected',
            'default via 10.0.2.2 dev e1000e0',
            '10.0.2.2 at ',
            'dev e1000e0 retained-from-live-ARP',
            'ZigOs permanent network: device yes ping 1 dns 1 failures 0 clean yes',
            'network-state yes live-network yes persistent-storage yes canned-results no explicit-shutdown yes'
        )
    } else {
        $required += @(
            'serial COM1 online; framebuffer no; USB keyboard no; NVMe yes; AHCI no; e1000e no',
            'ifconfig: unavailable: e1000e was not initialized for this boot',
            'ping: unavailable: e1000e was not initialized for this boot',
            'dns: unavailable: e1000e was not initialized for this boot',
            'netstat: unavailable: e1000e was not initialized for this boot',
            'routes: unavailable: e1000e was not initialized for this boot',
            'arp: unavailable: e1000e was not initialized for this boot',
            'ZigOs permanent network: device no ping 0 dns 0 failures 0 clean yes',
            'network-state yes live-network no persistent-storage yes canned-results no explicit-shutdown yes'
        )
    }
    foreach ($marker in $required) {
        if (-not $serialText.Contains($marker)) { throw "Persistent runtime marker missing: $marker" }
    }
    if ($serialText.Contains('Persistent runtime failure:')) { throw 'The kernel reported a persistent runtime failure.' }
    if ($serialText.Contains([char]0)) { throw 'The permanent runtime emitted an unexpected NUL byte.' }
    $runtimeMarker = 'ZigOs persistent runtime online'
    $runtimeOffset = $serialText.IndexOf($runtimeMarker, [System.StringComparison]::Ordinal)
    if ($runtimeOffset -lt 0) { throw 'The permanent-runtime output boundary was not observed.' }
    $runtimeText = $serialText.Substring($runtimeOffset)
    foreach ($forbidden in @('192.0.2.42', 'deterministic-QEMU-path', 'reply from 192.0.2.1')) {
        if ($runtimeText.Contains($forbidden)) { throw "Canned network facade leaked into permanent runtime output: $forbidden" }
    }
    if (-not (Test-Path $debugLog)) { throw 'The persistent runtime produced no debugcon log.' }
    $debugText = Get-Content $debugLog -Raw
    if (-not $debugText.Contains('ZigOs x86-64 Capstone 16 verified:')) { throw 'The inherited Capstone 16 gate did not pass before the runtime.' }
    if (-not $debugText.Contains('ZigOs x86-64 persistent runtime verified:')) { throw 'The runtime shutdown marker was not mirrored to debugcon.' }
    if (-not $debugText.Contains('ZigOs x86-64 Capstone 18 verified:')) { throw 'The inherited Capstone 18 marker was not mirrored to debugcon.' }
    if (-not $debugText.Contains('ZigOs x86-64 Capstone 19 verified:')) { throw 'The Capstone 19 release marker was not mirrored to debugcon.' }

    Write-Host '=== ZigOs persistent COM1 session ==='
    Write-Host $serialText
    Write-Host 'Persistent x86-64 runtime session passed.'
}
finally {
    if ($client) { $client.Dispose() }
    if ($process) {
        $process.Refresh()
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue; $process.WaitForExit() }
        $process.Dispose()
    }
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
