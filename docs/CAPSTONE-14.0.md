# ZigOs Capstone 14.0

## Bounded recyclable task generations

Capstone 14 extends the legacy i686 asynchronous runtime from one release-specific child wave into a reusable, generation-safe task lifecycle. The scope is deliberately bounded and testable: at most four scheduled task contexts are live at once; each owns one page-directory frame, one page-table frame, one 4 KiB code frame, one 4 KiB user-stack frame, and one fixed 4 KiB ring-0 privilege stack. The kernel retains at most sixteen terminal tombstones, twenty-four process records, and sixteen descriptors. Scheduling remains single-CPU IRQ0 round robin. ELF replacement remains one validated, executable, single-page `PT_LOAD` segment at `0x00400000` with a fixed user stack at `0x00402000`-`0x00403000`.

This release does not claim full POSIX `fork`/`exec`, copy-on-write, unrestricted ELF layouts, dynamic stacks, priorities, SMP process migration, signal handlers, multi-threaded processes, or unbounded process creation.

## Thirty-two completed goals

1. **Generation-tagged task handles.** A public handle combines a 16-bit generation with a one-based bounded slot identity.
2. **Generation advancement.** Every successful terminal reclaim advances the slot generation and skips the invalid zero generation.
3. **Stale poll rejection.** Polling a reclaimed generation fails without exposing the replacement occupant.
4. **Stale wait rejection.** Waiting on a reclaimed generation fails without consuming another task's terminal record.
5. **Stale signal rejection.** Directed signaling validates both slot and generation before touching pending-signal state.
6. **Live-slot recycling.** Nine successful spawns execute through a four-slot runtime, proving eight deterministic slot reuses.
7. **Process-record recycling.** Ten internal process records are returned to the free table and reused without exhausting the twenty-four-entry bound.
8. **Terminal tombstones.** Sixteen bounded historical slots retain terminal identity after live context and process-record reclamation.
9. **Extended status record.** A 48-byte record exports handle, PID, PPID, state, exit code, quanta, syscall count, completion order, lifecycle flags, exec metadata, inherited/CLOEXEC counts, and fault details.
10. **Handle-returning spawn.** Syscall 49 creates a scheduled ELF task and returns its generation-safe handle.
11. **Current-handle query.** Syscall 52 exposes the executing scheduled task's exact handle and rejects an unscheduled outer process.
12. **Handle-aware polling.** Syscall 53 reads live task state without reaping it.
13. **Handle-aware blocking wait.** Syscall 54 preserves the outer parent's complete return frame and blocks until the selected generation is terminal.
14. **Handle-directed signal delivery.** Syscall 55 delivers a bounded pending signal only to a live matching generation.
15. **Scheduled fork-from-current-context.** Syscall 50 creates a runnable child from the current saved CPL3 context.
16. **Parent fork result.** The parent resumes with the exact generation-tagged child handle.
17. **Child fork result.** The copied child frame resumes from the same instruction stream with `EAX = 0`.
18. **Saved CPU-frame cloning.** The kernel verifies copied `EIP`, user `ESP`, selectors, flags, and general register frame before scheduling the child.
19. **Executable-page cloning.** The parent and child code frames are copied byte-for-byte and independently hashed.
20. **User-stack cloning.** The complete 4 KiB user stack is copied byte-for-byte before either branch resumes.
21. **Private paging state.** Forked parent and child use distinct page-directory, page-table, code, and stack physical frames at the same user virtual addresses.
22. **Private privilege stack.** The child owns a distinct 4 KiB ring-0 stack and TSS `esp0` follows every selected context.
23. **Current-directory inheritance.** The child process record inherits the parent's exact FAT12 cwd cluster.
24. **Process-group inheritance.** The child retains the parent's process group across fork and both exec replacements.
25. **Descriptor inheritance.** Four process-owned descriptors are cloned into independent child descriptor slots.
26. **Pipe-reference inheritance.** Read/write endpoint references are incremented transactionally and later return to zero.
27. **Atomic in-place exec.** Syscall 51 loads a replacement image into a temporary frame and commits only after full validation; two missing-image attempts prove code, stack, name, identity, descriptors, and frame accounting remain unchanged.
28. **Verified code replacement.** Successful exec copies and independently hashes the replacement page before execution.
29. **Fresh execution state.** Successful exec zeroes the complete user stack and resets `EIP`, user `ESP`, selectors, flags, and all general registers to the fixed entry contract.
30. **Exact exec identity and descriptor semantics.** PID, task handle, paging frames, process group, and cwd survive; the process name changes and one CLOEXEC descriptor closes in each branch.
31. **Scheduled fault containment.** A CPL3 page fault records vector 14 and address `0x00800000`, closes resources, selects the next context through the exception return stub, and leaves the outer kernel alive.
32. **Exact multi-generation restoration.** Ten terminals, ten waits, one adoption/auto-reap, nine wakeups, ten parent restorations, every descriptor/pipe closure, every process-record reclaim, and every temporary frame return to the original baseline.

The cumulative verified release count is 145 goals (`0x91`), with 32 (`0x20`) new in Capstone 14.

## ABI extension

Capstone 14 extends the inherited 48-call CPL3 ABI with calls 49 through 55:

| Call | Operation | Result |
|---:|---|---|
| 49 | Spawn bounded task generation | Generation-tagged handle or bounded error |
| 50 | Fork current scheduled context | Parent receives child handle; child receives zero |
| 51 | Replace current image | Does not return on success; atomic bounded error on failure |
| 52 | Query current task handle | Exact handle or non-task error |
| 53 | Poll handle | 48-byte status without reaping |
| 54 | Wait handle | Blocking terminal status and one-shot reclaim |
| 55 | Signal handle | Pending signal set only for a live matching generation |

A handle has the bounded form:

```text
bits 31..16  generation
bits 15..0   one-based slot (1..4)
```

The proof advances slot one through handles `0x00010001` to `0x00090001`; the fork child uses slot two handle `0x00010002`. Final generations are `10/2/1/1`.

## Deterministic CPL3 workload

`GENRUN.ELF` executes 38 outer-parent calls and its scheduled tasks execute 69 calls, for 107 calls (`0x6B`) total. It creates ten terminal generations:

| Completion | Handle | Final image | Outcome |
|---:|---:|---|---|
| 1-6 | `00010001`-`00060001` | `REUSE.ELF` | Exit `0x90`; generation three consumes signal 7 |
| 7 | `00070001` | `EXECA.ELF` | Fork parent, failed exec rollback, successful exec, exit `0xA1` |
| 8 | `00010002` | `EXECB.ELF` | Fork child, four inherited descriptors, adoption/auto-reap, exit `0xB2` |
| 9 | `00080001` | `FAULT.ELF` | Contained page fault, exit `0x8E` |
| 10 | `00090001` | `REUSE.ELF` | Final slot reuse, exit `0x90` |

The kernel independently validates all 37 values written by `GENRUN.ELF`, all ten tombstones, the final 48-byte status, exact syscall/rejection totals, completion order, fork/exec metadata, signal consumption, fault details, generation counters, process-table absence, descriptor and pipe closure, CR3/TSS/PID restoration, and the physical-frame baseline.

The live marker is:

```text
process PID 0x0000000D GENRUN.ELF exited 0x00000074 syscalls 0x0000006B taskgen-goals 0x00000020 calls 0x0000006B handles 0x00010001->0x00090001 generations 0x0000000A/0x00000002 fork yes exec yes stale yes fault-contained yes frames-restored yes
```

## Deterministic disk layout

The initial FAT12 root contains twenty-one files. New identities are:

| File | Bytes | FNV-1a32 | FAT12 chain |
|---|---:|---:|---|
| `GENRUN.ELF` | 2,864 | `D84697C0` | `34->35->36->37->38->39` |
| `REUSE.ELF` | 664 | `30A2BF85` | `40->41` |
| `FORKER.ELF` | 1,144 | `ADB21589` | `42->43->44` |
| `EXECA.ELF` | 660 | `8E043930` | `45->46` |
| `EXECB.ELF` | 660 | `21F7AB51` | `47->48` |
| `PATHS.ELF` | 4,024 | `38C1C0AD` | `49->50->51->52->53->54->55->56` |

Writable allocation begins at cluster 57. The first boot persists:

```text
/HOME                         cluster 57
/HOME/DOCS                    cluster 58
/HOME/ARCHIVE/LOG.TXT         clusters 59 -> 60
/HOME/ARCHIVE                 cluster 61
/NOTES.TXT                    clusters 62 -> 63
```

The offline verifier checks root slots 20-22, both FAT copies, all directory links and tombstones, exact file contents and hashes, and cluster 64 remaining free. The second boot performs zero writes and zero allocations and leaves the complete persisted image unchanged.

## Release markers

```text
ZigOs i686 Capstone 14 first session verified: goals 0x00000091 new-goals 0x00000020 root-files 0x00000016 processes 0x0000001A waits 0x0000000F creates 0x00000001 truncates 0x00000001 writes 0x00000002 seeks 0x00000001 allocations 0x00000002 notes 0x000002D0 hash 0xC6181D2F chain 0x0000003E->0x0000003F hierarchy 0x0000003B->0x0000003C hierarchy-hash 0x36F73195 async yes taskgen yes fault-contained yes descriptors-closed yes commands 0x00000012
```

```text
ZigOs i686 Capstone 14 persistence session verified: goals 0x00000091 inherited-goals 0x00000071 root-files 0x00000016 notes 0x000002D0 hash 0xC6181D2F chain 0x0000003E->0x0000003F hierarchy 0x0000003B->0x0000003C hierarchy-hash 0x36F73195 writes 0x00000000 allocations 0x00000000 descriptors-closed yes commands 0x00000003
```

## Validation

- Canonical i686 build and Zig formatting pass.
- Static BIOS, stage-1, kernel, 21-file FAT12, ELF identity, chain, and instruction-contract verification pass.
- The complete first mutation boot, offline persisted-image inspection, and read-only second boot pass.
- Three consecutive rebuild-and-two-boot repetitions pass.
- The inherited x86-64 UEFI artifact remains byte-identical and both HPET and 24-bit ACPI PM timer hardware/network regressions pass.

## Reference artifacts

- `BOOTX64.EFI`: 888,832 bytes, SHA-256 `ABA23A4C97F504146B1633D846A3F5A46242BC6360CDE9DDA8909A98941F45C2`.
- `ZIGOS386.BIN`: 103,624 bytes, 203 sectors at LBA 9-211, checksum16 `0xB785`.
- Kernel SHA-256: `59D2A2FE18CB34F83EFEB493D268FA29092696E256211E148A0DDFB0758EA702`.
- Initial image SHA-256: `3F162475D39DE25A2B3F50FE6D9FF8857DAC231191AA0B046D8A64C2B93881A2`.
- Persisted image SHA-256: `9CD89D88469CDF05E0155D1AC2DF007B4474329D148FE01158DE08153A8009C3`.
