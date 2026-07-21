# ZigOs Capstone 15.0

## Bounded x86-64 ELF64 userspace services

Capstone 15 moves the main x86-64 UEFI path forward with a deterministic, hardware-enforced ELF64 userspace service suite. The release builds a real ELF64 executable from hand-written x86-64 assembly, verifies it on the host, embeds the verified bytes, parses and verifies the image independently inside ZigOs, maps separate permission domains, enters CPL3, executes a 23-call service ABI, recovers two real user page faults, and returns to the kernel with exact resource restoration.

The scope is intentionally bounded. It is one synchronous service process with fixed virtual addresses, one RX text page, two RW data/BSS pages, one stack page, two heap pages, one anonymous page, one unmapped text gap, and one unmapped guard page. It is not a dynamic linker, general ELF loader, copy-on-write process model, multi-process userspace scheduler, signal-handler framework, filesystem-backed x86-64 VFS, or POSIX implementation. `yield` and `sleep` expose deterministic service semantics; the separately verified kernel preemptive scheduler remains the actual scheduling implementation.

## Sixty-four completed goals

1. **Deterministic long-mode workload source.** Added a freestanding NASM x86-64 CPL3 workload with no compiler or runtime dependency.
2. **Warning-clean payload assembly.** The canonical build assembles the workload as a flat binary with NASM warnings promoted to errors.
3. **Deterministic ELF64 construction.** Added a host generator that wraps the payload in a fixed ELF64 executable without external linker variation.
4. **Independent host verification.** Added a separate verifier for headers, segments, payload identity, syscall sites, guards, hashes, and exact image size.
5. **Verified package-local embedding.** The build copies the verified ELF into `src/generated` only after host validation and embeds that exact image into Zig.
6. **ELF identification validation.** The kernel checks the ELF magic and requires ELFCLASS64.
7. **Encoding and ABI validation.** The kernel requires little-endian encoding, current ELF version, System V ABI, and zeroed identification padding.
8. **Executable-type validation.** The kernel requires `ET_EXEC` and rejects other ELF object types.
9. **Machine validation.** The kernel requires `EM_X86_64` and rejects non-x86-64 images.
10. **Header-size validation.** The kernel requires exact ELF64 and program-header entry sizes.
11. **Bounded table validation.** The kernel accepts a bounded program-header count and requires no section-header table for this service image.
12. **Canonical entry validation.** The entry point must be a low-canonical userspace address.
13. **PT_LOAD-only contract.** Every program header in this bounded image must be `PT_LOAD`.
14. **Exact two-segment contract.** The service requires one RX segment and one RW segment.
15. **Alignment congruence.** File offsets and virtual addresses must have matching 4 KiB page offsets and page alignment.
16. **File-bound validation.** Every segment file range is checked with overflow-safe bounds before any copy.
17. **Virtual-bound validation.** Segment memory ranges are checked for overflow and low-canonical containment.
18. **Ordered non-overlap validation.** Load segments must be sorted and may not overlap after page rounding.
19. **W^X segment policy.** Read permission is mandatory and writable-plus-executable segments are rejected.
20. **Executable-entry containment.** The ELF entry must fall inside an executable load segment.
21. **Eight malformed-image rejections.** The live kernel rejects bad magic, class, machine, count, W+X flags, truncated memory, invalid alignment, and a noncanonical entry.
22. **Whole-image identity.** The kernel records FNV-1a64 `FB957FDFCD3FAC0F` for the complete embedded ELF image.
23. **Code identity.** Host and kernel validate the payload code identity; the source payload FNV-1a64 is `8B9C77E6A0D03758`.
24. **Data identity.** The generated data segment embeds and validates independent code/data FNV identities before execution.
25. **Seven bounded physical frames.** The process receives exactly seven below-4-GiB 4 KiB frames for text, data, BSS, stack, two heap pages, and anonymous memory.
26. **Allocator checkpointing.** The physical-frame allocator exposes a complete region/cursor/count checkpoint before process construction.
27. **Deterministic frame zeroing.** Every allocated process frame is zeroed before image or sentinel data is installed.
28. **RX text loading.** The first ELF segment is copied into its private text frame and the unused page tail remains zero.
29. **RW data loading.** The second segment's file bytes are copied independently into the data frame.
30. **BSS zero-fill.** The second segment's memory-only extension is represented by a separately verified zeroed BSS page.
31. **Private user stack.** A zeroed stack page carries a physical-base canary and a top-of-page aligned initial RSP.
32. **Hardware NX enablement.** CPUID extended feature discovery gates `EFER.NXE`, which is read back before both the inherited CPL3 smoke test and the ELF64 service; every user stack is NX.
33. **Generic low-canonical user mapping.** Paging now maps arbitrary aligned low-canonical user pages instead of only the inherited smoke-test addresses.
34. **Read-only executable code.** The CPU page table maps text user-readable and executable but not writable.
35. **Writable non-executable data.** The data page is user-writable and hardware NX.
36. **Writable non-executable BSS.** The BSS page is user-writable and hardware NX.
37. **Writable non-executable stack.** The stack page is user-writable and hardware NX.
38. **Unmapped text gap.** The page between the RX and RW segments remains absent.
39. **Unmapped guard page.** A dedicated address after the process service range remains absent.
40. **Zero additional page-table frames.** The service reuses the established user paging hierarchy and proves no page-table allocation occurred.
41. **PTE inspection and translation.** The live run requires RX text to be accessed but clean and data/BSS/stack to be accessed and dirty, then translates user addresses with requested permissions.
42. **Exact user unmapping.** Every unmap validates the expected physical frame, clears the PTE, reloads CR3, and verifies absence.
43. **Active-service syscall routing.** The existing two-syscall CPL3 smoke path remains unchanged; only an active ELF64 service is routed to the new ABI.
44. **Complete register preservation.** The workload verifies preserved `R12`, `R13`, and XMM6 state across the first transition.
45. **Process identity services.** `getpid` and `getppid` return bounded identities 64 and 1.
46. **Structured process status.** A 96-byte record exports identity, state, syscall count, break, mapping, signal, fault, descriptor, output, CR3, and selectors.
47. **Deterministic clock service.** The service begins at `0x1000` and reaches exactly `0x1004` after yield and sleep operations.
48. **Bounded output service.** A userspace pointer supplies the exact 34-byte message `ZigOs x86-64 ELF64 service active.`.
49. **Page-by-page pointer validation.** Copy-in and copy-out validate every touched page and required write permission.
50. **Overflow, crossing, and zero-length semantics.** Guard-crossing and wrapping ranges return `-EFAULT`; a zero-length request does not dereference its pointer.
51. **Userspace hashing.** A bounded FNV-1a64 syscall hashes executable and pipe-readback ranges without exposing kernel memory.
52. **Two-page program break.** `brk` grows two private heap pages, preserves sentinels, shrinks to baseline, and rejects an invalid stack address.
53. **Structured memory status.** A 64-byte record exports heap, break, page counts, anonymous state, NX state, guard state, and total mappings.
54. **Anonymous mapping lifecycle.** One RW/NX page maps at a fixed address, preserves `CAFEBABEDEADBEEF`, rejects a duplicate map, and unmaps once.
55. **Pipe creation.** The ABI transactionally creates read/write descriptors and copies the pair to validated userspace memory.
56. **Exact pipe I/O.** Userspace writes and reads the exact 24-byte `PIPE64-PAYLOAD-VERIFIED!` payload.
57. **Descriptor duplication.** `dup` creates the first free read endpoint and increments the pipe reference count.
58. **Targeted descriptor replacement.** `dup2` installs a write endpoint at descriptor 7 with exact reference accounting.
59. **Descriptor metadata and cleanup.** Status, close, EOF after last writer, and double-close rejection are verified; peak/opened and closed counts are both four.
60. **Directed pending signals.** Invalid PID rejection, signal 9 delivery, consume-and-clear, and empty second consume are verified.
61. **Deterministic yield/sleep semantics.** One yield advances the service clock by one; sleep rejects zero and accepts three bounded ticks.
62. **Strict unknown-call and handler validation.** Unknown syscall returns `-ENOSYS`; only an executable userspace address may register as a fault handler.
63. **Two real recoverable CPL3 page faults.** Instruction fetch from the NX data page records error `0x15`; read from the unmapped guard records error `0x04`; both capture CR2/RIP/RSP and resume at validated executable handlers.
64. **Exact terminal restoration.** Exit `0x64` closes all descriptors and the pipe, confirms text immutability plus BSS/heap/anonymous/stack sentinels, removes every service mapping, restores the allocator checkpoint and original CR3, and returns to the kernel.

The project cumulative verified count is 209 goals (`0xD1`), with 64 (`0x40`) new in Capstone 15.

## ELF64 image contract

The host-generated image has this fixed layout:

| Item | Value |
|---|---|
| ELF type | `ET_EXEC` |
| Machine | `EM_X86_64` |
| Entry | `0x0000008000100000` |
| Image size | 10,240 bytes |
| RX segment | file offset `0x1000`, virtual `0x0000008000100000`, 2,628 bytes |
| RW segment | file offset `0x2000`, virtual `0x0000008000102000`, 2,048 file bytes / 8,192 memory bytes |
| Encoded syscall sites | 51, including the failure-only exit site |
| Successful runtime calls | 50 |
| Payload FNV-1a64 | `8B9C77E6A0D03758` |
| ELF SHA-256 | `A166FAE8BCFD94663CA1CE0904AE2BF5D2044E831179910C173F9E4BCA1A8E28` |

## Virtual layout

```text
0x0000008000100000  RX text
0x0000008000101000  unmapped text gap
0x0000008000102000  RW/NX initialized data and result records
0x0000008000103000  RW/NX BSS
0x0000008000104000  RW/NX stack
0x0000008000105000  RW/NX heap page 0
0x0000008000106000  RW/NX heap page 1
0x0000008000107000  RW/NX anonymous mapping
0x0000008000108000  unmapped guard page
```

## Bounded x86-64 syscall ABI

| Call | Operation |
|---:|---|
| 0 | getpid |
| 1 | getppid |
| 2 | process information |
| 3 | deterministic clock |
| 4 | bounded output |
| 5 | FNV-1a64 user range |
| 6 | program break |
| 7 | memory information |
| 8 | anonymous map |
| 9 | anonymous unmap |
| 10 | pipe create |
| 11 | descriptor read |
| 12 | descriptor write |
| 13 | descriptor close |
| 14 | dup |
| 15 | dup2 |
| 16 | descriptor information |
| 17 | signal send |
| 18 | signal consume |
| 19 | deterministic yield |
| 20 | bounded sleep |
| 21 | fault-handler registration |
| 22 | exit |

All pointer-taking operations use page-by-page low-canonical validation and required PTE permissions. Errors use negative Linux-style integer values only as a compact bounded ABI convention; this does not claim Linux syscall compatibility.

## Live proof

```text
ELF64 userspace image loaded: bytes 10240, entry 0x0000008000100000, RX 2628, RW 2048/ 8192, parser rejects 8
ELF64 hashes: file FNV-1a64 0xFB957FDFCD3FAC0F, code 0x3A81E78DA90E35D8, data 0xAC60E5A9F7D909F0
x86-64 user PTE enforcement: NX yes, code read-only yes, data non-executable yes, guard unmapped yes, A/D yes
ELF64 service ABI: syscalls 50, rejected 13, pointer faults 5, output 34, pipe 24, descriptors peak/closed 4/4
ELF64 service scheduling/signals: deliveries 1, yields 1, slept ticks 3, clock 0x0000000000001004
ELF64 user faults recovered: NX CR2 0x0000008000102000 error 0x0000000000000015, guard CR2 0x0000008000108000 error 0x0000000000000004
ZigOs x86-64 Capstone 15 verified: goals 0x000000D1 new-goals 0x00000040 syscalls 0x00000032 faults 0x00000002 parser-rejections 0x00000008 frames 0x00000007 page-tables 0x00000000 cleanup yes
```

## Validation

- Clean canonical seven-stage UEFI build passes.
- Host ELF64 generator and independent verifier pass before and after kernel compilation.
- Canonical Zig formatting, NASM warning-as-error assembly, Python compilation, PowerShell parsing, and whitespace checks pass.
- Full HPET-backed x86-64 storage, USB, SMP, networking, DNS, NTP, TCP, scheduler, inherited CPL3 smoke, and Capstone 15 service boot passes.
- Full 24-bit ACPI PM timer fallback boot with HPET and PS/2 disabled passes the same mandatory Capstone 15 markers.
- The GitHub Actions workflow now performs a deterministic single-CPU x86-64 UEFI service/storage boot using the 24-bit ACPI PM fallback rather than build-only validation; local release gates continue to exercise the full network matrix.
- The inherited Capstone 14 i686 writable first boot, offline FAT12 check, and read-only second boot pass unchanged.

## Reference artifacts

- `BOOTX64.EFI`: 913,920 bytes, SHA-256 `0BED23A310182BCEF969F01BA925D9537A84D7055DB06611139AB951FC81EE42`.
- `service-user.elf`: 10,240 bytes, SHA-256 `A166FAE8BCFD94663CA1CE0904AE2BF5D2044E831179910C173F9E4BCA1A8E28`.
- Unchanged `ZIGOS386.BIN`: 103,624 bytes, SHA-256 `59D2A2FE18CB34F83EFEB493D268FA29092696E256211E148A0DDFB0758EA702`.
- Unchanged persisted `ZIGOS386.IMG`: 2,097,152 bytes, SHA-256 `9CD89D88469CDF05E0155D1AC2DF007B4474329D148FE01158DE08153A8009C3`.
