[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$efiRoot = Join-Path $repoRoot 'zig-out'
$efiImage = Join-Path $efiRoot 'EFI\BOOT\BOOTX64.EFI'
$buildDir = Join-Path $repoRoot 'build'
$debugLog = Join-Path $repoRoot 'qemu-debug.log'
$serialLog = Join-Path $repoRoot 'qemu-serial.log'
$qemuStdout = Join-Path $repoRoot 'qemu-stdout.log'
$qemuStderr = Join-Path $repoRoot 'qemu-stderr.log'

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
$codeImage = Join-Path $buildDir 'ovmf-code.fd'
$varsImage = Join-Path $buildDir 'ovmf-vars.fd'
Copy-Item $codeSource $codeImage -Force
Copy-Item $varsSource $varsImage -Force

Remove-Item $debugLog, $serialLog, $qemuStdout, $qemuStderr -Force -ErrorAction SilentlyContinue
$fatPath = $efiRoot.Replace('\', '/')
$codePath = $codeImage.Replace('\', '/')
$varsPath = $varsImage.Replace('\', '/')
$debugPath = $debugLog.Replace('\', '/')
$serialPath = $serialLog.Replace('\', '/')

$arguments = @(
    '-machine', 'q35',
    '-m', '256M',
    '-cpu', 'max',
    '-smp', '4',
    '-device', 'qemu-xhci,id=xhci',
    '-device', 'usb-kbd,bus=xhci.0,port=1',
    '-drive', "if=pflash,format=raw,unit=0,readonly=on,file=$codePath",
    '-drive', "if=pflash,format=raw,unit=1,file=$varsPath",
    '-drive', "format=raw,file=fat:rw:$fatPath",
    '-debugcon', "file:$debugPath",
    '-global', 'isa-debugcon.iobase=0xe9',
    '-display', 'none',
    '-serial', "file:$serialPath",
    '-monitor', 'none',
    '-net', 'none',
    '-no-reboot'
)

Write-Host "Booting ZigOs in QEMU with $codeSource"
$process = Start-Process -FilePath $qemu -ArgumentList $arguments -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr -PassThru -WindowStyle Hidden
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$marker = 'ZigOs boot sequence complete'
$captured = $false

try {
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        if (Test-Path $debugLog) {
            $text = Get-Content $debugLog -Raw -ErrorAction SilentlyContinue
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
if (-not $output.Contains('MADT topology: 4 processors')) {
    throw 'The four-CPU MADT topology marker was not observed.'
}
if (-not $output.Contains('MADT processor IDs: 0(xAPIC) 1(xAPIC) 2(xAPIC) 3(xAPIC)')) {
    throw 'The expected retained MADT APIC-ID set was not observed.'
}
if (-not $output.Contains('Local APIC enabled:')) {
    throw 'The local APIC enablement marker was not observed.'
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
if (-not [regex]::IsMatch($output, 'External IRQ routed: ISA IRQ 0 -> GSI 2 -> vector 0x44, BSP APIC 0, PIT divisor [1-9][0-9]*, count 1, active-high, edge, remasked after EOI')) {
    throw 'The MADT/IOAPIC/PIT external IRQ0 round trip was not observed.'
}
if (-not [regex]::IsMatch($output, 'PS/2 keyboard IRQ verified: ISA IRQ 1 -> GSI 1 -> vector 0x45, injected scan code 0x1E, captured 0x1E, count 1, command byte 0x[0-9A-F]{2}, remasked and restored after EOI')) {
    throw 'The i8042/IOAPIC PS/2 keyboard IRQ and scan-code capture were not observed.'
}
if (-not $output.Contains('HPET active:')) {
    throw 'The HPET initialization marker was not observed.'
}
if (-not $output.Contains('APIC timer calibrated:')) {
    throw 'The APIC timer calibration marker was not observed.'
}
if (-not $output.Contains('Maskable interrupt vector 0x0040 handled')) {
    throw 'The APIC timer interrupt round trip was not observed.'
}
$descriptorMatches = [regex]::Matches($output, 'AP private descriptors: GDT 0x[0-9A-F]+, TSS 0x[0-9A-F]+, IDT 0x[0-9A-F]+, CS 0x0008, TR 0x0018, checksum 0x(?!0000000000000000)[0-9A-F]{16}')
if ($descriptorMatches.Count -ne 3) {
    throw 'All three AP-private GDT/TSS/IDT verification records were not observed.'
}
$mailboxMatches = [regex]::Matches($output, 'AP mailbox complete: APIC [123], epoch 1, input 0x[0-9A-F]{16}, result 0x(?!0000000000000000)[0-9A-F]{16}')
if ($mailboxMatches.Count -ne 3) {
    throw 'All three AP mailbox completion records were not observed.'
}
$runQueueMatches = [regex]::Matches($output, 'AP run queue complete: APIC [123], queued 4, completed 4, last sequence 4, checksum 0x(?!0000000000000000)[0-9A-F]{16}')
if ($runQueueMatches.Count -ne 3) {
    throw 'All three per-CPU FIFO run-queue completion records were not observed.'
}
$stealMatches = [regex]::Matches($output, 'AP work stealing: APIC [23] executed 2 stolen jobs')
if ($stealMatches.Count -ne 2) {
    throw 'Both idle application processors did not execute their deterministic steal quotas.'
}
if (-not [regex]::IsMatch($output, 'Work stealing complete: source APIC 1, jobs 8, owner 4, stolen 4, checksum 0x(?!0000000000000000)[0-9A-F]{16}')) {
    throw 'The deterministic multicore work-stealing verification marker was not observed.'
}
$ipiWakeMatches = [regex]::Matches($output, 'AP targeted IPI: APIC [123], vector 0x42, wake 1, halts [2-9][0-9]*, checksum 0x(?!0000000000000000)[0-9A-F]{16}')
if ($ipiWakeMatches.Count -ne 3) {
    throw 'All three application processors did not wake from HLT through targeted vector 0x42.'
}
if (-not $output.Contains('Targeted AP wakeups complete: vector 0x42, 3/3 APs woke from HLT and acknowledged EOI')) {
    throw 'The targeted AP IPI/HLT/EOI aggregate marker was not observed.'
}
$apTimerMatches = [regex]::Matches($output, 'AP local timer: APIC [123], vector 0x43, count [1-9][0-9]*, interrupts 1, epoch 1, halts [3-9][0-9]*')
if ($apTimerMatches.Count -ne 3) {
    throw 'All three application processors did not handle their private local-APIC timer interrupt.'
}
if (-not [regex]::IsMatch($output, 'Per-AP timers complete: vector 0x43, count [1-9][0-9]*, 3/3 APs woke autonomously from local timer interrupts')) {
    throw 'The per-AP autonomous local-timer aggregate marker was not observed.'
}
$tickSchedulerMatches = [regex]::Matches($output, 'AP tick scheduler: APIC [123], jobs 3, ticks 3, dispatches 3, halts [6-9][0-9]*, checksum 0x(?!0000000000000000)[0-9A-F]{16}')
if ($tickSchedulerMatches.Count -ne 3) {
    throw 'All three per-AP tick schedulers did not dispatch exactly one job per timer quantum.'
}
if (-not [regex]::IsMatch($output, 'Per-AP tick schedulers complete: jobs 3/core, quantum count [1-9][0-9]*, 3/3 APs dispatched exactly one job per timer tick')) {
    throw 'The aggregate per-AP tick-scheduler marker was not observed.'
}
$apTaskMatches = [regex]::Matches($output, 'AP local tasks: APIC [123], stacks 0x[0-9A-F]+/0x[0-9A-F]+, switches 13, yields 5/7, trace ABABABABABBB, canaries intact')
if ($apTaskMatches.Count -ne 3) {
    throw 'All three application processors did not complete their independent two-stack cooperative task experiment.'
}
if (-not $output.Contains('Per-AP task contexts complete: 3/3 APs, total context switches 39, trace ABABABABABBB on every core')) {
    throw 'The aggregate per-AP task-context verification marker was not observed.'
}
$syncWorkerMatches = [regex]::Matches($output, 'AP synchronization worker: APIC [123], worker [123], acquisitions 4096, barrier generation 1')
if ($syncWorkerMatches.Count -ne 3) {
    throw 'All three AP ticket-lock/barrier workers did not complete.'
}
if (-not [regex]::IsMatch($output, 'SMP synchronization complete: 4 participants, 16384 locked increments, tickets 16384/16384, barrier generation 1, checksum 0x(?!0000000000000000)[0-9A-F]{16}')) {
    throw 'The four-core ticket-lock and barrier verification marker was not observed.'
}
if (-not $output.Contains('PCIe ECAM active:')) {
    throw 'The PCIe MCFG/ECAM activation marker was not observed.'
}
if (-not $output.Contains('PCI inventory:')) {
    throw 'The PCI function inventory marker was not observed.'
}
if (-not $output.Contains('PCI function ')) {
    throw 'No enumerated PCI function was printed.'
}
if (-not [regex]::IsMatch($output, 'xHCI controller discovered at [0-9A-F]{4}:[0-9A-F]{2}:[0-9A-F]{2}\.[0-7], vendor 0x[0-9A-F]{4}, device 0x[0-9A-F]{4}, MMIO 0x000000C000000000, sparse identity map 0x000000C000000000 \+ 2097152 bytes using [12] new table page\(s\)')) {
    throw 'The PCI xHCI controller and BAR discovery marker was not observed.'
}
if (-not [regex]::IsMatch($output, 'xHCI capabilities: version [0-9]+\.[0-9A-F]{2}, [1-9][0-9]* slots, [1-9][0-9]* interrupters, [1-9][0-9]* ports, (32|64)-bit addressing, (32|64)-byte contexts, doorbells \+0x[0-9A-F]{16}, runtime \+0x[0-9A-F]{16}')) {
    throw 'The xHCI capability-register report was not observed.'
}
if (-not [regex]::IsMatch($output, 'USB keyboard attachment visible: [1-9][0-9]* connected xHCI port\(s\); read-only discovery complete')) {
    throw 'The attached USB keyboard was not visible in any xHCI PORTSC register.'
}
if (-not [regex]::IsMatch($output, 'xHCI ownership active: DCBAA 0x[0-9A-F]{16}, command ring 0x[0-9A-F]{16}, event ring 0x[0-9A-F]{16}, ERST 0x[0-9A-F]{16}, page size 4096, scratchpads 0, slots [1-9][0-9]*')) {
    throw 'The ZigOs-owned xHCI DCBAA/command/event ring installation marker was not observed.'
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
if (-not $output.Contains('AHCI controller active at')) {
    throw 'The AHCI PCI/BAR discovery marker was not observed.'
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
if (-not $output.Contains('FAT file streamed:')) {
    throw 'The complete FAT file-stream marker was not observed.'
}
if (-not $output.Contains('On-disk PE verified: AMD64 PE32+, EFI subsystem 10')) {
    throw 'The on-disk AMD64 PE32+ EFI validation marker was not observed.'
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
if (-not $output.Contains('Framebuffer retained and written directly at 0x')) {
    throw 'The framebuffer was not retained and accessed after the handoff.'
}

Write-Host 'QEMU boot test passed.'
