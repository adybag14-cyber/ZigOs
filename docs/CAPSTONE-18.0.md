# ZigOs Capstone 18.0 — persistent file descriptors and blocking pipes

Capstone 18 promotes file-descriptor and pipe semantics from temporary validation-only runtimes into the permanent x86-64 runtime introduced by Capstone 17. It adds **32 independently verified release goals** to the inherited 433-goal x86-64 total, reaching **465 cumulative goals (`0x1D1`)**.

The release marker is emitted only after the live descriptor contract has passed and the permanent shell has returned to exactly descriptors 0, 1 and 2 with no VFS-open-description or pipe leakage:

```text
ZigOs x86-64 Capstone 18 verified: goals 0x000001D1 new-goals 0x00000020 fd-namespaces yes open-descriptions yes shared-offsets yes duplication yes inheritance yes cloexec yes blocking-pipes yes shell-io yes cleanup yes
```

## Exact 32-goal contract

1. **C18-01** — Add a permanent-runtime descriptor subsystem separate from the temporary Capstone 15/16 descriptor proofs.
2. **C18-02** — Bind every descriptor namespace to an exact generation-tagged permanent-process handle.
3. **C18-03** — Provide thirty-two numeric descriptor slots per process.
4. **C18-04** — Provide a bounded pool of ninety-six reference-counted open-file descriptions.
5. **C18-05** — Provide a bounded pool of thirty-two permanent-runtime pipe objects.
6. **C18-06** — Install descriptor 0 as readable terminal input and descriptors 1 and 2 as writable terminal output for the serial shell.
7. **C18-07** — Allocate the lowest available numeric descriptor and reuse released numbers deterministically.
8. **C18-08** — Enforce process descriptor quotas transactionally before mutating descriptor, open-description or pipe tables.
9. **C18-09** — Assign generation-tagged identities to recyclable open-file-description slots.
10. **C18-10** — Maintain exact open-description reference counts across descriptor duplication and process-namespace cloning.
11. **C18-11** — Back regular-file descriptions with generation-safe VFS open handles.
12. **C18-12** — Share one file offset across every descriptor referring to the same open-file description.
13. **C18-13** — Implement lowest-free-number descriptor duplication equivalent to bounded `dup` semantics.
14. **C18-14** — Implement descriptor replacement equivalent to bounded `dup2` semantics, including target closure and self-duplication handling.
15. **C18-15** — Clone complete descriptor namespaces for fork-style process inheritance while sharing the inherited open descriptions.
16. **C18-16** — Keep descriptor flags process-local even when the underlying open description is shared.
17. **C18-17** — Implement a process-local close-on-exec descriptor flag.
18. **C18-18** — Close exactly the close-on-exec descriptors while retaining every other inherited descriptor.
19. **C18-19** — Release all descriptors, open-description references, VFS handles and pipe endpoints when a process namespace is destroyed.
20. **C18-20** — Sweep and reclaim namespaces whose generation-tagged process handles have become stale after reaping.
21. **C18-21** — Truncate through a writable descriptor while preserving the shared open-file offset.
22. **C18-22** — Make independent append-mode descriptions write at the file's current end rather than at a stale per-description offset.
23. **C18-23** — Route regular-file `cat` reads through transient numeric descriptors.
24. **C18-24** — Route shell `write` and `append` mutations through transient numeric descriptors.
25. **C18-25** — Route shell input redirection through the descriptor-backed file-read path.
26. **C18-26** — Route replacement and append output redirection through the descriptor-backed file-write path.
27. **C18-27** — Create bounded pipes as distinct readable and writable open-file descriptions.
28. **C18-28** — Preserve byte order across a wrapping 1,024-byte circular pipe buffer.
29. **C18-29** — Block a reader process on an empty pipe while at least one writer remains.
30. **C18-30** — Wake matching blocked readers when a writer makes pipe data available.
31. **C18-31** — Block a writer on a full pipe and wake matching writers when a reader frees capacity.
32. **C18-32** — Enforce final-writer EOF, final-reader broken-pipe behavior, exact endpoint reclamation and a leak-free release marker.

## Permanent descriptor model

The implementation deliberately separates three concepts:

- a **descriptor namespace** maps small process-local integers to open descriptions;
- an **open-file description** owns access mode, shared offset or pipe endpoint, generation and reference count;
- the **VFS object or pipe object** owns the underlying file or byte queue.

This means `dup`, `dup2` and fork-style namespace cloning share an offset, while close-on-exec remains attached to one process-local descriptor. A VFS handle is closed only when the final reference to its open description disappears.

### Bounded limits

| Resource | Limit |
|---|---:|
| Permanent process namespaces | 64, matching the process table |
| Descriptors per process | 32 |
| Open-file descriptions | 96 |
| Pipe objects | 32 |
| Bytes per pipe | 1,024 |
| Ordinary VFS file size | 16 KiB |

The model is allocation-free after initialization and uses fixed arrays suitable for the current freestanding kernel.

## Live `fdtest` contract

The permanent COM1 shell exposes `fdtest`, which runs a deterministic in-kernel integration workload after ordinary shell navigation, file mutation, pipeline and process tests. It proves:

- fd 3 lowest-free allocation;
- `dup` to fd 4 and `dup2` to fd 9;
- the shared `alpha-beta` offset and a child-appended `-child` suffix;
- one exact close-on-exec closure;
- five inherited file/terminal descriptors and two inherited pipe descriptors;
- descriptor-based truncation from sixteen to ten bytes without moving the shared offset;
- an empty-pipe reader block and one reader wakeup;
- a full-pipe writer block and one writer wakeup;
- 1,024-byte ring filling, 512-byte draining and wrapped tail delivery;
- EOF after the last writer closes;
- broken-pipe rejection after the last reader closes;
- child namespace release, terminal-process reaping and exact final cleanup.

Representative output:

```text
fdtest: descriptors 3 open 3 pipes 0 shared-offset yes clone yes cloexec yes read-block yes write-block yes eof yes broken-pipe yes ring yes clean yes
fdtest counters: dup 2 inherited 7 cloexec 1 blocked 1/1 wakeups 1/1 eof 4 broken 1
FD KIND       MODE OFD      REFS FLAGS OFFSET/BUFFERED
0 terminal  r-   0x00010001 1    -       0
1 terminal  -w   0x00010002 1    -       0
2 terminal  -w   0x00010003 1    -       0
```

The global EOF counter is four in the complete scripted session because ordinary descriptor-backed shell reads also reach EOF before `fdtest` runs. The `fdtest` contract itself compares counter deltas and therefore remains repeatable.

## Descriptor-backed shell I/O

Regular-file operations now use the permanent descriptor core:

- `cat FILE`;
- `write FILE TEXT...`;
- `append FILE TEXT...`;
- `COMMAND < FILE`;
- `COMMAND > FILE`;
- `COMMAND >> FILE`.

Pseudo-files such as `/proc/processes`, `/dev/console` and `/net/interfaces` remain generated kernel views rather than ordinary VFS-backed files.

The scripted session includes `wc < note.txt`, proving input redirection through a transient descriptor, and later verifies that the descriptor table has returned to fd 0—2 only.

## Isolated tests

The canonical `zig build test` graph now executes **29 unique `std.testing` declarations**:

- 10 descriptor/open-description/pipe tests;
- 5 VFS tests;
- 8 process-table tests;
- 6 parser/environment/editor tests.

The new descriptor tests cover lowest-free allocation, `dup`/`dup2`, shared offsets, independent append descriptions, inherited namespaces, close-on-exec, pipe blocking and wakeups, ring wrap, EOF, broken pipe, truncation, quota rollback and stale namespace sweeping.

## Complete runtime result

The bidirectional COM1 harness now sends thirty commands and requires zero failures:

```text
ZigOs persistent runtime shutdown: commands 30 failed 0 ticks 459 idle-halts 458 service-passes 459
ZigOs persistent VFS: nodes 40 files 10 directories 18 pseudo 12 mounts 5 bytes 30950 clean yes
ZigOs persistent processes: live 2 created 7 reaped 5 switches 41 signals 0 faults 1
ZigOs persistent descriptors: namespaces 1 fds 3 open 3 terminals 3 vfs 0 pipes 0 dup/inherited/cloexec 2/7/1 blocked 1/1 wakeups 1/1 eof 4 broken 1 clean yes
ZigOs x86-64 persistent runtime verified: loop permanent shell yes navigation yes files yes descriptors yes processes yes network-diagnostics yes explicit-shutdown yes
```

Tick and idle totals vary slightly with host scheduling. Descriptor identities, counts, state transitions, data and cleanup results are exact.

## Relationship to the 500-goal roadmap

Capstone release accounting and the general 500-goal roadmap are intentionally separate:

- Capstone 18 adds 32 granular release proofs, reaching 465 cumulative historical x86-64 goals.
- Four broad roadmap items are now complete: **G112, G191, G192 and G194**.
- The 500-goal roadmap therefore moves from 96/404 to **100 complete and 400 open**.

G175 remains open because pipes do not yet block and resume retained arbitrary CPL3 executable contexts. G193 remains open because the current bounded single-CPU model is not a general SMP-safe multiwriter atomic-append contract.

## Deliberate limitations

Capstone 18 does **not** claim:

- a general CPL3 file syscall ABI for permanent executable processes;
- storage-loaded arbitrary long-lived ELF64 execution;
- persistent-process fork or real in-place exec in the permanent process table;
- shell pipelines connected by live descriptor-backed pipes—the current shell still passes bounded intermediate buffers between stages;
- `poll`, `select`, `epoll`, asynchronous I/O or nonblocking descriptor flags;
- terminal process groups, controlling terminals or full job-control semantics;
- an SMP-safe general atomic-append guarantee;
- disk-backed x86-64 writes—the root VFS remains RAM-backed and `/boot` remains read-only;
- unbounded files, descriptors, pipes or process counts;
- POSIX compatibility or hostile-workload security.

## Reference artifact

The released x86-64 UEFI image is:

```text
BOOTX64.EFI
Size:    2,716,672 bytes
SHA-256: 4C7D5F0FC945F6F53306363C47418E3C63C60979CAA6E06C0B41C101E9382FA1
```

Clean Windows and Linux builds are byte-identical. The release requires both x86-64 QEMU profiles, the thirty-command runtime, the legacy i686 two-boot persistence regression and the complete hosted Linux/Windows CI matrix to pass on the release sources before the annotated tag is published.
