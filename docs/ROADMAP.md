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
- [x] ZigOs-owned x86-64 page tables
- [x] Identity map required bootstrap firmware, ACPI, stack, and framebuffer regions
- [ ] Higher-half kernel mapping experiment
- [x] GDT and TSS
- [x] IDT and assembly interrupt stub proof (vector 3 on IST1)
- [x] Full CPU exception-vector coverage and fault diagnostics
- [x] Fatal exception panic path over early debug output
- [ ] COM1 serial diagnostics and symbolized stack traces

## 0.4 - Hardware discovery

- [x] Validate and parse ACPI RSDP/XSDT
- [x] MADT and APIC discovery
- [x] Local APIC initialization and legacy PIC masking
- [x] I/O APIC discovery and fully masked redirection table
- [ ] External IRQ routing through MADT overrides
- [x] PCIe ECAM enumeration from validated MCFG
- [x] HPET initialization and local-APIC timer calibration
- [x] Maskable APIC timer interrupt with EOI and HLT wake-up
- [ ] PS/2 and USB input experiments

## 0.5 - Runtime

- [x] Kernel free-list heap with aligned allocation and coalescing
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
