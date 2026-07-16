# ZigOs

ZigOs is an experimental x86-64 operating-system project built from **freestanding Zig and hand-written assembly**.

The project deliberately uses the canonical Zig builds published by [`adybag14-cyber/zig`](https://github.com/adybag14-cyber/zig/releases). The build scripts do not fall back to a system or stock Zig installation.

## Milestone 0.1

The first boot path is a native UEFI application:

```text
Motherboard UEFI
      |
      v
EFI/BOOT/BOOTX64.EFI
      |
      v
Zig UEFI entry point
      |
      v
NASM x86-64 hardware layer
      |
      +--> CPUID vendor
      +--> CR0 / CR3 / CR4
```

On boot, ZigOs clears the UEFI console, calls hand-written x86-64 assembly, and displays the CPU vendor and control-register values.

This milestone still runs while UEFI Boot Services exist. Later milestones will capture the firmware memory map, call `ExitBootServices`, install ZigOs-owned page tables, interrupts and drivers, and become a self-hosted kernel environment.

## Verified boot

The milestone is compiled and boot-tested with QEMU/EDK2. A successful test currently produces output similar to:

```text
ZigOs
Experimental x86-64 operating system in Zig + Assembly

CPU vendor: AuthenticAMD
CR0 = 0x0000000080010033
CR3 = 0x000000000FC01000
CR4 = 0x0000000000000668

Milestone 0.1 reached: UEFI -> Zig -> x86-64 assembly -> hardware.
Returning control to UEFI.
```

Control-register values vary between machines and emulator configurations.

## Requirements

- Windows PowerShell 7 or Windows PowerShell 5.1
- NASM 2.16 or newer in `PATH`
- Internet access for the first canonical Zig download
- QEMU with OVMF/EDK2 for emulation, or a FAT32 USB drive for hardware testing

## Build

```powershell
.\scripts\build.ps1
```

The script:

1. Downloads and verifies the pinned canonical Zig release when absent.
2. Assembles `src/arch/x86_64/cpu.asm` as a Win64 COFF object.
3. Links Zig and assembly into `zig-out/EFI/BOOT/BOOTX64.EFI`.
4. Verifies the output is AMD64 PE32+ with UEFI application subsystem 10.

The currently pinned compiler is recorded in `.toolchain-version`.

## Automated QEMU boot test

```powershell
.\scripts\test-qemu.ps1
```

The test boots the generated EFI image with split EDK2 pflash firmware, captures the assembly debug stream through QEMU port `0xE9`, and verifies that ZigOs reached the milestone marker and returned CPUID/control-register data.

## Run interactively in QEMU

```powershell
.\scripts\run-qemu.ps1
```

## Boot on a physical machine

Copy the contents of `zig-out` onto an empty FAT32 USB drive so the file is located at:

```text
EFI\BOOT\BOOTX64.EFI
```

Disable Secure Boot unless the EFI image has been signed with a key trusted by the machine. Test in QEMU before using real hardware.

## Repository layout

```text
src/main.zig                    UEFI entry and Zig logic
src/arch/x86_64/cpu.asm         x86-64 assembly hardware primitives
scripts/bootstrap-toolchain.ps1 canonical Zig downloader and verifier
scripts/build.ps1               reproducible build
scripts/verify-efi.ps1          PE/COFF structural validation
scripts/test-qemu.ps1           automated headless boot test
scripts/run-qemu.ps1            interactive emulator launcher
docs/ROADMAP.md                 development milestones
```

## Principles

- Assembly only where exact instruction and register control matters.
- Zig for the maintainable kernel and runtime majority.
- No silent dependence on hosted operating-system services.
- Reproducible, pinned canonical Zig toolchain.
- QEMU-first testing before physical hardware.

## License

MIT
