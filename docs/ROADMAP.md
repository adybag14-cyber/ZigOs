# ZigOs roadmap

## 0.1 - UEFI proof of execution

- [x] Native AMD64 `BOOTX64.EFI`
- [x] Canonical Zig toolchain pin and checksum
- [x] Separate NASM hardware module
- [x] CPUID vendor query
- [x] CR0, CR3 and CR4 reads
- [x] PE/COFF verifier
- [x] QEMU/EDK2 boot test

## 0.2 - Firmware handoff

- [x] Obtain and retain the final UEFI memory map
- [x] Locate ACPI RSDP
- [x] Locate and retain the graphics framebuffer
- [x] Allocate a 64 KiB ZigOs-owned kernel stack
- [x] Switch stacks through an x86-64 assembly trampoline
- [x] Call `ExitBootServices` with stale-key retry handling
- [x] Continue without UEFI console or boot services
- [x] Write directly to the framebuffer after handoff
- [x] Verify the complete transition in QEMU

## 0.3 - Kernel foundations

- [ ] Parse retained memory descriptors into usable and reserved regions
- [x] Physical frame allocator
- [ ] ZigOs-owned x86-64 page tables
- [ ] Identity map required firmware/runtime regions
- [ ] Higher-half kernel mapping experiment
- [ ] GDT and TSS
- [ ] IDT and assembly interrupt stubs
- [ ] Kernel panic path and serial diagnostics

## 0.4 - Hardware discovery

- [ ] Validate and parse ACPI RSDP/XSDT
- [ ] MADT and APIC discovery
- [ ] Local APIC and I/O APIC initialization
- [ ] PCI/PCIe enumeration
- [ ] HPET or invariant-TSC timing
- [ ] PS/2 and USB input experiments

## 0.5 - Runtime

- [ ] Kernel heap
- [ ] Cooperative task abstraction
- [ ] Pre-emptive scheduler experiment
- [ ] Userspace privilege-transition experiment
- [ ] Minimal syscall ABI

## Long-term experiments

- Multicore startup through INIT/SIPI
- NVMe and AHCI storage
- FAT filesystem
- Network stack
- Native Zig applications
- Reproducible disk-image and release pipeline
