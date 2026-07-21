# ZigOs Capstone 10.0 - Process Services, IPC, Namespace Syscalls, and PCI Discovery

Capstone 10.0 adds eighteen independently verified goals to the legacy BIOS/i686 path while retaining every Capstone 9 virtual-memory, threading, interrupt-queue, writable-FAT12, and two-boot persistence contract.

## Eighteen-goal contract

### User memory services

1. **Mapped user-range validation** - validate every page crossed by a user buffer, require present/user permissions, require writable PTEs for output buffers, reject wraparound, and bound access to `0x00400000..0x00406000`.
2. **Program-break query and growth** - expose syscall 9 and grow a process break from `0x00403000` to `0x00405000`, mapping two zeroed user pages.
3. **Program-break contraction** - shrink the break to `0x00403000`, unmap both pages, invalidate their TLB entries, and preserve physical sentinels for post-exit verification.
4. **Anonymous mapping** - expose syscall 10 for one fixed read/write anonymous page at `0x00405000`.
5. **Explicit unmapping** - expose syscall 11, remove the anonymous PTE, invalidate the page, and reject duplicate or malformed unmaps.

### Process and clock services

6. **Parent identity** - expose syscall 12 and return the exact parent PID retained in the process table.
7. **Monotonic uptime** - expose syscall 13 and return the current PIT tick counter without modifying scheduler state.
8. **Interrupt-driven sleep** - expose syscall 14, sleep through real 100 Hz IRQ0 delivery, and return the observed tick delta.
9. **Pending process signals** - expose syscalls 21 and 22 to set one bounded pending signal on a PID, retrieve it once, and clear it atomically.

### Filesystem namespace services

10. **Userspace stat** - expose syscall 15 and copy a bounded 16-byte record containing size, first cluster, attributes, and object type.
11. **Userspace rename** - expose syscall 16, validate two FAT 8.3 names in user memory, and update the on-disk root entry.
12. **Userspace unlink** - expose syscall 17, reject open targets, mark the root entry deleted, free its chain in both FAT mirrors, and reload the VFS root.

### IPC and descriptor services

13. **Pipe creation** - expose syscall 18 and allocate one of four fixed-capacity 256-byte pipe objects plus process-owned read/write descriptors.
14. **Pipe transfer and EOF** - route existing read/write syscalls through descriptor kinds, preserve byte ordering, and return zero after all writers close and buffered data is exhausted.
15. **Descriptor duplication** - expose syscall 19 and duplicate a descriptor into the first free slot while incrementing pipe endpoint references.
16. **Targeted descriptor duplication** - expose syscall 20, replace a chosen descriptor transactionally, and preserve exact pipe reader/writer accounting.
17. **Exit-time IPC cleanup** - close every process-owned file and pipe descriptor through the normal close path so endpoint references and object lifetime remain correct.

### Hardware discovery

18. **Native PCI enumeration** - add 32-bit port I/O primitives, access configuration mechanism 1 through `0xCF8/0xCFC`, verify the QEMU i440FX host bridge `8086:1237`, and enumerate function 0 across bus 0.

## Ring-3 SERVICE.ELF proof

The deterministic FAT12 image adds `SERVICE.ELF` as a real ELF32 Intel 80386 executable:

- Size: 1,362 bytes (`0x552`).
- FAT chain: `14 -> 15 -> 16 -> EOC`.
- FNV-1a32: `7C65C5CE`.
- Entry: `0x00400000`.
- One executable `PT_LOAD`, with a 4 KiB memory image.

`SERVICE.ELF` executes 30 `int 0x80` calls and exits with code `0x66`. It:

1. Queries and grows `brk`.
2. Writes sentinel `DEADBEEF` through the first heap mapping.
3. Maps and writes sentinel `CAFEBABE` through an anonymous mapping.
4. Unmaps the anonymous page.
5. Reads parent PID and uptime.
6. Sleeps for two or more PIT ticks.
7. Creates `TEMP2.BIN`, writes 18 bytes, and stats it.
8. Renames it to `RENAMED.BIN`, stats it again, and unlinks it.
9. Creates a pipe, writes `SERVICE-PIPE-OK!\r\n`, duplicates its read endpoint, and uses `dup2` for the write endpoint.
10. Reads the exact payload, closes every writer, proves EOF, and closes the final reader aliases.
11. Sends signal 9 to itself, consumes it exactly once, and proves the pending field clears.
12. Shrinks `brk`, exits, and leaves no mapped service page, descriptor, pipe, signal, file, or allocated FAT cluster behind.

Exact shell result:

```text
process PID 0x00000006 SERVICE.ELF exited 0x00000066 syscalls 0x0000001E services 0x00000012 pipe-bytes 0x00000012 sleep-ticks 0x00000002 signal 0x00000009 cleanup yes
```

## PCI contract

The kernel uses PCI configuration mechanism 1 and requires:

- Host bridge identity `8086:1237`.
- Host class code `0x06`.
- At least three function-0 devices on bus 0.
- The reference QEMU machine exposes four devices.

Exact marker:

```text
ZigOs i686 PCI verified: mechanism-1 yes bus 0x00000000 devices 0x00000004 host 8086:1237 class 0x06 config-ports 0x0CF8/0x0CFC
```

## Filesystem and persistence contract

The initial FAT12 volume contains nine files. `SERVICE.ELF` occupies clusters 14-16, so all reversible namespace tests and the persistent writer move to clusters 17-18.

The first boot performs two independent writable lifecycles:

- The inherited kernel namespace test creates, renames, unlinks, reclaims, and reuses clusters `17 -> 18`, then restores the original nine-file root.
- `SERVICE.ELF` creates and removes its own 18-byte file, proves first-fit allocation at cluster 17, and resets namespace accounting.
- `WRITER.ELF` then creates persistent `NOTES.TXT`, 720 bytes, at `17 -> 18 -> EOC`, with FNV-1a32 `C6181D2F`.

Offline inspection verifies both FAT copies, root slot 9, chain geometry, content, and hash. A second boot reads and stats `NOTES.TXT`, performs zero writes and zero allocations, and leaves the complete image SHA-256 unchanged.

## Exact release markers

First-session marker:

```text
ZigOs i686 Capstone 10 first session verified: goals 0x0000002C new-goals 0x00000012 root-files 0x0000000A processes 0x00000008 waits 0x00000001 creates 0x00000001 truncates 0x00000001 writes 0x00000002 seeks 0x00000001 allocations 0x00000002 notes 0x000002D0 hash 0xC6181D2F chain 0x00000011->0x00000012 fault-contained yes descriptors-closed yes commands 0x0000000E
```

Persistence marker:

```text
ZigOs i686 Capstone 10 persistence session verified: goals 0x0000002C inherited-goals 0x0000001A root-files 0x0000000A notes 0x000002D0 hash 0xC6181D2F chain 0x00000011->0x00000012 writes 0x00000000 allocations 0x00000000 descriptors-closed yes commands 0x00000003
```

Capstone 10 therefore reports 44 cumulative verified goals (`0x2C`), including 18 new goals (`0x12`).

## Reference artifact identity

- Kernel physical entry: `0x00010000`.
- FAT12 partition start: LBA 256.
- Protected maximum kernel area: 247 sectors.
- Capstone 10 kernel: 58,144 bytes / 114 sectors at LBA 9-122.
- Kernel checksum16: `0x3874`.
- Kernel SHA-256: `255441B1F42100DFF7E319D96659731F07270FA2155D8BFF24DA04ABD07B4340`.
- Initial image SHA-256: `864CB1E1C3AD79A06A336F9CE76E4B59CD940F2D69298B4EB4CDF0527E189C42`.
- Persisted image SHA-256: `A1514EF5B466DB72906C7253F88A520613578E2484211C7D0E3039CECF8CC44D`.

The independent x86-64 UEFI artifact must remain 888,832 bytes with SHA-256 `ABA23A4C97F504146B1633D846A3F5A46242BC6360CDE9DDA8909A98941F45C2`.
