# ZigOs x86-64 threat model

## Scope

This document describes the security boundary of the current bounded x86-64 ZigOs runtime. It is a development threat model, not a claim that ZigOs is secure against hostile workloads.

The model covers the post-UEFI kernel, retained CPL3 processes, the bounded RAM VFS, the retained read-only `/boot` FAT volume, the `/persist` A/B journal, COM1/TTY input, the retained e1000e and NVMe paths, and the generated ABI 1.12 SDK interfaces. The legacy i686 environment is outside this document.

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
- Shutdown validation requires zero retained userspace contexts, descriptors and owned pages.
- The diagnostic shutdown path performs a bounded quiescence and terminal-child reap rather than accepting delayed lifecycle leaks.

### Filesystem and persistence

- Paths are bounded and normalized; traversal, rename cycles and cross-mount rename are rejected.
- The retained EFI partition is mounted read-only through a bounded FAT16 parser: only 8.3 entries are staged, file/directory/depth counts are fixed, LBAs and volume extents are checked, directory and file chains are traversed through EOC, same-chain revisits are rejected as loops, one global bitmap rejects cross-linked ownership, and invalid current/next clusters are classified as out-of-range. VFS publication occurs only after the complete integrity scan. Classified FAT-structure failures erase staging, retain one quarantine reason/event and mount an embedded read-only `/boot`; device/I/O failures remain fatal. Shared sector buffers are ticket-locked, and backed-file logical sizes are excluded from RAM-resident accounting. Quarantine does not repair the disk and does not claim transactional rollback for a later unrelated VFS resource failure during publication.
- `/persist` uses alternating generations, payload CRCs, payload-before-header ordering, flushes and an FUA commit header.
- Global sync and stable-path file fsync build in a separate scratch payload; the committed in-memory baseline changes only after payload and FUA header success.
- Global sync prevalidates every active writable mount before I/O, treats RAM filesystems as immediately synchronized, skips read-only mounts, commits the configured persistent backend once and rejects unsupported or duplicate writable durable backends without advancing the journal.
- The file-data page cache is bounded to sixteen pages and keys entries by inode generation and logical page so reclaimed node slots cannot reuse stale data; the authoritative block pool remains write-through.
- Cache page bytes are allocated independently from the post-bootstrap physical-memory manager; entries carry page addresses, invalidation and eviction return those pages, and shutdown requires cache allocations and releases to balance before final PMM accounting.
- Runtime service checks a bounded low-watermark policy and evicts only clean LRU entries. Dirty resident pages are never pressure victims, and their independent dirty ledger remains authoritative until successful synchronization.
- Each inode owns eight logical-page writer ticket locks. Data mutations acquire affected page locks in ascending order beneath the inode data lock and release them in reverse; shutdown requires exercised page locks and zero outstanding tickets.
- Same-page writes are therefore explicitly serialized, including cached-page mutation, truncate, preallocation, hole punching and sparse restore. The outer inode lock still serializes different-page writes, so parallel page writes are not claimed.
- An independent one-byte dirty-page bitmap per inode survives cache eviction, while resident entries must mirror the corresponding generation-keyed dirty bit.
- Successful global sync clears dirty state only after a validated all-writable-mount plan and journal success; RAM-backed regular-file fsync/fdatasync clears only its target immediately, persistent file sync clears only after journal success, and rejected plans or device-write failures preserve dirty bits for retry.
- Journal restoration and read-only mount adoption establish clean baselines, inode destruction discards obsolete dirty bits, and every release profile requires zero dirty cache entries, pages and nodes at shutdown.
- Asynchronous writeback permits only one active generation-tagged request; scheduling does not clear dirty state, and one later runtime service pass consumes at most one request.
- RAM-backed requests complete by clearing only the validated target; stable persistent requests use data-only A/B journal commit ordering. Busy, unsupported, failed and stale outcomes are explicit and retain dirty pages for retry or global sync.
- Request/completion/pass and queued/completed-page counters are conserved at shutdown; dedicated QEMU requires a nonzero three-page asynchronous proof, while other profiles may remain validly idle.
- Ordinary reads hold the inode data lock; every data/size/allocation mutation invalidates that inode's cached pages, and shutdown requires the cache lock to have no outstanding ticket.
- Large cache-array scans use indexed/reference traversal; the source contract rejects by-value iteration that previously created a kernel-stack-sized temporary during QEMU execution.
- Persistent file fsync and fdatasync copy unrelated records from the last committed generation, excluding unrelated dirty VFS state. Full fsync records current mode; fdatasync retains committed mode while advancing data, size and sparse allocation. A forced-termination four-boot test verifies both policies; nonpersistent regular files use immediate target-only synchronization.
- Mount selects the newest completely valid generation and can fall back from a corrupt newest slot.

### Devices and networking

- `/dev/null`, `/dev/zero` and `/dev/console` are registered through per-node operation tables instead of a global pseudo-reader shortcut.
- Network receive queues and active driver UDP endpoints are bounded; ABI discovery reports four usable hardware endpoints rather than eight bookkeeping slots.
- Retained NVMe and e1000e operation is bounded and polling-based during the permanent runtime.

## Known security gaps

The following are not mitigated and must be treated as open security work:

- no real UID/GID credentials or ownership-aware permission checks;
- no capability enforcement policy across all syscalls;
- no complete userspace signal-frame, handler or permission model;
- no SMEP or SMAP enablement and audit;
- no complete kernel W^X audit, KASLR/ASLR or relocation hardening;
- no stack canaries or independently guarded kernel stacks for every execution context;
- no IOMMU setup, DMA remapping or per-device DMA isolation;
- no system-wide cross-resource pressure policy or OOM victim selection;
- no cryptographic executable, package or persistent-data trust policy;
- no comprehensive fuzzing corpus for every pointer-bearing syscall and parser;
- no SMP-safe scheduler, allocator, VFS or device registry;
- no side-channel, speculative-execution or physical-attack defence claim.

## Security acceptance conditions

ZigOs must not claim hostile-workload security until, at minimum:

1. credentials and ownership-aware VFS authorization are enforced;
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
