# ZigOs Capstone 17.0 ??? persistent x86-64 runtime and portable build

Capstone 17 is the first bounded implementation slice of the 500-goal operating-system roadmap. It adds 96 verified goals to the 337 inherited x86-64 goals, reaching **433 cumulative goals (`0x1B1`)**. The release replaces the terminal post-validation halt with a permanent serial runtime, but it deliberately does not claim a general POSIX process, persistent filesystem or socket environment.

## Release marker

```text
ZigOs x86-64 Capstone 17 verified: goals 0x000001B1 new-goals 0x00000060 runtime yes vfs yes process-table yes shell yes portable-build yes ci-matrix yes
```

The marker is emitted only after the inherited Capstone 15 and 16 gates, the permanent runtime session, clean VFS/process reports and explicit shutdown. The host integration workflow separately proves the portable build and CI matrix fields.

## Exact 96-goal contract

### Permanent runtime and interrupt ownership (G001???G016)

1. **G001** ??? Transfer control from the completed boot-validation sequence into a non-returning x86-64 runtime.
2. **G002** ??? Retain PID 1 as a permanent init process after boot validation.
3. **G003** ??? Retain PID 2 as a permanent serial-shell process after boot validation.
4. **G004** ??? Install a dedicated LAPIC vector for the permanent runtime clock.
5. **G005** ??? Use a dedicated runtime timer ISR that cannot select a Capstone 16 process context.
6. **G006** ??? Restore the canonical kernel GDT before permanent runtime ownership.
7. **G007** ??? Restore a valid TSS and task register before permanent interrupt delivery.
8. **G008** ??? Install and verify permanent runtime IDT entries independently of temporary test gates.
9. **G009** ??? Preserve all general-purpose and FX state in the dedicated runtime timer entry.
10. **G010** ??? Expose the runtime interrupt count through atomic operations.
11. **G011** ??? Drive the permanent service clock at 100 Hz.
12. **G012** ??? Use an interrupt-enabled HLT idle path instead of a terminal halt.
13. **G013** ??? Run device service work after each observed runtime tick.
14. **G014** ??? Run retained network service work after each observed runtime tick.
15. **G015** ??? Wake sleeping runtime tasks when their tick deadlines expire.
16. **G016** ??? Stop the permanent loop only through an explicit testable shutdown command.

### Runtime process table (G017???G032)

17. **G017** ??? Provide a bounded 64-slot x86-64 runtime process table.
18. **G018** ??? Use generation-tagged process handles to reject stale references.
19. **G019** ??? Allocate monotonic process identifiers independently of recyclable slots.
20. **G020** ??? Track PID, PPID, process group, session, current directory, UID and GID fields.
21. **G021** ??? Represent runnable, running, sleeping, blocked, stopped, zombie and faulted states.
22. **G022** ??? Select runnable tasks with bounded round-robin scheduling.
23. **G023** ??? Track sleeping deadlines and wakeups in the process table.
24. **G024** ??? Support explicit blocking and targeted wakeup.
25. **G025** ??? Support parent wait, terminal status collection and one-time reaping.
26. **G026** ??? Adopt orphaned children into PID 1 and support init auto-reaping.
27. **G027** ??? Support directed signal delivery and pending-signal masks.
28. **G028** ??? Support process-group signal delivery.
29. **G029** ??? Enforce bounded UID-based signal permission checks.
30. **G030** ??? Apply transactional page, descriptor, socket, child and CPU quotas.
31. **G031** ??? Preserve crash vector, fault address and terminal status metadata.
32. **G032** ??? Reject operations through reaped or otherwise stale process handles.

### Runtime VFS (G033???G048)

33. **G033** ??? Provide a bounded 96-node x86-64 virtual filesystem.
34. **G034** ??? Provide bounded ordinary files of up to 16 KiB each.
35. **G035** ??? Resolve both absolute and current-directory-relative paths.
36. **G036** ??? Normalize repeated separators, dot and parent path components.
37. **G037** ??? Maintain a five-entry mount table.
38. **G038** ??? Mount a writable RAM-backed root filesystem at slash.
39. **G039** ??? Mount the verified boot namespace read-only at /boot.
40. **G040** ??? Mount process, device and network pseudo namespaces at /proc, /dev and /net.
41. **G041** ??? Support file creation, replacement, truncation, writing and append.
42. **G042** ??? Support process-owned open, read, seek and close handles.
43. **G043** ??? Support directory creation and empty-directory removal.
44. **G044** ??? Support unlink and rename with bounded namespace updates.
45. **G045** ??? Expose stat metadata and chmod mutation.
46. **G046** ??? Use generation-safe VFS handles with ownership and descriptor quotas.
47. **G047** ??? Reject cross-mount rename and directory-cycle creation.
48. **G048** ??? Validate complete VFS structure through an fsck-style integrity pass.

### Persistent shell and command environment (G049???G064)

49. **G049** ??? Expose a persistent root@zigos serial prompt.
50. **G050** ??? Receive COM1 bytes after boot validation through a nonblocking UART path.
51. **G051** ??? Support insertion into an editable command line.
52. **G052** ??? Support left/right movement, backspace, delete, home and end editing.
53. **G053** ??? Retain a deduplicated sixteen-entry ANSI command history.
54. **G054** ??? Parse quoted and escaped command arguments.
55. **G055** ??? Expand bounded shell environment variables.
56. **G056** ??? Ignore shell comments outside quoted text.
57. **G057** ??? Parse and execute pipelines of up to four stages.
58. **G058** ??? Support input, replacement-output and append-output redirection.
59. **G059** ??? Recognize background-job syntax.
60. **G060** ??? Expose navigation, inspection and mutation filesystem commands.
61. **G061** ??? Expose process listing, spawn, signal, wait, sleep and fault-containment commands.
62. **G062** ??? Expose device and bounded network-diagnostic commands.
63. **G063** ??? Inspect arbitrary VFS-resident ELF64 headers and PT_LOAD segments.
64. **G064** ??? Expose an explicit shutdown command used only by the integration harness.

### Live COM1 integration proof (G065???G072)

65. **G065** ??? Drive a 27-command post-boot session through bidirectional COM1.
66. **G066** ??? Complete the scripted persistent session with zero failed commands.
67. **G067** ??? Prove directory creation, navigation, file replacement and file viewing live.
68. **G068** ??? Prove pipelines and output redirection preserve expected command data.
69. **G069** ??? Prove a sleeping shell wakes from hardware runtime ticks.
70. **G070** ??? Prove a background job reaches terminal state and is reaped once.
71. **G071** ??? Prove a simulated child fault is contained and reported without halting the kernel.
72. **G072** ??? Prove device and network service passes continue while the shell remains online.

### Portable build infrastructure (G073???G080)

73. **G073** ??? Add a conventional build.zig graph for the x86-64 UEFI image.
74. **G074** ??? Add build.zig.zon package identity and exact minimum Zig revision.
75. **G075** ??? Make NASM payloads, generated ELF files and the AP trampoline explicit build dependencies.
76. **G076** ??? Add a portable Python PE32+ EFI verifier.
77. **G077** ??? Add checksum-pinned Linux Zig bootstrap support for x86-64 and AArch64 hosts.
78. **G078** ??? Reduce the Windows PowerShell build script to a wrapper over zig build.
79. **G079** ??? Add a POSIX shell wrapper and conventional Makefile targets.
80. **G080** ??? Produce byte-identical Windows and Linux UEFI images from the pinned toolchain.

### Isolated testing and hosted CI (G081???G088)

81. **G081** ??? Expose zig build test as a conventional isolated-test target.
82. **G082** ??? Pass five independent VFS std.testing declarations.
83. **G083** ??? Pass eight independent process-table std.testing declarations.
84. **G084** ??? Pass six independent shell-parser and line-editor std.testing declarations.
85. **G085** ??? Add a clean Ubuntu hosted build, test and PE-verification job.
86. **G086** ??? Retain the reduced Windows x86-64 fallback boot profile in hosted CI.
87. **G087** ??? Add a network-enabled x86-64 QEMU boot profile to hosted CI.
88. **G088** ??? Add the persistent COM1 runtime and legacy i686 two-boot regressions to hosted CI.

### Release integrity and bounded scope (G089???G096)

89. **G089** ??? Generate an asset manifest containing output sizes and SHA-256 identities.
90. **G090** ??? Treat NASM warnings as errors for generated x86-64 payloads and the hardware object.
91. **G091** ??? Run Zig formatting, Python compilation, PowerShell parsing and workflow-YAML validation.
92. **G092** ??? Require inherited Capstone 15 and Capstone 16 markers before the persistent runtime marker.
93. **G093** ??? Keep the legacy i686 Capstone 14 build and persistence contract passing unchanged.
94. **G094** ??? Document the RAM-backed, bounded and diagnostic-only limits without production claims.
95. **G095** ??? Track the broader operating-system work as a separate 500-goal roadmap.
96. **G096** ??? Emit the Capstone 17 release marker with 433 cumulative and 96 new verified goals.

## Persistent runtime proof

The dedicated COM1 harness drives 27 post-boot commands and requires zero command failures. It proves directory navigation and mutation, pipelines and redirection, ELF inspection, process creation and reaping, hardware-tick sleep/wake, contained child-fault reporting, device/network diagnostics, VFS integrity and explicit shutdown.

A representative successful run reported:

```text
ZigOs persistent runtime shutdown: commands 27 failed 0 ticks 424 idle-halts 424 service-passes 424
ZigOs persistent VFS: nodes 40 files 10 directories 18 pseudo 12 mounts 5 bytes 30938 clean yes
ZigOs persistent processes: live 2 created 4 reaped 2 switches 41 signals 0 faults 1
```

Tick totals are expected to vary slightly with host scheduling; the harness checks semantic markers and nonzero continued servicing rather than one fixed tick value.

## Isolated tests

- Five VFS tests cover path normalization, mutation, directory invariants, stale handles and read-only mounts.
- Eight process tests cover generations, scheduling, waits, adoption, signals, quotas, groups and fault records.
- Six shell tests cover quoting, variables, pipelines, redirection, malformed syntax, environment mutation, line editing and history.

All 19 tests are available through `zig build test` and are part of `zig build check`.

## Portable build contract

- `build.zig` is the canonical x86-64 UEFI graph.
- `scripts/build-assets.py` makes NASM objects, flat payloads, generated ELF files and the AP trampoline explicit.
- `scripts/verify-efi.py` validates AMD64 PE32+ EFI application output on Windows and Linux.
- `scripts/bootstrap-toolchain.sh` checksum-pins the same canonical Zig revision for x86-64 and AArch64 Linux.
- Windows PowerShell, POSIX shell and Make wrappers delegate to `zig build`.

A clean Windows build and a clean WSL Ubuntu build produced byte-identical UEFI output.

## Artifact identities

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `zig-out/EFI/BOOT/BOOTX64.EFI` | 2,649,088 | `17cfb13a943d42877bedf2265e547cd635bac6a8d5fcc51195487ff775c3efdc` |
| `service-user.elf` | 10,240 | `A166FAE8BCFD94663CA1CE0904AE2BF5D2044E831179910C173F9E4BCA1A8E28` |
| `process-user.elf` | 10,240 | `A04BEBD46E4C95A9A34A5BD84B2B3A43A2C555FB1601F2A94EBDBA82D3DDDD40` |
| `process-exec.elf` | 10,240 | `41D3ED292B1BE84EF3A30969B9CF22D650A22FB8BA92E831C40838B771B97B65` |

## Validation gates

- clean Windows `zig build` and portable PE verification;
- clean Linux `zig build check` and installed artifact build;
- Windows/Linux byte-identity comparison;
- reduced x86-64 fallback QEMU profile;
- network-enabled x86-64 QEMU profile;
- 27-command persistent COM1 runtime profile;
- full legacy i686 build and two-boot FAT12 persistence regression;
- Zig formatting, Python compilation, PowerShell parser, YAML parser and `git diff --check`.

## Deliberate limitations

- The runtime process table schedules bounded kernel-mode pseudo jobs; it is not yet unified with persistent CPL3 contexts.
- `exec` validates VFS-resident ELF64 images but does not yet transfer execution into arbitrary storage-loaded code.
- The writable root is RAM-backed and is lost at reboot.
- `/boot` remains read-only and currently exposes verified embedded ELF copies.
- VFS calls are not yet a complete general userspace file syscall ABI.
- Networking remains a bounded in-kernel stack plus diagnostics; no general userspace socket API is exposed.
- No IPv6, firewall, general routing service, permission model, ASLR, IOMMU isolation, executable trust policy or stable ABI is claimed.
- Hardware support remains primarily validated against QEMU configurations.

The remaining work is tracked as G097???G500 in [`ROADMAP-500.md`](ROADMAP-500.md).
