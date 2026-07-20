# ZigOs Capstone 7.0

Capstone 7.0 moves filesystem access across the privilege boundary. A disk-loaded CPL3 program now opens, reads, prints, and closes a FAT12 file entirely through the `int 0x80` ABI.

## Release contract

- Version: `7.0.0`
- Syscall vector: `0x80`
- Existing syscalls: `write` (1), `getpid` (2), `exit` (3)
- New syscalls: `open` (4), `read` (5), `close` (6)
- Descriptor capacity: 4
- Process-table capacity: 8
- Maximum user read per syscall: 128 bytes
- Valid user-pointer window: `0x00400000` through `0x00400FFF`
- Filesystem: read-only, bounded FAT12, one cluster per file

## Process-owned descriptors

Every descriptor records an owning PID in addition to its node and byte offset. Kernel clients use owner PID 0; user clients use the currently executing process PID. Read and close operations require an exact owner match.

The boot contract deliberately opens `HELLO.TXT` as owner `0x77`, then attempts to read and close it as owner `0x78`. Both operations must fail without advancing the descriptor offset or incrementing read/close counters. The correct owner subsequently closes the descriptor.

Process exit closes any descriptors still owned by the exiting PID and reports the exact cleanup count. The reference `CAT.ELF` program closes explicitly, so exit cleanup must remain zero.

## CAT.ELF

The deterministic FAT12 image now contains:

- `HELLO.TXT`, cluster 2, 86 bytes
- `INIT.ELF`, cluster 3, 423 bytes
- `CAT.ELF`, cluster 4, 510 bytes

`CAT.ELF` is a real ELF32 Intel 80386 executable:

- entry: `0x00400000`
- one `PT_LOAD` segment
- file offset: `0x100`
- segment file size: `0xFE` / 254 bytes
- segment memory size: `0x200` / 512 bytes
- flags: `R-X`
- embedded FAT name: `HELLO   TXT`
- FNV-1a32: `8F95EE48`

The program executes five system calls:

1. `open("HELLO   TXT", 11)`
2. `read(fd, buffer, 86)`
3. `write(buffer, 86)`
4. `close(fd)`
5. `exit(0x44)`

It prints the exact contents of `HELLO.TXT` from CPL3, becomes PID 5, and exits with code `0x44`.

## Error and pointer contract

All user pointers are checked for range, wraparound, and maximum length before dereference. The file calls return bounded negative errno values for invalid pointers, invalid arguments, missing files, invalid or foreign descriptors, and unknown syscall numbers.

The user VFS proof requires:

```text
ZigOs i686 user VFS syscalls verified: open 0x00000001 reads 0x00000001 read-bytes 0x00000056 closes 0x00000001 write-bytes 0x00000056 exit 0x00000044 owner-isolation yes explicit-close yes cleanup-closes 0x00000000 heap-restored yes
```

## Live shell proof

The COM1 harness sends ten paced commands:

```text
help
ls
mem
ticks
disk
cat HELLO.TXT
run INIT.ELF
run CAT.ELF
ps
exit
```

The final process table contains:

- PID 1: `INIT.ELF`, exited `0x33`
- PID 2: `WORKA.BIN`, exited `0x40`
- PID 3: `WORKB.BIN`, exited `0x41`
- PID 4: `INIT.ELF`, exited `0x33`
- PID 5: `CAT.ELF`, exited `0x44`

Final VFS accounting requires six opens, six reads, six closes, five process records, no open descriptors, nine operational shell commands, and zero unknown commands.

## Capstone 7.0 reference build

- Raw kernel size: 32,604 bytes
- Raw kernel sectors: 64
- Kernel LBA range: 9-72
- Kernel checksum16: `0x5281`
- Raw kernel SHA-256: `6648B69C2BD7B118BEEDBC5BB59AD28E6F077525FBD93B105B7F584CF7745CF1`
- Disk image SHA-256: `E41A2DA36D20034A2B9EC84CA5DBED234683983BFA4C091B2C47B61838BC6BF7`
