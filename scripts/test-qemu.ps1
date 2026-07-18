[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 30,
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
    [switch]$Network
)

$ErrorActionPreference = 'Stop'
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
if ($NoHpet) {
    if (-not $output.Contains('HPET not present')) {
        throw 'The no-HPET ACPI topology marker was not observed.'
    }
    if (-not $output.Contains('PIT channel 2 reference active: 1193182 Hz polled one-shot, no IRQ route')) {
        throw 'The PIT channel 2 reference-clock fallback marker was not observed.'
    }
    if ($output.Contains('HPET active:')) {
        throw 'HPET unexpectedly initialized while disabled.'
    }
    if (-not [regex]::IsMatch($output, 'APIC timer calibrated with PIT channel 2: [1-9][0-9]* ticks/s, one-shot count [1-9][0-9]*')) {
        throw 'The PIT-calibrated APIC timer rate was not observed.'
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
    if (-not [regex]::IsMatch($output, 'e1000e UDP endpoint lifecycle verified: table 4, usable queue 7, duplicate slot 2, full-table rejection yes, queue slot 2 7/7 high-water 7 dropped 1, busy unregister rejected yes, reuse slot 2, final endpoints 2, ingress 21/21 dropped 0, dispatch total/UDP 18/17, unmatched 1, completions TX 25/25 RX 22/22, overflow 0, pending TX 0x0000000000000000, RX 0x00000000000000FF')) {
        throw 'The UDP endpoint lifecycle did not preserve FIFO order, enforce capacity, or safely reuse a drained slot.'
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

if ($NoGraphics) {
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
