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


## 2.0 - Low-core-count topology

- [x] Uniprocessor boot without INIT/SIPI or AP validation stages
- [x] One- and two-AP mailbox, FIFO, IPI, timer, scheduler, and local-task validation
- [x] Work stealing enabled only with three selected APs
- [x] Ticket-lock/barrier participant count sized to BSP plus active APs
- [x] One-, two-, three-, and four-CPU QEMU topology regressions


## 2.1 - 4 KiB NVMe logical blocks

- [x] NVMe NVM Read with one page-aligned 4 KiB PRP buffer
- [x] Protective-MBR signature read from bytes 510-511 independent of logical-block size
- [x] Block-size-aware deterministic GPT/FAT16 namespace builder
- [x] Primary and backup GPT validation on a 4 KiB namespace
- [x] FAT16 directory and complete EFI file streaming with 4 KiB clusters
- [x] OVMF direct boot from the 4 KiB NVMe GPT/FAT namespace


## 2.2 - Optional PS/2 controller

- [x] i8042 discovery treated as an optional legacy-input capability
- [x] No IOAPIC IRQ1 route installed when i8042 is absent
- [x] Boot continuation with USB-only or headless input hardware
- [x] Explicit PS/2 input readiness reporting
- [x] q35 `i8042=off` full-system QEMU regression


## 2.3 - HPET-independent timing

- [x] Shared reference-clock abstraction for APIC calibration and INIT/SIPI delays
- [x] HPET selected when ACPI and MMIO validation succeed
- [x] PIT channel 2 polled one-shot fallback without an IRQ route
- [x] APIC timer calibration and interrupt wake-up using PIT timing
- [x] SMP INIT/SIPI startup and validation rounds using PIT delays
- [x] q35 `hpet=off` full-system QEMU regression

## 2.4 - x2APIC and sparse processor identifiers

- ZigOs detects CPUID x2APIC support and enters x2APIC mode on the BSP when available.
- Every application processor enables and verifies its own IA32_APIC_BASE x2APIC state before reading x2APIC MSRs or its 32-bit APIC ID.
- `scripts/test-qemu.ps1 -NoX2Apic` removes CPUID x2APIC support and verifies the complete xAPIC MMIO fallback, including AP startup, fixed IPIs, local timers, and work stealing.
- INIT/SIPI and fixed IPIs retain full 32-bit destination IDs in x2APIC mode.
- Work-stealing participant masks use stable per-CPU state slots rather than hardware APIC IDs, so sparse or greater-than-63 identifiers cannot overflow a 64-bit mask.
- `scripts/test-qemu.ps1 -SparseApicIds` uses a six-slot topology with four online processors. QEMU retains MADT IDs `0,1,2,4`; ZigOs starts IDs `1,2,4` and completes the full multicore validation suite without assuming contiguous hardware identifiers.
- `scripts/test-qemu.ps1 -HighApicId` explicitly installs APIC IDs `1`, `2`, and `256`, requiring a mixed MADT with an x2APIC record for ID 256 and proving full-width INIT/SIPI, fixed-IPI, local-timer, and work-stealing paths.

## 2.5 - Routable legacy interrupt destination

- Ordinary IOAPIC physical-destination entries are limited to an 8-bit APIC ID even when the CPUs use x2APIC.
- ZigOs now completes SMP startup before programming legacy IRQ routes, selects an online application processor with APIC ID below 256, and falls back to the BSP only on uniprocessor systems.
- IOAPIC initialization leaves all redirection entries masked with a neutral destination until a routable processor is online.
- IRQ0 and IRQ1 handlers may execute on the selected AP while the BSP verifies their atomic completion counters using the active HPET/PIT reference clock.
- The normal multicore regression deliberately routes PIT and PS/2 interrupts to APIC 1, proving the same fallback required by a real system whose BSP APIC ID exceeds the IOAPIC destination width.

## 2.6 - PCI capability lists and NVMe MSI-X

- Conventional PCI capability lists are validated for status-bit presence, header layout, 4-byte alignment, range, cycles, and linked-list termination on both ECAM and legacy configuration backends.
- ZigOs decodes MSI, MSI-X, PCIe capability offsets and arbitrary 32/64-bit memory BARs selected by an MSI-X BIR field.
- The QEMU NVMe controller exposes 65 MSI-X entries in BAR0 at offset `0x2000`; ZigOs programs dedicated I/O entry 1 at `0x2010`, masks legacy INTx, and targets CPU vector `0x46` at the selected routable processor.
- MSI-X is enabled before I/O completion queue 1 is created, ensuring the vector is registered by device models and hardware before the queue selects table index 1. Every data read then waits for an MSI-X interrupt before consuming its completion entry, while admin commands and devices without MSI-X retain bounded polling.
- The first LBA read must produce exactly one MSI-X interrupt, and the complete GPT/FAT/PE traversal continues over the same interrupt-driven queue.

## 2.7 - AHCI MSI command completion

- The PCI MSI capability parser supports 32/64-bit message addresses, single-message enablement, optional per-vector masking, configuration readback, and legacy INTx disablement over ECAM or configuration mechanism 1.
- QEMU's ICH9 AHCI controller exposes MSI at capability offset `0x80`; ZigOs programs vector `0x47` for the selected routable CPU.
- AHCI global interrupt enable and the active port's D2H/PIO/DMA/descriptor/error interrupt mask are enabled only after stale global and port status are cleared.
- The MSI handler records and clears global/port W1C status, increments an atomic completion counter, and acknowledges the local APIC.
- ATA IDENTIFY, READ DMA EXT, and all later FAT traversal reads wait for MSI before validating `PxCI`, transfer length, and task-file error state. Controllers without MSI retain bounded polling.
- `scripts/test-qemu.ps1 -LegacyAhci` attaches an ICH9 AHCI function to i440FX, enumerates it through `0xCF8/0xCFC`, and proves the same MSI setup and command completions without ACPI MCFG/ECAM.

## 2.8 - xHCI MSI-X event delivery

- The PCI capability walk discovers the qemu-xhci MSI-X capability at `0x90`, validates 16 vectors, and decodes the BAR0 table/PBA offsets at `0x3000`/`0x3800`.
- ZigOs programs table entry 0 for CPU vector `0x48`, enables USBCMD.INTE and runtime interrupter 0, and installs the ISR in both BSP and per-AP IDTs.
- Enable Slot completion requires both a valid event TRB and an MSI-X counter advance, eliminating the event-visible/ISR-pending race.
- Before each later synchronous command or control transfer, ZigOs drains already-ready port-status events, advances ERDP/EHB, then captures a fresh pre-doorbell interrupt baseline; the matching completion is accepted only after MSI-X activity advances that baseline.
- HID interrupt-IN arms capture their interrupt baseline before ringing the endpoint doorbell and block until both an MSI-X counter advance and the matching event TRB are visible; interrupt coalescing is accepted.
- The regression harness uses a retried HMP connection with a settling interval and proves press, release, and the complete native shell session over xHCI MSI-X. Five consecutive cold interactive boots are used as the race-regression gate.
- NVMe controller-ready and queue-completion waits use a five-second HPET deadline when available, with a bounded PIT-only fallback; SQ/CQ doorbell writes are flushed by a CSTS read to prevent posted-write timing from becoming a CPU-iteration race.


## 2.9 - Intel 82574L networking

- QEMU's `e1000e` function is discovered as Intel `8086:10D3`, with BAR0 register MMIO and a five-entry MSI-X table in BAR3.
- ZigOs performs a software reset, restores and validates the station MAC address, and verifies the 1 Gb/s link before enabling DMA.
- Eight-entry legacy RX and TX descriptor rings use page-backed buffers below 4 GiB and queue 0 for the first deterministic exchange.
- MSI-X table entry 0 targets vector `0x49` on the selected routable CPU; IVAR maps both RXQ0 and TXQ0 to that vector and the ISR records queue-specific causes.
- A padded Ethernet ARP request advertises `10.0.2.15` and resolves QEMU user networking's `10.0.2.2` gateway.
- The reply must match the local MAC, ARP opcode 2, sender IPv4 `10.0.2.2`, and target IPv4 `10.0.2.15` after both DMA descriptor writeback and MSI-X delivery.


## 3.0 - IPv4 and ICMP echo

- The live e1000e descriptor rings carry a second unicast transaction after ARP resolution without resetting the controller.
- ZigOs constructs Ethernet II, a 20-byte IPv4 header, and an ICMP Echo Request with deterministic identifier `0x5A49`, sequence `1`, and a 16-byte payload.
- IPv4 and ICMP Internet checksums are generated in the kernel and independently revalidated across the complete received headers and payload.
- TX descriptor 1 and RX descriptor 1 require fresh queue-specific MSI-X counter advances before their writebacks are accepted.
- The QEMU gateway Echo Reply must preserve the identifier, sequence, payload, source/destination IPv4 addresses, and a nonzero TTL.


## 3.1 - DHCP lease acquisition

- ZigOs sends a broadcast DHCP Discover and receives an Offer on RX descriptor 0, then sends a DHCP Request and receives the ACK on descriptor 1.
- BOOTP transaction ID, client hardware address, DHCP magic cookie, message type, server identifier, and acknowledged address are validated before accepting the lease.
- Ethernet, IPv4, UDP, and DHCP lengths are bounded against the DMA writeback length; IPv4 and nonzero UDP checksums are independently verified.
- The ACK supplies the local IPv4 address, subnet mask, server identifier, lease duration, and server MAC address. Router and DNS options remain explicitly tracked as advertised or absent; QEMU user networking omits both, so the validated server identifier becomes the gateway fallback while DNS remains unset.
- ARP and ICMP move to descriptors 2 and 3 and consume the acknowledged address and router instead of compile-time network constants.
- Every Discover, Offer, Request, ACK, ARP, and ICMP stage requires fresh queue-specific MSI-X activity and the matching descriptor writeback.


## 3.2 - Reusable UDP and TFTP

- A protocol-independent Ethernet II, IPv4, and UDP builder emits padded frames with IPv4 and UDP pseudoheader checksums.
- The matching parser validates MAC/IP endpoints, IPv4 header length and checksum, non-fragmentation, UDP ports and length, and any nonzero UDP checksum before exposing the payload.
- The QEMU user-network TFTP root contains a deterministic 36-byte `zigos.txt` fixture and remains available with `restrict=on`.
- TX descriptor 4 sends an octet-mode RRQ from UDP port 40000 to the validated router/TFTP server on port 69; RX descriptor 4 accepts DATA block 1 from the server's selected transfer port.
- The TFTP payload must match the exact fixture and FNV-1a64 `6FA5A2AB46F699B6`, and a sub-512-byte DATA block is treated as final.
- TX descriptor 5 sends ACK block 1 back to the actual transfer port, with fresh TXQ0/RXQ0 MSI-X progress required for RRQ, DATA, and ACK.


## 3.3 - Multi-block TFTP streaming

- The deterministic TFTP fixture expands to 1,280 binary bytes generated by `(index * 37 + 11) mod 256`, with SHA-256 `9E56C920BB08B3E00A4E0034224F877C21945DCB09ECCD6CEAF2D843E8CFDE39`.
- DATA blocks 1 and 2 carry 512 bytes each; block 3 carries the final 256 bytes. Every block number, length, byte pattern, UDP/IP checksum, source port, TTL, and DMA descriptor is validated in order.
- The kernel maintains a cumulative FNV-1a64 stream hash and requires `3CE18B3991BE5925` across all 1,280 bytes before accepting the transfer.
- RX descriptors 4-6 receive the three DATA frames, while TX descriptors 5-7 emit ACK blocks 1-3.
- The final ACK advances the eight-entry TX tail from descriptor 7 back to index 0, proving hardware ring wrap and writeback across the boundary.
- Fresh RXQ0/TXQ0 MSI-X progress is required for every DATA and ACK rather than only the first block.


## 3.4 - RX descriptor recycling and wrap

- The deterministic TFTP stream expands to 2,304 bytes across five DATA blocks (`512/512/512/512/256`) with cumulative FNV-1a64 `6175986CBBAB5125`.
- Every DHCP, ARP, ICMP, and TFTP receive descriptor is cleared and returned to hardware through RDT only after its packet has been fully parsed and copied into stable state.
- The nine received packets consume descriptors `0,1,2,3,4,5,6,7,0`; the final block therefore proves hardware receive-head wrap and reuse of descriptor 0.
- End-of-stream register validation requires RDH `1`, RDT `0`, nine recycled descriptors, and one receive-index wrap.
- TFTP ACKs use TX descriptors `5,6,7,0,1`, proving descriptor reuse after the transmit tail wraps once; final TDT is `2`.
- Every recycled DATA descriptor and every reused ACK descriptor still requires fresh RXQ0/TXQ0 MSI-X progress before acceptance.


## 3.5 - Interrupt completion queues

- The e1000e ISR scans TXQ0/RXQ0 descriptor writebacks and enqueues completed descriptor indices into independent 32-entry single-producer/single-consumer queues.
- Per-descriptor atomic pending masks prevent stale writebacks from being emitted twice when ring entries are recycled and reused.
- Kernel-side waits consume completion records rather than treating a global interrupt counter as proof that a particular descriptor completed.
- Coalesced or out-of-order records are retained in consumer-side ready masks until the matching descriptor is requested.
- The complete DHCP, ARP, ICMP, and five-block TFTP sequence must produce exactly ten TX and nine RX queue records, with matching dequeue totals, no overflow, no pending TX descriptor, and all eight RX descriptors returned to hardware.
- The same queue path is exercised for BSP-local MSI-X delivery, remote APIC delivery, legacy PCI configuration, x2APIC ID 256, and PIT-only timing.


## 3.6 - Persistent e1000e queue ownership

- The initialized e1000e rings, DMA buffers, RX buffer map, interrupt target, lease, gateway, and producer/consumer cursors are retained in a persistent `Device` owner.
- `submitFrame` copies a caller-supplied Ethernet frame into the owned TX DMA buffer, arms the current descriptor, advances TDT, and consumes the matching ISR completion record.
- `receiveFrame` consumes the next RX completion, exposes the bounded DMA frame, and advances the software consumer cursor; `releaseFrame` clears and returns that descriptor to hardware.
- After the scripted DHCP/ARP/ICMP/TFTP bootstrap, a second ICMP Echo (`identifier 0x5A50`, sequence `2`) runs solely through these reusable APIs.
- The follow-up exchange reuses TX descriptor 2 and RX descriptor 1, advances cursors to 3 and 2, and leaves all pending/ready masks clean.
- Final completion totals are eleven TX and ten RX records with matching dequeue counts and zero overflow across BSP-local, remote AP, legacy PCI, APIC-ID-256, and PIT-only modes.


## 3.7 - Software RX packet queue

- The persistent e1000e owner contains an eight-entry software packet queue whose 2,048-byte entries hold stable copies of received Ethernet frames.
- `pumpReceive` consumes the next hardware completion, copies the bounded frame into software-owned memory, and recycles the DMA descriptor immediately.
- `dequeuePacket` exposes the stable packet later, decoupling protocol parsing from hardware descriptor lifetime.
- A third ICMP Echo (`identifier 0x5A51`, sequence `3`) uses TX descriptor 3 and RX descriptor 2; the reply is copied, descriptor 2 is returned to hardware, and only then is the packet parsed.
- The software queue must report one enqueue, one dequeue, high-water one, zero drops, and an empty final queue.
- Final hardware completion totals are twelve TX and eleven RX records with zero overflow and clean pending/ready masks across the full topology matrix.


## 3.8 - Protocol packet dispatch

- Software-owned ingress packets are classified by Ethernet type and bounded IPv4 metadata before protocol parsing.
- ARP, ICMP, and UDP each have independent eight-entry packet queues with enqueue/dequeue, high-water, and drop accounting.
- `dispatchNextPacket` removes one packet from the driver ingress queue and routes it without exposing DMA storage; unknown or malformed packets are counted and rejected.
- A fourth ICMP Echo (`identifier 0x5A52`, sequence `4`) uses TX descriptor 4 and RX descriptor 3, then follows `pumpReceive -> dispatchNextPacket -> dequeueIcmpPacket`.
- The dispatcher must report exactly one ICMP dispatch, zero ARP/UDP/unknown packets, one ICMP enqueue/dequeue, high-water one, and zero drops.
- Final hardware completion totals are thirteen TX and twelve RX records with zero overflow and clean descriptor masks across the topology matrix.


## 3.9 - UDP/TFTP protocol queue transfer

- A fresh TFTP RRQ is submitted through the persistent e1000e owner on UDP client port 40001 after the ICMP dispatch proof.
- All five TFTP DATA frames follow `pumpReceive -> dispatchNextPacket -> dequeueUdpPacket`, so protocol parsing consumes only stable software-owned packets.
- Every DATA payload is validated byte-for-byte, accumulated to 2,304 bytes, and checked against FNV-1a64 `0x6175986CBBAB5125`.
- Five ACK frames are submitted through the retained TX producer; expected DATA descriptors are `4/5/6/7/0` and ACK descriptors are `6/7/0/1/2`.
- Both TX and RX software cursors wrap once, the UDP queue reports five balanced enqueue/dequeue operations with zero drops, and the ingress queue remains empty.
- Final hardware completion totals are nineteen TX and seventeen RX records with zero overflow and clean descriptor masks across the topology matrix.


## 3.10 - UDP endpoint demultiplexing

- The retained network device owns a four-slot UDP endpoint table keyed by destination port, with duplicate-safe registration and bounded per-endpoint queues.
- UDP dispatch validates the IPv4/UDP envelope, extracts the destination port, and routes packets only to a matching active endpoint.
- A valid synthetic datagram for unregistered port 49999 is rejected and counted without polluting any endpoint queue.
- Existing TFTP client port 40001 occupies slot 0; a second endpoint on port 40002 occupies slot 1 and completes another five-block transfer.
- Port 40002 receives DATA descriptors `1/2/3/4/5`, sends ACK descriptors `4/5/6/7/0`, and validates the same 2,304-byte deterministic payload.
- Final hardware completion totals are twenty-five TX and twenty-two RX records with two TX wraps, one RX wrap, one unmatched drop, zero queue drops, and clean descriptor masks.


## 3.11 - UDP endpoint lifecycle and capacity

- Duplicate registration is idempotent, port zero is rejected, all four endpoint slots can be occupied, and a fifth registration is refused.
- An endpoint queue is filled to its seven-packet usable ring capacity with valid UDP datagrams and preserves FIFO payload order while draining.
- The eighth packet is dropped deterministically, raising the queue high-water mark to seven without corrupting ingress or other endpoints.
- Unregistering a non-empty endpoint is rejected; after all packets are dequeued, the endpoint can be removed safely.
- The freed slot is reused by a new port, then temporary endpoints are removed so the original ports 40001 and 40002 remain active.
- Hardware completion totals remain twenty-five TX and twenty-two RX because the lifecycle proof operates entirely on stable software-owned packet copies.

## 3.12 - Generation-tagged UDP sockets

- Raw endpoint slots are wrapped in `UdpSocket` handles containing the slot, local port, and a monotonically allocated nonzero generation.
- The second live TFTP transfer uses `openUdpSocket`, `sendUdpSocket`, and `receiveUdpSocket` for its RRQ, five DATA packets, and five ACKs while preserving the existing descriptor and completion totals.
- Duplicate opens of the same port return the same live handle without consuming another endpoint slot.
- Closing and reusing slot 2 advances its generation from 3 to 5; the stale generation-3 handle is rejected by active lookup, receive, send, and close.
- A rejected stale send must not arm a TX descriptor or change the device submission count.
- The topology matrix continues to require twenty-five TX and twenty-two RX completions, zero completion overflow, and clean pending masks.
- The QEMU harness serializes its shared OVMF, NVMe, serial, and debug artifacts across concurrent invocations, and combined no-graphics/no-keyboard runs follow the zero-device assertion path.

## 3.13 - Validated UDP ingress and peer filtering

- UDP dispatch now parses the full Ethernet/IPv4/UDP envelope before endpoint lookup, including destination MAC/IP, IPv4 checksum, fragmentation, UDP length, and any nonzero UDP checksum.
- Invalid UDP packets have independent accounting and never enter a socket queue; unregistered destination ports remain separately counted.
- A live socket can bind an exact remote MAC, IPv4 address, and UDP port through `connectUdpSocket`, inspect that peer, and return to wildcard receive mode through `disconnectUdpSocket`.
- Peer changes and disconnects are rejected while queued packets remain, and duplicate connection to the same peer is idempotent.
- Deterministic packets prove that the correct peer is accepted while wrong MAC, wrong IPv4 address, wrong source port, and a corrupted UDP checksum are all rejected.
- After disconnect, an alternate source is accepted again, proving that wildcard receive semantics are restored without reopening the socket.

## 3.14 - Structured UDP datagrams and connected transmission

- `receiveUdpDatagram` consumes a socket packet and returns stable packet ownership together with source/destination MAC and IPv4 addresses, ports, TTL, IPv4 identification, checksum presence, and a bounds-checked payload view.
- The receive API revalidates the packet against the live socket and its optional connected peer before exposing metadata.
- `sendConnectedUdpSocket` emits through the peer already attached to the generation-tagged socket, eliminating repeated destination arguments and rejecting unconnected handles.
- The second five-block TFTP transfer receives every DATA frame through the structured API, connects to the validated first responder, and transmits every ACK through the connected-send API.
- The proof requires five structured receives, five connected sends, a retained peer port of 69, unchanged descriptor order, unchanged completion totals, and the same 2,304-byte payload hash.

## 3.15 - Deterministic UDP ephemeral ports

- `openEphemeralUdpSocket` allocates from the IANA dynamic/private range `49152-65535` while retaining the existing generation-tagged endpoint semantics.
- Allocation checks endpoint capacity before advancing state, so a full table is rejected without consuming a port cursor.
- Active-port collisions are skipped rather than treated as duplicate opens, and the next genuinely unused candidate is selected.
- A deterministic proof allocates ports 49152 and 49153, rejects a full-table request, skips occupied 49153 to select 49154 after slot reuse, and preserves advancing generations.
- Starting at 65535 proves range wrap: the next allocation returns 65535, advances to 49152, and the following socket receives 49152.
- All temporary sockets close cleanly, the original two TFTP endpoints remain active, and packet/completion accounting is unchanged.

## 3.16 - UDP socket readiness and queue control

- `inspectUdpSocket` exposes generation-validated local/peer state, pending packet depth, usable capacity, enqueue/dequeue totals, drops, and high-water marks.
- `udpSocketReadable` provides a nonblocking readiness check suitable for a future event loop without touching the queue.
- `discardUdpSocketPackets` drains all queued datagrams through normal dequeue accounting and rejects stale handles.
- A connected ephemeral socket receives three deterministic datagrams, reports pending depth three and high-water three, and refuses peer disconnection while packets remain queued.
- After an explicit three-packet discard, readiness clears, disconnection and close succeed, and stale status/discard operations are rejected.
- The original two TFTP endpoints remain active while ingress and UDP dispatch accounting advance exactly by the three routed test datagrams.

## 3.17 - Bounded packet dispatch batches

- `dispatchNextPacketResult` distinguishes an empty ingress queue from a successfully routed packet and a consumed-but-rejected packet.
- The legacy boolean `dispatchNextPacket` remains available and reports only successful routing, preserving existing callers.
- `dispatchPacketBatch` examines at most a caller-supplied budget, continues after malformed or unmatched packets, and returns examined/routed/dropped totals plus remaining ingress depth.
- A five-packet mixed batch contains three valid socket datagrams, one unmatched destination port, and one corrupted UDP checksum.
- Budgets of two, two, and ten produce deterministic results `2/1/1/3`, `2/1/1/1`, and `1/1/0/0`; a subsequent empty batch reports zero work.
- The three valid datagrams retain FIFO order and payload metadata while independent unmatched and invalid counters each advance by one.

## 3.18 - Endpoint-wide UDP readiness polling

- `pollUdpEndpoints` scans the fixed endpoint table without consuming packets and returns active, readable, and connected bitmasks plus counts, total pending packets, and maximum per-socket depth.
- Two ephemeral sockets occupy slots 2 and 3 while the retained TFTP sockets remain in slots 0 and 1; slot 3 is peer-connected and slot 1 retains its TFTP peer.
- Routing two datagrams to slot 2 and one to slot 3 produces masks `active=0x0F`, `readable=0x0C`, and `connected=0x0A`, with three total pending and maximum depth two.
- Consuming one packet preserves both readable bits with total pending two; draining both sockets clears the readable mask while active and connected state remain unchanged.
- Closing both temporary sockets returns masks to `active=0x03`, `readable=0x00`, and `connected=0x02`, leaving the original endpoints and their peer state intact.
- Ingress and UDP dispatch totals advance exactly by three, with no new drops or hardware completions.

## 3.19 - Generation-safe UDP service cycles

- `collectReadableUdpSockets` converts readable endpoint slots into generation-tagged `UdpSocket` handles ordered by endpoint slot, with total pending depth.
- `serviceUdpSockets` performs one bounded ingress-dispatch batch and then returns the current readable handles in a single nonblocking cycle.
- Two ephemeral sockets receive a mixed four-packet workload containing two valid datagrams, one corrupted checksum, and one unmatched destination.
- A budget-three service cycle reports `3/2/1/1` and two readable handles; a second cycle consumes the unmatched packet as `1/0/1/0` while preserving the same ready set.
- The returned handles receive the two valid datagrams with stable payload metadata; a drained cycle reports no dispatch work and no readable sockets.
- Closing the endpoints invalidates both previously returned handles by generation, while ingress/drop accounting advances deterministically to 42 packets examined.

## 3.20 - Round-robin UDP service fairness

- The device retains a bounded ready-socket cursor independent of endpoint allocation and ephemeral-port state.
- `collectReadableUdpSocketsFair` scans from that cursor, returns at most a caller-supplied number of generation-tagged handles, and advances only when a readable endpoint is selected.
- `serviceUdpSocketsFair` combines bounded ingress dispatch with the fair collector while preserving the existing slot-ordered polling APIs.
- Two sockets each receive two datagrams; successive one-handle service cycles select slots `2,3,2,3` with cursor states `3,0,3,0`.
- Payload delivery order becomes `0,2,1,3`, demonstrating inter-socket fairness while retaining FIFO order within each socket.
- A zero-ready cycle leaves the cursor stable, and closing the temporary sockets preserves the original endpoint table and all prior drop accounting.

## 3.21 - Transactional automatic UDP identification

- The retained device owns a nonzero IPv4 identification cursor for application-level connected UDP sends.
- `sendConnectedUdpDatagram` chooses the current identification, delegates to the connected socket path, and advances the cursor only after a completed hardware transmission.
- Unconnected sockets and zero-TTL requests are rejected without arming a TX descriptor, changing submission totals, or consuming an identification.
- Two normal sends emit IDs `0x7000` and `0x7001`; forcing the cursor to `0xFFFF` proves wrap to `0x0001` while zero remains reserved.
- The four frames use TX descriptors `1/2/3/4`, advance cursors `2/3/4/5`, and each retain the Ethernet minimum length of 60 bytes.
- Completion totals advance from 25 to 29 with zero overflow, clean TX pending state, unchanged RX ownership, and the original two UDP endpoints preserved.

## 3.22 - Exact UDP payload boundaries

- The socket layer publishes a maximum UDP payload of 1,476 bytes, derived from the 1,518-byte Ethernet frame buffer minus Ethernet, IPv4, and UDP headers.
- A 1,477-byte connected payload is rejected before descriptor submission, preserving the automatic-identification cursor, TX producer, completion count, and submission total.
- A 1,476-byte payload emits a full 1,518-byte frame through descriptor 5 with identification `0x0002`.
- A zero-byte UDP payload remains valid and emits the Ethernet minimum frame of 60 bytes through descriptor 6 with identification `0x0003`.
- Both successful sends advance the identification cursor to 4 and TX producer to 7 without wrapping, while completion totals reach 31 with zero overflow.

## 3.23 - Application UDP TX ring wrap

- The connected automatic-send path begins at TX producer 7 after the payload-boundary proof.
- Two minimum-sized UDP frames use descriptors `7` and `0`, advancing software cursors `0` and `1` across the eight-entry ring boundary.
- Automatic IPv4 identifications advance from `0x0004` to `0x0005`, leaving cursor 6 after both completions.
- The device TX wrap counter advances exactly once, from 2 to 3, while completion totals reach 33 with zero overflow.
- TX pending state returns to zero, all RX descriptors remain owned by hardware, and the original two UDP endpoints remain registered.

## 3.24 - Bounded-copy UDP receive

- `receiveUdpInto` parses directly from the endpoint queue, copies at most the caller's buffer length, and returns complete source/destination metadata without returning the 2 KiB packet backing object.
- Queue ownership advances only after successful validation and copy, preserving generation and connected-peer checks.
- An eight-byte payload received into five bytes reports `payload=8`, `copied=5`, and truncation while preserving the first five bytes exactly.
- A four-byte payload received into eight bytes reports no truncation and leaves the unused output tail unchanged.
- A zero-length datagram received into a zero-length buffer remains valid and reports no truncation.
- Three routed packets produce balanced endpoint and ingress dequeue accounting with no hardware completion changes.

## 3.25 - Non-consuming UDP preview and exact receive

- `peekUdpDatagram` validates the next queued datagram and returns full endpoint metadata plus payload length without moving the queue tail or dequeue counters.
- Repeated previews of the same datagram are stable and preserve its source/destination identity, TTL, checksum state, and IPv4 identification.
- `receiveUdpExact` compares the previewed payload length against the caller buffer and rejects insufficient buffers without consuming or modifying the output.
- A six-byte datagram rejects a four-byte exact buffer while remaining queued, then succeeds with a six-byte buffer and exact payload hash.
- A following two-byte datagram previews and receives independently, after which preview and exact receive both report an empty queue.
- Endpoint, ingress, dispatch, and hardware completion accounting remains balanced across both datagrams.

## 3.26 - Explicit discard-on-close semantics

- Normal `closeUdpSocket` continues to reject nonempty queues, preventing accidental packet loss.
- `closeUdpSocketDiscarding` explicitly drains queued packets through normal dequeue accounting, captures connection and queue statistics, and then unregisters the endpoint.
- A connected ephemeral socket receives three packets; normal close is rejected while all three remain readable.
- Discard-close reports three discarded packets, balanced `3/3` endpoint accounting, high-water three, zero drops, and the original connected peer.
- The former handle is rejected by normal close, force close, and receive after endpoint removal, while the original two TFTP endpoints remain active.

## 3.27 - Transactional unconnected send-to and replies

- `sendUdpDatagramTo` applies automatic nonzero IPv4 identification to an explicit validated remote peer without connecting the socket.
- `sendUdpReply` validates that a received datagram targeted the live socket and local interface, then addresses a response to its source MAC, IPv4 address, and UDP port.
- Invalid peer ports and zero-TTL sends are rejected without consuming identification, descriptor, completion, or submission state.
- A synthetic four-byte request from port 34567 is received and answered with a reply using identification `0x0006` and TX descriptor 1.
- A second unconnected send-to uses identification `0x0007` and descriptor 2, leaving the automatic cursor at 8 and TX producer at 3.
- Completion totals reach 35 with zero overflow while the receive path advances by exactly one routed request.

## 3.28 - Bounded DNS A-record wire codec

- A new `dns.zig` module builds recursion-desired A queries and authoritative compressed A responses without allocation.
- Domain validation enforces total and label lengths, rejects empty labels, leading/trailing dots, invalid characters, and leading/trailing hyphens.
- Response parsing validates transaction identity, response/opcode/truncation/error flags, one matching A/IN question, bounded record lengths, and a matching A answer.
- DNS compression pointers are decoded with a strict jump budget, rejecting self-referential loops and out-of-range pointers.
- The deterministic `zigos.test` query is 28 bytes; its compressed response is 44 bytes and resolves to `192.0.2.42` with TTL 300.
- Wrong transaction IDs, truncation, NXDOMAIN, wrong answer type, insufficient buffers, malformed names, and compression loops are rejected; matching is case-insensitive.

## 3.29 - Connected UDP DNS transaction

- `sendDnsAQuery` validates a connected port-53 socket, builds the bounded query, and transmits it through transactional automatic IPv4 identification.
- `receiveDnsAResponse` consumes one connected datagram and applies the DNS transaction/name/A-record validator.
- Invalid query names are rejected without consuming identification, descriptor, completion, or submission state.
- A 28-byte `zigos.test` query uses IPv4 identification `0x0008`, TX descriptor 3, cursor 4, and a 70-byte Ethernet frame.
- Two synthetic server responses are routed through the endpoint queue: the wrong transaction is consumed and rejected, then the matching response resolves `192.0.2.42` with TTL 300.
- Endpoint accounting balances at `2/2`, TX completions reach 36, and ingress/UDP dispatch totals advance exactly by the two responses.

## 3.30 - Resumable bounded DNS polling

- `startDnsAQuery` stores the generation-tagged socket, transaction ID, bounded name copy, and completed query transmission in a resumable request object.
- `pollDnsAQuery` consumes at most a caller-supplied number of queued server datagrams and returns `inactive`, `pending`, or `resolved` with examined/rejected counts.
- A zero budget leaves all three queued responses untouched; a budget of two consumes and rejects a wrong transaction and NXDOMAIN response while leaving one packet.
- The next poll resolves the matching response to `192.0.2.42`, and polling the request after socket close returns `inactive` without touching state.
- The query uses IPv4 identification `0x0009`, descriptor 4, and cursor 5; endpoint accounting balances at `3/3` with high-water three.
- TX completions reach 37 and ingress/UDP dispatch totals reach `60/60` and `49/48` with no new network-layer drops.

## 3.31 - Loop-safe DNS CNAME resolution

- DNS A responses now include an alias-hop count and can follow bounded CNAME chains before locating the final A record.
- Answer scanning restarts from the bounded answer section for each canonical name, so record ordering does not require the A record to follow the CNAME immediately.
- CNAME RDATA uses the same compression-safe decoder and must consume its declared record length exactly.
- A visited-name set and eight-hop ceiling reject self-references, cycles, and unbounded alias chains.
- The deterministic `alias.zigos.test -> zigos.test` response is 84 bytes and resolves `192.0.2.42` with one alias hop and TTL 300.
- A self-alias and truncated response are rejected, while mixed-case alias and canonical names resolve case-insensitively.

## 3.32 - CNAME resolution through the UDP client

- A resumable DNS request now queries `alias.zigos.test` through the same connected port-53 socket and bounded polling API used for direct A records.
- The 34-byte alias query emits a 76-byte Ethernet frame with IPv4 identification `0x000A`, TX descriptor 5, and cursor 6.
- A synthetic 84-byte CNAME-plus-A response is routed through the exact DNS peer and resolved in one poll operation.
- The result reports `192.0.2.42`, TTL 300, and one alias hop while endpoint accounting balances at `1/1`.
- TX completions reach 38; ingress and UDP dispatch totals advance to `61/61` and `50/49` with no additional drops.

## 3.33 - Transactional DNS retransmission

- `DnsARequest` tracks its completed transmission count and latest hardware transmit record.
- `retryDnsAQuery` reuses the original DNS transaction ID and bounded name while allocating a fresh automatic IPv4 identification.
- An initial query emits ID `0x000B` through descriptor 6; an empty poll remains pending without touching state.
- The retry emits ID `0x000C` through descriptor 7, wraps the TX producer to zero, and advances the device TX-wrap counter from 3 to 4.
- A subsequent matching response resolves normally, while retrying the request after socket close is rejected without consuming identification, descriptor, completion, or transmission-count state.
- Two transmissions raise TX completions to 40; ingress/UDP dispatch advance by one response to `62/62` and `51/50`.

## 3.34 - Fixed-capacity TTL-aware DNS cache

- `dns.Cache` stores four allocator-free A-record entries with bounded name copies, absolute caller-supplied expiry ticks, and usage ordering.
- Lookups are case-insensitive, refresh recency, return remaining TTL, and lazily remove expired entries.
- Stores reject invalid names and zero TTL without mutating cache state or statistics.
- Existing names refresh in place; new names use inactive or expired slots before evicting the least-recently-used live entry.
- The deterministic proof fills all four entries, protects a recently used record, evicts the oldest, expires a short-TTL record, reuses its slot, and refreshes `b.test` to `192.0.2.99`.
- Final statistics are nine hits, two misses, seven stores, one refresh, one eviction, and one expiration with all four slots active.

## 3.35 - Cache-aware DNS resolution

- `startDnsAResolve` returns a cached A record immediately when its caller-clocked TTL remains live, otherwise starts a resumable connected UDP request.
- `pollDnsAResolve` delegates bounded DNS polling and stores successful answers under the original requested name and response TTL.
- The first `zigos.test` lookup misses, transmits ID `0x000D` through descriptor 0, resolves one response, and stores the result.
- A mixed-case lookup at tick 1100 returns the cached address with 200 ticks remaining and does not change identification, TX producer, submissions, or completion totals.
- At expiry tick 1300 the cache entry is removed and a new request transmits ID `0x000E` through descriptor 1.
- Closing the socket makes that pending request inactive; final cache statistics are one hit, two misses, one expiration, and zero active entries.

## 3.36 - Transactional automatic DNS transaction IDs

- The retained network device owns a nonzero DNS transaction-ID cursor independent of IPv4 packet identification.
- `startAutomaticDnsAQuery` allocates the current DNS transaction ID, starts the bounded query, and advances the cursor only after a completed transmission.
- Invalid names and stale socket handles are rejected without consuming DNS ID, IPv4 ID, TX descriptor, submission, or completion state.
- Three successful queries use DNS IDs `0x5000`, `0xFFFF`, and `0x0001`, proving zero-skipping wraparound.
- Their IPv4 IDs are 15/16/17 and descriptors are 2/3/4, with frame lengths 70/70/76 for direct and alias names.
- Final DNS, IPv4, and TX cursors are 2, 18, and 5; TX completions reach 45 with no ring wrap or network receive changes.

## 3.37 - Fully automatic cache-aware DNS starts

- `startAutomaticDnsAResolve` checks the TTL cache first and allocates DNS transaction and IPv4 packet IDs only for a real cache miss.
- A preloaded mixed-case cache hit returns `192.0.2.42` with 900 ticks remaining without changing either cursor, TX producer, submissions, or completions.
- At tick 1000 the entry expires and the resolver starts DNS transaction `0x0002` with IPv4 ID 18 on TX descriptor 5.
- The matching response resolves and refreshes the cache; a later mixed-case hit returns 200 ticks remaining with no wire activity.
- An invalid name is rejected without consuming DNS ID, IPv4 ID, descriptor, submission, or completion state.
- Final cache statistics are two hits, one miss, two stores, one expiration, and one active entry; TX completions reach 46.

## 3.38 - Terminal DNS negative outcomes

- The DNS codec exposes `AOutcome`, distinguishing a validated A answer from a validated authoritative name error while retaining the compatibility `parseAResponse` wrapper.
- `buildNameErrorResponse` creates a bounded NXDOMAIN response with the original question and no answer records.
- `pollDnsAQuery` now returns `not_found` immediately for a matching NXDOMAIN instead of counting it as unrelated input and leaving the request pending.
- A query for `missing.zigos.test` uses DNS transaction 3, IPv4 ID 19, TX descriptor 6, cursor 7, and a 78-byte frame.
- Its NXDOMAIN response is consumed exactly once, returns no A payload, empties the endpoint queue, and becomes `inactive` after socket close.
- TX completions reach 47 and ingress/UDP dispatch totals advance to `65/65` and `54/53` with no extra drops.

## 3.39 - TTL-bounded negative DNS caching

- The fixed DNS cache can now represent either a positive A record or a negative name-error outcome under the same bounded name, TTL, LRU, and expiry rules.
- `startAutomaticDnsAResolveCachedOutcome` returns a positive hit, cached not-found TTL, or a new automatic request without allocating on live cache hits.
- `pollDnsAResolveCachedOutcome` stores successful A records or matching NXDOMAIN results with a caller-supplied bounded negative TTL.
- The first missing-name lookup uses DNS ID 4 and IPv4 ID 20 on descriptor 7, then stores its `not-found` result for 60 ticks.
- A mixed-case lookup at tick 10 returns cached not-found with 50 ticks remaining and performs no TX work.
- At tick 60 the negative entry expires and a fresh request uses DNS ID 5, IPv4 ID 21, and descriptor 0; final cache statistics are one hit, two misses, one store, and one expiration.

## 3.40 - Explicit DNS request cancellation

- `DnsARequest` carries a cancellation flag, and `cancelDnsAQuery` is idempotent: the first cancellation succeeds and repeated cancellation is rejected.
- Cancelled requests immediately poll as `inactive` and cannot be retried, without consuming DNS IDs, IPv4 IDs, TX descriptors, submissions, or completions.
- Cancellation does not silently consume already queued responses; the socket queue and dequeue counters remain unchanged until close policy is chosen.
- A queued matching response remains protected by normal close, which is rejected while the packet is present.
- Explicit discard-close drains exactly one response and invalidates the generation-tagged socket; later polls remain inactive.
- The cancelled query uses DNS ID 6, IPv4 ID 22, descriptor 1, and cursor 2; TX completions reach 50 and ingress/UDP dispatch totals reach `67/67` and `56/55`.

## 3.41 - Stateful DNS resolver context

- `DnsResolver` owns a generation-tagged ephemeral UDP socket, selected server IPv4 address, active lifetime, and fixed positive/negative cache.
- Resolver opening validates the server peer before allocating a port or endpoint generation; invalid server addresses leave all allocation state untouched.
- Resolver start and poll wrappers require the live owned socket and route automatic IDs, cache outcomes, bounded polling, and negative TTL policy through one context.
- A direct query uses DNS ID 7, IPv4 ID 23, descriptor 2, and cursor 3, resolves `192.0.2.42`, and stores it in the resolver cache.
- A mixed-case follow-up returns the cached record with 200 ticks remaining and performs no TX work.
- Normal close invalidates the resolver and socket; subsequent starts are rejected without even mutating cache hit statistics.

## 3.42 - Bounded NTPv4 wire codec

- A new `ntp.zig` module builds allocation-free 48-byte NTPv4 client requests with a nonzero transmit timestamp.
- Synthetic server responses include stratum, poll, precision, fixed-point root delay/dispersion, reference ID, and all four timestamps.
- Response parsing validates server mode, NTP version 3/4, non-alarm leap state, stratum 1-15, exact originate echo, monotonic receive/transmit timestamps, and post-1970 epoch conversion.
- The deterministic response reports stratum 2, poll 6, precision -20, reference `LOCL`, Unix second 1800000000, and half-second fraction `0x80000000`.
- Zero timestamps, short buffers, client-mode replies, leap alarms, invalid strata, wrong originate timestamps, zero transmit time, pre-Unix epochs, and truncation are rejected.

## 3.43 - Connected NTP client transaction

- `sendNtpRequest` requires a generation-valid socket connected to UDP port 123 and transmits the bounded 48-byte request through automatic IPv4 identification.
- `receiveNtpResponse` consumes one connected datagram and validates the echoed originate timestamp before exposing server time.
- A zero client timestamp is rejected without consuming IPv4 ID, TX descriptor, submission, or completion state.
- The valid request uses IPv4 ID 24, descriptor 3, cursor 4, and a 90-byte Ethernet frame.
- Two server responses are queued: a wrong originate timestamp is consumed and rejected, then the valid response returns Unix second 1800000000, half-second fraction, stratum 2, and reference `LOCL`.
- Endpoint accounting balances at `2/2`; TX completions reach 52 and ingress/UDP dispatch totals reach `70/70` and `59/58`.

## 3.44 - Resumable bounded NTP polling and cancellation

- `NtpRequest` retains the generation-tagged socket, client originate timestamp, completed transmit record, transmission count, and cancellation state.
- `pollNtpRequest` consumes at most a caller budget, rejecting malformed or mismatched replies while returning `inactive`, `pending`, or `resolved`.
- A zero budget leaves three replies queued; a budget of two rejects wrong-originate and client-mode packets, leaving one valid reply for the next poll.
- The next poll resolves Unix second 1800000000 with half-second fraction and drains the endpoint queue.
- A second request proves idempotent cancellation: polling becomes inactive without consuming its queued valid reply, normal close is rejected, and explicit discard-close drains one packet.
- The two requests use IPv4 IDs 25/26 and descriptors 4/5; TX completions reach 54 while ingress/UDP dispatch totals reach `74/74` and `63/62`.

## 3.45 - Transactional NTP retransmission

- `retryNtpRequest` reuses the original nonzero client originate timestamp while sending a fresh UDP/NTP request through automatic IPv4 identification.
- An initial request uses IPv4 ID 27, descriptor 6, and cursor 7; an empty poll remains pending without consuming state.
- The retry uses IPv4 ID 28 and descriptor 7, wraps the TX producer to zero, and advances the TX-wrap counter from 5 to 6.
- A matching server response resolves normally with the same originate timestamp and deterministic Unix time.
- Retrying the request after socket close is rejected without changing IPv4 ID, TX cursor, submissions, completions, or request transmission count.
- Two transmissions raise TX completions to 56; ingress/UDP dispatch advance by one response to `75/75` and `64/63`.

## 3.46 - Stateful NTP client context

- `NtpClient` owns a validated server IPv4 address, connected generation-tagged ephemeral UDP socket, and active lifetime.
- Opening rejects an invalid server before consuming endpoint slots, ephemeral ports, or generations.
- Start, poll, and retry wrappers require the live owned socket and reject requests from another or closed context.
- A context request uses IPv4 ID 29, descriptor 0, cursor 1, and resolves the deterministic Unix time in one poll.
- Closing invalidates both client and socket; subsequent start, poll, and retry operations are rejected without changing TX state or request transmission count.
- TX completions reach 57 and ingress/UDP dispatch totals reach `76/76` and `65/64`.

## 3.47 - Monotonic synchronized network clock

- `ntp.Clock` begins unsynchronized and exposes time only after a validated NTP response is applied.
- Applying a response stores Unix seconds/fraction, stratum, reference ID, and accepted/stale sample counters.
- Duplicate timestamps and backward samples are rejected as stale without rolling back time or changing source metadata.
- A later fractional sample in the same second is accepted, followed by a next-second sample that becomes the final clock value.
- The deterministic proof ends at Unix second 1800000001, fraction `0x10000000`, stratum 4, reference `NEXT`, with three accepted and two stale samples.

## 3.48 - Clock-aware bounded NTP polling

- `pollNtpClientClock` composes the owned NTP client, bounded request polling, response validation, and monotonic clock application in one result.
- A zero-budget poll leaves the queued response and unsynchronized clock untouched and reports no clock-application result.
- The first valid response resolves the request and synchronizes the clock to Unix second 1800000000 with fraction `0x80000000`.
- A second valid protocol response carrying the same server timestamp resolves normally but is classified as a stale clock sample without changing time or source metadata.
- Closing the client makes later clock-aware polling inactive and leaves the synchronized clock byte-for-byte unchanged.
- Two new transmissions finish at IPv4 ID 31, TX cursor 3, 59 TX completions, and ingress/UDP dispatch totals `78/78` and `67/66`.

## 3.49 - Monotonic-tick wall-clock projection

- `ntp.ProjectedClock` anchors a validated Unix timestamp to a caller-owned monotonic tick and tick frequency.
- Reads convert elapsed ticks to exact 32-bit Unix fractions with carry into whole seconds, without floating-point arithmetic or allocation.
- The deterministic proof advances a half-second sample through quarter-, three-quarter-, and one-second elapsed positions with exact fractions.
- Zero-frequency application and reads before the anchor tick are rejected without changing synchronization state.
- A newer response reanchors time and source metadata; an older response at a later monotonic tick is stale and cannot alter the anchor.
- The proof finishes with two accepted samples, one stale sample, stratum 3, reference `SYNC`, and the projected quarter-second value `1800000002/0x50000000`.

## 3.50 - ACPI PM timer continuous reference fallback

- The FADT legacy and extended PM-timer blocks are parsed with checksum, address-space, width, and mapping validation.
- HPET remains the preferred calibration/reference source; the 3.579545 MHz ACPI PM timer is selected when HPET is absent; PIT channel 2 remains delay-only last resort.
- Both 24-bit and 32-bit PM timer counters are supported with mask-based wrap arithmetic and bounded nanosecond waits.
- `time_reference.ContinuousCounter` extends finite-width hardware counters into a monotonic 64-bit tick stream.
- Boot verification reads the selected continuous counter, waits one millisecond through the same reference, and requires a strictly positive delta.
- The no-HPET QEMU topology now calibrates the APIC timer from the ACPI PM timer instead of the one-shot PIT fallback.

## 3.51 - Live reference-backed NTP wall clock

- The kernel passes its wrap-extending HPET/ACPI-PM continuous counter into the e1000e network validation path.
- `pollNtpClientReferenceClock` samples the hardware counter only when a validated NTP response is actually consumed.
- A zero-budget poll leaves both the queued response and the continuous-counter anchor untouched.
- The first response anchors Unix time to the live hardware tick; after a real two-millisecond reference delay, projected Unix time is strictly later.
- A second protocol-valid response with the original server timestamp is stale relative to the advanced hardware-backed clock and cannot reanchor it.
- Closing the NTP client makes later reference-clock polling inactive without sampling the counter or changing synchronized time.
- The proof completes at IPv4 ID 33, TX cursor 5, 61 TX completions, and ingress/UDP dispatch totals `80/80` and `69/68` on both HPET and ACPI PM timer paths.

## 3.52 - Fail-fast resource-safe QEMU harness

- The shared QEMU mutex now rejects duplicate launchers immediately by default instead of allowing PowerShell or Python parents to queue for fifteen minutes.
- `-HarnessWaitSeconds` permits a bounded intentional wait while retaining fail-fast behavior for normal local and automated runs.
- After exclusive ownership is obtained, the harness removes only stale QEMU or NVMe-image-builder processes whose command line is rooted in this ZigOs checkout; unrelated Android emulator processes are never selected.
- QEMU runs at below-normal Windows process priority and its process object is disposed after forced or normal shutdown.
- `scripts/cleanup-zigos-tests.ps1` provides inspection-first manual recovery and requires `-Terminate` before stopping repository-owned QEMU, test-harness PowerShell, or bounded build-helper Python processes.
- The cleanup and mutex rules prevent the duplicate process trees that previously exhausted host memory while preserving the single-test shared artifact model.

## 3.53 - Deadline-driven NTP synchronization service

- `NtpService` owns one NTP client, one projected wall clock, optional in-flight request state, retry/refresh deadlines, and lifecycle counters.
- `stepNtpService` is externally driven and bounded: it never sleeps, busy-waits, or launches work outside the caller's budget.
- The unsynchronized service starts immediately, emits no packet before its retry deadline, and retransmits the same originate timestamp exactly at the deadline.
- A valid response samples the live HPET or ACPI PM counter, synchronizes wall time, and schedules a refresh deadline.
- Before refresh no packet is sent; at the deadline a fresh request crosses TX descriptor 7 to cursor 0 and a newer response advances time to Unix second 1800000002.
- Closing invalidates the owned socket and makes later service steps inactive without sampling time or consuming network state.

## 3.54 - Projected-time NTP timestamp generation

- `unixTimeToTimestamp` converts Unix seconds plus the 32-bit fraction into NTP's 64-bit seconds/fraction representation without floating point.
- `projectedTimestampAt` reads the synchronized monotonic projection and produces a client transmit timestamp at a caller-selected tick.
- The fixture anchor maps exactly to `0xEEF4508080000000`; quarter-second and fractional-carry reads map to `0xEEF45080C0000000` and `0xEEF4508140000000`.
- Unsynchronized clocks, ticks before the projection anchor, and Unix times outside the supported 32-bit NTP seconds era are rejected.
- The maximum supported Unix time with fraction `0xFFFFFFFF` maps exactly to `0xFFFFFFFFFFFFFFFF`.

## 3.55 - Automatic NTP service timestamp selection

- `selectNtpServiceTimestamp` accepts a nonzero bootstrap timestamp only while the service clock is unsynchronized.
- Once synchronized, the selector ignores the bootstrap value and derives timestamps from the projected clock at the caller's monotonic tick.
- `stepNtpServiceAutomatic` reuses an in-flight request's retained originate timestamp and selects a fresh projected timestamp only when starting a new transaction.
- Zero bootstrap and ticks before the projection anchor are rejected without producing a timestamp.
- The deterministic proof maps bootstrap, anchor, and quarter-second selection to `0xEEF4507F40000000`, `0xEEF4508080000000`, and `0xEEF45080C0000000`.
## 3.56 - Live automatic NTP service timestamps

- `stepNtpServiceAutomatic` now selects a timestamp only when a new request is actually due, so idle calls before the projected-clock anchor remain valid and non-consuming.
- An unsynchronized service rejects a zero bootstrap timestamp without consuming an IPv4 identification, TX descriptor, completion, or submission.
- The initial request uses the explicit bootstrap timestamp; retries preserve that request's original originate timestamp exactly.
- Once synchronized, a refresh request ignores the bootstrap argument and derives its originate timestamp from projected wall time at the refresh deadline.
- The live e1000e verifier proves bootstrap rejection, retry preservation, pre-anchor idle behavior, projected-time refresh, two accepted samples, exact accounting, and inert shutdown.

## 3.57 - Deterministic NTP sample-quality policy

- `ntp.QualityPolicy` bounds accepted stratum, signed 16.16 root-delay magnitude, and unsigned 16.16 root dispersion.
- `ntp.evaluateQuality` returns one deterministic outcome: accepted, invalid policy, stratum, root delay, or root dispersion.
- Root delay is interpreted as signed fixed-point and compared by magnitude, including the full negative `i32` range without overflow.
- Exact threshold equality is accepted; the next representable positive or negative delay and dispersion values are rejected.
- A boot-time verifier exercises the parsed fixture response, exact boundaries, invalid policy, excessive stratum, positive delay, negative delay, and dispersion.

## 3.58 - Quality-gated live NTP service

- `openNtpServiceWithPolicy` validates quality policy before opening a UDP socket; invalid policy is rejected without consuming endpoint, port, generation, TX, or identification state.
- `NtpService` owns its quality policy plus accepted and per-reason rejection counters.
- A syntactically valid response is evaluated before reading the continuous reference counter or applying wall time.
- Rejected responses are consumed and reported while the request remains active for another response or deadline-driven retry.
- The live verifier injects an excessive-dispersion response, proves no clock sample or mutation occurred, then accepts a good response on the retained request and completes the projected-time refresh cycle.
## 3.59 - NTP synchronization health snapshots

- `readNtpServiceHealth` classifies a service as inactive, unsynchronized, synchronized, holdover, or expired without mutating service, socket, clock, deadline, or accounting state.
- Callers supply strict holdover and expiry thresholds; zero, equal, and reversed thresholds are rejected.
- Synchronized and holdover snapshots expose projected Unix time and sample age. Expired snapshots explicitly withhold wall time.
- Reads before the projected-clock anchor are rejected instead of underflowing sample age.
- Snapshot metadata includes request activity, retry/refresh deadlines, request/retry/response counters, and quality acceptance/rejection totals.
## 3.60 - Capped exponential NTP retry policy

- `ntp.RetryPolicy` defines an initial interval, maximum interval, and explicit maximum retry count.
- Invalid zero initial intervals, caps below the initial interval, and zero retry limits are rejected.
- `retryIntervalForAttempt` doubles intervals by attempt, saturates exactly at the configured cap, and returns no interval after the retry limit.
- Fixed-interval policies remain supported by setting the initial and maximum intervals equal.
- Saturation near `u64` maximum is overflow-safe and reaches the exact configured maximum.

## 3.61 - Live NTP retry backoff and timeout

- `openNtpServiceWithPolicies` validates quality and retry policies before opening a socket while legacy constructors retain fixed-interval compatibility.
- Each request owns an independent retry-attempt counter and schedules capped exponential deadlines from `ntp.RetryPolicy`.
- After the final retry, the service waits one final capped interval, cancels the request, increments timeout accounting, and latches the `timed_out` state.
- A timed-out service cannot silently restart; `clearNtpServiceTimeout` must explicitly clear exhaustion before another request cycle.
- Synchronization-health snapshots expose retry attempts, exhaustion, timeout count, and last timeout tick without mutation.
- The live verifier proves `1/2/4/4` waits, three retries, exact timeout at tick delta 11, latched inactivity, explicit clear, clean restart, active-request close, and exact ring/accounting deltas.
## 3.62 - Bounded NTP timeout-recovery policy

- `ntp.RecoveryPolicy` defines a nonzero cooldown and an explicit maximum number of automatic recoveries.
- `evaluateRecovery` returns invalid policy, waiting, ready, or exhausted together with the exact recovery deadline.
- Readiness changes exactly at the cooldown boundary; recovery count equality is terminal exhaustion.
- Deadline addition is saturating, so recovery scheduling near `u64` maximum cannot wrap into the past.
- The verifier proves invalid-policy rejection, first and second recovery readiness, terminal exhaustion, exact boundary behavior, and overflow-safe waiting/readiness.
## 3.63 - Live bounded NTP automatic recovery

- `openNtpServiceWithRecoveryPolicies` validates quality, retry, and optional recovery policies transactionally before opening a socket.
- Services without a recovery policy retain the explicit-clear timeout behavior from 3.61.
- Recovery-enabled services remain inert until the saturated cooldown deadline, then start exactly one new request with start reason `recovery`.
- Each automatic restart consumes one recovery allowance. Consecutive success resets the recovery budget; repeated outage eventually latches terminal recovery exhaustion.
- Unsynchronized recovery preserves the original bootstrap originate timestamp; synchronized recovery derives a fresh projected timestamp.
- Synchronization-health snapshots expose recovery deadline, automatic recovery count, exhaustion, and terminal limit hits.
- The live verifier proves two cooldown-gated restarts, three retry timeouts, terminal exhaustion after the second recovery, no hidden fourth request, clean close, and exact six-transmission ring/accounting deltas.
## 3.64 - Synchronized holdover recovery and budget reset

- Synchronization-health snapshots keep projected wall time visible and advancing through refresh timeout and recovery cooldown while the sample remains within holdover limits.
- Recovery requests from a synchronized clock use fresh projected originate timestamps rather than the original bootstrap value.
- `NtpService.recovery_successes` records successful automatic recoveries monotonically.
- An accepted recovery sample clears timeout/recovery state, resets the consecutive automatic-recovery allowance, and preserves monotonic wall time.
- A subsequent outage receives the full recovery budget again, proving recovery success is a circuit-breaker reset rather than a lifetime allowance consumption.
- The live verifier proves two accepted samples, visible holdover, projected recovery timestamps, success accounting, a second allowed recovery, clean close, and exact seven-transmission/two-response accounting.
## 3.65 - Bounded NTP forward clock-step policy

- `ntp.ClockStepPolicy` expresses the maximum accepted forward correction as exact seconds plus a 32-bit fraction.
- `forwardTimeDelta` subtracts synchronized timestamps without floating point and handles fractional borrow exactly.
- Equal and backward candidates are stale; an unsynchronized clock may accept its initial sample.
- Exact policy equality is accepted. One fractional unit or one whole-second excess is rejected as an excessive forward step.
- `evaluateResponseStepAt` applies the same policy against projected wall time at a caller-supplied monotonic tick.
- The verifier proves invalid zero policy, initial acceptance, stale equality/backward behavior, borrow/no-borrow equality, and exact over-boundary rejection.
## 3.66 - Quality and step-gated live NTP discipline

- `NtpService` owns a validated `ClockStepPolicy`; legacy constructors use a one-hour default forward bound.
- The response path evaluates syntax, quality, one continuous-counter sample, and projected forward-step policy in that order.
- Step evaluation and clock application share the same sampled tick, eliminating a time-of-check/time-of-use gap.
- A quality-accepted but stale or excessive response is consumed and counted while the request remains active; wall time and recovery state remain unchanged.
- Health snapshots expose accepted and per-reason step rejection counters alongside quality and retry state.
- The live verifier injects an excessive 100-second reply, proves sampled-but-unapplied transactional rejection, then accepts a bounded two-second reply on the retained request with exact two-TX/three-RX accounting.
## 3.67 - Stale NTP sample retention and retry

- A syntactically valid and quality-accepted stale response is sampled and classified by the live clock-step gate without applying wall time.
- Stale rejection increments the dedicated discipline counter while leaving the projected clock, active request, originate timestamp, and retry deadline intact.
- The retained request follows the normal deadline-driven retry path rather than opening a new socket or transaction.
- A later bounded response on the same request may synchronize successfully and closes the rejection/retry cycle.
- The live verifier proves stale transactional rejection, exact retry timing, retry timestamp preservation, two transmissions plus one retry, three consumed replies, clean close, and exact ring/accounting deltas.
## 3.68 - Bounded NTP discipline-rejection budget

- `ntp.StepRejectionPolicy` defines a nonzero maximum number of step rejections allowed for one active request.
- `evaluateStepRejectionBudget` is side-effect free and returns invalid policy, retain request, or retry now plus the exact remaining allowance.
- Counts strictly below the limit retain the request; equality and all larger counts transition deterministically to immediate retry.
- Zero current rejections report the full allowance, making the decision usable before and after each rejection.
- Arithmetic remains safe at the `u8` maximum: count 254 retains one allowance and count 255 retries immediately.
- The verifier proves invalid zero policy, zero/first/penultimate retention, exact boundary/beyond retry, remaining allowance, and maximum-count behavior.

## 3.69 - Live NTP rejection-budget retry

- `NtpService` owns a validated step-rejection policy, the current per-transmission rejection count, and total discipline-forced retries.
- Legacy constructors use a maximum budget of 255, preserving prior retain-until-deadline behavior.
- Each stale or excessive high-quality response increments the current count and exposes retain/retry action plus remaining allowance in `NtpServiceStep`.
- Below the boundary the request, originate timestamp, clock, and normal retry deadline remain unchanged.
- At the exact boundary the service retries immediately, before the normal deadline, using the same request and originate timestamp while remaining bounded by the existing retry policy.
- A forced retry resets the per-transmission rejection count; an accepted response also resets it and completes normally.
- The live verifier proves one retained stale response, one excessive boundary response, immediate forced retry, timestamp preservation, accepted follow-up, clean close, and exact three-TX/four-RX accounting.

## 3.70 - Discipline-forced retry exhaustion

- A discipline boundary may request immediate retry only while the ordinary retry policy still has an available attempt.
- When a later rejection reaches the same boundary after retry allowance is exhausted, the service cancels the request, latches `timed_out`, increments the retry-limit counter, and sends no hidden packet.
- The projected clock remains unchanged and readable in holdover; health reports the active rejection count, forced-retry total, and retry exhaustion.
- The timed-out state is inert until `clearNtpServiceTimeout`; clearing now also resets the per-request discipline-rejection count.
- The live verifier proves one forced retry, second-boundary exhaustion, request cancellation, latched timeout, health exposure, explicit clear, duplicate-clear rejection, clean close, and exact three-TX/three-RX accounting.

## 3.71 - Synchronized discipline-timeout recovery

- A synchronized service that exhausts retry allowance through the discipline-rejection boundary enters the same bounded recovery state machine as an ordinary network timeout.
- The projected clock remains visible and advances through the timeout instant and recovery cooldown; no packet is transmitted before the exact recovery deadline.
- The automatic recovery request derives its originate timestamp from projected holdover time and starts on the existing socket without manual timeout clearing.
- A bounded, quality-valid recovery sample applies at one hardware reference tick, increments recovery success, and resets consecutive recovery, retry, and discipline-rejection budgets.
- Health returns to synchronized state with monotonic wall time and exposes the completed recovery without losing timeout or forced-retry accounting.
- The live verifier proves four transmissions, four consumed replies, no hidden cooldown traffic, exact HPET/ACPI PM timer behavior, clean close, and exact ring/accounting deltas.

## 3.72 - Bounded NTP quality-rejection budget

- `ntp.QualityRejectionPolicy` defines a nonzero maximum number of quality rejections allowed for one active request.
- `evaluateQualityRejectionBudget` is side-effect free and returns invalid policy, retain request, or retry now plus the exact remaining allowance.
- Counts strictly below the limit retain the request; equality and all larger counts transition deterministically to immediate retry.
- Zero current rejections report the full allowance, making the decision usable before and after each quality rejection.
- Arithmetic remains safe at the `u8` maximum: count 254 retains one allowance and count 255 retries immediately.
- The verifier proves invalid zero policy, zero/first/penultimate retention, exact boundary/beyond retry, remaining allowance, and maximum-count behavior.

## 3.73 - Live pre-sample NTP quality retry

- `NtpService` now owns a quality-rejection policy, per-transmission quality rejection count, and total quality-forced retry counter.
- `openNtpServiceWithResponseRejectionPolicies` validates quality, quality-rejection, clock-step, step-rejection, retry, and optional recovery policies before opening a socket; existing constructors retain maximum-budget compatibility.
- Quality-rejected responses are consumed and reason-counted without sampling HPET/ACPI PM timer or mutating projected time.
- Rejections below the exact budget retain the active request; the boundary triggers an immediate retry on the same socket and request with the originate timestamp preserved.
- Every transmission and every quality-accepted response resets the per-transmission quality-rejection count; successful synchronization also resets retry state.
- Health snapshots expose the configured quality budget, current count, and total quality-forced retries.
- The live verifier proves root-dispersion retention, stratum boundary retry, no hardware samples on either rejection, accepted follow-up synchronization, exact reason counters, and exact ring/accounting deltas.

## 3.74 - Quality-forced retry exhaustion

- A one-rejection quality budget and one-retry transport budget prove the exact interaction between pre-sample quality rejection and terminal retry exhaustion.
- The first low-quality response forces an immediate retry on the existing request with the originate timestamp preserved and no hardware clock sample.
- A second low-quality response after that retry reaches the retry ceiling, cancels the request, latches timed-out state, and emits no hidden transmission.
- Both root-dispersion and stratum rejections preserve the unsynchronized projected clock and expose no sample or apply result.
- Health reports the configured quality budget, boundary count, quality-forced retry total, retry exhaustion, and retry-limit hit.
- Explicit timeout clear resets quality, step, and retry counts; duplicate clear is rejected and a clean bootstrap request can restart immediately.
- The verifier proves three transmissions, two consumed replies, exact reason counters, clean close, and exact ring/accounting deltas on both reference sources.

## 3.75 - Synchronized quality-timeout recovery

- A synchronized service that exhausts retry allowance through the pre-sample quality-rejection boundary enters the bounded recovery state machine without losing projected wall time.
- Root-dispersion and stratum failures are consumed without reading HPET/ACPI PM timer or mutating the projected clock; the first forces retry and the second triggers timeout.
- The clock remains visible and advances as holdover through timeout and the exact two-tick recovery cooldown; no packet is transmitted during the wait.
- Automatic recovery starts on the existing socket with an originate timestamp derived from projected holdover time.
- A quality-valid, bounded-step recovery sample applies at one hardware reference tick, increments recovery success, and resets recovery, retry, quality-rejection, and step-rejection budgets.
- Health returns to synchronized state while retaining cumulative quality reasons, forced-retry, retry-limit, and recovery-success accounting.
- The verifier proves four transmissions, four consumed replies, no pre-sample clock reads, no hidden cooldown traffic, exact HPET/ACPI PM timer behavior, clean close, and exact ring/accounting deltas.

## 3.76 - Deterministic NTP source rotation policy

- `ntp.SourceRotationPolicy` requires at least two sources and a nonzero consecutive-failure threshold.
- `evaluateSourceRotation` is side-effect free and returns invalid policy, invalid source, stay, or rotate plus the selected source index and exact remaining failure allowance.
- Failure counts below the threshold stay on the current source; equality and all larger counts rotate to the next source.
- Rotation from the final configured source wraps deterministically to source zero.
- Out-of-range current source indices are rejected without yielding a usable selection.
- Arithmetic remains safe at the `u8` maximum: source 254 with 254 failures stays with one allowance, while failure 255 rotates to source zero.
- The verifier proves zero/single-source and zero-threshold rejection, invalid-index handling, exact stay/rotate boundaries, wraparound, and maximum-count behavior.

## 3.77 - Transactional NTP client server switch

- `switchNtpClientServer` changes an active NTP client's connected server without closing or replacing its UDP socket.
- The current peer must match the client's recorded server, gateway MAC, and NTP port before mutation begins.
- Invalid zero addresses, inactive clients, and stale socket handles are rejected without changing client, endpoint, cursor, generation, or packet state.
- Selecting the current server is an idempotent success with byte-for-byte client and peer preservation.
- A real switch disconnects only an empty endpoint, binds the new peer, and updates `server_ipv4` only after connection succeeds; failed connection attempts restore the original peer.
- Forward and reverse switches preserve endpoint index, socket generation, local ephemeral port, gateway MAC, and port 123.
- The verifier proves zero transmissions and receives, clean close, exact endpoint/generation cursor changes from one socket lifetime, and unchanged completion, ingress, dispatch, IP-ID, and TX-ring accounting.

## 3.78 - Validated bounded NTP source pool

- `ntp.SourcePool` stores two to four active IPv4 NTP servers in a fixed-size allocation-free array.
- Active source addresses must be nonzero and pairwise unique; unused slots outside `count` are ignored.
- Counts below two or above four are rejected.
- `sourcePoolServer` validates the entire pool before returning an indexed source and rejects out-of-range indices.
- Invalid pools cannot yield a source even when the requested index would otherwise be in range.
- The verifier proves zero/single/too-many count rejection, zero-address and duplicate rejection, valid two- and four-source pools, exact indexed selection, unused-slot semantics, and out-of-range behavior.

## 3.79 - NTP service source-pool ownership

- `NtpService` can now own an optional validated source pool and matching source-rotation policy while all existing constructors retain single-source compatibility.
- `openNtpServiceWithSourcePoolPolicies` validates the pool, rotation policy, and exact source-count match before opening a socket.
- Source-pool services open the existing NTP client on source index zero and initialize consecutive failure and rotation counters to zero.
- `NtpServiceHealth` exposes the pool, rotation policy, current source index/server, consecutive source failures, and total source rotations.
- Every accepted synchronization sample resets consecutive source failures; automatic source switching remains intentionally deferred to the next milestone.
- Invalid pools and source-count mismatches are rejected transactionally without endpoint, generation, cursor, ID, TX, or submission mutation.
- The packet-free verifier proves initial peer selection, service-state initialization, health projection, clean close, one socket-lifetime cursor changes, and otherwise unchanged completion, ingress, dispatch, IP-ID, and TX-ring accounting.

## 3.80 - Automatic same-socket NTP source failover

- Every terminal request timeout records one consecutive failure for source-pool services and evaluates the configured source-rotation threshold.
- A rotation decision stores a pending source index while the current UDP peer remains unchanged throughout the recovery cooldown.
- Recovery readiness transactionally switches the existing NTP client socket to the pending source before the projected recovery request is transmitted.
- Successful switching preserves endpoint index, socket generation, local ephemeral port, gateway MAC, and NTP port while incrementing total source rotations.
- Rotation clears the pending index and per-source failure count; an accepted synchronization sample also clears any remaining pending/failure state.
- Health exposes current and pending source indices, current server, consecutive failures, total rotations, and recovery success.
- The live verifier proves initial synchronization on `10.0.2.4`, one refresh retry, timeout selection of `10.0.2.5`, no cooldown traffic, projected recovery on the same socket, accepted alternate-server response, clean close, and exact HPET/ACPI PM timer packet/ring accounting.

## 3.81 - Consecutive-failure threshold before NTP rotation

- A two-source service configured with threshold two remains on source zero after the first complete request timeout.
- The first recovery request uses projected time on the same server and socket while preserving one consecutive source failure and zero rotations.
- If that recovery request also exhausts its retry allowance, the second source failure selects source one as pending while retaining source zero throughout the next cooldown.
- Only the second recovery deadline switches the existing socket to source one; endpoint index, generation, local port, gateway MAC, and NTP port remain unchanged.
- Both cooldowns emit no traffic, and both recovery requests derive monotonically increasing originate timestamps from holdover time.
- A valid fallback response resets pending/failure state, records one source rotation and one recovery success, and returns health to synchronized source one.
- The verifier proves six transmissions, two accepted replies, two retry-limit hits, exact threshold behavior, clean close, and exact HPET/ACPI PM timer packet/ring accounting.

## 3.82 - Live three-source NTP wraparound

- A three-source service with threshold one rotates live from source zero to one, one to two, and two back to zero.
- Each failed request includes one bounded retry, records exactly one source failure, and selects the next source while preserving the current peer through a silent two-tick cooldown.
- Each recovery deadline transactionally switches the same socket to its pending source before transmitting a projected-time request.
- All three switches preserve endpoint index, socket generation, local port, gateway MAC, and NTP port; total rotations advance exactly `1, 2, 3`.
- Refresh and all three recovery originate timestamps are projected from holdover and strictly increase.
- A valid response after wraparound synchronizes on source zero, clears pending/failure state, records one recovery success, and exposes source zero with three rotations through health.
- The verifier proves eight transmissions, two accepted replies, three retry-limit hits, three silent cooldowns, live `0→1→2→0` wraparound, clean close, and exact HPET/ACPI PM timer packet/ring accounting.

## 3.83 - Successful samples reset the NTP source-failure chain

- A two-source service with rotation threshold two experiences one complete request timeout and remains on source zero with one consecutive failure.
- Same-source recovery uses projected time, accepts a valid sample, and resets the consecutive source-failure count to zero without rotating.
- Health immediately reports source zero, no pending source, zero failures, zero rotations, and one recovery success.
- A later independent request timeout again records exactly one failure rather than accumulating to two, so source zero is retained and no pending rotation is selected.
- The second same-source recovery also succeeds and resets the chain, proving successful samples separate outages into independent failure sequences.
- Both cooldowns remain silent, all requests use the same socket, and refresh/recovery originate timestamps increase monotonically.
- The verifier proves seven transmissions, three accepted replies, two retry-limit hits, two recovery successes, zero rotations, clean close, and exact HPET/ACPI PM timer packet/ring accounting.

## 3.84 - Terminal multi-source NTP recovery exhaustion

- A three-source service permits exactly two automatic recoveries, rotating source zero to one and one to two on the same UDP socket.
- Each failed request includes one bounded retry, records one source failure, selects the next source, and preserves the current peer through a silent two-tick cooldown.
- After the source-two request exhausts its retry allowance, the recovery budget is already spent, so the timeout returns terminal `exhausted` state immediately with no wraparound transmission.
- Terminal state preserves source two as the connected peer, pending source zero as the diagnostic wrap target, one current-source failure, two completed rotations, and the original socket handle.
- Repeated service steps remain exhausted without incrementing the recovery-limit counter again or mutating IP-ID, TX-ring, or submission cursors.
- The synchronized clock remains visible as advancing holdover while health reports source, pending target, failure count, rotation count, retry exhaustion, recovery exhaustion, and the single recovery-limit hit.
- The verifier proves seven transmissions, one accepted sample, three retry-limit hits, two source rotations, zero recovery successes, clean close, and exact HPET/ACPI PM timer packet/ring accounting.

## 3.85 - Explicit reset from terminal NTP source exhaustion

- `clearNtpServiceTimeout` now clears the consecutive source-failure count in addition to retry, rejection, recovery, and pending-source transient state.
- A successful clear preserves the current source, connected UDP peer, socket handle, synchronized projected clock, source-rotation count, timeout history, and cumulative retry/recovery limit counters.
- Duplicate clears remain rejected because the service is no longer timeout-latched after the first successful clear.
- The next automatic step uses projected holdover time to start a normal refresh on the retained current source rather than switching, reopening, or reverting to bootstrap time.
- A valid response from the current source returns the service to synchronized health with zero transient outage state while cumulative diagnostics remain visible.
- The verifier isolates reset semantics by seeding the terminal state already proven in 3.84, then proves two transmissions, two accepted samples, source-two/socket/clock preservation, clean close, and exact HPET/ACPI PM timer packet/ring accounting.

## 3.86 - Transactional operator-selected NTP source reset

- Added `resetNtpServiceTimeoutToSource`, combining valid pool-source selection with terminal timeout clearing in one operation.
- Invalid source indexes, invalid pool/rotation policy state, inactive services, live requests, non-exhausted services, and stale sockets are rejected before mutation.
- A valid target is applied through the existing transactional same-socket peer switch, then retry, rejection, recovery, pending-source, and consecutive-failure transient state is cleared.
- Manual source selection preserves automatic source-rotation counts, timeout history, cumulative request/retry/response counters, and retry/recovery limit-hit diagnostics.
- Duplicate reset attempts are rejected after the timeout latch has been cleared.
- The packet-free verifier proves source `2 -> 1`, server `10.0.2.6 -> 10.0.2.5`, exact state preservation on invalid selection, same-socket valid selection, zero packet/ring activity, and clean close.

## 3.87 - Live projected refresh after operator source selection

- A synchronized terminal service can be reset directly from source two to source one through `resetNtpServiceTimeoutToSource` without replacing its UDP socket or projected clock.
- The selected source becomes the connected peer before the timeout latch is cleared, while automatic rotation count and cumulative timeout diagnostics remain unchanged.
- The next automatic step uses projected holdover time and starts a normal refresh on the selected source rather than bootstrap or recovery mode.
- A valid response from source one is quality-gated, step-gated, sampled from the active hardware reference, and applied to the projected clock.
- Successful acceptance leaves synchronized health on source one with no pending source, no source-failure chain, no retry/recovery latch, and all cumulative limit counters preserved.
- The verifier proves two transmissions, two accepted samples, source-two to source-one selection, same-socket projected refresh, clean close, and exact HPET/ACPI PM timer packet/ring accounting.

## 3.88 - Automatic failover after operator-selected NTP recovery

- A terminal synchronized service is reset manually from source two to source one without incrementing automatic source rotations.
- The manually selected source accepts a projected refresh and returns to ordinary synchronized service state with all transient outage state cleared.
- Its next refresh uses projected time, performs one bounded retry with an unchanged originate timestamp, and times out without a hidden transmission.
- Threshold-one source failure selects source two as pending while source one remains connected throughout the silent recovery cooldown.
- At the recovery deadline the existing socket switches from source one to source two, increments automatic rotations exactly once, and transmits a projected recovery request.
- A valid source-two response synchronizes the clock, clears pending/failure/recovery state, records one recovery success, and preserves cumulative pre-reset diagnostics.
- The verifier proves five transmissions, three accepted replies, manual rotation preservation, one automatic fallback rotation, clean close, and exact HPET/ACPI PM timer packet/ring accounting.

## 3.89 - Reject delayed replies from the previous NTP source

- A synchronized source-pool service enters recovery with source two pending while source one remains the previous peer.
- At the recovery deadline the existing socket switches to source two and transmits a projected-time request without replacing its endpoint, generation, or local port.
- A delayed, otherwise valid NTP response from source one is rejected by connected UDP peer filtering before endpoint delivery.
- The rejected packet increments the peer-mismatch counter exactly once but produces no NTP poll examination, quality result, hardware sample, step evaluation, clock mutation, or request mutation.
- The request remains active and accepts the valid source-two response normally, clearing recovery state and recording one recovery success.
- The verifier proves two transmissions, two accepted samples, one peer-filtered ingress packet, unchanged NTP counters across rejection, clean close, and exact HPET/ACPI PM timer accounting.

## 3.90 - Reject wrong-originate replies from the active NTP source

- A source-pool recovery switches the existing socket to source two and starts a projected-time request.
- An otherwise valid response from the active connected peer is routed to the NTP endpoint but carries an originate timestamp that does not match the live request.
- The bounded NTP poll examines and rejects exactly one datagram, remains pending, and does not classify the packet as a quality or clock-step rejection.
- Rejection performs no hardware-reference read, sample, clock application, peer-mismatch drop, request mutation, retry, or transmission.
- The unchanged request then accepts a correctly originated response from the same source and completes recovery normally.
- The verifier proves two transmissions, two accepted samples, one transaction-layer rejection, preserved peer-drop accounting, clean close, and exact HPET/ACPI PM timer packet/ring accounting.

## 3.91 - Resolve a valid NTP reply behind a rejected reply in one batch

- A recovery request on source two queues two current-peer responses: a wrong-originate datagram followed by a correctly originated response.
- One service step with budget two examines both packets, rejects exactly the first, resolves the second, and leaves no response queued.
- The transaction-layer rejection does not count as a quality, clock-step, or peer-mismatch rejection.
- The valid response triggers exactly one hardware sample and one clock application in the same step.
- Because the valid response is found within the bounded poll, no deadline retry or extra transmission occurs.
- The verifier proves two transmissions, a `resolved/2/1` poll outcome, two accepted samples, preserved peer-drop and retry counts, clean close, and exact HPET/ACPI PM timer accounting.

## 3.92 - Rejected NTP traffic cannot postpone a due retry

- A source-two recovery request receives a wrong-originate response at the exact retry deadline.
- The current-peer packet is routed and examined once, rejected at the transaction layer, and leaves quality, clock-step, peer-drop, and rejection-budget counters unchanged.
- Rejection performs no hardware sample or clock application and preserves the request's socket and originate timestamp.
- Because the deadline is already due, the same service step transmits the normal retry rather than allowing invalid traffic to extend the request lifetime.
- The retry preserves the originate timestamp, increments transmissions to two, resets no quality/discipline budget, and remains bounded by the configured retry limit.
- A valid response after the retry completes recovery normally.
- The verifier proves three transmissions, one transaction rejection at deadline, one exact retry, two accepted samples, clean close, and exact HPET/ACPI PM timer accounting.

## 3.93 - Preserve a queued valid NTP reply across a deadline retry

- A source-two recovery request queues a wrong-originate response followed by a correctly originated response.
- At the exact retry deadline, a service step with budget one consumes and rejects only the first packet.
- The same step performs the due retry with the unchanged originate timestamp and leaves the valid response queued and readable.
- The endpoint status proves exactly one pending packet remains after the retry.
- A second budget-one step at the same tick resolves the retained valid response, samples and applies the clock once, and emits no additional retry or transmission.
- The endpoint queue is empty after acceptance and all peer, quality, discipline, retry, and recovery counters remain exact.
- The verifier proves three transmissions, two accepted samples, one retained queued response, clean close, and exact HPET/ACPI PM timer packet/ring accounting.

## 3.94 - Zero-budget NTP polling preserves queued data and deadlines

- A valid source-two response is already queued when the retry deadline becomes due.
- A service step with receive budget zero examines and rejects no packets and returns no response.
- Zero-budget polling performs no hardware sample, quality evaluation, clock-step evaluation, or clock mutation.
- Deadline scheduling remains independent of receive budget, so the same step transmits the due retry with the unchanged originate timestamp.
- Endpoint depth and enqueue/dequeue counters prove the valid response remains queued and readable after the retry.
- A following budget-one step resolves and accepts the retained response without another retry, then leaves the endpoint queue empty.
- The verifier proves three transmissions, two accepted samples, exact zero-budget queue preservation, clean close, and exact HPET/ACPI PM timer accounting.

## 3.95 - Purge residual NTP datagrams after an accepted response

- `NtpService` now tracks cumulative `post_response_discards`, and health snapshots expose the same counter.
- After a response passes transaction, quality, and clock-step validation and is applied, the service discards every residual datagram queued on the same NTP socket.
- The accepted response itself is consumed by the bounded poll; only later queued duplicates or stale transaction packets count as post-response discards.
- Purging occurs only in the accepted apply branch and therefore does not run for transaction, quality, or clock-step rejection.
- The verifier queues three same-peer responses, accepts the first with budget one, purges exactly two residual datagrams, and proves endpoint depth `3 -> 0` with dequeue accounting `0 -> 3`.
- Health reports two cumulative discards, a subsequent idle step emits no traffic and preserves state, and the socket closes normally.
- The verifier proves one transmission, one accepted sample, two post-response discards, and exact HPET/ACPI PM timer packet/ring accounting.

## 3.96 - Quality rejection preserves queued NTP responses

- A root-dispersion-invalid response and a valid response are queued behind the same live NTP request.
- Budget-one polling resolves the first datagram syntactically, rejects it through quality policy, and retains the request.
- Quality rejection takes no hardware sample, performs no clock-step evaluation or apply, and does not run the post-response purge.
- Endpoint depth and queue accounting prove the valid response remains queued and readable after the rejection.
- A second budget-one step accepts the retained valid response, clears the request's quality-rejection count, and leaves the endpoint queue empty.
- Because no datagram remains after acceptance, cumulative post-response discards remain zero and health reports zero.
- The verifier proves one transmission, one quality rejection, one accepted sample, no purge, clean close, and exact HPET/ACPI PM timer accounting.

## 3.97 - Clock-step rejection preserves queued NTP responses

- A synchronized service starts a projected refresh with a strict four-second forward-step limit.
- A quality-valid response that is one hundred seconds ahead is followed by a bounded valid response in the same endpoint queue.
- Budget-one polling accepts the first packet's quality, samples the hardware reference once, rejects the excessive forward clock step, and retains the live request.
- Clock-step rejection performs no clock application and does not run the post-response purge.
- Endpoint depth and queue accounting prove the bounded response remains queued and readable after rejection.
- A second budget-one step accepts the retained bounded response, resets the request's step-rejection count, and leaves the queue empty.
- Because no residual datagram remains after acceptance, cumulative post-response discards stay zero.
- The verifier proves two transmissions, three quality-accepted packets, one step rejection, two applied samples, clean close, and exact HPET/ACPI PM timer accounting.


## 3.98 - Transaction rejection preserves queued NTP responses

- A wrong-originate response and a valid response from the connected active peer are queued behind one live request.
- Budget-one polling consumes and rejects the wrong-originate datagram at the NTP transaction layer while leaving the request pending.
- Transaction rejection performs no hardware sample, quality evaluation, clock-step evaluation, clock application, retry, or post-response purge.
- Endpoint depth and queue accounting prove the valid response remains queued and readable after the transaction rejection.
- A second budget-one step accepts the retained valid response and leaves the endpoint queue empty.
- Because no residual datagram remains after acceptance, cumulative post-response discards stay zero and health reports zero.
- The verifier proves one transmission, one transaction rejection, one accepted sample, no purge, clean close, and exact HPET/ACPI PM timer accounting.


## 3.99 - Purge stale idle NTP datagrams before new requests

- The service and health snapshot expose cumulative `pre_request_discards` separately from accepted-response `post_response_discards`.
- Every new initial, refresh, or recovery request uses one shared generation-safe socket purge immediately before transmission.
- Retransmissions remain outside this purge boundary because they continue the same NTP transaction and preserve its originate timestamp.
- The live verifier first synchronizes normally, then queues two late same-peer replies while the service is idle.
- At the exact refresh deadline, both stale packets are discarded before the projected refresh request is transmitted.
- Endpoint queue accounting proves the stale queue is empty when the new request becomes active.
- The valid refresh response is accepted normally; health reports `pre_request_discards = 2` and `post_response_discards = 0`.
- The verifier proves two transmissions, two accepted samples, no retries, clean close, and exact HPET/ACPI PM timer accounting.


## 4.00 - Purge queued old-source replies before recovery peer switching

- A recovery edge case was identified: UDP peer switching rejects connected sockets while endpoint data is queued.
- Recovery-ready handling now discards and counts stale endpoint datagrams before applying a pending NTP source switch.
- The ordinary new-request purge remains in place after switching as a second generation-safe guard before transmission.
- The live verifier synchronizes source zero, starts a refresh, retries once, and reaches timeout with source one pending.
- Two delayed source-zero replies are routed after timeout and remain queued and readable throughout cooldown.
- At the recovery deadline, both packets are purged before the same socket switches to source one, enabling the projected recovery request to transmit.
- The accepted source-one response completes recovery with `pre_request_discards = 2`, `post_response_discards = 0`, one source rotation, and one recovery success.
- The verifier proves four transmissions, two accepted samples, unchanged retry semantics, clean close, and exact HPET/ACPI PM timer accounting.


## 4.01 - Purge queued replies before operator-selected source reset

- `resetNtpServiceTimeoutToSource` now validates the requested source before touching endpoint data.
- Once validation succeeds, the operator reset discards and counts stale queued datagrams before switching the connected NTP peer.
- The reset then selects the requested source on the same socket and clears only transient timeout, recovery, and rejection state.
- The live verifier seeds terminal state on source two with cumulative quality, discipline, recovery, rotation, and discard diagnostics.
- Two stale source-two replies are queued while the service is exhausted.
- An invalid source index is rejected without changing service state, peer binding, queue depth, or queue counters.
- A valid reset to source one purges both packets, increments `pre_request_discards` from three to five, preserves `post_response_discards = 4`, and emits no packet.
- Health reports the selected source, additive discard counters, and all cumulative lifecycle diagnostics; duplicate reset is rejected and close accounting is exact.


## 4.02 - Purge stale replies during same-source automatic recovery

- A two-source pool with a failure threshold of two records one timeout without selecting a pending source.
- Two delayed replies remain queued and readable throughout cooldown.
- Recovery readiness purges both packets before starting the projected same-source request.
- The source, connected peer, socket handle, failure count, and zero rotation count remain unchanged while recovery is active.
- Acceptance resets the transient failure count, records one recovery success, and preserves `pre_request_discards = 2` / `post_response_discards = 0`.
- HPET and ACPI PM timer boots verify four transmissions, two accepted samples, one retry-limit hit, zero rotations, clean close, and exact accounting.


## 4.03 - Purge stale replies before the initial NTP request

- Two same-peer NTP datagrams are queued on a newly opened unsynchronized service before any request exists.
- The shared request-start boundary purges both packets before transmitting the bootstrap initial request.
- The bootstrap originate timestamp is preserved exactly and the endpoint queue is empty when the request becomes active.
- A valid matching response is accepted normally, with `pre_request_discards = 2` and `post_response_discards = 0` exposed through health.
- HPET and ACPI PM timer boots verify one transmission, one accepted sample, no retries, clean close, and exact accounting.


## 4.04 - Purge stale replies during same-source operator reset

- Terminal timeout state is seeded while source one is already the current and operator-selected target.
- Two delayed source-one replies are queued before reset.
- Resetting to the same source purges both packets, increments `pre_request_discards` from four to six, and preserves `post_response_discards = 3`.
- The source, connected peer, socket handle, rotation count, clock-independent cumulative diagnostics, and TX ring state remain unchanged.
- Only transient timeout, recovery, and rejection counters are cleared.
- A duplicate reset is rejected before any further queue or counter mutation.
- Health reports source one, additive discard accounting, and preserved lifecycle diagnostics; close accounting is exact on HPET and ACPI PM timer boots.


## 4.05 - Accumulate pre-request and post-response purges independently

- One service lifecycle exercises both purge boundaries twice without resetting counters.
- Two stale datagrams before the initial request increment only `pre_request_discards` to two.
- A valid initial response followed by two residual datagrams increments only `post_response_discards` to two.
- Two stale idle datagrams before refresh increment the pre-request total to four while preserving the post-response total.
- A valid refresh response followed by one residual duplicate increments the post-response total to three while preserving the pre-request total.
- Endpoint queue accounting closes exactly at nine enqueues and nine dequeues with high-water three and no drops.
- Health reports synchronized time with independent `pre_request_discards = 4` and `post_response_discards = 3`.
- HPET and ACPI PM timer boots verify two transmissions, two accepted samples, no retries, clean close, and exact accounting.


## 4.06 - Expose structured NTP service close and discard results

- `closeNtpServiceDiscarding` returns an `NtpServiceCloseResult` instead of hiding cancellation and queue disposal behind a boolean.
- The result records whether a request was active and cancelled, its originate timestamp and transmission count, the complete UDP discard-close record, and the service pre/post purge and lifecycle counters.
- The existing `closeNtpService` remains a compatibility wrapper over the structured API.
- The live verifier starts one bootstrap request, queues three same-peer replies without polling, and closes the active service.
- Close cancels the request, discards all three packets, unregisters the connected generation-tagged socket, and leaves service/client/request inactive.
- Stale status, receive, poll, and retry operations reject; structured and boolean duplicate closes reject without state mutation.
- Inactive health preserves `pre_request_discards = 4`, `post_response_discards = 3`, and lifecycle counts.
- HPET and ACPI PM timer boots verify one transmission, exact close queue statistics, no residual endpoint, and exact completion/ingress/dispatch accounting.


## 4.07 - Track close-time NTP discards independently

- `NtpService`, `NtpServiceHealth`, and `NtpServiceCloseResult` expose cumulative `close_discards` separately from pre-request and post-response purges.
- Structured close adds the exact UDP discard count with saturating arithmetic before marking the service inactive.
- The live verifier synchronizes once and accepts a valid response while post-purging two residual datagrams.
- Two later stale datagrams are queued while the synchronized service is idle.
- Idle close requires no request cancellation, discards both packets, and yields independent totals `pre/post/close = 0/2/2`.
- The synchronized projected clock remains readable and unchanged after transport shutdown.
- Inactive health preserves all three discard counters and the accepted lifecycle counts; duplicate close rejects without mutation.
- HPET and ACPI PM timer boots verify one transmission, queue totals five/five with high-water three, and exact final accounting.


## 4.08 - Saturate all NTP discard counters

- All five production discard update sites now use one `recordNtpServiceDiscards` helper.
- The helper applies saturating addition to pre-request, post-response, and close-time counters.
- A pure verifier covers zero additions, normal additions, near-maximum overflow, already-maximum preservation, and three independent totals.
- Near-maximum and already-maximum counters remain pinned at `18446744073709551615` instead of wrapping.
- HPET and ACPI PM timer full boots retain every live purge/close verifier while asserting the shared saturation marker.

## 4.09 - Verify live saturation across every NTP discard boundary

- A single service seeds pre-request, post-response, and close-time discard totals at `18446744073709551614`.
- Two stale packets before the bootstrap request drive only the pre-request counter to `18446744073709551615`.
- One accepted response plus two residual packets drives only the post-response counter to the same maximum.
- Two later idle packets are discarded by structured close and drive only the close-time counter to the maximum.
- The endpoint queue closes at seven enqueues and seven dequeues with high-water three and zero drops.
- Synchronized health before close and inactive health afterward preserve the independent saturated totals and lifecycle counts.
- The projected clock survives transport shutdown; duplicate close rejects without mutation.
- HPET and ACPI PM timer boots verify one transmission and exact completion, endpoint, ingress, and dispatch accounting.

## 4.10 - Verify atomic NTP close preflight after transport loss

- The structured close path preflights service, client, and generation-tagged UDP socket activity before cancelling an active request.
- The live verifier starts one bootstrap request and queues two same-peer replies.
- The underlying UDP socket is then externally discard-closed, removing both packets and invalidating the endpoint while leaving the service object untouched.
- Structured and boolean service close both reject before mutating service, client, request, clock, or diagnostics.
- The active request remains uncancelled; stale socket status, poll, and retry operations reject safely.
- Health continues to expose the preserved unsynchronized awaiting request, discard totals, and lifecycle counts.
- HPET and ACPI PM timer boots verify one transmission, two routed packets, no residual endpoint, and exact final accounting.

## 4.11 - Abandon an NTP service after irrecoverable transport loss

- `abandonNtpServiceAfterTransportLoss` rejects while the generation-tagged UDP socket is still active.
- After external socket loss, it returns a structured result with request, socket, discard, and lifecycle diagnostics.
- An active request is cancelled exactly once; service, client, and request-active state become inactive while clock and cumulative counters are preserved.
- The live verifier queues two replies, externally discard-closes the socket, and abandons the preserved service.
- Duplicate abandonment and normal close reject without mutation; stale status, poll, and retry operations remain safe.
- Inactive health retains discard totals `6/7/8` and one started request with no response.
- HPET and ACPI PM timer boots verify one transmission, two routed packets, no residual endpoint, and exact final accounting.

## 4.12 - Reopen abandoned NTP transport transactionally

- `reopenNtpServiceAfterTransportLoss` validates retained quality, rejection, step, retry, recovery, source-pool, source-index, and clock-tick invariants before allocating transport.
- The replacement `NtpClient` is opened and connected before any service field is mutated.
- Reopen preserves the synchronized projected clock, source pool and rotation policy, selected source, discard totals, lifecycle totals, limit counters, recovery successes, and rotation history.
- Per-request retry, rejection, timeout, recovery, pending-source, and consecutive-failure state is cleared, and an immediate refresh deadline is installed at the supplied tick.
- The live verifier synchronizes on source zero, seeds cumulative diagnostics and dirty recovery transients, externally invalidates the old socket, abandons the idle service, and reopens on socket generation 91 / port 49232.
- Duplicate reopen while active rejects without service or device mutation.
- The new socket emits a projected refresh timestamp, accepts a source-zero response, and returns synchronized health with all cumulative diagnostics retained.
- HPET and 24-bit ACPI PM timer boots verify two transmissions, two accepted samples, clean close, and exact final completion, endpoint, ingress, and dispatch accounting.

## 4.13 - Replace an active refresh transaction after transport loss

- A source-pool service synchronizes once, starts a projected refresh, and then loses transport while that refresh request is active.
- One valid-looking delayed response remains queued on the old socket and is reported/discarded by external transport close.
- Structured abandonment cancels the active refresh exactly once and preserves its old originate timestamp for diagnostics.
- Transactional reopen creates a new generation-tagged socket, preserves the synchronized clock, source selection, policies, discard totals, limit counters, recovery successes, rotation history, and accepted lifecycle totals, while clearing request transients.
- The immediate replacement refresh uses a strictly newer projected originate timestamp rather than retrying or reusing the cancelled request.
- On the new socket, a same-peer response carrying the cancelled request's originate timestamp is consumed and rejected before the valid replacement response is accepted in the same bounded two-packet poll.
- No retry transmission, quality rejection, clock-step rejection, or extra sample occurs.
- HPET and 24-bit ACPI PM timer boots verify three transmissions, `resolved/2/1` mixed-response accounting, synchronized health, clean close, and exact final completion, endpoint, ingress, and dispatch counters.

## 4.14 - Keep NTP transport reopen atomic under endpoint exhaustion

- An unsynchronized service is externally detached and abandoned with seeded cumulative discard, lifecycle, limit, recovery, quality, and clock-step diagnostics.
- Two fixed-port filler sockets occupy the only free UDP endpoint slots, saturating the four-entry endpoint table without changing the ephemeral-port cursor.
- `reopenNtpServiceAfterTransportLoss` fails before service mutation when replacement socket allocation is impossible.
- The failed attempt preserves the full service value, endpoint count, filler handles, ready cursor, ephemeral cursor `49236`, generation cursor `97`, identification cursor, TX cursor, and submission count.
- Releasing both fillers restores capacity without rewinding generation history.
- A second reopen succeeds on socket slot/generation/port `2/97/49236`, proving the failed attempt consumed neither an ephemeral port nor a generation.
- The reopened service starts a bootstrap request, accepts one response, exposes synchronized health with all seeded cumulative diagnostics retained, and closes cleanly.
- HPET and 24-bit ACPI PM timer boots verify one transmission and exact final completion, endpoint, cursor, ingress, and dispatch accounting.

## 4.15 - Reject invalid NTP transport reopen state before allocation

- A two-source service synchronizes on source zero, loses its old transport, and is abandoned with the synchronized clock and accepted lifecycle retained.
- Four independent invalid reopen attempts cover a tick before the clock anchor, a retained client-server mismatch, an invalid zero-retry policy, and an invalid zero-threshold source-rotation policy.
- Each call returns null while preserving the exact deliberately-invalid service snapshot supplied to it.
- Restoring the valid service after each attempt yields the original abandoned value, and all failures preserve endpoint count, ready cursor, ephemeral cursor `49238`, generation cursor `99`, identification cursor, TX cursor, and submission count.
- A subsequent valid reopen uses socket slot/generation/port `2/99/49238`, proving no failed validation consumed transport identity.
- The reopened synchronized service emits an immediate projected refresh, accepts a source-zero response, reports synchronized source-pool health, and closes cleanly.
- HPET and 24-bit ACPI PM timer boots verify two transmissions, two accepted samples, and exact final completion, endpoint, cursor, ingress, and dispatch accounting.

## 4.16 - Expose typed NTP transport reopen outcomes

- `NtpServiceTransportReopenError` names inactive-state, live-transport, retained-policy, clock-order, source-pool, source-selection, server, and transport-availability rejection reasons.
- `NtpServiceTransportReopenAttempt` contains exactly one successful reopen result or one rejection reason.
- `reopenNtpServiceAfterTransportLossDetailed` performs the full ordered preflight, opens transport only after validation succeeds, and returns `transport_unavailable` when replacement client allocation cannot complete.
- The existing nullable `reopenNtpServiceAfterTransportLoss` remains a source-compatible wrapper over the detailed result.
- The endpoint-exhaustion verifier now requires the typed reason `transport_unavailable` while retaining its exact state and cursor atomicity proof.
- The validation verifier now requires `backward_refresh_tick`, `retained_server_mismatch`, `invalid_retry_policy`, and `invalid_source_rotation_policy` for its four independent failures.
- Successful detailed attempts are required to have no rejection reason before their result is consumed.
- HPET and 24-bit ACPI PM timer boots retain the exact 4.14 and 4.15 packet, clock, endpoint, completion, ingress, and dispatch accounting while asserting the typed reason names.

## 4.17 - Exhaust every reachable NTP reopen preflight reason

- The detailed reopen taxonomy removes the unreachable `source_lookup_failed` branch; a validated pool and in-range source index make lookup deterministic.
- A packet-free matrix verifies four lifecycle reasons: `service_active`, `client_active`, `request_active`, and `transport_still_active`.
- Eight policy/clock reasons are verified: invalid refresh interval, quality policy, quality-rejection policy, clock-step policy, step-rejection policy, retry policy, recovery policy, and backward refresh tick.
- Nine source/server reasons are verified: missing rotation policy, invalid source pool, invalid rotation policy, source-count mismatch, out-of-range source index, retained-server mismatch, unexpected rotation policy, unexpected source index, and invalid server.
- Every candidate retains its exact deliberately-invalid service snapshot and preserves endpoint count, readiness cursor, ephemeral port, generation, IP identification, TX cursor, and submission count.
- After all 21 failures, a valid detailed reopen succeeds on socket `2/101/49240` with no rejection reason.
- The nullable compatibility wrapper rejects the now-active service without mutation, and structured close removes the replacement socket cleanly.
- Full HPET and 24-bit ACPI PM timer boots verify zero transmissions and unchanged completion, ingress, and dispatch totals while endpoint identity advances exactly to cursor/generation `49241/102`.

## 4.18 - Inspect NTP transport reopen readiness without allocation

- `NtpServiceTransportReopenPreflight` records the prior socket, validated target server, selected source index, synchronized-clock flag, and requested refresh deadline.
- `NtpServiceTransportReopenInspection` contains either that immutable preflight record or one typed rejection reason.
- `inspectNtpServiceTransportReopen` performs the complete ordered lifecycle, policy, clock, source-pool, source-selection, and server validation without opening a socket or mutating service/device state.
- `reopenNtpServiceAfterTransportLossDetailed` now delegates all validation to inspection and only performs replacement-client allocation after a successful preflight.
- The packet-free reason matrix verifies a ready inspection targets the retained server and prior socket while preserving both service and device state.
- The later detailed result must exactly match the inspected prior socket, target server, source index, clock state, and refresh tick.
- The 21 typed rejection reasons, nullable compatibility wrapper, exact socket identities, and zero-traffic accounting remain unchanged.
- Full HPET and 24-bit ACPI PM timer boots validate the refactor through the complete regression harness.

## 4.19 - Execute inspected NTP reopen plans only while fresh

- `NtpServiceTransportReopenPreflight` now carries the exact abandoned `NtpService` snapshot plus an endpoint-allocation snapshot covering active slots, ports, generations, endpoint count, ephemeral cursor, generation cursor, and gateway MAC.
- `executeNtpServiceTransportReopenPreflight` rejects `stale_service_state` before transport inspection when the supplied service no longer matches the inspected snapshot.
- It then rejects `stale_transport_state` when endpoint allocation identity changed after inspection, before `openNtpClient` can allocate a replacement socket.
- `reopenNtpServiceAfterTransportLossDetailed` remains compatible by performing inspection and immediate execution through the new two-phase API.
- The packet-free verifier mutates one cumulative service diagnostic and proves stale-service rejection with exact service/device preservation, then restores the inspected service.
- A real fixed-port socket opens at `2/101/55003` and closes, advancing only UDP generation state; executing the old plan then returns `stale_transport_state` without mutation.
- Fresh reinspection executes successfully on `2/102/49240`, exactly matches the inspected target, and advances final endpoint identity to cursor/generation `49241/103`.
- Reusing the consumed plan returns `stale_service_state`, while the nullable compatibility wrapper still rejects the active service through normal preflight validation.
- Full HPET and 24-bit ACPI PM timer boots retain IP/TX `166/1`, completions `193/193/22`, ingress/dispatch `211/211/199/198`, and zero transmission movement.

## 4.20 - Reject altered NTP reopen plans before state checks

- `NtpServiceTransportReopenPreflight` now carries a canonical FNV-1a64 integrity tag with a versioned domain separator.
- The tag is encoded field-by-field rather than from raw struct memory, avoiding padding, alignment, and host-endianness dependence.
- It covers the prior socket, target server, source index, clock flag, refresh deadline, every `NtpService` policy/transient/cumulative field, and the complete endpoint-allocation snapshot.
- `executeNtpServiceTransportReopenPreflight` validates the tag before stale-service or stale-transport classification and returns `invalid_preflight_plan` without allocation or mutation on mismatch.
- After freshness checks, execution performs a fresh inspection and requires the reconstructed plan to equal the supplied plan before opening transport.
- A packet-free verifier alters the tag, prior socket, server, source index, clock flag, deadline, service snapshot, and transport snapshot independently; all eight copies return `invalid_preflight_plan` with exact service/device preservation.
- The untouched plan executes on socket `2/104/49242`, matches its inspected metadata, and the consumed original still returns `stale_service_state` without mutation.
- Structured close leaves endpoints/cursor/generation `2/49243/105` while IP/TX `166/1`, completions `193/193/22`, and ingress/dispatch `211/211/199/198` remain unchanged.
- Full HPET and 24-bit ACPI PM timer boots validate the integrity implementation through the complete regression harness.

## 4.21 - Inspect NTP reopen plan integrity independently of freshness

- `NtpServiceTransportReopenPlanIntegrityInspection` reports the stored tag, canonically recomputed tag, and validity without requiring a device or service pointer.
- `inspectNtpServiceTransportReopenPlanIntegrity` is pure: it performs no allocation and cannot mutate the plan, service, or device.
- `executeNtpServiceTransportReopenPreflight` now delegates its first gate to this public inspection function before freshness validation.
- A packet-free verifier creates an abandoned plan on socket `2/105/49243` and proves its actual and expected tags are equal and nonzero.
- Independent tag, deadline, service-snapshot, and transport-snapshot modifications all inspect invalid with differing actual/expected tags while the exact runtime state remains unchanged.
- The original plan then executes on `2/106/49244` and exactly matches its inspected metadata.
- After execution, the unchanged consumed plan still inspects integrity-valid, while execution rejects it as `stale_service_state`; this explicitly separates byte integrity from lifecycle freshness.
- Structured close leaves endpoints/cursor/generation `2/49245/107` while IP/TX `166/1`, completions `193/193/22`, and ingress/dispatch `211/211/199/198` remain unchanged.
- Full HPET and 24-bit ACPI PM timer boots validate the pure inspection API and complete regression harness.

## 4.22 - Inspect NTP reopen plan freshness before allocation

- `NtpServiceTransportReopenPreflightFreshnessInspection` exposes the integrity result, service-snapshot match, transport-allocation match, canonical reinspection match, ready state, and exact rejection reason.
- `inspectNtpServiceTransportReopenPreflightFreshness` is non-allocating and preserves the supplied service, device endpoint state, readiness cursor, packet cursors, and submission totals.
- The ordered gates return `invalid_preflight_plan` before state comparison, `stale_service_state` before transport inspection, and `stale_transport_state` before canonical reinspection.
- A ready result requires all four gates: integrity, service, transport, and canonical reconstruction.
- `executeNtpServiceTransportReopenPreflight` now delegates every pre-allocation check to the public freshness inspector and opens replacement transport only after it reports ready.
- A packet-free verifier creates a plan on `2/107/49245`, proves the initial four-gate result ready, then independently verifies altered-tag, changed-service, and endpoint-churn rejection with exact state preservation.
- Real fixed-port churn opens and closes `2/108/55004`; fresh reinspection then executes on `2/109/49246` and advances endpoint cursor/generation to `49247/110`.
- The consumed plan remains integrity-valid but freshness-rejects as `stale_service_state`, preserving the distinction established in 4.21.
- Full HPET and 24-bit ACPI PM timer boots retain IP/TX `166/1`, completions `193/193/22`, ingress/dispatch `211/211/199/198`, and zero transmission movement.

## 4.23 - Preview exact NTP reopen transport allocation

- `UdpEphemeralSocketAllocationPreview` records the exact first free endpoint slot, normalized generation, selected ephemeral port, and post-allocation cursors without mutating the device.
- `previewEphemeralUdpSocketAllocation` and the internal plan consumer now share the complete ephemeral allocation decision; ordinary `openEphemeralUdpSocket` uses that same path.
- `NtpServiceTransportReopenExecutionPreview` combines 4.22 freshness with transport availability, an exact predicted socket, readiness, and a typed rejection.
- `previewNtpServiceTransportReopenExecution` returns freshness failures unchanged, returns `transport_unavailable` when no endpoint can be allocated, and remains non-mutating.
- `executeNtpServiceTransportReopenPreflight` delegates to the execution preview and consumes the same allocation plan, requiring the opened NTP socket to match the prediction exactly.
- A packet-free verifier abandons `2/110/49247`, fills the remaining slots with `2/111/55005` and `3/112/55006`, and proves both preview and execution reject `transport_unavailable` without cursor or service mutation.
- Releasing the fillers makes the saturated plan reject `stale_transport_state`; fresh reinspection predicts `2/113/49248`, and execution opens exactly that socket.
- Structured close leaves endpoint cursor/generation `49249/114`, while IP/TX `166/1`, completions `193/193/22`, and ingress/dispatch `211/211/199/198` remain unchanged.
- Full HPET and 24-bit ACPI PM timer boots validate exact preview/allocation parity through the complete regression harness.

## 4.24 - Consume tagged NTP reopen execution previews

- A ready `NtpServiceTransportReopenExecutionPreview` now contains an `NtpServiceTransportReopenExecutionPlan` with the protected preflight, exact ephemeral allocation, and a canonical FNV-1a64 tag.
- `inspectNtpServiceTransportReopenExecutionPlanIntegrity` independently reports stored/expected tags, preflight integrity, allocation agreement with the captured transport snapshot, and overall validity.
- `executeNtpServiceTransportReopenExecutionPreview` rejects altered plans as `invalid_execution_preview` before freshness or allocation checks.
- Integrity-valid plans whose service or endpoint-allocation state changed reject as `stale_execution_preview` before socket allocation.
- The source-compatible preflight executor now obtains a ready preview and delegates mutation to the explicit plan consumer while retaining its original typed preflight rejection reasons.
- A packet-free verifier creates an initial plan predicting `2/115/49250`; independent allocation and tag alterations both reject invalid with exact state preservation.
- Real fixed-port churn opens and closes `2/115/55007`, leaving the original plan byte-valid but runtime-stale.
- Fresh reinspection produces a new tagged plan predicting `2/116/49250`; explicit consumption opens exactly that socket, while reuse and the compatibility wrapper both reject `stale_service_state` without mutation.
- Structured close leaves endpoint cursor/generation `49251/117`, while IP/TX `166/1`, completions `193/193/22`, and ingress/dispatch `211/211/199/198` remain unchanged.
- Full HPET and 24-bit ACPI PM timer boots validate tagged preview consumption through the complete regression harness.

## 4.25 - Inspect NTP reopen execution-plan consumability

- `NtpServiceTransportReopenExecutionPlanInspection` combines canonical plan integrity, optional preflight freshness, current allocation agreement, consumability, the public rejection, and an underlying stale cause.
- `inspectNtpServiceTransportReopenExecutionPlan` is pure and short-circuits invalid plan bytes before service/device freshness inspection.
- Integrity-valid stale plans return public `stale_execution_preview` while retaining the precise cause such as `stale_service_state` or `stale_transport_state`.
- `executeNtpServiceTransportReopenExecutionPreview` now delegates every pre-allocation check to the public inspector, ensuring inspection and mutation paths share one decision.
- A packet-free verifier abandons `2/117/49251` and proves the initial plan predicting `2/118/49252` is consumable without changing service, allocation, readiness, packet, or submission state.
- A modified plan tag inspects and executes as `invalid_execution_preview` with no freshness result or stale cause.
- Mutating the abandoned service reports `stale_execution_preview/stale_service_state`; real fixed-port churn through `2/118/55008` reports `stale_execution_preview/stale_transport_state`.
- Fresh reinspection predicts and opens `2/119/49252`; inspection of the consumed plan remains integrity-valid but reports `stale_execution_preview/stale_service_state`, matching execution.
- Structured close leaves endpoint cursor/generation `49253/120`, while IP/TX `166/1`, completions `193/193/22`, and ingress/dispatch `211/211/199/198` remain unchanged.
- Full HPET and 24-bit ACPI PM timer boots validate pure inspection/execution agreement through the complete regression harness.

## 4.26 - Refresh stale NTP reopen execution plans without mutation

- `NtpServiceTransportReopenExecutionPlanRefresh` records the original 4.25 inspection, an optional refreshed preview, reuse/refreshed flags, and an exact rejection.
- `refreshNtpServiceTransportReopenExecutionPlan` is pure: invalid plan bytes reject `invalid_execution_preview`, consumable plans are returned unchanged, and integrity-valid stale plans are rebuilt from current service and allocation state.
- Refresh retains the original deadline while rerunning complete service validation, preflight capture, transport preview, canonical tagging, and exact socket prediction.
- A packet-free verifier abandons `2/120/49253`; its initial plan predicts `2/121/49254` and refresh returns the same tagged plan byte-for-byte.
- A modified tag remains unrefreshable and produces no preview.
- Incrementing retained close-discard diagnostics makes the original plan stale by service snapshot; refresh updates that snapshot and tag while preserving the same predicted socket.
- Real fixed-port churn opens and closes `2/121/55009`; refreshing the service-updated plan then predicts `2/122/49254` with a new tag and no runtime mutation.
- Explicit consumption opens exactly `2/122/49254`; refreshing the consumed plan reports original cause `stale_service_state` and current lifecycle rejection `service_active`.
- Structured close leaves endpoint cursor/generation `49255/123`, while IP/TX `166/1`, completions `193/193/22`, and ingress/dispatch `211/211/199/198` remain unchanged.
- Full HPET and 24-bit ACPI PM timer boots validate pure plan refresh/reissue through the complete regression harness.

## 4.27 - Refresh NTP reopen plans at an explicit deadline

- `refreshNtpServiceTransportReopenExecutionPlanAt` accepts a caller-selected refresh tick while retaining the 4.26 integrity, freshness, allocation, and purity guarantees.
- The existing refresh API remains source-compatible and delegates using the plan's retained deadline.
- A consumable plan refreshed at its existing deadline is returned byte-for-byte; a different deadline reruns complete current-service preflight validation and canonical retagging.
- A packet-free verifier abandons `2/123/49255`, seeds a synchronized clock anchored at tick `175`, and creates a deadline-`180` plan predicting `2/124/49256`.
- Same-tick refresh reuses the plan, while tick `174` rejects `backward_refresh_tick` without a preview or mutation.
- Forward tick `185` produces a new tag and deadline while preserving the synchronized clock and exact predicted socket.
- Real fixed-port churn opens and closes `2/124/55010`; refreshing at tick `190` reports original cause `stale_transport_state` and predicts `2/125/49256`.
- Explicit consumption opens exactly that socket with synchronized clock state retained; a later tick-`195` refresh on the active service rejects `service_active`.
- Structured close leaves endpoint cursor/generation `49257/126`, while IP/TX `166/1`, completions `193/193/22`, and ingress/dispatch `211/211/199/198` remain unchanged.
- Full HPET and 24-bit ACPI PM timer boots validate explicit-deadline refresh through the complete regression harness.

## 4.28 - Refresh and execute NTP reopen plans transactionally

- `NtpServiceTransportReopenRefreshExecutionAttempt` contains the complete pure refresh result, an optional reopen result, and the final typed rejection.
- `refreshAndExecuteNtpServiceTransportReopenExecutionPlanAt` performs no execution when refresh rejects; only a ready refreshed preview is passed to the exact tagged-plan consumer.
- The source-compatible no-deadline wrapper delegates using the retained plan deadline.
- A packet-free verifier abandons `2/126/49257` and creates a deadline-`211` plan predicting `2/127/49258`.
- A corrupted plan at tick `212` returns `invalid_execution_preview` with neither refreshed preview nor reopen result and no state mutation.
- Fixed-port fillers `2/127/55011` and `3/128/55012` saturate the endpoint table; a tick-`215` combined attempt reports original cause `stale_transport_state`, rejects `transport_unavailable`, and never executes.
- Releasing both fillers leaves generation `129`; a tick-`220` combined attempt refreshes and opens exactly `2/129/49258` in one transaction.
- Reusing that refreshed plan at tick `225` reports original cause `stale_service_state`, rejects `service_active`, and preserves the active service.
- Structured close leaves endpoint cursor/generation `49259/130`, while IP/TX `166/1`, completions `193/193/22`, and ingress/dispatch `211/211/199/198` remain unchanged.
- Full HPET and 24-bit ACPI PM timer boots validate transactional refresh/execute behavior through the complete regression harness.

## 4.29 - Reject invalid NTP reopen peers before allocation

- `invalid_transport_peer` distinguishes a valid service/preflight whose gateway MAC, server IPv4, or NTP port cannot form a usable connected UDP peer.
- NTP peer construction is centralized and shared by preflight inspection and actual client opening.
- Preflight inspection preserves `invalid_server` for a zero target address and returns `invalid_transport_peer` when a nonzero server cannot form a usable gateway-backed NTP peer.
- The peer rejection occurs before a preflight record exists; refresh and transactional refresh-execute inherit the same typed rejection and produce neither a tagged plan nor a reopen result.
- A packet-free verifier abandons `2/130/49259` and first creates a valid plan predicting `2/131/49260`.
- Zeroing the gateway MAC makes direct preflight inspection reject `invalid_transport_peer` with no preflight record and no state mutation.
- Transactional refresh at tick `235` reports original cause `stale_transport_state`, propagates `invalid_transport_peer`, and preserves service/device state.
- Fixed-port churn opens and closes `2/131/55013`; restoring the gateway then yields a fresh plan predicting and opening exactly `2/132/49260`.
- Active reuse reports original cause `stale_service_state` and rejects `service_active`; structured close leaves endpoint cursor/generation `49261/133`.
- IP/TX `166/1`, completions `193/193/22`, and ingress/dispatch `211/211/199/198` remain unchanged on full HPET and 24-bit ACPI PM timer boots.

## 4.30 - Protect NTP reopen execution peers

- `NtpServiceTransportReopenExecutionPlan` now embeds the exact connected UDP peer selected from the validated preflight transport snapshot and target server.
- The execution-plan integrity tag domain advances to v2 and covers peer MAC, IPv4, and port alongside the preflight tag and exact ephemeral allocation.
- `inspectNtpServiceTransportReopenExecutionPlanIntegrity` independently verifies the stored peer against the canonical gateway/server/NTP-port peer derived from the preflight snapshot.
- Execution consumes the protected peer directly instead of reconstructing it from mutable device state after inspection.
- A packet-free verifier abandons `2/133/49261`, previews exact replacement `2/134/49262`, and proves preview purity with all initial integrity dimensions valid.
- Independently forged MAC, server, and port plans are re-tagged correctly; their tags match, but canonical peer agreement remains false and execution rejects `invalid_execution_preview` without allocation or mutation.
- The valid plan opens exactly `2/134/49262`, binds the exact protected peer, preserves client/result server identity, and rejects consumed reuse as `stale_execution_preview` while byte integrity remains valid.
- Structured close leaves endpoint cursor/generation `49263/135`, while IP/TX `166/1`, completions `193/193/22`, and ingress/dispatch `211/211/199/198` remain unchanged.
- Full HPET and 24-bit ACPI PM timer boots validate protected peer integrity and exact binding through the complete regression harness.

## 4.31 - Add a native TCP transport foundation

- Added `src/tcp.zig` with bounded Ethernet II, IPv4, and TCP frame construction and parsing for TCP protocol number 6.
- The builder supports 20-60 byte TCP headers, aligned options, payloads, all nine control flags, urgent-pointer validation, minimum Ethernet padding, IPv4 checksums, and TCP pseudo-header checksums.
- The parser rejects invalid MAC/IP/port selectors, malformed IPv4 lengths or fragments, bad IPv4/TCP checksums, illegal TCP data offsets, reserved bits, and inconsistent urgent pointers before exposing options or payload.
- e1000e packet classification now routes valid TCP frames into a dedicated bounded queue, tracks TCP dispatches independently, and counts malformed TCP drops without affecting UDP endpoint state.
- `sendTcpSegment` provides transactional TCP transmission: it builds and self-validates the exact frame, submits through the real DMA TX ring, and advances a dedicated IPv4 identification cursor only after completion.
- The deterministic verifier builds a 32-byte SYN with MSS, window-scale, SACK-permitted, and NOP options; rejects zero-port, unaligned-option, urgent-pointer, checksum, fragment, offset, and reserved-bit cases; and routes a synthetic SYN-ACK through the shared software dispatcher.
- A real `50000 -> 443` SYN leaves descriptor `1`, advances TX cursor `1 -> 2` and TCP identification `0x7200 -> 0x7201`, and receives a checksum-valid 60-byte RST-ACK through RX descriptor `6 -> 7` from `192.0.2.1:443` with acknowledgement `0x13579BE0`.
- The live reply is parsed as `RST|ACK`, released back to hardware, and leaves balanced completion ownership `TX 194/194`, `RX 23/23`, ingress `213/213`, dispatch `200/1/198` for total/TCP/UDP, and unchanged UDP endpoint cursor/generation `2/49263/135`.
- Full HPET and 24-bit ACPI PM timer boots validate the TCP codec, dispatch path, DMA transmission, live hardware response, descriptor recycling, and complete regression harness.

## 4.32 - Add a native TCP active-open state machine

- Added `src/tcp_connection.zig` with an explicit TCP control block, connection states, typed transition actions, typed rejection causes, outbound control-segment descriptions, and wrap-safe 32-bit sequence comparisons.
- Active open moves atomically from `closed` to `syn_sent`, records ISS/SND.UNA/SND.NXT, and emits an exact SYN description without touching the NIC or UDP state.
- SYN-SENT handling accepts only a matching SYN-ACK or RST-ACK, rejects wrong acknowledgements, unsupported simultaneous open, malformed flag combinations, and duplicate active opens without mutating the control block.
- A valid synthetic SYN-ACK advances SND.UNA, captures the peer window, sets RCV.NXT to peer sequence plus one, enters `established`, and emits the exact final ACK.
- Established-state reset handling requires the exact next receive sequence; duplicate SYN and wrong-sequence RST inputs are rejected with byte-for-byte state preservation.
- The live `192.0.2.1:443` RST-ACK captured by milestone 4.31 is consumed by a fresh active-open control block and transitions deterministically to `reset` with the expected acknowledgement.
- Wraparound checks prove ordering across `0xFFFF_FFF0 -> 0x0000_0010`, including inclusive window membership through sequence zero.
- The verifier is packet-free after the 4.31 exchange and preserves completions `194/194/23/23`, ingress `213/213`, dispatch `200/1/198`, TX/RX `2/7`, TCP ID `0x7201`, and UDP endpoint cursor/generation `2/49263/135`.
- Full HPET and 24-bit ACPI PM timer boots validate the state machine and live RST transition through the complete regression harness.

## 4.33 - Add bounded TCP SYN retransmission

- `RetransmissionPolicy` validates a nonzero initial timeout, a cap at least as large as the initial timeout, and a nonzero retry budget before active-open state can change.
- `beginActiveOpenAt` arms a monotonic SYN timer while preserving the source-compatible untimed active-open API.
- `onTimer` rejects backward ticks, reports pre-deadline no-ops without mutation, retransmits the exact original SYN at the deadline, and records typed timer actions and reasons.
- Retry intervals follow capped exponential backoff `3 -> 6 -> 10 -> 10`; exact retransmission ticks `103/109/119` produce next deadlines `109/119/129` with counts `1/2/3`.
- At tick `129`, the exhausted retry budget transitions atomically from `syn_sent` to `timed_out`, stops the timer, and emits no additional segment.
- Matching SYN-ACK establishment and live RST-ACK reset both cancel the timer; later timer calls are rejected as invalid for their terminal states.
- Deadline addition and interval doubling saturate at `u64` maximum; an open starting at `18446744073709551613` with timeout `5` clamps to `18446744073709551615`.
- Invalid-policy, backward-tick, and early-tick paths preserve the complete control block byte-for-byte.
- The verifier remains packet-free and preserves completions `194/194/23/23`, ingress `213/213`, dispatch `200/1/198`, TX/RX `2/7`, TCP ID `0x7201`, and UDP endpoint cursor/generation `2/49263/135`.
- Full HPET and 24-bit ACPI PM timer boots validate retransmission timing and cancellation through the complete regression harness.

## 4.34 - Add TCP receive sequencing and graceful close

- Established connections now consume only the exact next receive sequence, advance RCV.NXT by payload length, account received bytes, update the peer window, and emit a cumulative ACK.
- Duplicate payload and future out-of-order payload produce exact current acknowledgements without mutating the control block; their typed causes are `duplicate_segment` and `unexpected_sequence`.
- Payload larger than the advertised receive window is rejected as `segment_outside_window` before any sequence, byte, window, or lifecycle state changes.
- A peer payload-plus-FIN advances RCV.NXT by payload plus one, records the FIN, enters `close_wait`, and emits the exact ACK.
- Passive application close emits `FIN|ACK`, enters `last_ack`, advances SND.NXT by one, and reaches `closed` only after the matching final ACK.
- Active close emits `FIN|ACK`, enters `fin_wait_1`, rejects a wrong FIN acknowledgement without mutation, advances through `fin_wait_2`, and enters `time_wait` after the peer FIN.
- Duplicate FIN in TIME-WAIT is acknowledged again without changing sequence or lifecycle state; explicit TIME-WAIT expiry then transitions to `closed`.
- A combined peer `FIN|ACK` in `fin_wait_1` implements simultaneous close directly into TIME-WAIT, while synchronized RST handling remains valid from established state.
- Deterministic values cover payload RCV.NXT `0x2468ACE1 -> 0x2468ACE6`, passive FIN RCV.NXT `0x2468ACEA`, local FIN SND.NXT `0x13579BE0 -> 0x13579BE1`, and active peer-FIN acknowledgement `0x2468ACE2`.
- The verifier remains packet-free and preserves completions `194/194/23/23`, ingress `213/213`, dispatch `200/1/198`, TX/RX `2/7`, TCP ID `0x7201`, and UDP endpoint cursor/generation `2/49263/135`.
- Full HPET and 24-bit ACPI PM timer boots validate receive and close semantics through the complete regression harness.

## 4.35 - Add a dual-target i686 build foundation

- Added a separate `src/legacy/i686` architecture path without weakening or conditionally compiling the existing x86-64 UEFI kernel.
- Canonical Zig now links `kernel.zig` plus a NASM ELF32 entry object for `x86-freestanding-none` with the explicit `i686` CPU baseline.
- The dedicated linker script fixes the kernel entry and load contract at physical address `0x00010000`, leaving low conventional memory available for BIOS data, loader state, and the protected-mode stack.
- `zig objcopy` extracts a raw kernel payload from the ELF32 executable without introducing GCC, binutils, or another linker dependency.
- `verify-legacy-i686.ps1` validates ELF magic, 32-bit class, little-endian encoding, executable type, Intel 80386 machine ID, exact entry address, nonempty payload, initial 127-sector size ceiling, and SHA-256.
- The first verified outputs are a 4,780-byte ELF32 image and a 280-byte raw payload with SHA-256 `F4BC910D57E6B942C1D41B9EB5FDB304148A5DAF66D5443279A7B65CC8F47683`.
- The existing AMD64 PE32+ UEFI image remains 888,832 bytes with SHA-256 `ABA23A4C97F504146B1633D846A3F5A46242BC6360CDE9DDA8909A98941F45C2`.
- GitHub Actions builds and uploads both architecture outputs, establishing the compatibility matrix required for subsequent BIOS boot milestones.

## 4.36 - Boot a verified BIOS stage-0 sector

- Added a flat 16-bit boot sector assembled at the PC BIOS load address `0x00007C00` and constrained to exactly 512 bytes.
- Stage-0 establishes deterministic zero-based data/stack segments, captures the firmware-provided boot drive, and emits debugcon diagnostics without relying on UEFI services.
- The loader probes INT 13h Extensions with function `AH=41h`, verifies the returned `0xAA55` handshake and packet-interface capability bit, and reports the hard-disk drive number `0x80`.
- The final two sector bytes are verified as the mandatory little-endian `0x55AA` boot signature before image construction.
- The build creates a deterministic 1 MiB raw hard-disk image beginning byte-for-byte with the verified boot sector.
- `test-legacy-i686.ps1` boots the image with `qemu-system-i386`, captures port `0xE9`, handles debugcon flush after emulator shutdown, and requires exact stage-entry and EDD markers.
- QEMU reports `ZigOs BIOS stage0 verified: drive 0x80 EDD yes signature 0x55AA` through real legacy firmware execution.
- The verified stage-0 image SHA-256 is `85EA3880E9EBFBAE97541AD9FF4B7BCAF87A216240A3878AB31985D0C30F8F2E`; GitHub artifacts now include the sector and bootable image alongside ELF32 and raw kernel outputs.

## 4.37 - Load stage-1 and enter the Zig i686 kernel

- Stage-0 uses an INT 13h Extended Read disk-address packet to load eight sectors from LBA 1 to `0x00008000`.
- The build pads stage-1 to 4,096 bytes, computes the kernel sector count, and places the payload at LBA 9 and address `0x00010000`.
- Stage-1 enables A20, installs flat 4 GiB code/data descriptors, sets protected mode, and far-jumps with CS selector `0x0008`.
- Protected-mode entry installs data selector `0x0010`, an aligned stack at `0x0009F000`, and jumps to the canonical Zig entry.
- Image verification checks stage-0, stage-1, and kernel placement byte-for-byte before execution.
- QEMU requires exact markers for both BIOS stages, disk loading, protected-mode entry, and Zig kernel handoff.
- The complete image SHA-256 is `E97329FF8F98B6EDEA7C7AABE62358B883742A86898B72F7E08959296E7E0B4A`.

## 4.38 - Verify the freestanding i686 runtime and consoles

- The ELF32 entry stores the exact incoming stack, clears the complete linker-defined BSS range, and preserves cdecl nonvolatile registers around CPUID helpers.
- The Zig kernel verifies CPUID vendor `GenuineIntel`, maximum basic leaf `0x00000004`, CR0 value `0x00000011`, protected-mode enablement, stack `0x0009F000`, and 16-byte alignment.
- A 64-byte BSS probe proves zero initialization before mutation, covering the flat-binary runtime requirement that cannot be delegated to an executable loader.
- VGA text memory at `0x000B8000` is cleared and receives mirrored kernel output with deterministic cursor and newline handling.
- COM1 is initialized at 38,400 baud, 8N1, FIFO enabled; every kernel message is mirrored to debugcon, serial, and VGA.
- The QEMU harness captures both port `0xE9` and COM1 independently and requires the complete runtime invariant marker on both channels.
- The raw kernel is 1,172 bytes across three BIOS sectors with SHA-256 `6E23F8B09280245316628E2707ABF4ED21738FCC98C1E3DEBF22172C93EB7B49`.
- The complete disk image SHA-256 is `5C764C2E4ED7D49BBA6195CCE7C7B8B45EE28A4CD87F9EC9E44673D9C1655E3D`.

## 4.39 - Establish a BIOS E820 boot contract

- Stage-1 creates a versioned 32-byte boot-info structure at `0x00005000` and stores up to 64 firmware memory descriptors at `0x00005200`.
- INT 15h E820 collection validates the `SMAP` signature, accepts 20- or 24-byte records, preserves extended attributes when present, and refuses an empty map.
- The contract records entry size/count, map address, drive `0x80`, validity flags, kernel physical address, exact byte length, and generated sector count.
- The boot-info pointer is passed in ESI through the protected-mode jump and captured before BSS initialization by the ELF32 entry.
- Zig compile-time assertions protect the 32-byte boot-info and 24-byte E820 layouts; runtime checks validate every header field and the 64-entry bound.
- The kernel computes usable-region count, saturating usable-byte total, and the highest described physical boundary using 64-bit arithmetic on i686.
- The 32 MiB QEMU machine deterministically reports six entries, two usable regions, `0x0000000001F7FC00` usable bytes, and highest boundary `0x0000000100000000`.
- Both debugcon and COM1 must carry the exact memory-map statistics while allowing generated kernel byte/sector fields to evolve.
- The raw kernel is 2,472 bytes across five sectors with SHA-256 `07A70E65AD466A375DD9B5AF2B007C2100DFDAD71263B55761788132005484B5`; the disk image SHA-256 is `C52AB6C0CA7B1469F68C8E84E64E7CB98B2323FCD4B29D141C650BADA1E93826`.

## 4.40 - Deliver timer interrupts on legacy i686

- Added a full 256-entry i686 IDT with compile-time-protected eight-byte gate layout and an explicit six-byte little-endian `LIDT` descriptor that cannot acquire compiler padding.
- IRQ0 vector `0x20` uses a hand-written assembly gate that saves all general registers, aligns the interrupt stack for Zig, clears direction state, calls the exported timer handler, sends the master-PIC EOI, restores context, and returns with `IRETD`.
- The dual 8259 PIC is masked before reconfiguration, initialized in cascade mode, remapped to vectors `0x20/0x28`, and left with only master IRQ0 unmasked (`0xFE/0xFF`).
- PIT channel 0 is programmed in square-wave mode with divisor `0x2E9C` (11,932) for an approximately 100 Hz periodic source.
- The kernel enables interrupts only after IDT/PIC/PIT setup, sleeps with `HLT`, counts exactly five volatile IRQ deliveries, disables interrupts, and masks both PICs before reporting success.
- Debugcon and COM1 both require `IDT 0x00000100`, limit `0x000007FF`, IRQ0 `0x20`, PIC offsets, masks, PIT frequency/divisor, and tick count `0x00000005`.
- The final raw i686 kernel is 3,288 bytes across seven sectors with SHA-256 `AC9B4ED1EF3A1FA2E0DAC48A359C4727DD903073E5596CF8E5C60D05A2057CB3`.
- The final 1 MiB BIOS disk image SHA-256 is `E3A370A3EDCF287650AE53CB2E04F089FBC79EA9B33E320BEDEBA9EC1E0EF4E1`.
- GitHub Actions now installs QEMU and executes the complete BIOS stage-0, stage-1, protected-mode, Zig runtime, E820, and hardware-timer boot test in addition to building both architecture artifacts.


## 4.41 - Establish a recoverable i686 exception framework

- Added all 32 architectural CPU exception vectors to the legacy IDT while preserving the existing IRQ0 gate.
- NASM stubs normalize exceptions with and without processor-supplied error codes into one 52-byte trap-frame ABI.
- The common entry preserves all general registers, aligns the Zig call stack, clears direction state, and returns through `IRETD`.
- Zig compile-time checks protect the exact trap-frame layout and records vector, error code, and interrupted EIP.
- Breakpoint vector 3 is explicitly recoverable; two real `INT3` instructions cross the assembly/Zig boundary and resume execution.
- Unexpected exceptions emit vector, error code, and EIP before entering a nonreturning halt path.
- Debugcon and COM1 require the exact 32-vector, two-breakpoint, zero-error, nonzero-EIP success marker.
- The legacy raw payload grows to 4,232 bytes across nine sectors while stage-1 continues to inject exact byte and sector metadata automatically.


## 4.42 - Deliver PS/2 keyboard interrupts

- Added an IRQ1 assembly gate at IDT vector `0x21` with full register preservation, aligned Zig entry, master-PIC EOI, and `IRETD` return.
- Added exact byte input from the 8042 data/status ports while retaining the existing output helpers.
- The PIC leaves IRQ0 and IRQ1 unmasked during setup, then masks the timer while independently validating keyboard delivery.
- A bounded 8042 readiness loop issues controller command `0xD2` and places make code `0x1E` in the controller output buffer, causing the emulated hardware to assert IRQ1.
- The Zig handler counts IRQ delivery, distinguishes make from break codes, and records the last make code without polling the keyboard data path.
- The boot harness requires one make event, scan code `0x1E`, and nonzero IRQ accounting on both debugcon and COM1.
- The raw payload is 4,928 bytes across ten sectors, with stage-1 metadata again generated from the exact image.


## 4.43 - Own physical memory with an E820 frame allocator

- Added a 4 KiB physical-frame bitmap covering a bounded 64 MiB i686 management window.
- E820 usable ranges are clipped, page-aligned, and converted into free frames while non-usable and out-of-window ranges remain reserved.
- All physical memory below 1 MiB stays reserved for BIOS data, boot information, stage-1, kernel, VGA, and the protected-mode stack.
- Allocation scans deterministically from 1 MiB and returns `0x00100000`, `0x00101000`, and `0x00102000` for the first three frames.
- Freeing the middle frame and allocating again returns exactly `0x00101000`, proving bitmap reuse and lowest-frame ordering.
- Invalid, unaligned, low-memory, out-of-range, and double-free operations are rejected by the allocator API.
- The 32 MiB QEMU E820 map yields exactly `0x1EE0` managed free frames before and after the transactional test.
- A linker-provided kernel-end symbol confirms the complete loaded image and BSS remain below the reserved 1 MiB boundary.


## 4.44 - Activate allocator-backed i686 paging

- Added exact assembly helpers to read CR3, load a page directory, enable CR0.PG, serialize the transition, and invalidate individual translations.
- The frame allocator supplies one page directory, four identity page tables, one higher-half alias table, and one test frame.
- Four standard 4 KiB page tables identity-map the first 16 MiB so the existing kernel, VGA, stack, page structures, and early devices remain reachable after paging starts.
- Directory index 768 maps virtual address `0xC0000000` through a separate page table to physical frame `0x00106000`.
- A value written through the physical identity mapping is read through the higher-half alias, overwritten virtually, invalidated with `INVLPG`, and observed through the physical mapping.
- Runtime validation requires CR3 `0x00100000`, CR0 `0x80000011`, four identity tables, alias value `0xA5A55A5A`, and exact remaining-frame count `0x1ED9`.
- Paging remains enabled after verification, establishing the MMU foundation for the bounded heap and later protected execution work.
- The raw kernel is 9,912 bytes across twenty sectors with SHA-256 `97D9FC919D209D3FB70B4BF42CD794CC01085C56F3CDD1336A9704F6D9481E0B`.


## 4.45 - Add a bounded coalescing i686 heap

- The frame allocator supplies eight contiguous pages at `0x00107000`, creating a 32 KiB identity-mapped kernel heap.
- A fixed 16-byte in-heap block header records payload size, next block, allocation state, and reserved metadata.
- First-fit allocation aligns every request to 16 bytes and splits only when the remainder can hold a header plus a minimally aligned payload.
- Free validates exact payload pointers, rejects invalid and double frees, then coalesces forward and backward adjacent free blocks.
- Deterministic allocations return `0x00107010`, `0x00107060`, and `0x00107470`; freeing the middle block and requesting 512 bytes reuses `0x00107060`.
- Sentinel fills prove middle-block reuse does not corrupt the first or third allocation.
- Releasing all allocations restores one `0x7FF0`-byte free block and leaves exact physical-frame accounting `0x1ED1`.
- Debugcon and COM1 both require the complete split, reuse, coalescing, and frame-accounting marker.


## 4.46 - Read the boot disk through native ATA PIO

- Added exact 16-bit port input alongside the existing byte I/O helpers.
- A bounded primary-master IDENTIFY path selects the device, enforces BSY/DRQ/ERR/DF status transitions, and reads all 256 identification words.
- The kernel byte-swaps and trims words 27-46 to recover model `QEMU HARDDISK`, verifies LBA28 support, and reports the 2,048-sector image capacity.
- Native LBA28 PIO reads program drive/head, count, low/mid/high LBA bytes, issue command `0x20`, and transfer exactly 256 words.
- LBA0 is read through ATA and must retain the BIOS boot signature `0x55AA`.
- LBA9 is read into the bounded heap and compared byte-for-byte with the first 512 bytes of the executing kernel at physical address `0x00010000`.
- Releasing the sector buffer must restore the heap to its exact pre-I/O free capacity.
- Debugcon and COM1 require model, capacity, signature, kernel-sector equality, buffer address, and heap-restoration evidence.


## 4.47 - Mount and load a deterministic FAT12 filesystem

- Added a tracked deterministic FAT12 generator producing a standard 1.44 MiB volume with two nine-sector FATs, 224 root entries, and one-sector clusters.
- The legacy disk image expands to 2 MiB and carries an MBR type-`0x01` partition at LBA 64 for exactly 2,880 sectors.
- Host verification checks the partition table, BPB, hidden-sector count, mirrored FAT bytes, reserved entries, root record, cluster-2 end marker, and exact file content before QEMU starts.
- The generated root directory contains `HELLO.TXT` at cluster 2 with a fixed 86-byte payload and FNV-1a32 `0xA9F660F2`.
- The kernel rereads the MBR through native ATA, derives FAT/root/data LBAs from the BPB, scans bounded root entries, decodes the 12-bit cluster entry, and loads the file data.
- Runtime geometry is LBA64, root LBA `0x53`, data LBA `0x61`, cluster 2, and end-of-chain `0x0FFF`.
- Exact content, length, hash, and heap restoration are required on debugcon and COM1.
- The kernel occupies 15,096 bytes across thirty sectors, staying below the enforced LBA64 partition boundary.


## 4.48 - Add an interactive legacy i686 shell

- Added a bounded 64-byte COM1 command line with printable-ASCII filtering, backspace handling, explicit overflow recovery, and no dynamic input allocation.
- The shell starts only after exceptions, IRQs, physical frames, paging, the heap, ATA, and FAT12 have all completed their deterministic boot checks.
- `help` reports the complete command surface; `mem` exposes live frame and heap accounting; `ticks` reports the verified PIT counter and frequency.
- `disk` reports the ATA model, current LBA28 capacity, FAT12 mount status, and loaded file length.
- `cat HELLO.TXT` prints the exact 86-byte file previously loaded through native ATA and FAT12 traversal.
- `exit` emits a terminal report with five recognized operational commands, zero unknown commands, and an explicit successful exit state.
- The QEMU harness binds COM1 to redirected standard I/O, consumes output asynchronously, and sends six commands one at a time only after the preceding exact response appears, avoiding UART FIFO overrun.
- Debugcon and the live COM1 transcript must independently contain every command response, the FAT12 payload, and `commands 0x00000005 unknown 0x00000000 exit yes`.
- The raw kernel is 16,568 bytes across thirty-three sectors with SHA-256 `0D43769F95B59287EDD1556DF808E57AEB09BB217BE1D5F25A2DCFDEFA64D2B8`; the partitioned 2 MiB disk image SHA-256 is `C57A61830F879B091BF7D7C4E3CCA4ECD9646014796CCE0E8605A31B73E5EB77`.

## 4.49 - Preempt legacy i686 kernel tasks

- Changed IRQ0 from a counter-only gate into a stack-switching interrupt dispatcher that passes the complete saved context to Zig and resumes the returned context with `POPAD`/`IRETD`.
- Added an exact 44-byte ring-0 interrupt-context layout containing all eight `PUSHAD` registers plus EIP, CS, and EFLAGS.
- Added two independent 4 KiB kernel stacks and synthetic initial interrupt frames with ring-0 code selector `0x08` and IF-enabled EFLAGS.
- The scheduler uses deterministic round-robin order across bootstrap, task A, and task B while preserving the interrupted bootstrap context.
- Each worker executes three independently preempted quanta, sleeping with `HLT` between timer interrupts rather than yielding cooperatively.
- Seven IRQ0 context switches cover bootstrap-to-A, alternating A/B execution, and final restoration of the bootstrap stack.
- Scheduler shutdown is transactional: the active flag clears in the final timer interrupt before the bootstrap task resumes and masks the PIC.
- Debugcon and COM1 require exact worker counts `3/3`, switch count `7`, timer delta `7`, and `bootstrap-restored yes`.

## 4.50 - Establish ring-3 privilege isolation

- Replaced the temporary stage-1 descriptor table with a kernel-owned six-entry GDT containing null, ring-0 code/data, ring-3 code/data, and a 32-bit available TSS descriptor.
- Added an exact 104-byte TSS with selector `0x28`, ring-0 stack selector `0x10`, and a dedicated 4 KiB privilege-transition stack.
- Added assembly helpers for `LGDT`, far control-transfer reloading, segment reload, `LTR`, `STR`, and controlled `IRETD` entry into CPL3.
- Added user mappings at `0x00400000` and `0x00402000` with present, writable, and user permissions while retaining supervisor-only kernel mappings.
- A real ring-3 instruction stream writes sentinel `0xCAFEBABE`, preserves EAX `0x13579BDF`, and invokes a DPL-3 interrupt gate.
- The processor switches to TSS.ESP0, captures CS `0x1B`, SS `0x23`, and user ESP `0x00402000`, then restores the original kernel call stack.
- Named postcondition predicates independently validate TR, registers, privilege selectors, sentinel coherence, kernel U/S denial, and user PTE permissions.
- The two persistent user frames reduce live free-frame accounting from `0x1ED1` to `0x1ECF`; the shell and harness require that exact state.

## 4.51 - Add a ring-3 syscall ABI

- Added a DPL-3 interrupt gate at vector `0x80` with a complete writable register frame and normal `IRETD` return to user mode.
- Syscall number 1 performs bounded writes only from the mapped user code page and returns the exact byte count in EAX.
- Syscall number 2 returns deterministic process ID 1; syscall number 3 records an exit code and restores the synchronous kernel caller.
- The dispatcher rejects oversized, wrapping, unmapped, and supervisor-range pointers before dereferencing them.
- A user request targeting kernel address `0x00010000` returns `0xFFFFFFF2` (`-EFAULT`) and increments an independent rejection counter.
- The ring-3 program performs four calls: a 37-byte write, rejected write, getpid, and exit with code 42.
- Debugcon and COM1 require exact call, byte, PID, rejection, errno, and exit accounting.

## 4.52 - Load ELF32 programs from FAT12

- The deterministic FAT12 generator now emits `INIT.ELF` as a second root file at cluster 3 while retaining `HELLO.TXT` at cluster 2.
- `INIT.ELF` is a real little-endian ELF32 Intel 80386 executable with a 52-byte ELF header and one 32-byte `PT_LOAD` program header.
- The host image verifier checks the second root entry, cluster-3 FAT chain, ELF identity, type, machine, entry point, program-header geometry, load address, memory size, and executable flags.
- The kernel persists validated FAT geometry, locates `INIT.ELF` through the root directory, and reads it through native ATA PIO rather than using embedded program bytes.
- The loader accepts one bounded `PT_LOAD` segment at `0x00400000`, copies exactly 167 file bytes, and zero-fills the remaining 345 bytes of its 512-byte memory image.
- The loaded process writes `INIT.ELF executed in ring3 via FAT12.`, obtains PID 1 through `int 0x80`, and exits with code `0x33`.
- The synchronous ring-3 transition now preserves all cdecl callee-saved registers so user programs may freely clobber EBP, EBX, ESI, and EDI without corrupting kernel metadata.
- Debugcon and COM1 require file size `0x1A7`, entry `0x00400000`, PT_LOAD file size `0xA7`, memory size `0x200`, flags `5`, PID `1`, exit `0x33`, BSS zeroing, and heap restoration.

## 4.53 - Add a bounded VFS and process lifecycle

- Added a fixed-capacity VFS mount over the validated FAT12 root with four cached nodes and four descriptor slots.
- Root mounting ignores deleted, long-name, volume-label, and directory entries, and rejects files that exceed the current single-cluster bound.
- Descriptors retain independent byte offsets and provide bounded `open`, `read`, and `close` semantics rather than exposing raw FAT sectors to shell commands.
- A boot probe opens `HELLO.TXT` as descriptor 0, reads it in exact 32-byte and 54-byte portions, verifies the reconstructed 86-byte payload, and closes it.
- Added a four-slot process table with PID allocation, running/exited states, FAT 8.3 names, and retained exit codes.
- The original boot-loaded `INIT.ELF` becomes exited PID 1; `run INIT.ELF` loads the file again through VFS, assigns PID 2, executes at CPL3, obtains PID 2 through `getpid`, and exits `0x33`.
- `ls` enumerates `HELLO.TXT` and `INIT.ELF` from cached VFS nodes; `cat HELLO.TXT` reads through a descriptor; `ps` reports both exited user processes.
- The expanded live COM1 harness sends nine paced commands: help, ls, mem, ticks, disk, cat, run, ps, and exit.
- Final accounting requires three opens, four reads, three closes, two process records, last PID 2, exit `0x33`, eight operational shell commands, zero unknown commands, and no leaked descriptors.
- The final raw kernel occupies 27,124 bytes across 53 sectors, ending at LBA61 and preserving the enforced LBA64 FAT12 partition boundary; SHA-256 is `8CFEF2BF57955860A251C8027F09185B9568DBC80FDF01545CBD0875176F257F`.
- The final partitioned 2 MiB image SHA-256 is `A88410AC06C2446D3260EA891E3CC745E34BFF1AEEEB7D02D0516A3FFC83FE39`.

## 5.0 - Capstone platform release

- Promoted the legacy BIOS/i686 runtime from milestone numbering to the versioned `5.0.0` capstone release.
- Relocated the FAT12 partition from LBA64 to LBA256 and raised the bounded kernel capacity from 55 to 247 sectors.
- Stage-1 now loads the kernel through repeated EDD requests of at most 64 sectors while advancing both destination segments and source LBAs.
- The build computes an additive little-endian checksum16 over the complete padded kernel-sector image.
- Stage-1 verifies the checksum before entering protected mode; `_start` independently verifies the same in-memory image before modifying `.data` or clearing BSS.
- Boot-info ABI version 2 retains its exact 32-byte size and carries checksum16, FAT LBA256, and explicit E820/chunked-load/checksum flags `0x07`.
- The kernel rejects inconsistent versions, flags, sector bounds, FAT placement, or entry-stage checksum state.
- The host image verifier requires a zero-filled protected gap from the padded kernel end through LBA255, preventing unnoticed filesystem overlap.
- The reference kernel occupies 27,388 bytes across 54 sectors at LBA9-62, checksum16 `0x2FA8`, leaving 193 sectors / 98,816 bytes of reserved growth.
- Reference hashes: kernel `9EDE0CCE5959951212740814AE3EE701F4BFBF6DF5AE01C6F46C880840B327F6`; disk image `F91559C52FDB6CC684474493A131641405A1569380F469FC7B2B5E78C70FAE6F`.
- The complete nine-command COM1 shell session and every prior legacy subsystem contract continue to pass unchanged after the layout and integrity upgrade.

## 6.0 - Capstone preemptive multiprocess userspace

- Added a CR3 write primitive and a timer interrupt path that can select either ring-0 or ring-3 saved contexts.
- IRQ0 normalizes data segments before entering Zig and restores ring-appropriate selectors from the selected context before `IRETD`.
- Two runnable CPL3 processes each own a page directory, user page table, physical code page, physical stack page, and dedicated 4 KiB kernel privilege stack.
- The scheduler updates CR3, current PID, and TSS `esp0` on every task selection.
- Both processes execute at `0x00400000` and modify virtual address `0x00400100`, while physical tags `0x11` and `0x22` prove isolation across address spaces.
- The deterministic PIT schedule delivers three quanta to each process, performs seven total switches, and restores the bootstrap task, kernel CR3, TSS stack, and PID state.
- Eight temporary paging and user frames are released after the proof, with exact free-frame restoration.
- The process table expands to eight slots and retains PID1 `INIT.ELF`, PID2 `WORKA.BIN`, PID3 `WORKB.BIN`, and shell-launched PID4 `INIT.ELF`.
- The complete COM1 shell contract now reports timer count `0x13`, all four exited processes, and unchanged VFS descriptor accounting.
- Reference kernel: 29,948 bytes, 59 sectors at LBA9-67, checksum16 `0x6B47`, SHA-256 `3818AEBF59C33B216EB54BD7817B82062D4962D62A046D4D24B5DBC98715453A`.
- Reference disk image SHA-256: `E2B46B4971DDFD812E0AA778B7416265B4B928E1395F869DF8EFB0B447721094`.

