# ZigOs Capstone 11.0

## Bounded process hierarchy and executable lifecycle

Capstone 11 adds a deterministic parent/child lifecycle to the legacy BIOS/i686 kernel. The release deliberately describes this as a **bounded fork-style clone/exec/wait contract**, not a complete POSIX process implementation: one child lifecycle may be active at a time, executable images use one bounded ELF32 `PT_LOAD`, and the child is dispatched synchronously when its parent waits. Within those limits, every claimed transition executes through real CPL3 code, private paging structures, process-owned descriptors, and the existing `int 0x80` boundary.

## Nineteen completed goals

1. **Child record allocation.** Syscall 23 reserves a free process-table slot and records a running child.
2. **PID and PPID identity.** Child PIDs remain monotonic; the child records and returns its exact parent PID.
3. **Private page directory.** Every child receives a distinct 4 KiB CR3 root copied from the kernel mappings.
4. **Private user page table.** The child owns a separate page table for `0x00400000..0x00405FFF`.
5. **Code-page cloning.** The parent executable page is copied into a distinct physical frame.
6. **Stack-page cloning.** The user stack is copied into a distinct physical frame.
7. **Service-page cloning.** Two grown-heap pages and one anonymous mapping are copied into three child frames.
8. **Physical-copy isolation.** Parent and child values at the same virtual address diverge without aliasing: child changes `DEADBEEF` to `AABBCCDD`, while the parent remains `DEADBEEF`.
9. **Descriptor inheritance.** Three parent descriptors are cloned with child ownership and independent descriptor slots.
10. **Pipe-reference inheritance.** Read/write endpoint reference counts are incremented for inherited pipe descriptors.
11. **Close-on-exec.** A read-only `HELLO.TXT` descriptor marked `CLOEXEC` is closed during image replacement while both pipe endpoints survive.
12. **Executable replacement.** Syscall 26 validates and loads `CHILD.ELF`, zeroes the replacement stack/service pages, patches its inherited handles, and changes the process name.
13. **Process-group assignment.** Syscall 28 places the child in a group led by its own PID.
14. **Process-group lookup.** Syscall 29 returns the group from both parent and child contexts.
15. **Group signal delivery.** Syscall 30 delivers signal 12 to the running child group; the child consumes and clears it through inherited syscall 22.
16. **Private-CR3 CPL3 execution.** Waiting dispatches `CHILD.ELF` at ring 3 after switching CR3, PID, and TSS `esp0` to child-owned state.
17. **Structured wait status.** Syscall 27 returns PID, exit code, terminal state, and child syscall count in a bounded 16-byte record.
18. **One-shot reaping.** The child can be waited exactly once and remains in the process table as an exited, waited record.
19. **Exact cleanup and restoration.** Exit closes both pipe endpoints; wait returns all seven frames and restores the outer parent CR3, TSS stack, PID, kernel return stack, mappings, descriptor table, and pipe table.

## ABI extension

Capstone 11 extends the inherited 22-call ABI with calls 23 through 31:

| Number | Service | Inputs | Result |
|---:|---|---|---|
| 23 | clone child | none | child PID |
| 24 | child peek | child PID, aligned user address | copied 32-bit value |
| 25 | child poke | child PID, aligned user address, value | zero on success |
| 26 | child exec | child PID, 11-byte FAT name | zero on success |
| 27 | wait child | child PID, 16-byte status pointer | reaped PID |
| 28 | set process group | PID, group | zero on success |
| 29 | get process group | PID | group ID |
| 30 | signal process group | group, signal | number delivered |
| 31 | process info | PID, 32-byte record pointer | zero on success |

All new user pointers use the existing page-by-page present/user/writable validator. Invalid process identity, state, alignment, executable geometry, group, signal, or repeat-wait operations return bounded negative error values and do not mutate the validated success path.

## Disk-loaded proof programs

### `ORCH.ELF`

- ELF32 little-endian Intel 80386 executable.
- Entry: `0x00400000`.
- Size: 1,937 bytes.
- FNV-1a32: `11986FD8`.
- FAT12 chain: `17 -> 18 -> 19 -> 20 -> EOC`.
- Parent exit: `0x70`.
- Parent syscalls: 23.
- Aggregate parent plus child syscalls: 30.

The orchestrator grows `brk`, maps one anonymous page, opens `HELLO.TXT` with close-on-exec, creates a pipe, writes `PARENT-TO-CHILD\r\n`, clones a child, proves copied-memory isolation, creates and signals the child process group, replaces the child image, reads process metadata, waits, receives `CHILD-TO-PARENT\r\n`, closes all parent descriptors, unmaps memory, contracts `brk`, and exits.

### `CHILD.ELF`

- ELF32 little-endian Intel 80386 executable.
- Entry: `0x00400000`.
- Size: 913 bytes.
- FNV-1a32: `7E1C062C`.
- FAT12 chain: `21 -> 22 -> EOC`.
- Exit: `0x77`.
- Syscalls: 7.

The child verifies its PID, PPID, process group, and pending signal; reads the exact 17-byte parent request from its inherited pipe; writes the exact 17-byte reply; and exits. Exit cleanup closes the two inherited pipe descriptors. The close-on-exec file descriptor is already absent.

## Exact live result

```text
process PID 0x00000007 ORCH.ELF exited 0x00000070 syscalls 0x0000001E child 0x00000008 child-syscalls 0x00000007 inherited 0x00000003 cloexec 0x00000001 signal 0x0000000C pipe-bytes 0x00000011 cleanup yes
```

The process table subsequently contains:

```text
PID 0x00000007 PPID 0x00000000 EXITED 0x00000070 ORCH.ELF waited no
PID 0x00000008 PPID 0x00000007 EXITED 0x00000077 CHILD.ELF waited yes
```

## Memory and resource proof

The kernel requires all of these postconditions simultaneously:

- Child CR3 is nonzero and differs from the parent kernel directory.
- Seven child frames are allocated and exactly seven are returned.
- Child code, stack, table, directory, two heap pages, and anonymous page are distinct frames.
- Parent virtual sentinel stays `DEADBEEF` after the child copy is changed to `AABBCCDD`.
- Three descriptors are inherited; exactly one closes on exec.
- Child exit cleanup closes exactly two pipe descriptors.
- No child-owned descriptor remains.
- No pipe object remains active.
- Parent heap and anonymous mappings are removed after use.
- Parent CR3, TSS `esp0`, PID, and outer kernel-return stack are restored.
- A second wait is rejected without changing the process or resource state.

## FAT12 and persistence

The initial volume contains eleven files. The two new executables consume clusters 17 through 22, moving the first deterministic writable pair to clusters 23 and 24.

The first boot still creates `NOTES.TXT` through `WRITER.ELF`:

- Root slot: 11.
- Size: 720 bytes.
- FAT chain: `23 -> 24 -> EOC`.
- FNV-1a32: `C6181D2F`.

The second boot reads, hashes, and stats the same file while performing zero writes and zero allocations. Its disk SHA-256 must remain unchanged.

## Validation matrix

- Canonical Zig formatting: required.
- ELF32 i386 compile/link: required.
- Host kernel geometry and 247-sector ceiling: required.
- Stage-1 chunked EDD loading and checksum16: required.
- Eleven-file FAT12 root and mirrored FAT verification: required.
- ORCH/CHILD ELF headers, hashes, embedded names/payloads, and exact chains: required.
- First QEMU BIOS session with sixteen interactions: required.
- Private-CR3 child execution and nested parent return: required.
- Offline persisted-image inspection: required.
- Read-only second QEMU boot and byte-identical image: required.
- Existing x86-64 UEFI HPET and ACPI-PM fallback regressions: required.
- Clean GitHub Actions rebuild and artifact upload: required.

## Reference artifacts

- Kernel: 65,112 bytes, 128 sectors at LBA 9-136.
- Kernel checksum16: `0x9815`.
- Kernel SHA-256: `D36AA9E31B5554E48A40311F2E4E60B46084B0D977B12FF3C7405C216657BF12`.
- Initial image SHA-256: `A5E0BFCC1C51785BC3108AAFCD0D8512C73D0DF0761C3581C5C34AA591BDDC53`.
- Persisted image SHA-256: `336BCA037C47BF35EE7AC081D341976CE6B634B7F3720E9FAA729905C70BF459`.
- The x86-64 `BOOTX64.EFI` is expected to remain byte-identical to Capstone 10 and is rechecked in the release matrix.
