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
$mutex = [System.Threading.Mutex]::new($false, 'Local\ZigOsQemuTestHarness')
$acquired = $false
$process = $null
$client = $null
try {
    try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(30)) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'The shared ZigOs QEMU harness remained busy for 30 seconds.' }

    if (-not (Test-Path $efiImage)) {
        & (Join-Path $PSScriptRoot 'build.ps1') -Clean
        if ($LASTEXITCODE -ne 0) { throw 'The x86-64 build failed.' }
    }

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
        $arguments += @('-netdev', 'user,id=net0,restrict=on', '-device', 'e1000e,netdev=net0,mac=52:54:00:12:34:56')
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

    $commands = @(
        'pwd',
        'ls /',
        'mkdir /home/root/demo',
        'cd /home/root/demo',
        'pwd',
        'write note.txt persistent runtime',
        'cat note.txt',
        'echo alpha beta gamma | wc',
        'echo alpha | grep alpha > match.txt',
        'cat match.txt',
        'stat note.txt',
        'mount',
        'df',
        'elf /boot/service-user.elf',
        'spawn worker 20',
        'ps',
        'sleep 25',
        'jobs',
        'wait 3',
        'crash bad 14',
        'wait 4',
        'devices',
        'ifconfig',
        'fsck',
        'sync',
        'history',
        'shutdown'
    )
    foreach ($command in $commands) {
        Send-SerialLine $command
        if ($command -like 'sleep *') { Start-Sleep -Milliseconds 600; Read-SerialAvailable }
    }

    $shutdownObserved = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
        $text = Current-SerialText
        if ($text.Contains('ZigOs x86-64 Capstone 17 verified:')) {
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
        '1 3 18',
        'alpha',
        'kind file size 19',
        'ramfs on / type ramfs (rw)',
        'ELF64 entry 0x8000100000 segments 2 bytes 10240',
        '[3] started worker',
        'PID PPID STATE',
        'sleep complete',
        'PID 3 status 0x0 state zombie',
        'contained fault in PID 4 vector 14',
        'PID 4 status 0x8000000E state faulted',
        'serial COM1 online',
        'fsck ramfs: clean',
        'sync complete:',
        'ZigOs persistent VFS:',
        'ZigOs persistent processes:',
        'loop permanent shell yes navigation yes files yes processes yes network-diagnostics yes explicit-shutdown yes',
        'ZigOs x86-64 Capstone 17 verified: goals 0x000001B1 new-goals 0x00000060 runtime yes vfs yes process-table yes shell yes portable-build yes ci-matrix yes'
    )
    foreach ($marker in $required) {
        if (-not $serialText.Contains($marker)) { throw "Persistent runtime marker missing: $marker" }
    }
    if ($serialText.Contains('Persistent runtime failure:')) { throw 'The kernel reported a persistent runtime failure.' }
    if (-not (Test-Path $debugLog)) { throw 'The persistent runtime produced no debugcon log.' }
    $debugText = Get-Content $debugLog -Raw
    if (-not $debugText.Contains('ZigOs x86-64 Capstone 16 verified:')) { throw 'The inherited Capstone 16 gate did not pass before the runtime.' }
    if (-not $debugText.Contains('ZigOs x86-64 persistent runtime verified:')) { throw 'The runtime shutdown marker was not mirrored to debugcon.' }
    if (-not $debugText.Contains('ZigOs x86-64 Capstone 17 verified:')) { throw 'The Capstone 17 release marker was not mirrored to debugcon.' }

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
