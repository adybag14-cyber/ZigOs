# Priority remediation plan after Capstone 19

This document records the current disposition of the post-Capstone architecture audit. It distinguishes bounded work that is implemented and boot-tested from general operating-system facilities that remain open. Source implementation, isolated testing, QEMU integration and required hosted CI are separate evidence levels.

## Current evidence baseline

The maintained x86-64 release line now requires:

- 248/248 canonical host-test executions across 102 unique isolated Zig test declarations;
- generated ABI constants checked for staleness;
- independent Zig and C userspace ELF verification;
- a 54-command offline permanent-runtime COM1 session;
- a 56-command live-network permanent-runtime COM1 session;
- a four-boot NVMe persistence proof with forced termination after both file-scoped `fsync` and `fdatasync`;
- persistent normal, cross-linked-media quarantine, recoverable NVMe read-error and persistent-write-error read-only-remount userspace PID 1/PID 2 profiles;
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

The current ABI 1.23 permanent-runtime integration proves exact userspace page-pool allocation/release totals of 253/253 offline and 284/284 live-network, with post-bootstrap physical-manager totals of 308/308 and 344/344 respectively. Persistent normal boot balances 249/249 physical allocations/frees after the required G263 interactive foreground-pipeline proof.

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
Mounts now form an explicit bounded tree. Every non-root mount records its parent mount, covered mountpoint and distinct mounted root; lookup and directory capabilities cross mountpoints, `..` escapes mounted roots through the parent namespace, canonical paths cross nested roots, and unmount requires child mounts and open descriptors to be released first. ABI 1.13 adds root-gated syscalls 119/120 for an empty-target `tmpfs` subset. The mounted root is distinct from the root ramfs, may be writable or read-only, and global sync treats it as an immediate RAM filesystem. Unmount resolves only the exact mounted root and rejects child mounts, open descriptions, referenced paths and every occupied process working directory inside the mount with `EBUSY`; after success, the covered empty directory is visible again. Forced/lazy detach, device-backed mounting, arbitrary filesystem types and per-process mount namespaces remain open. Three fixed-capacity kernel-only live registries now back the read-only pseudo mounts instead of boot-time dentry seeding. `devfs` registers `console`, `null` and `zero`; `procfs` registers live version, uptime, memory, process and mount views; `netfs` registers live interface, route, ARP and socket views. Registration can publish after mount, withdrawal returns `EBUSY` while a node is referenced, registry validation matches every entry to its VFS operation/context, and all required QEMU profiles conserve `3/5/4` publications with zero withdrawals/failures. The userspace unmount syscall rejects non-tmpfs mounts. Per-PID proc directories, userspace registrars, automatic hotplug discovery, an SMP-safe registry and a writable netfs control plane remain open. ABI 1.14 adds path-based `statfs` syscall 121. RAM root, tmpfs and zigos_persist expose the live shared 256-page VFS allocator and carry shared-block/shared-node flags instead of each claiming independent storage; procfs/devfs/netfs expose zero synthetic data blocks; real FAT16 scans every FAT entry to derive independent cluster total/free capacity; diskless/quarantine boot fallback reports the shared RAM allocator. The public result is fixed at 64 bytes and is exercised from both Zig and C CPL3 fixtures. Available blocks equal free blocks because quotas/reservations are absent, and persistent statfs describes live VFS allocation capacity rather than claiming the A/B journal has an independent 1 MiB physical filesystem. ABI 1.15 adds path-based `stattimes` syscall 122 with a fixed 32-byte four-u64 Zig/C `FileTimes` layout while leaving the older 32-byte `stat` ABI unchanged. VFS nodes retain creation, modification, change and access ticks; journal format v2 stores them directly in each existing record header, accepts legacy v1 generations with synthesized restore ticks, and restores shared hard-link inode metadata after alias reconstruction. Full `fsync` persists current timestamp metadata; `fdatasync` persists the data modification tick while retaining the committed creation/change/access values and mode. G238 additionally defines precision and ordering without another ABI change: timestamp values are the boot-local persistent-runtime 100 Hz counter (nominal 10 ms), reset to zero at boot, with same-tick ties allowed and no wall-clock or cross-reboot monotonic guarantee. Successful create/mkdir/symlink initialize all fields and touch parent modification/change; writes/truncate/fallocate touch modification/change; reads/readlink/getdents touch access; chmod touches change; link/unlink/rename/rmdir apply inode and parent-directory change rules. Stat/stattimes, synchronization calls, failed operations, zero-byte non-truncating I/O, EOF directory reads, read-only mapped access and kernel-internal scans remain timestamp-neutral. Persistent restore applies saved values after the namespace and hard-link passes so replay does not overwrite directory metadata. The host VFS policy test and a real CPL3 Zig SDK sequence prove these ordering rules. ABI 1.16 completes G239 with syscall 123 `statowner` and a fixed 8-byte two-u32 Zig/C `FileOwner` layout without widening legacy `stat`. Every VFS inode stores UID/GID; process-created files through `open(O_CREAT)`, directories and symbolic links inherit the caller's process credentials, while hard links retain the shared inode owner. Journal v3 extends the v2 record header by eight bytes for UID/GID, accepts v1/v2 generations by synthesizing root ownership `0:0`, and reapplies owner metadata after hard-link reconstruction. Full `fsync` records current owner metadata; `fdatasync` retains committed ownership. Host tests prove non-root `1000:1000` creation, exact nonzero owner reboot restoration, hard-link identity and v1/v2-to-v3 migration. The booted Zig/C fixtures exercise `statowner`. G240 then makes the stored owner and mode fields authoritative without another ABI change. UID 0 is an administrative bypass; otherwise exactly one class is selected in owner → matching primary group → other order. Path traversal checks directory execute, namespace mutation checks parent write+execute, descriptor opens check requested file/directory access, process launch checks execute independently from read, and chmod is restricted to inode owner or root. The descriptor layer deliberately does not revalidate mode bits after open, so an already-authorized description survives a later chmod. The existing host descriptor test proves owner/group/other read/write selection, class precedence, primary-group directory mutation, execute-only launch permission, owner-only chmod, root bypass and retained-open access. G241 adds ABI 1.17 syscall 124 `umask`: the process-local nine-bit mask defaults to zero for compatibility, is inherited by children, returns its previous value on update, rejects bits outside `0777` without mutation, and is applied exactly once to requested `open`/`openat(O_CREAT)` and `mkdir` permission bits. chmod, existing inodes, hard links and fixed-mode symlinks are unaffected. Child spawn also preserves the parent UID/GID. G242 keeps ABI 1.17 and validates setuid/setgid metadata without enabling set-ID execution: those bits survive creation, chmod, stat, hard-link identity and journal restore; full fsync commits current mode while fdatasync retains committed mode, and process launch always inherits caller UID/GID. G243 expands the validated stored mode to `07777` with sticky `01000`. Creation umask still affects only rwx bits. Ordinary namespace write+execute authorization remains mandatory, then sticky unlink/rmdir/rename removal additionally requires UID 0, directory ownership or victim-inode ownership. Rename source and destination replacement are checked independently, while exact rename-to-self remains a no-op. The host credential matrix covers victim-owner, directory-owner, root and unrelated-user cases; persistence restores a `03755` directory, and Zig/C CPL3 fixtures round-trip sticky metadata. ABI 1.18 then adds syscall 125 `flock` for advisory whole-file shared/exclusive/unlock locking with a nonblocking flag. Lock ownership follows the shared open description across `dup` and cloned process namespaces, while conflicts key independently opened aliases by inode generation; shared/shared is compatible, exclusive conflicts, blocking callers sleep on a file-lock wait key and are woken by unlock or final-description close, and nonblocking conflict returns `EWOULDBLOCK`. Failed nonblocking upgrades retain the prior shared lock; blocking shared-to-exclusive upgrade is explicitly non-atomic and releases shared ownership before sleeping. ABI 1.19 adds syscall 126 `lockrange` for positive half-open byte ranges within the bounded 32 KiB file address space. Each open description carries at most eight normalized non-overlapping segments; adjacent equal modes merge, replacement/conversion preserves unaffected left/right fragments, partial unlock can split a segment, and independently opened aliases conflict by inode generation. Nonblocking conflicts preserve existing owner state; blocking conversion releases only the caller's requested overlapping range before sleeping on the same file-lock wait key. Ordinary I/O never consults either advisory lock family, whole-file and byte-range locks are deliberately separate namespaces, and neither family is journaled. ABI 1.20 adds syscall 127 `watchdir` and a fixed 64-byte `DirectoryEvent` for bounded directory-change notification. A watch is created from an existing directory descriptor, begins at the current mutation sequence, reports successful create/link/symlink/mkdir/remove/rmdir/rename changes for that directory, and is poll-readable while unseen records remain. Reads are nonblocking and return `EWOULDBLOCK` when caught up. The VFS stores 64 global records; lag beyond that window produces an explicit overflow event. Separate watches consume independently, dup/fork aliases share one open-description cursor, stale watched directories report poll error/hangup, and all watch/event state is transient and absent from journal recovery. Supplementary groups, `chown`, set-ID execution and setgid-directory GID inheritance remain open.
G247 closes the user-path length/classification gap without changing ABI 1.20. The bounded VFS now validates the complete pathname before resolution or mutation with a 255-byte payload limit and 31-byte per-component limit, so a later overlong component cannot be hidden by an earlier missing prefix. Exactly 255 bytes is accepted and reaches normal resolution; 256+ bytes and any 32-byte component return `ENAMETOOLONG`. C-string pathname syscalls use a dedicated copier that reads the full bounded window and distinguishes user-address faults (`EFAULT`) from a missing terminator/overlength (`ENAMETOOLONG`). Length-delimited `spawn` and `spawnv` use the same validator while preserving embedded-NUL rejection. Rename and hard-link creation prevalidate both paths, and symlink creation validates both target and destination before mutation, keeping these bound failures failure-atomic.
G248 adds a deterministic model-based path/rename/unlink state-machine fuzzer to the existing VFS directory-mutation host test without changing ABI 1.20 or adding a new isolated-test declaration. Eight fixed 64-bit seeds execute 512 operations each (4,096 total) over four directories and 32 reusable file slots. The generator covers normal creation, absolute/repeated-slash/dot/root-relative/case-folded resolution, same-name and replacement rename, unlink, missing-source rename, missing-parent rename, overlong-component resolution/unlink, directory-unlink rejection, file-over-directory replacement rejection and guaranteed resolver misses. Each seed must exercise every one of the ten operation classes, all five source spellings, all four destination spellings and successful rename/replacement/unlink. After every transition, the VFS internal validator must pass and the implementation is compared against an independent slot model for presence, node identity, generation, link count and canonical path, plus exact node/dentry/file/directory conservation and zero transient open/reference/lock leakage. Fixed seed/step/op diagnostics make failures reproducible. This is bounded single-threaded host fuzzing; its G248 release artifact was byte-identical to G247, and broader filesystem path/directory fuzzing remains G414.
G249 supplies the separate concurrent target proof without changing ABI 1.20. A coarse `namespace_operation_lock` ticket lock is acquired by `createOwned`, path-based `write`, `renameAs` and `unlinkAs` before their resolver/mutation work and released only after the operation completes. This gives those four operations one serialization boundary around path-to-node lifetime and shared bounded node/dentry/data allocator mutation; the established order is namespace-operation lock -> inode data/page-write/cache/data-pool locks, and internal resolver helpers remain unlocked to avoid non-reentrant acquisition. `Vfs.validate()` rejects an undrained namespace ticket queue. The existing four-thread append test is extended rather than adding a declaration: four barrier-released workers each run 64 create/write/rename/unlink cycles against unique names in the same `/tmp` namespace, requiring an exact 1,024 lock-ticket and mutation delta, zero outstanding tickets, and unchanged node/dentry/block/open-file ownership after completion. Twelve repeated ReleaseSafe runs additionally completed 12,288 target operations under varying host scheduling. The complete normal, offline/live diagnostic, diskless, FAT-quarantine, recoverable-read-EIO, persistent-write-EIO, four-boot persistence and legacy i686 matrix remains green. This is deliberately narrower than general namespace SMP safety: ordinary path readers and mkdir/link/symlink/mount/unmount, descriptor-table, pseudo-registry, restore and other administrative mutation paths remain outside this coarse lock.
G250 adds block-level corruption injection to the required persistence recovery path. The established four-boot A/B sequence is preserved and ends with healthy generations A=3/B=4; the harness copies that image twice, mutates exactly one byte in one 512-byte block with a flushed host write, and never alters the healthy source. One copy corrupts the newest slot-B stored header CRC at byte 40 (measured LBA 18433); the other corrupts byte 4 of the newest slot-B first payload sector (measured LBA 18562). Before QEMU, the host parser requires generation 3 to remain valid in both copies, requires the header case to fail header CRC validation, and requires the payload case to retain a valid generation-4 header but fail payload CRC validation. Each recovery boot must select generation 3/slot 0, expose only the older data, report exactly one recovery, and leave the corrupted image hash unchanged. Header corruption records one `corrupt_headers` event; payload corruption records zero header errors. This integration test exposed that payload-CRC rejection previously selected the older slot without incrementing `recoveries`; mount accounting now treats any present-but-rejected header/payload candidate as recovery. The existing isolated fallback test was expanded with the same payload corruption case without increasing test-declaration count. No automatic repair is claimed: the fallback selection itself does not rewrite media; after a successful mount the persistent filesystem retains its normal writable/read-only mode unless a separate I/O failure triggers the fail-stop read-only-remount policy. A later explicit synchronization may write a new generation, and simultaneous loss of both journal generations remains a hard corruption condition.
G251 consolidates the persistence format and recovery policy in `docs/PERSISTENCE-COMPATIBILITY.md`. The current reader recognizes v1/v2/v3 while all new commits are v3; v1 synthesizes mount-tick timestamps and root ownership, v2 retains timestamps but synthesizes root ownership, and global sync migrates either older format to v3. The document specifies the two header blocks, two fixed 64 KiB payload regions, little-endian 48-byte header, versioned 8/40/48-byte record headers, record-kind payloads, CRC-32 coverage and payload-before-header/FUA/flush ordering. It also records the downgrade and recovery boundaries: unknown future versions are rejected rather than assumed compatible, device read errors are not corruption fallback, both-slot loss remains fatal, and a CRC-valid payload that later fails semantic VFS restoration does not currently trigger an older-slot retry. `recoveries` is documented as candidate selection/fallback telemetry rather than a pure corruption count. The permanent verifier pins these statements to the source constants and roadmap.
G258 completes shell exit-status propagation without changing ABI 1.20. `execute` and every builtin helper now return a `u32` status, foreground `spawnv` children return their exact `WaitStatus.exit_status`, and the shell assigns deterministic local values 0 for success, 1 for builtin/runtime failure, 2 for usage failure and 127 for executable lookup failure. The new `status` builtin prints the previous parsed command status and then succeeds, so status observation does not recursively preserve itself. The required normal QEMU proof exercises exact external 42, command-not-found 127, failing-builtin 1 and successful-builtin 0 transitions, followed by the existing shell shutdown and PID-1 reap with status 0. G259 consumes this status channel and G260 now sequences those conditional lists with semicolons; variable expansion remains G267.

G259 completes bounded shell conditional execution without changing ABI 1.20. The CPL3 shell pre-parses the entire input line into at most four command segments before executing any of them, accepts adjacent or whitespace-separated `&&` and `||`, rejects empty/leading/trailing/consecutive operators, rejects a fifth command, and preserves the existing eight-word bound per command. Both operators have equal precedence and evaluate left to right: `&&` executes only after status 0 and `||` only after nonzero status. Skipped commands preserve the current status and have no side effects. Any conditional-list syntax failure is failure-atomic, prints `syntax: invalid conditional list`, and sets status 2. The normal QEMU gate proves all four short-circuit branches, mixed recovery, adjacent operators, absence of skipped branch output, trailing-operator rejection and clean PID-1 reap. G260 now composes those lists sequentially.
Each inode now owns a portable ticket lock for data and size mutation. Ordinary writes, truncation and append share that lock; append holds it across EOF selection, data copy, file-size update and the calling open description's final offset. A four-thread host test verifies 128 fixed-size records appear exactly once without overlap or loss, while normal and diagnostic shutdown require nonzero lock activity and zero outstanding tickets.
Ordinary-file bytes now live in a shared pool of 256 page-sized blocks instead of one dense 32 KiB array per node. Each file has eight logical block slots; absent slots read as zero, writes allocate touched slots transactionally, truncate/unlink return blocks, and ABI 1.9 `fallocate` supports bounded preallocation and hole punching. Journal kind 5 preserves logical size and the resident-block bitmap, including executable files whose final mode is `0555`. Required shutdown gates report and drain the pool lock and verify resident block/byte ownership. This remains a bounded 32 KiB-per-file design, not a scalable extent tree.
ABI 1.10 adds synchronous vectored descriptor I/O without creating a second descriptor path. The kernel copies and validates at most eight 16-byte vector descriptors, validates every nonempty user range and the 1,024-byte aggregate limit before I/O, then performs one existing descriptor write from a gathered buffer or one descriptor read followed by scatter. Invalid later vectors therefore cannot partially mutate a file or consume its shared offset.

G260 completes bounded sequential semicolon lists without changing ABI 1.20. The shell now owns one 513-byte `CommandLine` buffer and pre-parses at most four semicolon-separated lists before executing any command. Every list reuses G259's four-command conditional parser over shared storage; semicolon bytes are replaced with NUL terminators before execution so C-string arguments remain bounded and isolated. Sequential lists execute unconditionally left to right and pass their resulting status into the next list. A trailing semicolon after a valid list is accepted, while a leading semicolon, an empty middle list, a fifth list or any invalid nested conditional expression rejects the entire input before side effects with status 2. The normal QEMU proof requires ordered `G260_FIRST/G260_SECOND`, execution after command-not-found, exact `missing-g260-status;status -> 127`, correct `&&` interaction, trailing-semicolon success, absence of every forbidden prefix/suffix/overflow marker, and clean shutdown. G261 provides restricted pipeline process-group formation and G262 now connects those groups with kernel pipe descriptors; foreground group waiting is now G263-complete; background notifications and job-control builtins remain G264-G266.

G261 advances the generated public ABI to 1.21 by extending existing syscall 96 `spawnv`; no new syscall number and no `SpawnRequest` size change are introduced. The existing 32-byte request's `flags` field accepts exactly `NEW_PROCESS_GROUP` or `JOIN_PROCESS_GROUP`, with the join PGID supplied separately in syscall argument 2. Ordinary `spawnv` requires argument 2 to remain zero. The process table assigns a new pipeline leader's PGID to its PID during process construction, and follower creation accepts only an extant same-parent/same-session group leader whose PID and PGID match the requested value; missing and foreign groups fail before a runnable context exists. A host process-group proof is folded into the pre-existing test declaration so canonical 102-declaration/248-execution accounting remains unchanged. The Zig SDK exposes restricted grouped-spawn wrappers; the generated C header publishes the flags without claiming a C spawn wrapper. The CPL3 shell layers a maximum of four `|` stages inside each conditional operand, prevalidates external-only multi-stage pipelines, launches stage one as group leader and later stages into that PGID, prints the accepted group/stage count, reaps explicit child PIDs and returns the final stage status. Normal QEMU proves PGID 7 with two real `hello` children and status 42, builtin rejection before spawn, malformed trailing-pipe rejection and PID-1 clean reap. This is group formation only: descriptors remain inherited from the shell, no pipeline data flow is claimed until G262, and the shell does not move the TTY foreground group or wait by PGID until G263. General membership operations remain G141.

G262 advances the generated public ABI to 1.22 while retaining syscall 96 and the 32-byte `SpawnRequest`. The new generated `PIPELINE_IO` bit may only accompany G261 new/join process-group modes, and syscall argument 3 carries two packed inherited parent descriptors with `65535` meaning that the corresponding standard stream is left inherited. Child setup occurs after namespace clone but before context installation: the kernel accepts only a readable pipe endpoint for stdin and a writable pipe endpoint for stdout, duplicates them to fd 0/1, closes every inherited descriptor >= 3, and lets existing rollback release the complete child namespace if remapping fails. The folded descriptor host proof verifies wrong-end rejection, exact fd0/fd1 remap and closure without adding a test declaration. The shell allocates N-1 pipes for at most four stages, passes only the adjacent endpoints to each grouped child, closes parent copies as soon as possible and closes every residual endpoint before reaping on failure. Normal QEMU proves PGID 9, an eight-byte `PIPE-CPL` transfer and status 0; offline/live diagnostics independently retain the older explicit-FD blocking/wakeup/reclamation proof. This is not a general spawn-actions API and does not yet move the terminal foreground group or wait by PGID; G263 remains open.

G263 advances the generated public ABI to 1.23 through existing wait/ioctl syscall numbers. `wait` flags are now machine-generated with `NOHANG` and `PROCESS_GROUP`; a PGID wait considers only direct children in that group, chooses the earliest terminal sequence, records group-vs-handle wait state explicitly and wakes only on a matching child exit. TTY ioctls add get/set foreground-PGID operations. Normal boot transfers the TTY internal controller from init PID 1 to shell PID 2; only that controller can switch foreground ownership, and it can select only its own group or a live direct-child group leader in the same inherited session. The shell moves each fully spawned pipeline to foreground, waits/reaps by PGID, preserves the last stage status by PID and restores/verifies its original PGID. The new normal-QEMU interaction launches `pipe-reader.elf|pipe-reader.elf`, observes PGID 11 without a returned prompt, supplies `TTYPIPE`, sees terminal echo plus the downstream pipe output, observes `pipeline foreground restored 2`, then requires status 0 and clean PID-1 reap. Host group-wait and TTY/ioctl proofs are folded into existing declarations, preserving 102/248 accounting. This is bounded foreground pipeline waiting, not general process-group membership/session/control-terminal management, stop/continue job control, background notification or `fg`/`bg`; G141-G146 and G264-G266 remain open.

Descriptor `fsync(fd)` and ABI 1.11 `fdatasync(fd)` resolve the exact regular VFS node. RAM-backed files complete immediately and clear only that inode's dirty ledger; persistent stable committed paths replace only the target record in a separate scratch payload built from the last committed generation. Both exclude unrelated dirty VFS state and preserve the committed in-memory baseline on device-write failure; a real journal I/O failure additionally fail-stops the exact persistent mount read-only. `fsync` records current data, logical size, sparse allocation map and mode; `fdatasync` records current data/size/allocation while retaining the mode from the prior committed record. A required four-boot gate creates generation 1, kills QEMU after a generation-2 fsync and a generation-3 fdatasync, then proves full fsync metadata durability, fdatasync dirty-mode exclusion, link-alias recovery and unrelated sparse-state exclusion before generation-4 cleanup. New names and changed rename/link topology still require global `sync`.

Global `sync` now operates over the complete active writable-mount table rather than being hard-wired to `/persist`. The store validates the full plan before device I/O, visits writable mounts in ID order, treats RAM filesystems as immediately synchronized, commits the configured `zigos_persist` mount exactly once, skips read-only mounts and rejects unsupported writable or duplicate persistent backends without advancing the journal. Required diagnostic shutdown reports one RAM and one durable visit; the diskless normal gate proves RAM-root-only sync succeeds with no journal generation.

Persistent journal damage now has a bounded fail-stop policy. The first payload-write, payload-flush, header-write or header-flush failure records an immutable reason and remounts only the configured `/persist` mount read-only. Existing open descriptions immediately lose write readiness and return `EROFS`; pathname mutation and later sync/fsync/fdatasync/writeback are also rejected, while live bytes remain readable. Unsynced dirty bits belonging to the damaged mount are discarded, RAM-backed writable mounts can still drain, and the running Store does not advance its committed A/B baseline. A header-flush error follows an FUA header write, so on-disk durability is indeterminate and reboot recovery selects the newest valid generation. A required hermetic QEMU gate injects one real NVMe error completion at payload LBA 18434, requires exact one-remount/one-discard conservation and 64/64 resource balance. This is containment, not repair or writable recovery.

A separate file-data page cache now fronts ordinary reads without replacing the authoritative 256-block file pool. It is fixed at sixteen 4 KiB entries, keys pages by inode slot, inode generation and logical page, caches sparse holes as zero pages and uses LRU replacement. Reads take the inode data lock before cache lookup; writes, truncation, hole punching, sparse restoration and inode reclamation write through to the block pool and invalidate all cached pages for that inode. An independent one-byte logical-page bitmap per inode records dirty pages even when no cache entry is resident, and resident entries mirror that authoritative state. Successful global sync clears every writable mount only after plan validation and durable commit; RAM-backed regular-file fsync/fdatasync clears only the target inode immediately, while persistent target state clears only after journal success. Rejected mount plans preserve dirty bits exactly for retry. An actual persistent journal write or flush failure records its stage, remounts `/persist` read-only once and discards that mount's unsynced dirty ledger rather than promising an unsafe in-place retry. Journal restoration and read-only mount adoption establish clean baselines, and inode destruction discards obsolete state. Normal and diagnostic shutdown require bounded occupancy, real hit/miss/population activity, zero dirty resident/ledger state and zero outstanding cache-lock tickets. An early QEMU run exposed a kernel-stack hazard when a 64 KiB cache scan was iterated by value; all scans now use indices/references and the source contract forbids the unsafe form. Data writes remain synchronous/write-through, but dirty-state synchronization can now be scheduled asynchronously through one generation-tagged request. Scheduling captures the target inode generation, dirty-page mask and persistent classification without clearing state; at most one later runtime service pass handles the active request. RAM-backed files complete immediately in the worker, while stable committed persistent files reuse data-only A/B journal semantics. Busy duplicate scheduling, unsupported new persistent names and stale inode reuse are counted separately and preserve dirty state. A persistent I/O failure is counted separately but enters the fail-stop read-only state and discards unsynced persistent dirtiness. Required diagnostic QEMU sessions prove scheduling/completion separation with `/bin/sdk.elf` and exact `1/1/1` request/completion/pass plus `6/6` queued/completed pages; normal, diskless and four-boot profiles also accept a conserved idle worker. Each cache entry now owns one independently allocated post-bootstrap PMM page rather than embedding 64 KiB of page bytes in the VFS object. Every runtime service pass checks a bounded low watermark and, when crossed, evicts clean LRU entries down to a fixed target while retaining every dirty resident page and its eviction-independent ledger. The diagnostic `cachepressure` command uses the same path: the required offline diagnostic returns seven cache pages while retaining 8 dirty entries, and the live-network diagnostic returns six while retaining 10 dirty entries, then global sync clears them and shutdown releases all remaining cache pages. Allocation/release counters must balance before final PMM accounting, with measured physical-manager totals of 308/308 offline, 344/344 live and 249/249 in the required persistent normal G263 boot. This is a bounded low-watermark policy, not global OOM selection. Each inode now additionally owns one ticket lock per logical 4 KiB page. Ordinary and append writes lock their affected pages, replacement writes lock all eight bounded pages, and truncate, preallocation, hole punching and sparse restoration acquire affected page locks in ascending order and release in reverse. A required four-thread host test performs 128 writes into disjoint regions of one already cached page and requires exact 128 page-lock and 128 inode-lock tickets, intact final regions and zero outstanding locks. Offline and live QEMU shutdown each report 186 page-write tickets with zero outstanding after replacing the three RAM-copied boot fixtures with block-backed files. The pre-existing whole-inode lock remains the outer serialization boundary for EOF selection, allocation, size and descriptor-offset consistency; this establishes explicit same-page correctness but does not permit concurrent different-page writes. ABI 1.12 now adds bounded read-only file-backed `MAP_SHARED`: descriptor resolution supplies a generation-tagged regular-file identity, each mapped page pins the matching PMM-backed cache entry and inode, pressure and ordinary eviction skip pinned entries, and ordinary file mutations refresh the borrowed physical page in place. Close and unlink preserve mapping lifetime until final unmap, which balances the pin and permits deferred reclamation. The CPL3 Zig fixture opens the descriptor before `chmod 000`, maps a 13-byte partial final page, and proves mapped/file read equality before and after an ordinary retained-descriptor write and after close/unlink; offline and live shutdown report exact mapped refs/pin/unpin/refresh/fail `0/1/1/1/0`, zero pin failures and zero final file mappings. Writable file mappings, file-backed private mappings, `msync` and mapped-write persistence remain open.

The verified EFI GPT partition is now retained after boot and mounted at `/boot` through a dedicated read-only FAT16 backend. Directory metadata is staged in bounded tables, while file contents remain on NVMe and are streamed through a generic block callback; backed logical bytes are reported separately from RAM-resident VFS bytes. The backend accepts at most 32 files, 24 directories and depth 8, handles 8.3 short names only, caches the active FAT sector and keeps a sequential per-file cluster cursor. Mount validation traverses every staged file and directory chain through EOC, using a per-chain bitmap for loop detection and a global ownership bitmap for cross-link detection; invalid current and next-cluster references have a separate out-of-range error and counter. VFS publication occurs only after the entire FAT scan succeeds. Host cases prove cyclic, cross-linked and out-of-range media leave `/boot` unpublished and can enter a conserved classified quarantine state. Healthy diagnostic QEMU reports 11,039 claimed and 5,072 free clusters with `0/0/0` loop/cross/range counters; persistent normal reports 10,938 claimed and 5,173 free clusters with metadata-only reads, while diskless normal requires the backend to remain absent. A dedicated required QEMU image aliases only the non-boot `BOOT.CFG` entry to `README.TXT`; the kernel boots from the untouched EFI chain, reports `cross_link`, erases staged metadata, mounts the embedded read-only fallback, proves the corrupt names are absent, and shuts down with exact `48/0/48` FAT preflight reads and 144/144 physical allocations/frees. Only classified FAT-integrity failures are quarantined; mount-time device/I/O errors remain fatal. Runtime backed-file data-read failures propagate as `InputOutput`/userspace `EIO` without advancing the descriptor offset or modifying the destination buffer. CPL3 `read` and `readv` execute descriptor I/O under the kernel CR3 and restore the exact process address space before copying results. The NVMe driver advances and acknowledges every phase-valid completion before returning an error, so a failed command cannot wedge the next request. A required private-prefix QEMU profile fixes `README.TXT` at LBA 17319, substitutes one out-of-range NVM read command, observes one `cat: input/output error`, then succeeds on retry with one consumed error completion, a disarmed trigger, exact `112/3/113` FAT metadata/file/block accounting and 144/144 physical allocation balance. The test-only triggers are disabled by default. Runtime read errors remain retryable; one persistent journal write error now triggers a bounded fail-stop read-only remount. Controller reset, writable recovery after remount, automatic repair and general block-device failover remain open. No on-disk repair is attempted, and a later VFS resource failure during post-validation publication is not claimed to be transactionally rolled back. FAT writes, LFN entries, mirror validation, repair and general fsck remain open.

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

Delivered through ABI 1.20:

- `abi/zigos-abi.json` remains the source of truth;
- generated matching kernel Zig, NASM, public Zig and C constants/layouts;
- syscall numbers 64-127 and typed errno values;
- capability discovery and SysV AMD64 argc/argv/envp/auxv startup;
- Zig wrappers for process, VM, file, directory, poll and UDP APIs;
- ABI 1.6 `ioctl`, path `stat`, `openat` and descriptor `fsync`;
- ABI 1.7 `symlink` and `readlink` with an eight-link traversal bound;
- ABI 1.8 hard-link creation and stat link counts without changing the 32-byte stat layout;
- ABI 1.9 descriptor `fallocate`, `KEEP_SIZE` preallocation and `PUNCH_HOLE|KEEP_SIZE` sparse-hole release;
- ABI 1.10 generated 16-byte `IoVector` layouts and descriptor `readv`/`writev`, bounded to eight vectors and 1,024 total bytes;
- ABI 1.11 descriptor `fdatasync`, sharing the transactional file-record path while preserving previously committed mode metadata;
- ABI 1.12 read-only file-backed `MAP_SHARED`, generated Zig/C constants and wrappers, descriptor-generation validation, coherent cache-page reads and balanced mapping pins;
- ABI 1.13 root-gated `mount`/`umount`, a typed read-only mount flag, a distinct empty-target `tmpfs`, exact-root lookup and descriptor/path/process-CWD busy rejection;
- ABI 1.14 path-based `statfs` syscall 121, stable 64-byte Zig/C layouts, seven filesystem kind identifiers and explicit read-only/shared-block/shared-node/synthetic interpretation flags;
- ABI 1.15 path-based `stattimes` syscall 122, stable 32-byte four-field Zig/C timestamp layouts, persistent journal-v2 storage with v1 restore compatibility and no widening of the legacy `stat`;
- ABI 1.16 path-based `statowner` syscall 123, stable 8-byte two-u32 Zig/C ownership layout, process-credential inheritance for created files/directories/symlinks and journal-v3 owner persistence with v1/v2 root-owner migration;
- ABI 1.17 process `umask` syscall 124, returning the prior nine-bit mask with failure-atomic validation, child inheritance and creation-time masking for regular files/directories;
- ABI 1.18 advisory whole-file `flock` syscall 125 with shared/exclusive/unlock plus nonblocking acquisition, open-description ownership across dup/fork, inode-generation alias conflict detection and process-table blocking/wakeup;
- ABI 1.19 advisory byte-range `lockrange` syscall 126 with eight normalized segments per open description, half-open overlap checks, split/merge replacement, failure-atomic nonblocking conflicts and blocking retry on the file-lock wait key;
- ABI 1.20 directory-change `watchdir` syscall 127 with a stable 64-byte event layout, poll readiness, nonblocking caught-up reads, 64-record bounded retention with explicit overflow, independent watch cursors and dup/fork shared-cursor lifetime;
- a generated `sdk/c/include/zigos.h` and freestanding C wrapper library;
- independently linked Zig and C conformance ELFs;
- userspace DNS codec/resolver, init and shell.

The booted C fixture proves generated layout compatibility, ABI discovery, directory watch create/rename/remove notification and poll semantics, `/dev/null`, `/dev/zero`, `/dev/console`, TTY ioctl flags, path stat, stattimes, statowner and umask creation masking, directory-descriptor and absolute `openat` semantics, `fsync`, `fdatasync`, symbolic-link creation, `readlink`, traversal, loop rejection, hard-link identity/link counts, sparse preallocation, invalid-mode rejection, hole punching, gathered writes, scattered reads and failure-atomic vector validation from a non-Zig application.

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
