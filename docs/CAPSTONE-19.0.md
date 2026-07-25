# ZigOs Capstone 19.0 — permanent VFS-loaded ELF64 execution

Capstone 19 connects the permanent x86-64 process table, descriptor layer and scheduler to genuine CPL3 executable contexts. It adds **32 independently verified release goals** to the inherited 465-goal x86-64 total, reaching **497 cumulative goals (`0x1F1`)**.

The release marker is emitted only after real VFS-loaded programs have exited, faulted, blocked and resumed; every private mapping and page-table page has been reclaimed; the descriptor contract remains clean; and the permanent shell has proved either real retained e1000e ping/DNS activity or explicit offline device absence without canned answers:

```text
ZigOs x86-64 Capstone 19 verified: goals 0x000001F1 new-goals 0x00000020 vfs-elf yes private-cr3 yes retained-contexts yes timer-preemption yes real-fault yes executable-pipes yes frame-reclamation yes network-facades-removed yes cleanup yes
```

## Exact 32-goal contract

1. **C19-01** — Generate six deterministic permanent-runtime ELF64 executables from warning-as-error NASM sources.
2. **C19-02** — Independently verify each generated ELF64 identity, header, two `PT_LOAD` entries, permissions, offsets and exact image size.
3. **C19-03** — Install the verified executables as ordinary `/bin/*.elf` files in the permanent VFS and as release artifacts.
4. **C19-04** — Make `run` and `exec` read executable bytes from the VFS and enter the parsed ELF64 entry point instead of creating a timed pseudo-job.
5. **C19-05** — Reserve a bounded 256-page physical arena for permanent executable contexts below 4 GiB.
6. **C19-06** — Recycle arena pages with zero-on-allocation, zero-on-release and exact peak/reclamation accounting.
7. **C19-07** — Allocate a reusable private PML4, PDPT, directory and page table for every retained executable context.
8. **C19-08** — Map executable `PT_LOAD` pages read-only/executable and writable data pages writable/non-executable under W^X.
9. **C19-09** — Construct a bounded one-page initial stack containing `argc`, `argv[]` and terminating null pointers.
10. **C19-10** — Leave an unmapped guard page above every permanent userspace stack.
11. **C19-11** — Install a read-only executable userspace fault trampoline in every permanent address space.
12. **C19-12** — Add an assembly entry that restores a complete saved GPR, RIP/RSP/RFLAGS and FXSAVE context before `iretq` to CPL3.
13. **C19-13** — Deliver timer-driven CPL3 validation on a 64 KiB bootstrap IST1 with a bottom canary, then install a separate canary-protected 64 KiB permanent-runtime IST1.
14. **C19-14** — Preempt non-cooperative permanent CPL3 code and return safely to the kernel scheduler without a userspace yield.
15. **C19-15** — Bind every executable context to an exact generation-tagged permanent process-table handle and PID.
16. **C19-16** — Clone the parent descriptor namespace into each real executable process and release it exactly once at termination.
17. **C19-17** — Provide permanent userspace identity, terminal write, tick, sleep, yield, close, duplication and bounded VFS-open syscalls.
18. **C19-18** — Validate every userspace buffer and string page-by-page with overflow-safe address arithmetic.
19. **C19-19** — Roll back both pipe descriptors transactionally if a userspace `pipe` result cannot be copied out.
20. **C19-20** — Return sleeping executables to the scheduler, wake them from hardware-tick deadlines and resume their saved CPL3 context.
21. **C19-21** — Rewind a blocked `int 0x80` instruction so pipe reads and writes retry after scheduler wakeup.
22. **C19-22** — Run a genuine CPL3 pipe reader until the permanent process table records `.blocked/.pipe_read`.
23. **C19-23** — Run a separate genuine CPL3 pipe writer that transfers exactly `PIPE-CPL` and wakes the blocked reader.
24. **C19-24** — Prove real executable pipe EOF, descriptor closure, endpoint reclamation and exact block/wakeup counter deltas.
25. **C19-25** — Run a CPL3 crash executable that performs an actual unmapped read and records vector 14 with CR2 `0x8000180000`.
26. **C19-26** — Terminate only the offending permanent userspace process through an exception-derived fault trampoline and preserve the shell.
27. **C19-27** — Launch a non-terminating CPL3 spin executable in the background, preempt it repeatedly, signal it, wait for it and reap it.
28. **C19-28** — Make `spawn PATH [ARGS...]` and executable-only trailing `&` create real retained userspace contexts rather than diagnostic records.
29. **C19-29** — Unmap every user page, release every page-table frame, restore the kernel CR3 and report zero live executable contexts at shutdown.
30. **C19-30** — Expand the canonical bidirectional COM1 session to 39 commands covering real `run`, `exec`, sleep, fault, pipe, preemption, default forced kill, blocking wait and cleanup.
31. **C19-31** — Remove canned network answers, retain the initialized e1000e owner for real bounded ICMP echo and DNS A queries when present, and report explicit unavailability when booted without the NIC.
32. **C19-32** — Add a portable source-contract verifier that rejects pseudo-job launchers, fabricated crash paths, canned network results and missing cleanup gates.

## Permanent executable model

The permanent runtime now owns up to eight retained executable contexts. Each context contains:

- one generation-tagged process-table handle;
- a private CR3 rooted in four recyclable page-table frames;
- up to 32 mapped user pages;
- a complete interrupt frame and aligned FXSAVE state;
- a one-page initial stack and one unmapped guard page;
- a bounded 4,096-byte terminal-output capture;
- exact image identity, fault information and preemption counts.

The runtime reserves 256 physical pages at initialization. It does not return those pages to the boot allocator, but it does recycle them internally and requires all pages to be free before the Capstone 19 marker can be emitted. The earlier 16 KiB bootstrap IST1 was expanded to 64 KiB after real multiprocess preemption proved it could overflow into an adjacent kernel page-table frame; a bottom canary is now checked after the complete boot-time CPL3 suite.

### Current userspace address window

```text
0x0000008000000000  beginning of the fixed 2 MiB userspace window
...                 validated ELF64 PT_LOAD pages
0x00000080001FD000  read-only executable fault trampoline
0x00000080001FE000  writable/non-executable one-page stack
0x00000080001FF000  unmapped stack guard
```

Only static `ET_EXEC`, x86-64, little-endian images accepted by the existing strict `elf64.zig` parser are supported. The current deterministic fixtures use one RX page and one RW/NX page.

## Permanent syscall subset

The retained executor uses a small ZigOs-specific `int 0x80` ABI:

| Number | Operation |
|---:|---|
| 64 | exit |
| 65 | write |
| 66 | read |
| 67 | getpid |
| 68 | sleep |
| 69 | yield |
| 70 | pipe |
| 71 | close |
| 72 | dup |
| 73 | dup2 |
| 74 | open |
| 75 | ticks |
| 78 | kernel-installed fault-trampoline return |

This is not a POSIX or Linux syscall ABI. Calls are bounded, pointer-validated and routed into the existing permanent VFS, descriptor and process-table implementations.

## Real command behavior

`run` and `exec` now execute VFS-resident bytes at CPL3. In this release both commands launch a foreground child process; `exec` does **not** replace the shell image in place.

Representative output:

```text
exec: mapped VFS ELF bytes 12288 hash 0x3D54A23EE5729EF5 into a private CR3; entering CPL3
hello from VFS-loaded CPL3 ELF64
exec: PID 3 state zombie status 0x2A CPU ticks 2 syscalls 3
```

`spawn` launches the same kind of real executable context in the background:

```text
[8] CPL3 started /bin/spin.elf ELF bytes 12288 hash 0x8CD4D0C9A24DB466
```

The `crash` command runs `/bin/crash.elf`; it does not call the process table's fault-accounting function directly:

```text
crash: real page fault follows
crash: contained genuine CPL3 exception in PID 5 vector 14 CR2 0x8000180000
```

The `pipex` command proves that permanent pipes block and wake executable contexts rather than only synthetic process records:

```text
PIPE-CPL
pipex: real CPL3 reader blocked; real CPL3 writer woke it; payload PIPE-CPL; pipe reclaimed
```

## Real bounded network status

The inherited boot suites exercise bounded e1000e, DHCP, ARP, ICMP, UDP, DNS, NTP, TCP and TFTP components under deterministic QEMU conditions. Capstone 19 now retains the initialized e1000e rings, DMA buffers, lease, gateway, DNS server and producer/consumer cursors into the permanent runtime.

With `-Network`, the permanent shell performs genuine device transactions rather than emitting fixtures:

```text
reply from 10.0.2.2: bytes=16 ttl=255 ...
localhost A 127.0.0.1 ttl 10800 aliases 0 ...
ZigOs permanent network: device yes ping 1 dns 1 failures 0 clean yes
```

The driver remains interrupt-first. After the strict boot-time MSI-X proofs have completed, descriptor DMA status may recover a completed runtime TX/RX operation when a later MSI-X edge is lost; boot validation itself still requires the real interrupt path.

Without the e1000e device, the same commands report the actual offline state:

```text
ifconfig: unavailable: e1000e was not initialized for this boot
ping: unavailable: e1000e was not initialized for this boot
dns: unavailable: e1000e was not initialized for this boot
ZigOs permanent network: device no ping 0 dns 0 failures 0 clean yes
```

The canonical harness also proves a sleeping spawned child completes under a genuinely blocking shell `wait`, then proves default `kill PID` performs an explicit forced signal-9 termination before one-time reap.

The canonical harness scopes its forbidden-fixture scan to output after `ZigOs persistent runtime online`, so deterministic boot codec tests may still use documentation addresses while the permanent shell is forbidden from leaking `192.0.2.42`, `deterministic-QEMU-path` or a fabricated reply.

## Complete runtime result

The canonical COM1 harness sends 39 commands and requires zero failures. One representative run reported:

```text
ZigOs persistent runtime shutdown: commands 39 failed 0 ticks 878 idle-halts 830 service-passes 878
ZigOs persistent processes: live 2 created 12 reaped 10 switches 112 signals 1 faults 1
ZigOs persistent descriptors: namespaces 1 fds 3 open 3 terminals 3 vfs 0 pipes 0 dup/inherited/cloexec 2/32/1 blocked 2/1 wakeups 2/1 eof 4 broken 1 clean yes
ZigOs permanent userspace: arena 256 used 0 peak 16 contexts 0 launches/exits/faults 7/5/1 preemptions/blocking/syscalls 42/3/19 reclaimed 56 clean yes
ZigOs permanent network: device yes ping 1 dns 1 failures 0 clean yes
```

Tick, switch and preemption totals may vary with host scheduling. Process states, exit/fault results, descriptor deltas, payload bytes and final cleanup are exact.

## Deliberate limitations

Capstone 19 does **not** claim:

- direct loading from a disk-backed executable filesystem; `/bin` currently resides in the boot-seeded RAM VFS;
- arbitrary ELF64 layouts, `ET_DYN`, dynamic linking, relocations or shared libraries;
- a flexible multi-page stack, environment vector or auxiliary vector;
- in-place POSIX `exec`; the shell command launches a foreground child;
- persistent-runtime `fork`, copy-on-write or general demand paging;
- a general terminal input syscall or controlling-terminal/job-control model;
- shell pipelines whose stages are separate executable processes; `pipex` is the bounded executable pipe proof;
- a retained userspace socket API or production network stack; `ping` and `dns` are bounded kernel-shell operations on one retained e1000e device;
- more than eight simultaneous executable contexts, 32 mappings per context or 4,096 captured output bytes;
- SMP scheduling of permanent userspace contexts; the current release gate uses one BSP runtime scheduler;
- POSIX compatibility, hostile-workload isolation or production security.

The inherited Capstone 15 and 16 suites remain valuable independent proofs of richer bounded process and memory mechanisms. Capstone 19 specifically connects a smaller, honest subset to the permanent runtime and leaves the broader unification work explicit.
