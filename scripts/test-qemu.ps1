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
if (-not $output.Contains('PCIe ECAM active:')) {
    throw 'The PCIe MCFG/ECAM activation marker was not observed.'
}
if (-not $output.Contains('PCI inventory:')) {
    throw 'The PCI function inventory marker was not observed.'
}
if (-not $output.Contains('PCI function ')) {
    throw 'No enumerated PCI function was printed.'
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
