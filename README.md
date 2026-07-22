# ZigOs

[![Build ZigOs](https://github.com/adybag14-cyber/ZigOs/actions/workflows/build.yml/badge.svg)](https://github.com/adybag14-cyber/ZigOs/actions/workflows/build.yml)

ZigOs is an experimental x86 operating system written in freestanding Zig and hand-written assembly. The primary target is an x86-64 UEFI kernel; a separate legacy BIOS/i686 kernel provides a smaller persistent FAT12 userspace environment.

ZigOs is a research and learning system. It is not production-ready, POSIX-compatible, secure against hostile workloads, or broadly validated on physical hardware.

## Current release: Capstone 17.0

Capstone 17 replaces the x86-64 kernel's terminal post-validation halt with a permanent, interrupt-driven serial runtime. After the inherited hardware, network and CPL3 validation suites pass, the kernel starts PID 1 as init, PID 2 as a persistent serial command environment, a dedicated 100 Hz LAPIC runtime clock, a bounded process table and a writable RAM-backed VFS.

The release adds 96 verified goals to the inherited 337 x86-64 goals, reaching **433 cumulative goals (`0x1B1`)**:

```text
ZigOs x86-64 Capstone 17 verified: goals 0x000001B1 new-goals 0x00000060 runtime yes vfs yes process-table yes shell yes portable-build yes ci-matrix yes
```

The exact contract is documented in [`docs/CAPSTONE-17.0.md`](docs/CAPSTONE-17.0.md). The broader program is tracked as 500 separate goals in [`docs/ROADMAP-500.md`](docs/ROADMAP-500.md): 96 complete and 404 open at this release.

## What runs after boot

The x86-64 kernel now remains alive after validation unless an explicit `shutdown` command is entered. Its permanent runtime provides:

- a dedicated LAPIC timer vector and ISR that are independent of the temporary Capstone 16 scheduler;
- an interrupt-enabled HLT idle loop;
- continued device and retained network service passes;
- sleeping, blocked, runnable, stopped, zombie and faulted task states;
- PID 1 orphan adoption and terminal-child reaping;
- a persistent COM1 prompt;
- a bounded writable VFS and mount table;
- process, device and network pseudo namespaces;
- a generation-safe 64-slot process table;
- command parsing, pipelines, redirection, background syntax and history.

The default serial prompt is:

```text
root@zigos:/home/root#
```

### Runtime commands

```text
Filesystem:
  pwd cd ls cat echo touch mkdir rm rmdir mv
  write append stat chmod mount df sync fsck

Processes:
  ps jobs spawn kill wait crash sleep uptime elf exec run

Devices and networking:
  devices ifconfig netstat sockets routes arp ping dns

Shell and utilities:
  env export unset history clear uname
  hash hexdump grep wc head shutdown
```

`spawn`, `exec` and `run` currently operate on the bounded runtime process model. `elf` performs real ELF64 header and `PT_LOAD` inspection, but the permanent shell does **not yet execute arbitrary storage-loaded ELF64 code at CPL3**.

## Persistent-runtime validation

Run the bidirectional COM1 session:

```powershell
.\scripts\test-runtime.ps1 -TimeoutSeconds 150
```

The harness boots the finished EFI image, waits for the permanent prompt and drives 27 commands covering navigation, mutation, pipelines, redirection, ELF inspection, task creation, hardware-tick sleep/wake, wait/reap, contained fault reporting, device/network diagnostics, fsck, sync, history and explicit shutdown.

A representative run reports:

```text
ZigOs persistent runtime shutdown: commands 27 failed 0 ticks 424 idle-halts 424 service-passes 424
ZigOs persistent VFS: nodes 40 files 10 directories 18 pseudo 12 mounts 5 bytes 30938 clean yes
ZigOs persistent processes: live 2 created 4 reaped 2 switches 41 signals 0 faults 1
```

Tick totals vary slightly with host scheduling. The harness verifies the semantic results and continued servicing rather than one exact tick value.

## Runtime VFS

The x86-64 runtime VFS currently provides:

- 96 bounded nodes;
- ordinary files up to 16 KiB;
- absolute and relative path resolution;
- repeated-separator, `.` and `..` normalization;
- files, directories and pseudo-files;
- create, replace, truncate, read, write, append and seek;
- directory creation and empty-directory removal;
- unlink and rename with cycle and cross-mount rejection;
- stat and chmod metadata;
- generation-safe, process-owned open handles;
- descriptor quotas and structural integrity validation.

Mounted namespaces:

```text
/       ramfs       writable, lost at reboot
/boot   boot_fat    read-only verified boot namespace
/proc   procfs      runtime process information
/dev    devfs       retained device information
/net    netfs       retained network information
```

The root filesystem is currently RAM-backed. `sync` therefore reports zero persistent block flushes, and `/boot` remains read-only.

## Runtime process table

The permanent process table is distinct from the bounded executable CPL3 suite inherited from Capstone 16. It currently provides:

- 64 recyclable slots and monotonic PIDs;
- generation-tagged handles;
- PPID, process group, session, current directory, UID and GID fields;
- runnable, running, sleeping, blocked, stopped, zombie and faulted states;
- bounded round-robin scheduling and tick accounting;
- wait, terminal status and one-time reaping;
- orphan adoption by PID 1;
- directed and process-group signals;
- pending masks and basic UID permission checks;
- page, descriptor, socket, child and CPU quotas;
- fault vector, address and terminal-status records.

It does not yet own persistent private CR3 contexts for arbitrary executable processes. Unifying this table with the Capstone 16 CPL3 engine is one of the next major milestones.

## Existing bounded x86-64 capabilities

Before entering the permanent runtime, the x86-64 kernel still runs its inherited assertion-heavy integration suites. These include:

- UEFI handoff, memory-map normalization, frame allocation and kernel-owned paging;
- higher-half aliases, GDT, TSS, IDT, IST stacks and exception recovery;
- local APIC, I/O APIC, HPET/ACPI PM/PIT timing and SMP startup;
- PCIe/legacy PCI discovery;
- NVMe, AHCI, xHCI, PS/2, framebuffer and COM1 paths;
- Intel 82574L/e1000e DMA and MSI-X operation;
- bounded DHCP, ARP, IPv4, ICMP, UDP, TFTP, DNS, NTP and TCP components;
- CPL3 transitions and an `int 0x80` service ABI;
- ELF64 parsing, private address spaces, copy-on-write fork, static-image exec, demand mapping, signals, pipes, waits and contained faults.

These components are validated against deterministic QEMU scenarios. They are not a production network stack or a general POSIX process environment.

A precise networking description is:

> ZigOs contains bounded in-kernel UDP, DNS, NTP and TCP components validated against deterministic QEMU scenarios, but does not yet expose a general userspace socket API or production network stack.

## Legacy BIOS/i686 path

The legacy path boots through a native 512-byte BIOS stage 0, an eight-sector stage 1 and an ELF32/freestanding Zig kernel. Its bounded environment includes:

- protected mode, E820 memory information, paging and heap allocation;
- PIC, PIT, PS/2 and COM1 interrupt handling;
- ATA PIO and writable FAT12;
- disk-loaded ELF32 CPL3 programs;
- process scheduling, fork/exec, waits, signals and fault containment;
- persistent file creation and a two-boot filesystem verification sequence.

Capstone 17 does not change the legacy functional contract. The complete i686 build and two-boot persistence regression remain required release gates.

## Requirements

### Build only

- Python 3
- NASM 2.16 or newer
- Internet access for the first checksum-pinned canonical Zig download

Supported build hosts:

- Windows x86-64 through PowerShell
- Linux x86-64 through POSIX shell
- Linux AArch64 through POSIX shell

The exact compiler revision is stored in `.toolchain-version`:

```text
0.17.0-dev.1420+5d08e4716
```

The scripts refuse to use a different Zig version silently.

### Integration tests

- QEMU x86-64/i386
- split OVMF/EDK2 code and variable-store images for UEFI tests
- PowerShell for the current hardware integration harnesses

## Build

### Standard Zig build graph

With the exact pinned Zig already available as `zig`:

```text
zig build
zig build test
zig build check
zig build assets
```

`zig build` generates all assembly/ELF assets, builds the UEFI application and installs:

```text
zig-out/
|-- EFI/
|   `-- BOOT/
|       `-- BOOTX64.EFI
`-- artifacts/
    |-- service-user.elf
    |-- process-user.elf
    `-- process-exec.elf
```

`zig build test` runs 19 isolated `std.testing` declarations: five VFS tests, eight process-table tests and six shell/parser/editor tests.

`zig build check` runs formatting, all isolated tests, the UEFI build and portable PE/COFF verification.

### Windows wrapper

```powershell
.\scripts\build.ps1
.\scripts\build.ps1 -Clean
.\scripts\build.ps1 -Optimize Debug
.\scripts\build.ps1 -Optimize ReleaseSafe
.\scripts\build.ps1 -Optimize ReleaseFast
.\scripts\build.ps1 -Optimize ReleaseSmall
```

### Linux wrapper

```sh
./scripts/build.sh
./scripts/build.sh test
./scripts/build.sh check
```

The Linux bootstrap supports x86-64 and AArch64 and verifies the downloaded archive SHA-256 before extraction.

### Make targets

```sh
make build
make assets
make test
make check
make clean
```

### Legacy i686

```powershell
.\scripts\build-legacy-i686.ps1
.\scripts\test-legacy-i686.ps1 -TimeoutSeconds 120
```

## Artifact identity

Capstone 17 reference UEFI image:

```text
Size:    2,649,088 bytes
SHA-256: 17CFB13A943D42877BEDF2265E547CD635BAC6A8D5FCC51195487FF775C3EFDC
```

A clean Windows build and a clean Ubuntu/WSL build produced byte-identical EFI images with this identity.

## QEMU validation

Reduced fallback profile:

```powershell
.\scripts\test-qemu.ps1 -NoHpet -NoPs2 -CpuCount 1 -NoUsbKeyboard -NoGraphics -TimeoutSeconds 120
```

Network-enabled hosted-stable profile:

```powershell
.\scripts\test-qemu.ps1 -Network -NoHpet -NoPs2 -CpuCount 1 -NoUsbKeyboard -NoGraphics -TimeoutSeconds 180
```

Persistent post-boot runtime:

```powershell
.\scripts\test-runtime.ps1 -TimeoutSeconds 150
```

Additional switches include `-CpuCount`, `-LegacyPci`, `-NvmeOnly`, `-Nvme4k`, `-LegacyAhci`, `-HighApicId`, `-SparseApicIds`, `-NoX2Apic`, `-NoGraphics`, `-NoUsbKeyboard` and `-UsbMouseOnly`.

## Continuous integration

The workflow contains two required implementation paths:

- **Portable Linux:** clean bootstrap, asset generation, formatting, 19 isolated tests, x86-64 UEFI build, portable PE verification and artifact upload.
- **Windows integration:** clean build, isolated checks, reduced fallback boot, a uniprocessor serial-only network profile, persistent COM1 runtime, legacy i686 build and two-boot persistence regression. Broader SMP, graphics and USB combinations remain extended local gates rather than being conflated with the hosted network proof.

A green badge therefore represents substantially more than the former reduced single-boot profile.

## Repository layout

```text
build.zig                         canonical x86-64 build graph
build.zig.zon                     package identity and minimum Zig revision
Makefile                          conventional POSIX targets
.github/workflows/build.yml       Linux and Windows CI matrix
.toolchain-version                exact canonical Zig revision
VERSION                           release version

docs/CAPSTONE-17.0.md            exact 96-goal release contract
docs/ROADMAP-500.md              500-goal general-OS program
docs/ROADMAP.md                  historical milestone record

scripts/build-assets.py           portable generated-asset pipeline
scripts/verify-efi.py             portable PE/COFF verifier
scripts/bootstrap-toolchain.sh    checksum-pinned Linux bootstrap
scripts/build.sh                  Linux zig-build wrapper
scripts/build.ps1                 Windows zig-build wrapper
scripts/test-runtime.ps1          bidirectional persistent COM1 test
scripts/test-qemu.ps1             x86-64 hardware/network test matrix
scripts/build-legacy-i686.ps1     legacy BIOS/i686 build
scripts/test-legacy-i686.ps1      legacy two-boot persistence test

src/main.zig                      UEFI entry and firmware handoff
src/kernel.zig                    post-UEFI integration and inherited gates
src/runtime.zig                   permanent x86-64 runtime and command dispatch
src/runtime_vfs.zig               bounded VFS and mount model
src/runtime_process.zig           generation-safe process table
src/runtime_command.zig           parser, environment and line editor
src/arch/x86_64/cpu.asm           instruction, interrupt and context entries
src/descriptor_tables.zig         GDT, TSS, IDT and permanent runtime gate setup
src/apic.zig                      LAPIC control and runtime clock
src/serial.zig                    COM1 transmit and receive
```

## Current limitations

- The permanent shell and its pseudo jobs still run as kernel-owned runtime services, not as arbitrary CPL3 programs.
- Storage-loaded ELF64 execution is not yet connected to the permanent process table.
- The writable x86-64 root filesystem is RAM-backed and does not survive reboot.
- The x86-64 boot FAT mount is read-only.
- The VFS is bounded and is not yet exposed through a complete userspace file syscall ABI.
- There is no general userspace socket API, long-lived production TCP service, IPv6 stack or firewall.
- Routing, ARP expiry and DHCP renewal are not yet general long-lived services.
- Hardware support remains strongly aligned with QEMU q35, QEMU NVMe/xHCI and Intel 82574L emulation.
- There is no complete user/group permission model, ASLR, IOMMU DMA isolation, executable-signing policy or stable ABI.
- Kernel and driver recovery behavior remains experimental; invariant failures may still halt the machine deliberately.

## Design principles

- Use assembly only where exact machine control is required.
- Keep policy, parsing and subsystem logic in readable Zig.
- Never depend silently on UEFI services after firmware handoff.
- Pin and verify the compiler and generated assets.
- Distinguish bounded validation components from general production interfaces.
- Prefer isolated unit tests plus end-to-end QEMU proofs.
- Treat every interrupt, DMA completion, page transition and on-disk mutation as something to verify.

## License

ZigOs is released under the [MIT License](LICENSE).
