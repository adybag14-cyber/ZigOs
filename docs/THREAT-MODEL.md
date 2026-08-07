# ZigOs x86-64 threat model

## Scope

This document describes the security boundary of the current bounded x86-64 ZigOs runtime. It is a development threat model, not a claim that ZigOs is secure against hostile workloads.

The model covers the post-UEFI kernel, retained CPL3 processes, the bounded RAM VFS, the retained read-only `/boot` FAT volume, the `/persist` A/B journal, COM1/TTY input, the retained e1000e and NVMe paths, and the generated ABI 1.20 SDK interfaces. The legacy i686 environment is outside this document.

## Assets to protect

- Kernel code, data, stacks, page tables, descriptor tables and interrupt state.
- Isolation between retained CPL3 address spaces.
- Physical-page ownership and allocator metadata.
- Process, descriptor, socket and VFS namespace integrity.
- Persistent journal generation, payload and commit ordering.
- Device MMIO, DMA buffers and retained controller state.
- Availability of the scheduler, TTY, VFS, storage and network service loops.

## Trust assumptions

The current release trusts:

- the UEFI firmware, ACPI tables accepted by the existing validators and the booted EFI image;
- the kernel image and all boot-embedded userspace ELF assets;
- QEMU hardware models used by the required integration tests;
- a single administrative user model with UID/GID-equivalent root authority;
- physical memory not being modified by an external DMA-capable attacker;
- a uniprocessor permanent runtime, because scheduler and allocator mutation are not SMP-safe.

The current release does not establish a package-signing or executable-trust chain for arbitrary files copied into `/persist`.

## Attacker model

A relevant attacker may control an unprivileged CPL3 program and may:

- issue any published syscall with malformed, non-canonical, overflowing, aliased or unmapped pointers;
- consume process, descriptor, socket, mapping and page quotas;
- fault deliberately, loop indefinitely, block on I/O or race logical lifecycle transitions on the BSP;
- create malformed paths, rename trees, mutate writable VFS files and provide malformed UDP/DNS data;
- provide malformed FAT boot-volume metadata or cluster chains and corrupted or stale `/persist` journal sectors between boots;
- send arbitrary serial input to the foreground TTY session.

The model does not currently defend against malicious kernel code, compromised firmware, physical attacks, hostile DMA, speculative-execution attacks, or concurrent malicious execution on several CPUs.

## Existing mitigations

### Memory and execution

- CPL3 processes use private CR3 address spaces and user/supervisor page separation.
- NX and W^X are enforced for supported mappings.
- User pointers and full-width descriptor/flag values are validated before narrowing or copy-in/copy-out.
- Process faults are contained and terminal contexts are reclaimed.
- Stack regions include unmapped guards, although stacks remain fixed-size.
- Physical pages have ownership, generation and reference accounting, final-release poisoning and double/wrong-owner rejection.
- Read-only shared file mappings borrow generation-tagged PMM-backed VFS cache pages; access is fixed by the validated open description rather than re-evaluated pathname mode, mapping pins block eviction and inode reclamation, ordinary writes refresh the mapped page, and unmap/process teardown must release the pin. Writable file mappings are rejected.

### Resource control

- Process, child, descriptor, socket, mapping and page counts are bounded.
- Descriptor and process handles are generation-tagged.
- Directory notification storage is globally bounded to 64 VFS mutation records; each watch consumes only an existing descriptor/open-description slot and reports overflow when retention is exceeded.
- Shutdown validation requires zero retained userspace contexts, descriptors and owned pages.
- The diagnostic shutdown path performs a bounded quiescence and terminal-child reap rather than accepting delayed lifecycle leaks.

### Filesystem and persistence

- Paths are bounded and normalized; traversal, rename cycles and cross-mount rename are rejected.
- User pathname payloads are capped at 255 bytes and individual slash-delimited components at 31 bytes. The complete path is validated before lookup or namespace mutation, including both sides of rename/link and both symlink target/destination strings, so an earlier missing component cannot suppress a later bounds failure. Exactly 255 bytes remains valid; 256+ bytes or a 32-byte component returns `ENAMETOOLONG`. C-string syscall copying distinguishes inaccessible user memory (`EFAULT`) from missing termination/overlength (`ENAMETOOLONG`). These fixed limits are a bounded ZigOs VFS policy, not a claim of dynamic POSIX `PATH_MAX`/`NAME_MAX` support.
- G248 adds deterministic model-based adversarial coverage for the bounded resolver, rename/replacement and unlink state machines. Eight fixed seeds produce 4,096 transitions over reusable namespace slots and accepted alternative path spellings; every seed self-checks coverage of all operation classes/path variants and successful rename/replacement/unlink; after every operation, structural invariants, reference-model visibility/identity/generation/canonical paths, namespace accounting and drained lock/reference state are checked. Failure paths for absent sources/parents, overlong components and file/directory type mismatches are required to be failure-atomic. This improves regression detection but is not a proof of memory safety or exhaustive state coverage: the seed set is finite, the model is single-threaded and intentionally bounded, the model itself remains single-threaded even though G249 separately stress-tests a bounded concurrent mutation subset, and broader filesystem/directory fuzzing remains G414.
- G249 introduces a coarse ticket lock only for the concurrent create/path-write/rename/unlink target set. Those four operations serialize before pathname resolution and retain the lock through namespace/data mutation, preventing one target operation from invalidating another target operation's resolved node while shared bounded dentry/node/data allocators are changing. The tested lock order is namespace operation before inode/page/cache/data-pool locks and the structural validator requires the ticket queue to drain. Four barrier-synchronized host threads perform 1,024 built-in target operations with exact mutation/ticket conservation, and the complete QEMU/fault/persistence matrix remains green. This reduces a concrete race surface but must not be interpreted as global VFS thread safety: plain readers and other namespace mutations such as mkdir, link, symlink, mount/unmount, descriptor tables, pseudo registries and restore/administrative paths are not all covered by this lock, and no linearizability claim is made for those interactions.
- G250 exercises the persistent A/B journal against physical-block corruption rather than only simulated write failure. After a healthy A=3/B=4 image is produced, independent copies corrupt exactly one newest-slot header block byte or one newest-slot payload block byte. The older slot must remain independently valid, QEMU must reject the damaged newest candidate by header CRC or payload CRC, restore generation 3, increment recovery accounting, and never expose generation-4-only data. Recovery itself must not rewrite either damaged image. Header corruption is intentionally observable as `corrupt_headers=1`, so that diagnostic boot is classified as recovered-but-not-clean; payload CRC rejection leaves header-error accounting at zero. The test does not prove arbitrary multi-block corruption tolerance, repair, Byzantine media behavior, or survival when both A/B generations are invalid. G251 separately defines the on-disk compatibility and supported recovery guarantees.
- G251 treats on-disk compatibility itself as a security/reliability boundary. `docs/PERSISTENCE-COMPATIBILITY.md` is authoritative for v1/v2/v3 decoding, one-way migration to v3, little-endian geometry/layout, CRC coverage, commit ordering and fallback limitations. Unknown future versions are deliberately not accepted as forward-compatible, and booting an older kernel on newer-format media is explicitly unsafe unless a later contract says otherwise: a recognized older slot may be selected while an unknown newer slot is rejected. The document also prevents overclaiming CRC recovery by stating that read I/O errors fail as I/O, both-slot loss is fatal, and CRC-valid semantic restore failure does not retry the older generation. Any format change must update source, migration/recovery tests, this contract and the permanent verifier together.
- The retained EFI partition is mounted read-only through a bounded FAT16 parser: only 8.3 entries are staged, file/directory/depth counts are fixed, LBAs and volume extents are checked, directory and file chains are traversed through EOC, same-chain revisits are rejected as loops, one global bitmap rejects cross-linked ownership, and invalid current/next clusters are classified as out-of-range. VFS publication occurs only after the complete integrity scan. Classified FAT-structure failures erase staging, retain one quarantine reason/event and mount an embedded read-only `/boot`; mount-time device/I/O failures remain fatal. Runtime backed-file read failures propagate as VFS `InputOutput` and userspace `EIO`, preserve the buffer and descriptor offset, and may be retried. CPL3 descriptor reads switch to the kernel CR3 for MMIO-backed I/O and restore the process CR3 before userspace copying. Phase-valid NVMe error completions are consumed and acknowledged so they cannot wedge the completion queue. Shared sector buffers are ticket-locked, and backed-file logical sizes are excluded from RAM-resident accounting. Quarantine does not repair the disk and does not claim transactional rollback for a later unrelated VFS resource failure during publication.
- `/persist` uses alternating generations, payload CRCs, payload-before-header ordering, flushes and an FUA commit header.
- Global sync and stable-path file fsync build in a separate scratch payload; the committed in-memory baseline changes only after payload and FUA header success.
- Global sync prevalidates every active writable mount before I/O, treats RAM filesystems as immediately synchronized, skips read-only mounts, commits the configured persistent backend once and rejects unsupported or duplicate writable durable backends without advancing the journal.
- ABI 1.13 exposes only a root-gated empty-target `tmpfs` mount subset. It rejects unknown flags, non-null mount data and unsupported filesystem names; unmount requires the exact mounted root and fails while child mounts, retained descriptors, referenced paths or any occupied process working directory remain inside. This is namespace-lifetime protection, not a complete privilege boundary because the current credential/capability model remains incomplete.
- ABI 1.14 `statfs` exposes bounded allocator/backend accounting only. Shared-block/shared-node flags explicitly prevent RAM root, tmpfs and zigos_persist from being interpreted as isolated capacity pools; pseudo filesystems report synthetic zero-block capacity; real FAT free clusters come from a complete FAT-entry scan; embedded fallback boot files report shared RAM capacity. `available_blocks` currently equals `free_blocks` because there is no quota/reservation policy. statfs capacity is accounting information, not a storage-isolation boundary or authorization primitive.
- ABI 1.15 `stattimes` exposes four stored inode ticks for creation, modification, metadata change and access. G238 defines them as samples of the boot-local 100 Hz persistent-runtime counter: nominal precision is 10 ms, operations within one tick may tie, the counter resets to zero at every boot, and a later post-reboot update can therefore be numerically smaller than an older persisted value. Successful data, metadata, namespace and access operations update only their documented fields; failed operations, stat/stattimes, synchronization, zero-byte non-truncating I/O, EOF getdents, read-only mapped-file access and kernel-internal scans are timestamp-neutral. `/persist` journal v3 carries all four values plus inode ownership in each record, accepts v1 payloads by synthesizing restore-time timestamps and v1/v2 payloads as root-owned `0:0`, and reapplies saved metadata after namespace/hard-link reconstruction; full `fsync` persists current metadata while `fdatasync` keeps committed creation/change/access metadata and advances the data modification tick. Timestamp values are therefore not an authorization primitive, audit log, real-world clock or cross-reboot ordering source.
- ABI 1.16 `statowner` exposes a fixed 8-byte pair of 32-bit owner UID/GID fields. VFS inodes store this metadata; files created through descriptor `O_CREAT`, directories and symbolic links inherit the creating process credentials, and hard links keep one shared inode owner. `/persist` journal v3 stores UID/GID and treats legacy v1/v2 records as root-owned `0:0`; full `fsync` records current owner metadata while `fdatasync` retains committed ownership. G240 makes this metadata authoritative for the bounded VFS: non-root callers select exactly one owner, matching-primary-group or other mode class; directory traversal requires execute, namespace mutation requires parent write+execute, requested open access is checked once, process launch requires execute, and chmod requires inode ownership. UID 0 is the explicit administrative bypass. Already-open descriptions retain their granted access after chmod. ABI 1.17 adds syscall 124 `umask`: each process carries a bounded nine-bit creation mask, children inherit it, updates return the previous mask and reject bits outside `0777` without changing state, and file/directory creation applies the mask once to rwx permissions. chmod and existing objects are not masked; hard links preserve the target mode and symlinks retain their fixed mode. Userspace child spawn preserves parent UID/GID. G242 preserves setuid/setgid metadata without granting credentials: executable loading checks execute permission and child creation inherits caller UID/GID without consuming inode owner/mode metadata. G243 expands stored mode metadata to validated `07777` and enforces sticky-directory removal. Parent write+execute remains necessary; if the parent has sticky `01000`, removing an entry by unlink, empty-directory rmdir, rename source movement or rename destination replacement additionally requires UID 0, ownership of the directory or ownership of the victim inode. Source and replacement victims are checked independently, and exact rename-to-self remains a no-op. ABI 1.18 `flock` is coordination rather than authorization: regular-file shared/exclusive locks are owned by open descriptions, separately opened aliases contend by inode generation, blocking callers sleep/wake through the process table, and ordinary read/write/mmap paths deliberately do not enforce lock ownership. ABI 1.19 `lockrange` applies the same advisory boundary to bounded byte ranges: at most eight normalized half-open segments live on one open description, independently opened aliases conflict by inode generation, nonblocking conflicts preserve owner state, partial unlock/replacement can split and merge ranges, and blocking conversion releases only the requested overlapping owner range before sleeping. Whole-file and byte-range lock families are separate advisory namespaces. Final close, process teardown and reboot discard both; neither grants access or persists to the journal. ABI 1.20 `watchdir` is also coordination/observation rather than authorization: callers must already hold an open directory descriptor, watches begin at the current mutation sequence and expose only later successful namespace changes for that directory. The shared VFS journal is bounded to 64 records and reports an explicit overflow event instead of silently claiming complete history; separate watches have independent cursors while dup/fork aliases share one cursor. Caught-up reads return `EWOULDBLOCK`, poll exposes readable/error/hangup state, and stale watched generations cannot be reused. Watch state and event history are transient and never enter the persistent journal, so this interface is not a durable audit trail, rollback log or access-control mechanism. Supplementary groups, `chown`, set-ID execution and setgid-directory GID inheritance remain open.
- The file-data page cache is bounded to sixteen pages and keys entries by inode generation and logical page so reclaimed node slots cannot reuse stale data; the authoritative block pool remains write-through.
- Cache page bytes are allocated independently from the post-bootstrap physical-memory manager; entries carry page addresses, invalidation and eviction return those pages, and shutdown requires cache allocations and releases to balance before final PMM accounting.
- Runtime service checks a bounded low-watermark policy and evicts only clean LRU entries. Dirty resident pages are never pressure victims, and their independent dirty ledger remains authoritative until successful synchronization.
- Each inode owns eight logical-page writer ticket locks. Data mutations acquire affected page locks in ascending order beneath the inode data lock and release them in reverse; shutdown requires exercised page locks and zero outstanding tickets.
- Same-page writes are therefore explicitly serialized, including cached-page mutation, truncate, preallocation, hole punching and sparse restore. The outer inode lock still serializes different-page writes, so parallel page writes are not claimed.
- An independent one-byte dirty-page bitmap per inode survives cache eviction, while resident entries must mirror the corresponding generation-keyed dirty bit.
- Successful global sync clears dirty state only after a validated all-writable-mount plan and journal success; RAM-backed regular-file fsync/fdatasync clears only its target immediately, persistent file sync clears only after journal success, and rejected plans preserve dirty bits for retry. A real persistent journal write or flush error is different: it records the failed stage, remounts the exact `/persist` mount read-only once, discards that mount's unsynced dirty ledger, preserves readable live bytes and the running Store's prior committed baseline, and makes later mutations and synchronization return `EROFS`. Because header flush follows an FUA header write, a header-flush error leaves on-disk generation durability indeterminate; reboot selects the newest valid generation.
- Journal restoration and read-only mount adoption establish clean baselines, inode destruction discards obsolete dirty bits, and every release profile requires zero dirty cache entries, pages and nodes at shutdown.
- Asynchronous writeback permits only one active generation-tagged request; scheduling does not clear dirty state, and one later runtime service pass consumes at most one request.
- RAM-backed requests complete by clearing only the validated target; stable persistent requests use data-only A/B journal commit ordering. Busy, unsupported and stale outcomes retain dirty pages for retry or global sync; a durable I/O failure enters the same fail-stop read-only containment state instead.
- Request/completion/pass and queued/completed-page counters are conserved at shutdown; dedicated QEMU requires a nonzero six-page asynchronous proof, while other profiles may remain validly idle.
- Ordinary reads hold the inode data lock; every data/size/allocation mutation invalidates that inode's cached pages, and shutdown requires the cache lock to have no outstanding ticket.
- Large cache-array scans use indexed/reference traversal; the source contract rejects by-value iteration that previously created a kernel-stack-sized temporary during QEMU execution.
- Persistent file fsync and fdatasync copy unrelated records from the last committed generation, excluding unrelated dirty VFS state. Full fsync records current mode; fdatasync retains committed mode while advancing data, size and sparse allocation. A forced-termination four-boot test verifies both policies; nonpersistent regular files use immediate target-only synchronization.
- Mount selects the newest completely valid generation and can fall back from a corrupt newest slot.

### Devices and networking

- `/dev/null`, `/dev/zero` and `/dev/console` are published through a fixed-capacity kernel-only live registry and retain independent per-node operation tables. Matching registries publish bounded live `/proc` kernel summaries and `/net` network summaries; withdrawal rejects referenced nodes, ordinary namespace mutation remains read-only, and kernel-owned pseudo mounts cannot be detached through the userspace tmpfs-only unmount ABI.
- Network receive queues and active driver UDP endpoints are bounded; ABI discovery reports four usable hardware endpoints rather than eight bookkeeping slots.
- Retained NVMe and e1000e operation is bounded and polling-based during the permanent runtime.

## Known security gaps

The following are not mitigated and must be treated as open security work:

- owner/group/other mode checks, process umask and sticky-directory removal are enforced against UID plus one primary GID; advisory whole-file `flock` coordinates cooperating processes but is not an authorization boundary; setuid/setgid metadata is stored but deliberately inert at execution, while supplementary groups, credential-changing syscalls, `chown`, set-ID execution and setgid-directory inheritance remain unimplemented;
- no capability enforcement policy across all syscalls;
- no complete userspace signal-frame, handler or permission model;
- no SMEP or SMAP enablement and audit;
- no complete kernel W^X audit, KASLR/ASLR or relocation hardening;
- no stack canaries or independently guarded kernel stacks for every execution context;
- no IOMMU setup, DMA remapping or per-device DMA isolation;
- no system-wide cross-resource pressure policy or OOM victim selection;
- no cryptographic executable, package or persistent-data trust policy;
- no comprehensive fuzzing corpus for every pointer-bearing syscall and parser;
- no SMP-safe scheduler, allocator, VFS or device registry; the live pseudo registries are bounded kernel-only publication tables, not a hotplug-safe general registry;
- no side-channel, speculative-execution or physical-attack defence claim.

## Security acceptance conditions

ZigOs must not claim hostile-workload security until, at minimum:

1. credential lifecycle, supplementary groups, ownership-changing operations and special-mode authorization are completed and stress-tested;
2. every syscall has a documented capability and permission rule;
3. SMEP/SMAP, kernel W^X, stack hardening and ASLR are enabled and tested;
4. DMA is constrained with an IOMMU or an explicit trusted-device/bounce-buffer policy;
5. all pointer-bearing ABI paths are fuzzed with reproducible corpora;
6. signals have complete permission, frame and return semantics;
7. resource pressure has a documented recovery/OOM policy;
8. SMP mutation is synchronized and stress-tested;
9. executable installation has an explicit trust/signing policy;
10. physical Intel and AMD systems pass repeated malformed-input and recovery sessions.

Until those conditions are met, the correct statement remains: ZigOs is an experimental, bounded research OS and is not secure against hostile workloads.
