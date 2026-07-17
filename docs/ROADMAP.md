# ZigOs roadmap

## 0.1 - UEFI proof of execution

- [x] Native AMD64 `BOOTX64.EFI`
- [x] Canonical Zig toolchain pin and checksum
- [x] Separate NASM hardware module
- [x] CPUID vendor query
- [x] CR0, CR3 and CR4 reads
- [x] PE/COFF verifier
- [x] QEMU/EDK2 boot test

## 0.2 - Firmware handoff

- [x] Obtain and retain the final UEFI memory map
- [x] Locate ACPI RSDP
- [x] Locate and retain the graphics framebuffer
- [x] Allocate a 64 KiB ZigOs-owned kernel stack
- [x] Switch stacks through an x86-64 assembly trampoline
- [x] Call `ExitBootServices` with stale-key retry handling
- [x] Continue without UEFI console or boot services
- [x] Write directly to the framebuffer after handoff
- [x] Verify the complete transition in QEMU

## 0.3 - Kernel foundations

- [x] Parse retained memory descriptors into usable and reserved regions
- [x] Physical frame allocator
- [x] ZigOs-owned x86-64 page tables
- [x] Identity map required bootstrap firmware, ACPI, stack, and framebuffer regions
- [x] Higher-half data alias and RIP-relative code-execution proof experiment
- [x] Sparse high-physical-address MMIO mappings with shared PML4-slot reuse
- [x] GDT and TSS
- [x] IDT and assembly interrupt stub proof (vector 3 on IST1)
- [x] Full CPU exception-vector coverage and fault diagnostics
- [x] Fatal exception panic path over early debug output
- [x] COM1 serial diagnostics with loopback self-test and mirrored panic output
- [x] Symbolized stack traces

## 0.4 - Hardware discovery

- [x] Validate and parse ACPI RSDP/XSDT
- [x] MADT and APIC discovery
- [x] Local APIC initialization and legacy PIC masking
- [x] I/O APIC discovery and fully masked redirection table
- [x] External IRQ routing through MADT overrides
- [x] PCIe ECAM enumeration from validated MCFG
- [x] AHCI controller and port inspection through BAR5 MMIO
- [x] AHCI command-engine ownership and ATA IDENTIFY DEVICE DMA
- [x] Read-only ATA sector DMA with LBA fingerprinting
- [x] MBR partition-table and FAT12/16/32 BPB discovery
- [x] FAT directory and cluster-chain traversal to EFI/BOOT/BOOTX64.EFI
- [x] Stream complete FAT files and validate on-disk AMD64 PE32+ EFI headers
- [x] HPET initialization and local-APIC timer calibration
- [x] Maskable APIC timer interrupt with EOI and HLT wake-up
- [x] PS/2 keyboard IRQ and scan-code injection experiment
- [x] xHCI capability and connected USB keyboard port discovery
- [x] xHCI controller ownership, command/event rings and Enable Slot completion
- [x] xHCI port reset, slot/EP0 context construction and Address Device completion
- [x] USB EP0 GET_DESCRIPTOR transfer and device-descriptor parsing
- [x] Configuration, interface, HID and interrupt-endpoint descriptor parsing
- [x] SET_CONFIGURATION and xHCI interrupt-IN endpoint configuration
- [x] HID boot protocol/idle setup and injected keyboard input transfer

## 0.5 - Runtime

- [x] Kernel free-list heap with aligned allocation and coalescing
- [x] Cooperative task abstraction with independent stacks and ABI-complete context switching
- [x] APIC-timer pre-emptive scheduler with complete GPR/FX frame switching
- [x] Userspace privilege-transition experiment
- [x] Minimal DPL3 int 0x80 syscall ABI with return and process exit

## Long-term experiments

- Multicore startup through INIT/SIPI
- NVMe and AHCI storage
- FAT filesystem
- Network stack
- Native Zig applications
- Reproducible disk-image and release pipeline

## 0.6 - Symmetric multiprocessing

- [x] UEFI-reserved AP startup trampoline below 1 MiB
- [x] MADT processor-ID retention and four-CPU QEMU topology
- [x] INIT/SIPI application-processor startup
- [x] Per-CPU GDT, TSS, IST and IDT installation
- [x] Lock-free BSP-to-AP work mailbox and parallel completion proof
- [x] Per-CPU scheduler/run-queue state
- [x] FIFO sequence and completion verification across all APs
- [x] Deterministic multicore work stealing with atomic queue claims
- [x] Targeted work IPI wakeups from per-CPU HLT idle loops
- [x] Per-AP local-APIC one-shot timers with autonomous HLT wakeups
- [x] Tick-gated per-AP run-queue dispatch with one job per quantum
- [x] Independent cooperative task stacks and ABI-complete context switching on every AP
- [x] Fair ticket spinlock and reusable four-core barrier synchronization

## 0.7 - Input subsystem

- [x] Reusable xHCI interrupt-IN report rearming
- [x] HID key press and release transition detection
- [x] Device-independent ordered keyboard event queue
- [x] PS/2 Set-1 make/break translation through the common queue
- [x] HID usage-to-ASCII translation proof

## 0.8 - Native shell

- [x] Line-buffered command parser driven by keyboard events
- [x] Repeated xHCI report rearming during interactive input
- [x] Native `help`, `cpu` and `mem` command dispatch
- [x] QEMU-injected end-to-end `help` command proof

## 0.9 - Graphical console

- [x] Direct GOP framebuffer clearing with retained post-UEFI ownership
- [x] Built-in scaled 5x7 bitmap font renderer
- [x] On-screen ZigOs banner and native-shell transcript
- [x] Deterministic framebuffer pixel-checksum regression gate
- [x] Persistent terminal state with live USB keystroke and shell-response rendering
- [x] Cursor, write, newline, backspace and scroll accounting
- [x] USB HID Backspace editing with framebuffer cell erasure
- [x] Persistent multi-command `help`, `cpu` and `mem` shell session
- [x] Prompt continuation and distinct command-response rendering
- [x] Native `scroll` shell command with six real framebuffer scroll operations
- [x] Overlapping pixel-row copy and bottom-line clearing verification
- [x] Native `clear` command with full pixel, cursor, and terminal-accounting reset
- [x] Continued USB input and `help` dispatch after framebuffer reset
- [x] Unknown-command error rendering with continued prompt operation
- [x] Empty-command handling and valid-command recovery in the same USB session
- [x] Live underline cursor overlay with automatic erase/redraw around terminal mutations
- [x] Separate content and displayed-pixel checksums preserving transcript regressions
- [x] Single-entry command history retained across valid, invalid, and empty commands
- [x] USB HID Up-arrow recall redrawn and executed through the normal shell path


## 1.0 - NVMe storage

- [x] PCI class 01:08:02 discovery and 32/64-bit BAR decoding
- [x] Sparse high-MMIO mapping and PCI memory/bus-master enablement
- [x] Controller reset and ZigOs-owned admin submission/completion queues
- [x] Identify Controller and active-namespace discovery
- [x] Identify Namespace geometry and logical-block-size validation
- [x] ZigOs-owned I/O submission/completion queues
- [x] Read-only NVM Read command for LBA 0 with deterministic QEMU payload verification


## 1.1 - NVMe GPT and FAT discovery

- [x] Protective MBR type 0xEE validation
- [x] Primary GPT signature, revision, bounds, and header-CRC validation
- [x] Full primary and backup partition-entry-array streaming CRC validation
- [x] Primary/backup GPT header cross-validation and disk-GUID consistency
- [x] EFI System Partition GUID and LBA-bound discovery
- [x] FAT12/16/32 BPB parsing from the NVMe EFI System Partition
- [x] Deterministic primary and backup GPT test namespace generation


## 1.2 - NVMe FAT file traversal

- [x] FAT16 root-directory and subdirectory traversal over NVMe NVM Read
- [x] EFI/BOOT/BOOTX64.EFI short-name resolution
- [x] FAT16 cluster-chain validation and complete file streaming
- [x] FNV-1a fingerprinting of the NVMe-resident EFI image
- [x] Independent DOS/PE32+ AMD64 EFI-application validation from NVMe
- [x] QEMU namespace populated with the current ZigOs BOOTX64.EFI
- [x] OVMF fallback boot directly from the GPT/FAT NVMe namespace
- [x] NVMe and AHCI streams cross-checked for identical EFI size and FNV-1a hash


## 1.3 - Storage backend fallback

- [x] Independent NVMe and AHCI readiness reporting
- [x] Boot continuation when an AHCI controller has no attached SATA devices
- [x] Fatal storage gate only when neither NVMe nor AHCI is usable
- [x] NVMe-only QEMU mode with no SATA disk attached
- [x] Full kernel, USB shell, SMP, scheduler, and userspace regression while NVMe-only


## 1.4 - Optional USB input

- [x] Boot continuation when no xHCI controller is present or usable
- [x] Read-only xHCI port discovery before controller ownership
- [x] Boot continuation when xHCI has no connected USB keyboard
- [x] Interactive shell started only when a keyboard is available
- [x] Keyboard-less startup prompt retained on the framebuffer
- [x] Combined NVMe-only and keyboard-less full-system QEMU regression


## 1.5 - Non-keyboard USB devices

- [x] Boot-HID keyboard and mouse protocol classification
- [x] Device descriptor and configuration descriptor reads for a USB mouse
- [x] Connected boot mouse rejected as an interactive keyboard without a fatal error
- [x] No keyboard endpoint configuration or shell startup for mouse-only systems
- [x] Combined NVMe-only and USB-mouse-only full-system QEMU regression


## 1.6 - Serial diagnostic integrity

- [x] Zero-valued decimal counters mirrored through the shared debug/COM1 path
- [x] Headless framebuffer reset counter verified as `0` in COM1 output


## 1.7 - Serial-only boot

- [x] COM1 initialized immediately after paging, descriptor tables, and exception handling
- [x] GOP framebuffer treated as an optional boot capability
- [x] Kernel continuation when GOP is missing or unsupported
- [x] USB interactive ownership suppressed when no framebuffer console exists
- [x] Final boot diagnostics emitted entirely through debugcon and COM1
- [x] NVMe-only, keyboard-connected, no-VGA full-system QEMU regression


## 1.8 - Legacy PCI configuration fallback

- [x] PCI configuration mechanism #1 access through ports `0xCF8` and `0xCFC`
- [x] 32-bit x86 port-I/O assembly primitives
- [x] Unified ECAM and legacy configuration access for AHCI, NVMe, and xHCI drivers
- [x] Automatic fallback when ACPI MCFG is absent or invalid
- [x] Full 256-bus legacy PCI scan with multifunction-device support
- [x] i440FX/PIIX machine boot with ACPI MCFG absent
- [x] NVMe, xHCI, SMP, scheduling, and userspace over legacy PCI configuration


## 1.9 - High-core-count SMP topology

- [x] MADT processor discovery separated from the actively started AP set
- [x] Up to three APs selected for the current validated multicore scheduler
- [x] Additional processors left safely parked instead of causing boot failure
- [x] Selected-versus-parked processor counts reported explicitly
- [x] Eight-CPU QEMU regression with three APs active and four additional APs parked
