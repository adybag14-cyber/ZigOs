# ZigOs Capstone 13.0

## Bounded asynchronous multiprocess execution

Capstone 13 replaces the legacy i686 process proof's single deferred child context with a bounded asynchronous runtime. The scope is deliberately narrow and testable: at most four asynchronous child contexts exist at once, one parent syscall may block in the runtime, every child uses one page-directory frame, one page-table frame, one 4 KiB code frame, one 4 KiB user-stack frame, and one fixed 4 KiB kernel privilege stack. Scheduling is single-CPU round robin through IRQ0. The release does not claim POSIX process semantics, priorities, SMP migration, signal handlers, unrestricted ELF layouts, dynamic user-stack growth, or reusable process-table slots after the release proof.

## Twenty-seven completed goals

1. **Bounded child table.** Four explicit asynchronous child slots own all runtime state and reject creation beyond the bound.
2. **Monotonic process identities.** Each successful asynchronous spawn consumes the next PID and publishes it to the parent.
3. **Parent relationships.** Every child process record stores its creating PID and exposes it through status and process-information calls.
4. **Process-group inheritance.** Children and descendants inherit the parent's process group for directed signal delivery.
5. **Current-directory inheritance.** The Capstone 12 `cwd_cluster` process state is copied into every asynchronous child.
6. **Private page directories.** Each child receives a distinct CR3 frame, separate from siblings and the kernel directory.
7. **Private executable frames.** Each ELF image is loaded into a distinct user code frame at the shared virtual address `0x00400000`.
8. **Private user stacks.** Each child receives a distinct user stack frame at `0x00402000`.
9. **Private privilege stacks.** Each child owns a separate 4 KiB ring-0 stack, and TSS `esp0` follows the scheduled child.
10. **Timer-driven round robin.** IRQ0 saves the complete interrupted frame and rotates runnable child contexts.
11. **Syscall-return context selection.** The `int 0x80` assembly stub can resume the caller, exit to the kernel, or restore a different selected user or kernel context.
12. **User yield.** Syscall 43 marks the current child ready and immediately schedules another runnable context.
13. **Asynchronous sleep.** Syscall 44 blocks the current child until a bounded future PIT tick.
14. **Timer wakeup.** Sleeping children become ready when the monotonic tick reaches their wake deadline.
15. **All-sleeping idle context.** A kernel-owned halt loop runs when no child is ready but at least one child is sleeping.
16. **Nonblocking status polling.** Syscall 45 returns PID, PPID, state, exit code, quanta, syscall count, completion order, and lifecycle flags without reaping.
17. **Blocking wait-pid.** Syscall 46 preserves the parent's complete syscall frame and blocks until the selected direct child exits.
18. **Blocking wait-any.** Syscall 47 blocks until any unreaped direct child exits and selects by completion order.
19. **Deterministic completion order.** The live workload proves `WORKA -> WORKB -> LEAF` as orders one, two, and three.
20. **Directed signal delivery.** The parent sends signal 15 to `WORKB.ELF` while it is being timer-preempted.
21. **Consume-and-clear pending signals.** `WORKB.ELF` observes signal 15 exactly once; the final process record contains no pending signal.
22. **Grandchild creation.** `WORKA.ELF` asynchronously creates `LEAF.ELF`, producing a three-generation process tree.
23. **Orphan adoption.** When `WORKA.ELF` exits, the sleeping leaf's PPID changes from the worker PID to PID 1.
24. **Init auto-reaping.** The adopted leaf is released automatically when it exits, without a direct wait from `ASYNC.ELF`.
25. **One-shot wait rejection.** A second wait-pid for `WORKA` and a wait-any after both direct children are reaped return the bounded no-child error.
26. **Exact child cleanup.** Exit closes every child-owned descriptor; reaping returns all four paging/user frames for each of three children.
27. **Exact parent restoration.** After three blocking intervals, the parent CR3, TSS `esp0`, PID, syscall frame, descriptor state, and twelve-frame baseline are restored exactly.

The cumulative verified release count is 113 goals (`0x71`), with 27 (`0x1B`) new in Capstone 13.

## ABI extension

Capstone 13 extends the inherited 41-call CPL3 ABI with calls 42 through 48:

| Call | Operation | Result |
|---:|---|---|
| 42 | Spawn bounded asynchronous ELF | Child PID or bounded error |
| 43 | Yield current child | Zero after the child resumes |
| 44 | Sleep current child | Zero after the wake deadline |
| 45 | Poll child status | 32-byte status record without reaping |
| 46 | Wait for one PID | Reaped PID and final status record |
| 47 | Wait for any direct child | Earliest completed unreaped PID |
| 48 | Drain live asynchronous descendants | Number of init auto-reaps during the block |

All user pointers retain the inherited page-by-page present, user-accessible, writable, length, and capacity validation. The status record is eight little-endian `u32` fields: PID, PPID, runtime state, exit code, timer quanta, syscall count, completion order, and flags. Flag bits report adoption, resource release, one-shot waiting, auto-reaping, and any pending signal.

## Disk-loaded process tree

The deterministic FAT12 image contains four new ELF32/i386 programs:

| File | Bytes | FNV-1a32 | FAT12 chain | Purpose |
|---|---:|---:|---|---|
| `ASYNC.ELF` | 2,336 | `21F68871` | `23 -> 24 -> 25 -> 26 -> 27` | Parent lifecycle verifier |
| `WORKA.ELF` | 824 | `C83AFC14` | `28 -> 29` | Creates the leaf, yields, sleeps, exits `0x81` |
| `WORKB.ELF` | 784 | `CD43E95A` | `30 -> 31` | Yields, executes a preemptible 100,000,000-iteration loop, consumes signal 15, exits `0x8F` |
| `LEAF.ELF` | 692 | `769A282E` | `32 -> 33` | Performs ten 20-tick sleeps, is adopted by PID 1, exits `0x83` |

`PATHS.ELF` consequently occupies clusters `34 -> 35 -> 36 -> 37 -> 38 -> 39 -> 40 -> 41`, and the first writable runtime cluster becomes 42.

The live tree is:

```text
ASYNC.ELF  PID 9
|-- WORKA.ELF  PID 10
|   `-- LEAF.ELF  PID 12  (adopted by PID 1)
`-- WORKB.ELF  PID 11
```

## CPL3 lifecycle proof

`ASYNC.ELF` performs 17 parent syscalls while its three children perform 26, for 43 total:

```text
process PID 0x00000009 ASYNC.ELF exited 0x00000073 syscalls 0x0000002B
async-goals 0x0000001B
children 0x0000000A->0x0000000B->0x0000000C
order 0x0000000A->0x0000000B->0x0000000C
preempt yes idle yes adoption yes auto-reap yes frames-restored yes
```

The parent observes all of the following in preserved user buffers and kernel records:

- `WORKA` is initially READY with zero quanta and zero executed syscalls.
- Wait-any returns `WORKA`, exit `0x81`, seven syscalls, completion order one, released and waited flags.
- `LEAF` reports PPID 1 while sleeping, proving adoption before its exit.
- Process information reports the leaf's original group and adopted PPID.
- Directed signal 15 reaches `WORKB`; it consumes the signal exactly once.
- Wait-pid returns `WORKB`, exit `0x8F`, at least three timer quanta, five syscalls, completion order two.
- Drain blocks through the all-sleeping idle path until the adopted leaf auto-reaps.
- Final leaf status reports exit `0x83`, fourteen syscalls, completion order three, and adopted, released, waited, and auto-reaped flags.
- Four intentional invalid operations return their exact bounded errors without mutating the process tree.

## Inherited filesystem persistence

The expanded static inventory contains 16 root files. The first boot still executes the complete Capstone 12 hierarchy mutation after the asynchronous proof:

```text
/HOME                         cluster 42
/HOME/DOCS                    cluster 43
/HOME/ARCHIVE                 cluster 46
/HOME/ARCHIVE/LOG.TXT         clusters 44 -> 45, 600 bytes, FNV-1a32 36F73195
/NOTES.TXT                    clusters 47 -> 48, 720 bytes, FNV-1a32 C6181D2F
```

The second boot independently validates both FAT copies, root and directory entries, dot links, parent links, tombstones, file contents, and cluster 49 remaining free while performing zero writes and zero allocations.

## Release markers

First session:

```text
ZigOs i686 Capstone 13 first session verified: goals 0x00000071 new-goals 0x0000001B root-files 0x00000011 processes 0x0000000F waits 0x00000005 creates 0x00000001 truncates 0x00000001 writes 0x00000002 seeks 0x00000001 allocations 0x00000002 notes 0x000002D0 hash 0xC6181D2F chain 0x0000002F->0x00000030 hierarchy 0x0000002C->0x0000002D hierarchy-hash 0x36F73195 async yes fault-contained yes descriptors-closed yes commands 0x00000011
```

Persistence session:

```text
ZigOs i686 Capstone 13 persistence session verified: goals 0x00000071 inherited-goals 0x00000056 root-files 0x00000011 notes 0x000002D0 hash 0xC6181D2F chain 0x0000002F->0x00000030 hierarchy 0x0000002C->0x0000002D hierarchy-hash 0x36F73195 writes 0x00000000 allocations 0x00000000 descriptors-closed yes commands 0x00000003
```

## Validation matrix

- Canonical Zig formatting and ELF32/i386 linking.
- Host verification of all sixteen initial FAT12 root files, exact chains, ELF identities, embedded worker names, spawn opcodes, preemption-loop bound, and ten leaf sleeps.
- Real QEMU BIOS execution of 43 asynchronous lifecycle syscalls across four CPL3 programs.
- IRQ0 preemption, yield, timed sleep/wake, and all-sleeping idle-context validation.
- Poll, wait-pid, wait-any, drain, deterministic completion, signal, adoption, and auto-reap validation.
- Distinct CR3, code frame, stack frame, and kernel privilege stack validation.
- Exact descriptor, frame, parent CR3, TSS `esp0`, PID, and syscall-frame restoration.
- Complete inherited hierarchy mutation and independent offline FAT12 verification.
- Read-only second QEMU boot and whole-image SHA-256 identity.
- Three consecutive complete canonical rebuild and two-boot repetitions.
- Existing x86-64 UEFI HPET and 24-bit ACPI PM timer fallback regressions.
- Clean GitHub Actions rebuild, boot test, and artifact upload.

## Reference artifacts

- Legacy kernel: 89,500 bytes, 175 sectors at LBA 9-183.
- Kernel checksum16: `0x5588`.
- Kernel SHA-256: `98814EB307863036AB704C2B22A35D58A18E993999E57FB4626D1A6A665846C5`.
- Initial image SHA-256: `0B859BD6F671FCFEE7E655D3777EE10AEAFCD4C19619898A84539194ABF3ED96`.
- Persisted image SHA-256: `B1FC794EB460020D99F52B1C10565F990E1D1FE845101B7C97DBED31247535FF`.
- The x86-64 `BOOTX64.EFI` is expected to remain byte-identical to Capstone 12 and is rechecked in the release matrix.
