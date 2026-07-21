[CmdletBinding()]
param(
    [ValidateRange(15, 300)]
    [int]$TimeoutSeconds = 40
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

function Invoke-LegacySession {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ReadyMarker,
        [Parameter(Mandatory)] [string]$FinalMarker,
        [Parameter(Mandatory)] [object[]]$CommandPlan
    )
    $debugPath = Join-Path $root "build\legacy-i686-$Name-debug.log"
    $serialPath = Join-Path $root "build\legacy-i686-$Name-serial.log"
    [IO.File]::WriteAllText($debugPath, '')
    [IO.File]::WriteAllText($serialPath, '')
    $arguments = @(
        '-m', '32M', '-machine', 'pc', '-cpu', 'qemu32', '-boot', 'c',
        '-drive', "file=$image,format=raw,if=ide,index=0,cache=unsafe",
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
    if (-not $process.Start()) { throw "Unable to start qemu-system-i386 for $Name." }
    $serialBuilder = [Text.StringBuilder]::new()
    $stdoutReadTask = $process.StandardOutput.ReadLineAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $nextCommand = 0
    $commandInFlight = $false
    $commandsSent = 0
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($stdoutReadTask.IsCompleted) {
                $line = $stdoutReadTask.Result
                if ($null -ne $line) {
                    [void]$serialBuilder.Append($line)
                    [void]$serialBuilder.Append("`r`n")
                    $stdoutReadTask = $process.StandardOutput.ReadLineAsync()
                } elseif ($process.HasExited) {
                    break
                }
            }
            $serialNow = $serialBuilder.ToString()
            if ($nextCommand -lt $CommandPlan.Count) {
                $canSend = if ($nextCommand -eq 0) {
                    $serialNow.Contains($ReadyMarker)
                } else {
                    $serialNow.Contains($CommandPlan[$nextCommand - 1].Expect)
                }
                if (-not $commandInFlight -and $canSend) {
                    $process.StandardInput.WriteLine($CommandPlan[$nextCommand].Command)
                    $process.StandardInput.Flush()
                    $commandInFlight = $true
                    $commandsSent += 1
                }
                if ($commandInFlight -and $serialNow.Contains($CommandPlan[$nextCommand].Expect)) {
                    $nextCommand += 1
                    $commandInFlight = $false
                }
            }
            if ($serialNow.Contains($FinalMarker)) { break }
            Start-Sleep -Milliseconds 10
        }
    } finally {
        try { $process.StandardInput.Close() } catch {}
        Start-Sleep -Milliseconds 100
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
    if ($commandsSent -ne $CommandPlan.Count) {
        throw "$Name sent $commandsSent of $($CommandPlan.Count) commands. QEMU stderr: $qemuError`nSERIAL:`n$serial`nDEBUG:`n$debug"
    }
    if (-not $serial.Contains($FinalMarker)) {
        throw "$Name did not reach final marker. QEMU stderr: $qemuError`nSERIAL:`n$serial`nDEBUG:`n$debug"
    }
    foreach ($step in $CommandPlan) {
        if (-not $serial.Contains($step.Expect)) { throw "$Name missing command result: $($step.Expect)" }
    }
    if ($serial.Contains('ZigOs i686 fatal exception') -or $serial.Contains(' failed: ')) {
        throw "$Name reported a kernel failure.`n$serial"
    }
    [PSCustomObject]@{ Serial = $serial; Debug = $debug; SerialPath = $serialPath; DebugPath = $debugPath }
}

$firstReady = 'ZigOs i686 Capstone 9 shell ready: commands help ls mem ticks disk hash FILE stat FILE run FILE wait PID ps exit mode first'
$firstFinal = 'ZigOs i686 Capstone 9 first session verified: goals 0x0000001A new-goals 0x00000010 root-files 0x00000009 processes 0x00000007 waits 0x00000001 creates 0x00000001 truncates 0x00000001 writes 0x00000002 seeks 0x00000001 allocations 0x00000002 notes 0x000002D0 hash 0xC6181D2F chain 0x0000000E->0x0000000F fault-contained yes descriptors-closed yes commands 0x0000000D'
$firstPlan = @(
    @{ Command = 'help'; Expect = 'commands: help ls mem ticks disk hash FILE stat FILE run FILE wait PID ps exit' },
    @{ Command = 'ls'; Expect = 'WRITER.ELF 0x000005D0 cluster 0x0000000B' },
    @{ Command = 'mem'; Expect = 'frames-free 0x' },
    @{ Command = 'ticks'; Expect = 'PIT-Hz 0x00000064' },
    @{ Command = 'disk'; Expect = 'FAT12 writable yes root-files 0x00000008 BIG.TXT-bytes 0x00000514 WRITER.ELF-bytes 0x000005D0 persistent-notes no' },
    @{ Command = 'hash BIG.TXT'; Expect = 'hash BIG.TXT bytes 0x00000514 fnv1a32 0xE5D120DF' },
    @{ Command = 'run INIT.ELF'; Expect = 'process PID 0x00000004 INIT.ELF exited 0x00000033 syscalls 0x00000003' },
    @{ Command = 'run CAT.ELF'; Expect = 'process PID 0x00000005 CAT.ELF exited 0x00000044 syscalls 0x00000005' },
    @{ Command = 'run WRITER.ELF'; Expect = 'process PID 0x00000006 WRITER.ELF exited 0x00000055 syscalls 0x00000009 wrote 0x000002D0 readback 0x000002BC notes-hash 0xC6181D2F chain 0x0000000E->0x0000000F' },
    @{ Command = 'stat NOTES.TXT'; Expect = 'stat NOTES.TXT bytes 0x000002D0 first-cluster 0x0000000E clusters 0x00000002' },
    @{ Command = 'wait 6'; Expect = 'wait PID 0x00000006 exit 0x00000055 reaped yes' },
    @{ Command = 'run FAULT.ELF'; Expect = 'process PID 0x00000007 FAULT.ELF faulted vector 0x0000000E address 0x00800000 contained yes exit 0x0000008E' },
    @{ Command = 'ps'; Expect = 'PID 0x00000007 PPID 0x00000000 FAULTED vector 0x0000000E address 0x00800000 exit 0x0000008E FAULT.ELF waited no' },
    @{ Command = 'exit'; Expect = $firstFinal }
)
$first = Invoke-LegacySession -Name 'first' -ReadyMarker $firstReady -FinalMarker $firstFinal -CommandPlan $firstPlan

$python = Get-Command python -ErrorAction Stop | Select-Object -ExpandProperty Source
& $python (Join-Path $PSScriptRoot 'verify-legacy-persistence.py') --image $image
if ($LASTEXITCODE -ne 0) { throw 'Offline persistent FAT12 verification failed after first boot.' }
$mutatedHash = (Get-FileHash $image -Algorithm SHA256).Hash

$secondReady = 'ZigOs i686 Capstone 9 shell ready: commands help ls mem ticks disk hash FILE stat FILE run FILE wait PID ps exit mode persistence'
$secondFinal = 'ZigOs i686 Capstone 9 persistence session verified: goals 0x0000001A new-goals 0x00000010 root-files 0x00000009 notes 0x000002D0 hash 0xC6181D2F chain 0x0000000E->0x0000000F writes 0x00000000 allocations 0x00000000 descriptors-closed yes commands 0x00000003'
$secondPlan = @(
    @{ Command = 'ls'; Expect = 'NOTES.TXT 0x000002D0 cluster 0x0000000E' },
    @{ Command = 'hash NOTES.TXT'; Expect = 'hash NOTES.TXT bytes 0x000002D0 fnv1a32 0xC6181D2F' },
    @{ Command = 'stat NOTES.TXT'; Expect = 'stat NOTES.TXT bytes 0x000002D0 first-cluster 0x0000000E clusters 0x00000002' },
    @{ Command = 'exit'; Expect = $secondFinal }
)
$second = Invoke-LegacySession -Name 'persistence' -ReadyMarker $secondReady -FinalMarker $secondFinal -CommandPlan $secondPlan
$afterSecondHash = (Get-FileHash $image -Algorithm SHA256).Hash
if ($afterSecondHash -ne $mutatedHash) { throw 'Read-only persistence boot changed the disk image.' }

$baseMarkers = @(
    'ZigOs BIOS stage1 kernel verified: chunked-EDD yes',
    'ZigOs i686 runtime verified:',
    'ZigOs i686 exceptions verified:',
    'ZigOs i686 interrupts verified:',
    'ZigOs i686 frame allocator verified:',
    'ZigOs i686 paging verified:',
    'ZigOs i686 heap verified:',
    'ZigOs i686 ATA verified:',
    'ZigOs i686 FAT12 verified:',
    'ZigOs i686 scheduler verified:',
    'ZigOs i686 ring3 verified:',
    'ZigOs i686 syscalls verified:',
    'ZigOs i686 ELF verified:',
    'ZigOs i686 writable VFS ready:',
    'ZigOs i686 user scheduler verified: disk-ELF tasks SPINA.ELF/SPINB.ELF'
)
foreach ($marker in $baseMarkers) {
    if (-not $first.Debug.Contains($marker)) { throw "First boot missing regression marker: $marker" }
    if (-not $second.Debug.Contains($marker)) { throw "Persistence boot missing regression marker: $marker" }
}

Write-Host '=== CAPSTONE 9 FIRST SESSION ==='
Write-Host $first.Serial.Trim()
Write-Host '=== CAPSTONE 9 PERSISTENCE SESSION ==='
Write-Host $second.Serial.Trim()
Write-Host "Persistent image SHA256: $mutatedHash"
Write-Host 'Legacy BIOS i686 Capstone 9 two-boot test passed.'
