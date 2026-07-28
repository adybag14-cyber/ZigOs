# Priority remediation plan after Capstone 19

This document records the disposition of the post-Capstone audit. It distinguishes defects fixed in the current release line from architectural work that is now explicitly accepted but remains open. A source implementation, an isolated test, a QEMU integration proof and a required hosted-CI gate are separate evidence levels.

## Priority 0 â€” release correctness

Status: closed by the correctness/CI remediation.

| Finding | Resolution | Evidence |
| --- | --- | --- |
| The advertised isolated-test total was not actually executed | `build.zig` now runs ten canonical host-test roots spanning descriptors, commands, processes, TTY, VFS, ABI, page ownership, persistence, ELF loading and the userspace DNS codec: 63 unique declarations in total | canonical `zig build test` and `zig build check` |
| Syscall descriptor and flag registers were narrowed before validation | `runtime_abi.zig` range-checks full-width descriptor, open-flag and mode arguments before conversion | hostile tests cover 65536, `u64` maximum and high flag bits; source-contract verifier forbids the old truncation forms |
| Descriptor/VFS errors collapsed to bad-FD | one kernel-error-to-userspace-errno mapping now preserves not-found, access, read-only, directory, broken-pipe and resource-limit distinctions | isolated errno mapping tests plus full UEFI build |
| Default `kill PID` sent signal 15 without a delivery/default-action path | the kernel shell now defaults explicitly to forced signal 9; other signals remain opt-in and the absence of general userspace delivery is still documented | 44/46-command COM1 sessions prove PID 9 becomes zombie and is reaped |
| `wait PID` was a status query | the shell validates direct parentage, blocks itself through the process table, services the runtime until the target is terminal, then reaps once | 44/46-command COM1 sessions wait over a sleeping CPL3 PID before the next command is accepted |
| Built-in network help contradicted retained ping/DNS | help now describes retained e1000e packet I/O and explicit offline unavailability | source-contract check plus offline/live runtime sessions |
| Hosted CI omitted live permanent-shell ping/DNS | Windows CI now runs the 44-command offline and 46-command `-Network` sessions | required workflow step |
| Cross-platform identity was printed but not enforced | a dependent job downloads both artifact sets, compares path sets, then compares every file byte-for-byte | required workflow job; G423 |

## Evidence model used by the roadmap

- **Source implemented** means code exists but may not yet control the permanent runtime.
- **Isolated tested** means a deterministic `std.testing` or host-side contract executes it.
- **QEMU integrated** means the permanent or hardware runtime exercises it in a booted system.
- **Hosted required** means failure blocks the GitHub Actions workflow.
- **Bounded fixture only** must not be used to claim a general kernel facility.

## Priority 1 â€” memory and process architecture

Status: in progress. A post-bootstrap reclaiming physical-memory handoff, bounded permanent-runtime ownership layer and userspace spawn/wait slice are integrated and required by QEMU tests; the system-wide milestones remain open.

### P1-M1: system physical-memory manager

Delivered bounded slice: after all boot-time validation and hardware setup, the monotonic allocator transfers every unused usable firmware extent in place to a reclaiming physical-memory manager and is sealed against further allocation. The permanent executor requests pages below 4 GiB on demand through 256 generation-tagged ownership slots with arbitrary release/reuse, reference counts, poison-on-final-release, duplicate-backing rejection, OOM and invalid/double/wrong-owner/backing-failure accounting. Final releases return physical pages to coalescing free extents. The 44-command offline profile requires 231 allocations/frees and the 46-command live profile requires 262; both finish with zero allocated physical pages, zero owned pages, zero OOMs and zero rejected operations.

Still open: move boot-time page tables, stacks, DMA buffers, heaps and retained drivers onto the permanent manager rather than handing off only after validation; add synchronization, memory-pressure callbacks and an explicit OOM victim policy; permit ordinary allocations above 4 GiB through a direct physical-memory map; and apply low-memory restrictions only through per-device DMA masks or bounce buffers.

Roadmap links: G100, G101, G118â€“G129, G159â€“G167, G203, G448, G478â€“G480.

### P1-M2: unified permanent scheduler

Delivered bounded slice: syscall 76 spawns a VFS-backed direct CPL3 child; syscall 77 implements exact waitpid, wait-any and WNOHANG. Every retained CPL3 context is now selected through the same `serviceOne` round-robin path. Foreground commands transfer the TTY process group, block the kernel shell through the process table and wait while the common scheduler runs the child; the shell no longer calls `runtime_user.dispatch` directly and the scheduler has no foreground-exclusion argument. The separate 24-entry `Job` array is removed: `jobs`, kill and wait derive state from the 64-slot process table. `pipex` gates its writer as a normal blocked process and lets the shared scheduler drive the reader into a real pipe wait before waking the writer. `/bin/wait.elf` overlaps a three-tick child and one-tick child to prove completion-ordered wait-any, exact waitpid and WNOHANG, and process-table scans remain pointer-based so blocking waits cannot copy the array onto the syscall IST.

Still open: merge saved architecture contexts and process metadata into a single scheduler-owned task object, move the diagnostic kernel shell itself out of the special kernel-command path, add SMP-safe locking and per-CPU runnable queues, and complete general signal consumption/default actions across all process states.

Roadmap links: G113â€“G176, especially G132â€“G160.

### P1-M3: scalable process virtual memory

Delivered bounded slice: the permanent ABI now provides page-granular anonymous `mmap`, arbitrary page-aligned anonymous subrange `munmap`, W^X-enforced `mprotect`, `brk` growth/shrink and dynamically added/reclaimed user page tables. `/bin/vm.elf` proves the complete sequence and final reclamation.

Still open: replace the fixed userspace-window bounds with general VMA objects, eligible guard-fault stack growth, file-backed mappings, lazy demand paging and scalable rollback under concurrency. The current eight-page stack and bounded argv/envp/auxv contract are fixed-size rather than fully POSIX-general.

Roadmap links: G100â€“G125 and G161â€“G176.

## Priority 1 â€” persistent storage and VFS

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

Delivered bounded slice: the primary NVMe controller and namespace survive boot in polling mode; a dedicated GPT data partition is mounted at `/persist`; an A/B checksummed journal commits payload-before-header with flush/FUA ordering; files, directories and linked ELF64 programs are serialised through the VFS. ABI 1.4 lets CPL3 seek, create directories, unlink files, remove empty directories, rename within a mount and change mode bits. `/bin/fs.elf` commits a renamed 0600 file in generation 1, then after reboot verifies its content/mode/offset and commits userspace cleanup in generation 2. The normal userspace shell exposes the same mutation path alongside persistent ELF installation. Controller and journal errors propagate into kernel/userspace `sync`, `fsck` and the shutdown invariant.

Still open: a general block-device registry, multiple devices/namespaces, a filesystem-driver operation table, scalable allocation/free-space metadata, package installation independent of copying a boot-seeded artifact, a disk-backed root, larger files, concurrent mutation and broader crash/fault injection.

Roadmap links: G102, G177â€“G251 and G295.

## Priority 2 â€” userspace environment, devices and networking

Status: accepted and open.

### P2-U1: documented userspace ABI and SDK

Delivered bounded slice: `abi/zigos-abi.json` defines ABI version 1.5, page size, capability bits, syscall numbers 64-107, errno values, seek origins, message flags, bounded spawn-vector limits and auxiliary keys; the build generates matching kernel Zig, NASM and public SDK Zig constants/structures. `sdk/zig` publishes a W^X linker script, a SysV AMD64 startup/syscall bridge and typed wrappers for descriptors, files, process/wait, VM, poll and UDP. `spawnv` copies and validates argv/envp, while the kernel creates a 16-byte-aligned argc/argv/envp/auxv stack. A directly linked Zig ELF verifies these startup vectors plus ABI discovery, pseudo-file I/O, memory protection and errno mapping in both required runtime profiles. ABI 1.4 introduced the kernel-CR3-bridged `sync` wrapper plus typed `lseek`, `mkdir`, `unlink`, `rmdir`, `rename` and `chmod` wrappers. ABI 1.5 adds typed `sendto`, `recvfrom`, `getpeername` and per-socket nonblocking controls plus bounded `MSG_DONTWAIT` validation. The independent filesystem conformance ELF exercises every new call across a real reboot without mapping controller MMIO into user address spaces. `sdk/zig/dns.zig` adds a bounded DNS A query/response codec with malformed-name, transaction and compression-pointer tests; `/bin/dns.elf` proves the resolver from an arbitrary CPL3 Zig process against QEMU's real `localhost` response.

Still open: a generated C header/library, ioctl, broader clocks/signals, stat-by-path/openat/link/symlink/fsync interfaces, independent package/version distribution and a formal within-major compatibility suite.

Roadmap links: G138â€“G165, G182â€“G199, G252â€“G296 and G494â€“G495.

### P2-U2: real TTY

Delivered bounded slice: terminal descriptors provide blocking userspace input, canonical line buffering, echo, Backspace editing, poll readiness, foreground process-group routing, targeted scheduler wakeups and Ctrl-C default action. `/bin/tty.elf` proves an edited COM1 line blocks and wakes in CPL3. The normal profile now attaches a directly linked Zig `/bin/init.elf` to PID 1; that CPL3 init launches `/bin/sh.elf` as PID 2, while the shell prompt, `pwd`, `cd`, `ls`, `cat`, PID reporting, external spawn/wait and staged shutdown all execute in CPL3. Still open are termios/ioctl controls, `/dev/console` as a general openable device, pseudo-terminals and sessions beyond the single console.

Roadmap links: G143â€“G146, G252â€“G266 and G454.

### P2-U3: real pseudo-files and device objects

Introduce VFS operation tables for read/write/ioctl/poll/close and back `/dev`, `/proc` and `/net` with live registered objects. Shell-only `readPseudo()` conveniences do not satisfy this milestone.

Roadmap links: G171â€“G174 and G230â€“G235.

### P2-N1: userspace sockets

Delivered bounded slice: ABI syscalls provide descriptor-backed UDP socket, bind, connect, connected send/receive, unconnected `sendto`, source-reporting `recvfrom`, getsockname/getpeername, close and poll. Packet ingress fills bounded per-socket receive queues and wakes blocked readers; empty receives return `EWOULDBLOCK` under either persistent socket-level nonblocking mode or bounded per-call `MSG_DONTWAIT`. Process and descriptor quotas limit socket ownership. `/bin/socket.elf` sends a raw `localhost` DNS query to QEMU's retained resolver, blocks through the common scheduler until the real reply arrives, verifies source `10.0.2.3:53`, then checks its connected gateway peer. The retained driver masks NIC MSI-X and polls DMA status so syscall frames cannot be corrupted by nested IST1 timer entry.

Still open: concurrent resolver transactions, DHCP-derived resolver configuration/search domains, general socket options, writable readiness/backpressure, richer routing/ARP lifecycle, TCP application data/HTTP and decomposition of the monolithic e1000e protocol source.

Roadmap links: G297â€“G339 and G341â€“G343.

### P2-B1: normal boot profile

Delivered bounded slice: `-Dnormal-boot=true` branches after retained hardware/storage discovery and before the kernel heap, cooperative/preemptive scheduler demonstrations and Capstone 15/16 software proof workloads. It mounts the runtime VFS and persistent NVMe subtree, promotes the reserved PID 1 record to a directly linked Zig `/bin/init.elf`, and attaches a private CPL3 address space to that existing handle. PID 1 launches `/bin/sh.elf` through public `spawnv`, establishes PID 2 as the foreground process group, waits for and reaps the shell, then requests final shutdown. The session also copies, commits and executes a persistent Zig ELF, exercises userspace filesystem mutation, and requires exact 97/97 physical-page reclamation with zero descriptors/contexts at shutdown. The default diagnostic profile remains available and continues to run the exhaustive release workload.

Still open: split the large hardware discovery routines into minimal initialisation and optional validation phases so normal boot can also skip assertion-heavy NIC/NVMe protocol proofs, and promote a disk-installed userspace root and init image rather than the current boot-seeded RAM VFS copy of `/bin/init.elf`.

Roadmap links: G252, G295â€“G296, G424â€“G426 and G489.

## Priority 3 â€” security and hardware robustness

Status: accepted and open.

Security work includes credentials and permissions, syscall capability checks, SMEP/SMAP, kernel W^X, ASLR, guarded/canary-protected kernel stacks, DMA trust/IOMMU policy, cross-resource quotas, complete signal permissions/delivery, malformed-pointer testing and a written threat model. Current root-only credentials and bounded VFS modes do not provide multi-user isolation.

Hardware work includes physical Intel and AMD boots, RAM above 4 GiB, multiple controllers/namespaces/NICs, timeout/reset recovery, USB hubs/HID variation, ACPI power-off/reboot, interrupt-routing variation, DMA constraints and graceful RAM-backed recovery when no supported disk is usable.

Roadmap links: G413â€“G426, G427â€“G465 and G466â€“G500.

## ?Usable hobby OS? acceptance gate

ZigOs should not claim this gate until one normal permanent session can mount a writable disk root, preserve a file across reboot, execute an independently installed ELF, launch userspace PID 1 and an interactive userspace shell, use a real TTY, run and reclaim substantially more than eight processes, use RAM above 4 GiB, block/wait/signal/reap correctly, expose a versioned ABI, provide userspace UDP and pass repeated stress/malformed-input sessions on at least one documented physical machine.
