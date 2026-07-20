# ZigOs Capstone 5.0

Capstone 5.0 is the first versioned platform release of the ZigOs legacy BIOS/i686 runtime. It replaces the original small-kernel disk contract with an integrity-checked layout that leaves enough bounded space for multi-process userspace and additional system services.

## Release contract

- Version: `5.0.0`
- Boot architecture: BIOS stage-0, eight-sector stage-1, freestanding i686 Zig kernel
- Kernel load address: `0x00010000`
- Kernel disk start: LBA 9
- FAT12 partition start: LBA 256
- Maximum kernel sectors: 247
- Maximum padded kernel capacity: 126,464 bytes
- Stage-1 EDD chunk size: at most 64 sectors per request
- Boot-info ABI: version 2, 32 bytes
- Integrity algorithm: additive little-endian 16-bit word checksum across every padded kernel sector

## Integrity chain

The build computes the kernel checksum after padding the raw binary to its complete sector count. Stage-1 loads the kernel in bounded EDD chunks, advances both the destination segment and source LBA, checksums each loaded chunk, and refuses to enter protected mode if the result differs.

The i686 `_start` entry independently recomputes the checksum over the in-memory sector image before writing kernel `.data` or clearing BSS. Zig accepts the boot contract only when both checks agree, boot-info flags are exactly `0x07`, and the advertised FAT partition is LBA 256.

## Image isolation

The host verifier requires:

- stage-0, stage-1, kernel, and FAT12 bytes to match their source artifacts;
- the kernel to end before LBA 256;
- every byte from the end of the padded kernel through LBA 255 to remain zero;
- the MBR partition and FAT12 BPB hidden-sector values to agree on LBA 256.

This prevents kernel growth from silently overwriting filesystem data.

## Capstone 5.0 reference build

- Raw kernel size: 27,388 bytes
- Raw kernel sectors: 54
- Kernel LBA range: 9-62
- Kernel checksum16: `0x2FA8`
- Remaining reserved growth: 193 sectors / 98,816 bytes
- Raw kernel SHA-256: `9EDE0CCE5959951212740814AE3EE701F4BFBF6DF5AE01C6F46C880840B327F6`
- Disk image SHA-256: `F91559C52FDB6CC684474493A131641405A1569380F469FC7B2B5E78C70FAE6F`

## Runtime proof

The QEMU contract requires both debugcon and COM1 to report:

```text
ZigOs BIOS stage1 kernel verified: chunked-EDD yes max-chunk 0x0040 checksum16 yes FAT-LBA 0x00000100
ZigOs i686 E820 verified: ... version 0x00000002 ... loader checksum16 0x00002FA8 entry-checksum yes FAT-LBA 0x00000100 flags 0x07
ZigOs i686 FAT12 verified: volume-LBA 0x00000100 ... root-start 0x00000113 data-start 0x00000121 ...
```

All earlier exception, IRQ, allocator, paging, heap, ATA, FAT12, scheduler, ring-3, syscall, ELF, VFS, process-table, and interactive shell contracts remain mandatory.
