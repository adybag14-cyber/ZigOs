# ZigOs

[![Build ZigOs](https://github.com/adybag14-cyber/ZigOs/actions/workflows/build.yml/badge.svg)](https://github.com/adybag14-cyber/ZigOs/actions/workflows/build.yml)

ZigOs is an experimental x86-64 operating system built from **freestanding Zig and hand-written assembly**. It boots as a UEFI application, exits firmware boot services, installs its own low-level execution environment, starts additional processors, drives emulated hardware directly, enters CPL3 userspace, and validates its subsystems in deterministic QEMU boot tests.

The project deliberately uses the canonical Zig builds published by [`adybag14-cyber/zig`](https://github.com/adybag14-cyber/zig/releases). Build scripts do not silently fall back to a system or stock Zig installation.

> ZigOs is a research and learning operating system. It is not ready for production use or general physical-hardware support.

## Current milestone: 3.14

The current checkpoint includes a native Intel 82574L/e1000e path with DMA descriptor recycling, transmit/receive ring wrap, interrupt-to-kernel completion queues, a persistent queue owner, a bounded software RX packet queue, protocol-specific packet dispatch, retained UDP/TFTP transfers, destination-port UDP endpoint demultiplexing, bounded endpoint lifecycle management, generation-tagged UDP socket handles, checksum-validating UDP dispatch, peer-connected socket filtering, structured datagram receive metadata, and connected UDP transmission.

The deterministic networking sequence is:

```text
DHCP Discover -> Offer -> Request -> ACK
        |
        v
ARP gateway resolution
        |
        v
IPv4 / ICMP Echo Request and Reply
        |
        v
UDP / TFTP read of zigos.bin
        |
        +--> 5 DATA blocks: 512 / 512 / 512 / 512 / 256 bytes
        +--> 2,304 bytes validated byte-for-byte
        +--> cumulative FNV-1a64: 6175986CBBAB5125
        +--> TX descriptors: 5, 6, 7, 0, 1
        +--> RX packets:      0, 1, 2, 3, 4, 5, 6, 7, 0
        +--> final TDT: 2
        +--> final RDH/RDT: 1 / 0
```

Every DHCP, ARP, ICMP, TFTP DATA, and TFTP ACK stage requires a fresh queue-specific MSI-X interrupt and the expected descriptor writeback. The ISR scans completed descriptors and publishes their indices through bounded TX/RX completion queues; kernel code consumes those records before recycling or reusing entries. Receive descriptors are returned to hardware only after their packet has been parsed and its required state preserved.

## Architecture

```text
UEFI / OVMF
    |
    v
EFI/BOOT/BOOTX64.EFI
    |
    +-- firmware memory-map, ACPI RSDP and GOP discovery
    +-- final ExitBootServices transition
    +-- NASM stack switch into kernel ownership
    |
    v
Freestanding Zig kernel
    |
    +-- normalized physical-memory map and frame allocator
    +-- kernel-owned page tables and higher-half aliases
    +-- GDT, TSS, IDT, IST exception stacks and stack traces
    +-- Local APIC, IOAPIC, HPET/PIT and interrupt routing
    +-- x86-64 SMP startup through a 16-to-64-bit AP trampoline
    +-- per-CPU state, local timers, IPIs and work stealing
    +-- PCIe ECAM or legacy PCI configuration mechanism #1
    +-- xHCI, NVMe, AHCI and Intel 82574L/e1000e drivers
    +-- framebuffer terminal, PS/2 and USB HID input
    +-- heap, cooperative and preemptive scheduling
    +-- isolated CPL3 payload and int 0x80 syscall round trip
    +-- DHCP, ARP, IPv4, ICMP, UDP and TFTP validation
```

Assembly is used where exact instruction, register, descriptor, interrupt-entry, context-switch, or startup control matters. The maintainable kernel and protocol logic remain in Zig.

## Implemented subsystems

### Boot and memory

- Native `x86_64-uefi-msvc` EFI application at `EFI/BOOT/BOOTX64.EFI`.
- ACPI RSDP, GOP framebuffer, final UEFI memory-map, and kernel-stack discovery.
- Clean `ExitBootServices` transition with no later dependency on UEFI boot services.
- Normalized physical-memory layout with protected firmware/kernel regions.
- Physical frame allocator and kernel heap allocator.
- Kernel-owned page tables, identity mappings, and higher-half data/code aliases.
- Deterministic checks that protected ranges cannot be returned by the allocator.

### CPU, exceptions, interrupts, and SMP

- NASM CPUID, control-register, port-I/O, interrupt, context, and memory-order primitives.
- GDT, TSS, IDT, IST1 exception stack, vectors 0-31, and recoverable invalid-opcode probe.
- Frame-pointer stack tracing with kernel symbol lookup.
- Local APIC/x2APIC, IOAPIC, legacy PIC masking, EOI handling, and routed ISA interrupts.
- HPET timing with PIT channel 2 fallback when HPET is absent.
- SMP startup through a one-page real-mode AP trampoline.
- Per-CPU descriptors, stacks, local timers, targeted IPIs, queues, synchronization, and work stealing.
- Sparse and high APIC-ID topology validation, including APIC ID 256.

### Runtime and userspace

- Kernel heap allocation, alignment, splitting, freeing, and coalescing checks.
- Cooperative task switching with dedicated stacks and canaries.
- Timer-driven preemptive scheduling with GPR and FX-state preservation.
- CPL3 code and stack mappings isolated through dedicated user page tables.
- `int 0x80` syscall frame validation and userspace-to-kernel round trip.

### Display and input

- Direct GOP framebuffer terminal with cursor rendering, scrolling, clearing, and checksums.
- COM1 diagnostics at 115200 8N1.
- PS/2 keyboard initialization and IOAPIC-routed interrupt delivery.
- Native xHCI ownership, command/event rings, MSI-X, device enumeration, and boot-keyboard input.
- Shared keyboard event queue and interactive ZigOs shell with editing and history.

### Storage

- Native NVMe controller ownership, admin/I/O queues, MSI-X completions, and namespace reads.
- NVMe namespaces with 512-byte and 4 KiB logical blocks.
- GPT primary/backup headers, partition-array CRCs, and EFI System Partition discovery.
- Native AHCI ownership, ATA IDENTIFY, READ DMA EXT, and MSI completion.
- MBR partition parsing and FAT16 volume discovery.
- FAT directory traversal and streaming verification of `EFI/BOOT/BOOTX64.EFI` from NVMe and AHCI-backed media.
- Optional NVMe-only and storage-backend fallback test configurations.

### Networking

- Intel 82574L/e1000e discovery and ownership.
- DMA RX/TX rings with eight descriptors, writeback checks, recycling, and wrap.
- Independent 32-entry ISR-to-kernel TX/RX completion queues with atomic pending masks, coalesced-completion ready masks, high-water tracking, and overflow detection.
- A retained `Device` owner exposes reusable frame submission, receive, and release operations with persistent TX/RX cursors and DMA addresses.
- A bounded eight-entry software RX queue copies frames out of DMA before immediately recycling their hardware descriptors; later protocol code dequeues stable packet copies.
- After DHCP/ARP/ICMP/TFTP bootstrap, a second ICMP exchange exercises the generic owner APIs and a third ICMP exchange exercises DMA-to-software queuing.
- The complete flow produces twenty-five TX and twenty-two RX completion records, each dequeued once with zero overflow; two UDP endpoints remain isolated and unmatched traffic is accounted for.
- MSI-X vector `0x49` routed to a valid BSP or application-processor destination.
- DHCP Discover/Offer/Request/ACK with BOOTP identity and option validation.
- Runtime lease fields for local address, subnet mask, server, lease duration, and optional router/DNS data.
- ARP request/reply validation against the leased address and effective gateway.
- IPv4 and ICMP Echo construction, checksum generation, and reply verification.
- Reusable Ethernet II, IPv4, and UDP builder/parser with pseudoheader checksum validation.
- Multi-block TFTP RRQ/DATA/ACK transfer against QEMU's restricted built-in TFTP service.
- Bounded software ingress queue with ARP/ICMP/UDP classification and independent protocol queues.
- Retained five-block TFTP transfer routed through the UDP packet queue with TX/RX wrap.
- Four-slot UDP endpoint table with destination-port routing and unmatched-port accounting.
- Duplicate-safe endpoint registration, bounded FIFO saturation, guarded removal, and slot reuse.
- Deterministic 2,304-byte fixture validation, cumulative hash, TX descriptor reuse, and RX descriptor recycling.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- NASM 2.16 or newer in `PATH`.
- Python 3 for deterministic NVMe test-image generation.
- Internet access for the first canonical Zig bootstrap.
- QEMU x86-64 with split EDK2/OVMF code and variable-store images for emulation.
- Git only for repository operations; it is not required by the build itself.

The pinned compiler version is stored in `.toolchain-version` and is currently:

```text
0.17.0-dev.1420+5d08e4716
```

## Build

```powershell
.\scripts\build.ps1
```

Clean build:

```powershell
.\scripts\build.ps1 -Clean
```

Select an optimization mode:

```powershell
.\scripts\build.ps1 -Optimize Debug
.\scripts\build.ps1 -Optimize ReleaseSafe
.\scripts\build.ps1 -Optimize ReleaseFast
.\scripts\build.ps1 -Optimize ReleaseSmall
```

`ReleaseSmall` is the default.

The build script:

1. Bootstraps the pinned canonical Zig release when it is missing.
2. Refuses to continue when the compiler version differs from `.toolchain-version`.
3. Runs canonical `zig fmt --check` across the entire `src` tree.
4. Assembles the x86-64 hardware layer as Win64 COFF.
5. Assembles the one-page AP startup trampoline as a flat binary.
6. Compiles and links the UEFI image.
7. Verifies AMD64 PE32+, EFI application subsystem 10, and output structure.

Output:

```text
zig-out/
â””â”€â”€ EFI/
    â””â”€â”€ BOOT/
        â””â”€â”€ BOOTX64.EFI
```

Latest verified kernel image before this README-only update:

```text
Size:    229,888 bytes
SHA-256: 5378CF27F1F8FEECCF9822C23E7C9856EE9560395DB56B56D1D65574A6838F9D
```

## QEMU validation

Run the default full-system test without a network controller:

```powershell
.\scripts\test-qemu.ps1
```

Run the complete networking path:

```powershell
.\scripts\test-qemu.ps1 -Network -TimeoutSeconds 75
```

Useful compatibility matrices:

```powershell
# BSP-only interrupt destination
.\scripts\test-qemu.ps1 -Network -CpuCount 1 -TimeoutSeconds 75

# i440FX and legacy PCI configuration mechanism #1
.\scripts\test-qemu.ps1 -Network -LegacyPci -NvmeOnly -TimeoutSeconds 75

# Topology containing x2APIC ID 256
.\scripts\test-qemu.ps1 -Network -HighApicId -TimeoutSeconds 75

# HPET and PS/2 absent; PIT timing fallback
.\scripts\test-qemu.ps1 -Network -NoHpet -NoPs2 -TimeoutSeconds 75

# 4 KiB NVMe logical blocks
.\scripts\test-qemu.ps1 -Nvme4k

# Serial-only / no graphical adapter
.\scripts\test-qemu.ps1 -NoGraphics

# No USB keyboard attached
.\scripts\test-qemu.ps1 -NoUsbKeyboard
```

Other supported switches include `-NvmeOnly`, `-UsbMouseOnly`, `-LegacyAhci`, `-SparseApicIds`, and `-NoX2Apic`. Some combinations are intentionally rejected when they describe an unsupported QEMU topology.

The harness builds deterministic NVMe and TFTP fixtures, starts QEMU, injects keyboard input through the QEMU monitor, captures port `0xE9` and COM1 output, and rejects the run when expected hardware, interrupt, scheduler, userspace, storage, or network invariants are absent.

The GitHub Actions workflow currently performs the canonical Windows build, Zig formatting check, and EFI artifact upload. The full QEMU hardware matrix is run locally.

## Run interactively

```powershell
.\scripts\run-qemu.ps1
```

This launches a simpler interactive q35/OVMF session using the FAT-backed `zig-out` directory. The automated test harness exercises the broader device and topology matrix.

## Boot on a physical machine

Copy the contents of `zig-out` to an empty FAT32 EFI System Partition so this path exists:

```text
EFI\BOOT\BOOTX64.EFI
```

Secure Boot must be disabled unless the image has been signed with a key trusted by the firmware.

Physical-machine execution is experimental. Most current device validation targets QEMU's emulated hardware, particularly q35, e1000e, QEMU xHCI, QEMU NVMe, and AHCI. Use disposable hardware or a virtual machine and preserve important data elsewhere.

## Repository layout

```text
.github/workflows/build.yml       canonical Windows CI build
.toolchain-version                pinned canonical Zig version
docs/ROADMAP.md                   completed and planned milestones
scripts/bootstrap-toolchain.ps1   canonical Zig downloader/verifier
scripts/build.ps1                 reproducible UEFI build
scripts/create-nvme-test-image.py deterministic GPT/FAT NVMe image builder
scripts/run-qemu.ps1              interactive QEMU launcher
scripts/test-qemu.ps1             headless hardware/system validation matrix
scripts/verify-efi.ps1            PE/COFF UEFI image verifier
src/main.zig                      UEFI entry and firmware handoff
src/kernel.zig                    post-UEFI kernel integration and validation
src/arch/x86_64/cpu.asm           x86-64 primitives and interrupt/context stubs
src/arch/x86_64/ap_trampoline.asm 16-to-64-bit AP startup trampoline
src/memory.zig                    physical frame allocation
src/paging.zig                    kernel and user page tables
src/descriptor_tables.zig         GDT, TSS, IDT, and IST setup
src/exceptions.zig                exception handling and recovery probes
src/apic.zig / ioapic.zig         local and I/O APIC control
src/smp.zig / percpu.zig          AP startup and per-CPU execution
src/scheduler.zig                 cooperative scheduling
src/preemptive.zig                timer-driven preemptive scheduling
src/user_mode.zig                 CPL3 and syscall validation
src/framebuffer_console.zig       graphical terminal
src/input.zig / ps2.zig           input queue and PS/2 keyboard
src/xhci.zig                      USB xHCI and HID boot keyboard
src/pci.zig                       ECAM and legacy PCI enumeration
src/nvme.zig / ahci.zig           storage-controller drivers
src/gpt.zig / partition.zig       disk partition parsing
src/fat.zig / pe.zig              FAT traversal and PE verification
src/e1000e.zig                    Intel 82574L DMA/MSI-X driver
src/dhcp.zig                      DHCP client framing and validation
src/udp.zig                       reusable Ethernet/IPv4/UDP framing
src/tftp.zig                      deterministic multi-block TFTP client
```

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the milestone-by-milestone implementation record.

## Current limitations

- x86-64 UEFI only; there is no legacy BIOS boot path.
- Hardware support is deliberately narrow and primarily validated in QEMU.
- Networking is currently a deterministic boot-time validation flow, not an asynchronous socket API.
- There is no TCP, DNS resolver, IPv6, firewall, or general network service framework.
- The CPL3 component is a controlled validation payload, not a complete process/ELF runtime.
- FAT support is read-oriented; there is no general writable filesystem layer.
- There is no package manager, graphical desktop, security hardening, or stable userspace ABI.
- The kernel remains experimental and may halt deliberately when an invariant fails.

## Design principles

- Use assembly only where exact machine control is required.
- Keep the kernel and protocol majority in readable Zig.
- Never depend silently on hosted operating-system services after firmware handoff.
- Pin and verify the canonical Zig compiler.
- Prefer deterministic, assertion-heavy integration tests over optimistic boot messages.
- Test in QEMU before attempting physical hardware.
- Treat every interrupt, DMA completion, descriptor transition, and checksum as something to verify.

## License

ZigOs is released under the [MIT License](LICENSE).
