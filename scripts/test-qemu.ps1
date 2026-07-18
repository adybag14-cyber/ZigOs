[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 60,
    [ValidateRange(1, 64)]
    [int]$CpuCount = 4,
    [switch]$NvmeOnly,
    [switch]$NoUsbKeyboard,
    [switch]$UsbMouseOnly,
    [switch]$NoGraphics,
    [switch]$LegacyPci,
    [switch]$LegacyAhci,
    [switch]$Nvme4k,
    [switch]$NoPs2,
    [switch]$NoHpet,
    [switch]$SparseApicIds,
    [switch]$NoX2Apic,
    [switch]$HighApicId,
    [ValidateRange(0, 900)]
    [int]$HarnessWaitSeconds = 0,
    [switch]$Network
)

$ErrorActionPreference = 'Stop'
$testMutex = [System.Threading.Mutex]::new($false, 'Local\ZigOsQemuTestHarness')
$testMutexAcquired = $false
try {
    try {
        $testMutexAcquired = $testMutex.WaitOne([TimeSpan]::FromSeconds($HarnessWaitSeconds))
    } catch [System.Threading.AbandonedMutexException] {
        $testMutexAcquired = $true
    }
    if (-not $testMutexAcquired) {
        throw "Another ZigOs QEMU test already owns the shared harness artifacts. Refusing to queue another launcher; pass -HarnessWaitSeconds N only when an intentional wait is required."
    }

if ($LegacyAhci) { $LegacyPci = $true }
$repoRoot = Split-Path -Parent $PSScriptRoot
$efiRoot = Join-Path $repoRoot 'zig-out'
$efiImage = Join-Path $efiRoot 'EFI\BOOT\BOOTX64.EFI'
$buildDir = Join-Path $repoRoot 'build'
$debugLog = Join-Path $repoRoot 'qemu-debug.log'
$serialLog = Join-Path $repoRoot 'qemu-serial.log'
$qemuStdout = Join-Path $repoRoot 'qemu-stdout.log'
$qemuStderr = Join-Path $repoRoot 'qemu-stderr.log'
$nvmeImage = Join-Path $buildDir 'nvme-test.img'
$nvmeMetadataPath = Join-Path $buildDir 'nvme-test.json'

if (-not (Test-Path $efiImage)) {
    & (Join-Path $PSScriptRoot 'build.ps1')
}

$qemuCandidates = @(
    (Get-Command qemu-system-x86_64 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    'C:\Program Files\qemu\qemu-system-x86_64.exe'
) | Where-Object { $_ -and (Test-Path $_) }
$qemu = $qemuCandidates | Select-Object -First 1
if (-not $qemu) {
    throw 'qemu-system-x86_64 was not found.'
}
$repoRootSlash = $repoRoot.Replace('\', '/')
$staleProcesses = @(Get-CimInstance Win32_Process | Where-Object {
    if ($_.ProcessId -eq $PID -or [string]::IsNullOrWhiteSpace($_.CommandLine)) { return $false }
    $ownedByRepo = $_.CommandLine.IndexOf($repoRoot, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $_.CommandLine.IndexOf($repoRootSlash, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    if (-not $ownedByRepo) { return $false }
    if ($_.Name -eq 'qemu-system-x86_64.exe') { return $true }
    return $_.Name -in @('python.exe', 'pythonw.exe', 'py.exe') -and
        $_.CommandLine -match 'create-nvme-test-image\.py'
})
foreach ($staleProcess in $staleProcesses) {
    Write-Warning "Terminating stale ZigOs-owned $($staleProcess.Name) process $($staleProcess.ProcessId) before using shared test artifacts."
    Stop-Process -Id $staleProcess.ProcessId -Force -ErrorAction SilentlyContinue
}
if ($staleProcesses.Count -ne 0) {
    $cleanupDeadline = (Get-Date).AddSeconds(5)
    do {
        $remainingStale = @($staleProcesses | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
        if ($remainingStale.Count -eq 0) { break }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $cleanupDeadline)
    if ($remainingStale.Count -ne 0) {
        throw "Unable to terminate $($remainingStale.Count) stale ZigOs-owned process(es)."
    }
}

$shareDir = Join-Path (Split-Path -Parent $qemu) 'share'
$codeCandidates = @(
    (Join-Path $shareDir 'edk2-x86_64-code.fd'),
    (Join-Path $shareDir 'edk2-x86_64-secure-code.fd'),
    (Join-Path $shareDir 'OVMF_CODE.fd')
)
$varsCandidates = @(
    (Join-Path $shareDir 'edk2-i386-vars.fd'),
    (Join-Path $shareDir 'OVMF_VARS.fd')
)
$codeSource = $codeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$varsSource = $varsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $codeSource -or -not $varsSource) {
    throw 'No compatible split OVMF/EDK2 code and vars images were found.'
}

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$tftpRoot = Join-Path $buildDir 'tftp-root'
$tftpFile = Join-Path $tftpRoot 'zigos.bin'
if ($Network) {
    New-Item -ItemType Directory -Force -Path $tftpRoot | Out-Null
    $tftpBytes = [byte[]]::new(2304)
    for ($index = 0; $index -lt $tftpBytes.Length; $index++) {
        $tftpBytes[$index] = [byte](($index * 37 + 11) -band 0xFF)
    }
    [System.IO.File]::WriteAllBytes($tftpFile, $tftpBytes)
    $tftpHash = (Get-FileHash -Path $tftpFile -Algorithm SHA256).Hash
    if ($tftpBytes.Length -ne 2304 -or $tftpHash -ne '03652909284ACDFA888C1815EFC062536C671574EB7761413F6E2F2385F5F822') {
        throw "The deterministic multi-block TFTP fixture was invalid: $($tftpBytes.Length) bytes, SHA-256 $tftpHash."
    }
}
$codeImage = Join-Path $buildDir 'ovmf-code.fd'
$varsImage = Join-Path $buildDir 'ovmf-vars.fd'
Copy-Item $codeSource $codeImage -Force
Copy-Item $varsSource $varsImage -Force

Remove-Item $debugLog, $serialLog, $qemuStdout, $qemuStderr -Force -ErrorAction SilentlyContinue
$fatPath = $efiRoot.Replace('\', '/')
$nvmeBlockSize = if ($Nvme4k) { 4096 } else { 512 }
$nvmeBuilder = Join-Path $PSScriptRoot 'create-nvme-test-image.py'
& python $nvmeBuilder --output $nvmeImage --efi $efiImage --block-size $nvmeBlockSize --metadata $nvmeMetadataPath | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $nvmeMetadataPath)) {
    throw "The deterministic NVMe test image builder failed for block size $nvmeBlockSize."
}
$nvmeMetadata = Get-Content $nvmeMetadataPath -Raw | ConvertFrom-Json
$nvmePath = $nvmeImage.Replace('\', '/')
$codePath = $codeImage.Replace('\', '/')
$varsPath = $varsImage.Replace('\', '/')
$debugPath = $debugLog.Replace('\', '/')
$serialPath = $serialLog.Replace('\', '/')
$tftpPath = $tftpRoot.Replace('\', '/')

$monitorListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$monitorListener.Start()
$monitorPort = ([System.Net.IPEndPoint]$monitorListener.LocalEndpoint).Port
$monitorListener.Stop()
$monitorEndpoint = "tcp:127.0.0.1:$monitorPort,server=on,wait=off"

function Send-QemuMonitorCommands {
    param(
        [Parameter(Mandatory)]
        [string[]]$Commands,
        [int]$DelayMilliseconds = 180
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $client.Connect('127.0.0.1', $monitorPort)
            $stream = $client.GetStream()
            $writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::ASCII)
            $writer.NewLine = "`n"
            $writer.AutoFlush = $true

            # Give HMP time to publish its greeting/prompt before the first command.
            Start-Sleep -Milliseconds 150
            foreach ($command in $Commands) {
                $writer.WriteLine($command)
                Start-Sleep -Milliseconds $DelayMilliseconds
            }
            Start-Sleep -Milliseconds 250
            $writer.Dispose()
            $client.Dispose()
            return
        }
        catch {
            $lastError = $_
            $client.Dispose()
            Start-Sleep -Milliseconds 150
        }
    }
    throw "QEMU monitor command delivery failed after 8 attempts: $lastError"
}

$machineType = if ($LegacyPci) { 'pc' } else { 'q35' }
if ($SparseApicIds) {
    if ($LegacyPci) { throw '-SparseApicIds is currently supported only with the q35 test machine.' }
    if ($CpuCount -ne 4) { throw '-SparseApicIds requires -CpuCount 4.' }
}
if ($HighApicId) {
    if ($LegacyPci) { throw '-HighApicId is currently supported only with the q35 test machine.' }
    if ($CpuCount -ne 4) { throw '-HighApicId requires -CpuCount 4.' }
    if ($SparseApicIds) { throw '-HighApicId and -SparseApicIds are separate topology matrices.' }
    if ($NoX2Apic) { throw '-HighApicId requires x2APIC support.' }
}
if ($LegacyAhci) {
    if ($NvmeOnly) { throw '-LegacyAhci requires the SATA FAT disk.' }
    if ($NoPs2 -or $NoHpet) { throw '-LegacyAhci uses the fixed i440FX firmware topology.' }
}
$machineOptions = @()
if ($NoPs2) {
    if ($LegacyPci) { throw '-NoPs2 is currently supported only with the q35 test machine.' }
    $machineOptions += 'i8042=off'
}
if ($NoHpet) {
    if ($LegacyPci) { throw '-NoHpet is currently supported only with the q35 test machine.' }
    $machineOptions += 'hpet=off'
}
$machineArgument = if ($machineOptions.Count -eq 0) {
    $machineType
} else {
    "$machineType,$($machineOptions -join ',')"
}
$smpArgument = if ($HighApicId) {
    'cpus=1,maxcpus=257,sockets=257,cores=1,threads=1'
} elseif ($SparseApicIds) {
    'cpus=4,maxcpus=6,sockets=2,cores=3,threads=1'
} else {
    [string]$CpuCount
}
$cpuArgument = if ($NoX2Apic) { 'max,-x2apic' } else { 'max' }
$arguments = @(
    '-machine', $machineArgument,
    '-m', '256M',
    '-cpu', $cpuArgument,
    '-smp', $smpArgument
)
if ($HighApicId) {
    $arguments += @(
        '-device', 'max-x86_64-cpu,apic-id=1,socket-id=1,core-id=0,thread-id=0',
        '-device', 'max-x86_64-cpu,apic-id=2,socket-id=2,core-id=0,thread-id=0',
        '-device', 'max-x86_64-cpu,apic-id=256,socket-id=256,core-id=0,thread-id=0'
    )
}
$arguments += @(
    '-device', 'qemu-xhci,id=xhci',
    '-drive', "file=$nvmePath,if=none,id=nvme0,format=raw,cache=unsafe",
    '-device', "nvme,drive=nvme0,serial=ZIGOSNVME,logical_block_size=$nvmeBlockSize,physical_block_size=$nvmeBlockSize",
    '-drive', "if=pflash,format=raw,unit=0,readonly=on,file=$codePath",
    '-drive', "if=pflash,format=raw,unit=1,file=$varsPath",
    '-debugcon', "file:$debugPath",
    '-global', 'isa-debugcon.iobase=0xe9',
    '-display', 'none',
    '-serial', "file:$serialPath",
    '-monitor', $monitorEndpoint,
    '-no-reboot'
)
if ($Network) {
    $arguments += @(
        '-netdev', "user,id=net0,restrict=on,tftp=$tftpPath",
        '-device', 'e1000e,netdev=net0,mac=52:54:00:12:34:56'
    )
} else {
    $arguments += @('-net', 'none')
}
if (-not $NvmeOnly) {
    if ($LegacyAhci) {
        $arguments += @(
            '-device', 'ich9-ahci,id=ahci',
            '-drive', "if=none,id=sata0,format=raw,file=fat:rw:$fatPath",
            '-device', 'ide-hd,drive=sata0,bus=ahci.0'
        )
    } else {
        $arguments += @('-drive', "format=raw,file=fat:rw:$fatPath")
    }
}
if ($UsbMouseOnly) {
    $arguments += @('-device', 'usb-mouse,bus=xhci.0,port=1')
} elseif (-not $NoUsbKeyboard) {
    $arguments += @('-device', 'usb-kbd,bus=xhci.0,port=1')
}
if ($NoGraphics) {
    $arguments += @('-vga', 'none')
}

Write-Host "Booting ZigOs in QEMU with $codeSource (machine: $machineType, CPU: $cpuArgument, CPUs: $CpuCount, SMP: $smpArgument, NVMe-only: $NvmeOnly, no USB keyboard: $NoUsbKeyboard, mouse-only: $UsbMouseOnly, no graphics: $NoGraphics, legacy PCI: $LegacyPci, legacy AHCI: $LegacyAhci, NVMe block size: $nvmeBlockSize, no PS/2: $NoPs2, no HPET: $NoHpet, sparse APIC IDs: $SparseApicIds, no x2APIC: $NoX2Apic, high APIC ID: $HighApicId, network: $Network)"
$process = Start-Process -FilePath $qemu -ArgumentList $arguments -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr -PassThru -WindowStyle Hidden
try {
    $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
    Write-Host "QEMU process $($process.Id) running at below-normal priority."
} catch {
    Write-Warning "Could not lower QEMU process priority: $($_.Exception.Message)"
}
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$marker = 'ZigOs boot sequence complete'
$captured = $false
$keyInjected = $false
$inputMarker = 'HID input transfer armed:'
$shellInjected = $false
$shellMarker = 'ZigOs shell input armed:'

try {
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 25
        if (Test-Path $debugLog) {
            $text = Get-Content $debugLog -Raw -ErrorAction SilentlyContinue
            if (-not $NoUsbKeyboard -and -not $UsbMouseOnly -and -not $NoGraphics -and $text -and -not $keyInjected -and $text.Contains($inputMarker)) {
                Send-QemuMonitorCommands -Commands @('sendkey a 500') -DelayMilliseconds 300
                $keyInjected = $true
            }
            if (-not $NoUsbKeyboard -and -not $UsbMouseOnly -and -not $NoGraphics -and $text -and $keyInjected -and -not $shellInjected -and $text.Contains($shellMarker)) {
                $shellKeys = @('h', 'e', 'l', 'x', 'backspace', 'p', 'ret', 'c', 'p', 'u', 'ret', 'm', 'e', 'm', 'ret', 's', 'c', 'r', 'o', 'l', 'l', 'ret', 'c', 'l', 'e', 'a', 'r', 'ret', 'h', 'e', 'l', 'p', 'ret', 'n', 'o', 'p', 'e', 'ret', 'ret', 'h', 'e', 'l', 'p', 'ret', 'up', 'ret')
                Send-QemuMonitorCommands -Commands @($shellKeys | ForEach-Object { "sendkey $_ 120" }) -DelayMilliseconds 180
                $shellInjected = $true
            }
            if ($text -and $text.Contains($marker)) {
                $captured = $true
                break
            }
        }
        $process.Refresh()
        if ($process.HasExited) { break }
    }
}
finally {
    $process.Refresh()
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
    $process.Dispose()
}

if (-not (Test-Path $debugLog)) {
    $errorText = if (Test-Path $qemuStderr) { Get-Content $qemuStderr -Raw } else { '' }
    throw "QEMU produced no debug output. $errorText"
}

$output = Get-Content $debugLog -Raw
Write-Host '=== ZigOs QEMU debug output ==='
Write-Host $output

if (-not $captured) {
    $errorText = if (Test-Path $qemuStderr) { Get-Content $qemuStderr -Raw } else { '' }
    throw "ZigOs boot marker was not captured within $TimeoutSeconds seconds. $errorText"
}
if (-not $output.Contains('CPU vendor:')) {
    throw 'The assembly CPUID result was not observed.'
}
if (-not $output.Contains('CR0 = 0x')) {
    throw 'The assembly control-register result was not observed.'
}
if (-not $output.Contains('ExitBootServices succeeded.')) {
    throw 'The firmware handoff did not complete.'
}
if (-not $output.Contains('ZigOs now owns execution without UEFI boot services.')) {
    throw 'No post-UEFI kernel execution marker was observed.'
}
if (([regex]::Matches($output, 'Kernel stack: 0x')).Count -lt 2) {
    throw 'The ZigOs-owned stack was not observed on both sides of the handoff.'
}
if (-not $output.Contains('AP trampoline reservation: 0x')) {
    throw 'The low-memory AP trampoline reservation marker was not observed.'
}
if (-not [regex]::IsMatch($output, 'Memory layout normalized: [1-9][0-9]* descriptors -> [1-9][0-9]* regions; usable [1-9][0-9]* bytes in [1-9][0-9]* descriptors, reclaimable [0-9]+, runtime [0-9]+, ACPI NVS [0-9]+, MMIO [0-9]+, reserved [0-9]+ bytes')) {
    throw 'The normalized UEFI memory-layout report was not observed.'
}
if (-not $output.Contains('Protected memory verified: kernel code, kernel stack, UEFI memory map, AP trampoline, ACPI RSDP and framebuffer excluded from allocator')) {
    throw 'The protected-range exclusion report was not observed.'
}
if (-not $output.Contains('Physical frame allocator verified:')) {
    throw 'The physical frame allocator verification marker was not observed.'
}
if (-not $output.Contains('ZigOs page tables active:')) {
    throw 'The ZigOs-owned CR3 marker was not observed.'
}
if (-not $output.Contains('Post-switch frame verified at 0x')) {
    throw 'The post-page-table-switch memory probe was not observed.'
}
if (-not $output.Contains('Higher-half data alias verified:')) {
    throw 'The higher-half data-alias marker was not observed.'
}
if (-not $output.Contains('Higher-half code execution verified:')) {
    throw 'The higher-half code-execution marker was not observed.'
}
if (-not $output.Contains('Higher-half mirror base 0xFFFF800000000000')) {
    throw 'The canonical higher-half PML4 mirror marker was not observed.'
}
if (-not $output.Contains('Descriptor tables active:')) {
    throw 'The ZigOs GDT/TSS/IDT marker was not observed.'
}
if (-not $output.Contains('Segments verified: CS=0x0008, TR=0x0018')) {
    throw 'The expected ZigOs code segment and task register were not observed.'
}
if (-not $output.Contains('Breakpoint interrupt handled on IST1')) {
    throw 'The IST1 breakpoint round trip was not observed.'
}
if (-not $output.Contains('CPU exception coverage active: vectors 0-31')) {
    throw 'The full architectural exception-vector installation marker was not observed.'
}
if (-not $output.Contains('Invalid-opcode exception recovered: vector 6')) {
    throw 'The controlled UD2 exception recovery marker was not observed.'
}
if (-not [regex]::IsMatch($output, 'Symbolized exception stack trace: #0 zigos_trigger_ud2\+0x[0-9A-F]{16} <- #1 exceptions\.traceProbeLevel3\+0x[0-9A-F]{16} <- #2 exceptions\.traceProbeLevel2\+0x[0-9A-F]{16} <- #3 exceptions\.traceProbeLevel1\+0x[0-9A-F]{16}; [4-9][0-9]*/[4-9][0-9]* frames symbolized')) {
    throw 'The guarded RBP unwind and symbol-resolution proof was not observed.'
}
if (-not $output.Contains('ACPI verified: revision')) {
    throw 'The checksum-validated ACPI root walk was not observed.'
}
if (-not $output.Contains('MADT topology:')) {
    throw 'The validated MADT topology marker was not observed.'
}
$expectedMadtProcessorCount = $CpuCount
$expectedProcessorRecords = if ($HighApicId) {
    @('0(xAPIC)', '1(xAPIC)', '2(xAPIC)', '256(x2)')
} elseif ($SparseApicIds) {
    @('0(xAPIC)', '1(xAPIC)', '2(xAPIC)', '4(xAPIC)')
} else {
    @(0..($CpuCount - 1) | ForEach-Object { "$_(xAPIC)" })
}
if (-not $output.Contains("MADT topology: $expectedMadtProcessorCount processors")) {
    throw "The expected $expectedMadtProcessorCount-processor MADT topology marker was not observed."
}
$expectedProcessorIds = 'MADT processor IDs:'
foreach ($processorRecord in $expectedProcessorRecords) {
    $expectedProcessorIds += " $processorRecord"
}
if (-not $output.Contains($expectedProcessorIds)) {
    throw "The expected retained MADT processor records were not observed: $($expectedProcessorRecords -join ',')."
}
$expectedActiveAps = [Math]::Min(3, [Math]::Max(0, $CpuCount - 1))
$expectedLegacyIrqTarget = if ($expectedActiveAps -gt 0) { 1 } else { 0 }
$expectedParkedAps = [Math]::Max(0, $expectedMadtProcessorCount - 1 - $expectedActiveAps)
if (-not [regex]::IsMatch($output, "SMP startup: BSP APIC 0, MADT processors $expectedMadtProcessorCount, AP targets $expectedActiveAps, discovered APs $($expectedMadtProcessorCount - 1), parked APs $expectedParkedAps, trampoline 0x[0-9A-F]{16}, SIPI vector 0x[0-9A-F]{2}")) {
    throw 'The selected-versus-parked SMP topology marker was not observed.'
}
if (-not $output.Contains('Local APIC enabled:')) {
    throw 'The local APIC enablement marker was not observed.'
}
if ($NoX2Apic) {
    if (-not $output.Contains('Local APIC enabled: xAPIC ID 0')) {
        throw 'The CPUID-disabled x2APIC matrix did not retain xAPIC mode.'
    }
    if ($output.Contains('Local APIC enabled: x2APIC')) {
        throw 'x2APIC unexpectedly enabled while the CPUID feature was disabled.'
    }
} else {
    if (-not $output.Contains('Local APIC enabled: x2APIC ID 0')) {
        throw 'The default QEMU CPU did not enter x2APIC mode.'
    }
}
if ($SparseApicIds) {
    if (-not $output.Contains('Local APIC enabled: x2APIC ID 0')) {
        throw 'The sparse-APIC-ID matrix did not enter x2APIC mode.'
    }
    foreach ($activeApicId in @(1, 2, 4)) {
        if (-not $output.Contains("AP online: expected APIC $activeApicId, actual APIC $activeApicId, state 2")) {
            throw "Sparse APIC ID $activeApicId did not start and validate."
        }
    }
    if ($output.Contains('AP online: expected APIC 3,')) {
        throw 'The sparse topology unexpectedly collapsed APIC ID 4 into contiguous ID 3.'
    }
}
if ($HighApicId) {
    foreach ($activeApicId in @(1, 2, 256)) {
        if (-not $output.Contains("AP online: expected APIC $activeApicId, actual APIC $activeApicId, state 2")) {
            throw "High-width APIC ID $activeApicId did not start and validate."
        }
        if (-not $output.Contains("AP targeted IPI: APIC $activeApicId, vector 0x42")) {
            throw "High-width APIC ID $activeApicId did not receive a targeted fixed IPI."
        }
    }
    if (-not $output.Contains('AP work stealing: APIC 256 executed 2 stolen jobs')) {
        throw 'APIC ID 256 did not participate in slot-indexed work stealing.'
    }
}
if (-not $output.Contains('APIC SVR verified at 0x')) {
    throw 'The local APIC SVR verification marker was not observed.'
}
if (-not $output.Contains('IOAPIC initialized:')) {
    throw 'The IOAPIC discovery marker was not observed.'
}
if (-not $output.Contains('IOAPIC redirection table fully masked:')) {
    throw 'The IOAPIC redirection-mask verification marker was not observed.'
}
$expectedLegacyTargetKind = if ($expectedActiveAps -gt 0) { 'application processor' } else { 'bootstrap processor' }
if (-not $output.Contains("Legacy IRQ target selected: APIC $expectedLegacyIrqTarget ($expectedLegacyTargetKind)")) {
    throw 'The expected routable legacy-IRQ destination was not selected.'
}
if (-not [regex]::IsMatch($output, "External IRQ routed: ISA IRQ 0 -> GSI 2 -> vector 0x44, target APIC $expectedLegacyIrqTarget, PIT divisor [1-9][0-9]*, count 1, active-high, edge, remasked after EOI")) {
    throw 'The MADT/IOAPIC/PIT external IRQ0 round trip was not observed.'
}
if ($NoPs2) {
    if (-not $output.Contains('i8042/PS2 controller unavailable; continuing without legacy keyboard input')) {
        throw 'The missing-i8042 fallback marker was not observed.'
    }
    if (-not $output.Contains('Legacy input ready: PS/2 keyboard no')) {
        throw 'The PS/2-unavailable readiness marker was not observed.'
    }
    if ($output.Contains('PS/2 keyboard IRQ verified:') -or $output.Contains('PS/2 event queue verified:')) {
        throw 'The PS/2 validation path unexpectedly ran with i8042 disabled.'
    }
} else {
    if (-not [regex]::IsMatch($output, "PS/2 keyboard IRQ verified: ISA IRQ 1 -> GSI 1 -> vector 0x45, make 0x1E, break 0x9E, count 2, command byte 0x[0-9A-F]{2}, target APIC $expectedLegacyIrqTarget, remasked and restored after EOI")) {
        throw 'The i8042/IOAPIC PS/2 keyboard IRQ and scan-code capture were not observed.'
    }
    if (-not $output.Contains("PS/2 event queue verified: #1 usage 0x04 pressed -> 'a'; #2 usage 0x04 released -> 'a'; dropped 0")) {
        throw 'The PS/2 make/break translation through the common keyboard queue was not observed.'
    }
    if (-not $output.Contains('Legacy input ready: PS/2 keyboard yes')) {
        throw 'The PS/2-available readiness marker was not observed.'
    }
}
if (-not [regex]::IsMatch($output, 'Continuous reference counter: source (HPET|ACPI PM timer), frequency [1-9][0-9]* Hz, bits (24|32|64), first/second/delta [0-9]+/[1-9][0-9]*/[1-9][0-9]*')) {
    throw 'The selected platform clock did not expose an advancing continuous counter.'
}
if ($NoHpet) {
    if (-not $output.Contains('HPET not present')) {
        throw 'The no-HPET ACPI topology marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'ACPI PM timer active: address 0x[0-9A-F]{16}, system I/O, frequency 3579545 Hz, (24|32)-bit counter')) {
        throw 'The ACPI PM timer continuous reference fallback marker was not observed.'
    }
    if ($output.Contains('HPET active:')) {
        throw 'HPET unexpectedly initialized while disabled.'
    }
    if (-not [regex]::IsMatch($output, 'APIC timer calibrated with ACPI PM timer: [1-9][0-9]* ticks/s, one-shot count [1-9][0-9]*')) {
        throw 'The ACPI-PM-timer-calibrated APIC timer rate was not observed.'
    }
} else {
    if (-not $output.Contains('HPET at 0x')) {
        throw 'The validated HPET table was not retained.'
    }
    if (-not [regex]::IsMatch($output, 'HPET active: base 0x[0-9A-F]{16}, period [1-9][0-9]* fs, timers [1-9][0-9]*, (32|64)-bit counter')) {
        throw 'The HPET capability and counter marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'APIC timer calibrated with HPET: [1-9][0-9]* ticks/s, one-shot count [1-9][0-9]*')) {
        throw 'The HPET-calibrated APIC timer rate was not observed.'
    }
}
if (-not $output.Contains('Maskable interrupt vector 0x0040 handled')) {
    throw 'The APIC timer interrupt round trip was not observed.'
}
$descriptorMatches = [regex]::Matches($output, 'AP private descriptors: GDT 0x[0-9A-F]+, TSS 0x[0-9A-F]+, IDT 0x[0-9A-F]+, CS 0x0008, TR 0x0018, checksum 0x(?!0000000000000000)[0-9A-F]{16}')
if ($descriptorMatches.Count -ne $expectedActiveAps) {
    throw "The expected $expectedActiveAps AP-private descriptor records were not observed."
}
$mailboxMatches = [regex]::Matches($output, 'AP mailbox complete: APIC [1-9][0-9]*, epoch 1, input 0x[0-9A-F]{16}, result 0x(?!0000000000000000)[0-9A-F]{16}')
if ($mailboxMatches.Count -ne $expectedActiveAps) {
    throw "The expected $expectedActiveAps AP mailbox completion records were not observed."
}
$runQueueMatches = [regex]::Matches($output, 'AP run queue complete: APIC [1-9][0-9]*, queued 4, completed 4, last sequence 4, checksum 0x(?!0000000000000000)[0-9A-F]{16}')
if ($runQueueMatches.Count -ne $expectedActiveAps) {
    throw "The expected $expectedActiveAps per-AP FIFO run-queue records were not observed."
}
if ($expectedActiveAps -eq 3) {
    $stealMatches = [regex]::Matches($output, 'AP work stealing: APIC [1-9][0-9]* executed 2 stolen jobs')
    if ($stealMatches.Count -ne 2) {
        throw 'Both idle application processors did not execute their deterministic steal quotas.'
    }
    if (-not [regex]::IsMatch($output, 'Work stealing complete: source APIC [1-9][0-9]*, jobs 8, owner 4, stolen 4, checksum 0x(?!0000000000000000)[0-9A-F]{16}')) {
        throw 'The deterministic multicore work-stealing verification marker was not observed.'
    }
} else {
    if (-not $output.Contains('Work stealing skipped: requires three selected application processors')) {
        throw 'The low-core-count work-stealing skip marker was not observed.'
    }
    if ($output.Contains('Work stealing complete:')) {
        throw 'Work stealing unexpectedly ran without three selected application processors.'
    }
}

if ($expectedActiveAps -eq 0) {
    if (-not $output.Contains('SMP validation skipped: uniprocessor topology; BSP APIC 0 remains the only active processor')) {
        throw 'The uniprocessor SMP fallback marker was not observed.'
    }
    if ([regex]::IsMatch($output, '^AP online:', [Text.RegularExpressions.RegexOptions]::Multiline)) {
        throw 'An application processor unexpectedly started in uniprocessor mode.'
    }
} else {
    $ipiWakeMatches = [regex]::Matches($output, 'AP targeted IPI: APIC [1-9][0-9]*, vector 0x42, wake 1, halts [2-9][0-9]*, checksum 0x(?!0000000000000000)[0-9A-F]{16}')
    if ($ipiWakeMatches.Count -ne $expectedActiveAps) {
        throw "The expected $expectedActiveAps AP targeted-IPI wake records were not observed."
    }
    if (-not $output.Contains("Targeted AP wakeups complete: vector 0x42, $expectedActiveAps/$expectedActiveAps APs woke from HLT and acknowledged EOI")) {
        throw 'The targeted AP IPI/HLT/EOI aggregate marker was not observed.'
    }
    $apTimerMatches = [regex]::Matches($output, 'AP local timer: APIC [1-9][0-9]*, vector 0x43, count [1-9][0-9]*, interrupts 1, epoch 1, halts [3-9][0-9]*')
    if ($apTimerMatches.Count -ne $expectedActiveAps) {
        throw "The expected $expectedActiveAps AP local-timer records were not observed."
    }
    if (-not [regex]::IsMatch($output, "Per-AP timers complete: vector 0x43, count [1-9][0-9]*, $expectedActiveAps/$expectedActiveAps APs woke autonomously from local timer interrupts")) {
        throw 'The per-AP autonomous local-timer aggregate marker was not observed.'
    }
    $tickSchedulerMatches = [regex]::Matches($output, 'AP tick scheduler: APIC [1-9][0-9]*, jobs 3, ticks 3, dispatches 3, halts [6-9][0-9]*, checksum 0x(?!0000000000000000)[0-9A-F]{16}')
    if ($tickSchedulerMatches.Count -ne $expectedActiveAps) {
        throw "The expected $expectedActiveAps per-AP tick-scheduler records were not observed."
    }
    if (-not [regex]::IsMatch($output, "Per-AP tick schedulers complete: jobs 3/core, quantum count [1-9][0-9]*, $expectedActiveAps/$expectedActiveAps APs dispatched exactly one job per timer tick")) {
        throw 'The aggregate per-AP tick-scheduler marker was not observed.'
    }
    $apTaskMatches = [regex]::Matches($output, 'AP local tasks: APIC [1-9][0-9]*, stacks 0x[0-9A-F]+/0x[0-9A-F]+, switches 13, yields 5/7, trace ABABABABABBB, canaries intact')
    if ($apTaskMatches.Count -ne $expectedActiveAps) {
        throw "The expected $expectedActiveAps AP local-task records were not observed."
    }
    $expectedContextSwitches = 13 * $expectedActiveAps
    if (-not $output.Contains("Per-AP task contexts complete: $expectedActiveAps/$expectedActiveAps APs, total context switches $expectedContextSwitches, trace ABABABABABBB on every core")) {
        throw 'The aggregate per-AP task-context verification marker was not observed.'
    }
    $syncWorkerMatches = [regex]::Matches($output, 'AP synchronization worker: APIC [1-9][0-9]*, worker [1-9][0-9]*, acquisitions 4096, barrier generation 1')
    if ($syncWorkerMatches.Count -ne $expectedActiveAps) {
        throw "The expected $expectedActiveAps AP ticket-lock/barrier records were not observed."
    }
    $expectedSyncParticipants = $expectedActiveAps + 1
    $expectedSyncIncrements = $expectedSyncParticipants * 4096
    if (-not [regex]::IsMatch($output, "SMP synchronization complete: $expectedSyncParticipants participants, $expectedSyncIncrements locked increments, tickets $expectedSyncIncrements/$expectedSyncIncrements, barrier generation 1, checksum 0x(?!0000000000000000)[0-9A-F]{16}")) {
        throw 'The topology-sized ticket-lock and barrier verification marker was not observed.'
    }
}
if (-not $output.Contains("SMP startup complete: $expectedActiveAps/$expectedActiveAps selected application processors online; $expectedParkedAps additional application processors left parked")) {
    throw 'The selected-AP startup and parked-CPU marker was not observed.'
}
if ($NoGraphics) {
    if (-not $output.Contains('GOP framebuffer: unavailable or BLT-only')) {
        throw 'UEFI did not report the expected missing GOP framebuffer.'
    }
    if (-not $output.Contains('GOP framebuffer unavailable; continuing with serial diagnostics only')) {
        throw 'The kernel serial-only GOP fallback marker was not observed.'
    }
    if ($output.Contains('Framebuffer terminal initialized:')) {
        throw 'A graphical terminal was unexpectedly initialized in no-graphics mode.'
    }
} else {
    if (-not [regex]::IsMatch($output, 'Framebuffer terminal initialized: 1280x800, cells 102x37, cursor row 3, column 7, writes 31, cursor visible, draws 6, erases 5, display checksum 0x7CF72F9AF061C761')) {
        throw 'The persistent graphical terminal was not initialized before PCI/xHCI discovery.'
    }
}
if ($LegacyPci) {
    if (-not $output.Contains('MCFG not present')) {
        throw 'The legacy machine unexpectedly exposed an ACPI MCFG table.'
    }
    if (-not $output.Contains('Legacy PCI configuration active: mechanism #1 ports 0x0CF8/0x0CFC, buses scanned 256')) {
        throw 'The legacy PCI configuration-mechanism #1 marker was not observed.'
    }
    if ($output.Contains('PCIe ECAM active:')) {
        throw 'ECAM was unexpectedly selected in legacy PCI mode.'
    }
} else {
    if (-not $output.Contains('PCIe ECAM active:')) {
        throw 'The PCIe MCFG/ECAM activation marker was not observed.'
    }
}
if (-not $output.Contains('PCI inventory:')) {
    throw 'The PCI function inventory marker was not observed.'
}
if (-not $output.Contains('PCI function ')) {
    throw 'No enumerated PCI function was printed.'
}
if ($Network) {
    if (-not [regex]::IsMatch($output, 'PCI function 0000:[0-9A-F]{2}:[0-9A-F]{2}\.[0-7] vendor 0x8086 device 0x10D3 class 02:00:00 header 0x00')) {
        throw 'The QEMU Intel 82574L PCI function was not enumerated.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e PCI capabilities: count [1-9][0-9]*, MSI \+0x[0-9A-F]{2}, MSI-X \+0x[0-9A-F]{2}')) {
        throw 'The e1000e MSI/MSI-X capability chain was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e MSI-X descriptor: vectors [1-9][0-9]*, table BAR [0-5] \+0x[0-9A-F]{16}, PBA BAR [0-5] \+0x[0-9A-F]{16}')) {
        throw 'The e1000e MSI-X table and PBA descriptor was not decoded.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e controller discovered at 0000:[0-9A-F]{2}:[0-9A-F]{2}\.[0-7], vendor 0x8086, device 0x10D3, BAR0 0x(?!0000000000000000)[0-9A-F]{16}, identity map 0x[0-9A-F]{16} \+ [1-9][0-9]* bytes using [0-9]+ new table page\(s\)')) {
        throw 'The e1000e BAR0 and MMIO mapping marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e MAC 52:54:00:12:34:56, link up, speed 1000 Mb/s, CTRL 0x[0-9A-F]{16}, STATUS 0x[0-9A-F]{16}, CTRL_EXT 0x[0-9A-F]{16}')) {
        throw 'The e1000e MAC/link/status registers were not validated.'
    }
    if (-not $output.Contains('Network interfaces ready: Intel 82574L yes')) {
        throw 'The e1000e network readiness marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e rings active: RX 0x[0-9A-F]{16}, TX 0x[0-9A-F]{16}, descriptors 8, TX buffer 0x[0-9A-F]{16}, RX buffer 0x[0-9A-F]{16}')) {
        throw 'The e1000e RX/TX DMA rings were not activated.'
    }
    if (-not [regex]::IsMatch($output, "e1000e MSI-X active: capability \+0xA0, table entry 0 at 0x[0-9A-F]{16}, vectors 5, vector 0x49, target APIC $expectedLegacyIrqTarget, control 0x[0-9A-F]{4}, mapping pages [0-9]+")) {
        throw 'The e1000e MSI-X vector was not programmed for the selected routable CPU.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e DHCP Discover transmitted: xid 0x000000005A49474F, 342 bytes, TX interrupts [1-9][0-9]*, cause 0x[0-9A-F]{16}')) {
        throw 'The DHCP Discover did not complete through TX DMA and MSI-X.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e DHCP Offer received: address 10\.0\.2\.15, server 10\.0\.2\.2, lease [1-9][0-9]* s, [3-9][0-9][0-9] bytes, RX interrupts [1-9][0-9]*, cause 0x[0-9A-F]{16}')) {
        throw 'The DHCP Offer was not received and validated.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e DHCP Request transmitted: address 10\.0\.2\.15, server 10\.0\.2\.2, 342 bytes, TX interrupts [1-9][0-9]*, cause 0x[0-9A-F]{16}')) {
        throw 'The DHCP Request did not complete through TX DMA and MSI-X.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e DHCP ACK received: address 10\.0\.2\.15, subnet 255\.255\.255\.0, router 10\.0\.2\.2 \(server fallback\), DNS absent, server 10\.0\.2\.2, lease [1-9][0-9]* s, TTL [1-9][0-9]*, UDP checksum (present|absent), [3-9][0-9][0-9] bytes, RX interrupts [1-9][0-9]*, cause 0x[0-9A-F]{16}')) {
        throw 'The DHCP ACK lease fields or UDP/IPv4 validation were not observed.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e ARP request transmitted: 10\.0\.2\.15 -> 10\.0\.2\.2, 60 bytes, TX interrupts [1-9][0-9]*, cause 0x[0-9A-F]{16}')) {
        throw 'The e1000e ARP request did not complete through TX DMA and MSI-X.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e ARP reply received: gateway MAC ([0-9A-F]{2}:){5}[0-9A-F]{2}, opcode 2, sender 10\.0\.2\.2, target 10\.0\.2\.15, [4-9][0-9] bytes, RX interrupts [1-9][0-9]*, cause 0x[0-9A-F]{16}')) {
        throw 'The e1000e RX ring did not receive and validate the QEMU gateway ARP reply.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e ICMP echo request transmitted: 10\.0\.2\.15 -> 10\.0\.2\.2, 60 bytes, identifier 0x5A49, sequence 1, TX interrupts [1-9][0-9]*, cause 0x[0-9A-F]{16}')) {
        throw 'The e1000e IPv4/ICMP echo request did not complete through TX DMA and MSI-X.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e ICMP echo reply received: 10\.0\.2\.2 -> 10\.0\.2\.15, [4-9][0-9] bytes, TTL [1-9][0-9]*, payload 16 bytes, RX interrupts [1-9][0-9]*, cause 0x[0-9A-F]{16}')) {
        throw 'The e1000e RX ring did not validate the IPv4 and ICMP checksums, echo identity, and payload.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e TFTP RRQ transmitted: zigos\.bin mode octet, 60 bytes, UDP 40000 -> 69, TX interrupts [1-9][0-9]*, cause 0x[0-9A-F]{16}')) {
        throw 'The TFTP read request did not complete through the reusable UDP builder and TX MSI-X.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e TFTP stream received: blocks 5, payload 2304 bytes, FNV-1a64 0x6175986CBBAB5125, frames 558/558/558/558/302, server port [1-9][0-9]*, TTL [1-9][0-9]*, UDP checksum (present|absent), final yes, RX interrupts [5-9][0-9]*, cause 0x[0-9A-F]{16}')) {
        throw 'The three-block TFTP DATA stream or cumulative fixture hash was not validated.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e TFTP ACK stream transmitted: blocks 1-5, frames 60/60/60/60/60, UDP 40000 -> [1-9][0-9]*, TX interrupts [5-9][0-9]*, wraps 1, tail 2, cause 0x[0-9A-F]{16}')) {
        throw 'The TFTP acknowledgement stream did not wrap and reuse TX descriptors 0-1.'
    }
    if (-not $output.Contains('e1000e RX ring recycled: descriptors 9, wraps 1, head 1, tail 0')) {
        throw 'The RX descriptor ring was not recycled through descriptor 7 and wrapped to descriptor 0.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e completion queues active: TX 10/10, RX 9/9, high-water [1-9][0-9]*/[1-9][0-9]*, overflow 0, pending TX 0x0000000000000000, RX 0x00000000000000FF')) {
        throw 'The e1000e ISR-to-kernel completion queues did not deliver every TX/RX descriptor exactly once.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e persistent queue owner verified: TX descriptor 2 -> cursor 3, RX descriptor 1 -> cursor 2, ICMP 0x5A50/2, frames 60/60, interrupts [1-9][0-9]*/[1-9][0-9]*, submissions 1, deliveries 1, cursors wrapped 0/0, final queues TX 11/11, RX 10/10, overflow 0, pending TX 0x0000000000000000, RX 0x00000000000000FF')) {
        throw 'The persistent e1000e owner did not complete a second ICMP exchange through reusable queue APIs.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e software RX queue verified: TX descriptor 3 -> cursor 4, DMA RX descriptor 2 recycled -> cursor 3, packet 60 bytes, ICMP 0x5A51/3, queue 1/1, high-water 1, dropped 0, final completions TX 12/12, RX 11/11, overflow 0, pending TX 0x0000000000000000, RX 0x00000000000000FF')) {
        throw 'The software packet queue did not copy, recycle, dequeue, and parse the third ICMP reply.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e protocol dispatch verified: TX descriptor 4 -> cursor 5, DMA RX descriptor 3 recycled -> cursor 4, ICMP 0x5A52/4, ingress 2/2 dropped 0, dispatch total 1 ARP/ICMP/UDP 0/1/0, unknown 0, ICMP queue 1/1 high-water 1 dropped 0, final completions TX 13/13, RX 12/12, overflow 0, pending TX 0x0000000000000000, RX 0x00000000000000FF')) {
        throw 'The protocol dispatcher did not route the fourth ICMP reply through the bounded ICMP queue.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e UDP/TFTP dispatch verified: RRQ TX descriptor 5, DATA RX descriptors 4/5/6/7/0, ACK TX descriptors 6/7/0/1/2, blocks 5, payload 2304 bytes, FNV-1a64 0x6175986CBBAB5125, frames 558/558/558/558/302, ACKs 60/60/60/60/60, server port 69, checksum present, final cursors TX/RX 3/1, wraps 1/1, ingress 7/7 dropped 0, dispatch ARP/ICMP/UDP 0/1/5, UDP queue 5/5 high-water 1 dropped 0, final completions TX 19/19, RX 17/17, overflow 0, pending TX 0x0000000000000000, RX 0x00000000000000FF')) {
        throw 'The retained UDP/TFTP path did not dispatch five DATA packets and acknowledge the complete fixture.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e UDP endpoint demux verified: endpoints 2, miss port 49999 dropped 1, TFTP port 40002 slot 1, RRQ TX descriptor 3, DATA RX descriptors 1/2/3/4/5, ACK TX descriptors 4/5/6/7/0, blocks 5, payload 2304 bytes, FNV-1a64 0x6175986CBBAB5125, endpoint queue 5/5 high-water 1 dropped 0, final cursors TX/RX 1/6, wraps 2/1, ingress 13/13 dropped 0, dispatch ARP/ICMP/UDP 0/1/10, completions TX 25/25 RX 22/22, overflow 0, pending TX 0x0000000000000000, RX 0x00000000000000FF')) {
        throw 'The UDP endpoint table did not isolate port 40002 or account for the unmatched destination port.'
    }
    if (-not $output.Contains('e1000e UDP datagram API verified: structured RX 5, connected TX 5, peer port 69 bound yes, payload metadata retained yes')) {
        throw 'Structured UDP receive metadata or connected socket transmission was not validated by the TFTP transfer.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e UDP endpoint lifecycle verified: table 4, usable queue 7, duplicate slot 2, full-table rejection yes, queue slot 2 7/7 high-water 7 dropped 1, busy unregister rejected yes, reuse slot 2, final endpoints 2, ingress 21/21 dropped 0, dispatch total/UDP 18/17, unmatched 1, completions TX 25/25 RX 22/22, overflow 0, pending TX 0x0000000000000000, RX 0x00000000000000FF')) {
        throw 'The UDP endpoint lifecycle did not preserve FIFO order, enforce capacity, or safely reuse a drained slot.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e UDP socket handles verified: TFTP slot 1 generation 2, lifecycle slot 2 generation 3, duplicate handle yes, reuse slot 2 generation 5, stale active/receive/send/close rejected yes/yes/yes/yes')) {
        throw 'Generation-tagged UDP sockets did not reject stale lookup, receive, send, and close operations after slot reuse.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e UDP peer filtering verified: socket slot 2 generation 6, local/peer ports 42000/23456, correct accepted yes, wrong MAC/IP/port rejected yes/yes/yes, invalid checksum rejected yes, wildcard after disconnect yes, endpoint queue 2/2 high-water 1 dropped 0, ingress 27/27, dispatch total/UDP 20/19, drops unmatched/invalid/peer 1/1/3, final endpoints 2')) {
        throw 'Validated UDP dispatch or connected-peer filtering did not reject malformed and wrong-peer datagrams.'
    }
    if (-not $output.Contains('e1000e UDP ephemeral ports verified: range 49152-65535, first slot/gen/port 2/7/49152, second 3/8/49153, full-table rejected yes, collision skipped yes -> 2/9/49154, wrap 2/10/65535 -> 3/11/49152, final cursor/endpoints 49153/2')) {
        throw 'Ephemeral UDP allocation did not skip collisions, preserve cursor state on full tables, or wrap deterministically.'
    }
    if (-not $output.Contains('e1000e UDP socket queue verified: slot/gen/port 2/12/49153, connected peer 23456, pending/readable before 3/yes, disconnect pending rejected yes, discarded 3, pending/readable after 0/no, queue 3/3 high-water 3 dropped 0, stale status/discard rejected yes/yes, ingress 30/30, dispatch total/UDP 23/22, final endpoints 2')) {
        throw 'UDP readiness inspection, queue discard, or queued-peer transition guards did not behave deterministically.'
    }
    if (-not $output.Contains('e1000e UDP dispatch batch verified: slot/gen/port 2/13/49154, initial 5, batches examined/routed/dropped/remaining 2/1/1/3 -> 2/1/1/1 -> 1/1/0/0, empty 0/0, delivered/high-water 3/3, ingress 35/35, dispatch total/UDP 26/25, drops unmatched/invalid 2/2, final endpoints 2')) {
        throw 'Bounded packet dispatch did not continue across drops or preserve ordered delivery and remaining-depth accounting.'
    }
    if (-not $output.Contains('e1000e UDP endpoint poll verified: sockets 2/14/49155 and 3/15/49156, initial masks active/readable/connected 0x0F/0x0C/0x0A, pending/max 3/2, partial readable/pending 0x0C/2, drained readable/pending 0x00/0, final masks active/readable/connected 0x03/0x00/0x02, pending/endpoints/cursor 0/2/49157, ingress 38/38, dispatch total/UDP 29/28')) {
        throw 'Endpoint-wide readiness polling did not track active, readable, connected, and pending state across queue drains and closes.'
    }
    if (-not $output.Contains('e1000e UDP service cycle verified: sockets 2/16/49157 and 3/17/49158, first dispatch 3/2/1/1 ready/pending 2/2, second dispatch 1/0/1/0 ready/pending 2/2, drained dispatch/ready 0/0, delivered 2, stale handles rejected yes/yes, endpoints/cursor 2/49159, ingress 42/42, dispatch total/UDP 31/30, drops unmatched/invalid 3/3')) {
        throw 'The UDP service cycle did not combine bounded dispatch with generation-safe readable handles.'
    }
    if (-not $output.Contains('e1000e UDP fair service verified: sockets 2/18/49159 and 3/19/49160, initial dispatch/ready/pending 4/4/0/4, selections slot/gen/payload/cursor 2/18/0/3 -> 3/19/2/0 -> 2/18/1/3 -> 3/19/3/0, empty/final cursor 0/0, endpoints/ephemeral cursor 2/49161, ingress 46/46, dispatch total/UDP 35/34')) {
        throw 'Round-robin readable socket selection did not alternate endpoints while preserving per-socket FIFO order.'
    }
    if (-not $output.Contains('e1000e UDP automatic identification verified: socket 2/20/49161, peer port 9, unconnected/zero-TTL rejected yes/yes, cursor preserved yes, IDs 0x7000/0x7001/0xFFFF/0x0001, descriptors 1/2/3/4, cursors 2/3/4/5, frames 60/60/60/60, final ID/TX cursor 2/5, submissions 4, completions 29/29, overflow 0, pending TX/RX 0x0000000000000000/0x00000000000000FF, endpoints/ephemeral cursor 2/49162')) {
        throw 'Automatic UDP IPv4 identification did not preserve cursor state on failure or wrap without emitting zero.'
    }
    if (-not $output.Contains('e1000e UDP payload boundary verified: socket 2/21/49162, maximum/oversized 1476/1477, oversized rejected/cursor preserved yes/yes, maximum ID/descriptor/cursor/frame 0x0002/5/6/1518, empty ID/descriptor/cursor/frame 0x0003/6/7/60, final ID/TX cursor 4/7, submissions 2, completions 31/31, overflow 0, wraps unchanged yes, endpoints/ephemeral cursor 2/49163')) {
        throw 'UDP payload limits did not accept the maximum frame, reject oversize transactionally, or preserve empty datagrams.'
    }
    if (-not $output.Contains('e1000e UDP transmit wrap verified: socket 2/22/49163, IDs 0x0004/0x0005, descriptors 7/0, cursors 0/1, frames 60/60, wraps 2->3 delta 1, final ID/TX cursor 6/1, submissions 2, completions 33/33, overflow 0, pending TX/RX 0x0000000000000000/0x00000000000000FF, endpoints/ephemeral cursor 2/49164')) {
        throw 'Connected UDP transmission did not cross the hardware TX ring boundary with clean completion ownership.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e UDP receive-into verified: socket 2/23/49164, first payload/copied/truncated/hash 8/5/yes/0x[0-9A-F]{16}, second 4/4/no/0x[0-9A-F]{16}, empty 0/0/no, source port 23456, endpoint queue 3/3 high-water 3 dropped 0, endpoints/cursor 2/49165, ingress 49/49, dispatch total/UDP 38/37, completions TX/RX 33/22')) {
        throw 'Bounded UDP receive copies did not report truncation, preserve metadata, or consume queue entries exactly once.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e UDP peek/exact verified: socket 2/24/49165, first payload/ID 6/0x6300, repeated stable yes, insufficient rejected/queue preserved yes/yes, first exact/hash 6/0x[0-9A-F]{16}, second payload/ID/exact/hash 2/0x6301/2/0x[0-9A-F]{16}, final preview empty yes, endpoint queue 2/2 high-water 2 dropped 0, endpoints/cursor 2/49166, ingress 51/51, dispatch total/UDP 40/39, completions TX/RX 33/22')) {
        throw 'UDP preview or exact-buffer receive consumed data on insufficient buffers or returned unstable metadata.'
    }
    if (-not $output.Contains('e1000e UDP discard-close verified: socket 2/25/49166, peer 23456, normal close rejected yes, discarded/connected 3/yes, queue 3/3 high-water 3 dropped 0, stale close/force/receive rejected yes/yes/yes, endpoints/cursor 2/49167, ingress 54/54, dispatch total/UDP 43/42, completions TX/RX 33/22')) {
        throw 'Discarding UDP close did not drain queued packets atomically or invalidate the socket handle.'
    }
    if (-not [regex]::IsMatch($output, 'e1000e UDP send-to/reply verified: socket 2/26/49167, request source/payload/hash 34567/4/0x[0-9A-F]{16}, invalid peer/zero-TTL rejected yes/yes, cursor preserved yes, reply ID/descriptor/cursor/frame 0x0006/1/2/60, send-to 0x0007/2/3/60, final ID/TX cursor 8/3, submissions 2, completions TX/RX 35/35/22, overflow 0, endpoints/cursor 2/49168, ingress 55/55, dispatch total/UDP 44/43')) {
        throw 'Unconnected UDP send-to or stateless reply did not preserve transactional identification and completion ownership.'
    }
    if (-not [regex]::IsMatch($output, 'DNS codec verified: transaction 0x4453, query length/hash 28/0x[0-9A-F]{16}, response length/hash 44/0x[0-9A-F]{16}, A 192\.0\.2\.42, TTL 300, authoritative/recursion yes/yes, rejects names/small/ID/truncated/loop/error/type yes/yes/yes/yes/yes/yes/yes, case-insensitive yes')) {
        throw 'The DNS wire codec did not validate names, compressed responses, transaction identity, and malformed-message rejection.'
    }
    if (-not [regex]::IsMatch($output, 'DNS transaction verified: socket 2/27/49168, server 10\.0\.2\.3:53, transaction 0x4453, invalid name/cursor preserved yes/yes, query length/hash 28/0x[0-9A-F]{16}, TX ID/descriptor/cursor/frame 0x0008/3/4/70, wrong transaction rejected yes, A 192\.0\.2\.42 TTL 300 authoritative/recursion yes/yes, endpoint queue 2/2 high-water 2 dropped 0, final ID/TX cursor 9/4, submissions 1, completions TX/RX 36/36/22, overflow 0, endpoints/cursor 2/49169, ingress 57/57, dispatch total/UDP 46/45')) {
        throw 'The DNS client transaction did not use connected UDP, reject a mismatched transaction, and return the validated A record.'
    }
    if (-not [regex]::IsMatch($output, 'DNS polling verified: socket 2/28/49169, server 10\.0\.2\.3:53, transaction 0x4454, name length/hash 10/0x[0-9A-F]{16}, invalid/cursor preserved yes/yes, TX ID/descriptor/cursor/frame 0x0009/4/5/70, zero state/examined/rejected/remaining pending/0/0/3, first pending/2/2/1, second resolved/1/0, A 192\.0\.2\.42 TTL 300, stale inactive, endpoint queue 3/3 high-water 3 dropped 0, final ID/TX cursor 10/5, submissions 1, completions TX/RX 37/37/22, overflow 0, endpoints/cursor 2/49170, ingress 60/60, dispatch total/UDP 49/48')) {
        throw 'The resumable DNS query did not respect polling budgets, reject unrelated responses, resolve the match, and become inactive with its stale socket.'
    }
    if (-not [regex]::IsMatch($output, 'DNS alias verified: transaction 0x4455, alias length/hash 16/0x[0-9A-F]{16}, canonical length/hash 10/0x[0-9A-F]{16}, response length/hash 84/0x[0-9A-F]{16}, A 192\.0\.2\.42 TTL 300 hops 1, loop/truncated rejected yes/yes, case-insensitive yes')) {
        throw 'DNS CNAME resolution did not follow the bounded alias, reject a loop, and preserve case-insensitive matching.'
    }
    if (-not [regex]::IsMatch($output, 'DNS alias transaction verified: socket 2/29/49170, server 10\.0\.2\.3:53, transaction 0x4456, name length/hash 16/0x[0-9A-F]{16}, TX ID/descriptor/cursor/frame 0x000A/5/6/76, poll resolved/1/0, A 192\.0\.2\.42 TTL 300 hops 1, endpoint queue 1/1 high-water 1 dropped 0, final ID/TX cursor 11/6, submissions 1, completions TX/RX 38/38/22, overflow 0, endpoints/cursor 2/49171, ingress 61/61, dispatch total/UDP 50/49')) {
        throw 'The resumable DNS transaction did not resolve a CNAME response through the connected UDP polling path.'
    }
    if (-not [regex]::IsMatch($output, 'DNS retry verified: socket 2/30/49171, server 10\.0\.2\.3:53, transaction 0x4457, name length/hash 10/0x[0-9A-F]{16}, initial ID/descriptor/cursor/frame 0x000B/6/7/70, pending pending/0/0, retry 0x000C/7/0/70, transmissions 2, wraps 3->4, resolved resolved/1/0, A 192\.0\.2\.42 TTL 300, stale retry/cursor preserved yes/yes, final ID/TX cursor 13/0, submissions 2, completions TX/RX 40/40/22, overflow 0, endpoints/cursor 2/49172, ingress 62/62, dispatch total/UDP 51/50')) {
        throw 'DNS retry did not preserve the application transaction, allocate fresh packet IDs, cross the TX ring, and reject stale requests transactionally.'
    }
    if (-not $output.Contains('DNS cache verified: capacity/active 4/4, invalid/zero-TTL rejected yes/yes, case hit/TTL yes/199, eviction/expiration/refresh yes/yes/yes, refreshed A 192.0.2.99 TTL 300, stats hits/misses/stores/refreshes/evictions/expirations 9/2/7/1/1/1')) {
        throw 'The bounded DNS cache did not enforce TTL expiry, case-insensitive refresh, and least-recently-used replacement.'
    }
    if (-not [regex]::IsMatch($output, 'DNS cached resolve verified: socket 2/31/49172, server 10\.0\.2\.3:53, transaction 0x4458, miss TX 0x000D/0/1/70, resolved resolved/1 A 192\.0\.2\.42 TTL 300 stores 1, cached hit/no-TX yes/yes A 192\.0\.2\.42 TTL 200, expiry requery 0x000E/1/2/70, stale pending inactive, final ID/TX cursor 15/2, submissions 2, completions TX/RX 42/42/22, overflow 0, cache hits/misses/expirations/active 1/2/1/0, endpoints/cursor 2/49173, ingress 63/63, dispatch total/UDP 52/51')) {
        throw 'The cached DNS resolver did not avoid TX on a live hit, expire by TTL, requery, and reject the stale pending request.'
    }
    if (-not $output.Contains('DNS automatic transactions verified: socket 2/32/49173, invalid/cursors preserved yes/yes, DNS IDs 0x5000/0xFFFF/0x0001, packet IDs 15/16/17, descriptors 2/3/4, cursors 3/4/5, frames 70/70/76, transmissions 1/1/1, stale/cursors preserved yes/yes, final DNS/IP/TX cursors 2/18/5, submissions 3, completions TX/RX 45/45/22, overflow 0, wraps unchanged yes, endpoints/cursor 2/49174, ingress 63/63, dispatch total/UDP 52/51')) {
        throw 'Automatic DNS transaction allocation did not reject failures transactionally or wrap from 0xFFFF to 0x0001.'
    }
    if (-not [regex]::IsMatch($output, 'DNS automatic cached resolve verified: socket 2/33/49174, server 10\.0\.2\.3:53, preload yes, initial hit/TTL/no-TX yes/900/yes, expired DNS/IP/descriptor/cursor/frame 0x0002/18/5/6/70, resolved resolved/1/0 A 192\.0\.2\.42 TTL 300, refreshed hit/TTL/no-TX yes/200/yes, invalid/cursors preserved yes/yes, final DNS/IP/TX cursors 3/19/6, submissions 1, completions TX/RX 46/46/22, overflow 0, cache hits/misses/stores/expirations/active 2/1/2/1/1, endpoints/cursor 2/49175, ingress 64/64, dispatch total/UDP 53/52')) {
        throw 'The automatic cached resolver did not keep cache hits off the wire, requery on expiry, cache the answer, and reject invalid names transactionally.'
    }
    if (-not [regex]::IsMatch($output, 'DNS negative response verified: socket 2/34/49175, server 10\.0\.2\.3:53, transaction 0x0003, TX ID/descriptor/cursor/frame 19/6/7/78, poll not-found/1/0, response absent/queue empty yes/yes, stale inactive, final DNS/IP/TX cursors 4/20/7, submissions 1, completions TX/RX 47/47/22, overflow 0, endpoints/cursor 2/49176, ingress 65/65, dispatch total/UDP 54/53')) {
        throw 'NXDOMAIN did not become a terminal not-found poll result with balanced socket and hardware accounting.'
    }
    if (-not [regex]::IsMatch($output, 'DNS negative cache verified: socket 2/35/49176, server 10\.0\.2\.3:53, initial DNS/IP/descriptor/cursor/frame 4/20/7/0/78, poll/stored not-found/yes, cached not-found/TTL/no-TX yes/50/yes, expiry DNS/IP/descriptor/cursor/frame 5/21/0/1/78, stale inactive, final DNS/IP/TX cursors 6/22/1, submissions 2, completions TX/RX 49/49/22, overflow 0, cache hits/misses/stores/expirations/active 1/2/1/1/0, endpoints/cursor 2/49177, ingress 66/66, dispatch total/UDP 55/54')) {
        throw 'Negative DNS caching did not suppress live repeated lookups, expire by TTL, and start a fresh query afterward.'
    }
    if (-not [regex]::IsMatch($output, 'DNS cancellation verified: socket 2/36/49177, DNS/IP/descriptor/cursor/frame 6/22/1/2/70, queued 1, cancel/duplicate rejected yes/yes, poll inactive/0/0, queue preserved yes, retry/cursors preserved yes/yes, normal close rejected/discarded yes/1, stale poll inactive, final DNS/IP/TX cursors 7/23/2, submissions 1, completions TX/RX 50/50/22, overflow 0, endpoints/cursor 2/49178, ingress 67/67, dispatch total/UDP 56/55')) {
        throw 'DNS cancellation did not stop polling/retry transactionally while preserving queued responses for explicit close policy.'
    }
    if (-not [regex]::IsMatch($output, 'DNS resolver context verified: socket 2/37/49178, server 10\.0\.2\.3:53, invalid/state preserved yes/yes, DNS/IP/descriptor/cursor/frame 7/23/2/3/70, resolved resolved/1/0 A 192\.0\.2\.42 TTL 300, cached hit/TTL/no-TX yes/200/yes, close/inactive/stale/state preserved yes/yes/yes/yes, final DNS/IP/TX cursors 8/24/3, submissions 1, completions TX/RX 51/51/22, overflow 0, cache hits/misses/stores/active 1/1/1/1, endpoints/cursor 2/49179, ingress 68/68, dispatch total/UDP 57/56')) {
        throw 'The DNS resolver context did not own socket/cache state transactionally or reject operations after close.'
    }
    if (-not [regex]::IsMatch($output, 'NTP codec verified: client/server timestamp 0x[0-9A-F]{16}/0x[0-9A-F]{16}, request length/hash 48/0x[0-9A-F]{16}, response length/hash 48/0x[0-9A-F]{16}, LI/version/stratum/poll/precision 0/4/2/6/-20, root delay/dispersion 0x00010000/0x00008000, reference LOCL, Unix seconds/fraction 1800000000/0x80000000, rejects zero/small/mode/alarm/stratum/originate/transmit/epoch/truncated yes/yes/yes/yes/yes/yes/yes/yes/yes')) {
        throw 'The NTPv4 codec did not validate timestamps, epoch conversion, server identity fields, and malformed responses.'
    }
    if (-not [regex]::IsMatch($output, 'NTP transaction verified: socket 2/38/49179, server 10\.0\.2\.4:123, client timestamp 0x[0-9A-F]{16}, invalid/state preserved yes/yes, TX ID/descriptor/cursor/frame 24/3/4/90, wrong originate rejected yes, Unix seconds/fraction 1800000000/0x80000000, stratum/poll/precision 2/6/-20, reference LOCL, endpoint queue 2/2 high-water 2 dropped 0, final IP/DNS/TX cursors 25/8/4, submissions 1, completions TX/RX 52/52/22, overflow 0, endpoints/cursor 2/49180, ingress 70/70, dispatch total/UDP 59/58')) {
        throw 'The NTP client did not transmit through connected UDP, reject a mismatched originate timestamp, and accept the valid server time.'
    }
    if (-not [regex]::IsMatch($output, 'NTP polling verified: poll socket 2/39/49180, TX 25/4/5/90, zero pending/0/0/3, first pending/2/2/1, second resolved/1/0 time 1800000000/0x80000000, cancel socket 2/40/49181 TX 26/5/6/90, queued 1, cancel/duplicate yes/yes, poll inactive/0/0, queue preserved yes, close/discard yes/1, final IP/DNS/TX 27/8/6, submissions 2, completions TX/RX 54/54/22, overflow 0, endpoints/cursor 2/49182, ingress 74/74, dispatch total/UDP 63/62')) {
        throw 'Bounded NTP polling or cancellation did not preserve queue ownership, work budgets, and explicit close policy.'
    }
    if (-not [regex]::IsMatch($output, 'NTP retry verified: socket 2/41/49182, client 0x[0-9A-F]{16}, initial 27/6/7/90, pending pending/0/0, retry 28/7/0/90, transmissions 2, wraps 5->6, resolved resolved/1/0 time 1800000000/0x80000000, stale/state preserved yes/yes, final IP/DNS/TX 29/8/0, submissions 2, completions TX/RX 56/56/22, overflow 0, endpoints/cursor 2/49183, ingress 75/75, dispatch total/UDP 64/63')) {
        throw 'NTP retry did not preserve the originate timestamp, allocate a fresh IPv4 ID, cross the TX ring, and reject stale requests transactionally.'
    }
    if (-not [regex]::IsMatch($output, 'NTP client context verified: socket 2/42/49183, server 10\.0\.2\.4:123, invalid/state preserved yes/yes, client 0x[0-9A-F]{16}, TX 29/0/1/90, poll resolved/1/0 time 1800000000/0x80000000, close/inactive/stale start/poll/retry/state yes/yes/yes/inactive/yes/yes, final IP/DNS/TX 30/8/1, submissions 1, completions TX/RX 57/57/22, overflow 0, endpoints/cursor 2/49184, ingress 76/76, dispatch total/UDP 65/64')) {
        throw 'The NTP client context did not own its socket transactionally or reject start, poll, and retry after close.'
    }
    if (-not $output.Contains('NTP clock verified: initially unsynchronized yes, apply first/duplicate/backward/fraction/second accepted/stale/stale/accepted/accepted, duplicate/backward preserved yes/yes, final seconds/fraction 1800000001/0x10000000, stratum/reference 4/NEXT, accepted/stale 3/2')) {
        throw 'The synchronized NTP clock did not reject non-forward samples or retain the newest validated time and source metadata.'
    }
    if (-not [regex]::IsMatch($output, 'NTP clock polling verified: socket 2/43/49184, server 10\.0\.2\.4:123, first TX 30/1/2/90, zero pending/0/0/apply absent yes/queue 1/clock unsynchronized yes, accepted resolved/1/0/apply accepted time 1800000000/0x80000000, second TX 31/2/3/90, duplicate resolved/1/0/apply stale/clock preserved yes, samples 1/1, close/inactive/apply absent/clock preserved yes/inactive/yes/yes, final IP/DNS/TX 32/8/3, submissions 2, completions TX/RX 59/59/22, overflow 0, endpoints/cursor 2/49185, ingress 78/78, dispatch total/UDP 67/66')) {
        throw 'Clock-aware NTP polling did not preserve zero-budget work, apply the first response, reject a duplicate clock sample, and remain inert after close.'
    }
    if (-not $output.Contains('NTP projected clock verified: invalid frequency/state preserved yes/yes, initially unsynchronized yes, first apply accepted at tick/frequency 1000/1000, quarter 1800000000/0xC0000000, three-quarter 1800000001/0x40000000, one-second 1800000001/0x80000000, backward tick rejected yes, resync accepted at 2000/1000 time 1800000002/0x10000000 stratum/reference 3/SYNC, quarter after resync 1800000002/0x50000000, stale apply/preserved stale/yes, samples 2/1')) {
        throw 'The projected NTP clock did not advance fractional Unix time from monotonic ticks or preserve its anchor on invalid and stale updates.'
    }
    if (-not [regex]::IsMatch($output, 'NTP reference clock verified: source (HPET|ACPI PM timer), frequency [1-9][0-9]* Hz, bits (24|32|64), socket 2/44/49185, server 10\.0\.2\.4:123, first TX 32/3/4/90, zero pending/0/0/sample absent yes/apply absent yes/queue 1, accepted resolved/1/0/sample [1-9][0-9]*/apply accepted time 1800000000/0x80000000, later tick/delta [1-9][0-9]*/[1-9][0-9]* time [0-9]+/0x[0-9A-F]{8} advanced yes, second TX 33/4/5/90, duplicate resolved/1/0/sample [1-9][0-9]*/apply stale/clock preserved yes, close/inactive/sample/apply absent/clock preserved yes/inactive/yes/yes/yes, final IP/DNS/TX 34/8/5, submissions 2, completions TX/RX 61/61/22, overflow 0, endpoints/cursor 2/49186, ingress 80/80, dispatch total/UDP 69/68')) {
        throw 'The live reference-backed NTP clock did not sample hardware ticks, advance after a real delay, reject a repeated timestamp, and remain inert after close.'
    }
    if (-not [regex]::IsMatch($output, 'NTP service verified: source (HPET|ACPI PM timer), frequency/bits [1-9][0-9]*/(24|32|64), socket 2/45/49186, invalid policy/state preserved yes/yes, policy 4/0x00020000/0x00010000, bootstrap rejected/state preserved yes/yes, initial timestamp 0xEEF4507F40000000, intervals 1/2, initial TX 34/5/6, early no-TX yes, retry TX 35/6/7 transmissions 2 timestamp preserved yes, quality reject root-dispersion/sample absent/request retained yes/yes, first sample [1-9][0-9]* time 1800000000/0x80000000 deadline [1-9][0-9]*, pre-anchor idle preserved yes, before refresh no-TX yes, refresh timestamp 0x[0-9A-F]{16} automatic yes, refresh TX 36/7/0, second sample [1-9][0-9]* time 1800000002/0x80000000, counts 2/1/2, quality counts 2/1/0/0/0/1, close/inactive preserved yes/yes, final IP/TX 37/0, submissions 3, completions TX/RX 64/64/22, endpoints/cursor 2/49187, ingress 83/83, dispatch 72/71')) {
        throw 'The owned NTP service did not reject invalid policy transactionally, preserve retry originate time, reject a low-quality response without sampling the clock, retain the request, derive refresh time, and shut down cleanly.'
    }
    if (-not [regex]::IsMatch($output, 'NTP backoff verified: source (HPET|ACPI PM timer), frequency/bits [1-9][0-9]*/(24|32|64), invalid policy/state preserved yes/yes, socket 2/46/49187, policy 1/4/3, initial 37/0/1 wait 1, early no-TX yes, retries 38/1/2 wait 2 -> 39/2/3 wait 4 -> 40/3/4 wait 4, timeout delta/state/reached/cancelled/exhausted 11/timed-out/yes/yes/yes, latched/health yes/yes, clear/duplicate yes/yes, restart 41/4/5 wait 1, close yes, counts 2/3/1, final IP/TX 42/5, submissions 5, completions TX/RX 69/69/22, endpoints/cursor 2/49188, ingress 83/83, dispatch 72/71')) {
        throw 'The live NTP retry service did not follow capped backoff deadlines, latch timeout without hidden restart, expose exhaustion through health, clear explicitly, restart cleanly, and preserve exact network accounting.'
    }
    if (-not [regex]::IsMatch($output, 'NTP automatic recovery verified: source (HPET|ACPI PM timer), frequency/bits [1-9][0-9]*/(24|32|64), invalid policy/state preserved yes/yes, socket 2/47/49188, retry 1/1/1 recovery 2/2, transmissions 42/5/6 -> 43/6/7 -> 44/7/0 -> 45/0/1 -> 46/1/2 -> 47/2/3, timeline first 2/4/4 second 6/8/8 terminal 10/12, waits no-TX yes/yes, recovery starts yes/yes, exhausted/latched/health/bootstrap yes/yes/yes/yes, counts 3/3/3/2/1, close yes, final IP/TX 48/3, submissions 6, completions TX/RX 75/75/22, endpoints/cursor 2/49189, ingress 83/83, dispatch 72/71')) {
        throw 'The live NTP recovery service did not enforce cooldown waits, bounded automatic restarts, terminal recovery exhaustion, timestamp preservation, health exposure, and exact network accounting.'
    }
    if (-not [regex]::IsMatch($output, 'NTP synchronized recovery verified: source (HPET|ACPI PM timer), frequency/bits [1-9][0-9]*/(24|32|64), socket 2/48/49189, transmissions 48/3/4 -> 49/4/5 -> 50/5/6 -> 51/6/7 -> 52/7/0 -> 53/0/1 -> 54/1/2, timestamps initial/refresh/recovery1/recovery2 0xEEF4507F40000000/0x[0-9A-F]{16}/0x[0-9A-F]{16}/0x[0-9A-F]{16} automatic yes/yes/yes, holdover states holdover/holdover timestamps 0x[0-9A-F]{16}/0x[0-9A-F]{16} visible/advanced yes/yes, first timeline 4/6/6 started yes, accepted/successes/reset/advanced yes/1/yes/yes recovered 0xEEF4508280000000, second timeline 4/6/6 started/budget/health yes/yes/yes, counts 5/2/2/2/2/1/1/0, close yes, final IP/TX 55/2, submissions 7, completions TX/RX 82/82/22, endpoints/cursor 2/49190, ingress 85/85, dispatch 74/73')) {
        throw 'Synchronized NTP recovery did not preserve visible advancing holdover time, derive projected recovery timestamps, reset the recovery budget after success, permit a fresh recovery, and preserve exact accounting.'
    }
    if (-not [regex]::IsMatch($output, 'NTP live step gate verified: source (HPET|ACPI PM timer), frequency/bits [1-9][0-9]*/(24|32|64), invalid policy/state preserved yes/yes, socket 2/49/49190, policy 4/0x00000000, initial TX 55/2/3 results accepted/accepted sample/time [1-9][0-9]*/1800000000/0x80000000, refresh TX 56/3/4 timestamp 0x[0-9A-F]{16}, excessive accepted/excessive-forward sample [1-9][0-9]* apply-absent/clock-preserved/request-retained yes/yes/yes, accepted accepted/accepted sample/time [1-9][0-9]*/1800000002/0x80000000 advanced yes, counts quality 3/0 step 2/1/0/0/1 responses 2, close yes, final IP/TX 57/4, submissions 2, completions TX/RX 84/84/22, endpoints/cursor 2/49191, ingress 88/88, dispatch 77/76')) {
        throw 'The live NTP step gate did not reject an excessive high-quality forward jump without clock mutation, retain the request, accept a bounded follow-up, and preserve exact network accounting.'
    }
    if (-not [regex]::IsMatch($output, 'NTP stale-step retry verified: source (HPET|ACPI PM timer), frequency/bits [1-9][0-9]*/(24|32|64), socket 2/50/49191, policy 4, initial TX 57/4/5 sample/time [1-9][0-9]*/1800000000/0x80000000, refresh TX 58/5/6 timestamp 0x[0-9A-F]{16}, stale accepted/stale sample [1-9][0-9]* apply-absent/clock-preserved/request-retained yes/yes/yes, retry 59/6/7 timestamp-preserved/transmissions yes/2, accepted accepted/accepted sample/time [1-9][0-9]*/1800000002/0x80000000 advanced yes, counts quality 3/0 step 2/1/0/1/0 lifecycle 2/1/2, close yes, final IP/TX 60/7, submissions 3, completions TX/RX 87/87/22, endpoints/cursor 2/49192, ingress 91/91, dispatch 80/79')) {
        throw 'The live stale-step path did not preserve the clock and request, retry at the deadline, retain the originate timestamp, accept the bounded follow-up, and preserve exact accounting.'
    }
    if (-not [regex]::IsMatch($output, 'NTP live rejection budget verified: source (HPET|ACPI PM timer), frequency/bits [1-9][0-9]*/(24|32|64), invalid policy/state preserved yes/yes, socket 2/51/49192, max 2, initial 60/7/0 sample [1-9][0-9]*, refresh 61/0/1 timestamp 0x[0-9A-F]{16}, first accepted/stale/retain count/remaining 1/1 absent/preserved/retained yes/yes/yes, boundary accepted/excessive-forward/retry-now count/remaining 2/0 absent/preserved yes/yes, forced retry 62/1/2 before-deadline/timestamp-preserved/transmissions/reset yes/yes/2/yes, accepted accepted/accepted sample/time [1-9][0-9]*/1800000002/0x80000000 advanced yes, counts quality 4/0 step 2/2/1/1 forced/lifecycle 1/2/1/2, close yes, final IP/TX 63/2, submissions 3, completions TX/RX 90/90/22, endpoints/cursor 2/49193, ingress 95/95, dispatch 84/83')) {
        throw 'The live NTP rejection budget did not retain below the limit, force a bounded immediate retry at the limit, preserve the originate timestamp, reset the count, accept the follow-up, and preserve exact accounting.'
    }
    if (-not [regex]::IsMatch($output, 'NTP rejection exhaustion verified: source (HPET|ACPI PM timer), frequency/bits [1-9][0-9]*/(24|32|64), socket 2/52/49193, policies reject/retry 1/1, initial 63/2/3, refresh 64/3/4 timestamp 0x[0-9A-F]{16}, first accepted/stale/retry-now retry 65/4/5 timestamp-preserved/transmissions yes/2, second accepted/excessive-forward/retry-now count/remaining 1/0 absent/preserved yes/yes, timeout timed-out reached/no-TX/cancelled/inactive/exhausted yes/yes/yes/yes/yes limit/forced 1/1, latched/health yes/yes, clear/duplicate/count-cleared yes/yes/yes, counts quality 3/0 step 1/2/1/1 lifecycle 2/1/1, close yes, final IP/TX 66/5, submissions 3, completions TX/RX 93/93/22, endpoints/cursor 2/49194, ingress 98/98, dispatch 87/86')) {
        throw 'Discipline-forced retry exhaustion did not cancel and latch at the retry limit, preserve the clock, expose health, clear explicitly, and avoid a hidden transmission.'
    }
    if (-not [regex]::IsMatch($output, 'NTP discipline recovery verified: source (HPET|ACPI PM timer), frequency/bits [1-9][0-9]*/(24|32|64), socket 2/53/49194, policies reject/retry/recovery 1/1/2/2, transmissions 66/5/6 -> 67/6/7 -> 68/7/0 -> 69/0/1, timestamps refresh/recovery 0x[0-9A-F]{16}/0x[0-9A-F]{16} automatic yes, timeout timed-out waiting/no-TX/cancelled/exhausted yes/yes/yes/yes deadline 2, holdover states holdover/holdover timestamps 0x[0-9A-F]{16}/0x[0-9A-F]{16} visible/advanced yes/yes, cooldown no-TX yes, recovery ready/started yes/yes, accepted accepted/accepted sample/time [1-9][0-9]*/1800000002/0x80000000, reset successes/recovery/retry/rejection/clock/health 1/yes/yes/yes/yes/yes, counts quality 4/0 step 2/2/1/1 forced/lifecycle 1/3/1/2, close yes, final IP/TX 70/1, submissions 4, completions TX/RX 97/97/22, endpoints/cursor 2/49195, ingress 102/102, dispatch 91/90')) {
        throw 'Discipline-triggered NTP timeout did not preserve advancing holdover, wait through cooldown, restart with projected time, accept bounded recovery, reset all outage budgets, and preserve exact accounting.'
    }
    if (-not [regex]::IsMatch($output, 'NTP live quality rejection budget verified: source (HPET|ACPI PM timer), frequency/bits [1-9][0-9]*/(24|32|64), invalid policy/state preserved yes/yes, socket 2/54/49195, max 2, initial 70/1/2 timestamp 0xEEF4507F40000000, first root-dispersion retain count/remaining 1/1 sample/apply absent clock/request preserved yes/yes/yes/yes, boundary stratum retry-now count/remaining 2/0 sample/apply absent clock preserved yes/yes/yes, forced retry 71/2/3 before-deadline/timestamp-preserved/transmissions/reset yes/yes/2/yes, accepted accepted/accepted sample/time [1-9][0-9]*/1800000000/0x80000000 health yes, counts quality 1/2 reasons stratum/dispersion 1/1 forced/step/lifecycle 1/1/1/1/1, close yes, final IP/TX 72/3, submissions 2, completions TX/RX 99/99/22, endpoints/cursor 2/49196, ingress 105/105, dispatch 94/93')) {
        throw 'The live NTP quality-rejection budget did not reject invalid policy transactionally, retain below the limit without sampling, force a bounded pre-sample retry at the limit, preserve the originate timestamp, accept the follow-up, expose health, and preserve exact accounting.'
    }
    if (-not [regex]::IsMatch($output, 'NTP quality rejection exhaustion verified: source (HPET|ACPI PM timer), frequency/bits [1-9][0-9]*/(24|32|64), socket 2/55/49196, policies reject/retry 1/1, initial 72/3/4 timestamp 0xEEF4507F40000000, first root-dispersion retry-now sample/apply absent clock preserved yes/yes/yes retry 73/4/5 timestamp-preserved/transmissions yes/2, second stratum retry-now count/remaining 1/0 sample/apply absent clock preserved yes/yes/yes, timeout timed-out reached/no-TX/cancelled/inactive/exhausted yes/yes/yes/yes/yes limit/forced 1/1, latched/health yes/yes, clear/duplicate/count-cleared yes/yes/yes, restart 74/5/6 wait 1, counts quality 0/2 reasons stratum/dispersion 1/1 step 0/0 lifecycle 2/1/0, close yes, final IP/TX 75/6, submissions 3, completions TX/RX 102/102/22, endpoints/cursor 2/49197, ingress 107/107, dispatch 96/95')) {
        throw 'Quality-forced NTP retry exhaustion did not avoid clock reads, time out without hidden transmission, latch safely, expose health, clear both rejection budgets, restart cleanly, and preserve exact accounting.'
    }
    if (-not [regex]::IsMatch($output, 'NTP quality recovery verified: source (HPET|ACPI PM timer), frequency/bits [1-9][0-9]*/(24|32|64), socket 2/56/49197, policies quality/retry/recovery 1/1/2/2, transmissions 75/6/7 -> 76/7/0 -> 77/0/1 -> 78/1/2, timestamps refresh/recovery 0x[0-9A-F]{16}/0x[0-9A-F]{16} automatic yes, rejections root-dispersion/stratum no-sample/apply/clock yes/yes/yes -> yes/yes/yes, first retry timestamp/transmissions yes/2, timeout timed-out waiting/no-TX/cancelled/exhausted yes/yes/yes/yes deadline 2, holdover states holdover/holdover timestamps 0x[0-9A-F]{16}/0x[0-9A-F]{16} visible/advanced yes/yes, cooldown no-TX yes, recovery ready/started yes/yes, accepted accepted/accepted sample/time [1-9][0-9]*/1800000002/0x80000000, reset successes/recovery/retry/quality/step/clock/health 1/yes/yes/yes/yes/yes/yes, counts quality 2/2 reasons stratum/dispersion 1/1 forced/step/lifecycle/limit 1/2/0/3/1/2/1, close yes, final IP/TX 79/2, submissions 4, completions TX/RX 106/106/22, endpoints/cursor 2/49198, ingress 111/111, dispatch 100/99')) {
        throw 'Quality-triggered NTP timeout did not preserve advancing holdover, avoid pre-sample clock reads, wait through cooldown, restart with projected time, accept bounded recovery, reset all outage budgets, and preserve exact accounting.'
    }
    if (-not $output.Contains('NTP client server switch verified: socket 2/57/49198, servers 10.0.2.4 -> 10.0.2.5 -> 10.0.2.4, invalid/idempotent/forward/reverse yes/yes/yes/yes, state invalid/idempotent/forward/reverse yes/yes/yes/yes, socket/MAC/port preserved yes/yes/123, close/inactive/stale yes/yes/yes state yes/yes, no traffic yes, final endpoints/cursor/generation 2/49199/58, IP/TX 79/2, completions TX/RX 106/106/22, ingress 111/111, dispatch 100/99')) {
        throw 'The NTP client server switch did not reject invalid/stale/inactive state transactionally, preserve idempotent state, switch and restore the peer on the same socket, avoid packet traffic, and preserve exact accounting.'
    }
    if (-not $output.Contains('NTP timestamp verified: base/anchor 0xEEF4508080000000/0xEEF4508080000000, quarter/rollover 0xEEF45080C0000000/0xEEF4508140000000, maximum 0xFFFFFFFFFFFFFFFF, rejects unsynchronized/backward/overflow yes/yes/yes')) {
        throw 'Projected Unix time did not convert into exact NTP timestamps or enforce the supported NTP-era boundary.'
    }
    if (-not $output.Contains('NTP automatic timestamp verified: zero bootstrap rejected yes, bootstrap/anchor/quarter 0xEEF4507F40000000/0xEEF4508080000000/0xEEF45080C0000000, backward tick rejected yes')) {
        throw 'The NTP service timestamp selector did not enforce bootstrap requirements or derive synchronized timestamps from projected time.'
    }
    if (-not $output.Contains('NTP quality verified: fixture/boundary accepted yes/yes, rejects invalid/stratum/positive-delay/negative-delay/dispersion yes/yes/yes/yes/yes, delay magnitudes 0x00010000/0x00010001')) {
        throw 'The NTP quality policy did not enforce stratum, signed root-delay magnitude, root-dispersion, invalid-policy, and exact-boundary behavior.'
    }
    if (-not $output.Contains('NTP health verified: invalid thresholds zero/equal/reversed yes/yes/yes, states inactive/unsynchronized/synchronized/holdover/expired, backward rejected yes, synchronized age/time 3/1800000001/0x40000000, holdover age/time 4/1800000001/0x80000000, expired age/time absent 8/yes, awaiting/counters preserved yes/yes')) {
        throw 'The NTP health snapshot did not enforce threshold validity, exact state boundaries, projected-time visibility, expiry withholding, and non-mutating counter preservation.'
    }
    if (-not $output.Contains('NTP retry policy verified: invalid zero-initial/cap/zero-retries yes/yes/yes, intervals 3/6/10/10, limit rejected yes, fixed 5/5/5, overflow saturated yes at 18446744073709551615')) {
        throw 'The NTP retry policy did not enforce validation, capped exponential progression, retry limits, fixed-interval compatibility, and overflow-safe saturation.'
    }
    if (-not $output.Contains('NTP recovery policy verified: invalid zero-cooldown/zero-recoveries yes/yes, deadline 110, before/at/second/exhausted yes/yes/yes/yes, overflow deadline 18446744073709551615 waiting/ready yes/yes')) {
        throw 'The NTP recovery policy did not enforce validation, exact cooldown boundaries, recovery limits, and overflow-safe deadline saturation.'
    }
    if (-not $output.Contains('NTP step policy verified: invalid zero rejected yes, initial accepted yes, stale equal/behind yes/yes, exact borrow/no-borrow yes/yes, excessive fraction/seconds yes/yes, deltas borrow 1/0x80000000 no-borrow 1/0x80000000')) {
        throw 'The NTP clock-step policy did not enforce exact fixed-point stale, borrow, no-borrow, boundary, and excessive-forward-step behavior.'
    }
    if (-not $output.Contains('NTP source pool verified: invalid count zero/single/too-many yes/yes/yes, invalid zero/duplicate yes/yes, valid two/max yes/yes, sources 10.0.2.4/10.0.2.5/10.0.2.7, lookup range/invalid/unused yes/yes/yes')) {
        throw 'The bounded NTP source pool did not enforce count, nonzero, uniqueness, indexed selection, out-of-range rejection, invalid-pool rejection, and unused-slot semantics.'
    }
    if (-not $output.Contains('NTP source rotation policy verified: invalid sources/single/threshold/index yes/yes/yes/yes, stay zero/first yes/yes remaining 2/1, rotate boundary/beyond yes/yes next 2/2, wrap 2->0 yes, maximum stay/rotate yes/yes next 0')) {
        throw 'The NTP source-rotation policy did not enforce validation, exact stay/rotate boundaries, wraparound, invalid-index handling, and u8-maximum behavior.'
    }
    if (-not $output.Contains('NTP quality rejection policy verified: invalid zero yes, zero/first/penultimate retain yes/yes/yes remaining 3/2/1, boundary/beyond retry yes/yes remaining 0, maximum penultimate/boundary yes/yes')) {
        throw 'The NTP quality-rejection budget did not enforce validation, exact retain/retry boundaries, remaining allowance, and u8-maximum behavior.'
    }
    if (-not $output.Contains('NTP step rejection policy verified: invalid zero yes, zero/first/penultimate retain yes/yes/yes remaining 3/2/1, boundary/beyond retry yes/yes remaining 0, maximum penultimate/boundary yes/yes')) {
        throw 'The NTP step-rejection budget did not enforce validation, exact retain/retry boundaries, remaining allowance, and u8-maximum behavior.'
    }
} else {
    if (-not $output.Contains('Intel 82574L network controller not present; continuing without networking')) {
        throw 'The network-absent fallback marker was not observed.'
    }
    if (-not $output.Contains('Network interfaces ready: Intel 82574L no')) {
        throw 'The network-absent readiness marker was not observed.'
    }
    if ($output.Contains('e1000e controller discovered at')) {
        throw 'An e1000e controller unexpectedly initialized without -Network.'
    }
}
if ($LegacyPci) {
    if (-not [regex]::IsMatch($output, 'xHCI controller discovered at 0000:[0-9A-F]{2}:[0-9A-F]{2}\.[0-7], vendor 0x[0-9A-F]{4}, device 0x[0-9A-F]{4}, MMIO 0x(?!0000000000000000)[0-9A-F]{16}, sparse identity map 0x[0-9A-F]{16} \+ [1-9][0-9]* bytes using [0-9]+ new table page\(s\)')) {
        throw 'The legacy-PCI xHCI function and BAR discovery marker was not observed.'
    }
} else {
    if (-not [regex]::IsMatch($output, 'xHCI controller discovered at [0-9A-F]{4}:[0-9A-F]{2}:[0-9A-F]{2}\.[0-7], vendor 0x[0-9A-F]{4}, device 0x[0-9A-F]{4}, MMIO 0x[0-9A-F]{16}, sparse identity map 0x[0-9A-F]{16} \+ 2097152 bytes using [12] new table page\(s\)')) {
        throw 'The PCI xHCI controller and BAR discovery marker was not observed.'
    }
}
if (-not [regex]::IsMatch($output, 'xHCI capabilities: version [0-9]+\.[0-9A-F]{2}, [1-9][0-9]* slots, [1-9][0-9]* interrupters, [1-9][0-9]* ports, (32|64)-bit addressing, (32|64)-byte contexts, doorbells \+0x[0-9A-F]{16}, runtime \+0x[0-9A-F]{16}')) {
    throw 'The xHCI capability-register report was not observed.'
}
if (-not [regex]::IsMatch($output, 'xHCI PCI capabilities: count [1-9][0-9]*, MSI absent, MSI-X \+0x90')) {
    throw 'The xHCI PCI MSI-X capability chain was not observed.'
}
if (-not $output.Contains('xHCI MSI-X descriptor: vectors 16, table BAR 0 +0x0000000000003000, PBA BAR 0 +0x0000000000003800')) {
    throw 'The xHCI MSI-X table and pending-bit-array descriptor was not decoded.'
}

if ($NoGraphics -and -not $NoUsbKeyboard) {
    if (-not $output.Contains('USB keyboard attachment visible: 1 connected xHCI port(s); read-only discovery complete')) {
        throw 'The connected keyboard was not visible during serial-only xHCI discovery.'
    }
    if (-not $output.Contains('Framebuffer console unavailable; continuing without interactive USB shell')) {
        throw 'The xHCI serial-only interactive-shell fallback marker was not observed.'
    }
    if (-not $output.Contains('Interactive input ready: USB keyboard no')) {
        throw 'The serial-only USB-input readiness marker was not observed.'
    }
    if ($output.Contains('xHCI ownership active:') -or $output.Contains('ZigOs shell input armed:')) {
        throw 'xHCI ownership or the shell unexpectedly started without a framebuffer console.'
    }
    if ($output.Contains('xHCI MSI-X active:')) { throw 'xHCI MSI-X unexpectedly activated without an owned input path.' }
} elseif ($NoUsbKeyboard) {
    if (-not $output.Contains('USB keyboard attachment visible: 0 connected xHCI port(s); read-only discovery complete')) {
        throw 'The zero-device xHCI port inventory was not observed.'
    }
    if (-not $output.Contains('USB keyboard unavailable; continuing without interactive shell')) {
        throw 'The optional USB-input fallback marker was not observed.'
    }
    if (-not $output.Contains('Interactive input ready: USB keyboard no')) {
        throw 'The no-USB-keyboard readiness marker was not observed.'
    }
    if ($output.Contains('xHCI ownership active:') -or $output.Contains('ZigOs shell input armed:')) {
        throw 'xHCI ownership or the interactive shell unexpectedly started without a USB keyboard.'
    }
    if ($output.Contains('xHCI MSI-X active:')) { throw 'xHCI MSI-X unexpectedly activated without an owned input path.' }
} elseif ($UsbMouseOnly) {
    if (-not $output.Contains('USB keyboard attachment visible: 1 connected xHCI port(s); read-only discovery complete')) {
        throw 'The connected USB mouse was not visible in the xHCI port inventory.'
    }
    if (-not [regex]::IsMatch($output, 'xHCI ownership active: DCBAA 0x[0-9A-F]{16}, command ring 0x[0-9A-F]{16}, event ring 0x[0-9A-F]{16}, ERST 0x[0-9A-F]{16}, page size 4096, scratchpads 0, slots [1-9][0-9]*')) {
        throw 'The xHCI controller was not taken over for the USB mouse identification path.'
    }
    if (-not [regex]::IsMatch($output, "xHCI MSI-X active: capability \+0x90, table entry 0 at 0x[0-9A-F]{16}, vectors 16, vector 0x48, target APIC $expectedLegacyIrqTarget, control 0x[0-9A-F]{4}, mapping pages [0-9]+")) {
        throw 'The xHCI MSI-X vector was not programmed for the selected routable CPU.'
    }
    if (-not [regex]::IsMatch($output, 'xHCI Enable Slot MSI-X completion verified: interrupt count 1, USBSTS 0x[0-9A-F]{16}, IMAN 0x[0-9A-F]{16}')) {
        throw 'xHCI Enable Slot did not complete through exactly one MSI-X interrupt.'
    }
    if (-not [regex]::IsMatch($output, 'xHCI Address Device completed: slot [1-9][0-9]*, USB address [1-9][0-9]*, slot state [2-9][0-9]*, EP0 state [1-7], completion 1, context size (32|64), device context 0x[0-9A-F]{16}, input context 0x[0-9A-F]{16}, EP0 ring 0x[0-9A-F]{16}')) {
        throw 'The USB mouse was not addressed through xHCI.'
    }
    if (-not [regex]::IsMatch($output, 'USB configuration descriptor: total [1-9][0-9]* bytes, value [1-9][0-9]*, interfaces [1-9][0-9]*, attributes 0x[0-9A-F]{2}, max power [0-9]+ mA')) {
        throw 'The USB mouse configuration descriptor was not read.'
    }
    if (-not [regex]::IsMatch($output, 'USB HID boot interface is not a keyboard: class 3/1/2, interface [0-9]+, endpoint 0x8[1-9A-F]; continuing without interactive shell')) {
        throw 'The boot-protocol USB mouse was not classified and skipped correctly.'
    }
    if (-not $output.Contains('Interactive input ready: USB keyboard no')) {
        throw 'The USB-mouse-only input readiness marker was not observed.'
    }
    if ($output.Contains('HID boot keyboard interface:') -or
        $output.Contains('xHCI HID endpoint configured:') -or
        $output.Contains('ZigOs shell input armed:')) {
        throw 'The USB mouse was incorrectly configured as a keyboard.'
    }
} else {
    if (-not [regex]::IsMatch($output, 'USB keyboard attachment visible: [1-9][0-9]* connected xHCI port\(s\); read-only discovery complete')) {
        throw 'The attached USB keyboard was not visible in any xHCI PORTSC register.'
    }
    if (-not [regex]::IsMatch($output, 'xHCI ownership active: DCBAA 0x[0-9A-F]{16}, command ring 0x[0-9A-F]{16}, event ring 0x[0-9A-F]{16}, ERST 0x[0-9A-F]{16}, page size 4096, scratchpads 0, slots [1-9][0-9]*')) {
        throw 'The ZigOs-owned xHCI DCBAA/command/event ring installation marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, "xHCI MSI-X active: capability \+0x90, table entry 0 at 0x[0-9A-F]{16}, vectors 16, vector 0x48, target APIC $expectedLegacyIrqTarget, control 0x[0-9A-F]{4}, mapping pages [0-9]+")) {
        throw 'The xHCI MSI-X vector was not programmed for the selected routable CPU.'
    }
    if (-not [regex]::IsMatch($output, 'xHCI Enable Slot MSI-X completion verified: interrupt count 1, USBSTS 0x[0-9A-F]{16}, IMAN 0x[0-9A-F]{16}')) {
        throw 'xHCI Enable Slot did not complete through exactly one MSI-X interrupt.'
    }
    if (-not [regex]::IsMatch($output, 'xHCI command completed: Enable Slot, completion 1, slot [1-9][0-9]*, command pointer 0x[0-9A-F]{16}, event cycle 1, controller running, (legacy handoff claimed|no legacy handoff required)')) {
        throw 'The xHCI Enable Slot command-completion event was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'xHCI port reset complete: port [1-9][0-9]*, speed ID [1-4], PORTSC 0x[0-9A-F]{16}, EP0 max packet (8|64|512), skipped [1-9][0-9]* port-status event\(s\)')) {
        throw 'The connected xHCI root-hub port reset and EP0 packet-size marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'xHCI Address Device completed: slot [1-9][0-9]*, USB address [1-9][0-9]*, slot state [2-9][0-9]*, EP0 state [1-7], completion 1, context size (32|64), device context 0x[0-9A-F]{16}, input context 0x[0-9A-F]{16}, EP0 ring 0x[0-9A-F]{16}')) {
        throw 'The xHCI Address Device command and device-context verification marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'USB device descriptor read: length 18, type 1, USB BCD 0x[0-9A-F]{4}, class 0x[0-9A-F]{2}:0x[0-9A-F]{2}:0x[0-9A-F]{2}, EP0 packet (8|64)')) {
        throw 'The USB device descriptor control-transfer marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'USB identity: vendor 0x(?!0000)[0-9A-F]{4}, product 0x(?!0000)[0-9A-F]{4}, device BCD 0x[0-9A-F]{4}, configurations [1-9][0-9]*, string indexes [0-9]+/[0-9]+/[0-9]+')) {
        throw 'The USB vendor/product/configuration identity marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'xHCI EP0 transfer completed: completion 1, endpoint 1, slot [1-9][0-9]*, residual 0, event TRB 0x[0-9A-F]{16}, buffer 0x[0-9A-F]{16}')) {
        throw 'The xHCI EP0 Setup/Data/Status transfer-event marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'USB configuration descriptor: total [1-9][0-9]* bytes, value [1-9][0-9]*, interfaces [1-9][0-9]*, attributes 0x[0-9A-F]{2}, max power [0-9]+ mA')) {
        throw 'The complete USB configuration descriptor marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'HID boot keyboard interface: number [0-9]+, alternate 0, endpoints [1-9][0-9]*, class 3/1/1, HID BCD 0x[0-9A-F]{4}, report type 0x22, report length [1-9][0-9]*')) {
        throw 'The boot-keyboard interface and HID descriptor marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'HID interrupt endpoint: address 0x8[1-9A-F], attributes 0x[0-9A-F]{2}, max packet [1-9][0-9]*, interval [1-9][0-9]*, completion 1, residual 0')) {
        throw 'The HID interrupt-IN endpoint descriptor marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'USB SET_CONFIGURATION completed: value [1-9][0-9]*, completion 1')) {
        throw 'The USB SET_CONFIGURATION control transfer was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'xHCI HID endpoint configured: address 0x81, DCI 3, type 7, interval [1-9][0-9]*, max packet 8, max burst 0, max ESIT 8')) {
        throw 'The boot-keyboard interrupt-IN endpoint context marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'xHCI Configure Endpoint completed: completion 1, endpoint state 1, slot context entries 3, input context 0x[0-9A-F]{16}, interrupt ring 0x[0-9A-F]{16}')) {
        throw 'The xHCI Configure Endpoint command-completion marker was not observed.'
    }
    if (-not $keyInjected) {
        throw 'The QEMU HMP harness never injected the A key after the HID arm marker.'
    }
    if (-not [regex]::IsMatch($output, 'HID boot protocol ready: SET_PROTOCOL completion 1, SET_IDLE completion 1')) {
        throw 'The HID boot-protocol and idle-rate control transfers were not observed.'
    }
    if (-not [regex]::IsMatch($output, 'HID input transfer armed: slot [1-9][0-9]*, endpoint 3, length 8, TRB 0x[0-9A-F]{16}, buffer 0x[0-9A-F]{16}; waiting for QEMU key injection')) {
        throw 'The xHCI interrupt-IN keyboard transfer was not armed.'
    }
    if (-not [regex]::IsMatch($output, 'HID keyboard press report received: completion (1|13), residual 0, length 8, MSI-X interrupts [1-9][0-9]*, modifier 0x00, keys 0x04 0x00 0x00 0x00 0x00 0x00')) {
        throw 'The expected eight-byte A-key HID boot report was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'HID release transfer armed: slot [1-9][0-9]*, endpoint 3, length 8, TRB 0x[0-9A-F]{16}, buffer 0x[0-9A-F]{16}; waiting for key release')) {
        throw 'The reusable second HID interrupt-IN transfer was not armed.'
    }
    if (-not [regex]::IsMatch($output, 'HID keyboard release report received: completion (1|13), residual 0, length 8, MSI-X interrupts [1-9][0-9]*, modifier 0x00, keys 0x00 0x00 0x00 0x00 0x00 0x00')) {
        throw 'The expected all-keys-released HID boot report was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'USB keyboard input verified: HID usage 0x04 \(A\), slot [1-9][0-9]*, endpoint 3, press TRB 0x[0-9A-F]{16}, release TRB 0x[0-9A-F]{16}')) {
        throw 'The final USB keyboard usage verification marker was not observed.'
    }
    if (-not $output.Contains("Keyboard event queue verified: #1 USB usage 0x04 pressed -> 'a'; #2 USB usage 0x04 released -> 'a'; dropped 0")) {
        throw 'The ordered device-independent keyboard event queue marker was not observed.'
    }
    if (-not $shellInjected) {
        throw 'The QEMU HMP harness never typed the persistent shell session after the shell arm marker.'
    }
    if (-not $output.Contains('ZigOs shell input armed: commands help cpu mem scroll clear; waiting for QEMU session')) {
        throw 'The persistent native ZigOs shell input marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'xHCI shell MSI-X input verified: [1-9][0-9]* interrupt\(s\) after the shell arm marker')) {
        throw 'The persistent shell did not complete through xHCI MSI-X input interrupts.'
    }
    if (-not $output.Contains('zigos> help') -or -not $output.Contains('commands: help cpu mem')) {
        throw 'The native shell help command or response was not observed.'
    }
    if (-not $output.Contains('zigos> cpu') -or -not $output.Contains('cpu: x86-64 SMP online')) {
        throw 'The native shell cpu command or response was not observed.'
    }
    if (-not $output.Contains('zigos> mem') -or -not $output.Contains('memory: normalized UEFI layout active')) {
        throw 'The native shell mem command or response was not observed.'
    }
    if (-not $output.Contains('zigos> scroll') -or -not $output.Contains('scroll: 32 lines')) {
        throw 'The native shell scroll command or response was not observed.'
    }
    if (-not $output.Contains('zigos> clear') -or -not $output.Contains('clear: screen reset')) {
        throw 'The native shell clear command or response was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'Framebuffer scrolling verified before clear: 32 lines, 37 rows, 6 scrolls, checksum 0x9F06BA73625AD44D')) {
        throw 'The framebuffer scrolling memory-move proof before clear was not observed.'
    }
    if (-not $output.Contains('Framebuffer line editing verified: helx<BS>p -> help')) {
        throw 'The USB Backspace command-line editing proof was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'Framebuffer clear verified: cursor row 0, column 7, writes 7, resets 1, checksum 0x5E875379DEFF239D')) {
        throw 'The full framebuffer clear-and-reset proof was not observed.'
    }
    if (-not $output.Contains('Framebuffer unknown command verified: nope -> error: unknown command')) {
        throw 'The unknown-command error rendering proof was not observed.'
    }
    if (-not $output.Contains('Framebuffer empty command verified: prompt continued without an error response')) {
        throw 'The empty-command prompt-continuation proof was not observed.'
    }
    if (-not $output.Contains('Framebuffer history recall verified: Up -> help')) {
        throw 'The USB Up-arrow command-history recall marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'Framebuffer history shell: cursor row 8, column 35, lines 9, writes 178, newlines 8, resets 1, recalls 1, checksum 0x4721B2F0411D5331, cursor visible, draws 31, erases 30, display checksum 0x030FBD6154A5D1BD')) {
        throw 'The history-recalled framebuffer state was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'ZigOs shell session complete: valid, clear, unknown, empty, recovery, history; commands 10, reports [1-9][0-9]*, rejected 0')) {
        throw 'The persistent native shell history-recovery marker was not observed.'
    }
    if (-not $output.Contains('Interactive input ready: USB keyboard yes')) {
        throw 'The USB-keyboard readiness marker was not observed.'
    }
}
if (-not $output.Contains('NVMe PCI capabilities: count 3, MSI absent, MSI-X +0x40')) {
    throw 'The validated NVMe PCI MSI-X capability chain was not observed.'
}
if (-not $output.Contains('NVMe MSI-X descriptor: vectors 65, table BAR 0 +0x0000000000002000, PBA BAR 0 +0x0000000000003000')) {
    throw 'The NVMe MSI-X table and pending-bit-array descriptors were not observed.'
}
if (-not [regex]::IsMatch($output, 'NVMe controller active at [0-9A-F]{4}:[0-9A-F]{2}:[0-9A-F]{2}\.[0-7], vendor 0x[0-9A-F]{4}, device 0x[0-9A-F]{4}, BAR 0x[0-9A-F]{16}')) {
    throw 'The NVMe PCI function and BAR marker was not observed.'
}
if (-not [regex]::IsMatch($output, 'NVMe capabilities: version [0-9]+\.[0-9]+\.[0-9]+, CAP 0x[0-9A-F]{16}, max queue entries [2-9][0-9]*, doorbell stride [1-9][0-9]*, timeout units [0-9]+')) {
    throw 'The NVMe controller capability-register marker was not observed.'
}
if ($LegacyPci) {
    if (-not [regex]::IsMatch($output, 'NVMe MMIO mapping: 0x(?!0000000000000000)[0-9A-F]{16} \+ [1-9][0-9]* bytes using [0-9]+ new table page\(s\)')) {
        throw 'The legacy-PCI NVMe MMIO mapping marker was not observed.'
    }
} else {
    if (-not [regex]::IsMatch($output, 'NVMe MMIO mapping: 0x000000C000000000 \+ 2097152 bytes using 0 new table page\(s\)')) {
        throw 'The NVMe sparse MMIO mapping marker was not observed.'
    }
}
if (-not [regex]::IsMatch($output, 'NVMe identity: model "[^"]+", serial "ZIGOSNVME", firmware "[^"]+", namespaces [1-9][0-9]*')) {
    throw 'The NVMe Identify Controller result was not observed.'
}
if (-not [regex]::IsMatch($output, "NVMe namespace [1-9][0-9]*: $($nvmeMetadata.total_lbas) LBA\(s\), capacity $($nvmeMetadata.total_lbas) LBA\(s\) x $nvmeBlockSize bytes = $($nvmeMetadata.total_bytes) bytes, metadata 0")) {
    throw 'The NVMe Identify Namespace geometry was not observed.'
}
if (-not [regex]::IsMatch($output, 'NVMe queues active: admin SQ 0x[0-9A-F]{16}, admin CQ 0x[0-9A-F]{16}, I/O SQ 0x[0-9A-F]{16}, I/O CQ 0x[0-9A-F]{16}, depth 16')) {
    throw 'The ZigOs-owned NVMe admin and I/O queues were not observed.'
}
if (-not [regex]::IsMatch($output, "NVMe MSI-X active: vector 0x46, table index 1, target APIC $expectedLegacyIrqTarget, table 0x[0-9A-F]{12}2010, vectors 65, mapping table pages [0-9]+")) {
    throw 'The NVMe MSI-X vector was not programmed for the selected routable CPU.'
}
if (-not $output.Contains("NVMe MSI-X I/O completion verified: vector 0x46, target APIC $expectedLegacyIrqTarget, interrupt count 1")) {
    throw 'The first NVMe data read did not complete through MSI-X.'
}
if (-not [regex]::IsMatch($output, "NVMe READ completed: namespace [1-9][0-9]*, LBA 0, $nvmeBlockSize bytes at 0x[0-9A-F]{16}")) {
    throw 'The read-only NVMe LBA 0 command was not observed.'
}
if (-not $output.Contains('NVMe LBA 0 first 16 bytes: 5A 49 47 4F 53 2D 4E 56 4D 45 2D 4C 42 41 30 21')) {
    throw 'The deterministic NVMe LBA 0 payload was not read correctly.'
}
if (-not $output.Contains("NVMe LBA 0 FNV-1a64: 0x$($nvmeMetadata.lba0_fnv1a64), MBR signature 0xAA55")) {
    throw 'The NVMe LBA 0 fingerprint and protective-MBR signature were not observed.'
}
if (-not $output.Contains("NVMe protective MBR verified: type 0xEE, first LBA 1, sectors $($nvmeMetadata.last_lba)")) {
    throw 'The NVMe protective MBR verification marker was not observed.'
}
if (-not [regex]::IsMatch($output, "NVMe GPT header verified: revision 1\.0, current LBA 1, backup LBA $($nvmeMetadata.last_lba), usable $($nvmeMetadata.first_usable_lba)-$($nvmeMetadata.last_usable_lba), header CRC 0x00000000$($nvmeMetadata.primary_header_crc)")) {
    throw 'The checksum-valid primary GPT header marker was not observed.'
}
if (-not $output.Contains("NVMe GPT partition array verified: 128 entries x 128 bytes at LBA 2, sectors $($nvmeMetadata.entry_array_sectors), populated 1, CRC 0x00000000$($nvmeMetadata.partition_array_crc)")) {
    throw 'The checksum-valid GPT partition-entry-array marker was not observed.'
}
if (-not $output.Contains("NVMe backup GPT verified: current LBA $($nvmeMetadata.last_lba), primary LBA 1, entries LBA $($nvmeMetadata.backup_entry_lba), header CRC 0x00000000$($nvmeMetadata.backup_header_crc), array CRC 0x00000000$($nvmeMetadata.partition_array_crc)")) {
    throw 'The cross-validated backup GPT header and partition array were not observed.'
}
if (-not $output.Contains("NVMe EFI System Partition: index 0, LBA $($nvmeMetadata.partition_first_lba) + $($nvmeMetadata.partition_sectors) sectors, name `"ZigOs NVMe FAT`"")) {
    throw 'The NVMe EFI System Partition discovery marker was not observed.'
}
if (-not $output.Contains("NVMe FAT volume verified: FAT16, label `"ZIGOSNVME`", filesystem `"FAT16`", $($nvmeMetadata.partition_sectors) sectors, first FAT LBA $($nvmeMetadata.first_fat_lba), root LBA $($nvmeMetadata.root_directory_lba)")) {
    throw 'The FAT16 volume inside the NVMe GPT partition was not observed.'
}
if (-not [regex]::IsMatch($output, 'NVMe FAT path resolved: EFI cluster 2 -> BOOT cluster 3 -> BOOTX64.EFI cluster 4')) {
    throw 'The NVMe FAT EFI/BOOT directory traversal was not observed.'
}
if (-not [regex]::IsMatch($output, 'NVMe FAT boot file found: EFI/BOOT/BOOTX64.EFI, size [1-9][0-9]* bytes')) {
    throw 'The NVMe FAT BOOTX64.EFI directory entry was not observed.'
}
$nvmeFilePattern = "NVMe FAT file streamed: ($($nvmeMetadata.efi_size)) bytes across ($($nvmeMetadata.file_cluster_count)) cluster\(s\), last cluster ($($nvmeMetadata.file_last_cluster)), FNV-1a64 0x($($nvmeMetadata.efi_fnv1a64))"
$nvmeFileMatch = [regex]::Match($output, $nvmeFilePattern)
if (-not $nvmeFileMatch.Success) {
    throw 'The complete NVMe FAT file stream was not observed.'
}
$nvmePeMatch = [regex]::Match($output, 'NVMe on-disk PE verified: AMD64 PE32\+, EFI subsystem 10, sections ([1-9][0-9]*), entry RVA 0x([0-9A-F]{16}), image size ([1-9][0-9]*)')
if (-not $nvmePeMatch.Success) {
    throw 'The NVMe-resident BOOTX64.EFI PE validation was not observed.'
}
$builtEfiSize = (Get-Item $efiImage).Length
if ([Int64]$nvmeFileMatch.Groups[1].Value -ne $builtEfiSize) {
    throw "The NVMe FAT file size did not match the built EFI image: NVMe=$($nvmeFileMatch.Groups[1].Value), built=$builtEfiSize."
}

if ($NvmeOnly -or ($LegacyPci -and -not $LegacyAhci)) {
    if ($LegacyPci) {
        if (-not $output.Contains('AHCI controller not present; continuing with another storage backend')) {
            throw 'The legacy machine did not report the expected absence of an AHCI controller.'
        }
        if ($output.Contains('AHCI controller active at')) {
            throw 'An AHCI controller was unexpectedly active on the legacy i440FX machine.'
        }
    } else {
        if (-not $output.Contains('AHCI controller active at')) {
            throw 'The q35 AHCI controller was not enumerated in NVMe-only mode.'
        }
        if (-not $output.Contains('AHCI PCI capabilities: count 2, MSI +0x80, MSI-X absent')) {
            throw 'The q35 AHCI MSI capability chain was not observed in NVMe-only mode.'
        }
        if (-not $output.Contains('AHCI controller has no active SATA devices; continuing with NVMe storage')) {
            throw 'The empty AHCI controller was not skipped in NVMe-only mode.'
        }
    }
    if ($output.Contains('ATA IDENTIFY completed on port')) {
        throw 'ATA IDENTIFY unexpectedly ran without an active AHCI SATA device.'
    }
    if (-not $output.Contains('Storage backends ready: NVMe yes, AHCI no')) {
        throw 'The NVMe-backed storage readiness marker was not observed.'
    }
} else {
    if (-not $output.Contains('AHCI controller active at')) {
        throw 'The AHCI PCI/BAR discovery marker was not observed.'
    }
    if (-not $output.Contains('AHCI PCI capabilities: count 2, MSI +0x80, MSI-X absent')) {
        throw 'The AHCI MSI capability chain was not observed.'
    }
    if (-not $output.Contains('AHCI port inventory:')) {
        throw 'The AHCI port inventory marker was not observed.'
    }
    if (-not $output.Contains('AHCI port 0: SATA active')) {
        throw 'The expected active SATA port was not observed.'
    }
    if (-not $output.Contains('ATA IDENTIFY completed on port 0:')) {
        throw 'The ATA IDENTIFY DEVICE completion marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, "AHCI MSI active: capability \+0x80, vector 0x47, target APIC $expectedLegacyIrqTarget, (32|64)-bit address, control 0x[0-9A-F]{4}")) {
        throw 'The AHCI MSI vector was not programmed for the selected routable CPU.'
    }
    if (-not [regex]::IsMatch($output, 'AHCI IDENTIFY MSI completion verified: interrupt count 1, global IS 0x[0-9A-F]{16}, port IS 0x[0-9A-F]{16}')) {
        throw 'ATA IDENTIFY did not complete through one AHCI MSI interrupt.'
    }
    if (-not $output.Contains('SATA capacity:')) {
        throw 'The decoded SATA capacity marker was not observed.'
    }
    if (-not $output.Contains('AHCI DMA structures:')) {
        throw 'The AHCI DMA structure and transfer marker was not observed.'
    }
    if (-not $output.Contains('transferred 512 bytes')) {
        throw 'ATA IDENTIFY did not report a complete 512-byte DMA transfer.'
    }
    if (-not $output.Contains('READ DMA EXT completed: LBA 0')) {
        throw 'The read-only ATA sector DMA marker was not observed.'
    }
    if (-not [regex]::IsMatch($output, "AHCI READ DMA MSI completion verified: vector 0x47, target APIC $expectedLegacyIrqTarget, interrupt count 1, global IS 0x[0-9A-F]{16}, port IS 0x[0-9A-F]{16}")) {
        throw 'READ DMA EXT did not complete through one AHCI MSI interrupt.'
    }
    if ($LegacyAhci) {
        if (-not $output.Contains('Legacy PCI configuration active: mechanism #1 ports 0x0CF8/0x0CFC, buses scanned 256')) {
            throw 'The legacy-AHCI matrix did not use PCI configuration mechanism 1.'
        }
        if (-not [regex]::IsMatch($output, 'AHCI controller active at 0000:[0-9A-F]{2}:[0-9A-F]{2}\.[0-7], ABAR 0x[0-9A-F]{16}')) {
            throw 'The add-on ICH9 AHCI controller was not enumerated through legacy PCI configuration.'
        }
    }
    if (-not $output.Contains('LBA 0 FNV-1a64:')) {
        throw 'The LBA 0 sector fingerprint marker was not observed.'
    }
    if (-not $output.Contains('trailing signature 0xAA55')) {
        throw 'The expected LBA 0 MBR signature was not observed.'
    }
    if (-not $output.Contains('MBR parsed:')) {
        throw 'The MBR partition-table parser marker was not observed.'
    }
    if (-not $output.Contains('FAT volume detected: FAT16')) {
        throw 'The FAT volume classification marker was not observed.'
    }
    if (-not $output.Contains('FAT layout:')) {
        throw 'The FAT geometry/layout marker was not observed.'
    }
    if (-not $output.Contains('FAT root entry: EFI <DIR>')) {
        throw 'The FAT root-directory decoding marker was not observed.'
    }
    if (-not $output.Contains('FAT path resolved: EFI cluster')) {
        throw 'The FAT cluster-chain path-resolution marker was not observed.'
    }
    if (-not $output.Contains('FAT boot file found: EFI/BOOT/BOOTX64.EFI')) {
        throw 'The FAT boot-file lookup marker was not observed.'
    }
    $ahciFileMatch = [regex]::Match($output, '(?m)^FAT file streamed: ([1-9][0-9]*) bytes across ([1-9][0-9]*) cluster\(s\), last cluster ([1-9][0-9]*), FNV-1a64 0x([0-9A-F]{16})\r?$')
    if (-not $ahciFileMatch.Success) {
        throw 'The complete AHCI FAT file-stream marker was not observed.'
    }
    if ($nvmeFileMatch.Groups[1].Value -ne $ahciFileMatch.Groups[1].Value -or
        $nvmeFileMatch.Groups[4].Value -ne $ahciFileMatch.Groups[4].Value) {
        throw "NVMe and AHCI streamed different BOOTX64.EFI content: NVMe size/hash $($nvmeFileMatch.Groups[1].Value)/$($nvmeFileMatch.Groups[4].Value), AHCI size/hash $($ahciFileMatch.Groups[1].Value)/$($ahciFileMatch.Groups[4].Value)."
    }
    if (-not $output.Contains('On-disk PE verified: AMD64 PE32+, EFI subsystem 10')) {
        throw 'The on-disk AMD64 PE32+ EFI validation marker was not observed.'
    }
    if (-not $output.Contains('Storage backends ready: NVMe yes, AHCI yes')) {
        throw 'The dual NVMe/AHCI storage readiness marker was not observed.'
    }
}
if (-not $output.Contains('Kernel heap active:')) {
    throw 'The kernel heap initialization marker was not observed.'
}
if (-not $output.Contains('Heap allocator verified: aligned alloc/free, split, coalesce')) {
    throw 'The kernel heap invariant test marker was not observed.'
}
if (-not (Test-Path $serialLog)) {
    throw 'QEMU produced no COM1 serial log.'
}
$serialOutput = Get-Content $serialLog -Raw
Write-Host '=== ZigOs COM1 serial output ==='
Write-Host $serialOutput
if (-not $NoGraphics -and ($NoUsbKeyboard -or $UsbMouseOnly) -and -not $serialOutput.Contains('resets 0, lit pixels 1744')) {
    throw 'COM1 decimal formatting dropped the zero-valued framebuffer reset counter.'
}
if (-not $LegacyPci -and -not $serialOutput.Contains('BdsDxe: starting Boot0001 "UEFI QEMU NVMe Ctrl ZIGOSNVME 1"')) {
    throw 'OVMF did not report the expected q35 NVMe Boot0001 path.'
}
if (-not $serialOutput.Contains('ZigOs COM1 serial diagnostics online')) {
    throw 'The COM1 loopback-tested online marker was not captured.'
}
if (-not $serialOutput.Contains('ZigOs boot sequence complete')) {
    throw 'The final boot marker was not mirrored to COM1.'
}
if (-not $output.Contains('Cooperative scheduler active: 2 tasks, 13 context switches, trace ABABABABABBB')) {
    throw 'The deterministic cooperative scheduler marker was not observed.'
}
if (-not $output.Contains('Scheduler stack canaries intact; execution returned to the kernel context.')) {
    throw 'The scheduler stack-integrity and kernel-return marker was not observed.'
}
if (-not $output.Contains('Preemptive scheduler active: APIC periodic count')) {
    throw 'The timer-driven preemptive scheduler marker was not observed.'
}
if (-not $output.Contains('Timer-frame GPR/FX state switching verified; no task called yield.')) {
    throw 'The full interrupt-frame preemption proof marker was not observed.'
}
if (-not $output.Contains('Preemptive stack canaries intact; kernel interrupt frame restored.')) {
    throw 'The preemptive stack-integrity and kernel-frame restoration marker was not observed.'
}
if (-not $output.Contains('CPL3 userspace active:')) {
    throw 'The isolated CPL3 page-mapping marker was not observed.'
}
if (-not $output.Contains('int 0x80 syscall frame verified: CS=0x0033, SS=0x002B')) {
    throw 'The RPL3 syscall-frame selector marker was not observed.'
}
if (-not $output.Contains('CPL3 -> kernel -> CPL3 -> kernel round trip complete; stack canary intact.')) {
    throw 'The userspace syscall-return and kernel-restoration marker was not observed.'
}
if ($NoGraphics) {
    if (-not $output.Contains('Framebuffer console unavailable; serial-only diagnostics active')) {
        throw 'The final serial-only framebuffer marker was not observed.'
    }
    if ($output.Contains('Framebuffer console active:') -or
        $output.Contains('Framebuffer transcript:') -or
        $output.Contains('Framebuffer retained and written directly at 0x')) {
        throw 'Framebuffer output was unexpectedly used in no-graphics mode.'
    }
} elseif ($NoUsbKeyboard -or $UsbMouseOnly) {
    if (-not [regex]::IsMatch($output, 'Framebuffer console active: 1280x800, stride 1280, lines 4, glyphs 31, resets 0, lit pixels 1744, checksum 0x866AA691AB18DEB5, cursor visible, draws 6, erases 5, display lit pixels 1764, display checksum 0x7CF72F9AF061C761')) {
        throw 'The unchanged startup-prompt framebuffer state was not observed without a USB keyboard.'
    }
    if (-not $output.Contains('Framebuffer transcript: startup prompt; USB keyboard unavailable')) {
        throw 'The keyboard-less framebuffer transcript marker was not observed.'
    }
    if (-not $output.Contains('Framebuffer retained and written directly at 0x')) {
        throw 'The framebuffer was not retained and accessed after the handoff.'
    }
} else {
    if (-not [regex]::IsMatch($output, 'Framebuffer console active: 1280x800, stride 1280, lines 9, glyphs 178, resets 1, lit pixels 9492, checksum 0x4721B2F0411D5331, cursor visible, draws 31, erases 30, display lit pixels 9512, display checksum 0x030FBD6154A5D1BD')) {
        throw 'The deterministic GOP bitmap-console report was not observed.'
    }
    if (-not $output.Contains('Framebuffer transcript: clear, error recovery, and Up-arrow history recall')) {
        throw 'The rendered graphical-console transcript marker was not observed.'
    }
    if (-not $output.Contains('Framebuffer retained and written directly at 0x')) {
        throw 'The framebuffer was not retained and accessed after the handoff.'
    }
}

Write-Host 'QEMU boot test passed.'
} finally {
    if ($testMutexAcquired) {
        $testMutex.ReleaseMutex()
    }
    $testMutex.Dispose()
}
