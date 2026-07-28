# ZigOs

[![Build ZigOs](https://github.com/adybag14-cyber/ZigOs/actions/workflows/build.yml/badge.svg)](https://github.com/adybag14-cyber/ZigOs/actions/workflows/build.yml)

ZigOs is an experimental x86 operating system written in freestanding Zig and hand-written assembly. The primary target is an x86-64 UEFI kernel; a separate legacy BIOS/i686 kernel provides a smaller persistent FAT12 userspace environment.

ZigOs is a research and learning system. It is not production-ready, POSIX-compatible, secure against hostile workloads, or broadly validated on physical hardware.

## Current release: Capstone 19.0

Capstone 19 connects the permanent x86-64 process table, descriptor layer and scheduler to genuine retained CPL3 contexts. `run`, `exec` and `spawn` now read ELF64 bytes from the VFS, map them into private CR3 address spaces and execute their entry points instead of creating timed pseudo-jobs. `crash` runs a real faulting executable, and `pipex` proves that permanent pipes block and wake real executables.

The release adds 32 verified goals to the inherited 465 x86-64 goals, reaching **497 cumulative goals (`0x1F1`)**:

```text
ZigOs x86-64 Capstone 19 verified: goals 0x000001F1 new-goals 0x00000020 vfs-elf yes private-cr3 yes retained-contexts yes timer-preemption yes real-fault yes executable-pipes yes frame-reclamation yes network-facades-removed yes cleanup yes
```

The exact contract and limitations are documented in [`docs/CAPSTONE-19.0.md`](docs/CAPSTONE-19.0.md). Capstone 18's descriptor contract remains an inherited release gate. The broader program remains separately tracked in [`docs/ROADMAP-500.md`](docs/ROADMAP-500.md); granular Capstone proof accounting is not conflated with the broader roadmap. The post-release audit disposition and tiered architecture plan are recorded in [`docs/PRIORITY-REMEDIATION.md`](docs/PRIORITY-REMEDIATION.md).

Local Windows validation is complete for the canonical build, all 69 unique isolated-test declarations, the source contract, the 45-command offline runtime, the 47-command live-network runtime, the x86-64 NVMe two-boot persistence proof, persistent and diskless normal-boot profiles, and the legacy i686 two-boot regression. The required hosted workflow includes these gates plus cross-platform byte comparison.

## What runs after boot

The x86-64 kernel remains alive after validation unless an explicit `shutdown` command is entered. Its permanent runtime provides:

- a dedicated 100 Hz LAPIC timer and interrupt-enabled HLT idle loop;
- a permanent PID 1 record; in normal boot it runs the directly linked Zig `/bin/init.elf`, launches the interactive Zig PID 2 shell, waits for it and reaps it before final shutdown;
- a bounded writable VFS and six mounted namespaces;
- a generation-safe 64-slot process table whose ordinary round-robin service path owns foreground, background and fixture CPL3 dispatch without a second job table or direct shell dispatcher;
- process-local numeric descriptors, shared open-file descriptions and bounded blocking pipes;
- up to 64 retained CPL3 executable contexts backed by on-demand pages from a reclaiming post-bootstrap physical-memory manager and a 4,096-slot ownership table;
- private CR3 roots, strict W^X `PT_LOAD` mappings, eight-page stacks and unmapped guards;
- complete GPR and FXSAVE context preservation across syscalls and timer preemption;
- a pointer-validated ABI 1.6 with generated kernel Zig, NASM, public Zig and C interfaces, capability discovery, bounded `spawnv`, System V-style argv/envp/auxv startup, persistent `sync`, descriptor `lseek`/`fsync`, path `stat`, `openat`, TTY `ioctl`, pathname mutation, UDP datagram controls, exact waitpid, wait-any and WNOHANG;
- freestanding Zig and C SDKs with generated ABI structures, a SysV AMD64 startup/syscall shim, typed file/process/VM/poll/UDP/filesystem wrappers, a bounded DNS A resolver, environment/auxiliary helpers, a directly linked `/bin/init.elf`, and independently verified `/bin/sdk.elf`, `/bin/fs.elf`, `/bin/dns.elf` and `/bin/c-sdk.elf` conformance programs;
- an explicit `-Dnormal-boot=true` profile that skips the software proof suite, attaches `/bin/init.elf` to the reserved PID 1 handle, lets that CPL3 init supervise `/bin/sh.elf` as PID 2, and falls back to a tested RAM-root recovery session when no NVMe or SATA backend is usable;
- page-granular anonymous `mmap`, subrange `munmap`, W^X `mprotect` and expandable/shrinkable `brk`;
- descriptor-backed `fstat`, directory iteration and `poll`;
- eight descriptor/socket bookkeeping slots, with at most four simultaneously usable retained e1000e UDP endpoints, supporting bind, connect, send, receive, local/peer lookup, readiness and blocked-reader wakeup;
- real executable exit, sleep, preemption, fault containment, wait/reap and pipe block/wakeup;
- a retained bounded e1000e owner with real shell ICMP echo and DNS A queries when present, plus explicit offline status when absent;
- command parsing, bounded shell pipelines, descriptor-backed file redirection and history.

The default serial prompt is:

```text
root@zigos:/home/root#
```

### Runtime commands

```text
Filesystem and descriptors:
  pwd cd ls cat echo touch mkdir rm rmdir mv
  write append stat chmod mount df fds fdtest pipex sync fsck

Processes:
  ps jobs spawn kill wait crash sleep uptime elf exec run

Device and network status:
  devices ifconfig netstat sockets routes arp ping dns

Shell and utilities:
  env export unset history clear uname
  hash hexdump grep wc head shutdown
```

`run PATH [ARGS...]` and `exec PATH [ARGS...]` launch a foreground CPL3 child from VFS-resident ELF64 bytes. The current `exec` command does **not** replace the shell image in place. `spawn PATH [ARGS...]` launches the same retained executable model in the background. `/bin` remains boot-seeded RAM-VFS content, but the userspace shell can copy an ELF into `/persist`, mutate persistent files and directories through the versioned ABI, commit with `sync`, search `/bin:/persist`, and execute the restored NVMe-backed file after reboot.

`ping` and `dns` use the retained e1000e device for real bounded ICMP and UDP/DNS transactions when the network profile is present. `ifconfig`, `netstat`, `routes` and `arp` expose retained device state. With no e1000e device, all of these commands report explicit unavailability; none emits canned success, addresses or packets.

## Persistent-runtime validation

Run the bidirectional COM1 session:

```powershell
# Honest offline profile
.\scripts\test-runtime.ps1 -TimeoutSeconds 180

# Retained e1000e with real ping and DNS
.\scripts\test-runtime.ps1 -TimeoutSeconds 180 -Network
```

Each harness run boots the finished EFI image, waits for the permanent prompt and drives 45 commands offline or 47 commands with the live e1000e profile. It preserves the previous navigation, mutation, redirection, parser, descriptor, device, fsck, sync and history coverage, then additionally requires:

- `run` and `exec` to enter VFS-loaded CPL3 code;
- a real hardware-tick sleep and saved-context resume;
- a genuine vector-14 page fault with CR2 `0x8000180000`;
- a real CPL3 reader block and separate CPL3 writer wakeup;
- non-cooperative timer preemption of a background spin process;
- a genuinely blocking shell `wait` over a sleeping CPL3 child, default forced `kill` through signal 9, one-time reap, descriptor cleanup and frame cleanup;
- `/bin/wait.elf` spawning two VFS-backed CPL3 children and overlapping a 32-tick child and one-tick child to prove completion-ordered wait-any, exact waitpid and WNOHANG before exiting with status `0x31`;
- `/bin/vm.elf` proving ABI discovery, anonymous mapping, W^X protection changes, unmapping and heap-break growth/shrink before exiting with status `0x52`;
- `/bin/io.elf` proving descriptor-backed open/read/fstat/getdents/poll before exiting with status `0x53`;
- `/bin/socket.elf` proving socket-level and per-call nonblocking `EWOULDBLOCK`, unconnected DNS `sendto`, blocking scheduler-woken `recvfrom` with source metadata, `getpeername`, connected send, poll and close before exiting with status `0x54`;
- `/bin/dns.elf` proving that an arbitrary directly linked Zig process can encode a DNS A request, use ABI 1.6 datagrams, retry nonblocking receive to a tick deadline, validate compressed response records and resolve `localhost` to `127.0.0.1` before exiting with status `0x5A`;
- `/bin/c-sdk.elf` proving ABI 1.6 generated C layouts and wrappers, writable `/dev/null` and `/dev/zero`, an openable `/dev/console`, TTY ioctl flags, path `stat`, directory-descriptor and absolute `openat`, and descriptor `fsync` before exiting with status `0x57`;
- `/bin/init.elf` running as CPL3 PID 1, launching `/bin/sh.elf` through `spawnv`, waiting for PID 2, reaping it and issuing final shutdown;
- the normal userspace shell copying `/bin/sdk.elf` to `/persist/persist-sdk.elf`, committing it through syscall 97, resolving `persist-sdk` through `PATH=/bin:/persist` and receiving status `0x56`;
- the two-boot NVMe gate restoring and executing `/persist/persist-sdk.elf` before committing the alternate journal generation;
- `/bin/fs.elf` proving userspace `mkdir`, write, `lseek`, rename, chmod, unlink-while-open with descriptor access and final-close reclamation, rmdir and sync, then reboot-verifying mode/content/offset and committing cleanup from CPL3;
- the normal Zig shell exercising write, append, mkdir, rm, rmdir, mv and chmod without invoking the diagnostic kernel command implementation;
- real `10.0.2.2` ICMP and `localhost` DNS results in the network profile;
- explicit unavailable responses in the offline profile;
- absence of the former canned DNS and ping strings in permanent-runtime output.

Representative exact shutdown contracts are:

```text
# Offline
ZigOs persistent runtime shutdown: commands 45 failed 0
ZigOs persistent descriptors: ... dup/inherited/cloexec 2/56/1 ... clean yes
ZigOs persistent storage: mounted yes generation/slot 1/0 ... NVMe read/write/flush .../2/2 errors 0/0 clean yes
ZigOs post-bootstrap physical memory: ... peak 48 alloc/free 246/246 failed/rejected 0/0 clean yes
ZigOs permanent userspace: page-limit 4096 used 0 peak 48 contexts 0 launches/exits/faults 15/13/1 ... reclaimed 246 stale-contexts-swept 0 allocator alloc/release/retains 246/246/0 shared/oom/rejected 0/0/0 clean yes
ZigOs permanent network: device no ping 0 dns 0 failures 0 clean yes

# Live e1000e
ZigOs persistent runtime shutdown: commands 47 failed 0
ZigOs persistent descriptors: ... dup/inherited/cloexec 2/62/1 ... clean yes
ZigOs persistent storage: mounted yes generation/slot 1/0 ... NVMe read/write/flush .../2/2 errors 0/0 clean yes
ZigOs post-bootstrap physical memory: ... peak 48 alloc/free 277/277 failed/rejected 0/0 clean yes
ZigOs permanent userspace: page-limit 4096 used 0 peak 48 contexts 0 launches/exits/faults 17/15/1 ... reclaimed 277 stale-contexts-swept 0 allocator alloc/release/retains 277/277/0 shared/oom/rejected 0/0/0 clean yes
ZigOs permanent network: device yes ping 1 dns 1 failures 0 clean yes

# Normal userspace-shell profile
ZigOs normal userspace shutdown: init PID 1 status 0 shell PID 2 reaped yes
ZigOs normal userspace resources: processes 1 descriptors 0 contexts 0 pages 0 alloc/free 99/99 storage persistent clean yes
ZigOs normal boot verified: diagnostic-suite skipped yes userspace-init yes userspace-shell yes tty yes vfs yes spawn-wait yes storage persistent cleanup yes

# Diskless normal RAM-root recovery profile
ZigOs normal userspace resources: processes 1 descriptors 0 contexts 0 pages 0 alloc/free ... storage diskless-ram-root clean yes
ZigOs normal boot verified: diagnostic-suite skipped yes userspace-init yes userspace-shell yes tty yes vfs yes spawn-wait yes storage diskless-ram-root cleanup yes
```

Tick, switch and preemption totals vary slightly with host scheduling. Process states, exit/fault results, descriptor deltas, payload bytes and final cleanup are exact.

## Runtime VFS

The x86-64 runtime VFS currently provides:

- 96 bounded nodes;
- ordinary files up to 32 KiB;
- absolute and relative path resolution;
- repeated-separator, `.` and `..` normalization;
- files, directories and pseudo-files;
- create, replace, truncate, read, write, append and seek;
- directory creation and empty-directory removal;
- unlink and rename with cycle and cross-mount rejection;
- immediate pathname removal with deferred reclamation while open descriptions still reference a file;
- directory-descriptor-relative `openat` and one shared VFS-to-ABI metadata conversion for `stat`/`fstat`;
- stat and chmod metadata;
- generation-safe VFS open handles used behind shared open-file descriptions;
- descriptor-backed read, write, append, seek and truncate operations;
- descriptor quotas and structural integrity validation.

Mounted namespaces:

```text
/       ramfs       writable, lost at reboot
/boot   boot_fat    read-only verified boot namespace
/proc   procfs      runtime process information
/dev    devfs       retained device information
/net    netfs       retained network information
/persist zigos_persist bounded NVMe A/B journal when available
```

The general root remains RAM-backed, while `/persist` is a writable NVMe-backed `zigos_persist` mount using alternating checksummed generations. Kernel and userspace `sync` paths write the payload, flush it, commit a FUA generation header and flush again. Regular files—including linked ELF64 programs up to the VFS limit—are restored into `/persist` and can be executed after reboot; `/boot` remains read-only.

## Runtime file descriptors and pipes

The permanent descriptor layer provides:

- 32 numeric descriptor slots per process and a global 96-entry open-description pool;
- readable fd 0 and writable fd 1/fd 2 terminal descriptions for the shell;
- deterministic lowest-free allocation;
- shared offsets and reference counts across `dup`, `dup2` and cloned namespaces;
- process-local close-on-exec flags and exact close-on-exec cleanup;
- regular-file read, write, append, seek and truncate operations;
- 32 bounded 1,024-byte circular pipes;
- reader blocking on empty pipes and writer blocking on full pipes;
- targeted scheduler wakeups, final-writer EOF and final-reader broken-pipe behavior;
- complete namespace, open-description, VFS-handle and endpoint reclamation;
- `fds` inspection and a repeatable live `fdtest` contract.

Ordinary `cat`, `write`, `append`, `<`, `>` and `>>` file paths use this layer. Shell pipeline stages still exchange bounded intermediate buffers rather than live descriptor-connected processes, and general permanent CPL3 file syscalls remain future work.

## Runtime process table and executable contexts

The permanent process table now owns real executable lifecycle records. It provides:

- 64 recyclable process slots and monotonic PIDs;
- generation-tagged handles and parent/current-directory metadata;
- runnable, running, sleeping, blocked, stopped, zombie and faulted states;
- bounded round-robin scheduling, hardware-tick accounting and targeted wakeups;
- waits, terminal status, one-time reaping and PID 1 adoption;
- directed/process-group signals and basic UID permission checks;
- page, descriptor, socket, child and CPU quotas;
- fault vector/address records derived from genuine CPL3 exceptions.

The permanent executor supports up to 64 retained CPL3 process slots and 1,024 tracked mappings per context. After boot validation, the monotonic allocator is sealed and every remaining usable firmware extent is transferred to a reclaiming physical-memory manager. The executor requests pages on demand below 4 GiB through a 256-slot ownership table; final releases poison pages, return them to the manager and require exact ownership-layer and physical-manager allocation/free balance at shutdown. Each process receives a private CR3, a complete saved integer/FX context, an eight-page stack, an unmapped guard page and cloned descriptor namespace. Untouched extents above 4 GiB are retained and counted, but ordinary runtime use of them awaits a direct physical-memory map.

This is still not a general POSIX process implementation. There is no persistent-runtime fork/COW, in-place exec, dynamic linker, flexible stack growth, ASLR, SMP userspace scheduler, or unified task object combining process metadata with saved architecture context.

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

> ZigOs retains one bounded e1000e device into the permanent runtime. The shell performs real ICMP echo and DNS A queries, while ABI version 1 exposes a bounded descriptor-backed UDP socket subset. The broader NTP/TCP components remain assertion-heavy kernel mechanisms rather than a production network stack.

## Legacy BIOS/i686 path

The legacy path boots through a native 512-byte BIOS stage 0, an eight-sector stage 1 and an ELF32/freestanding Zig kernel. Its bounded environment includes:

- protected mode, E820 memory information, paging and heap allocation;
- PIC, PIT, PS/2 and COM1 interrupt handling;
- ATA PIO and writable FAT12;
- disk-loaded ELF32 CPL3 programs;
- process scheduling, fork/exec, waits, signals and fault containment;
- persistent file creation and a two-boot filesystem verification sequence.

Capstone 19 does not change the legacy functional contract. The complete i686 build and two-boot persistence regression remain required release gates.

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
    |-- process-exec.elf
    |-- sdk.elf
    |-- init.elf
    |-- sh.elf
    |-- fs.elf
    |-- dns.elf
    |-- c-sdk.elf
    `-- runtime-*.elf
```

`zig build test` executes ten canonical host-test roots covering 69 unique `std.testing` declarations across eleven source files, including descriptors, commands, processes, TTY, VFS, ABI, page ownership, persistence, ELF loading and the DNS codec. Imported tests may execute from more than one root, but the source contract counts each declaration once.

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

Capstone 19 reference UEFI image:

```text
Size:    6,907,392 bytes
SHA-256: CCE69C03D91E8EFFED6687E42CA61F8EC8C3AC4C4B150BA8DEF11107A683A1D8
```

This identity is from the locally validated Windows diagnostic ABI 1.6 build with the Zig/C SDK, per-node device operations, diskless recovery, directory-relative `openat`, unified `stat`/`fstat` metadata and deferred open-file unlink reclamation. Hosted CI now downloads the Linux and Windows artifact sets into one required job and compares every path byte-for-byte.

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
.\scripts\test-runtime.ps1 -TimeoutSeconds 180

# Required live-network permanent-shell profile
.\scripts\test-runtime.ps1 -TimeoutSeconds 180 -Network

# Normal profile: real Zig userspace PID 1 supervising the PID 2 shell
python .\scripts\test-normal-boot.py --boot-timeout 240

# Diskless recovery: USB boot, no usable NVMe/SATA, RAM-backed root
python .\scripts\test-diskless-normal-boot.py --skip-build --boot-timeout 240
```

Additional switches include `-CpuCount`, `-LegacyPci`, `-NvmeOnly`, `-Nvme4k`, `-LegacyAhci`, `-HighApicId`, `-SparseApicIds`, `-NoX2Apic`, `-NoGraphics`, `-NoUsbKeyboard` and `-UsbMouseOnly`.

## Continuous integration

The workflow contains two required implementation paths:

- **Portable Linux:** clean bootstrap, asset generation, formatting, 69 unique isolated declarations, directly linked Zig/C SDK, init, shell and DNS verification, x86-64 UEFI build, portable PE verification and artifact upload.
- **Windows integration:** clean build, isolated checks, reduced fallback boot, a uniprocessor serial-only network profile, the 45-command offline and 47-command live-network permanent COM1 sessions, the x86-64 NVMe two-boot proof, persistent and diskless normal boots, and the legacy i686 build/two-boot regression.
- **Cross-platform identity:** download both artifact sets and require identical relative paths and byte-for-byte contents. Broader SMP, graphics and USB combinations remain extended local gates.

A green badge therefore represents substantially more than the former reduced single-boot profile.

## Repository layout

```text
build.zig                         canonical x86-64 build graph
build.zig.zon                     package identity and minimum Zig revision
Makefile                          conventional POSIX targets
.github/workflows/build.yml       Linux and Windows CI matrix
.toolchain-version                exact canonical Zig revision
VERSION                           release version

docs/CAPSTONE-19.0.md            exact permanent-userspace release contract
docs/CAPSTONE-18.0.md            inherited descriptor release contract
docs/CAPSTONE-17.0.md            inherited permanent-runtime contract
docs/ROADMAP-500.md              500-goal general-OS program
docs/PRIORITY-REMEDIATION.md     audit disposition and tier plan
docs/THREAT-MODEL.md             current trust boundary, mitigations and security gaps
docs/ROADMAP.md                  historical milestone record

scripts/build-assets.py           portable generated-asset pipeline
scripts/verify-efi.py             portable PE/COFF verifier
scripts/verify-permanent-userspace.py source/release contract verifier
scripts/create-runtime-user-elf.py deterministic permanent ELF generator
scripts/verify-runtime-user-elf.py independent permanent ELF verifier
scripts/bootstrap-toolchain.sh    checksum-pinned Linux bootstrap
scripts/build.sh                  Linux zig-build wrapper
scripts/build.ps1                 Windows zig-build wrapper
scripts/test-runtime.ps1          bidirectional persistent COM1 test
scripts/test-diskless-normal-boot.py USB-booted RAM-root recovery gate
scripts/test-qemu.ps1             x86-64 hardware/network test matrix
scripts/build-legacy-i686.ps1     legacy BIOS/i686 build
scripts/test-legacy-i686.ps1      legacy two-boot persistence test

src/main.zig                      UEFI entry and firmware handoff
src/kernel.zig                    post-UEFI integration and inherited gates
src/runtime.zig                   permanent x86-64 runtime and command dispatch
src/runtime_user.zig              retained CPL3 executor and syscall/fault bridge
src/runtime_vfs.zig               bounded VFS and mount model
src/runtime_fd.zig                numeric descriptors, shared descriptions and pipes
src/runtime_process.zig           generation-safe process table
src/runtime_command.zig           parser, environment and line editor
sdk/c/include/zigos.h             generated public C ABI
sdk/c/zigos.c                     freestanding C syscall wrapper library
src/arch/x86_64/cpu.asm           instruction, interrupt and context entries
src/descriptor_tables.zig         GDT, TSS, IDT and permanent runtime gate setup
src/apic.zig                      LAPIC control and runtime clock
src/serial.zig                    COM1 transmit and receive
```

## Current limitations

- `/bin` is boot-seeded RAM-VFS content; executable files are not yet fetched from a disk-backed filesystem at launch.
- Permanent execution accepts only the strict static x86-64 `ET_EXEC` layouts supported by `elf64.zig`; there is no `ET_DYN`, dynamic linker or relocation support.
- The permanent executor is bounded to 64 contexts, 1,024 mapping records per context, a fixed eight-page stack and bounded output buffers.
- The shell `exec` command launches a foreground child instead of replacing the shell process image.
- Fork, copy-on-write, demand paging, file-backed mappings and flexible guard-fault stack growth are not implemented; startup environment and auxiliary vectors are bounded rather than general.
- Shell pipeline stages still exchange bounded kernel buffers; `pipex` is the real executable pipe proof rather than a general process pipeline.
- The writable x86-64 root filesystem is RAM-backed and does not survive reboot; `/boot` remains read-only.
- The userspace network ABI is UDP-only, with eight descriptor bookkeeping slots but four active e1000e hardware endpoints and fixed receive queues. It supports connected and unconnected datagrams, source-address receive, peer inspection, poll and socket-level/per-call nonblocking receive, but there is no TCP listen/accept/data API, general socket-option layer, IPv6 or production network stack.
- Permanent userspace scheduling currently runs on the BSP rather than an SMP scheduler.
- Hardware support remains strongly aligned with QEMU q35, QEMU NVMe/xHCI and Intel 82574L emulation.
- ABI version 1.6 provides generated Zig/NASM/C syscall interfaces, bounded startup/spawn vectors, capability discovery and errno conventions, but it is still experimental: there is no formal compatibility guarantee, complete user/group permission model, ASLR, IOMMU DMA isolation or executable-signing policy.
- ZigOs remains experimental, non-POSIX and not secure against hostile workloads.

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
