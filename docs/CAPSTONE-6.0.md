# ZigOs Capstone 6.0

Capstone 6.0 introduces genuine preemptive scheduling of multiple CPL3 processes with independent virtual address spaces.

## Release contract

- Version: `6.0.0`
- User processes demonstrated simultaneously runnable: 2
- User address spaces: 2 distinct CR3 page directories
- Kernel privilege stacks: 2 distinct TSS `esp0` targets
- Scheduling policy: PIT-driven round robin
- User quanta: 3 per process
- Scheduler switches: 7 including bootstrap restoration
- User virtual code address: `0x00400000`
- Isolated test address: `0x00400100`

## Address-space isolation

Each process receives its own page directory, user page table, physical code page, and physical stack page. The two processes execute at the same virtual addresses while writing to different physical storage. The first address space retains a `0x11` tag and the second retains a `0x22` tag after preemptive execution, proving that the shared virtual address does not alias across CR3 boundaries.

Kernel mappings are cloned as supervisor-only mappings. Only PDE1 and the process user pages carry the U/S bit. The scheduler switches CR3 before returning through `IRETD` and restores the kernel page directory before returning to the bootstrap task.

## Privilege-stack switching

Each runnable CPL3 process has a separate 4 KiB kernel privilege stack. On every task selection, the scheduler updates the 32-bit TSS `esp0` before returning to user mode. The IRQ0 assembly gate normalizes data segments to the kernel selector before entering Zig and restores ring-0 or ring-3 data selectors according to the selected context's CS.

## Process lifecycle

The process table capacity increases to eight records. The boot proof retains:

- PID 1: `INIT.ELF`, exited `0x33`
- PID 2: `WORKA.BIN`, exited `0x40`
- PID 3: `WORKB.BIN`, exited `0x41`
- PID 4: shell-launched `INIT.ELF`, exited `0x33`

The two scheduler-owned processes transition from running to exited after their isolated execution proof. Their temporary page-directory, page-table, code, and stack frames are all released, and exact free-frame accounting is restored.

## Runtime proof

The required marker is:

```text
ZigOs i686 user scheduler verified: policy preemptive-CPL3 tasks 0x00000002 address-spaces 0x00000002 switches 0x00000007 quanta 0x00000003/0x00000003 tick-delta 0x00000007 CR3-distinct yes kernel-stacks distinct shared-VA 0x00400100 tags 0x11/0x22 active yes frames-restored yes
```

The complete COM1 session additionally requires the timer count `0x13`, all four process records, PID 4 execution through the existing ELF/syscall path, zero leaked VFS descriptors, and zero unknown commands.

## Capstone 6.0 reference build

- Raw kernel size: 29,948 bytes
- Raw kernel sectors: 59
- Kernel LBA range: 9-67
- Kernel checksum16: `0x6B47`
- Raw kernel SHA-256: `3818AEBF59C33B216EB54BD7817B82062D4962D62A046D4D24B5DBC98715453A`
- Disk image SHA-256: `E2B46B4971DDFD812E0AA778B7416265B4B928E1395F869DF8EFB0B447721094`
