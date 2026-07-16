# ZigOs roadmap

## 0.1 â€” UEFI proof of execution

- [x] Native AMD64 `BOOTX64.EFI`
- [x] Canonical Zig toolchain pin and checksum
- [x] Separate NASM hardware module
- [x] CPUID vendor query
- [x] CR0, CR3 and CR4 reads
- [x] PE/COFF verifier

## 0.2 â€” Firmware handoff

- [ ] Obtain the UEFI memory map
- [ ] Locate ACPI RSDP and graphics output protocol
- [ ] Allocate an owned kernel stack
- [ ] Call `ExitBootServices`
- [ ] Continue without UEFI console services

## 0.3 â€” Kernel foundations

- [ ] Physical frame allocator
- [ ] ZigOs-owned x86-64 page tables
- [ ] Higher-half kernel mapping
- [ ] GDT and TSS
- [ ] IDT and assembly interrupt stubs
- [ ] Panic screen and serial diagnostics

## 0.4 â€” Hardware discovery

- [ ] ACPI table parser
- [ ] APIC initialization
- [ ] PCI/PCIe enumeration
- [ ] HPET or invariant-TSC timing
- [ ] PS/2 and USB input experiments

## 0.5 â€” Runtime

- [ ] Kernel heap
- [ ] Cooperative task abstraction
- [ ] Pre-emptive scheduler experiment
- [ ] Userspace privilege transition experiment
- [ ] Minimal syscall ABI

## Long-term experiments

- Multicore startup through INIT/SIPI
- NVMe and AHCI storage
- FAT filesystem
- Network stack
- Native Zig applications
- Reproducible disk-image and release pipeline
