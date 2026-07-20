# ZigOs Capstone 8.0 - Persistent Writable Userspace

Capstone 8.0 upgrades the legacy BIOS/i686 runtime from a read-only userland file demonstration into a deterministic writable operating-system environment. The release contract is divided into ten independently observable goals and is verified through a two-boot QEMU session over one unchanged raw disk image.

## Ten achieved goals

### 1. Verified ATA PIO writes

The primary-master ATA driver now issues 28-bit PIO sector writes with command `0x30`, transfers all 256 words, flushes the device cache with command `0xE7`, reads the same LBA back, and compares all 512 bytes before reporting success. Failed readiness, DRQ, flush, readback, or byte comparison aborts the mutation.

### 2. Multi-cluster FAT12 reads

FAT12 traversal is no longer limited to one cluster. The kernel validates bounded chains, detects premature termination and invalid cluster values, and reads across sector/cluster boundaries. The deterministic 1,300-byte `BIG.TXT` spans clusters `5 -> 6 -> 7 -> EOC` and must hash to FNV-1a32 `0xE5D120DF` both at boot and through the shell.

### 3. Mirrored FAT12 allocation and freeing

The kernel can read and update packed 12-bit entries, including entries that cross a sector boundary. Every mutation is written to both FAT copies. First-free allocation, EOC assignment, chain linking, and bounded chain freeing are implemented with exact counters.

### 4. Writable root-directory metadata

The VFS can create a free 8.3 root entry, update its first cluster and byte size, and truncate an existing node. Root scanning uses independent storage from FAT traversal so validating one file cannot corrupt directory iteration.

### 5. Multi-cluster VFS write, seek, and append

Descriptors now carry owner PID, access flags, and persistent offsets. Reads and writes cross cluster boundaries, allocate new clusters transactionally, update root metadata, and enforce a 4 KiB per-file bound. Seek supports beginning, current offset, and end; append forces every write to the current file size.

### 6. Extended CPL3 filesystem ABI

The `int 0x80` ABI now contains eight calls:

| Number | Call |
|---:|---|
| 1 | console `write` |
| 2 | `getpid` |
| 3 | `exit` |
| 4 | file `open` with read/write/create/truncate/append flags |
| 5 | file `read` |
| 6 | file `close` |
| 7 | file `write` |
| 8 | file `seek` |

User pointers remain range-checked and wrap-safe. File operations enforce descriptor ownership, access mode, transfer bounds, and cleanup on exit or fault.

### 7. Disk-loaded writer application

`WRITER.ELF` is a real 1,488-byte ELF32 Intel 80386 executable stored across clusters `11 -> 12 -> 13 -> EOC`. It executes at CPL3 and performs exactly nine syscalls:

1. create/truncate/open `NOTES.TXT` for reading and writing;
2. write 700 deterministic bytes;
3. seek to byte zero;
4. read the 700 bytes back into user BSS;
5. close;
6. reopen in append mode;
7. append `APPEND-PERSIST-OK!\r\n`;
8. close;
9. exit with code `0x55`.

The resulting file is exactly 720 bytes with FNV-1a32 `0xC6181D2F` and deterministic chain `14 -> 15 -> EOC`.

### 8. Generic ELF execution

The shell no longer has separate hard-coded INIT and CAT launch paths. `run FILE.ELF` resolves a FAT 8.3 name, reads an arbitrary bounded ELF through VFS, validates ELF32/i386 identity and one executable `PT_LOAD`, maps and zero-fills the segment, assigns a PID, enters CPL3, and restores heap resources after exit or fault.

### 9. Wait semantics and contained process faults

Process records now retain PID, parent PID, exit/fault state, fault vector, fault address, and waited status. `wait PID` accepts only a terminated unwaited child belonging to the caller and returns its exit code once. A disk-loaded `FAULT.ELF` deliberately accesses unmapped virtual address `0x00800000`; page fault vector 14 is converted into process exit `0x8E`, owned descriptors are closed, and the kernel shell continues.

### 10. Disk-loaded concurrent userspace and persistence

`SPINA.ELF` and `SPINB.ELF` are loaded from FAT12 into separate physical code pages and independent CR3 address spaces. Both execute at `0x00400000`, increment virtual address `0x00400100`, receive three PIT quanta each across seven switches, use distinct kernel privilege stacks, preserve physical tags `0x11` and `0x22`, and release all eight temporary frames.

The release harness then proves persistence:

1. build one raw image;
2. boot it and execute the 14-command first session;
3. create and validate `NOTES.TXT` from ring 3;
4. terminate QEMU only after the final flush/readback marker;
5. inspect both FAT copies, the root entry, chain, content, and hash offline;
6. boot the same image again without rebuilding;
7. read/hash/stat `NOTES.TXT` from the second kernel instance;
8. require zero writes and zero allocations during that boot;
9. require the complete image SHA-256 to remain unchanged across the second session.

The QEMU harness uses `cache=unsafe` only to avoid a pathological Windows-host `fsync` translation for the emulated ATA `FLUSH CACHE` command. The guest still issues command `0xE7`, waits for completion, rereads every changed sector, and compares all 512 bytes. After QEMU exits, the independent host verifier reads the raw image directly, and the second boot plus unchanged-image SHA-256 check remain mandatory.

## Deterministic initial filesystem

| File | Bytes | Initial cluster chain | FNV-1a32 |
|---|---:|---|---:|
| `HELLO.TXT` | 86 | `2 -> EOC` | `A9F660F2` |
| `INIT.ELF` | 423 | `3 -> EOC` | `4E34353F` |
| `CAT.ELF` | 510 | `4 -> EOC` | `9CD11469` |
| `BIG.TXT` | 1,300 | `5 -> 6 -> 7 -> EOC` | `E5D120DF` |
| `SPINA.ELF` | 264 | `8 -> EOC` | `FD5D48A0` |
| `SPINB.ELF` | 264 | `9 -> EOC` | `FD5D48A0` |
| `FAULT.ELF` | 262 | `10 -> EOC` | `3A59C4D6` |
| `WRITER.ELF` | 1,488 | `11 -> 12 -> 13 -> EOC` | `267B866B` |

After the first boot, `NOTES.TXT` occupies root slot 8, contains 720 bytes, and uses clusters `14 -> 15 -> EOC`.

## Exact first-session accounting

- Ten goals reported complete.
- Nine root files after mutation.
- Seven retained process records.
- One successful wait, for PID 6.
- One create and one truncate.
- Two VFS writes totalling 720 bytes.
- One seek and a 700-byte readback.
- Two allocated clusters.
- One contained user page fault at `0x00800000`.
- Zero leaked descriptors and zero unknown commands.
- Thirteen operational shell commands, excluding `exit`.

## Build and image contract

- Kernel physical entry: `0x00010000`.
- FAT12 partition start: LBA 256.
- Protected maximum kernel area: 247 sectors.
- ATA command issue is gated on `BSY=0` and `DRQ=0`; all polling loops are explicitly bounded.
- Capstone 8 kernel: 41,948 bytes / 82 sectors at LBA 9-90.
- Kernel checksum16: `0xEE2D`.
- Kernel SHA-256: `E626432D97EA8A42CAB9BAC1B519A0AEBEBC2096F7B3E3E3D8BD62720A2F5AD2`.
- Initial image SHA-256: `0A478B127FF14E3D3D13F83D3A3E2E321F018C89AB91131B4844CE058E5184E2`.
- Persisted image SHA-256: `47080279C1A72F053E3715CCE2B499CEE8D4FCB31807F300C7B8773934F6E6C2`.

The x86-64 UEFI artifact remains an independent regression target and must retain its established byte identity.
