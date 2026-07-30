# Priority remediation plan after Capstone 19

This document records the current disposition of the post-Capstone architecture audit. It distinguishes bounded work that is implemented and boot-tested from general operating-system facilities that remain open. Source implementation, isolated testing, QEMU integration and required hosted CI are separate evidence levels.

## Current evidence baseline

The maintained x86-64 release line now requires:

- 89 unique isolated Zig test declarations;
- generated ABI constants checked for staleness;
- independent Zig and C userspace ELF verification;
- a 49-command offline permanent-runtime COM1 session;
- a 51-command live-network permanent-runtime COM1 session;
- a four-boot NVMe persistence proof with forced termination after both file-scoped `fsync` and `fdatasync`;
- a persistent normal userspace PID 1/PID 2 profile;
- a USB-booted diskless normal RAM-root recovery profile;
- byte-identical Linux and Windows release artifacts.

A bounded fixture must not be used to claim a general kernel facility.

## Priority 0 — release correctness

**Status: closed for the current release contract.**

The release contract now enforces full-width syscall argument validation, stable errno mapping, real blocking wait, completion-ordered wait-any, one retained CPL3 scheduler path, live network integration, exact allocator cleanup, generated ABI interfaces and byte-for-byte cross-platform artifact identity.

The later ABI 1.6/device pass also closes several documentation and lifecycle discrepancies:

- delayed terminal children are drained and reaped before diagnostic shutdown accounting;
- the hardware socket capability reports four active e1000e UDP endpoints rather than eight descriptor bookkeeping slots;
- `/dev/null`, `/dev/zero` and `/dev/console` have real per-node semantics;
- normal boot can recover without NVMe or SATA instead of hard-failing while using a RAM-backed root.

## Priority 1A — memory and process architecture

### P1-M1: system physical-memory manager

**Verdict: partially addressed; system-wide work remains open.**

Delivered bounded slice:

- unused firmware memory is transferred from the sealed bootstrap allocator to a reclaiming physical-memory manager;
- arbitrary page allocation and release, immediate reuse and extent coalescing;
- ownership, generation and reference tracking;
- invalid, duplicate, double and wrong-owner release detection;
- final-release poisoning and exact allocation accounting;
- permanent userspace shutdown with zero outstanding owned pages;
- 4,096 ownership slots and allocation support preserving low and high firmware extents.

The current ABI 1.12 permanent-runtime integration proves exact userspace page-pool allocation/release totals of 248/248 offline and 279/279 live-network, with post-bootstrap physical-manager totals of 298/298 and 334/334 respectively. Persistent normal boot balances 129/129 physical allocations/frees.

Still open:

- boot page tables, boot stacks, retained driver allocations and DMA buffers are not generally owned by the permanent manager;
- ordinary runtime allocations remain constrained below 4 GiB;
- no direct physical-memory map supports normal high-memory access;
- no per-device DMA mask or bounce-buffer policy;
- no SMP locking;
- no memory-pressure callbacks or explicit OOM victim policy.

**Disposition:** executor memory reclamation is addressed. System-wide physical-memory management is not.

### P1-M2: unified scheduler and task ownership

**Verdict: substantially addressed for BSP CPL3 execution; scalable task architecture remains open.**

Delivered bounded slice:

- the separate pseudo-job array is gone;
- foreground, background, pipe and fixture CPL3 execution all enter through `runtime_user.serviceOne`;
- userspace spawn/wait use the 64-slot process table;
- wait-any, exact waitpid and WNOHANG are tested with overlapping children;
- foreground shell execution blocks through normal process state rather than directly dispatching a selected context;
- diagnostic shutdown performs bounded quiescence, finalizes terminal contexts and reaps terminal children before enforcing zero leaks.

Still open:

- process metadata remains in `runtime_process.Table` while saved CPU contexts remain in `runtime_user.contexts`;
- scheduling is BSP-only and depends on the permanent service loop;
- no SMP-safe or per-CPU runnable queues;
- no complete userspace signal-frame/handler/return mechanism;
- the diagnostic kernel shell remains a special kernel execution path.

**Disposition:** normal CPL3 execution has one scheduler path, but ZigOs does not yet have one scalable kernel task subsystem.

### P1-M3: scalable process virtual memory

**Verdict: partially addressed.**

Delivered bounded slice:

- anonymous `mmap`;
- page-aligned partial `munmap`;
- W^X-enforced `mprotect`;
- `brk` growth and shrink;
- dynamically created and reclaimed page tables;
- a booted `/bin/vm.elf` conformance sequence.

Still open:

- fixed userspace window and 1,024 mapping records per context;
- fixed eight-page stacks;
- eager allocation;
- no file-backed or shared mappings;
- no demand paging, copy-on-write or guard-fault stack growth;
- no concurrent VMA tree or scalable rollback.

**Disposition:** a credible bounded VM API exists. A general process virtual-memory manager does not.

## Priority 1B — persistent storage and VFS

**Verdict: real bounded persistence; general disk filesystem remains open.**

Delivered bounded slice:

- retained primary NVMe controller and dedicated GPT data partition mounted at `/persist`;
- alternating A/B generations with CRC validation;
- payload-before-header ordering, flush and FUA commit behaviour;
- newest-valid-generation recovery and fallback from a corrupt newest slot;
- persistent files, directories, modes and offsets;
- userspace mutation and two-boot integration testing;
- persistent ELF installation and execution after reboot.

What it still is not:

`/persist` remains a serialized bounded RAM-VFS subtree. Normal VFS operations do not directly manipulate scalable on-disk inode, extent or free-space structures. `/` remains RAM-backed and `/bin` is initially embedded in the EFI image.

The bounded VFS now also provides real directory-descriptor-relative `openat`, one shared `stat`/`fstat` metadata conversion, and POSIX-style unlink lifetime for ordinary open files: the pathname disappears immediately, existing open descriptions remain usable, and the node is reclaimed after the final close. Detached files are absent from persistence snapshots because serialization walks only the visible namespace.
Replacement rename is now supported for an existing same-mount file. All kind, mount, cycle, read-only and destination constraints are validated before mutation; the source then becomes the visible destination in one namespace operation. If the old destination is open, its descriptors retain the replaced object until final close, while persistence records only the new visible file.
Symbolic links are represented as distinct VFS nodes. Normal path lookup follows relative and absolute targets with an eight-link maximum, while `unlink`, `rmdir`, rename-source lookup and `readlink` do not follow the final component. Link records and target text survive the A/B journal and are revalidated by a second CPL3 boot.
Directory-entry names are now stored separately from node data and metadata in a bounded dentry table. Ordinary files can have multiple same-mount dentries; stat reports their shared node/generation and link count, unlink removes one name, and zero-link nodes remain alive only while descriptors reference them. The journal writes canonical file data once and restores alias records in a second pass.
A separate bounded dentry lookup cache now stores generation-validated parent/name mappings. Traversal acquires and releases references, referenced entries are not eligible for LRU eviction, namespace mutations invalidate matching entries, and a full pinned cache falls back to authoritative lookup. Normal and diagnostic shutdown require zero cache references and balanced acquire/release accounting.
Mounts now form an explicit bounded tree. Every non-root mount records its parent mount, covered mountpoint and distinct mounted root; lookup and directory capabilities cross mountpoints, `..` escapes mounted roots through the parent namespace, canonical paths cross nested roots, and unmount requires child mounts and open descriptors to be released first. The kernel still has no public mount/unmount ABI and does not yet track process working directories as unmount references.
Each inode now owns a portable ticket lock for data and size mutation. Ordinary writes, truncation and append share that lock; append holds it across EOF selection, data copy, file-size update and the calling open description's final offset. A four-thread host test verifies 128 fixed-size records appear exactly once without overlap or loss, while normal and diagnostic shutdown require nonzero lock activity and zero outstanding tickets.
Ordinary-file bytes now live in a shared pool of 256 page-sized blocks instead of one dense 32 KiB array per node. Each file has eight logical block slots; absent slots read as zero, writes allocate touched slots transactionally, truncate/unlink return blocks, and ABI 1.9 `fallocate` supports bounded preallocation and hole punching. Journal kind 5 preserves logical size and the resident-block bitmap, including executable files whose final mode is `0555`. Required shutdown gates report and drain the pool lock and verify resident block/byte ownership. This remains a bounded 32 KiB-per-file design, not a scalable extent tree.
ABI 1.10 adds synchronous vectored descriptor I/O without creating a second descriptor path. The kernel copies and validates at most eight 16-byte vector descriptors, validates every nonempty user range and the 1,024-byte aggregate limit before I/O, then performs one existing descriptor write from a gathered buffer or one descriptor read followed by scatter. Invalid later vectors therefore cannot partially mutate a file or consume its shared offset.

Descriptor `fsync(fd)` and ABI 1.11 `fdatasync(fd)` resolve the exact regular VFS node. RAM-backed files complete immediately and clear only that inode's dirty ledger; persistent stable committed paths replace only the target record in a separate scratch payload built from the last committed generation. Both exclude unrelated dirty VFS state and preserve the committed in-memory baseline on device-write failure. `fsync` records current data, logical size, sparse allocation map and mode; `fdatasync` records current data/size/allocation while retaining the mode from the prior committed record. A required four-boot gate creates generation 1, kills QEMU after a generation-2 fsync and a generation-3 fdatasync, then proves full fsync metadata durability, fdatasync dirty-mode exclusion, link-alias recovery and unrelated sparse-state exclusion before generation-4 cleanup. New names and changed rename/link topology still require global `sync`.

Global `sync` now operates over the complete active writable-mount table rather than being hard-wired to `/persist`. The store validates the full plan before device I/O, visits writable mounts in ID order, treats RAM filesystems as immediately synchronized, commits the configured `zigos_persist` mount exactly once, skips read-only mounts and rejects unsupported writable or duplicate persistent backends without advancing the journal. Required diagnostic shutdown reports one RAM and one durable visit; the diskless normal gate proves RAM-root-only sync succeeds with no journal generation.

A separate file-data page cache now fronts ordinary reads without replacing the authoritative 256-block file pool. It is fixed at sixteen 4 KiB entries, keys pages by inode slot, inode generation and logical page, caches sparse holes as zero pages and uses LRU replacement. Reads take the inode data lock before cache lookup; writes, truncation, hole punching, sparse restoration and inode reclamation write through to the block pool and invalidate all cached pages for that inode. An independent one-byte logical-page bitmap per inode records dirty pages even when no cache entry is resident, and resident entries mirror that authoritative state. Successful global sync clears every writable mount only after plan validation and durable commit; RAM-backed regular-file fsync/fdatasync clears only the target inode immediately, while persistent target state clears only after journal success. Rejected mount plans and injected journal-write failure preserve dirty bits exactly for retry. Journal restoration and read-only mount adoption establish clean baselines, and inode destruction discards obsolete state. Normal and diagnostic shutdown require bounded occupancy, real hit/miss/population activity, zero dirty resident/ledger state and zero outstanding cache-lock tickets. An early QEMU run exposed a kernel-stack hazard when a 64 KiB cache scan was iterated by value; all scans now use indices/references and the source contract forbids the unsafe form. Data writes remain synchronous/write-through, but dirty-state synchronization can now be scheduled asynchronously through one generation-tagged request. Scheduling captures the target inode generation, dirty-page mask and persistent classification without clearing state; at most one later runtime service pass handles the active request. RAM-backed files complete immediately in the worker, while stable committed persistent files reuse data-only A/B journal semantics. Busy duplicate scheduling, unsupported new persistent names, injected I/O failure and stale inode reuse are counted separately and preserve dirty state. Required diagnostic QEMU sessions prove scheduling/completion separation with `/bin/sdk.elf` and exact `1/1/1` request/completion/pass plus `3/3` queued/completed pages; normal, diskless and four-boot profiles also accept a conserved idle worker. Each cache entry now owns one independently allocated post-bootstrap PMM page rather than embedding 64 KiB of page bytes in the VFS object. Every runtime service pass checks a bounded low watermark and, when crossed, evicts clean LRU entries down to a fixed target while retaining every dirty resident page and its eviction-independent ledger. The diagnostic `cachepressure` command uses the same path: the required 54/56-command QEMU sessions prove four cache pages returned to the PMM while 11/12 dirty entries remain, then global sync clears them and shutdown releases all remaining cache pages. Allocation/release counters must balance before final PMM accounting, with measured physical-manager totals of 298/298 offline, 334/334 live and 129/129 in persistent normal boot. This is a bounded low-watermark policy, not global OOM selection. Each inode now additionally owns one ticket lock per logical 4 KiB page. Ordinary and append writes lock their affected pages, replacement writes lock all eight bounded pages, and truncate, preallocation, hole punching and sparse restoration acquire affected page locks in ascending order and release in reverse. A required four-thread host test performs 128 writes into disjoint regions of one already cached page and requires exact 128 page-lock and 128 inode-lock tickets, intact final regions and zero outstanding locks. Offline and live QEMU shutdown each report 186 page-write tickets with zero outstanding after replacing the three RAM-copied boot fixtures with block-backed files. The pre-existing whole-inode lock remains the outer serialization boundary for EOF selection, allocation, size and descriptor-offset consistency; this establishes explicit same-page correctness but does not permit concurrent different-page writes. ABI 1.12 now adds bounded read-only file-backed `MAP_SHARED`: descriptor resolution supplies a generation-tagged regular-file identity, each mapped page pins the matching PMM-backed cache entry and inode, pressure and ordinary eviction skip pinned entries, and ordinary file mutations refresh the borrowed physical page in place. Close and unlink preserve mapping lifetime until final unmap, which balances the pin and permits deferred reclamation. The CPL3 Zig fixture opens the descriptor before `chmod 000`, maps a 13-byte partial final page, and proves mapped/file read equality before and after an ordinary retained-descriptor write and after close/unlink; offline and live shutdown report exact mapped refs/pin/unpin/refresh/fail `0/1/1/1/0`, zero pin failures and zero final file mappings. Writable file mappings, file-backed private mappings, `msync` and mapped-write persistence remain open.

The verified EFI GPT partition is now retained after boot and mounted at `/boot` through a dedicated read-only FAT16 backend. Directory metadata is staged in bounded tables, while file contents remain on NVMe and are streamed through a generic block callback; backed logical bytes are reported separately from RAM-resident VFS bytes. The backend accepts at most 32 files, 24 directories and depth 8, handles 8.3 short names only, caches the active FAT sector and keeps a sequential per-file cluster cursor. Mount validation traverses every staged file and directory chain through EOC, using a per-chain bitmap for loop detection and a global ownership bitmap for cross-link detection; invalid current and next-cluster references have a separate out-of-range error and counter. VFS publication occurs only after the entire FAT scan succeeds. Host cases prove cyclic, cross-linked and out-of-range media leave `/boot` unpublished and can enter a conserved classified quarantine state. Healthy diagnostic QEMU reports 10,881 claimed clusters with `0/0/0` loop/cross/range counters; persistent normal reports 10,781 claimed clusters with metadata-only reads, while diskless normal requires the backend to remain absent. A dedicated required QEMU image aliases only the non-boot `BOOT.CFG` entry to `README.TXT`; the kernel boots from the untouched EFI chain, reports `cross_link`, erases staged metadata, mounts the embedded read-only fallback, proves the corrupt names are absent, and shuts down with exact `48/0/48` FAT preflight reads and 129/129 physical allocations/frees. Only classified FAT-integrity failures are quarantined; device/I/O errors remain fatal. No on-disk repair is attempted, and a later VFS resource failure during post-validation publication is not claimed to be transactionally rolled back. FAT writes, LFN entries, mirror validation, repair and general fsck remain open.

Still open:

- disk-backed root;
- filesystem backend/operation interface for several filesystem implementations;
- block-device registry and multiple devices/namespaces;
- AHCI-backed permanent storage;
- scalable free-space allocation and large files;
- concurrency remains incomplete outside per-inode data writes; richer crash injection remains open;
- package installation independent of a boot-seeded executable.

## Priority 2 — userspace, devices and networking

### P2-U1: documented ABI and SDK

**Verdict: substantially addressed; stable external platform remains open.**

Delivered through ABI 1.12:

- `abi/zigos-abi.json` remains the source of truth;
- generated matching kernel Zig, NASM, public Zig and C constants/layouts;
- syscall numbers 64-118 and typed errno values;
- capability discovery and SysV AMD64 argc/argv/envp/auxv startup;
- Zig wrappers for process, VM, file, directory, poll and UDP APIs;
- ABI 1.6 `ioctl`, path `stat`, `openat` and descriptor `fsync`;
- ABI 1.7 `symlink` and `readlink` with an eight-link traversal bound;
- ABI 1.8 hard-link creation and stat link counts without changing the 32-byte stat layout;
- ABI 1.9 descriptor `fallocate`, `KEEP_SIZE` preallocation and `PUNCH_HOLE|KEEP_SIZE` sparse-hole release;
- ABI 1.10 generated 16-byte `IoVector` layouts and descriptor `readv`/`writev`, bounded to eight vectors and 1,024 total bytes;
- ABI 1.11 descriptor `fdatasync`, sharing the transactional file-record path while preserving previously committed mode metadata;
- ABI 1.12 read-only file-backed `MAP_SHARED`, generated Zig/C constants and wrappers, descriptor-generation validation, coherent cache-page reads and balanced mapping pins;
- a generated `sdk/c/include/zigos.h` and freestanding C wrapper library;
- independently linked Zig and C conformance ELFs;
- userspace DNS codec/resolver, init and shell.

The booted C fixture proves generated layout compatibility, ABI discovery, `/dev/null`, `/dev/zero`, `/dev/console`, TTY ioctl flags, path stat, directory-descriptor and absolute `openat` semantics, `fsync`, `fdatasync`, symbolic-link creation, `readlink`, traversal, loop rejection, hard-link identity/link counts, sparse preallocation, invalid-mode rejection, hole punching, gathered writes, scattered reads and failure-atomic vector validation from a non-Zig application.

Still open:

- formal within-major compatibility policy and compatibility test corpus;
- packaged/versioned SDK distribution;
- dynamic linking and `ET_DYN`;
- broader clocks and complete signal APIs;
- file-backed mappings, global OOM selection and automatic writeback scheduling, parallel different-page writes, mmap/file cache coherence and broader asynchronous filesystem synchronization.

### P2-U2: real TTY

**Verdict: substantially addressed for one console session.**

Delivered bounded slice:

- blocking CPL3 reads, canonical line buffering and poll;
- echo, Backspace/DEL, Ctrl-U, Ctrl-D EOF and Ctrl-C foreground-group termination;
- foreground session/group checks and reader wake-up;
- `/dev/console` opens as the actual TTY stream;
- ABI 1.6 ioctl get/set flags for echo, canonical input and signal processing;
- userspace init PID 1 and shell PID 2 in normal boot.

Still open:

- a complete termios-compatible structure and ioctl surface;
- pseudo-terminals;
- several login sessions;
- complete Unix job control;
- richer streaming/output semantics.

### P2-U3: pseudo-files and device objects

**Verdict: bounded milestone delivered; general device registry remains open.**

Delivered:

- each pseudo/device node carries a `PseudoOperations` table for read, write, poll, ioctl and close plus optional stream identity;
- `/dev/null` is readable EOF and writable discard;
- `/dev/zero` returns zero bytes and accepts writes;
- `/dev/console` routes to the actual retained TTY;
- `/proc/*` and `/net/*` are separately registered read-only generated nodes;
- VFS and descriptor tests verify operation dispatch, readonly-devfs exceptions, close lifecycle and console ioctl state.

Still open:

- a system-wide device registry with discovery, naming and hotplug lifecycle;
- richer independently registered `/proc`, `/dev` and `/net` kernel objects;
- device-specific structured ioctl families;
- block, character and network backend interfaces shared by several drivers.

### P2-N1: userspace sockets

**Verdict: substantially addressed for bounded IPv4 UDP.**

Delivered:

- descriptor-backed UDP socket, bind, connect, send, receive, sendto, recvfrom, getsockname, getpeername, nonblocking mode, poll and close;
- blocked-reader wake-up from live network ingress;
- a userspace DNS resolver fixture using the retained e1000e path;
- ABI discovery now reports a maximum of four simultaneously usable hardware UDP endpoints, matching `udp_endpoint_capacity = 4`, while eight descriptor bookkeeping slots remain available internally.

Still open:

- TCP application data and listen/accept;
- IPv6;
- general socket options;
- multiple interfaces and complete routing;
- resolver concurrency;
- writable backpressure;
- production-grade ARP/DHCP lifecycle;
- decomposition of the large e1000e driver/protocol source.

### P2-B1: normal boot

**Verdict: substantially addressed, including diskless recovery.**

Delivered:

- `-Dnormal-boot=true` skips the kernel heap and large software proof workloads;
- retained hardware discovery, runtime VFS, userspace PID 1 and userspace PID 2 shell;
- persistent file mutation, ELF installation and execution with NVMe present;
- exact cleanup and reclamation;
- when no usable NVMe or SATA device exists, normal boot continues with embedded assets and a RAM-backed root;
- a required USB-booted QEMU gate verifies the diskless session, RAM file mutation, C SDK execution, successful RAM-root all-writable-mount sync with zero journal commits and `storage diskless-ram-root cleanup yes`.

Still open:

- hardware discovery still needs a clean split between minimal initialization and optional diagnostic validation;
- PID 1 and `/bin` are still seeded from embedded build assets;
- no disk-installed root or recovery image package manager;
- AHCI is not a retained persistence backend.

## Priority 3 — security and hardware robustness

**Verdict: mostly open; threat boundaries are now documented.**

Delivered foundations:

- private CR3 spaces, user/supervisor separation, NX and W^X;
- pointer validation and process fault containment;
- guarded userspace stack regions;
- bounded process, descriptor, socket, mapping and page resources;
- exact allocator and lifecycle cleanup gates;
- `docs/THREAT-MODEL.md` now states assets, trust assumptions, attacker abilities, mitigations, known gaps and security acceptance conditions.

Security work still open:

- real UID/GID identity and ownership-aware VFS permissions;
- capability enforcement across all syscalls;
- complete signal permission/delivery/return;
- SMEP/SMAP and kernel W^X audit;
- ASLR/KASLR;
- protected kernel stacks and stack canaries;
- IOMMU/DMA isolation;
- cross-resource pressure and OOM policy;
- comprehensive pointer/parser fuzzing;
- executable/package trust and signing.

Hardware work still open:

- documented physical Intel and AMD boots;
- normal use of RAM above 4 GiB;
- multiple controllers, namespaces and NICs;
- USB hubs and broader HID devices;
- device timeout/reset recovery;
- ACPI shutdown/reboot;
- interrupt-routing variations;
- per-device DMA constraints.

Graceful diskless normal recovery is now delivered and tested; broad physical-hardware recovery is not.

## “Usable hobby OS” acceptance gate

ZigOs should not claim this gate until one normal permanent session can mount a writable disk root, preserve files across reboot, install an independently supplied ELF, run userspace PID 1 and an interactive userspace shell, use a real TTY, run and reclaim substantially more than the bounded fixture workload, use RAM above 4 GiB, block/wait/signal/reap correctly, expose a versioned compatibility policy, provide userspace networking and pass repeated stress/malformed-input sessions on at least one documented Intel and one documented AMD machine.
