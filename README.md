# ZigOs

[![Build ZigOs](https://github.com/adybag14-cyber/ZigOs/actions/workflows/build.yml/badge.svg)](https://github.com/adybag14-cyber/ZigOs/actions/workflows/build.yml)

ZigOs is an experimental x86 operating system written in freestanding Zig and hand-written assembly. The primary target is an x86-64 UEFI kernel; a separate legacy BIOS/i686 kernel provides a smaller persistent FAT12 userspace environment.

ZigOs is a research and learning system. It is not production-ready, POSIX-compatible, secure against hostile workloads, or broadly validated on physical hardware.

## Current release: Capstone 19.0

Capstone 19 connects the permanent x86-64 process table, descriptor layer and scheduler to genuine retained CPL3 contexts. `run`, `exec` and `spawn` now read ELF64 bytes from the VFS, map them into private CR3 address spaces and execute their entry points instead of creating timed pseudo-jobs. `crash` runs a real faulting executable, and `pipex` proves that permanent pipes block and wake real executables.

The release adds 32 verified goals to the inherited 465 x86-64 goals, reaching **497 cumulative goals (`0x1F1`)**:

```text
ZigOs x86-64 Capstone 19 verified: goals 0x000001F1 new-goals 0x00000020 vfs-elf yes private-cr3 yes retained-contexts yes timer-preemption yes real-fault yes executable-pipes yes frame-reclamation yes network-facades-removed yes cleanup yes
```

The exact contract and limitations are documented in [`docs/CAPSTONE-19.0.md`](docs/CAPSTONE-19.0.md). Capstone 18's descriptor contract remains an inherited release gate. The broader program remains separately tracked in [`docs/ROADMAP-500.md`](docs/ROADMAP-500.md); granular Capstone proof accounting is not conflated with the broader roadmap. The post-release audit disposition and tiered architecture plan are recorded in [`docs/PRIORITY-REMEDIATION.md`](docs/PRIORITY-REMEDIATION.md).

Local Windows validation is complete for the canonical build, all 97 unique isolated-test declarations, the source contract, the 54-command offline runtime, the 56-command live-network runtime, the x86-64 NVMe four-boot fsync/fdatasync persistence proof, persistent, quarantined-media, recoverable-read-error, persistent-write-error read-only-remount and diskless normal-boot profiles, and the legacy i686 two-boot regression. The required hosted workflow includes these gates plus cross-platform byte comparison.

## What runs after boot

The x86-64 kernel remains alive after validation unless an explicit `shutdown` command is entered. Its permanent runtime provides:

- a dedicated 100 Hz LAPIC timer and interrupt-enabled HLT idle loop;
- a permanent PID 1 record; in normal boot it runs the directly linked Zig `/bin/init.elf`, launches the interactive Zig PID 2 shell, waits for it and reaps it before final shutdown;
- a bounded writable VFS with an explicit parent-linked mount tree, six mounted namespaces, a retained read-only block-backed FAT16 `/boot`, a shared 256-page ordinary-file pool supporting zero-filled sparse holes, and a separate 16-page generation-keyed file-data LRU cache backed by post-bootstrap PMM pages, an eviction-safe per-inode dirty-page ledger, clean-only low-watermark pressure reclaim, one ticket lock per logical file page, generation-safe read-only shared-file mapping pins and a single-request asynchronous writeback worker;
- a generation-safe 64-slot process table whose ordinary round-robin service path owns foreground, background and fixture CPL3 dispatch without a second job table or direct shell dispatcher;
- process-local numeric descriptors, shared open-file descriptions and bounded blocking pipes;
- up to 64 retained CPL3 executable contexts backed by on-demand pages from a reclaiming post-bootstrap physical-memory manager and a 4,096-slot ownership table;
- private CR3 roots, strict W^X `PT_LOAD` mappings, eight-page stacks and unmapped guards;
- complete GPR and FXSAVE context preservation across syscalls and timer preemption;
- a pointer-validated ABI 1.12 with generated kernel Zig, NASM, public Zig and C interfaces, capability discovery, bounded `spawnv`, System V-style argv/envp/auxv startup, all-writable-mount `sync`, descriptor `lseek`/`fsync`/`fdatasync`/`fallocate`/`readv`/`writev`, path `stat`, `openat`, TTY `ioctl`, pathname mutation, sparse preallocation/hole punching, UDP datagram controls, exact waitpid, wait-any and WNOHANG;
- freestanding Zig and C SDKs with generated ABI structures, a SysV AMD64 startup/syscall shim, typed file/process/VM/poll/UDP/filesystem wrappers, a bounded DNS A resolver, environment/auxiliary helpers, a directly linked `/bin/init.elf`, and independently verified `/bin/sdk.elf`, `/bin/fs.elf`, `/bin/dns.elf` and `/bin/c-sdk.elf` conformance programs;
- an explicit `-Dnormal-boot=true` profile that skips the software proof suite, attaches `/bin/init.elf` to the reserved PID 1 handle, lets that CPL3 init supervise `/bin/sh.elf` as PID 2, and falls back to a tested RAM-root recovery session when no NVMe or SATA backend is usable;
- page-granular anonymous private `mmap`, generation-safe read-only file-backed `MAP_SHARED`, subrange `munmap`, W^X `mprotect` and expandable/shrinkable `brk`;
- descriptor-backed `fstat`, directory iteration and `poll`;
- eight descriptor/socket bookkeeping slots, with at most four simultaneously usable retained e1000e UDP endpoints, supporting bind, connect, send, receive, local/peer lookup, readiness and blocked-reader wakeup;
- real executable exit, sleep, preemption, fault containment, wait/reap and pipe block/wakeup;
- a retained bounded e1000e owner with real shell ICMP echo and DNS A queries when present, plus explicit offline status when absent;
- command parsing, bounded shell pipelines, descriptor-backed file redirection and history.

The default serial prompt is:

```text
root@zigos:/home/root#
```

### Runtime commands

```text
Filesystem and descriptors:
  pwd cd ls cat echo touch mkdir rm rmdir mv
  write append stat chmod mount df fds fdtest pipex sync fsck

Processes:
  ps jobs spawn kill wait crash sleep uptime elf exec run

Device and network status:
  devices ifconfig netstat sockets routes arp ping dns

Shell and utilities:
  env export unset history clear uname
  hash hexdump grep wc head shutdown
```

`run PATH [ARGS...]` and `exec PATH [ARGS...]` launch a foreground CPL3 child from VFS-resident ELF64 bytes. The current `exec` command does **not** replace the shell image in place. `spawn PATH [ARGS...]` launches the same retained executable model in the background. `/bin` remains boot-seeded RAM-VFS content, but the userspace shell can copy an ELF into `/persist`, mutate persistent files and directories through the versioned ABI, commit with `sync`, search `/bin:/persist`, and execute the restored NVMe-backed file after reboot.

`ping` and `dns` use the retained e1000e device for real bounded ICMP and UDP/DNS transactions when the network profile is present. `ifconfig`, `netstat`, `routes` and `arp` expose retained device state. With no e1000e device, all of these commands report explicit unavailability; none emits canned success, addresses or packets.

## Persistent-runtime validation

Run the bidirectional COM1 session:

```powershell
# Honest offline profile
.\scripts\test-runtime.ps1 -TimeoutSeconds 180

# Retained e1000e with real ping and DNS
.\scripts\test-runtime.ps1 -TimeoutSeconds 180 -Network
```

Each harness run boots the finished EFI image, waits for the permanent prompt and drives 54 commands offline or 56 commands with the live e1000e profile. It preserves the previous navigation, mutation, redirection, parser, descriptor, device, fsck, sync and history coverage, then additionally requires:

- `run` and `exec` to enter VFS-loaded CPL3 code;
- a real hardware-tick sleep and saved-context resume;
- a genuine vector-14 page fault with CR2 `0x8000180000`;
- a real CPL3 reader block and separate CPL3 writer wakeup;
- non-cooperative timer preemption of a background spin process;
- a genuinely blocking shell `wait` over a sleeping CPL3 child, default forced `kill` through signal 9, one-time reap, descriptor cleanup and frame cleanup;
- `/bin/wait.elf` spawning two VFS-backed CPL3 children and overlapping a 32-tick child and one-tick child to prove completion-ordered wait-any, exact waitpid and WNOHANG before exiting with status `0x31`;
- `/bin/vm.elf` proving ABI discovery, anonymous mapping, W^X protection changes, unmapping and heap-break growth/shrink before exiting with status `0x52`;
- `/bin/sdk.elf` proving startup vectors, errno mapping, core file/VM wrappers, coherent read-only shared file mapping across ordinary writes, close and unlink, both descriptor sync variants and bounded failure-atomic `readv`/`writev` gather/scatter semantics before exiting with status `0x56`;
- `/bin/io.elf` proving descriptor-backed open/read/fstat/getdents/poll before exiting with status `0x53`;
- `/bin/socket.elf` proving socket-level and per-call nonblocking `EWOULDBLOCK`, unconnected DNS `sendto`, blocking scheduler-woken `recvfrom` with source metadata, `getpeername`, connected send, poll and close before exiting with status `0x54`;
- `/bin/dns.elf` proving that an arbitrary directly linked Zig process can encode a DNS A request, use ABI 1.10 datagrams, retry nonblocking receive to a tick deadline, validate compressed response records and resolve `localhost` to `127.0.0.1` before exiting with status `0x5A`;
- `/bin/c-sdk.elf` proving ABI 1.12 generated C layouts and wrappers, writable `/dev/null` and `/dev/zero`, an openable `/dev/console`, TTY ioctl flags, path `stat`, directory-descriptor and absolute `openat`, descriptor `fsync`/`fdatasync`, `symlink`, `readlink`, loop rejection, hard-link identity/stat link counts, sparse preallocation/hole punching and failure-atomic `readv`/`writev` before exiting with status `0x57`;
- `/bin/init.elf` running as CPL3 PID 1, launching `/bin/sh.elf` through `spawnv`, waiting for PID 2, reaping it and issuing final shutdown;
- the normal userspace shell copying `/bin/sdk.elf` to `/persist/persist-sdk.elf`, committing it through syscall 97, resolving `persist-sdk` through `PATH=/bin:/persist` and receiving status `0x56`;
- the four-boot NVMe gate restoring and executing `/persist/persist-sdk.elf` after separate forced-termination `fsync` and `fdatasync` generations;
- the same gate committing eight boot-one records, preserving all eight through boot-two full-file `fsync` and boot-three data-only `fdatasync`, killing QEMU after each file commit, then proving the new data/size survives while dirty mode and unrelated sparse rewrites do not before cleaning to three boot-four records;
- `/bin/fs.elf` proving userspace `mkdir`, write, `lseek`, replacement rename over an open destination, chmod, persistent hard and symbolic links, sparse `fallocate`/hole punching, unlink-while-open with descriptor access and final-close reclamation, global sync, file-scoped `fsync`/`fdatasync`, crash recovery and cleanup from CPL3;
- the normal Zig shell exercising write, append, mkdir, rm, rmdir, mv and chmod without invoking the diagnostic kernel command implementation;
- real `10.0.2.2` ICMP and `localhost` DNS results in the network profile;
- explicit unavailable responses in the offline profile;
- root and nested reads from the retained NVMe FAT16 `/boot`, plus `stat` of the multi-mebibyte `BOOTX64.EFI` without copying its bytes into the RAM-file pool;
- absence of the former canned DNS and ping strings in permanent-runtime output.

Representative exact shutdown contracts are:

```text
# Offline
ZigOs persistent runtime shutdown: commands 54 failed 0
ZigOs persistent VFS: ... backing alloc/release/fail 50/50/0/0 ... mapped refs/pin/unpin/refresh/fail 0/1/1/1/0 ... page-write tickets/outstanding 186/0 ... clean yes
ZigOs persistent descriptors: ... dup/inherited/cloexec 2/56/1 ... clean yes
ZigOs boot FAT: block-backed yes files/directories 3/2 bytes 5573188 metadata/file/block reads 49/4/51 failures 0 clusters claimed/loop/cross/range 10889/0/0/0 lock tickets/outstanding 5/0 quarantine state/reason/events no/none/0 clean yes
ZigOs persistent storage: mounted yes generation/slot 1/0 ... NVMe read/write/flush .../2/2 errors 0/0 clean yes
ZigOs post-bootstrap physical memory: ... alloc/free 298/298 failed/rejected 0/0 clean yes
ZigOs permanent userspace: page-limit 4096 used 0 peak 48 contexts 0 file-mappings 0 launches/exits/faults 15/13/1 ... reclaimed 248 stale-contexts-swept 0 allocator alloc/release/retains 248/248/0 shared/oom/rejected 0/0/0 clean yes
ZigOs permanent network: device no ping 0 dns 0 failures 0 clean yes

# Live e1000e
ZigOs persistent runtime shutdown: commands 56 failed 0
ZigOs persistent VFS: ... backing alloc/release/fail 55/55/0/0 ... mapped refs/pin/unpin/refresh/fail 0/1/1/1/0 ... page-write tickets/outstanding 186/0 ... clean yes
ZigOs persistent descriptors: ... dup/inherited/cloexec 2/62/1 ... clean yes
ZigOs boot FAT: block-backed yes files/directories 3/2 bytes 5573188 metadata/file/block reads 49/4/51 failures 0 clusters claimed/loop/cross/range 10889/0/0/0 lock tickets/outstanding 5/0 quarantine state/reason/events no/none/0 clean yes
ZigOs persistent storage: mounted yes generation/slot 1/0 ... NVMe read/write/flush .../2/2 errors 0/0 clean yes
ZigOs post-bootstrap physical memory: ... alloc/free 334/334 failed/rejected 0/0 clean yes
ZigOs permanent userspace: page-limit 4096 used 0 peak 48 contexts 0 file-mappings 0 launches/exits/faults 17/15/1 ... reclaimed 279 stale-contexts-swept 0 allocator alloc/release/retains 279/279/0 shared/oom/rejected 0/0/0 clean yes
ZigOs permanent network: device yes ping 1 dns 1 failures 0 clean yes

# Normal userspace-shell profile
ZigOs normal userspace shutdown: init PID 1 status 0 shell PID 2 reaped yes
ZigOs boot FAT: block-backed yes files/directories 3/2 bytes 5521988 metadata/file/block reads 49/0/49 failures 0 clusters claimed/loop/cross/range 10789/0/0/0 lock tickets/outstanding 1/0 quarantine state/reason/events no/none/0 clean yes
ZigOs normal userspace resources: processes 1 descriptors 0 contexts 0 pages 0 alloc/free 129/129 cache-released 13 storage persistent clean yes
ZigOs normal boot verified: diagnostic-suite skipped yes userspace-init yes userspace-shell yes tty yes vfs yes spawn-wait yes storage persistent cleanup yes

# Cross-linked FAT16 quarantine profile
ZigOs boot FAT quarantined: cross_link; embedded read-only fallback mounted
ZigOs boot FAT: block-backed no files/directories 0/0 bytes 0 metadata/file/block reads 48/0/48 failures 0 clusters claimed/loop/cross/range 0/0/1/0 lock tickets/outstanding 1/0 quarantine state/reason/events yes/cross_link/1 clean yes
ZigOs normal userspace resources: processes 1 descriptors 0 contexts 0 pages 0 alloc/free 129/129 cache-released 13 storage persistent clean yes

# Recoverable NVMe read-error profile
NVMe one-shot read error armed: requested LBA 17319, command LBA 32768
cat: input/output error
ZigOs NVMe read fault injection: failures 1 armed no clean yes
ZigOs boot FAT: block-backed yes files/directories 3/2 bytes 5522500 metadata/file/block reads 50/3/51 failures 1 clusters claimed/loop/cross/range 10790/0/0/0 lock tickets/outstanding 4/0 quarantine state/reason/events no/none/0 clean yes
ZigOs normal userspace resources: processes 1 descriptors 0 contexts 0 pages 0 alloc/free 129/129 cache-released 13 storage persistent clean yes

# Persistent NVMe write-error read-only-remount profile
NVMe one-shot write error armed: requested LBA 18434, command LBA 32768
sync: input/output error
nvme-zigos-data on /persist type zigos_persist (ro)
write: read-only filesystem
sync: read-only filesystem
ZigOs NVMe write fault injection: failures 1 armed no clean yes
ZigOs persistent damage containment: damaged yes reason payload_write remounts/failures 1/0 discarded/rejected 1/1 vfs-remount/discard 1/1 mount-readonly yes clean yes
ZigOs boot FAT: block-backed yes files/directories 3/2 bytes 5522500 metadata/file/block reads 49/0/49 failures 0 clusters claimed/loop/cross/range 10790/0/0/0 lock tickets/outstanding 1/0 quarantine state/reason/events no/none/0 clean yes
ZigOs normal userspace resources: processes 1 descriptors 0 contexts 0 pages 0 alloc/free 58/58 cache-released 9 storage persistent-read-only clean yes

# Diskless normal RAM-root recovery profile
ZigOs boot FAT: block-backed no files/directories 0/0 bytes 0 metadata/file/block reads 0/0/0 failures 0 clusters claimed/loop/cross/range 0/0/0/0 lock tickets/outstanding 0/0 quarantine state/reason/events no/none/0 clean yes
ZigOs normal userspace resources: processes 1 descriptors 0 contexts 0 pages 0 alloc/free ... storage diskless-ram-root clean yes
ZigOs normal boot verified: diagnostic-suite skipped yes userspace-init yes userspace-shell yes tty yes vfs yes spawn-wait yes storage diskless-ram-root cleanup yes
```

Tick, switch and preemption totals vary slightly with host scheduling. Process states, exit/fault results, descriptor deltas, payload bytes and final cleanup are exact.

## Runtime VFS

The x86-64 runtime VFS currently provides:

- 96 bounded nodes;
- ordinary files up to 32 KiB;
- absolute and relative path resolution;
- repeated-separator, `.` and `..` normalization;
- files, directories and pseudo-files;
- create, replace, truncate, read, write, append and seek;
- directory creation and empty-directory removal;
- unlink and rename with cycle and cross-mount rejection;
- replacement rename over an existing same-mount file, including retained descriptors to the old destination;
- separate bounded dentries and link-counted nodes, with same-mount hard links sharing data and metadata;
- a separate 16-entry generation-validated dentry lookup cache with reference pinning, LRU eviction, mutation invalidation and authoritative fallback;
- parent-linked mounts with distinct mountpoint/root nodes, nested traversal, mounted-root `..`, canonical paths across boundaries and child-first unmount protection;
- relative and absolute symbolic links, non-following `readlink` and an eight-link traversal limit;
- immediate pathname removal with deferred reclamation while open descriptions still reference a file;
- directory-descriptor-relative `openat` and one shared VFS-to-ABI metadata conversion for `stat`/`fstat`;
- stat and chmod metadata;
- generation-safe VFS open handles used behind shared open-file descriptions;
- descriptor-backed read, write, seek and truncate operations, with per-inode ticket-locked append transactions across independent writers;
- descriptor quotas and structural integrity validation.

Mounted namespaces:

```text
/       ramfs       writable, lost at reboot
/boot   boot_fat    retained NVMe FAT16, read-only; embedded fallback when diskless
/proc   procfs      runtime process information
/dev    devfs       retained device information
/net    netfs       retained network information
/persist zigos_persist bounded NVMe A/B journal when available
```

The general root remains RAM-backed, while `/persist` is a writable NVMe-backed `zigos_persist` mount using alternating checksummed generations. Kernel and userspace `sync` paths write the payload, flush it, commit a FUA generation header and flush again. Regular files?including linked ELF64 programs up to the VFS limit?are restored into `/persist` and can be executed after reboot. On NVMe boots, `/boot` is the retained EFI FAT16 partition itself: bounded 8.3 directory metadata is imported into VFS, while file bytes are streamed on demand from the controller and logical backed-file sizes are excluded from RAM-resident byte accounting. Diskless recovery retains the previous embedded read-only `/boot` fallback.

## Runtime file descriptors and pipes

The permanent descriptor layer provides:

- 32 numeric descriptor slots per process and a global 96-entry open-description pool;
- readable fd 0 and writable fd 1/fd 2 terminal descriptions for the shell;
- deterministic lowest-free allocation;
- shared offsets and reference counts across `dup`, `dup2` and cloned namespaces;
- process-local close-on-exec flags and exact close-on-exec cleanup;
- regular-file read, write, seek and truncate operations, with append serialized from EOF selection through data, size and final offset updates;
- 32 bounded 1,024-byte circular pipes;
- reader blocking on empty pipes and writer blocking on full pipes;
- targeted scheduler wakeups, final-writer EOF and final-reader broken-pipe behavior;
- complete namespace, open-description, VFS-handle and endpoint reclamation;
- `fds` inspection and a repeatable live `fdtest` contract.

Ordinary `cat`, `write`, `append`, `<`, `>` and `>>` file paths use this layer. Shell pipeline stages still exchange bounded intermediate buffers rather than live descriptor-connected processes, and general permanent CPL3 file syscalls remain future work.

## Runtime process table and executable contexts

The permanent process table now owns real executable lifecycle records. It provides:

- 64 recyclable process slots and monotonic PIDs;
- generation-tagged handles and parent/current-directory metadata;
- runnable, running, sleeping, blocked, stopped, zombie and faulted states;
- bounded round-robin scheduling, hardware-tick accounting and targeted wakeups;
- waits, terminal status, one-time reaping and PID 1 adoption;
- directed/process-group signals and basic UID permission checks;
- page, descriptor, socket, child and CPU quotas;
- fault vector/address records derived from genuine CPL3 exceptions.

The permanent executor supports up to 64 retained CPL3 process slots and 1,024 tracked mappings per context. After boot validation, the monotonic allocator is sealed and every remaining usable firmware extent is transferred to a reclaiming physical-memory manager. The executor requests pages on demand below 4 GiB through a 256-slot ownership table; final releases poison pages, return them to the manager and require exact ownership-layer and physical-manager allocation/free balance at shutdown. Each process receives a private CR3, a complete saved integer/FX context, an eight-page stack, an unmapped guard page and cloned descriptor namespace. Untouched extents above 4 GiB are retained and counted, but ordinary runtime use of them awaits a direct physical-memory map.

This is still not a general POSIX process implementation. There is no persistent-runtime fork/COW, in-place exec, dynamic linker, flexible stack growth, ASLR, SMP userspace scheduler, or unified task object combining process metadata with saved architecture context.

## Existing bounded x86-64 capabilities

Before entering the permanent runtime, the x86-64 kernel still runs its inherited assertion-heavy integration suites. These include:

- UEFI handoff, memory-map normalization, frame allocation and kernel-owned paging;
- higher-half aliases, GDT, TSS, IDT, IST stacks and exception recovery;
- local APIC, I/O APIC, HPET/ACPI PM/PIT timing and SMP startup;
- PCIe/legacy PCI discovery;
- NVMe, AHCI, xHCI, PS/2, framebuffer and COM1 paths;
- Intel 82574L/e1000e DMA and MSI-X operation;
- bounded DHCP, ARP, IPv4, ICMP, UDP, TFTP, DNS, NTP and TCP components;
- CPL3 transitions and an `int 0x80` service ABI;
- ELF64 parsing, private address spaces, copy-on-write fork, static-image exec, demand mapping, signals, pipes, waits and contained faults.

These components are validated against deterministic QEMU scenarios. They are not a production network stack or a general POSIX process environment.

A precise networking description is:

> ZigOs retains one bounded e1000e device into the permanent runtime. The shell performs real ICMP echo and DNS A queries, while ABI version 1 exposes a bounded descriptor-backed UDP socket subset. The broader NTP/TCP components remain assertion-heavy kernel mechanisms rather than a production network stack.

## Legacy BIOS/i686 path

The legacy path boots through a native 512-byte BIOS stage 0, an eight-sector stage 1 and an ELF32/freestanding Zig kernel. Its bounded environment includes:

- protected mode, E820 memory information, paging and heap allocation;
- PIC, PIT, PS/2 and COM1 interrupt handling;
- ATA PIO and writable FAT12;
- disk-loaded ELF32 CPL3 programs;
- process scheduling, fork/exec, waits, signals and fault containment;
- persistent file creation and a two-boot filesystem verification sequence.

Capstone 19 does not change the legacy functional contract. The complete i686 build and two-boot persistence regression remain required release gates.

## Requirements

### Build only

- Python 3
- NASM 2.16 or newer
- Internet access for the first checksum-pinned canonical Zig download

Supported build hosts:

- Windows x86-64 through PowerShell
- Linux x86-64 through POSIX shell
- Linux AArch64 through POSIX shell

The exact compiler revision is stored in `.toolchain-version`:

```text
0.17.0-dev.1420+5d08e4716
```

The scripts refuse to use a different Zig version silently.

### Integration tests

- QEMU x86-64/i386
- split OVMF/EDK2 code and variable-store images for UEFI tests
- PowerShell for the current hardware integration harnesses

## Build

### Standard Zig build graph

With the exact pinned Zig already available as `zig`:

```text
zig build
zig build test
zig build check
zig build assets
```

`zig build` generates all assembly/ELF assets, builds the UEFI application and installs:

```text
zig-out/
|-- EFI/
|   `-- BOOT/
|       `-- BOOTX64.EFI
`-- artifacts/
    |-- service-user.elf
    |-- process-user.elf
    |-- process-exec.elf
    |-- sdk.elf
    |-- init.elf
    |-- sh.elf
    |-- fs.elf
    |-- dns.elf
    |-- c-sdk.elf
    `-- runtime-*.elf
```

`zig build test` executes the canonical host-test graph covering 97 unique `std.testing` declarations, including the dedicated ReleaseSafe NVMe completion-recovery target alongside descriptors, commands, processes, TTY, VFS, ABI, page ownership, persistence, ELF loading and the DNS codec. Imported tests may execute from more than one root, but the source contract counts each declaration once.

`zig build check` runs formatting, all isolated tests, the UEFI build and portable PE/COFF verification.

### Windows wrapper

```powershell
.\scripts\build.ps1
.\scripts\build.ps1 -Clean
.\scripts\build.ps1 -Optimize Debug
.\scripts\build.ps1 -Optimize ReleaseSafe
.\scripts\build.ps1 -Optimize ReleaseFast
.\scripts\build.ps1 -Optimize ReleaseSmall
```

### Linux wrapper

```sh
./scripts/build.sh
./scripts/build.sh test
./scripts/build.sh check
```

The Linux bootstrap supports x86-64 and AArch64 and verifies the downloaded archive SHA-256 before extraction.

### Make targets

```sh
make build
make assets
make test
make check
make clean
```

### Legacy i686

```powershell
.\scripts\build-legacy-i686.ps1
.\scripts\test-legacy-i686.ps1 -TimeoutSeconds 120
```

## Artifact identity

Capstone 19 reference UEFI image:

```text
Size:    5,573,120 bytes
SHA-256: F0017D676B27963B0D91502748FF3D86B168E84EF5E2C8C4954DD3A2F91A56CD
```

This identity is from the locally validated Windows diagnostic ABI 1.12 build with the Zig/C SDK, per-node device operations, diskless recovery, directory-relative `openat`, unified `stat`/`fstat` metadata and deferred open-file unlink reclamation, persistent bounded symbolic-link traversal, hard-link identity, reference-counted dentry-cache cleanup, parent-linked nested mount roots, per-inode ticket-locked atomic append, a shared sparse-file block pool with persistent allocation maps, failure-atomic bounded `readv`/`writev`, transactional file-scoped `fsync`, data-only `fdatasync` with committed-mode preservation for stable committed paths, transactional global `sync` that prevalidates and visits every writable mount, treats RAM filesystems as immediately synchronized, commits the configured persistent mount once, skips read-only mounts and rejects unsupported writable backends before journal I/O, and a separate bounded 16-page file-data cache keyed by inode generation and logical page, with inode-serialized reads, sparse-zero page caching, LRU replacement, write-through mutation invalidation, an independent one-byte-per-inode dirty-page bitmap that survives cache eviction, target-only fsync/fdatasync clearing, with RAM-backed regular files clearing immediately and persistent files clearing only after journal success; all-writable-mount global clearing after commit success, rejected-plan dirty-state retention, read-only mount baseline adoption, zero-dirty/zero-outstanding-lock shutdown gates, and an explicit generation-tagged asynchronous writeback request serviced at most once per runtime pass, with scheduling/completion separation, RAM-backed immediate completion, persistent data-only A/B journal commits and explicit busy/stale/unsupported/failure accounting. Busy, stale and unsupported outcomes retain dirty state; a real persistent journal write or flush error instead records the failed stage, remounts the exact `/persist` mount read-only once, discards its unsynced dirty ledger, preserves readable live bytes and the running Store's prior committed baseline, and rejects later mutations or synchronization with `EROFS`. A header-flush error occurs after an FUA header write, so disk durability is indeterminate: reboot recovery selects whichever valid generation is newest rather than promising the prior one. Cache page bytes are independently allocated from the post-bootstrap physical-memory manager rather than embedded in the VFS object; runtime service performs bounded low-watermark checks, evicts only clean LRU entries, retains dirty resident pages and the independent ledger, and releases every remaining clean cache page before final PMM accounting. The required diagnostic sessions force the same reclaim path and prove four physical pages returned while dirty pages remain synchronized only by writeback or sync. Every inode also owns eight logical-page writer ticket locks. Ordinary writes lock only affected pages; replacement writes conservatively lock all pages; truncate, preallocation, hole punching and sparse restoration lock their affected page sets in ascending order and release in reverse. A four-thread host test performs 128 writes into disjoint regions of one cached page and requires exact 128/128 page/inode lock ticket deltas, intact final regions and zero outstanding locks; QEMU reports 186 page-write tickets and zero outstanding in both diagnostic profiles after the three former RAM-copied `/boot` fixtures were replaced by block-backed files. The existing whole-inode lock remains outside these page locks for EOF selection, allocation, size and descriptor-offset consistency, so this does not claim concurrent writes to different pages. The retained EFI GPT partition is now mounted as a real read-only FAT16 backend. It imports bounded short-name metadata (32 files, 24 directories, depth 8), caches FAT sectors, streams large file data through one ticket-locked block buffer, and reports metadata/file/block reads and failures. Mount validation first scans into bounded staging tables, follows every imported file and directory chain through EOC, and claims each cluster in one global ownership bitmap; only after the complete scan succeeds are VFS dentries published. A revisit within the current chain is a loop, reuse by a different chain is a cross-link, and invalid current or next cluster values are classified as out-of-range. Healthy diagnostic profiles claim 10,889 clusters with exact loop/cross/range counters `0/0/0`, persistent normal claims 10,789 clusters for its smaller EFI profile, and diskless fallback reports no backend ownership. For classified loop, cross-link, range or generic FAT-structure corruption, staging is erased, one quarantine reason/event is retained, and an embedded read-only `/boot` fallback is mounted. Mount-time device/I/O failures remain fatal rather than being mislabeled as corruption. Runtime backed-file read failures instead propagate as VFS `InputOutput` and ABI `EIO`; `read` and `readv` temporarily activate the kernel address space for descriptor I/O, restore the exact process CR3 before userspace copies, preserve the caller buffer and open-description offset on failure, and permit retry. Every phase-valid NVMe completion, including an error, advances and acknowledges the completion queue before status classification. A private-prefix required QEMU profile places `README.TXT` at fixed LBA 17319 and replaces its first valid request with one real out-of-range NVMe command, observes `cat: input/output error`, then reads the file successfully on retry with exact one-failure telemetry and clean 129/129 resource balance. A second private-prefix QEMU profile targets the first slot-A payload sector at LBA 18434, substitutes one real out-of-range NVMe write command, observes the triggering global `sync` as `EIO`, then proves `/persist` appears read-only through `/proc/mounts`, retained data remains readable, write/append/create/remove and later sync return `EROFS`, the remount/discard counters conserve exactly `1/1`, and shutdown balances 58/58 physical allocations with storage labeled `persistent-read-only`. A required QEMU image cross-links only `BOOT.CFG` to `README.TXT`, proves no corrupted FAT names were published, observes exact `48/0/48` preflight reads and `0/0/1/0` loop/cross/range state, and completes normal shutdown with 129/129 physical allocation balance. This is quarantine, not repair, and does not promise rollback if a later unrelated VFS resource failure occurs during post-validation publication. Long-file names, FAT writes, mirror verification, automatic repair and general FAT fsck remain open. ABI 1.12 additionally maps readable regular-file descriptors through generation-tagged, read-only `MAP_SHARED` pages borrowed directly from the PMM-backed VFS cache. Open-description access is authoritative: the CPL3 proof opens the descriptor before changing the pathname to mode `000`, then maps a 13-byte partial final page and continues to write through the retained writable descriptor. Mapping pins prevent cache pressure, ordinary LRU replacement and unlink reclamation from releasing the page; ordinary file writes refresh the same physical page, and final unmap balances the pin and permits deferred inode reclamation. The required CPL3 Zig fixture observes initial bytes, an ordinary-write update, file-read equality and post-close/post-unlink lifetime, while both diagnostic profiles report exact mapped refs/pin/unpin/refresh/fail `0/1/1/1/0` and all profiles finish with zero mapped file pages. Writable file mappings, file-backed `MAP_PRIVATE`, `msync` and mapped-write persistence remain open. Hosted CI now downloads the Linux and Windows artifact sets into one required job and compares every path byte-for-byte.

## QEMU validation

Reduced fallback profile:

```powershell
.\scripts\test-qemu.ps1 -NoHpet -NoPs2 -CpuCount 1 -NoUsbKeyboard -NoGraphics -TimeoutSeconds 120
```

Network-enabled hosted-stable profile:

```powershell
.\scripts\test-qemu.ps1 -Network -NoHpet -NoPs2 -CpuCount 1 -NoUsbKeyboard -NoGraphics -TimeoutSeconds 180
```

Persistent post-boot runtime:

```powershell
.\scripts\test-runtime.ps1 -TimeoutSeconds 180

# Required live-network permanent-shell profile
.\scripts\test-runtime.ps1 -TimeoutSeconds 180 -Network

# Normal profile: real Zig userspace PID 1 supervising the PID 2 shell
python .\scripts\test-normal-boot.py --boot-timeout 240

# Diskless recovery: USB boot, no usable NVMe/SATA, RAM-backed root
python .\scripts\test-diskless-normal-boot.py --skip-build --boot-timeout 240

# Persistent journal write failure: fail-stop /persist read-only remount
python .\scripts\test-persistent-readonly-remount.py --boot-timeout 240
```

Additional switches include `-CpuCount`, `-LegacyPci`, `-NvmeOnly`, `-Nvme4k`, `-LegacyAhci`, `-HighApicId`, `-SparseApicIds`, `-NoX2Apic`, `-NoGraphics`, `-NoUsbKeyboard` and `-UsbMouseOnly`.

## Continuous integration

The workflow contains two required implementation paths:

- **Portable Linux:** clean bootstrap, asset generation, formatting, 97 unique isolated declarations, directly linked Zig/C SDK, init, shell and DNS verification, x86-64 UEFI build, portable PE verification and artifact upload.
- **Windows integration:** clean build, isolated checks, reduced fallback boot, a uniprocessor serial-only network profile, the 54-command offline and 56-command live-network permanent COM1 sessions, the x86-64 NVMe four-boot fsync/fdatasync proof, persistent, cross-linked quarantine, recoverable NVMe read-error, persistent write-error read-only-remount and diskless normal boots, and the legacy i686 build/two-boot regression.
- **Cross-platform identity:** download both artifact sets and require identical relative paths and byte-for-byte contents. Broader SMP, graphics and USB combinations remain extended local gates.

A green badge therefore represents substantially more than the former reduced single-boot profile.

## Repository layout

```text
build.zig                         canonical x86-64 build graph
build.zig.zon                     package identity and minimum Zig revision
Makefile                          conventional POSIX targets
.github/workflows/build.yml       Linux and Windows CI matrix
.toolchain-version                exact canonical Zig revision
VERSION                           release version

docs/CAPSTONE-19.0.md            exact permanent-userspace release contract
docs/CAPSTONE-18.0.md            inherited descriptor release contract
docs/CAPSTONE-17.0.md            inherited permanent-runtime contract
docs/ROADMAP-500.md              500-goal general-OS program
docs/PRIORITY-REMEDIATION.md     audit disposition and tier plan
docs/THREAT-MODEL.md             current trust boundary, mitigations and security gaps
docs/ROADMAP.md                  historical milestone record

scripts/build-assets.py           portable generated-asset pipeline
scripts/verify-efi.py             portable PE/COFF verifier
scripts/verify-permanent-userspace.py source/release contract verifier
scripts/create-runtime-user-elf.py deterministic permanent ELF generator
scripts/verify-runtime-user-elf.py independent permanent ELF verifier
scripts/bootstrap-toolchain.sh    checksum-pinned Linux bootstrap
scripts/build.sh                  Linux zig-build wrapper
scripts/build.ps1                 Windows zig-build wrapper
scripts/test-runtime.ps1          bidirectional persistent COM1 test
scripts/test-diskless-normal-boot.py USB-booted RAM-root recovery gate
scripts/test-qemu.ps1             x86-64 hardware/network test matrix
scripts/build-legacy-i686.ps1     legacy BIOS/i686 build
scripts/test-legacy-i686.ps1      legacy two-boot persistence test

src/main.zig                      UEFI entry and firmware handoff
src/kernel.zig                    post-UEFI integration and inherited gates
src/runtime.zig                   permanent x86-64 runtime and command dispatch
src/runtime_user.zig              retained CPL3 executor and syscall/fault bridge
src/runtime_vfs.zig               bounded VFS and mount model
src/runtime_fd.zig                numeric descriptors, shared descriptions and pipes
src/runtime_process.zig           generation-safe process table
src/runtime_command.zig           parser, environment and line editor
sdk/c/include/zigos.h             generated public C ABI
sdk/c/zigos.c                     freestanding C syscall wrapper library
src/arch/x86_64/cpu.asm           instruction, interrupt and context entries
src/descriptor_tables.zig         GDT, TSS, IDT and permanent runtime gate setup
src/apic.zig                      LAPIC control and runtime clock
src/serial.zig                    COM1 transmit and receive
```

## Current limitations

- `/bin` is boot-seeded RAM-VFS content; executable files are not yet fetched from a disk-backed filesystem at launch.
- Permanent execution accepts only the strict static x86-64 `ET_EXEC` layouts supported by `elf64.zig`; there is no `ET_DYN`, dynamic linker or relocation support.
- The permanent executor is bounded to 64 contexts, 1,024 mapping records per context, a fixed eight-page stack and bounded output buffers.
- The shell `exec` command launches a foreground child instead of replacing the shell process image.
- Fork, copy-on-write, demand paging, writable/private file mappings and flexible guard-fault stack growth are not implemented; startup environment and auxiliary vectors are bounded rather than general.
- Shell pipeline stages still exchange bounded kernel buffers; `pipex` is the real executable pipe proof rather than a general process pipeline.
- The writable x86-64 root filesystem is RAM-backed and does not survive reboot; `/boot` is read-only FAT16 with bounded 8.3-name import and no LFN, write, mirror-repair or filesystem-checking support.
- The userspace network ABI is UDP-only, with eight descriptor bookkeeping slots but four active e1000e hardware endpoints and fixed receive queues. It supports connected and unconnected datagrams, source-address receive, peer inspection, poll and socket-level/per-call nonblocking receive, but there is no TCP listen/accept/data API, general socket-option layer, IPv6 or production network stack.
- Permanent userspace scheduling currently runs on the BSP rather than an SMP scheduler.
- Hardware support remains strongly aligned with QEMU q35, QEMU NVMe/xHCI and Intel 82574L emulation.
- ABI version 1.12 provides generated Zig/NASM/C syscall interfaces, bounded startup/spawn vectors, capability discovery and errno conventions, but it is still experimental: there is no formal compatibility guarantee, complete user/group permission model, ASLR, IOMMU DMA isolation or executable-signing policy.
- ZigOs remains experimental, non-POSIX and not secure against hostile workloads.

## Design principles

- Use assembly only where exact machine control is required.
- Keep policy, parsing and subsystem logic in readable Zig.
- Never depend silently on UEFI services after firmware handoff.
- Pin and verify the compiler and generated assets.
- Distinguish bounded validation components from general production interfaces.
- Prefer isolated unit tests plus end-to-end QEMU proofs.
- Treat every interrupt, DMA completion, page transition and on-disk mutation as something to verify.

## License

ZigOs is released under the [MIT License](LICENSE).
