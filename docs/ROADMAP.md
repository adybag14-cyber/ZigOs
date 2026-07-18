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
