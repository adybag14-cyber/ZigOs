# ZigOs persistent journal compatibility and recovery contract

This document is the normative G251 description of the current `/persist` on-disk journal implemented by `src/runtime_persist.zig`. It documents what the current kernel can read, what it writes, how it chooses between A/B generations, and which failure cases are deliberately outside the compatibility guarantee. It is a repository contract, not a promise that the experimental format will never change: any incompatible change must update this document, the permanent verifier and executable migration/recovery evidence in the same change.

## Compatibility summary

- Current writer format: **v3**.
- Current reader formats: **v1, v2 and v3 only**.
- v1 is readable; timestamps are synthesized from the mount-time tick and ownership is synthesized as UID/GID `0:0`.
- v2 is readable; its stored four timestamps are retained and ownership is synthesized as UID/GID `0:0`.
- The next successful global `sync` after mounting v1 or v2 writes a new v3 generation. The older slot may still contain its older-format generation until later overwritten.
- File-scoped persistent `fsync`, `fdatasync` and persistent asynchronous writeback require the mounted committed payload to already be v3. On v1/v2 they return the existing unsupported-operation path until global `sync` performs migration.
- Unknown versions are not forward-compatible. A header version other than 1, 2 or 3 is rejected as an invalid candidate. If another recognized slot is valid, the current kernel may select that older recognized generation; if no recognized candidate remains, mount fails as corrupt. **Do not boot an older ZigOs build against storage written by a newer on-disk version unless that downgrade is explicitly documented as supported.**
- There is no downgrade writer and no promise that a pre-v3 kernel can understand a v3 generation.

## Device geometry

All offsets below are relative to the `BlockDevice.first_lba` of the ZigOs data partition. The store accepts only 512-byte or 4096-byte logical blocks and requires `first_lba != 0`.

The journal therefore reserves **two fixed 64 KiB payload regions**. `maximum_payload_bytes` is fixed at **64 KiB per slot**. Let `N = ceil(65536 / block_size)`:

| Relative LBA range | Purpose |
| --- | --- |
| `0` | slot A header |
| `1` | slot B header |
| `2 .. 2+N-1` | slot A payload region |
| `2+N .. 2+2N-1` | slot B payload region |

The minimum accepted data extent is therefore `2 + 2*N` blocks: 258 blocks for 512-byte media and 34 blocks for 4096-byte media. Additional blocks in the partition are not part of this journal format.

For the current 512-byte QEMU image, the data partition begins at raw LBA 18432. Consequently the slot headers are raw LBAs 18432/18433, slot-A payload begins at 18434, and slot-B payload begins at 18562. These raw LBAs are image-layout measurements, not portable format constants; the relative geometry above is the compatibility contract.

## Scalar encoding and CRC

All integer fields are unsigned **little-endian** values. CRCs use the repository CRC-32 implementation with initial state `0xFFFFFFFF`, reflected polynomial `0xEDB88320`, and final bitwise complement (the usual CRC-32/IEEE encoding used elsewhere in ZigOs).

### 48-byte slot header

The first 48 bytes of each header block have this layout:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | ASCII magic `ZIGPERS1` |
| 8 | 4 | format version (`1`, `2` or `3`) |
| 12 | 4 | header size, exactly `48` |
| 16 | 8 | generation |
| 24 | 4 | payload length in bytes |
| 28 | 4 | CRC-32 of exactly `payload_length` payload bytes |
| 32 | 4 | encoded physical slot (`0` or `1`) |
| 36 | 4 | record count |
| 40 | 4 | header CRC-32 |
| 44 | 4 | commit marker `0x434F4D54` |

The header CRC covers exactly bytes `0..47` with bytes `40..43` treated as zero during calculation. A valid header must have the expected magic, one of the supported versions, header size 48, the commit marker, a physical-slot value matching the block in which it was found, a payload length from 4 through 65536 bytes, and a matching header CRC.

The current writer zero-fills the whole physical header block before writing these fields. Readers do **not** make the unused bytes after offset 47 part of the compatibility contract. An entirely zero physical header block means that slot is absent.

## Payload and record encoding

The protected payload starts with one little-endian `u32` record count. It must equal the record count stored in the selected slot header. Records follow immediately and must consume exactly `payload_length` bytes; trailing bytes inside the declared payload are not permitted.

Every record begins with this v1-compatible 8-byte prefix:

| Record offset | Size | Field |
| ---: | ---: | --- |
| 0 | 1 | record kind |
| 1 | 1 | relative path length |
| 2 | 2 | inode mode |
| 4 | 4 | data length |

Version-specific record headers are:

- **v1: 8 bytes** — only the common prefix.
- **v2: 40 bytes** — v1 prefix plus four `u64` ticks at offsets 8, 16, 24 and 32: creation, modification, change and access.
- **v3: 48 bytes** — v2 header plus `u32 uid` at offset 40 and `u32 gid` at offset 44.

Immediately after the version-specific record header come `path_length` bytes of relative path followed by `data_length` bytes of kind-specific data. Paths are relative to `/persist`, must not start with `/`, contain NUL, empty slash components, `.` or `..`, and remain within the VFS pathname limits when restored.

Record-kind values are stable for v1-v3:

| Value | Kind | Data encoding |
| ---: | --- | --- |
| 1 | directory | empty data |
| 2 | file | file bytes; legacy dense-file representation accepted up to the bounded VFS file size |
| 3 | symbolic link | target bytes |
| 4 | hard link | relative target path within `/persist` |
| 5 | sparse file | 1-byte allocation bitmap, 4-byte little-endian logical size, then one 4096-byte block for each set allocation bit in ascending logical-block order |

The current v3 serializer writes ordinary files using kind 5 sparse-file records so allocation holes survive reboot. Kind 2 remains readable for compatibility.

## Restore and migration semantics

A selected payload is restored in three passes: non-hard-link namespace objects first, hard-link aliases second, then timestamp/ownership metadata. This ordering prevents hard-link reconstruction and namespace creation from replacing the persisted shared-inode metadata.

Version migration is intentionally one-way in the current writer:

| Mounted format | Current kernel reads it? | Synthesized metadata | Next global `sync` writes |
| --- | --- | --- | --- |
| v1 | yes | all four timestamps = mount tick; UID/GID = `0:0` | v3 |
| v2 | yes | UID/GID = `0:0`; stored timestamps preserved | v3 |
| v3 | yes | none | v3 |
| unknown/future | no | none | no write; candidate rejected |

A successful v1/v2 migration increments the generation and writes v3 to the inactive slot. Because the journal is A/B, the other slot may continue to contain the older format until a later commit replaces it. Tools must therefore inspect the version in each candidate header independently rather than assuming one format for the whole partition.

## Commit protocol

Every durable snapshot targets the inactive slot and follows this order:

1. Serialize the intended snapshot in memory.
2. Write the target slot payload blocks without FUA.
3. Flush the block device.
4. Increment the generation; wrap to zero is rejected rather than reused.
5. Build the 48-byte v3 header with payload CRC, slot number, record count, commit marker and header CRC.
6. Write the target slot header with force-unit-access requested.
7. Flush the block device again.
8. Only after those steps succeed, update the in-memory active slot/generation/payload baseline.

The payload-before-header ordering means an interrupted inactive-slot payload cannot become the newest committed generation without a corresponding valid header. It does **not** mean both previous generations always survive: writing a new inactive payload may invalidate the older header that previously referred to that same slot. The guarantee is that the currently active committed slot is left untouched until the new candidate is ready to publish.

## Mount selection and recovery

Mount evaluates slot A and slot B independently:

1. Read each header. A read I/O failure is an I/O error, not a corruption fallback.
2. Classify an all-zero block as absent; validate supported header structure and header CRC for nonzero blocks.
3. For a structurally valid header, CRC-check exactly its declared payload bytes.
4. Among payload-valid recognized candidates, select the one with the greater generation. If only one is valid, select it.
5. Load and semantically restore the selected payload.

The writer never intentionally emits equal generations in both slots. Equal-generation tie behavior is not a compatibility guarantee and external tooling must not manufacture such images.

The following cases are supported:

| On-disk state | Result |
| --- | --- |
| both headers absent | mount an empty persistent tree at generation 0 |
| one recognized valid candidate, other absent | mount the valid candidate |
| two recognized payload-valid candidates with different generations | mount the higher generation |
| newest header structurally/CRC invalid, older candidate valid | fall back to older candidate |
| newest header valid but payload CRC invalid, older candidate valid | fall back to older candidate |
| no valid candidate but at least one non-absent slot | fail mount as corrupt |
| header/payload device read returns I/O failure | fail as I/O; do not relabel it as corruption |

A CRC-valid candidate can still fail semantic record restoration. The current selector does **not** retry the older generation after such a restoration failure; mount returns the corresponding corruption/invalid-record failure. G250 proves physical header/payload corruption detected before restoration, not arbitrary CRC-colliding or semantically malformed payload recovery.

## Recovery telemetry

`recoveries` is a **candidate-selection/fallback counter**, not a corruption counter. It increments when a selected mount had either:

- a non-absent candidate that was rejected during header/payload validation, or
- two valid candidates with different generations, requiring generation selection.

Therefore a normal A/B disk containing two healthy unequal generations can increment `recoveries` even when neither copy is corrupt.

`corrupt_headers` counts nonzero header blocks rejected for header structure/version/slot/length/commit-marker/header-CRC reasons. Payload CRC rejection does not increment `corrupt_headers`. Device I/O failures use separate I/O-failure accounting.

## Write-failure guarantees

The same commit protocol is used by global sync and supported v3 file-scoped durable updates. Runtime write/flush failures also trigger the existing fail-stop read-only containment policy for the mounted persistent filesystem.

| Failure point | Durable-state guarantee for reboot |
| --- | --- |
| payload write or first flush fails | the active slot header was not modified; reboot can use the active valid generation |
| header write fails | the active slot remains the only generation ZigOs promises to rely on; the target candidate is not assumed committed |
| final flush fails after successful FUA header write | durability is indeterminate: either old or new candidate may be valid on real media, and reboot selects the newest candidate that validates |

No automatic repair or scrub is performed during mount fallback. G250 specifically verifies that booting a copy with one corrupted newest header block or one corrupted newest payload block leaves the damaged image byte-for-byte unchanged.

## Guarantees deliberately not made

The current format does **not** claim:

- forward compatibility with versions newer than v3;
- safe downgrade from a newer writer to an older kernel;
- recovery when both A/B generations are invalid;
- recovery from arbitrary multi-block corruption, malicious/Byzantine storage or CRC collisions;
- fallback after a CRC-valid newest payload fails semantic VFS restoration;
- automatic repair, rewriting, mirroring, bad-block relocation or journal scrubbing;
- atomic persistence of open-but-unlinked objects, transient locks, directory-watch cursors, process state or other runtime-only objects;
- wall-clock meaning or cross-reboot monotonicity for stored timestamp ticks;
- a scalable filesystem format beyond the current bounded VFS and 64 KiB snapshot payload.

## Required evidence

G251 relies on executable contracts already required by the repository:

- the isolated persistence test that mounts handcrafted v1 and v2 snapshots, synthesizes their missing metadata, globally syncs them to v3, and remounts the migrated generation;
- alternating A/B snapshot restore tests for directories, files, sparse allocation, symbolic links, hard links, timestamps and ownership;
- write/flush-failure tests covering payload, header and final-flush containment behavior;
- the required x86-64 persistence harness: four normal/crash-recovery boots followed by independent newest-header and newest-payload physical-block corruption boots from G250;
- the permanent verifier, which pins this document to the source constants, version matrix, commit ordering and recovery limitations.

If the magic, supported versions, header/record sizes, payload bound, record kinds, commit ordering, migration behavior or recovery policy changes, this document and its verifier assertions must change in the same commit.
