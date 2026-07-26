# Priority remediation plan after Capstone 19

This document records the disposition of the post-Capstone audit. It distinguishes defects fixed in the current release line from architectural work that is now explicitly accepted but remains open. A source implementation, an isolated test, a QEMU integration proof and a required hosted-CI gate are separate evidence levels.

## Priority 0 — release correctness

Status: closed by the correctness/CI remediation.

| Finding | Resolution | Evidence |
| --- | --- | --- |
| The advertised isolated-test total was not actually executed | `build.zig` now runs `runtime_fd.zig`, `runtime_command.zig`, `runtime_process.zig`, `runtime_vfs.zig`, `runtime_abi.zig` and `runtime_page_pool.zig`: 47 unique declarations in total (62 direct-runner executions including imported tests) | canonical `zig build test` and `zig build check` |
| Syscall descriptor and flag registers were narrowed before validation | `runtime_abi.zig` range-checks full-width descriptor, open-flag and mode arguments before conversion | hostile tests cover 65536, `u64` maximum and high flag bits; source-contract verifier forbids the old truncation forms |
| Descriptor/VFS errors collapsed to bad-FD | one kernel-error-to-userspace-errno mapping now preserves not-found, access, read-only, directory, broken-pipe and resource-limit distinctions | isolated errno mapping tests plus full UEFI build |
| Default `kill PID` sent signal 15 without a delivery/default-action path | the kernel shell now defaults explicitly to forced signal 9; other signals remain opt-in and the absence of general userspace delivery is still documented | 42/43-command COM1 sessions prove PID 9 becomes zombie and is reaped |
| `wait PID` was a status query | the shell validates direct parentage, blocks itself through the process table, services the runtime until the target is terminal, then reaps once | 42/43-command COM1 sessions wait over a sleeping CPL3 PID before the next command is accepted |
| Built-in network help contradicted retained ping/DNS | help now describes retained e1000e packet I/O and explicit offline unavailability | source-contract check plus offline/live runtime sessions |
| Hosted CI omitted live permanent-shell ping/DNS | Windows CI now runs the 42-command offline and 43-command `-Network` sessions | required workflow step |
| Cross-platform identity was printed but not enforced | a dependent job downloads both artifact sets, compares path sets, then compares every file byte-for-byte | required workflow job; G423 |

## Evidence model used by the roadmap

- **Source implemented** means code exists but may not yet control the permanent runtime.
- **Isolated tested** means a deterministic `std.testing` or host-side contract executes it.
- **QEMU integrated** means the permanent or hardware runtime exercises it in a booted system.
- **Hosted required** means failure blocks the GitHub Actions workflow.
- **Bounded fixture only** must not be used to claim a general kernel facility.

## Priority 1 — memory and process architecture

Status: in progress. A post-bootstrap reclaiming physical-memory handoff, bounded permanent-runtime ownership layer and userspace spawn/wait slice are integrated and required by QEMU tests; the system-wide milestones remain open.

### P1-M1: system physical-memory manager

Delivered bounded slice: after all boot-time validation and hardware setup, the monotonic allocator transfers every unused usable firmware extent in place to a reclaiming physical-memory manager and is sealed against further allocation. The permanent executor requests pages below 4 GiB on demand through 256 generation-tagged ownership slots with arbitrary release/reuse, reference counts, poison-on-final-release, duplicate-backing rejection, OOM and invalid/double/wrong-owner/backing-failure accounting. Final releases return physical pages to coalescing free extents. The 42-command offline profile requires 197 allocations/frees and the 43-command live profile requires 213; both finish with zero allocated physical pages, zero owned pages, zero OOMs and zero rejected operations.

Still open: move boot-time page tables, stacks, DMA buffers, heaps and retained drivers onto the permanent manager rather than handing off only after validation; add synchronization, memory-pressure callbacks and an explicit OOM victim policy; permit ordinary allocations above 4 GiB through a direct physical-memory map; and apply low-memory restrictions only through per-device DMA masks or bounce buffers.

Roadmap links: G100, G101, G118–G129, G159–G167, G203, G448, G478–G480.

### P1-M2: unified permanent scheduler

Delivered bounded slice: syscall 76 spawns a VFS-backed direct CPL3 child; syscall 77 implements exact waitpid, wait-any and WNOHANG. The scheduler excludes the shell-owned foreground context while servicing its runnable children, and `/bin/wait.elf` proves both blocking forms and nonblocking wait in the permanent runtime. Process-table scans are pointer-based so blocking waits cannot copy the 64-process array onto the syscall IST. Roadmap goals G114 and G138-G140 are closed.

Still open: retire the separate bounded executor/job structure entirely. One system scheduler must own saved contexts, runnable queues, time slices, all blocking/wakeups, signal consumption, process groups, orphan adoption and reaping across the kernel.

Roadmap links: G113–G176, especially G132–G160.

### P1-M3: scalable process virtual memory

Delivered bounded slice: the permanent ABI now provides page-granular anonymous `mmap`, arbitrary page-aligned anonymous subrange `munmap`, W^X-enforced `mprotect`, `brk` growth/shrink and dynamically added/reclaimed user page tables. `/bin/vm.elf` proves the complete sequence and final reclamation.

Still open: replace the eight-context and fixed userspace-window bounds with general VMA objects, flexible multi-page stacks, eligible guard-fault growth, file-backed mappings, lazy demand paging, argv/envp/auxv completeness and scalable rollback under concurrency.

Roadmap links: G100–G125 and G161–G176.

## Priority 1 — persistent storage and VFS

Status: accepted and open.

The retained kernel architecture should converge on a permanent service layer equivalent to:

```zig
const KernelServices = struct {
    physical_memory: *PhysicalMemoryManager,
    scheduler: *Scheduler,
    devices: *DeviceRegistry,
    block_devices: *BlockRegistry,
    network_interfaces: *NetworkRegistry,
    consoles: *ConsoleRegistry,
    vfs: *Vfs,
};
```

Drivers must register live interfaces rather than return boot-success booleans. The VFS must dispatch through filesystem and file-operation tables rather than only assigning mount metadata. Required milestones are retained block devices, GPT/MBR partition objects, a filesystem-driver interface, a writable disk filesystem, flush/error propagation, reboot persistence and execution of an ELF placed on disk independently of the EFI build.

Roadmap links: G102, G177–G251 and G295.

## Priority 2 — userspace environment, devices and networking

Status: accepted and open.

### P2-U1: documented userspace ABI and SDK

Delivered bounded slice: `abi/zigos-abi.json` defines ABI major version 1, page size, capability bits, syscall numbers 64-92 and errno values; the build generates matching Zig and NASM constants, userspace can query the ABI, and hostile full-width argument tests enforce narrowing and flag rules.

Still open: publish startup code, linker scripts, C/Zig SDK libraries, compatibility policy/conformance binaries, ioctl and the broader file/process/clock interfaces required by independent applications.

Roadmap links: G138–G165, G182–G199, G252–G296 and G494–G495.

### P2-U2: real TTY

The kernel shell and spawned processes now inherit numeric terminal descriptors, and userspace writes stream through descriptors 1 and 2. Still open are blocking userspace terminal input, line discipline, echo/editing controls, foreground process groups, Ctrl-C generation, `/dev/console` and pseudo-terminals. The kernel-shell model remains a bounded transition stage.

Roadmap links: G143–G146, G252–G266 and G454.

### P2-U3: real pseudo-files and device objects

Introduce VFS operation tables for read/write/ioctl/poll/close and back `/dev`, `/proc` and `/net` with live registered objects. Shell-only `readPseudo()` conveniences do not satisfy this milestone.

Roadmap links: G171–G174 and G230–G235.

### P2-N1: userspace sockets

Delivered bounded slice: ABI syscalls provide descriptor-backed UDP socket, bind, connect, send, blocking receive, getsockname, close and poll. Packet ingress fills bounded per-socket receive queues and wakes blocked readers; process and descriptor quotas limit socket ownership. `/bin/socket.elf` proves socket/bind/connect/send/poll/close through the live e1000e path. The retained driver masks NIC MSI-X and polls DMA status so syscall frames cannot be corrupted by nested IST1 timer entry.

Still open: sendto/recvfrom and explicit nonblocking mode, getpeername/options, resolver APIs, richer routing/ARP lifecycle, TCP application data/HTTP and decomposition of the monolithic e1000e protocol source.

Roadmap links: G297–G339 and G341–G343.

### P2-B1: normal boot profile

Boot validation must become an explicit test profile. Normal boot should initialise retained services, mount a root and launch userspace PID 1 without executing the entire proof sequence. Recovery/diagnostic boot should remain possible when optional devices are absent.

Roadmap links: G252, G295–G296, G424–G426 and G489.

## Priority 3 — security and hardware robustness

Status: accepted and open.

Security work includes credentials and permissions, syscall capability checks, SMEP/SMAP, kernel W^X, ASLR, guarded/canary-protected kernel stacks, DMA trust/IOMMU policy, cross-resource quotas, complete signal permissions/delivery, malformed-pointer testing and a written threat model. Current root-only credentials and bounded VFS modes do not provide multi-user isolation.

Hardware work includes physical Intel and AMD boots, RAM above 4 GiB, multiple controllers/namespaces/NICs, timeout/reset recovery, USB hubs/HID variation, ACPI power-off/reboot, interrupt-routing variation, DMA constraints and graceful RAM-backed recovery when no supported disk is usable.

Roadmap links: G413–G426, G427–G465 and G466–G500.

## ?Usable hobby OS? acceptance gate

ZigOs should not claim this gate until one normal permanent session can mount a writable disk root, preserve a file across reboot, execute an independently installed ELF, launch userspace PID 1 and an interactive userspace shell, use a real TTY, run and reclaim substantially more than eight processes, use RAM above 4 GiB, block/wait/signal/reap correctly, expose a versioned ABI, provide userspace UDP and pass repeated stress/malformed-input sessions on at least one documented physical machine.
