[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 30,
    [switch]$NvmeOnly,
    [switch]$NoUsbKeyboard
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
$nvmeImage = Join-Path $buildDir 'nvme-test.img'

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
Add-Type -TypeDefinition @'
namespace ZigOs {
    public static class Crc32 {
        public static uint Compute(byte[] data, int offset, int count) {
            uint crc = 0xFFFFFFFFu;
            for (int index = 0; index < count; index++) {
                crc ^= data[offset + index];
                for (int bit = 0; bit < 8; bit++) {
                    uint mask = (uint)-(int)(crc & 1u);
                    crc = (crc >> 1) ^ (0xEDB88320u & mask);
                }
            }
            return ~crc;
        }
    }
}
'@

function Set-Le16([byte[]]$Buffer, [int]$Offset, [UInt16]$Value) {
    [Array]::Copy([BitConverter]::GetBytes($Value), 0, $Buffer, $Offset, 2)
}
function Set-Le32([byte[]]$Buffer, [int]$Offset, [UInt32]$Value) {
    [Array]::Copy([BitConverter]::GetBytes($Value), 0, $Buffer, $Offset, 4)
}
function Set-Le64([byte[]]$Buffer, [int]$Offset, [UInt64]$Value) {
    [Array]::Copy([BitConverter]::GetBytes($Value), 0, $Buffer, $Offset, 8)
}
function Set-Fat16Entry([byte[]]$Fat, [UInt16]$Cluster, [UInt16]$Value) {
    Set-Le16 $Fat ([int]$Cluster * 2) $Value
}
function Set-FatDirectoryEntry(
    [byte[]]$Buffer,
    [int]$Offset,
    [string]$ShortName,
    [byte]$Attributes,
    [UInt16]$FirstCluster,
    [UInt32]$FileSize
) {
    if ($ShortName.Length -ne 11) { throw "FAT short names must contain exactly 11 characters." }
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes($ShortName), 0, $Buffer, $Offset, 11)
    $Buffer[$Offset + 11] = $Attributes
    Set-Le16 $Buffer ($Offset + 20) 0
    Set-Le16 $Buffer ($Offset + 26) $FirstCluster
    Set-Le32 $Buffer ($Offset + 28) $FileSize
}
function New-GptHeader(
    [UInt64]$CurrentLba,
    [UInt64]$BackupLba,
    [UInt64]$EntryLba,
    [UInt32]$EntryArrayCrc,
    [byte[]]$DiskGuid
) {
    [byte[]]$header = [byte[]]::new(512)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('EFI PART'), 0, $header, 0, 8)
    Set-Le32 $header 8 0x00010000
    Set-Le32 $header 12 92
    Set-Le64 $header 24 $CurrentLba
    Set-Le64 $header 32 $BackupLba
    Set-Le64 $header 40 34
    Set-Le64 $header 48 32734
    [Array]::Copy($DiskGuid, 0, $header, 56, 16)
    Set-Le64 $header 72 $EntryLba
    Set-Le32 $header 80 128
    Set-Le32 $header 84 128
    Set-Le32 $header 88 $EntryArrayCrc
    Set-Le32 $header 16 ([ZigOs.Crc32]::Compute($header, 0, 92))
    return $header
}

[UInt64]$nvmeTotalSectors = 32768
[UInt64]$nvmeLastLba = $nvmeTotalSectors - 1
[UInt64]$primaryEntriesLba = 2
[UInt64]$backupEntriesLba = 32735
[UInt64]$partitionFirstLba = 2048
[UInt64]$partitionLastLba = 32734
[UInt32]$partitionSectors = [UInt32]($partitionLastLba - $partitionFirstLba + 1)

[byte[]]$protectiveMbr = [byte[]]::new(512)
[byte[]]$nvmeMarker = [Text.Encoding]::ASCII.GetBytes('ZIGOS-NVME-LBA0!')
[Array]::Copy($nvmeMarker, 0, $protectiveMbr, 0, $nvmeMarker.Length)
$protectiveMbr[446] = 0x00
$protectiveMbr[447] = 0x00
$protectiveMbr[448] = 0x02
$protectiveMbr[449] = 0x00
$protectiveMbr[450] = 0xEE
$protectiveMbr[451] = 0xFF
$protectiveMbr[452] = 0xFF
$protectiveMbr[453] = 0xFF
Set-Le32 $protectiveMbr 454 1
Set-Le32 $protectiveMbr 458 ([UInt32]($nvmeTotalSectors - 1))
$protectiveMbr[510] = 0x55
$protectiveMbr[511] = 0xAA

[byte[]]$partitionEntries = [byte[]]::new(128 * 128)
[byte[]]$efiSystemGuid = 0x28,0x73,0x2A,0xC1,0x1F,0xF8,0xD2,0x11,0xBA,0x4B,0x00,0xA0,0xC9,0x3E,0xC9,0x3B
[byte[]]$partitionGuid = 0x44,0x33,0x22,0x11,0x66,0x55,0x88,0x77,0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0xF0,0x01
[Array]::Copy($efiSystemGuid, 0, $partitionEntries, 0, 16)
[Array]::Copy($partitionGuid, 0, $partitionEntries, 16, 16)
Set-Le64 $partitionEntries 32 $partitionFirstLba
Set-Le64 $partitionEntries 40 $partitionLastLba
[byte[]]$partitionName = [Text.Encoding]::Unicode.GetBytes('ZigOs NVMe FAT')
[Array]::Copy($partitionName, 0, $partitionEntries, 56, $partitionName.Length)
[UInt32]$partitionArrayCrc = [ZigOs.Crc32]::Compute($partitionEntries, 0, $partitionEntries.Length)

[byte[]]$diskGuid = 0x78,0x56,0x34,0x12,0xBC,0x9A,0xF0,0xDE,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88
[byte[]]$primaryHeader = New-GptHeader 1 $nvmeLastLba $primaryEntriesLba $partitionArrayCrc $diskGuid
[byte[]]$backupHeader = New-GptHeader $nvmeLastLba 1 $backupEntriesLba $partitionArrayCrc $diskGuid

[byte[]]$fatBootSector = [byte[]]::new(512)
$fatBootSector[0] = 0xEB
$fatBootSector[1] = 0x3C
$fatBootSector[2] = 0x90
[Array]::Copy([Text.Encoding]::ASCII.GetBytes('ZIGOS   '), 0, $fatBootSector, 3, 8)
Set-Le16 $fatBootSector 11 512
$fatBootSector[13] = 1
Set-Le16 $fatBootSector 14 1
$fatBootSector[16] = 2
Set-Le16 $fatBootSector 17 512
Set-Le16 $fatBootSector 19 ([UInt16]$partitionSectors)
$fatBootSector[21] = 0xF8
Set-Le16 $fatBootSector 22 120
Set-Le16 $fatBootSector 24 63
Set-Le16 $fatBootSector 26 255
Set-Le32 $fatBootSector 28 ([UInt32]$partitionFirstLba)
$fatBootSector[36] = 0x80
$fatBootSector[38] = 0x29
Set-Le32 $fatBootSector 39 0x5A49474F
[Array]::Copy([Text.Encoding]::ASCII.GetBytes('ZIGOSNVME  '), 0, $fatBootSector, 43, 11)
[Array]::Copy([Text.Encoding]::ASCII.GetBytes('FAT16   '), 0, $fatBootSector, 54, 8)
$fatBootSector[510] = 0x55
$fatBootSector[511] = 0xAA

[byte[]]$nvmeEfiBytes = [IO.File]::ReadAllBytes($efiImage)
[UInt32]$nvmeFileClusterCount = [UInt32][Math]::Ceiling($nvmeEfiBytes.Length / 512.0)
if ($nvmeFileClusterCount -eq 0 -or $nvmeFileClusterCount -gt 30000) {
    throw 'The current BOOTX64.EFI did not fit the deterministic NVMe FAT16 volume.'
}
[UInt16]$nvmeFileFirstCluster = 4
[UInt16]$nvmeFileLastCluster = [UInt16]($nvmeFileFirstCluster + $nvmeFileClusterCount - 1)
[byte[]]$nvmeFat = [byte[]]::new(120 * 512)
Set-Fat16Entry $nvmeFat 0 0xFFF8
Set-Fat16Entry $nvmeFat 1 0xFFFF
Set-Fat16Entry $nvmeFat 2 0xFFFF
Set-Fat16Entry $nvmeFat 3 0xFFFF
for ([UInt32]$cluster = $nvmeFileFirstCluster; $cluster -lt $nvmeFileLastCluster; $cluster++) {
    Set-Fat16Entry $nvmeFat ([UInt16]$cluster) ([UInt16]($cluster + 1))
}
Set-Fat16Entry $nvmeFat $nvmeFileLastCluster 0xFFFF

[byte[]]$nvmeRootDirectory = [byte[]]::new(32 * 512)
Set-FatDirectoryEntry $nvmeRootDirectory 0 'EFI        ' 0x10 2 0
$nvmeRootDirectory[32] = 0
[byte[]]$nvmeEfiDirectory = [byte[]]::new(512)
Set-FatDirectoryEntry $nvmeEfiDirectory 0 'BOOT       ' 0x10 3 0
$nvmeEfiDirectory[32] = 0
[byte[]]$nvmeBootDirectory = [byte[]]::new(512)
Set-FatDirectoryEntry $nvmeBootDirectory 0 'BOOTX64 EFI' 0x20 $nvmeFileFirstCluster ([UInt32]$nvmeEfiBytes.Length)
$nvmeBootDirectory[32] = 0

$nvmeStream = [IO.File]::Open($nvmeImage, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
try {
    $nvmeStream.SetLength(16MB)
    $nvmeStream.Position = 0
    $nvmeStream.Write($protectiveMbr, 0, $protectiveMbr.Length)
    $nvmeStream.Position = 512
    $nvmeStream.Write($primaryHeader, 0, $primaryHeader.Length)
    $nvmeStream.Position = $primaryEntriesLba * 512
    $nvmeStream.Write($partitionEntries, 0, $partitionEntries.Length)
    $nvmeStream.Position = $backupEntriesLba * 512
    $nvmeStream.Write($partitionEntries, 0, $partitionEntries.Length)
    $nvmeStream.Position = $nvmeLastLba * 512
    $nvmeStream.Write($backupHeader, 0, $backupHeader.Length)
    $nvmeStream.Position = $partitionFirstLba * 512
    $nvmeStream.Write($fatBootSector, 0, $fatBootSector.Length)
    $nvmeStream.Position = ($partitionFirstLba + 1) * 512
    $nvmeStream.Write($nvmeFat, 0, $nvmeFat.Length)
    $nvmeStream.Position = ($partitionFirstLba + 121) * 512
    $nvmeStream.Write($nvmeFat, 0, $nvmeFat.Length)
    $nvmeStream.Position = ($partitionFirstLba + 241) * 512
    $nvmeStream.Write($nvmeRootDirectory, 0, $nvmeRootDirectory.Length)
    $nvmeStream.Position = ($partitionFirstLba + 273) * 512
    $nvmeStream.Write($nvmeEfiDirectory, 0, $nvmeEfiDirectory.Length)
    $nvmeStream.Position = ($partitionFirstLba + 274) * 512
    $nvmeStream.Write($nvmeBootDirectory, 0, $nvmeBootDirectory.Length)
    $nvmeStream.Position = ($partitionFirstLba + 275) * 512
    $nvmeStream.Write($nvmeEfiBytes, 0, $nvmeEfiBytes.Length)
    $nvmeStream.Flush()
}
finally {
    $nvmeStream.Dispose()
}
$nvmePath = $nvmeImage.Replace('\', '/')
$codePath = $codeImage.Replace('\', '/')
$varsPath = $varsImage.Replace('\', '/')
$debugPath = $debugLog.Replace('\', '/')
$serialPath = $serialLog.Replace('\', '/')

$monitorListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$monitorListener.Start()
$monitorPort = ([System.Net.IPEndPoint]$monitorListener.LocalEndpoint).Port
$monitorListener.Stop()
$monitorEndpoint = "tcp:127.0.0.1:$monitorPort,server=on,wait=off"

$arguments = @(
    '-machine', 'q35',
    '-m', '256M',
    '-cpu', 'max',
    '-smp', '4',
    '-device', 'qemu-xhci,id=xhci',
    '-drive', "file=$nvmePath,if=none,id=nvme0,format=raw,cache=unsafe",
    '-device', 'nvme,drive=nvme0,serial=ZIGOSNVME',
    '-drive', "if=pflash,format=raw,unit=0,readonly=on,file=$codePath",
    '-drive', "if=pflash,format=raw,unit=1,file=$varsPath",
    '-debugcon', "file:$debugPath",
    '-global', 'isa-debugcon.iobase=0xe9',
    '-display', 'none',
    '-serial', "file:$serialPath",
    '-monitor', $monitorEndpoint,
    '-net', 'none',
    '-no-reboot'
)
if (-not $NvmeOnly) {
    $arguments += @('-drive', "format=raw,file=fat:rw:$fatPath")
}
if (-not $NoUsbKeyboard) {
    $arguments += @('-device', 'usb-kbd,bus=xhci.0,port=1')
}

Write-Host "Booting ZigOs in QEMU with $codeSource (NVMe-only: $NvmeOnly, no USB keyboard: $NoUsbKeyboard)"
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
            if (-not $NoUsbKeyboard -and $text -and -not $keyInjected -and $text.Contains($inputMarker)) {
                $client = [System.Net.Sockets.TcpClient]::new()
                try {
                    $client.Connect('127.0.0.1', $monitorPort)
                    $stream = $client.GetStream()
                    $writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::ASCII)
                    $writer.NewLine = "`n"
                    $writer.AutoFlush = $true
                    Start-Sleep -Milliseconds 50
                    $writer.WriteLine('sendkey a 500')
                    $keyInjected = $true
                    $writer.Dispose()
                }
                finally {
                    $client.Dispose()
                }
            }
            if (-not $NoUsbKeyboard -and $text -and $keyInjected -and -not $shellInjected -and $text.Contains($shellMarker)) {
                $client = [System.Net.Sockets.TcpClient]::new()
                try {
                    $client.Connect('127.0.0.1', $monitorPort)
                    $stream = $client.GetStream()
                    $writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::ASCII)
                    $writer.NewLine = "`n"
                    $writer.AutoFlush = $true
                    Start-Sleep -Milliseconds 50
                    foreach ($key in @('h', 'e', 'l', 'x', 'backspace', 'p', 'ret', 'c', 'p', 'u', 'ret', 'm', 'e', 'm', 'ret', 's', 'c', 'r', 'o', 'l', 'l', 'ret', 'c', 'l', 'e', 'a', 'r', 'ret', 'h', 'e', 'l', 'p', 'ret', 'n', 'o', 'p', 'e', 'ret', 'ret', 'h', 'e', 'l', 'p', 'ret', 'up', 'ret')) {
                        $writer.WriteLine("sendkey $key 120")
                        Start-Sleep -Milliseconds 180
                    }
                    $shellInjected = $true
                    $writer.Dispose()
                }
                finally {
                    $client.Dispose()
                }
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
if (-not [regex]::IsMatch($output, 'PS/2 keyboard IRQ verified: ISA IRQ 1 -> GSI 1 -> vector 0x45, make 0x1E, break 0x9E, count 2, command byte 0x[0-9A-F]{2}, remasked and restored after EOI')) {
    throw 'The i8042/IOAPIC PS/2 keyboard IRQ and scan-code capture were not observed.'
}
if (-not $output.Contains("PS/2 event queue verified: #1 usage 0x04 pressed -> 'a'; #2 usage 0x04 released -> 'a'; dropped 0")) {
    throw 'The PS/2 make/break translation through the common keyboard queue was not observed.'
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
if (-not [regex]::IsMatch($output, 'Framebuffer terminal initialized: 1280x800, cells 102x37, cursor row 3, column 7, writes 31, cursor visible, draws 6, erases 5, display checksum 0x7CF72F9AF061C761')) {
    throw 'The persistent graphical terminal was not initialized before PCI/xHCI discovery.'
}if (-not $output.Contains('PCIe ECAM active:')) {
    throw 'The PCIe MCFG/ECAM activation marker was not observed.'
}
if (-not $output.Contains('PCI inventory:')) {
    throw 'The PCI function inventory marker was not observed.'
}
if (-not $output.Contains('PCI function ')) {
    throw 'No enumerated PCI function was printed.'
}
if (-not [regex]::IsMatch($output, 'xHCI controller discovered at [0-9A-F]{4}:[0-9A-F]{2}:[0-9A-F]{2}\.[0-7], vendor 0x[0-9A-F]{4}, device 0x[0-9A-F]{4}, MMIO 0x[0-9A-F]{16}, sparse identity map 0x[0-9A-F]{16} \+ 2097152 bytes using [12] new table page\(s\)')) {
    throw 'The PCI xHCI controller and BAR discovery marker was not observed.'
}
if (-not [regex]::IsMatch($output, 'xHCI capabilities: version [0-9]+\.[0-9A-F]{2}, [1-9][0-9]* slots, [1-9][0-9]* interrupters, [1-9][0-9]* ports, (32|64)-bit addressing, (32|64)-byte contexts, doorbells \+0x[0-9A-F]{16}, runtime \+0x[0-9A-F]{16}')) {
    throw 'The xHCI capability-register report was not observed.'
}
if ($NoUsbKeyboard) {
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
} else {
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
    if (-not [regex]::IsMatch($output, 'HID keyboard press report received: completion (1|13), residual 0, length 8, modifier 0x00, keys 0x04 0x00 0x00 0x00 0x00 0x00')) {
        throw 'The expected eight-byte A-key HID boot report was not observed.'
    }
    if (-not [regex]::IsMatch($output, 'HID release transfer armed: slot [1-9][0-9]*, endpoint 3, length 8, TRB 0x[0-9A-F]{16}, buffer 0x[0-9A-F]{16}; waiting for key release')) {
        throw 'The reusable second HID interrupt-IN transfer was not armed.'
    }
    if (-not [regex]::IsMatch($output, 'HID keyboard release report received: completion (1|13), residual 0, length 8, modifier 0x00, keys 0x00 0x00 0x00 0x00 0x00 0x00')) {
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
if (-not [regex]::IsMatch($output, 'NVMe controller active at [0-9A-F]{4}:[0-9A-F]{2}:[0-9A-F]{2}\.[0-7], vendor 0x[0-9A-F]{4}, device 0x[0-9A-F]{4}, BAR 0x[0-9A-F]{16}')) {
    throw 'The NVMe PCI function and BAR marker was not observed.'
}
if (-not [regex]::IsMatch($output, 'NVMe capabilities: version [0-9]+\.[0-9]+\.[0-9]+, CAP 0x[0-9A-F]{16}, max queue entries [2-9][0-9]*, doorbell stride [1-9][0-9]*, timeout units [0-9]+')) {
    throw 'The NVMe controller capability-register marker was not observed.'
}
if (-not [regex]::IsMatch($output, 'NVMe MMIO mapping: 0x000000C000000000 \+ 2097152 bytes using 0 new table page\(s\)')) {
    throw 'The NVMe sparse MMIO mapping marker was not observed.'
}
if (-not [regex]::IsMatch($output, 'NVMe identity: model "[^"]+", serial "ZIGOSNVME", firmware "[^"]+", namespaces [1-9][0-9]*')) {
    throw 'The NVMe Identify Controller result was not observed.'
}
if (-not [regex]::IsMatch($output, 'NVMe namespace [1-9][0-9]*: [1-9][0-9]* LBA\(s\), capacity [1-9][0-9]* LBA\(s\) x 512 bytes = [1-9][0-9]* bytes, metadata 0')) {
    throw 'The NVMe Identify Namespace geometry was not observed.'
}
if (-not [regex]::IsMatch($output, 'NVMe queues active: admin SQ 0x[0-9A-F]{16}, admin CQ 0x[0-9A-F]{16}, I/O SQ 0x[0-9A-F]{16}, I/O CQ 0x[0-9A-F]{16}, depth 16')) {
    throw 'The ZigOs-owned NVMe admin and I/O queues were not observed.'
}
if (-not [regex]::IsMatch($output, 'NVMe READ completed: namespace [1-9][0-9]*, LBA 0, 512 bytes at 0x[0-9A-F]{16}')) {
    throw 'The read-only NVMe LBA 0 command was not observed.'
}
if (-not $output.Contains('NVMe LBA 0 first 16 bytes: 5A 49 47 4F 53 2D 4E 56 4D 45 2D 4C 42 41 30 21')) {
    throw 'The deterministic NVMe LBA 0 payload was not read correctly.'
}
if (-not [regex]::IsMatch($output, 'NVMe LBA 0 FNV-1a64: 0xA3BA5289D74BDD3C, trailing signature 0xAA55')) {
    throw 'The NVMe LBA 0 fingerprint and trailing signature were not observed.'
}
if (-not $output.Contains('NVMe protective MBR verified: type 0xEE, first LBA 1, sectors 32767')) {
    throw 'The NVMe protective MBR verification marker was not observed.'
}
if (-not [regex]::IsMatch($output, 'NVMe GPT header verified: revision 1\.0, current LBA 1, backup LBA 32767, usable 34-32734, header CRC 0x[0-9A-F]{16}')) {
    throw 'The checksum-valid primary GPT header marker was not observed.'
}
if (-not [regex]::IsMatch($output, 'NVMe GPT partition array verified: 128 entries x 128 bytes at LBA 2, sectors 32, populated 1, CRC 0x[0-9A-F]{16}')) {
    throw 'The checksum-valid GPT partition-entry-array marker was not observed.'
}
if (-not [regex]::IsMatch($output, 'NVMe backup GPT verified: current LBA 32767, primary LBA 1, entries LBA 32735, header CRC 0x[0-9A-F]{16}, array CRC 0x[0-9A-F]{16}')) {
    throw 'The cross-validated backup GPT header and partition array were not observed.'
}
if (-not $output.Contains('NVMe EFI System Partition: index 0, LBA 2048 + 30687 sectors, name "ZigOs NVMe FAT"')) {
    throw 'The NVMe EFI System Partition discovery marker was not observed.'
}
if (-not $output.Contains('NVMe FAT volume verified: FAT16, label "ZIGOSNVME", filesystem "FAT16", 30687 sectors, first FAT LBA 2049, root LBA 2289')) {
    throw 'The FAT16 volume inside the NVMe GPT partition was not observed.'
}
if (-not [regex]::IsMatch($output, 'NVMe FAT path resolved: EFI cluster 2 -> BOOT cluster 3 -> BOOTX64.EFI cluster 4')) {
    throw 'The NVMe FAT EFI/BOOT directory traversal was not observed.'
}
if (-not [regex]::IsMatch($output, 'NVMe FAT boot file found: EFI/BOOT/BOOTX64.EFI, size [1-9][0-9]* bytes')) {
    throw 'The NVMe FAT BOOTX64.EFI directory entry was not observed.'
}
$nvmeFileMatch = [regex]::Match($output, 'NVMe FAT file streamed: ([1-9][0-9]*) bytes across ([1-9][0-9]*) cluster\(s\), last cluster ([1-9][0-9]*), FNV-1a64 0x([0-9A-F]{16})')
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

if ($NvmeOnly) {
    if (-not $output.Contains('AHCI controller active at')) {
        throw 'The q35 AHCI controller was not enumerated in NVMe-only mode.'
    }
    if (-not $output.Contains('AHCI controller has no active SATA devices; continuing with NVMe storage')) {
        throw 'The empty AHCI controller was not skipped in NVMe-only mode.'
    }
    if ($output.Contains('ATA IDENTIFY completed on port')) {
        throw 'ATA IDENTIFY unexpectedly ran without a SATA disk in NVMe-only mode.'
    }
    if (-not $output.Contains('Storage backends ready: NVMe yes, AHCI no')) {
        throw 'The NVMe-only storage readiness marker was not observed.'
    }
} else {
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
if (-not $serialOutput.Contains('BdsDxe: starting Boot0001 "UEFI QEMU NVMe Ctrl ZIGOSNVME 1"')) {
    throw 'OVMF did not boot ZigOs from the GPT/FAT NVMe namespace.'
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
if ($NoUsbKeyboard) {
    if (-not [regex]::IsMatch($output, 'Framebuffer console active: 1280x800, stride 1280, lines 4, glyphs 31, resets 0, lit pixels 1744, checksum 0x866AA691AB18DEB5, cursor visible, draws 6, erases 5, display lit pixels 1764, display checksum 0x7CF72F9AF061C761')) {
        throw 'The unchanged startup-prompt framebuffer state was not observed without a USB keyboard.'
    }
    if (-not $output.Contains('Framebuffer transcript: startup prompt; USB keyboard unavailable')) {
        throw 'The keyboard-less framebuffer transcript marker was not observed.'
    }
} else {
    if (-not [regex]::IsMatch($output, 'Framebuffer console active: 1280x800, stride 1280, lines 9, glyphs 178, resets 1, lit pixels 9492, checksum 0x4721B2F0411D5331, cursor visible, draws 31, erases 30, display lit pixels 9512, display checksum 0x030FBD6154A5D1BD')) {
        throw 'The deterministic GOP bitmap-console report was not observed.'
    }
    if (-not $output.Contains('Framebuffer transcript: clear, error recovery, and Up-arrow history recall')) {
        throw 'The rendered graphical-console transcript marker was not observed.'
    }
}
if (-not $output.Contains('Framebuffer retained and written directly at 0x')) {
    throw 'The framebuffer was not retained and accessed after the handoff.'
}

Write-Host 'QEMU boot test passed.'
