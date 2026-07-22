# ZigOs Capstone 16.0 - bounded preemptive ELF64 process runtime

## Status

Complete.

Capstone 16 adds 128 verified x86-64 goals on top of the 209 inherited goals, reaching 337 cumulative verified goals (`0x151`). It adds a bounded multiprocess integration suite with private CR3 roots, timer-driven CPL3 switching, generation handles, spawn, COW fork, static-image exec, directed wait, descriptor inheritance, shared open-file descriptions, pipes, signals, demand paging, terminal fault containment, and exact final reclamation.

The inherited Capstone 15 service still runs first as an independent regression gate. The legacy i686 implementation is not modified.

## Bounded scope

This is not a general POSIX process layer. It uses four simultaneous slots, six deterministic generations, two statically embedded ELF64 images, one fixed user page table per process, COW only for data/BSS, eager stack copying, eight descriptors, a 128-byte pipe, directed waits, a signal bitset, one-page mapping services, BSP-local scheduling, and allocator checkpoint reclamation at suite completion.

## The 128 verified goals

1. A freestanding NASM main-process workload is built for long-mode CPL3 execution.
2. A separate freestanding NASM replacement workload proves that exec installs different bytes.
3. Both process payloads assemble with NASM warnings promoted to errors.
4. A deterministic host generator wraps each payload in a bounded ELF64 executable.
5. An independent host verifier rejects any layout, size, syscall-count, FNV, or SHA drift.
6. Both images require ELF64, little-endian, current-version, System V identity bytes.
7. Each image contains exactly two ordered, non-overlapping `PT_LOAD` segments.
8. The first segment is read/execute and contains only the userspace text payload.
9. The second segment is read/write and supplies initialized data plus zero-filled BSS.
10. The main image is fixed at 10,240 bytes with a 1,657-byte payload and 44 encoded syscall sites.
11. The exec image is fixed at 10,240 bytes with a 175-byte payload and seven encoded syscall sites.
12. The canonical build copies both verified images into the package-local generated directory before Zig compilation.
13. Both process images are verified before the kernel is compiled.
14. Both process images are independently re-verified after the UEFI image is linked.
15. GitHub Actions uploads the main and exec images beside the inherited service image and `BOOTX64.EFI`.
16. The kernel independently parses both embedded images through the strict Capstone 15 ELF64 parser.
17. Every process receives a private PML4 root below 4 GiB.
18. Every process receives a private user PDPT page.
19. Every process receives a private user page-directory page.
20. Every process receives a private user page-table page.
21. Kernel-half mappings are copied from the established kernel root without rebuilding global mappings.
22. The copied user PML4 slot is replaced by the process-private hierarchy.
23. An explicit CR3 activation API switches to a selected process address space and verifies readback.
24. A dedicated API restores the original kernel CR3 after the process suite.
25. User pages can be mapped against an explicit address-space object without depending on the active CR3.
26. Mapped pages can be atomically replaced when the expected physical frame matches.
27. Existing pages can be protected read-only or writable while retaining their physical identity.
28. Pages can be unmapped only when their expected physical identity matches.
29. PTE inspection exposes physical address, writable, executable, Accessed, and Dirty state per process.
30. User virtual addresses can be translated against an explicit process root with write/execute requirements.
31. A process page table can be proved empty after teardown.
32. All six created address spaces have pairwise-distinct PML4, PDPT, directory, and table frames.
33. Each private address space consumes exactly four page-table frames.
34. Executable text is mapped read-only and hardware executable under W^X.
35. Data, BSS, stack, heap, demand, and anonymous mappings are hardware NX.
36. The guard page remains unmapped in every process address space.
37. The runtime exposes exactly four simultaneously usable process slots.
38. Every recyclable slot carries a monotonically changing 32-bit generation.
39. Public process handles combine the generation and slot into one 64-bit value.
40. Process IDs remain the bounded slot identities 80 through 83 while handles distinguish reuse.
41. Every process records its parent PID and parent slot.
42. Six explicit workload roles select initial, two workers, fault, reuse, and exec paths.
43. Processes move through free, runnable, running, sleeping, waiting, zombie, and faulted states.
44. Every process owns a complete 160-byte syscall/timer return frame.
45. Every process owns a 16-byte-aligned 512-byte FXSAVE image.
46. Every process owns an eight-entry descriptor table referencing shared open-file descriptions.
47. The live workload creates exactly six process generations.
48. The initial process performs exactly four bounded spawn operations.
49. Spawn may inherit the caller's descriptors by incrementing shared open-file references.
50. One real fork is executed from the caller's saved CPL3 context.
51. One child replaces itself with the independently generated exec image.
52. The parent completes exactly five directed wait operations.
53. Six bounded tombstones retain terminal handle, status, and fault classification.
54. The fourth slot is reused twice after reaping earlier generations.
55. One stale wait and one stale signal are rejected against old generation handles.
56. The existing `int 0x80` return frame can resume a different process than the caller.
57. The runtime installs a temporary APIC periodic-timer hook without replacing the inherited scheduler implementation.
58. The process timer is programmed at a bounded 250 Hz target.
59. Timer interrupts save the complete live CPL3 general-register frame.
60. Timer interrupts save and restore the complete FPU/SSE state through FXSAVE/FXRSTOR.
61. A selected process CR3 is activated before the interrupt or syscall returns to CPL3.
62. Runnable slots are selected by bounded round-robin scanning.
63. The workload requires at least two real hardware timer preemptions.
64. The workload requires at least six complete process context switches.
65. Worker GPR sentinels survive timer preemption.
66. Worker XMM0 sentinels survive timer preemption and sleep.
67. Two explicit userspace yield operations reschedule through the live syscall frame.
68. One bounded sleep operation blocks a process for two logical ticks.
69. A sleeping process is returned to runnable state and the blocked workload completes.
70. When all nonterminal processes are sleeping, at most two deterministic idle ticks may advance to the earliest wake deadline.
71. The final parent exits through the original `zigos_enter_user` kernel-return continuation.
72. Fork returns a generation-tagged child handle to the parent.
73. Fork returns zero to the child through its copied syscall frame.
74. The forked child retains PID 83 and parent PID 80.
75. A nonvolatile GPR sentinel is inherited across fork.
76. A stack sentinel at the live user RSP is inherited across fork.
77. The user stack is eagerly copied into a private physical frame.
78. Fork shares the read-only executable text frame.
79. Parent and child data pages are initially shared read-only for copy-on-write.
80. Parent and child BSS pages are initially shared read-only for copy-on-write.
81. The parent's first post-fork data write resolves into a private data frame.
82. The child's first data write resolves into a different private data frame.
83. The child's first BSS write resolves into a private BSS frame.
84. The kernel independently verifies the child's exact data, BSS, and demand sentinels before exec.
85. The kernel independently verifies that the parent's corresponding data and BSS values remain unchanged.
86. An invalid exec request from the parent returns the bounded no-executable error.
87. An invalid exec request from the forked child returns the same bounded error.
88. Invalid image identifiers perform no visible mapping, register, role, or descriptor mutation.
89. Successful exec stages fresh text, data, BSS, and stack frames before replacing the process image.
90. Exec replaces the visible text mapping with the verified replacement payload.
91. Exec replaces initialized data with the verified replacement data segment.
92. Exec installs a completely zero-filled replacement BSS page.
93. Exec installs a fresh stack and stack canary.
94. Exec removes any inherited heap mapping.
95. Exec removes any inherited demand-zero mapping.
96. Exec removes any inherited anonymous mapping.
97. Exec resets RIP, RSP, GPRs, and FX state while preserving PID, PPID, handle, and descriptors.
98. A one-page anonymous mapping can be created at the fixed anonymous address.
99. The anonymous page is verified zero-filled before userspace writes it.
100. The anonymous page can be explicitly unmapped with physical-identity validation.
101. The bounded program break can grow by one page.
102. The new heap page is verified zero-filled before userspace writes it.
103. The program break can shrink and unmap the heap page.
104. A non-present userspace read at the demand address allocates a zero-filled page and resumes the instruction.
105. A second process independently faults in its own demand page.
106. Both demand pages are checked as zero before their first write.
107. A guard-page read terminates only the faulting process with status `0xE00E` and schedules another process from the exception return frame.
108. A bounded pipe allocates one read and one write open-file description plus a 128-byte kernel buffer.
109. Pipe reads and writes operate through shared open-file descriptions rather than per-descriptor copies.
110. Spawn and fork preserve pipe endpoints by reference-counting the same open-file descriptions.
111. `dup` creates another descriptor reference to the existing write description.
112. Four independent eight-byte records traverse the pipe for an exact total of 32 bytes.
113. The live descriptor-reference high-water mark is exactly eight.
114. Exactly thirteen descriptor closes occur across explicit close and process teardown.
115. Only two open-file descriptions are ever simultaneously active.
116. The forked child sends signal 5 to its parent.
117. Worker one sends signal 6 to the same parent.
118. Signal consumption returns signals 5 then 6 from the pending bitset, and stale-target delivery is rejected.
119. The six terminal statuses are exactly `0x80`, `0x81`, `0x82`, `0x83`, `0xE00E`, and `0x95`.
120. Every process descriptor table is empty after the final exit.
121. Both pipe endpoints and the pipe object are released after the last reference closes.
122. Every process user PTE is removed during teardown.
123. All six private page tables are independently proved empty.
124. The original kernel CR3 is restored before reporting success.
125. The allocator checkpoint rewinds all 52 temporary frames exactly.
126. Stack canaries, PTE permissions, shared-text identity, COW isolation, exec identity, and pipe records all pass independent kernel checks.
127. The inherited Capstone 15 service and the unchanged Capstone 14 i686 writable/offline/read-only sequence remain mandatory regressions.
128. The release emits the cumulative 337-goal (`0x151`) marker, requires the 128-goal (`0x80`) marker in the local and hosted harness, and uploads all verified artifacts.

## ELF64 workload identities

| Image | Payload | `int 0x80` sites | ELF bytes | Code FNV-1a64 | ELF FNV-1a64 | SHA-256 |
|---|---:|---:|---:|---|---|---|
| `process-user.elf` | 1,657 | 44 | 10,240 | `D56BC3BAEAFFE340` | `F4E0D9F25BF74D76` | `A04BEBD46E4C95A9A34A5BD84B2B3A43A2C555FB1601F2A94EBDBA82D3DDDD40` |
| `process-exec.elf` | 175 | 7 | 10,240 | `98EA5EC32A047A98` | `13F8A5B090C2F18A` | `41D3ED292B1BE84EF3A30969B9CF22D650A22FB8BA92E831C40838B771B97B65` |

```text
0x0000008000000000  RX text
0x0000008000001000  unmapped gap
0x0000008000002000  RW/NX initialized data
0x0000008000003000  RW/NX BSS
0x0000008000004000  RW/NX stack
0x0000008000005000  optional RW/NX heap
0x0000008000006000  demand-zero page
0x0000008000007000  optional anonymous page
0x0000008000008000  unmapped terminal guard
```

## Process syscall ABI

Calls 32-55 provide PID, PPID, role, tick, spawn, fork, exec, exit, yield, sleep, directed wait, pipe, read, write, close, dup, signal send/take, process information, VM information, anonymous map/unmap, bounded `brk`, and current generation handle. These are ZigOs-specific calls, not Linux syscall numbers.

## Exact live sequence

The initial PID 80 creates a pipe, spawns workers 81 and 82, forks PID 83, and later reuses slot 83 twice. The fork child proves inherited GPR/stack state, resolves data/BSS COW, faults in demand memory, signals its parent, rejects an invalid exec, and replaces itself with the second ELF. Workers prove timer and FX-state preservation, sleep/yield, heap and anonymous mappings, demand paging, pipe sharing, and signals. A guard-fault generation is contained with `0xE00E`; the final reuse generation writes the fourth pipe record. PID 80 rejects stale handles, reads all 32 bytes, consumes signals 5 and 6, and exits `0x80`.

## Required release marker

```text
ZigOs x86-64 Capstone 16 verified: goals 0x00000151 new-goals 0x00000080 processes 0x00000006 syscalls 0x00000018 spawns 0x00000004 fork 0x00000001 exec 0x00000001 COW 0x00000003 demand 0x00000002 terminal 0x00000001 frames 0x00000034 page-tables 0x00000018 cleanup yes
```

Timer ticks, preemptions, context switches, wakeups, and zero-to-two idle-advance ticks are bounded rather than fixed because they depend on actual QEMU timer delivery.

## Validation matrix

- clean canonical nine-stage x86-64 build;
- pre- and post-link verification of all three ELF64 images;
- warning-as-error NASM, Zig formatting, Python parsing, PowerShell parsing, and YAML parsing;
- deterministic single-CPU ACPI-PM hosted boot;
- four-CPU HPET/network and four-CPU ACPI-PM/network local boots;
- inherited Capstone 15 service;
- unchanged Capstone 14 i686 writable first boot, offline FAT12 verification, and read-only persistence boot;
- exact hashes, clean worktree, and no repo-owned helper processes.

## Reference artifacts

`BOOTX64.EFI`: 961,536 bytes, SHA-256 `4A5A3CDA43F1D29B0CD30184487ABC1912542343A65C523CDE6399CC849A4166`. The two process ELF identities above are frozen by the host verifier. Unchanged legacy references:

- `ZIGOS386.BIN`: 103,624 bytes, SHA-256 `59D2A2FE18CB34F83EFEB493D268FA29092696E256211E148A0DDFB0758EA702`.
- persisted `ZIGOS386.IMG`: 2,097,152 bytes, SHA-256 `9CD89D88469CDF05E0155D1AC2DF007B4474329D148FE01158DE08153A8009C3`.
