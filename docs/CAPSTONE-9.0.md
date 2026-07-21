# ZigOs Capstone 9.0 - Virtual Memory, Threading, IRQ Queues, and FAT Namespace

Capstone 9.0 extends the legacy BIOS/i686 runtime with sixteen independently observable goals. The release adds reusable virtual-memory operations, recoverable and contained page-fault paths, a richer four-thread scheduler, a real IRQ-fed keyboard ring, and reversible FAT12 namespace mutation. It preserves the ten Capstone 8.0 writable-userspace goals, so the final shell reports 26 cumulative goals (`0x1A`) and 16 new goals (`0x10`).

## Sixteen goals

### Virtual memory and fault handling

1. **Reusable page mapping** - map an aligned physical frame into an existing page table with explicit flags.
2. **Page-table query** - inspect a present PTE and recover its physical frame and permission bits.
3. **Page unmapping** - clear a present PTE, invalidate the target page, and return the removed mapping.
4. **TLB-coherent remapping** - replace a live mapping and prove that the virtual address immediately observes the new physical frame while the old frame remains unchanged.
5. **Demand-zero recovery** - recover a CPL3 not-present write fault at `0x00403000`, install a zeroed user-writable frame, retry the faulting instruction, and return `0xD00DFEED` to the kernel.
6. **Read-only containment** - remove write permission from the user code page and contain a CPL3 write with page-fault error code `0x07`.
7. **Supervisor isolation** - contain a CPL3 read from the supervisor-only kernel image at `0x00010000` with error code `0x05`.
8. **Guard-page containment** - leave `0x00404000` unmapped and contain a CPL3 write with error code `0x06`.

### Kernel threading and process control

9. **Kernel-thread control blocks** - track stack pointer, wake tick, quanta, and the states `free`, `ready`, `running`, `sleeping`, `blocked`, and `exited`.
10. **Four-thread preemption** - schedule four independent ring-0 workers for exactly three quanta each.
11. **Timer sleep deadlines** - suspend one worker until `timer_ticks + 4` without busy-waiting in that thread.
12. **Wait-queue blocking** - move one worker to a non-runnable blocked state.
13. **Event-driven wakeup** - signal the blocked worker from another thread and return it to the ready queue.
14. **Clean exit and restoration** - retire all four workers, preserve four stack canaries, and restore the bootstrap interrupt frame after 13 timer switches and 12 worker dispatches.

### Interrupt and filesystem state

15. **IRQ1 keyboard ring** - enqueue ordered make/break scan codes in a bounded 16-byte interrupt ring and prove `1E, 9E, 30, B0` with zero drops.
16. **FAT12 namespace lifecycle** - create a 600-byte two-cluster file, rename it, verify hash `A6F87E15`, unlink it, reclaim clusters `14 -> 15`, reuse cluster `14` through deterministic first-fit allocation, unlink again, and restore a residue-free eight-entry root before the normal persistence workload.

## Exact virtual-memory contract

The advanced VM test performs one new map, one remap, and two successful unmaps. The mapped alias is `0xC0001000`. Every page-table mutation executes `invlpg`, and the test restores all three temporary physical frames.

| Probe | Address | Expected result |
|---|---:|---|
| Demand-zero write | `0x00403000` | recovered, error `0x06`, value `0xD00DFEED` |
| Write to read-only user page | `0x00400200` | contained, error `0x07` |
| Read supervisor kernel page | `0x00010000` | contained, error `0x05` |
| Write unmapped guard page | `0x00404000` | contained, error `0x06` |

The probe boundary restores the caller PID before `INIT.ELF` runs, preventing validation-only user faults from contaminating the real boot process contract.

## Exact scheduler contract

- Four worker threads.
- Three quanta per worker.
- Thirteen total timer switches, including bootstrap restoration.
- Twelve worker dispatches.
- One sleep transition.
- One wait-queue block.
- One explicit signal.
- Two wakeups: one deadline wake and one signal wake.
- Four clean exits.
- Four intact 32-byte stack-canary regions.

## FAT12 namespace contract

At mount time, the kernel reads all nine sectors of the primary FAT into an aligned memory cache and compares every sector against the secondary FAT. All FAT12 entry reads then use the cache, eliminating command-boundary races from repeated metadata PIO. Entry mutations update the packed 12-bit cache first and write each affected sector to both FAT copies through the existing ATA read-after-write verification path. Both final shell sessions require the mirrored cache to remain loaded.

Every ATA read and write is a two-attempt transaction. Polling uses the alternate-status register with a 1,024-read bound. A failed command boundary triggers primary-channel software reset (`SRST`), drive reselection, and one complete sector retry; writes still require cache flush and byte-for-byte readback before success. This prevents a slow emulator from spending the entire session in an opaque 65,536-read poll.

On the first boot, the kernel performs this reversible sequence before entering the shell:

```text
TEMP.BIN (600 bytes, clusters 14 -> 15)
    -> rename MOVED.BIN
    -> verify FNV-1a32 A6F87E15
    -> unlink and free clusters 14 and 15
    -> create REUSE.BIN
    -> prove first cluster is 14
    -> unlink and free cluster 14
    -> reload root: exactly eight original files, no residue
```

Namespace accounting is then reset so the established `WRITER.ELF` contract remains exact. `WRITER.ELF` subsequently creates `NOTES.TXT` at clusters `14 -> 15`, and the second boot performs no namespace writes or allocations.

## Two-boot release gate

The QEMU harness requires all of the following:

- First boot reaches the sixteen-goal Capstone 9 marker.
- The namespace lifecycle completes and restores the original root/FAT state.
- The original Capstone 8 shell workload still creates and verifies `NOTES.TXT`.
- Offline inspection confirms root slot 8, 720 bytes, chain `14 -> 15 -> EOC`, and FNV-1a32 `C6181D2F`.
- A second boot reads, hashes, and stats `NOTES.TXT` using the same raw image.
- The second boot performs zero filesystem writes and zero allocations.
- The complete image SHA-256 is unchanged by the second boot.
- The COM1 harness drains every currently buffered line before sleeping and applies the 90-second limit to inactivity rather than total wall-clock runtime; every output line, command send, and matched result refreshes the deadline without weakening any exact marker assertion.

## Artifact identity

- Kernel physical entry: `0x00010000`.
- FAT12 partition start: LBA 256.
- Protected maximum kernel area: 247 sectors.
- Capstone 9 kernel: 51,212 bytes / 101 sectors at LBA 9-109.
- Kernel checksum16: `0xC8CC`.
- Kernel SHA-256: `D1E2E983B8ECAB63B0B14A2A42BEA90574FD223EEF722E908E6CF810A93842A3`.
- Initial image SHA-256: `5C2C6E0A6543BEC8FB1E74E0DD637AA356CC0B402BA62BC1D5086BEBA0A19602`.
- Persisted image SHA-256: `4AB05D6DF42FE9452AAB917434312834CFD2B4E25F39A028B61C2E2850835728`.

The independent x86-64 UEFI regression artifact must remain 888,832 bytes with SHA-256 `ABA23A4C97F504146B1633D846A3F5A46242BC6360CDE9DDA8909A98941F45C2`.
