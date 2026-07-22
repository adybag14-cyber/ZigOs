# ZigOs Capstone 12.0

## Hierarchical FAT12 paths and persistent directories

Capstone 12 extends the legacy BIOS/i686 filesystem from a writable root-only namespace to a bounded hierarchical FAT12 path layer. The scope is intentionally precise: path inputs are at most 48 bytes and four non-dot components, names use uppercase-compatible FAT 8.3 entries, and each subdirectory occupies exactly one 512-byte cluster. This release does not claim VFAT long names, multi-cluster directories, hard links, mount points, permissions, or crash-consistent journaling.

## Twenty-three completed goals

1. **Bounded path inputs.** Every new syscall validates user memory page by page and rejects empty, over-48-byte, or over-four-component paths.
2. **FAT 8.3 component parsing.** Path components are normalized through the existing strict short-name parser before lookup or mutation.
3. **Absolute resolution.** Paths beginning at `/` resolve from the FAT12 root directory.
4. **Relative resolution.** Paths without a leading slash resolve from the calling process's current directory.
5. **Separator normalization.** Repeated `/` separators are skipped; `PATHS.ELF` resolves `/HOME//ARCHIVE///LOG.TXT` successfully.
6. **Dot-component handling.** `.` components preserve the current directory; `./DOCS` is exercised from CPL3.
7. **Parent-component handling.** `..` follows the on-disk parent link and never moves above root.
8. **Per-process current directory.** Every process record now owns a `cwd_cluster`; shell-launched programs begin at root.
9. **Cwd lifecycle inheritance.** Fork-style children inherit the parent's directory and `exec` preserves it.
10. **Canonical `getcwd`.** The kernel reconstructs `/`, `/HOME`, and `/HOME/DOCS` by walking parent links and reverse-looking-up directory names.
11. **Root and subdirectory lookup.** One resolver scans the fixed FAT12 root and bounded one-cluster subdirectories.
12. **Directory enumeration.** A bounded list call omits `.` and `..`, emits `/` suffixes for directories, and proves exact `HOME` and `ARCHIVE` listings.
13. **Directory creation.** `mkdir` allocates the deterministic first free FAT cluster and commits a directory entry.
14. **Self-link initialization.** Every new directory receives a valid `.` entry pointing to itself.
15. **Parent-link initialization.** Every new directory receives a valid `..` entry pointing to its parent, including root cluster zero.
16. **Empty-directory removal.** `rmdir` deletes an empty directory and frees its cluster.
17. **Nonempty-directory rejection.** Removing `ARCHIVE` while `LOG.TXT` exists returns the bounded `ENOTEMPTY` result without mutation.
18. **Direct path write.** A new create/truncate/append path service prepares data clusters before committing visible metadata.
19. **Nested multi-cluster file I/O.** A 600-byte deterministic payload is written and read as `/HOME/ARCHIVE/LOG.TXT` across clusters 33 and 34.
20. **Path stat.** Size, first cluster, attributes, and chain length are returned in a bounded 16-byte record.
21. **Same-directory rename.** `TEMP.BIN` becomes `RENAMED.BIN` in `/HOME/DOCS` without reallocating its chain.
22. **Cross-directory move and reclamation.** The file moves to `/HOME/MOVED.BIN`, then to `ARCHIVE/LOG.TXT`; scratch files are unlinked and cluster 36 is reused first-fit.
23. **Two-boot hierarchy persistence.** The second boot independently validates root slots, directory sectors, dot links, parent links, both FAT copies, exact log and notes contents, and performs zero writes or allocations.

The cumulative verified release count is 86 goals (`0x56`), with 23 (`0x17`) new in Capstone 12.

## ABI extension

Capstone 12 extends the inherited 31-call CPL3 ABI with calls 32 through 41:

| Number | Service | Inputs | Result |
|---:|---|---|---|
| 32 | get cwd | destination, capacity | canonical path length |
| 33 | change directory | path, length | zero on success |
| 34 | make directory | path, length | allocated cluster |
| 35 | remove directory | path, length | zero or bounded rejection |
| 36 | stat path | path, length, 16-byte record | zero on success |
| 37 | write path | path, length, buffer, bytes, flags | source bytes written |
| 38 | read path | path, length, buffer, capacity | file bytes copied |
| 39 | rename/move path | old path/length, new path/length | zero on success |
| 40 | unlink path | path, length | zero on success |
| 41 | list directory | path, length, buffer, capacity | listing bytes copied |

The path-write flags are create `0x01`, truncate `0x02`, and append `0x04`. Files remain bounded to 2 KiB through this direct path ABI, while the inherited descriptor ABI retains its existing 4 KiB limit.

## Disk-loaded proof program

### `PATHS.ELF`

- ELF32 little-endian Intel 80386 executable.
- Entry: `0x00400000`.
- Size: 4,024 bytes.
- FNV-1a32: `38C1C0AD`.
- FAT12 chain: `23 -> 24 -> 25 -> 26 -> 27 -> 28 -> 29 -> 30 -> EOC`.
- PID in the canonical first session: 9.
- Exit code: `0x72`.
- Syscalls: 31, including two intentional rejected operations.

The program proves root, home, and docs cwd strings; creates and removes `EMPTY`; writes, stats, reads, renames, and moves the 600-byte payload; rejects a missing-directory `chdir`; rejects nonempty `rmdir`; enumerates exact directory contents; unlinks two temporary files; proves first-fit cluster reuse; returns to `/`; and exits.

Exact live result:

```text
process PID 0x00000009 PATHS.ELF exited 0x00000072 syscalls 0x0000001F hierarchy-goals 0x00000017 home 0x0000001F docs 0x00000020 log 0x00000021->0x00000022 archive 0x00000023 reuse 0x00000024 hash 0x36F73195 cleanup yes
```

## Persistent filesystem geometry

The initial volume contains twelve regular files. The persistent first boot leaves this hierarchy:

```text
/
HOME/                                 cluster 31
├── DOCS/                             cluster 32, empty
├── ARCHIVE/                          cluster 35
│   └── LOG.TXT                       600 bytes, clusters 33 -> 34
└── NOTES.TXT                         720 bytes, clusters 36 -> 37
```

- `LOG.TXT` FNV-1a32: `36F73195`.
- `NOTES.TXT` FNV-1a32: `C6181D2F`.
- `HOME` is root slot 12.
- `NOTES.TXT` is root slot 13.
- Cluster 38 remains the first free cluster after the first session.
- `DOCS` contains only `.` and `..`; its deleted scratch slot remains a FAT tombstone.
- `HOME` retains the deleted cross-directory source slot and the committed `ARCHIVE` entry.
- Both FAT copies must be byte-identical.

## Mutation and rollback rules

- New file data chains are allocated and written before the directory entry becomes visible.
- If slot commit fails, the prepared chain is freed.
- Replacing an existing file commits the new first cluster and size before releasing the old chain.
- Cross-directory moves create the destination entry before deleting the source; a failed source deletion removes the destination as rollback.
- Empty-directory removal rejects any directory used as a live process cwd.
- All traversal, chain, directory, and user-memory loops are bounded.

These rules reduce partial-state exposure but are not a power-loss journal. A machine reset between separate sector writes can still leave FAT12 metadata requiring offline repair.

## Two-boot result

First boot:

```text
ZigOs i686 Capstone 12 first session verified: goals 0x00000056 new-goals 0x00000017 root-files 0x0000000D processes 0x0000000B waits 0x00000002 creates 0x00000001 truncates 0x00000001 writes 0x00000002 seeks 0x00000001 allocations 0x00000002 notes 0x000002D0 hash 0xC6181D2F chain 0x00000024->0x00000025 hierarchy 0x00000021->0x00000022 hierarchy-hash 0x36F73195 fault-contained yes descriptors-closed yes commands 0x00000010
```

Persistence boot:

```text
ZigOs i686 Capstone 12 persistence session verified: goals 0x00000056 inherited-goals 0x00000043 root-files 0x0000000D notes 0x000002D0 hash 0xC6181D2F chain 0x00000024->0x00000025 hierarchy 0x00000021->0x00000022 hierarchy-hash 0x36F73195 writes 0x00000000 allocations 0x00000000 descriptors-closed yes commands 0x00000003
```

The persisted image SHA-256 remains unchanged across the second boot.

## Validation matrix

- Canonical Zig formatting and ELF32/i386 linking.
- Host validation of all twelve initial root files and exact FAT chains.
- Host validation of `PATHS.ELF` headers, hash, strings, repeated-separator path, and payload.
- Stage-1 chunked EDD loading and checksum16.
- First QEMU BIOS mutation session with sixteen shell commands.
- Offline nested-directory, dot-link, parent-link, FAT mirror, content, hash, tombstone, and free-cluster inspection.
- Read-only second QEMU boot and whole-image SHA-256 identity.
- Existing x86-64 UEFI HPET and 24-bit ACPI PM fallback regressions.
- Clean GitHub Actions rebuild, boot test, and artifact upload.

## Reference artifacts

- Legacy kernel: 77,880 bytes, 153 sectors at LBA 9-161.
- Kernel checksum16: `0x56BA`.
- Kernel SHA-256: `390CD94081AAE8153E984DA4D8EB7A4BF8DE859DFB4206C7498DFE6A77A86F19`.
- Initial image SHA-256: `E964341A937B5F22C680BFC7CFF954D2F2FDD911A206FE2E3E8F8D027B948490`.
- Persisted image SHA-256: `4F7C190F1729881B15D056DBDA6C37E9C4F016B77C74FE5F908519B9A7D9D7F0`.
- The x86-64 `BOOTX64.EFI` is expected to remain byte-identical to the previous release and is rechecked in the release matrix.
