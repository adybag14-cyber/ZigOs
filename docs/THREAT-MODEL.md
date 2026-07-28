# ZigOs x86-64 threat model

## Scope

This document describes the security boundary of the current bounded x86-64 ZigOs runtime. It is a development threat model, not a claim that ZigOs is secure against hostile workloads.

The model covers the post-UEFI kernel, retained CPL3 processes, the bounded RAM VFS, the `/persist` A/B journal, COM1/TTY input, the retained e1000e and NVMe paths, and the generated ABI 1.9 SDK interfaces. The legacy i686 environment is outside this document.

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
- provide corrupted or stale `/persist` journal sectors between boots;
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

### Resource control

- Process, child, descriptor, socket, mapping and page counts are bounded.
- Descriptor and process handles are generation-tagged.
- Shutdown validation requires zero retained userspace contexts, descriptors and owned pages.
- The diagnostic shutdown path performs a bounded quiescence and terminal-child reap rather than accepting delayed lifecycle leaks.

### Filesystem and persistence

- Paths are bounded and normalized; traversal, rename cycles and cross-mount rename are rejected.
- `/persist` uses alternating generations, payload CRCs, payload-before-header ordering, flushes and an FUA commit header.
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
