# ZigOs

ZigOs is an experimental x86-64 operating-system project built from **freestanding Zig and hand-written assembly**.

The project deliberately uses the canonical Zig builds published by [`adybag14-cyber/zig`](https://github.com/adybag14-cyber/zig/releases). The build scripts do not fall back to a system or stock Zig installation.

## Current milestone: 0.2 firmware handoff

ZigOs now performs a complete transition from UEFI boot services into a kernel-owned execution environment:

```text
Motherboard UEFI / OVMF
        |
        v
EFI/BOOT/BOOTX64.EFI
        |
        v
Zig firmware entry
        |
        +--> NASM CPUID and control-register primitives
        +--> ACPI RSDP discovery
        +--> GOP framebuffer discovery
        +--> 64 KiB ZigOs kernel-stack allocation
        +--> final UEFI memory-map capture
        |
        v
ExitBootServices
        |
        v
NASM stack-switch trampoline
        |
        v
Freestanding Zig kernel
        |
        +--> direct debug-port output
        +--> direct framebuffer write
        +--> interrupt-disabled halt loop
```

After `ExitBootServices` succeeds, ZigOs no longer calls the UEFI console or any UEFI boot service. The kernel continues on its own allocated stack, retains the final memory map, ACPI root pointer and framebuffer description, writes directly to video memory, and then halts safely while interrupts remain disabled.

ZigOs does **not** yet install its own page tables, IDT, APIC configuration, allocator or device drivers. Those are milestone 0.3 and later.

## Verified QEMU boot

The current image is compiled and boot-tested with QEMU and EDK2/OVMF. A successful run produces output similar to:

```text
ZigOs
Experimental x86-64 operating system in Zig + Assembly

CPU vendor: AuthenticAMD
CR0 = 0x0000000080010033
CR3 = 0x000000000FC01000
CR4 = 0x0000000000000668

Firmware discovery:
  Kernel stack: 0x000000000E0AA000 + 65536 bytes
  ACPI RSDP: 0x000000000FB7E014
  GOP framebuffer: 1280x800 at 0x0000000080000000
  Memory descriptors: 117
  Conventional memory: 219140096 bytes

Exiting UEFI boot services...

ExitBootServices succeeded.
ZigOs now owns execution without UEFI boot services.
Kernel stack: 0x000000000E0AA000 + 65536 bytes
Final memory descriptors: 117
Conventional memory: 219140096 bytes
ACPI RSDP retained at 0x000000000FB7E014
Framebuffer retained and written directly at 0x0000000080000000
Milestone 0.2 reached: firmware handoff complete; kernel remains alive.
```

Addresses, memory totals, descriptor counts and control-register values vary between machines and emulator configurations.

## Requirements

- Windows PowerShell 7 or Windows PowerShell 5.1
- NASM 2.16 or newer in `PATH`
- Internet access for the first canonical Zig download
- QEMU with EDK2/OVMF for emulation, or a FAT32 USB drive for hardware testing

## Build

```powershell
.\scripts\build.ps1
```

The build script:

1. Downloads and verifies the pinned canonical Zig release when absent.
2. Refuses to build if the compiler version differs from `.toolchain-version`.
3. Assembles `src/arch/x86_64/cpu.asm` as a Win64 COFF object.
4. Links Zig and assembly into `zig-out/EFI/BOOT/BOOTX64.EFI`.
5. Verifies AMD64 PE32+ format and UEFI application subsystem 10.

## Automated firmware-handoff test

```powershell
.\scripts\test-qemu.ps1
```

The test boots the EFI image with split EDK2 pflash firmware and captures port `0xE9`. It fails unless it observes:

- CPUID and control-register results from assembly
- the ZigOs-owned stack before and after handoff
- successful `ExitBootServices`
- post-UEFI Zig kernel execution
- retained ACPI and framebuffer information
- a direct framebuffer access marker

## Run interactively

```powershell
.\scripts\run-qemu.ps1
```

## Boot on a physical machine

Copy the contents of `zig-out` onto an empty FAT32 USB drive so this path exists:

```text
EFI\BOOT\BOOTX64.EFI
```

Disable Secure Boot unless the image has been signed with a key trusted by the machine. QEMU testing should always come before physical-hardware testing.

## Repository layout

```text
src/main.zig                    UEFI discovery and firmware handoff
src/boot_info.zig               firmware-to-kernel data contract
src/kernel.zig                  post-ExitBootServices Zig kernel
src/arch/x86_64/cpu.asm         x86-64 primitives and stack trampoline
scripts/bootstrap-toolchain.ps1 canonical Zig downloader and verifier
scripts/build.ps1               reproducible UEFI build
scripts/verify-efi.ps1          PE/COFF structural validation
scripts/test-qemu.ps1           automated headless handoff test
scripts/run-qemu.ps1            interactive emulator launcher
docs/ROADMAP.md                 development milestones
```

## Principles

- Assembly only where exact instruction, register or stack control matters.
- Zig for the maintainable kernel and runtime majority.
- No silent dependence on hosted operating-system services.
- Reproducible, pinned canonical Zig toolchain.
- QEMU-first validation before physical hardware.

## License

MIT
