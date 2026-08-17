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

Local Windows validation is complete for the canonical build, 248/248 canonical host-test executions across all 102 unique isolated-test declarations, the source contract, the 54-command offline runtime, the 56-command live-network runtime, the x86-64 NVMe four-boot fsync/fdatasync persistence proof, persistent, quarantined-media, recoverable-read-error, persistent-write-error read-only-remount and diskless normal-boot profiles, and the legacy i686 two-boot regression. The required hosted workflow includes these gates plus cross-platform byte comparison.

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
- a pointer-validated ABI 1.26 with generated kernel Zig, NASM, public Zig and C interfaces, capability discovery, bounded `spawnv`, System V-style argv/envp/auxv startup, all-writable-mount `sync`, root-gated empty-target `tmpfs` `mount`/`umount`, path-based `statfs` and four-field `stattimes`, descriptor `lseek`/`fsync`/`fdatasync`/`fallocate`/`readv`/`writev`, path `stat`, `openat`, TTY `ioctl`, pathname mutation, sparse preallocation/hole punching, UDP datagram controls, exact waitpid, wait-any and WNOHANG;
- freestanding Zig and C SDKs with generated ABI structures, a SysV AMD64 startup/syscall shim, typed file/process/VM/poll/UDP/filesystem wrappers, a bounded DNS A resolver, environment/auxiliary helpers, a directly linked `/bin/init.elf`, and independently verified `/bin/sdk.elf`, `/bin/fs.elf`, standalone `/bin/ls.elf`, `/bin/cat.elf`, `/bin/echo.elf`, `/bin/pwd.elf`, `/bin/mkdir.elf`, `/bin/rm.elf`, `/bin/rmdir.elf`, `/bin/mv.elf`, `/bin/cp.elf`, `/bin/stat.elf`, `/bin/hexdump.elf`, `/bin/ps.elf`, `/bin/kill.elf`, `/bin/sleep.elf`, `/bin/head.elf`, `/bin/tail.elf`, `/bin/wc.elf`, `/bin/grep.elf`, `/bin/dns.elf` and `/bin/c-sdk.elf` programs;
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

`run PATH [ARGS...]` and `exec PATH [ARGS...]` launch a foreground CPL3 child from VFS-resident ELF64 bytes. The current `exec` command does **not** replace the shell image in place. `spawn PATH [ARGS...]` launches the same retained executable model in the background. `/bin` remains boot-seeded RAM-VFS content, but the userspace shell can copy an ELF into `/persist`, mutate persistent files and directories through the versioned ABI, commit with `sync`, search `/bin:/persist`, and execute the restored NVMe-backed file after reboot. G258 makes foreground execution status-bearing: the shell retains the exact 32-bit `wait` exit status from external children, successful builtins produce 0, builtin/runtime failures produce 1, usage failures produce 2, and command lookup failure produces 127. The `status` builtin prints the previous parsed command status and itself succeeds. G259 consumes that authoritative status channel for bounded `&&`/`||` conditional lists, and G260 now adds bounded left-to-right semicolon sequencing across those lists. G267 adds bounded shell-local `NAME=VALUE` assignment: retained overrides immediately affect `PATH` lookup and are merged into every subsequently spawned child environment. G268 adds bounded command substitution for exact argument tokens of the form `$(PROGRAM)`, capturing at most 31 bytes through a real kernel pipe before executing the outer command.

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
- `/bin/sdk.elf` proving startup vectors, errno mapping, core file/VM wrappers, coherent read-only shared file mapping across ordinary writes, close and unlink, both descriptor sync variants, bounded failure-atomic `readv`/`writev`, and isolated writable/read-only `tmpfs` mount/unmount with descriptor and working-directory `EBUSY` protection before exiting with status `0x56`;
- `/bin/io.elf` proving descriptor-backed open/read/fstat/getdents/poll before exiting with status `0x53`;
- `/bin/socket.elf` proving socket-level and per-call nonblocking `EWOULDBLOCK`, unconnected DNS `sendto`, blocking scheduler-woken `recvfrom` with source metadata, `getpeername`, connected send, poll and close before exiting with status `0x54`;
- `/bin/dns.elf` proving that an arbitrary directly linked Zig process can encode a DNS A request, use ABI 1.10 datagrams, retry nonblocking receive to a tick deadline, validate compressed response records and resolve `localhost` to `127.0.0.1` before exiting with status `0x5A`;
- `/bin/c-sdk.elf` proving ABI 1.23 generated C layouts and wrappers, writable `/dev/null` and `/dev/zero`, an openable `/dev/console`, TTY ioctl flags, path `stat`/`statfs`/`stattimes`/`statowner`, directory-descriptor and absolute `openat`, descriptor `fsync`/`fdatasync`, `symlink`, `readlink`, loop rejection, hard-link identity/stat link counts, sparse preallocation/hole punching and failure-atomic `readv`/`writev` before exiting with status `0x57`;
- `/bin/init.elf` running as CPL3 PID 1, launching `/bin/sh.elf` through `spawnv`, waiting for PID 2, reaping it and issuing final shutdown;
- the normal userspace shell copying `/bin/sdk.elf` to `/persist/persist-sdk.elf`, committing it through syscall 97, resolving `persist-sdk` through `PATH=/bin:/persist` and receiving status `0x56`;
- the four-boot NVMe gate restoring and executing `/persist/persist-sdk.elf` after separate forced-termination `fsync` and `fdatasync` generations;
- the same gate committing eight boot-one records, preserving all eight through boot-two full-file `fsync` and boot-three data-only `fdatasync`, killing QEMU after each file commit, then proving the new data/size survives while dirty mode and unrelated sparse rewrites do not before cleaning to three boot-four records;
- `/bin/fs.elf` proving userspace `mkdir`, write, `lseek`, replacement rename over an open destination, chmod, persistent hard and symbolic links, sparse `fallocate`/hole punching, unlink-while-open with descriptor access and final-close reclamation, global sync, file-scoped `fsync`/`fdatasync`, crash recovery and cleanup from CPL3;
- the normal Zig shell exercising write, append, mkdir, rm, rmdir, mv and chmod without invoking the diagnostic kernel command implementation;
- real `10.0.2.2` ICMP and `localhost` DNS results in the network profile;
- explicit unavailable responses in the offline profile;
- root and nested reads from the retained NVMe FAT16 `/boot`, plus `stat` of the multi-mebibyte `BOOTX64.EFI` without copying its bytes into the RAM-file pool;
- kernel-only fixed-capacity live registries publishing three device nodes, five kernel-state views and four network-state views, with exact conservation in every required QEMU profile;
- absence of the former canned DNS and ping strings in permanent-runtime output.

Representative exact shutdown contracts are:

```text
# Offline
ZigOs persistent runtime shutdown: commands 54 failed 0
ZigOs persistent VFS: ... backing alloc/release/fail 55/55/0/0 ... mapped refs/pin/unpin/refresh/fail 0/1/1/1/0 ... page-write tickets/outstanding 354/0 ... clean yes
ZigOs persistent descriptors: ... dup/inherited/cloexec 5/56/1 ... clean yes
ZigOs boot FAT: block-backed yes files/directories 3/2 bytes 5796420 metadata/file/block reads 113/4/115 failures 0 clusters claimed/free/loop/cross/range 11325/4786/0/0/0 lock tickets/outstanding 5/0 quarantine state/reason/events no/none/0 clean yes
ZigOs live pseudo filesystems: dev/proc/net registrations 3/5/4 publications 3/5/4 withdrawals 0/0/0 failures 0/0/0 clean yes
ZigOs persistent storage: mounted yes generation/slot 1/0 ... NVMe read/write/flush .../2/2 errors 0/0 clean yes
ZigOs post-bootstrap physical memory: ... alloc/free 308/308 failed/rejected 0/0 clean yes
ZigOs permanent userspace: page-limit 4096 used 0 peak 48 contexts 0 file-mappings 0 launches/exits/faults 15/13/1 ... reclaimed 253 stale-contexts-swept 0 allocator alloc/release/retains 253/253/0 shared/oom/rejected 0/0/0 clean yes
ZigOs permanent network: device no ping 0 dns 0 failures 0 clean yes

# Live e1000e
ZigOs persistent runtime shutdown: commands 56 failed 0
ZigOs persistent VFS: ... backing alloc/release/fail 60/60/0/0 ... mapped refs/pin/unpin/refresh/fail 0/1/1/1/0 ... page-write tickets/outstanding 354/0 ... clean yes
ZigOs persistent descriptors: ... dup/inherited/cloexec 5/62/1 ... clean yes
ZigOs boot FAT: block-backed yes files/directories 3/2 bytes 5796420 metadata/file/block reads 113/4/115 failures 0 clusters claimed/free/loop/cross/range 11325/4786/0/0/0 lock tickets/outstanding 5/0 quarantine state/reason/events no/none/0 clean yes
ZigOs live pseudo filesystems: dev/proc/net registrations 3/5/4 publications 3/5/4 withdrawals 0/0/0 failures 0/0/0 clean yes
ZigOs persistent storage: mounted yes generation/slot 1/0 ... NVMe read/write/flush .../2/2 errors 0/0 clean yes
ZigOs post-bootstrap physical memory: ... alloc/free 344/344 failed/rejected 0/0 clean yes
ZigOs permanent userspace: page-limit 4096 used 0 peak 48 contexts 0 file-mappings 0 launches/exits/faults 17/15/1 ... reclaimed 284 stale-contexts-swept 0 allocator alloc/release/retains 284/284/0 shared/oom/rejected 0/0/0 clean yes
ZigOs permanent network: device yes ping 1 dns 1 failures 0 clean yes

# Normal userspace-shell profile
ZigOs normal userspace shutdown: init PID 1 status 0 shell PID 2 reaped yes
ZigOs boot FAT: block-backed yes files/directories 3/2 bytes 5744708 metadata/file/block reads 112/0/112 failures 0 clusters claimed/free/loop/cross/range 11224/4887/0/0/0 lock tickets/outstanding 1/0 quarantine state/reason/events no/none/0 clean yes
ZigOs live pseudo filesystems: dev/proc/net registrations 3/5/4 publications 3/5/4 withdrawals 0/0/0 failures 0/0/0 clean yes
ZigOs normal userspace resources: processes 1 descriptors 0 contexts 0 pages 0 alloc/free 871/871 cache-released 13 storage persistent clean yes
ZigOs normal boot verified: diagnostic-suite skipped yes userspace-init yes userspace-shell yes tty yes vfs yes spawn-wait yes storage persistent cleanup yes

# Cross-linked FAT16 quarantine profile
ZigOs boot FAT quarantined: cross_link; embedded read-only fallback mounted
ZigOs boot FAT: block-backed no files/directories 0/0 bytes 0 metadata/file/block reads 49/0/49 failures 0 clusters claimed/free/loop/cross/range 0/0/0/1/0 lock tickets/outstanding 1/0 quarantine state/reason/events yes/cross_link/1 clean yes
ZigOs live pseudo filesystems: dev/proc/net registrations 3/5/4 publications 3/5/4 withdrawals 0/0/0 failures 0/0/0 clean yes
ZigOs normal userspace resources: processes 1 descriptors 0 contexts 0 pages 0 alloc/free 144/144 cache-released 13 storage persistent clean yes

# Recoverable NVMe read-error profile
NVMe one-shot read error armed: requested LBA 17319, command LBA 32768
cat: input/output error
ZigOs NVMe read fault injection: failures 1 armed no clean yes
ZigOs boot FAT: block-backed yes files/directories 3/2 bytes 5745220 metadata/file/block reads 113/3/114 failures 1 clusters claimed/free/loop/cross/range 11225/4886/0/0/0 lock tickets/outstanding 4/0 quarantine state/reason/events no/none/0 clean yes
ZigOs live pseudo filesystems: dev/proc/net registrations 3/5/4 publications 3/5/4 withdrawals 0/0/0 failures 0/0/0 clean yes
ZigOs normal userspace resources: processes 1 descriptors 0 contexts 0 pages 0 alloc/free 144/144 cache-released 13 storage persistent clean yes

# Persistent NVMe write-error read-only-remount profile
NVMe one-shot write error armed: requested LBA 18434, command LBA 32768
sync: input/output error
nvme-zigos-data on /persist type zigos_persist (ro)
write: read-only filesystem
sync: read-only filesystem
ZigOs NVMe write fault injection: failures 1 armed no clean yes
ZigOs persistent damage containment: damaged yes reason payload_write remounts/failures 1/0 discarded/rejected 2/1 vfs-remount/discard 1/2 mount-readonly yes clean yes
ZigOs boot FAT: block-backed yes files/directories 3/2 bytes 5745220 metadata/file/block reads 112/0/112 failures 0 clusters claimed/free/loop/cross/range 11225/4886/0/0/0 lock tickets/outstanding 1/0 quarantine state/reason/events no/none/0 clean yes
ZigOs live pseudo filesystems: dev/proc/net registrations 3/5/4 publications 3/5/4 withdrawals 0/0/0 failures 0/0/0 clean yes
ZigOs normal userspace resources: processes 1 descriptors 0 contexts 0 pages 0 alloc/free 64/64 cache-released 12 storage persistent-read-only clean yes

# Diskless normal RAM-root recovery profile
ZigOs boot FAT: block-backed no files/directories 0/0 bytes 0 metadata/file/block reads 0/0/0 failures 0 clusters claimed/free/loop/cross/range 0/0/0/0/0 lock tickets/outstanding 0/0 quarantine state/reason/events no/none/0 clean yes
ZigOs live pseudo filesystems: dev/proc/net registrations 3/5/4 publications 3/5/4 withdrawals 0/0/0 failures 0/0/0 clean yes
ZigOs normal userspace resources: processes 1 descriptors 0 contexts 0 pages 0 alloc/free 72/72 cache-released 15 storage diskless-ram-root clean yes
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
- ABI 1.13 root-only `mount`/`umount` for a distinct transient `tmpfs`: targets must be empty directories, only the read-only flag is accepted, unmount resolves an exact mounted root and returns `EBUSY` for child mounts, retained descriptors, referenced paths or any process working directory inside the mount; forced/lazy detach, arbitrary filesystem types, device-backed mounts and per-process mount namespaces are not implemented;
- ABI 1.14 `statfs` syscall 121 with a stable 64-byte Zig/C result: RAM root, tmpfs and zigos_persist expose one shared 256-page block pool and shared 96-node pool, pseudo filesystems report zero synthetic data blocks, real FAT16 reports independently scanned cluster totals/free space, and embedded fallback boot files report the shared RAM pool; `available_blocks == free_blocks` because quotas/reservations are not implemented;
- ABI 1.15 `stattimes` syscall 122 with a stable 32-byte Zig/C `FileTimes` result containing creation, modification, change and access ticks while retaining the 32-byte legacy `stat` layout; `/persist` journal v2 stores all four values in each namespace record, restores v1 records compatibly, and preserves exact shared-inode values across hard links; G238 defines the values as a boot-local 100 Hz counter with nominal 10 ms precision, valid same-tick ties and no wall-clock or cross-reboot-monotonic meaning, with successful data, metadata, namespace and access operations updating only their documented fields;
- ABI 1.16 `statowner` syscall 123 with a stable 8-byte Zig/C `FileOwner` result: VFS inodes store 32-bit owner UID/GID, userspace-created files/directories/symlinks inherit the creating process credentials, hard links retain one shared inode owner, and `/persist` journal v3 stores ownership alongside timestamps while reading v1/v2 records as `0:0`; G240 additionally enforces owner/group/other read, write and execute bits with owner-first/primary-group/other class selection, UID 0 administrative bypass, directory search and namespace-mutation checks, execute-gated process launch and owner-or-root chmod;
- ABI 1.17 `umask` syscall 124 stores one nine-bit process creation mask, returns the previous mask, rejects bits outside `0777` failure-atomically, inherits the mask across child spawn, and applies the mask exactly once to the low rwx bits of `open`/`openat(O_CREAT)` and `mkdir`; chmod, existing objects, hard links and fixed-mode symlinks are unchanged, and child spawn preserves the parent UID/GID;
- G242 keeps ABI 1.17 and extends stored inode mode metadata to `06777`: setuid `04000` and setgid `02000` survive creation, chmod, stat, hard links, journal restore and full fsync, while fdatasync retains the previously committed mode; umask masks only the low `0777`, and set-ID bits are deliberately inert at execution; spawn inherits caller UID/GID and never derives credentials from inode mode/owner metadata;
- G243 keeps ABI 1.17 and expands the validated stored mode to `07777` by adding sticky `01000`. Sticky survives creation, chmod, stat and journal restore. Ordinary parent write+execute checks still apply; when a sticky directory entry would actually be removed, the caller must additionally be UID 0, the directory owner or the victim inode owner. The rule covers unlink, empty-directory rmdir, rename source removal and destination replacement; a rename-to-itself remains a no-op because it removes nothing. Supplementary groups, `chown`, set-ID execution and setgid-directory GID inheritance remain open;
- ABI 1.18 syscall 125 `flock` adds advisory whole-file shared/exclusive/unlock operations with optional nonblocking acquisition. Locks are owned by the shared open description, so `dup` and cloned-process aliases share one lock and final-reference close releases it; independently opened hard-link aliases contend by inode generation. Shared locks coexist, exclusive locks conflict, nonblocking conflict returns `EWOULDBLOCK`, and blocking acquisition sleeps in the process table until unlock/final close wakes retry. Ordinary file I/O deliberately ignores advisory locks; lock state is not persisted, and G244 whole-file locks remain a separate advisory namespace from G245 byte-range locks;
- ABI 1.19 syscall 126 `lockrange` completes bounded advisory byte-range locking. Each shared open description owns up to eight normalized non-overlapping half-open `[start,start+length)` segments inside the 32 KiB file address space; `dup` and cloned processes share them, independently opened hard-link aliases contend by inode generation, and final-reference close/process teardown/reboot discard them. Shared overlaps coexist, exclusive overlaps conflict, adjacent equal modes merge, replacement/conversion preserves unaffected fragments, and partial unlock may split one segment. Nonblocking conflict returns `EWOULDBLOCK` without changing the caller's existing ranges; blocking conversion removes only the requested overlapping caller range before sleeping on the existing file-lock wait key. Ordinary I/O remains advisory-only, zero-length/out-of-range requests are rejected, and whole-file `flock` and byte-range locks intentionally do not conflict with each other;
- ABI 1.20 syscall 127 `watchdir` adds bounded directory-change notification descriptors. A watch is created from an already-open directory descriptor, starts at the current VFS mutation sequence rather than replaying boot history, is readable through fixed 64-byte Zig/C `DirectoryEvent` records, and becomes `POLLIN`-ready after successful create, link, symlink, mkdir, remove/rmdir or rename changes in that directory. Rename emits ordered `rename_from`/`rename_to` records and replacement may additionally report removal of the replaced destination. Each separately created watch has its own cursor, while `dup` and cloned-process aliases share one open-description cursor. Reads are nonblocking-by-contract and return `EWOULDBLOCK` when caught up. The VFS retains only 64 global events; a lagging watch receives an explicit overflow record before resuming from the oldest retained sequence. Watch descriptors are generation-safe, stale watched directories poll as error/hangup, ordinary file permissions and mutation authorization remain authoritative, and notification state is transient across final close/process teardown/reboot and is never written to the persistent journal;
- G247 keeps ABI 1.20 and centralizes pathname validation: user path payloads may be at most 255 bytes and each slash-delimited component at most 31 bytes. Exactly 255 bytes reaches ordinary resolution; byte 256 or any 32-byte component returns `ENAMETOOLONG` before lookup. C-string pathname syscalls use a dedicated user-path copier so inaccessible user memory remains `EFAULT` while an unterminated/overlong path is `ENAMETOOLONG`; length-delimited `spawn`/`spawnv` apply the same bounds, and rename/link prevalidate both pathnames while symlink validates both target and destination before namespace mutation;
- G248 keeps ABI 1.20 and adds deterministic model-based VFS fuzzing without changing the production runtime. Eight fixed 64-bit seeds drive 512 transitions each (4,096 total) across create/resolve/rename/replacement-rename/unlink plus guaranteed failure paths. Every seed must hit all 10 operation classes, all five source spellings, all four destination spellings and at least one successful rename, replacement rename and unlink. Accepted path spellings include absolute, repeated-slash, dot-component, root-relative and case-folded forms; every transition is followed by `Vfs.validate()`, a full 32-slot reference-model visibility/identity/generation/canonical-path sweep, node/dentry/file/directory conservation and drained transient-lock/reference checks. Failed missing-source, missing-parent, overlong-component, directory-unlink and file-over-directory operations must leave the model unchanged. The G248 release artifact was byte-identical to G247 at 5,633,536 bytes with SHA-256 `BD9B8A04A157CB64E2C0A4EEBFD67BA73674CCE639FC0BAC0D49BBA206221D5D`; its deliberately single-threaded namespace-fuzz boundary is supplemented by G249, while broader filesystem/directory fuzzing remains G414;
- G249 keeps ABI 1.20 and adds one coarse VFS namespace-operation ticket lock around the four target path operations `createOwned`, path-based `write`, `renameAs` and `unlinkAs`. Each operation acquires the lock before path resolution/mutation and releases it after the complete operation, preserving path-to-node lifetime while these four operations contend over shared bounded node, dentry and file-data allocators. The lock order is namespace-operation lock before inode/page/cache/data-pool locks, internal resolver helpers do not reacquire it, and `Vfs.validate()` requires the ticket queue to be fully drained. The existing four-thread append test now also starts four workers through one barrier; every worker performs 64 create -> 32-byte write -> rename -> unlink cycles in one shared directory. The built-in proof therefore requires exactly 1,024 namespace-operation lock tickets and mutations, zero outstanding tickets, and identical node/dentry/block/open-file counts before and after. Twelve additional ReleaseSafe repetitions exercised 12,288 target operations during local validation. This is not a claim that the entire VFS is SMP-safe: general unlocked readers plus mkdir/link/symlink/mount/unmount, descriptor-table, pseudo-registry, restore and other administrative state remain outside this coarse G249 serialization boundary;
- G250 keeps ABI 1.20 and extends the required x86-64 persistence gate with real 512-byte block corruption of the A/B journal after the existing four healthy/crash-recovery boots. The healthy image finishes at slot A generation 3 and slot B generation 4; two independent copies are then mutated with exactly one byte changed in exactly one block. The header case flips slot-B header byte 40 (the stored header CRC; measured LBA 18433), while the payload case flips byte 4 of slot B's first payload sector (measured LBA 18562). Host-side validation proves the older A header remains valid, the header-copy B CRC fails, and the payload-copy B header remains valid while its payload CRC fails. QEMU must then mount generation 3/slot 0, expose `survived-generation-one` but never rejected generation-4 data, report `recoveries=1` in both cases, distinguish `corrupt_headers=1` for header damage from `0` for payload damage, and leave the damaged image byte-for-byte unchanged during recovery. The test exposed and fixed a kernel accounting gap where a CRC-invalid payload was correctly rejected but did not increment `recoveries`; the mount selector now counts any present-but-rejected candidate. Both-slot loss, repair/rewrite policy and formal on-disk compatibility remain separate concerns, with G251 documenting the supported recovery contract;
- G251 keeps ABI 1.20 and makes [`docs/PERSISTENCE-COMPATIBILITY.md`](docs/PERSISTENCE-COMPATIBILITY.md) the canonical on-disk compatibility and recovery contract. The current writer emits v3, the current reader accepts only v1/v2/v3, global `sync` migrates readable v1/v2 generations to v3, and file-scoped durable updates remain v3-only until that migration. The document fixes the relative two-header/two-64-KiB-payload geometry, little-endian header/record layouts, CRC-32 coverage, record-kind encodings, payload-before-FUA-header commit order, candidate selection, write-failure guarantees and telemetry semantics. It explicitly forbids interpreting unknown versions as forward-compatible or an older kernel as a safe downgrade target, clarifies that `recoveries` can also mean selection between two healthy unequal generations, and states that semantic restore failure after a CRC-valid newest payload does not currently retry the older slot. G251 is documentation/verifier-only and does not change ABI or production runtime bytes;
- G258 keeps ABI 1.20 and completes shell exit-status propagation without adding new kernel interfaces. Every parsed command returns one `u32` shell status: foreground external commands propagate the exact `WaitStatus.exit_status`, successful builtins return 0, builtin/runtime failures return 1, usage errors return 2, and failed executable lookup returns 127. A dedicated `status` builtin reports the previous command value and then succeeds with 0. The required normal QEMU session proves `hello -> 42`, missing command `-> 127`, failed `cd -> 1`, and successful `pwd -> 0`, while PID 1 still reaps shell PID 2 with status 0. G259 consumes this status channel for `&&`/`||`; G260 now layers sequential semicolon lists over it, G267 adds bounded shell-local `NAME=VALUE` assignment and child-environment/PATH override propagation; G268 adds bounded command substitution and G269 now adds bounded final-component wildcard pathname expansion; tilde expansion remains G270;
- G259 keeps ABI 1.20 and implements bounded conditional execution with `&&` and `||`. The shell pre-parses the complete line into at most four commands before executing any segment, recognizes operators with or without surrounding spaces, and evaluates both operators at equal precedence from left to right. `&&` executes its right command only after status 0, while `||` executes its right command only after nonzero status; a skipped command neither runs nor changes the current status. Empty segments, leading/trailing operators, consecutive operators, too many commands or a segment exceeding the existing eight-word bound fail before side effects, print `syntax: invalid conditional list`, and set status 2. The required normal QEMU session proves success/failure short-circuiting, a mixed `missing && skipped || recovery` chain, adjacent operator syntax, skipped-output absence, syntax failure atomicity and final clean PID-1 reap. G260 now composes these conditional lists through semicolon sequencing;
- G260 keeps ABI 1.20 and implements bounded sequential command lists with semicolons. One input line is fully parsed before execution into at most four sequential lists; each list retains G259's four-command `&&`/`||` bound and eight-word command bound. Lists execute unconditionally from left to right across `;`, carrying the previous list's status into the next list so `missing;status` observes 127 before `status` itself returns 0. A normal trailing semicolon is accepted. Leading semicolons, empty middle lists such as `cmd;;next`, a fifth sequential list, or an invalid nested conditional list reject the whole line before its first side effect with the existing status-2 syntax error. The required normal QEMU gate proves ordered two-command output, execution after failure, cross-list status visibility, composition with a skipped `&&` branch, trailing-semicolon success, empty-list failure atomicity, overflow failure atomicity and clean PID-1 reap. Quoting/expansion remains later; G261 now adds bounded pipeline process-group formation while descriptor connectivity and foreground group control remain G262/G263;
- G261 advances the public ABI to 1.21 without adding a new syscall number. Existing syscall 96 `spawnv` retains its 32-byte `SpawnRequest`; two generated `u16` flags select either a new child-led pipeline process group or joining an existing sibling pipeline group, with the join PGID carried in syscall argument 2. The kernel validates the leader as a same-parent, same-session sibling with `pid == pgid`, assigns the group inside process construction before descriptors/context become runnable, rejects foreign/missing groups, and leaves the general process-group membership API G141 open. The Zig SDK exposes `spawnvNewProcessGroup` and `spawnvInProcessGroup`; the C header publishes the generated flags but no new C spawn wrapper is claimed. The shell now parses at most four external stages per `|` pipeline inside each existing G259 conditional operand. Multi-stage pipelines prevalidate all stages, reject builtins before spawning, create the first child as group leader, atomically join later stages, report `pipeline group <pgid> stages <n>`, reap the explicit child PIDs, and return the last stage exit status. The required normal QEMU gate proves `hello|hello` forms PGID 7 with two real CPL3 children and final status 42, while builtin/trailing-stage failures remain side-effect-free. G261 deliberately does **not** connect pipe descriptors, move the TTY foreground group, or implement process-group waiting; those remain G262 and G263;
- G262 advances the public ABI to 1.22 without adding a syscall number or changing the 32-byte `SpawnRequest`. A generated `PIPELINE_IO` spawn flag is valid only together with one of G261's restricted pipeline-group modes; syscall argument 3 packs optional inherited parent stdin/stdout pipe descriptors, using the generated `65535` sentinel to mean “retain the inherited standard stream.” After cloning the parent descriptor namespace, the kernel validates stdin as a readable pipe endpoint and stdout as a writable pipe endpoint, duplicates only those selected endpoints onto fd 0/1, closes every inherited child fd >= 3, and rolls the child back before context installation on any error. This remains deliberately narrower than a general spawn-actions or arbitrary descriptor-remapping interface. The Zig SDK exposes grouped pipeline-I/O spawn wrappers. The shell creates exactly N-1 bounded kernel pipes for an N-stage pipeline, closes each parent endpoint immediately after its last child inherits it, closes all remaining ends on partial failure, and still reaps explicit PIDs. The existing low-level diagnostic `pipex` proof remains live through dual-mode reader/writer fixtures. Required normal QEMU now proves `pipe-writer.elf|pipe-reader.elf` forms PGID 9, transfers the real eight-byte `PIPE-CPL` payload through the kernel pipe, returns status 0, and shuts down with no leaked descriptors or pipe endpoints. Foreground TTY process-group transfer and PGID-oriented waiting remain G263; general descriptor spawn actions remain outside this milestone;
- G263 advances the public ABI to 1.23 without adding a syscall number. Existing syscall 77 `wait` gains generated `NOHANG` and `PROCESS_GROUP` flag bits; group waits accept a nonzero PGID, select only direct children in that group, preserve terminal-completion ordering, block with an explicit group-target marker, and wake only when a matching child exits. Existing terminal `ioctl` gains generated get/set foreground-PGID requests. The TTY keeps one internal controller handle: normal boot transfers that controller from PID 1 to shell PID 2, and only the controller may query or change foreground ownership. It may select only its own PGID or a live direct-child group leader in the same session, so inherited terminal descriptors do not let pipeline children steal foreground control and general `setpgid`/session/control-terminal operations remain open. The Zig SDK exposes `waitProcessGroup`, `ttyForegroundProcessGroup` and `ttySetForegroundProcessGroup`. A fully spawned pipeline records shell PGID 2, moves the TTY to its pipeline PGID, reaps every child by group while retaining the last-stage status by PID, then restores and verifies PGID 2; partial-spawn failures still use pre-foreground explicit cleanup. Required normal QEMU proves `pipe-reader.elf|pipe-reader.elf` reaches foreground PGID 11 without returning a shell prompt, blocks for terminal input, receives echoed `TTYPIPE`, transfers the same eight bytes through the kernel pipe, restores foreground PGID 2 and returns status 0. G263 itself did not add background completion; G264 now provides bounded notifications and G265 running-job `fg`/`bg`; G266 now generates terminal interrupt/suspend keys; stopped-job resume and parent state-change notification remain G144-G146;
- G264 keeps ABI 1.23 and adds bounded background-job completion notifications entirely in the CPL3 shell. A trailing single `&` marks only the final fully prevalidated external pipeline as background while `&&` retains its G259 meaning; background builtins are rejected before execution, and general mid-line `&` sequencing is not claimed. The shell retains at most four jobs keyed by fixed slots, launches a one-stage job in a new process group without unnecessary pipe remapping, uses the existing G262 pipe-aware grouped spawn path for multi-stage jobs, and never transfers the TTY foreground away from shell PGID 2. While a job exists, the input loop multiplexes stdin readiness with one-tick sleeps and existing ABI 1.23 `WAIT_PROCESS_GROUP|NOHANG` reaping; when no job exists it falls back to the original blocking terminal read so TTY block/wakeup accounting remains intact. Completion preserves the final stage status by PID, emits `[slot] done <status>` without waiting for another user command, redraws the prompt, and does not overwrite the shell's previous-command status. Required normal QEMU launches `runtime-sleep.elf &`, proves the prompt returns before completion, sends no intervening command, observes autonomous `[1] done 7`, verifies `status` remains 0, and rejects `echo ... &` without executing the builtin. G265 now adds running-job `fg`/`bg`; G266 now generates terminal suspend events; stopped-job resume/notification remain G145-G146;
- G265 keeps ABI 1.23 and implements `fg [JOB]` / `bg [JOB]` directly over G264's four retained running-job slots. A one-digit slot 1-4 selects explicitly and an omitted operand selects the first active slot; invalid syntax returns status 2 and an empty slot returns status 1. `fg` uses the same shared foreground-group state machine as ordinary G263 pipelines: it records shell foreground ownership, transfers the selected PGID to the TTY, blocks in existing process-group wait until every retained direct child is reaped, preserves the final stage's exact status by PID, clears the slot, and restores/verifies shell ownership before returning that status. `bg` is deliberately idempotent for an already-running retained job: it leaves the PGID detached, returns 0 immediately, and G264's asynchronous reaper later emits the completion notification. There is still no userspace signal/continue syscall, so G265 does not pretend to resume a stopped job; G266 now provides terminal suspend-key generation, while stop/continue job-control policy, parent stop/continue notification and SIGCONT-style userspace resume remain G144-G146. The foreground code was factored so newly spawned pipelines and adopted jobs share one TTY/group-wait implementation, and informational pipeline banners no longer make process cleanup depend on console-write success. Required normal QEMU proves `runtime-sleep.elf &` followed immediately by `fg 1` suppresses the shell prompt until `sleep: after` and propagates status 7; a second `runtime-sleep.elf &` followed by `bg 1` returns the prompt before completion, later emits `[1] done 7`, and leaves status 0; `fg 4` returns 1 and `bg 0` returns 2. The shell remains 29,088 bytes under the unchanged 32 KiB VFS executable limit;
- G266 keeps ABI 1.23 and completes terminal interrupt/suspend key generation inside the kernel TTY line discipline without growing the CPL3 shell. With terminal signals enabled, Ctrl-C (`0x03`) retains its existing foreground-PGID interrupt path and default exit-130 behavior, while Ctrl-Z (`0x1A`) now clears the canonical edit buffer, increments a dedicated suspend counter, sends internal signal 19 to the current foreground PGID, stops every matching live process through the existing process-table signal path, and returns a distinct echo action rendered as `^Z`. Host proof is folded into the existing foreground-isolation TTY test: it edits one byte, injects Ctrl-Z, requires one signal and `State.stopped`, resumes the same group through the already-existing internal signal-18 path, requires `State.runnable`, verifies one suspend event, then re-runs Ctrl-C and still requires zombie status 130. Ordinary diagnostic QEMU reports `erase/interrupt/suspend/overflow 1/0/0/0`, proving the new counter is quiescent in normal operation. This milestone intentionally does not wake a shell group-wait on stop or expose userspace SIGCONT; parent stop/continue notification, stopped-job retention/resume and broader job-control semantics remain G144-G146. The shell remains byte-identical to G265 at 29,088 bytes;
- G267 keeps ABI 1.23 and implements bounded shell-local variable assignment without adding a syscall. A single-word `NAME=VALUE` command accepts identifiers beginning with a letter or underscore and continuing with letters, digits or underscores; each complete environment entry remains bounded by the existing 63-byte ABI limit. The shell retains at most four overrides, updates an existing name in place without consuming another slot, returns status 0 on success, status 1 when the fixed slot set is exhausted and status 2 for an overlong entry. Assigned `PATH` is authoritative for later command lookup. Every external spawn receives the inherited environment with matching names replaced and new names appended within the existing eight-entry ABI bound, so assignments deliberately act as exported shell state rather than POSIX unexported locals. Assignment words are rejected as background or pipeline stages before child creation; temporary prefix assignments, expansion, `export`/`unset` semantics and command substitution are not claimed. Required normal QEMU hides `hello` with `PATH=/missing`, proves the replaced PATH reaches `/bin/sdk.elf`, restores command lookup, updates that variable in place, fills the four-slot bound, rejects a fifth distinct variable and a background assignment, then launches `hello` successfully and shuts down with exact 344/344 allocation/free conservation. The ReleaseSmall shell remains 29,088 bytes under the fixed 32 KiB VFS executable limit; G268 provides bounded command substitution, G269 bounded wildcard pathname expansion and G270 bounded tilde expansion;
- G268 keeps ABI 1.23 and implements bounded command substitution entirely in the CPL3 shell. Substitution is deliberately limited to an argument token exactly shaped as `$(PROGRAM)`: the inner command is one external program name/path with no inner arguments, operators or nesting; command-name substitution is rejected, and the captured result is inserted as one argument with no word splitting. The shell creates a real kernel pipe, spawns the inner program with its current G267 merged environment and stdout remapped to the pipe, closes the parent writer, and captures at most the existing 31-byte argument limit. A full 31-byte capture is probed for one additional byte so overflow fails rather than truncating; overflow closes the reader and reaps the child. Nonzero child status, empty output after trimming trailing CR/LF, embedded NUL, lookup/I/O failure or overflow all fail the outer command with status 1 before it executes. Background and multi-stage pipeline prevalidation reject any substitution token before inner or outer child launch. Required normal QEMU captures `PIPE-CPL` from `pipe-writer.elf` into a `write` argument, proves `echo $(hello)` rejects the 34-byte output without leaking it to the terminal, and proves background/pipeline substitution rejection is side-effect-free. To retain the fixed 32 KiB VFS executable ceiling, G268 compacts help to one command-name line, unifies usage text, and preserves the externally contracted `not found`, `unsupported`, `input/output error` and `read-only filesystem` error classes while folding rarer diagnostics to `error`. ReleaseSmall `sh.elf` remains 29,088 bytes with a 24,316-byte RX segment; full quoting, nested substitutions, inner argument parsing, command-position substitution and word splitting remain outside this milestone, and G269/G270 are completed separately below;
- G269 keeps ABI 1.23 and implements bounded wildcard pathname expansion in the CPL3 shell using the real VFS directory interface. A wildcard argument may contain exactly one `*`, and that star must appear in the final path component; a literal directory prefix such as `/tmp/g269-*.txt` is opened with the caller's existing VFS permissions and enumerated through `getdents`. Matching is a deterministic prefix/suffix test around the star, and each directory match is appended as a separate outer argument in VFS enumeration order. Command-position wildcards are rejected; no-match, a second `*`, path/argument overflow or exceeding the existing eight-word command bound fails the outer command with status 1 rather than passing a literal. Background and multi-stage pipeline prevalidation reject wildcard-bearing stages before execution. Required normal QEMU creates two `/tmp/g269-*.txt` files, expands them into two arguments stored by `write`, proves an unmatched pattern produces no second literal output, rejects a second `*`, a wildcard in the directory-prefix components and a wildcard command name before outer execution, and proves background/pipeline wildcard commands are side-effect-free. G269 also consolidates G268/G269 expansion detection into one scan and trims non-contractual shell banners to retain the unchanged 32 KiB executable ceiling: successful `cp` is silent and is validated by prompt return plus later execution/persistence of the copied ELF; the redundant pre-shutdown banner is removed while PID-1 reap/final clean markers remain authoritative. ReleaseSmall `sh.elf` stays 29,088 bytes with a 24,572-byte RX segment, only four bytes below the `0x6000` page boundary. `?`, bracket classes, recursive globbing, glob sorting, wildcard command names and explicit hidden-file policy remain outside this milestone; G270 is completed separately below;
- G270 keeps ABI 1.23 and adds bounded root-home tilde expansion to the existing foreground single-stage expansion path. ZigOs currently exposes one login identity, root, whose canonical home is `/home/root`; therefore only exact `~` and `~/...` prefixes expand, while `~user` forms fail closed rather than inventing account-database semantics. Expansion occurs before builtin/external dispatch, so builtins such as `cd` receive the expanded path. The final word remains subject to the existing 31-byte argument bound and no word splitting occurs. Tilde-bearing background jobs and multi-stage pipelines are rejected by the same pre-launch expansion gate used for G268/G269. Required normal QEMU proves `cd ~` reaches `/home/root`, `cd ~/..` reaches `/home`, rejects `~nobody` and an expansion longer than 31 bytes without passing the literal through, and proves background/pipeline rejection is side-effect-free. To make room without relaxing the fixed 32 KiB VFS executable limit, buffers that are completely overwritten before observation are no longer eagerly zero-filled; wildcard directory prefixes now write their own terminating NUL, and the expansion core relies on the compile-time bound `8 * (31 + 1) <= 513` instead of a redundant per-word storage overflow branch. ReleaseSmall `sh.elf` remains 29,088 bytes with a 24,524-byte RX segment, leaving 52 bytes before the `0x6000` layout boundary. Named-user lookup, multiple login homes, parameter expansion, and composition of tilde with wildcard/substitution syntax remain outside G270; G271 is completed separately below;
- G271 advances ABI to 1.24 while adding bounded shell startup-file execution using the existing CPL3 parser and executor rather than a second configuration language. Every shell instance attempts `/etc/shrc` first and `/home/root/.shrc` second before printing its interactive banner; missing or unreadable files are non-fatal. Each file is capped at 512 bytes by reading into the existing 513-byte command buffer and rejecting a 513th byte. CR/LF input is normalized into the shell's existing semicolon sequencing while repeated blank separators collapse to whitespace, after which the same four-list/four-conditional/four-stage/eight-word bounds, expansion rules, permissions and process semantics apply. Required normal QEMU creates both startup files, launches a real foreground child shell through a kernel pipeline, captures the user-file marker, then proves a shared `/tmp/g271-order` side effect contains `SYSTEM` before `USER`, establishing system-before-user execution rather than merely source presence. To create sustainable code-size headroom, parser slots that are assigned before their counts expose them (`Command.words`, `Pipeline.stages`, `ConditionalList.commands`) are no longer eagerly zero-filled; ReleaseSmall `sh.elf` shrinks to 24,992 bytes with a 20,386-byte RX segment while preserving the fixed 32 KiB VFS executable ceiling. The startup-file feature itself needs no kernel authority, but hosted G270 validation exposed a pre-existing G263 scheduling race: a newly spawned foreground pipeline leader could run and attempt terminal input before the shell completed its post-spawn `tcsetpgrp` handoff. ABI 1.24 therefore adds one restricted `foreground_process_group` spawn flag, valid only with `new_process_group`; the kernel installs/remaps the child and performs the controller-authorized fd0 TTY foreground handoff inside the same `spawnv` syscall before it can be scheduled. Foreground transfer wakes blocked terminal readers so failed partial-pipeline construction can restore shell ownership before reaping without deadlock, while background pipelines retain the prior behavior. There is no shell `source` builtin, recursive startup loading, login/non-login mode split, or unbounded configuration input; G272 remains persistent shell history;
- G272 keeps ABI 1.24 and persists raw interactive CPL3 shell input to `/persist/.sh_history` through ordinary VFS permissions. Nonblank input is appended before parsing/execution so failed syntax and commands remain part of the audit-like user history; the file is created mode `0600`, and writes are best-effort so absent, read-only or damaged persistence never blocks the shell. The existing 32 KiB VFS file ceiling is the hard history bound: if an append reaches `FileTooLarge`, the shell truncates the file and retains only the newest entry instead of growing without limit. A single `history_dirty` bit avoids shutdown I/O when no entry was written. Clean shell shutdown flushes only `.sh_history` with file-scoped `fsync`; if the path has never entered a committed persistent snapshot and `fsync` returns `Unsupported`, the shell performs one bounded global `sync` fallback. Other storage errors remain non-fatal and do not bypass the existing read-only/damage policy. Required normal QEMU proves same-session contents, then reboots the exact same NVMe image with a fresh OVMF variable store and requires an earlier `cd ~` command to be recovered before a synchronized child-launch/clean-shutdown check. G272 grows ReleaseSmall `sh.elf` to 29,088 bytes with a 20,978-byte RX segment, still below the fixed 32 KiB executable ceiling. This is bounded persistence, not per-command crash durability, encrypted/redacted history, shell history search/editing, or protection against secrets typed directly into commands;
- G273 keeps ABI 1.24 and adds a standalone freestanding Zig `/bin/ls.elf` instead of requiring the PID-2 shell builtin. The executable accepts zero or one pathname operand (`ls [PATH]`), defaults to `.`, opens the target through ordinary VFS authorization and enumerates it through ABI `getdents` in fixed eight-entry batches. It writes one name per line in VFS iteration order and appends `/` to directory entries; more than one operand returns status 2 with a bounded usage diagnostic, while lookup/type/permission/I/O/name errors return status 1. The build graph links it with the same SysV startup/syscall object and linker script as the other freestanding SDK executables, independently verifies the ELF, installs `artifacts/ls.elf`, embeds it into the kernel and publishes `/bin/ls.elf` mode `0555`. Required normal QEMU invokes the absolute binary path with `/home/root`, requires the real `readme.txt` directory entry and status 0 so the shell builtin cannot satisfy the gate. There are no option flags, recursive traversal, sorting, long-format metadata, colour, wildcard parsing or hidden-file policy in G273;
- G274 keeps ABI 1.24 and adds a standalone freestanding Zig `/bin/cat.elf` for bounded file streaming outside the shell builtin. The executable requires exactly one `FILE` operand (`cat FILE`), opens it read-only through ordinary VFS permissions, reads at most 512 bytes per syscall into one fixed stack buffer and writes each chunk directly to stdout until EOF. Missing/extra operands return status 2 with a bounded usage diagnostic; lookup/directory/permission/I/O/name errors return status 1, and output bytes are never parsed or interpreted by `cat`. The build graph links, independently verifies, installs and embeds `cat.elf` beside the other SDK executables and publishes `/bin/cat.elf` mode `0555`. Required normal QEMU invokes `/bin/cat.elf /home/root/readme.txt` by absolute path, requires the exact retained-file text and status 0 so the shell builtin cannot satisfy the gate. Multiple files, stdin mode, options, line numbering, text transforms and output redirection owned by `cat` remain outside G274;
- G275 keeps ABI 1.24 and adds standalone freestanding Zig `/bin/echo.elf` with the same minimal presentation semantics as the shell builtin. It accepts the already-bounded startup vector, rejects zero/more-than-eight argv entries, scans each argument for a NUL only through the ABI 31-byte argument ceiling, emits arguments in order separated by exactly one ASCII space and appends one CRLF. It performs no filesystem access, option parsing, escape decoding, environment expansion, wildcard expansion or command substitution; those remain responsibilities of the invoking shell before `spawnv`. Write or malformed-startup failure returns status 1. Required normal QEMU invokes `/bin/echo.elf G275_ALPHA G275_BETA` by absolute path, requires the exact two-argument output and status 0 so the shell builtin cannot satisfy the gate. The build graph independently verifies, installs and embeds `echo.elf` as a byte-reproducible artifact. `-n`, `-e`, backslash escapes, locale handling and shell-builtin removal remain outside G275;
- G276 keeps ABI 1.24 and adds standalone freestanding Zig `/bin/pwd.elf`. It requires exactly zero operands, returning status 2 with `usage: pwd` for any extra argv. The executable owns one fixed 256-byte path buffer, obtains the process working directory through the generated `getcwd` ABI, writes that returned byte slice unchanged followed by one CRLF, and returns status 1 on cwd or output failure. It performs no directory traversal, filesystem mutation, environment lookup, canonicalization policy of its own or option parsing. Required normal QEMU invokes `/bin/pwd.elf` by absolute path while the shell cwd is `/`, requires exact `/` output and status 0 so the shell builtin cannot satisfy the gate. Build/install verification treats `pwd.elf` as a first-class byte-reproducible artifact. Logical/physical path modes, symlink spelling preservation and options remain outside G276;
- G277 keeps ABI 1.24 and adds standalone freestanding Zig `/bin/mkdir.elf`. It accepts exactly one `PATH`, requests directory creation with base mode `0755` through the generated `mkdir` ABI and therefore remains subject to the invoking process credentials, parent-directory permissions, sticky rules where relevant and process umask. Missing/extra operands return status 2; creation failures return status 1 with bounded diagnostics for existing targets, missing/non-directory parents, permissions, read-only mounts, overlong names and no-space conditions. It performs no recursive parent creation, ownership changes, chmod follow-up or path normalization beyond the kernel VFS. Required normal QEMU invokes `/bin/mkdir.elf /tmp/g277-dir` by absolute path, verifies `g277-dir/` through directory enumeration, checks status 0 and removes the proof directory before shutdown. Build/install verification treats `mkdir.elf` as a first-class byte-reproducible artifact. `-p`, `-m`, multiple operands and verbose output remain outside G277;
- G278 keeps ABI 1.24 and adds standalone freestanding Zig `/bin/rm.elf` and `/bin/rmdir.elf`. Each executable accepts exactly one path and performs exactly one namespace-removal syscall: `rm` calls `unlink` and therefore does not recursively remove directories, while `rmdir` calls the directory-specific removal ABI and preserves the kernel's non-empty-directory rejection. Missing/extra operands return status 2; lookup, type, permission, read-only, busy and path-length failures return status 1 with bounded diagnostics. Neither tool follows a recursive removal algorithm, synthesizes alternate paths, changes modes/ownership or implements force/interactive prompts. Required normal QEMU creates one temporary file and one temporary directory, removes them through the absolute standalone executable paths, requires status 0 for each and verifies both names are absent afterward. Build/install verification treats both ELF images as first-class byte-reproducible artifacts. Recursive `rm -r`, force/interactive flags, multiple operands and parent pruning remain outside G278;
- G279 keeps ABI 1.24 and adds standalone freestanding Zig `/bin/mv.elf` and `/bin/cp.elf`. `mv` requires exactly `SOURCE DEST` and performs one public `rename` operation, leaving replacement, permissions, sticky-directory policy, busy paths, read-only mounts and cross-mount rejection to the kernel. `cp` requires exactly two operands, opens the source read-only, rejects directories, captures source mode with `fstat`, and preflights an existing destination with `stat`; matching mount/node/generation identity is rejected before truncation so exact-path and hard-link self-copies cannot destroy the source. A non-alias destination is opened create/truncate with source mode plus owner-write subject to process umask, then bytes are streamed through one fixed 512-byte buffer. Required normal QEMU first rejects an exact self-copy and proves the source bytes survive, then copies `G279_PAYLOAD`, verifies the copied bytes, renames the copy through standalone `mv`, proves old-name disappearance/new-name presence and verifies the payload again before cleanup. Recursive copy, cross-filesystem move fallback, multi-source syntax, sparse/extended metadata preservation, atomic copy replacement and options remain outside G279;
- G280 keeps ABI 1.24 and adds standalone freestanding Zig `/bin/stat.elf`. It requires exactly one `PATH` and gathers metadata only through the public `stat`, `statowner` and `stattimes` ABIs. The executable performs no file open or content read and retains only fixed-size metadata structures plus 20-byte decimal and 4-byte octal formatting buffers. Output is deterministic and bounded: type (`file`, `directory`, `pseudo`, `symlink` or `unknown`), four-digit permission/set-ID mode, size, link count, node/generation/mount identity, `uid:gid`, read-only state and creation/modification/change/access ticks. Required normal QEMU invokes `/bin/stat.elf /home/root/readme.txt` by absolute path and requires the authoritative `file`, `0644`, size `57`, one-link, root-owned and writable metadata plus timestamp output and status 0. Human date conversion, recursive traversal, filesystem-capacity reporting, custom formats and non-following `lstat` semantics remain outside G280;
- G281 keeps ABI 1.24 and adds standalone freestanding Zig `/bin/head.elf`, `/bin/tail.elf`, `/bin/wc.elf` and `/bin/grep.elf` as bounded read-only text utilities. `head` and `tail` implement a fixed ten-line default with no option parser; `head` stops after the tenth newline while `tail` makes one constant-memory scan retaining only eleven newline boundaries, seeks to the computed start and streams the final ten logical lines. `wc` streams fixed 512-byte chunks and reports newline, ASCII-whitespace-delimited word and byte counts. `grep` accepts exactly `PATTERN FILE`, limits the literal non-regex pattern to the public 31-byte argument ceiling, builds a fixed KMP prefix table, scans with one 512-byte buffer and seeks back only to emit complete matching lines; status 0 means at least one match, 1 means no match and 2 means usage or I/O failure. Required normal QEMU creates a deterministic twelve-line fixture, proves head lines 1-10, tail lines 3-12, exact `12 12 116` wc output, two literal grep matches and no-match status 1 before cleanup. The four canonical artifacts are `head.elf` 6,848 bytes (SHA-256 `8B7322E5148C24AB811C4E482396F12B06A40067B43E4E52F73BF990B9070C72`), `tail.elf` 7,136 bytes (`C258FE0B3043BCD1B4ECB2FE9178B087FD5037955CCD01B852562646AF8D6483`), `wc.elf` 6,984 bytes (`03A6DE63537E6F9B1013F55BFE4C142C91497AB557A03729FC696F9C67A414D8`) and `grep.elf` 7,672 bytes (`DAB942F18B4FC45D192D067759FFD4D49FAAF51F363EBB43D056AF1CF8E773AC`). Variable line counts, stdin operands, multiple files, regex syntax, recursive search, context output and locale/Unicode word semantics remain outside G281;
- G282 keeps ABI 1.24 and adds standalone freestanding Zig `/bin/hexdump.elf` as a deliberately bounded read-only inspection utility. It accepts exactly one file operand, opens it read-only, reads at most the first 256 bytes through one 16-byte row buffer, and emits fixed four-digit uppercase offsets, sixteen two-digit uppercase hex columns and a printable-ASCII gutter with nonprintable bytes rendered as `.`. Required normal QEMU builds a 272-byte deterministic fixture, verifies the exact `0000` row for `ABCDEFGHIJKLMNOP`, observes the final permitted `00F0` row and rejects any `0100` row, proving the hard output ceiling before clean status/cleanup. The canonical `hexdump.elf` is 7,128 bytes with a 2,816-byte RX segment and SHA-256 `49248F94BB0B009F0B30AAB02384A6383E5AD875042B0698948E8155DBDBF4F8`. Offset/count options, stdin, multiple files, reverse conversion, wider offsets and output beyond the first 256 bytes remain outside G282;
- G283 keeps ABI 1.24 and adds standalone freestanding Zig `/bin/ps.elf` as a procfs-backed process viewer. The executable accepts no operands, opens only `/proc/processes` read-only, and streams the live generated snapshot with one fixed 512-byte buffer; it has no private process-table syscall or kernel-structure dependency. Required normal QEMU invokes `/bin/ps.elf` by absolute path and requires the procfs header plus live rows for PID 1 `init.elf`, PID 2 `sh.elf`, and the executing child itself as `running` with parent PID 2 and four open descriptors, proving the output is generated from current procfs state rather than canned text. The canonical `ps.elf` is 6,608 bytes with a 2,296-byte RX segment and SHA-256 `E7495246AAE00291DADDAA9845D7892A2D8A3101C5D229BD7693C2B5ABE62E62`. Selection/filter options, alternate output formats, per-PID proc directories and direct process-control operations remain outside G283;
- G284 advances the public ABI to 1.25 and adds standalone freestanding Zig `/bin/kill.elf` and `/bin/sleep.elf`. Syscall 128 `kill(pid, signal)` resolves a PID through the retained process table and delegates authorization/state changes to the existing `sendSignal` path, preserving root/same-UID policy and the existing SIGKILL/SIGSTOP/SIGCONT semantics; a terminal foreign target is finalized immediately, while self-termination exits through the active-context handoff before cleanup. The user utility accepts `kill PID [SIGNAL]`, defaults to signal 9, bounds signals to 1-63, and deliberately refuses PID 1 or the active shell PID 2. `sleep TICKS` accepts exactly one decimal tick count in the bounded range 1-100000 and uses the existing scheduler sleep syscall. The former fixed-status diagnostic sleep fixture moves from `/bin/sleep.elf` to `/bin/runtime-sleep.elf`; `/bin/wait.elf` retains its historical 32-tick/status-7 proof with the corrected 22-byte embedded path length. Required normal QEMU proves a foreground two-tick sleep, launches a 1000-tick sleep as a background job, discovers its actual PID through live `/bin/ps.elf`, terminates it through `/bin/kill.elf`, and requires the shell completion `[1] done 137`. Canonical `kill.elf` is 6,648 bytes (RX 2,336, SHA-256 `E4AEDF3D9AE841F8C3B4E4B9AC56C30CC230C211C51880A2498EC397C675907D`) and `sleep.elf` is 6,344 bytes (RX 2,032, SHA-256 `D2B41BBAB2119CF65D4653E57D3BEC7CF40FE693ADC0F130557DB1FFA489424E`);
- G285 keeps ABI 1.25 and adds standalone freestanding Zig `/bin/mount.elf` as a read-only mount-table observer. It accepts no operands, opens only the existing live `/proc/mounts` pseudo-file, and streams that kernel-formatted snapshot through one fixed 512-byte buffer to stdout; it does not call `mount`, `umount`, `statfs`, or any mutation interface. Required normal QEMU executes `/bin/mount.elf` by absolute path and requires both `ramfs on / type ramfs (rw)` and `process-table on /proc type procfs (ro)`, proving the output comes from the live mount registry rather than the diagnostic shell builtin. Canonical `mount.elf` is 6,616 bytes (RX 2,304, SHA-256 `DDD1F6C533AA96135EDCBD0DA422725AB61469A68F21D05AB4C040731D234CBC`); options, filtering, alternate formats and mount-management operations remain outside this milestone.
- G286 keeps ABI 1.25 and adds standalone freestanding Zig `/bin/df.elf` as a bounded `statfs` client. It accepts zero or one `PATH` operand (default `/`), invokes only the existing path-based `statfs` syscall, and prints filesystem kind, block size, total/free/available blocks, total/free nodes, mount ID and bounded read-only/shared/synthetic flags without allocating file-sized state. Required normal QEMU executes `/bin/df.elf /` by absolute path, requires the stable ramfs structure (`block-size 4096`, `blocks 256`, `nodes 96`, `mount 1`, `flags rw shared-blocks shared-nodes`), and parses the live counters to require `available == free <= total` and `free-nodes <= total-nodes`. Canonical `df.elf` is 7,504 bytes (RX 3,192, SHA-256 `6E5F9BF7A19D62DA7CD6B4991BF94A05BD20B9E9538ABA19BD8827D5CDD4F466`); aggregation across all mounts, human-readable units and option parsing remain outside this milestone.
- G287 advances the public ABI to 1.26 with check-only syscall 129 `fscheck` and standalone freestanding Zig `/bin/fsck.elf`. The syscall accepts no arguments, enters the kernel address space through the same callback boundary used by durable synchronization, and reuses the diagnostic checker: persistent storage must be mounted, the complete bounded VFS validator must pass, and the active A/B persistence generation must pass `Store.check()`. It returns 0 for clean state, 1 for structural corruption, `ENOSYS` when no persistent backend is mounted, and a negative operational errno such as `EIO` for block-read failure; it exposes no repair operation, block-writing mode, raw Store handle or pathname input. Required normal QEMU executes `/bin/fsck.elf` by absolute path, requires exact `fsck: clean`, waits for the shell prompt and requires status 0. Canonical `fsck.elf` is 6,344 bytes (RX 2,032, SHA-256 `489955503C26826F4A69D6BFA207F8CC546D001CEF14DE0E10B329EF9F56FB27`); repair, offline media scanning, per-filesystem selection, FAT repair and detailed inconsistency reporting remain outside this milestone.
- kernel-only fixed-capacity live registries for read-only `devfs`, `procfs` and `netfs`; registration may occur after mount, busy nodes cannot be withdrawn, and userspace cannot detach these kernel-owned mounts through the tmpfs-only unmount ABI; per-PID proc directories, userspace registrars and automatic hotplug discovery remain open;
- relative and absolute symbolic links, non-following `readlink` and an eight-link traversal limit;
- immediate pathname removal with deferred reclamation while open descriptions still reference a file;
- directory-descriptor-relative `openat` and one shared VFS-to-ABI metadata conversion for `stat`/`fstat`;
- stat, ownership and owner-or-root chmod metadata, with mode checks on path traversal, open, mutation and executable launch;
- generation-safe VFS open handles used behind shared open-file descriptions;
- descriptor-backed read, write, seek and truncate operations, with per-inode ticket-locked append transactions across independent writers;
- descriptor quotas and structural integrity validation.

Mounted namespaces:

```text
/       ramfs       writable, lost at reboot
/boot   boot_fat    retained NVMe FAT16, read-only; embedded fallback when diskless
/proc   procfs      live kernel version, uptime, memory, process and mount views
/dev    devfs       live registered console/null/zero devices
/net    netfs       live registered interface/route/ARP/socket views
/persist zigos_persist bounded NVMe A/B journal when available
```

The general root remains RAM-backed. ABI 1.13 can overlay an empty directory with a distinct transient `tmpfs`; a successful unmount destroys that temporary namespace and reveals the original empty mountpoint again. The kernel separately owns three read-only live pseudo mounts backed by bounded registries rather than boot-time namespace snapshots. `/dev` dispatches registered device operations; `/proc` and `/net` retain stable names but format current kernel/network objects on every read. The userspace unmount ABI is intentionally tmpfs-only and cannot detach these mounts. `/persist` remains a writable NVMe-backed `zigos_persist` mount using alternating checksummed generations. Kernel and userspace `sync` paths write the payload, flush it, commit a FUA generation header and flush again. Regular files?including linked ELF64 programs up to the VFS limit?are restored into `/persist` and can be executed after reboot. On NVMe boots, `/boot` is the retained EFI FAT16 partition itself: bounded 8.3 directory metadata is imported into VFS, while file bytes are streamed on demand from the controller and logical backed-file sizes are excluded from RAM-resident byte accounting. Diskless recovery retains the previous embedded read-only `/boot` fallback.

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

`zig build test` executes 248/248 canonical host-test executions covering 102 unique `std.testing` declarations, including the dedicated ReleaseSafe NVMe completion-recovery target alongside descriptors, commands, processes, TTY, VFS, ABI, page ownership, persistence, ELF loading and the DNS codec. Imported tests may execute from more than one root, but the source contract counts each declaration once. G248 deliberately expands the existing VFS directory-mutation declaration instead of adding a new declaration, so the 102/248 accounting remains unchanged while that declaration now performs 4,096 deterministic model-checked namespace transitions. G249 likewise expands the existing concurrent-append declaration instead of adding a test declaration; its built-in four-thread phase contributes 1,024 serialized create/write/rename/unlink operations while preserving the same 102/248 accounting.

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
Size:    5,796,352 bytes
SHA-256: 7C90564410404D10C60540FD53C4A57B41E9D3D7F94CDC8867B62A2A89C55FA8
```

This identity is from the locally validated Windows diagnostic ABI 1.26 G287 build with the Zig/C SDK, per-node device operations, diskless recovery, directory-relative `openat`, unified `stat`/`fstat` metadata and deferred open-file unlink reclamation, persistent bounded symbolic-link traversal, hard-link identity, reference-counted dentry-cache cleanup, parent-linked nested mount roots, root-gated ABI 1.13 empty-target `tmpfs` mount/unmount with exact-root and busy-reference checks, per-inode ticket-locked atomic append, a shared sparse-file block pool with persistent allocation maps, failure-atomic bounded `readv`/`writev`, transactional file-scoped `fsync`, data-only `fdatasync` with committed-mode preservation for stable committed paths, transactional global `sync` that prevalidates and visits every writable mount, treats RAM filesystems as immediately synchronized, commits the configured persistent mount once, skips read-only mounts and rejects unsupported writable backends before journal I/O, and a separate bounded 16-page file-data cache keyed by inode generation and logical page, with inode-serialized reads, sparse-zero page caching, LRU replacement, write-through mutation invalidation, an independent one-byte-per-inode dirty-page bitmap that survives cache eviction, target-only fsync/fdatasync clearing, with RAM-backed regular files clearing immediately and persistent files clearing only after journal success; all-writable-mount global clearing after commit success, rejected-plan dirty-state retention, read-only mount baseline adoption, zero-dirty/zero-outstanding-lock shutdown gates, and an explicit generation-tagged asynchronous writeback request serviced at most once per runtime pass, with scheduling/completion separation, RAM-backed immediate completion, persistent data-only A/B journal commits and explicit busy/stale/unsupported/failure accounting. Busy, stale and unsupported outcomes retain dirty state; a real persistent journal write or flush error instead records the failed stage, remounts the exact `/persist` mount read-only once, discards its unsynced dirty ledger, preserves readable live bytes and the running Store's prior committed baseline, and rejects later mutations or synchronization with `EROFS`. A header-flush error occurs after an FUA header write, so disk durability is indeterminate: reboot recovery selects whichever valid generation is newest rather than promising the prior one. Cache page bytes are independently allocated from the post-bootstrap physical-memory manager rather than embedded in the VFS object; runtime service performs bounded low-watermark checks, evicts only clean LRU entries, retains dirty resident pages and the independent ledger, and releases every remaining clean cache page before final PMM accounting. The required diagnostic sessions force the same reclaim path and prove seven physical pages returned while dirty pages remain synchronized only by writeback or sync. Every inode also owns eight logical-page writer ticket locks. Ordinary writes lock only affected pages; replacement writes conservatively lock all pages; truncate, preallocation, hole punching and sparse restoration lock their affected page sets in ascending order and release in reverse. A four-thread host test performs 128 writes into disjoint regions of one cached page and requires exact 128/128 page/inode lock ticket deltas, intact final regions and zero outstanding locks; QEMU reports 354 page-write tickets and zero outstanding in both diagnostic profiles after the three former RAM-copied `/boot` fixtures were replaced by block-backed files. The existing whole-inode lock remains outside these page locks for EOF selection, allocation, size and descriptor-offset consistency, so this does not claim concurrent writes to different pages. The retained EFI GPT partition is now mounted as a real read-only FAT16 backend. It imports bounded short-name metadata (32 files, 24 directories, depth 8), caches FAT sectors, streams large file data through one ticket-locked block buffer, and reports metadata/file/block reads and failures. Mount validation first scans into bounded staging tables, follows every imported file and directory chain through EOC, and claims each cluster in one global ownership bitmap; only after the complete scan succeeds are VFS dentries published. A revisit within the current chain is a loop, reuse by a different chain is a cross-link, and invalid current or next cluster values are classified as out-of-range. Healthy diagnostic profiles claim 11,325 clusters and measure 4,786 free clusters with exact loop/cross/range counters `0/0/0`, persistent normal claims 11,224 clusters and measures 4,887 free clusters for its smaller EFI profile, and diskless fallback reports no backend ownership. For classified loop, cross-link, range or generic FAT-structure corruption, staging is erased, one quarantine reason/event is retained, and an embedded read-only `/boot` fallback is mounted. Mount-time device/I/O failures remain fatal rather than being mislabeled as corruption. Runtime backed-file read failures instead propagate as VFS `InputOutput` and ABI `EIO`; `read` and `readv` temporarily activate the kernel address space for descriptor I/O, restore the exact process CR3 before userspace copies, preserve the caller buffer and open-description offset on failure, and permit retry. Every phase-valid NVMe completion, including an error, advances and acknowledges the completion queue before status classification. A private-prefix required QEMU profile places `README.TXT` at fixed LBA 17319 and replaces its first valid request with one real out-of-range NVMe command, observes `cat: input/output error`, then reads the file successfully on retry with exact one-failure telemetry and clean 144/144 resource balance. A second private-prefix QEMU profile targets the first slot-A payload sector at LBA 18434, substitutes one real out-of-range NVMe write command, observes the triggering global `sync` as `EIO`, then proves `/persist` appears read-only through `/proc/mounts`, retained data remains readable, write/append/create/remove and later sync return `EROFS`, the history-aware containment counters report discarded/rejected `2/1` and VFS remount/discard `1/2`, and shutdown balances 64/64 physical allocations with storage labeled `persistent-read-only`. A required QEMU image cross-links only `BOOT.CFG` to `README.TXT`, proves no corrupted FAT names were published, observes exact `49/0/49` preflight reads and `0/0/0/1/0` claimed/free/loop/cross/range state, and completes normal shutdown with 144/144 physical allocation balance. This is quarantine, not repair, and does not promise rollback if a later unrelated VFS resource failure occurs during post-validation publication. Long-file names, FAT writes, mirror verification, automatic repair and general FAT fsck remain open. ABI 1.12 additionally maps readable regular-file descriptors through generation-tagged, read-only `MAP_SHARED` pages borrowed directly from the PMM-backed VFS cache. Open-description access is authoritative: the CPL3 proof opens the descriptor before changing the pathname to mode `000`, then maps a 13-byte partial final page and continues to write through the retained writable descriptor. Mapping pins prevent cache pressure, ordinary LRU replacement and unlink reclamation from releasing the page; ordinary file writes refresh the same physical page, and final unmap balances the pin and permits deferred inode reclamation. The required CPL3 Zig fixture observes initial bytes, an ordinary-write update, file-read equality and post-close/post-unlink lifetime, while both diagnostic profiles report exact mapped refs/pin/unpin/refresh/fail `0/1/1/1/0` and all profiles finish with zero mapped file pages. Writable file mappings, file-backed `MAP_PRIVATE`, `msync` and mapped-write persistence remain open. ABI 1.14 adds path-based `statfs` syscall 121 and matching generated Zig/C 64-byte layouts. RAM-backed root, `tmpfs` and `zigos_persist` deliberately report the same shared block pool, so their capacities must not be summed; all VFS mounts share the bounded node pool. Synthetic pseudo filesystems report zero data blocks. Real FAT16 `/boot` performs a complete FAT entry scan after namespace validation, so free space counts unreferenced allocated and bad clusters as unavailable rather than assuming every unclaimed cluster is free. Diskless/quarantined embedded `/boot` instead reports the shared RAM allocator. Available and free block counts are currently equal because ZigOs has no quota/reservation layer. ABI 1.15 additionally exposes stored creation, modification, change and access ticks through syscall 122 `stattimes` without widening the existing 32-byte stat ABI. The `/persist` A/B payload format is now v2 with four u64 timestamp fields embedded in each existing record header; v1 generations remain readable, hard-link reconstruction restores one shared inode timestamp set, and full-file versus data-only synchronization retains their existing metadata boundaries. G238 now fixes the update contract: the persistent runtime resets a 100 Hz timestamp counter to zero at boot, so precision is nominally 10 ms, ties inside one tick are valid, and persisted values may later decrease numerically after reboot. Create/mkdir/symlink initialize all fields and mutate parent-directory modification/change; nonzero writes, truncate and fallocate mutate file modification/change; nonzero reads, readlink and getdents mutate access; chmod mutates change; link/unlink/rename/rmdir update the affected inode and parent namespace fields. Stat/stattimes, fsync/fdatasync/sync, failed calls, zero-byte non-truncating I/O, EOF getdents, read-only mapped-file access and kernel-internal scans are timestamp-neutral. Journal restore reapplies timestamp metadata after namespace and hard-link reconstruction so structural restore work cannot overwrite persisted directory values. ABI 1.16/G239 adds 32-bit UID/GID metadata to every VFS inode and exposes it separately through the fixed 8-byte `statowner` result, preserving the legacy `stat` ABI. Descriptor `O_CREAT`, mkdir and symlink creation inherit the current process credentials; hard links share the target inode ownership. Journal v3 extends each record header from 40 to 48 bytes with UID/GID, keeps v1/v2 readable as root-owned `0:0`, and reapplies ownership after namespace/hard-link reconstruction. Full `fsync` records current ownership while `fdatasync` retains the committed owner. G240 now uses these stored fields for authorization without changing ABI 1.16. Non-root access selects exactly one class—owner first, otherwise the process primary GID when it matches, otherwise other—and checks its read/write/execute bits without falling through to a more permissive lower-priority class. Directory traversal requires execute; create/link/unlink/rmdir/rename require write+execute on each affected parent; file and directory opens validate requested access; process launch requires execute independently of read; chmod is owner-or-root; and UID 0 is the explicit administrative bypass. Access already granted by an open description remains valid after later chmod, matching the existing descriptor-lifetime contract. G242 extends the same mode field to validated setuid/setgid metadata while keeping set-ID execution inert. G243 expands the stored mask to `07777` and makes sticky-directory deletion authoritative: ordinary write+execute is still required, then unlink/rmdir/rename removal is limited to root, the directory owner or the victim owner, with destination replacement checked independently and rename-to-self remaining a no-op. Sticky and set-ID bits survive the journal/fsync metadata boundary; process launch still retains parent UID/GID. ABI 1.18 adds advisory whole-file `flock`: shared/exclusive/unlock state belongs to the shared open description across dup and cloned processes, independently opened aliases contend by inode generation, nonblocking conflict returns `EWOULDBLOCK`, and blocking contenders sleep until unlock or final-reference close wakes them. File I/O does not enforce these advisory locks and no lock state is journaled. ABI 1.19 adds bounded advisory byte-range `lockrange`: each open description owns at most eight normalized non-overlapping half-open ranges inside the 32 KiB file address space; replacement and partial unlock preserve/split unaffected fragments, shared overlaps coexist, exclusive overlaps conflict, failed nonblocking conversions preserve prior ranges, and blocking conversion releases only the requested overlapping owner range before sleeping. Range state shares dup/fork/final-close lifetime with the open description but remains a separate advisory namespace from whole-file `flock`; ordinary I/O never enforces either lock family and neither is journaled. ABI 1.20 adds `watchdir` notification descriptors backed by a 64-record global VFS mutation journal and fixed 64-byte public events. Watches begin at the current sequence, independently created watches retain independent cursors, dup/fork aliases share their open-description cursor, caught-up reads return `EWOULDBLOCK`, poll reports readability for unseen records, and lag beyond the retained window produces an explicit overflow event. The notification stream covers successful create/link/symlink/mkdir/remove/rmdir/rename namespace changes, remains generation-safe if the watched directory disappears, does not grant access or mutation authority, and is transient rather than persistent audit state. G247 keeps ABI 1.20 but makes the fixed VFS pathname bounds authoritative at every user boundary: pathname payloads are limited to 255 bytes and components to 31 bytes; exactly 255 bytes is accepted, 256+ bytes and 32-byte components map to `ENAMETOOLONG` before lookup or mutation, while inaccessible user addresses remain `EFAULT`. G249 additionally serializes the create/path-write/rename/unlink target set through one drained namespace-operation ticket lock, without claiming general VFS SMP safety. G250 additionally proves block-level A/B journal fallback for independently corrupted newest header and payload blocks and counts both as recoveries without silently repairing the damaged image. Supplementary groups, `chown`, set-ID execution and setgid-directory GID inheritance remain open. The live-pseudo-filesystem advance replaces boot-time pseudo-node seeding with three kernel-only registries bounded to sixteen entries each. Required profiles report exact device/kernel/network registration and publication counts `3/5/4`, zero withdrawals/failures and a clean registry-to-VFS validation. Names remain a bounded flat set; per-PID proc directories, userspace registration, automatic hotplug discovery and a network mutation/control hierarchy remain open. G258 additionally gives the CPL3 shell one retained `u32` status channel: exact child exit statuses are preserved, deterministic shell-generated statuses distinguish success/failure/usage/not-found, and the `status` builtin exposes only the previous parsed command status. G259 consumes that channel through a fully prevalidated, four-command maximum `&&`/`||` list with left-to-right short-circuit evaluation. G260 adds a fully prevalidated four-list maximum semicolon layer that executes each conditional list left to right and carries status across list boundaries. G261 advances ABI 1.21 with restricted atomic pipeline-group spawn flags and a four-stage external pipeline parser; G262 advances ABI 1.22 with child-only kernel-pipe stdio remapping and real shell data pipelines; G263 advances ABI 1.23 with controller-only TTY foreground handoff and direct-child process-group waiting. G268 additionally adds bounded single-program command substitution through real kernel-pipe capture with a 31-byte raw-output ceiling, failure-atomic overflow/nonzero/NUL/empty rejection and pre-spawn exclusion from background and multi-stage pipeline contexts; the shell UI/error tables are compacted without changing the error classes required by hosted storage and lookup regressions. G269 additionally expands one final-component `*` through real VFS directory enumeration, fails closed on no-match/overflow/unsupported wildcard forms, and excludes wildcard-bearing background/pipeline stages before launch. The page-edge shell keeps successful `cp` and pre-shutdown progress silent; copied-image execution/persistence, PID-1 reap and final clean markers remain the authoritative proofs. Hosted CI now downloads the Linux and Windows artifact sets into one required job and compares every path byte-for-byte.

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

- **Portable Linux:** clean bootstrap, asset generation, formatting, 102 unique isolated declarations, directly linked Zig/C SDK, init, shell and DNS verification, x86-64 UEFI build, portable PE verification and artifact upload.
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
