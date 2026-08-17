const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Kernel optimization mode (default: ReleaseSmall)",
    ) orelse .ReleaseSmall;
    const normal_boot = b.option(
        bool,
        "normal-boot",
        "Skip the diagnostic proof suite and launch the userspace PID 2 shell",
    ) orelse false;
    const nvme_read_fault_lba = b.option(
        u64,
        "nvme-read-fault-lba",
        "Replace the first runtime read of this LBA with a one-past-end NVMe command",
    ) orelse std.math.maxInt(u64);
    const nvme_write_fault_lba = b.option(
        u64,
        "nvme-write-fault-lba",
        "Replace the first runtime write of this LBA with a one-past-end NVMe command",
    ) orelse std.math.maxInt(u64);

    const python = switch (b.graph.host.result.os.tag) {
        .windows => "python",
        else => "python3",
    };

    const assets = b.addSystemCommand(&.{
        python,
        "scripts/build-assets.py",
        "--repo-root",
        ".",
    });
    assets.setCwd(b.path("."));
    assets.has_side_effects = true;

    const assets_step = b.step("assets", "Generate and verify assembly/ELF build assets");
    assets_step.dependOn(&assets.step);

    const sdk_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const sdk_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/conformance.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    sdk_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const sdk_conformance = b.addExecutable(.{
        .name = "sdk",
        .root_module = sdk_module,
    });
    sdk_conformance.entry = .{ .symbol_name = "_start" };
    sdk_conformance.setLinkerScript(b.path("sdk/zig/linker.ld"));
    sdk_conformance.step.dependOn(&assets.step);

    const shell_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/shell.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    shell_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_shell = b.addExecutable(.{
        .name = "sh",
        .root_module = shell_module,
    });
    userspace_shell.entry = .{ .symbol_name = "_start" };
    userspace_shell.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_shell.step.dependOn(&assets.step);

    const init_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/init.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    init_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_init = b.addExecutable(.{
        .name = "init",
        .root_module = init_module,
    });
    userspace_init.entry = .{ .symbol_name = "_start" };
    userspace_init.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_init.step.dependOn(&assets.step);

    const fs_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/fs_conformance.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    fs_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const fs_conformance = b.addExecutable(.{
        .name = "fs",
        .root_module = fs_module,
    });
    fs_conformance.entry = .{ .symbol_name = "_start" };
    fs_conformance.setLinkerScript(b.path("sdk/zig/linker.ld"));
    fs_conformance.step.dependOn(&assets.step);

    const ps_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/ps.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    ps_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_ps = b.addExecutable(.{
        .name = "ps",
        .root_module = ps_module,
    });
    userspace_ps.entry = .{ .symbol_name = "_start" };
    userspace_ps.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_ps.step.dependOn(&assets.step);

    const hexdump_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/hexdump.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    hexdump_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_hexdump = b.addExecutable(.{
        .name = "hexdump",
        .root_module = hexdump_module,
    });
    userspace_hexdump.entry = .{ .symbol_name = "_start" };
    userspace_hexdump.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_hexdump.step.dependOn(&assets.step);

    const head_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/head.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    head_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_head = b.addExecutable(.{
        .name = "head",
        .root_module = head_module,
    });
    userspace_head.entry = .{ .symbol_name = "_start" };
    userspace_head.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_head.step.dependOn(&assets.step);

    const tail_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/tail.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    tail_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_tail = b.addExecutable(.{
        .name = "tail",
        .root_module = tail_module,
    });
    userspace_tail.entry = .{ .symbol_name = "_start" };
    userspace_tail.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_tail.step.dependOn(&assets.step);

    const wc_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/wc.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    wc_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_wc = b.addExecutable(.{
        .name = "wc",
        .root_module = wc_module,
    });
    userspace_wc.entry = .{ .symbol_name = "_start" };
    userspace_wc.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_wc.step.dependOn(&assets.step);

    const grep_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/grep.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    grep_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_grep = b.addExecutable(.{
        .name = "grep",
        .root_module = grep_module,
    });
    userspace_grep.entry = .{ .symbol_name = "_start" };
    userspace_grep.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_grep.step.dependOn(&assets.step);

    const stat_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/stat.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    stat_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_stat = b.addExecutable(.{
        .name = "stat",
        .root_module = stat_module,
    });
    userspace_stat.entry = .{ .symbol_name = "_start" };
    userspace_stat.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_stat.step.dependOn(&assets.step);

    const mv_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/mv.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    mv_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_mv = b.addExecutable(.{
        .name = "mv",
        .root_module = mv_module,
    });
    userspace_mv.entry = .{ .symbol_name = "_start" };
    userspace_mv.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_mv.step.dependOn(&assets.step);

    const cp_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/cp.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    cp_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_cp = b.addExecutable(.{
        .name = "cp",
        .root_module = cp_module,
    });
    userspace_cp.entry = .{ .symbol_name = "_start" };
    userspace_cp.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_cp.step.dependOn(&assets.step);

    const rm_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/rm.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    rm_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_rm = b.addExecutable(.{
        .name = "rm",
        .root_module = rm_module,
    });
    userspace_rm.entry = .{ .symbol_name = "_start" };
    userspace_rm.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_rm.step.dependOn(&assets.step);

    const rmdir_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/rmdir.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    rmdir_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_rmdir = b.addExecutable(.{
        .name = "rmdir",
        .root_module = rmdir_module,
    });
    userspace_rmdir.entry = .{ .symbol_name = "_start" };
    userspace_rmdir.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_rmdir.step.dependOn(&assets.step);

    const mkdir_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/mkdir.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    mkdir_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_mkdir = b.addExecutable(.{
        .name = "mkdir",
        .root_module = mkdir_module,
    });
    userspace_mkdir.entry = .{ .symbol_name = "_start" };
    userspace_mkdir.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_mkdir.step.dependOn(&assets.step);

    const pwd_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/pwd.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    pwd_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_pwd = b.addExecutable(.{
        .name = "pwd",
        .root_module = pwd_module,
    });
    userspace_pwd.entry = .{ .symbol_name = "_start" };
    userspace_pwd.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_pwd.step.dependOn(&assets.step);

    const echo_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/echo.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    echo_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_echo = b.addExecutable(.{
        .name = "echo",
        .root_module = echo_module,
    });
    userspace_echo.entry = .{ .symbol_name = "_start" };
    userspace_echo.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_echo.step.dependOn(&assets.step);

    const cat_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/cat.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    cat_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_cat = b.addExecutable(.{
        .name = "cat",
        .root_module = cat_module,
    });
    userspace_cat.entry = .{ .symbol_name = "_start" };
    userspace_cat.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_cat.step.dependOn(&assets.step);

    const ls_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/ls.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    ls_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const userspace_ls = b.addExecutable(.{
        .name = "ls",
        .root_module = ls_module,
    });
    userspace_ls.entry = .{ .symbol_name = "_start" };
    userspace_ls.setLinkerScript(b.path("sdk/zig/linker.ld"));
    userspace_ls.step.dependOn(&assets.step);

    const dns_module = b.createModule(.{
        .root_source_file = b.path("sdk/zig/dns_conformance.zig"),
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    dns_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const dns_conformance = b.addExecutable(.{
        .name = "dns",
        .root_module = dns_module,
    });
    dns_conformance.entry = .{ .symbol_name = "_start" };
    dns_conformance.setLinkerScript(b.path("sdk/zig/linker.ld"));
    dns_conformance.step.dependOn(&assets.step);

    const c_sdk_module = b.createModule(.{
        .target = sdk_target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .code_model = .large,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
    });
    c_sdk_module.addIncludePath(b.path("sdk/c/include"));
    c_sdk_module.addCSourceFiles(.{
        .files = &.{ "sdk/c/zigos.c", "sdk/c/conformance.c" },
        .flags = &.{ "-std=c11", "-ffreestanding", "-fno-builtin", "-fno-stack-protector", "-fno-pic" },
    });
    c_sdk_module.addObjectFile(b.path("build/sdk/syscall.o"));
    const c_sdk_conformance = b.addExecutable(.{
        .name = "c-sdk",
        .root_module = c_sdk_module,
    });
    c_sdk_conformance.entry = .{ .symbol_name = "_start" };
    c_sdk_conformance.setLinkerScript(b.path("sdk/zig/linker.ld"));
    c_sdk_conformance.step.dependOn(&assets.step);

    const sdk_embed = b.addWriteFiles();
    _ = sdk_embed.addCopyFile(sdk_conformance.getEmittedBin(), "sdk.elf");
    _ = sdk_embed.addCopyFile(userspace_init.getEmittedBin(), "init.elf");
    _ = sdk_embed.addCopyFile(userspace_shell.getEmittedBin(), "sh.elf");
    _ = sdk_embed.addCopyFile(fs_conformance.getEmittedBin(), "fs.elf");
    _ = sdk_embed.addCopyFile(userspace_ps.getEmittedBin(), "ps.elf");
    _ = sdk_embed.addCopyFile(userspace_hexdump.getEmittedBin(), "hexdump.elf");
    _ = sdk_embed.addCopyFile(userspace_head.getEmittedBin(), "head.elf");
    _ = sdk_embed.addCopyFile(userspace_tail.getEmittedBin(), "tail.elf");
    _ = sdk_embed.addCopyFile(userspace_wc.getEmittedBin(), "wc.elf");
    _ = sdk_embed.addCopyFile(userspace_grep.getEmittedBin(), "grep.elf");
    _ = sdk_embed.addCopyFile(userspace_stat.getEmittedBin(), "stat.elf");
    _ = sdk_embed.addCopyFile(userspace_mv.getEmittedBin(), "mv.elf");
    _ = sdk_embed.addCopyFile(userspace_cp.getEmittedBin(), "cp.elf");
    _ = sdk_embed.addCopyFile(userspace_rm.getEmittedBin(), "rm.elf");
    _ = sdk_embed.addCopyFile(userspace_rmdir.getEmittedBin(), "rmdir.elf");
    _ = sdk_embed.addCopyFile(userspace_mkdir.getEmittedBin(), "mkdir.elf");
    _ = sdk_embed.addCopyFile(userspace_pwd.getEmittedBin(), "pwd.elf");
    _ = sdk_embed.addCopyFile(userspace_echo.getEmittedBin(), "echo.elf");
    _ = sdk_embed.addCopyFile(userspace_cat.getEmittedBin(), "cat.elf");
    _ = sdk_embed.addCopyFile(userspace_ls.getEmittedBin(), "ls.elf");
    _ = sdk_embed.addCopyFile(dns_conformance.getEmittedBin(), "dns.elf");
    _ = sdk_embed.addCopyFile(c_sdk_conformance.getEmittedBin(), "c-sdk.elf");
    const sdk_embed_module = sdk_embed.add(
        "runtime_sdk.zig",
        "pub const sdk = @embedFile(\"sdk.elf\");\n" ++
            "pub const init = @embedFile(\"init.elf\");\n" ++
            "pub const shell = @embedFile(\"sh.elf\");\n" ++
            "pub const fs = @embedFile(\"fs.elf\");\n" ++
            "pub const ps = @embedFile(\"ps.elf\");\n" ++
            "pub const hexdump = @embedFile(\"hexdump.elf\");\n" ++
            "pub const head = @embedFile(\"head.elf\");\n" ++
            "pub const tail = @embedFile(\"tail.elf\");\n" ++
            "pub const wc = @embedFile(\"wc.elf\");\n" ++
            "pub const grep = @embedFile(\"grep.elf\");\n" ++
            "pub const stat = @embedFile(\"stat.elf\");\n" ++
            "pub const mv = @embedFile(\"mv.elf\");\n" ++
            "pub const cp = @embedFile(\"cp.elf\");\n" ++
            "pub const rm = @embedFile(\"rm.elf\");\n" ++
            "pub const rmdir = @embedFile(\"rmdir.elf\");\n" ++
            "pub const mkdir = @embedFile(\"mkdir.elf\");\n" ++
            "pub const pwd = @embedFile(\"pwd.elf\");\n" ++
            "pub const echo = @embedFile(\"echo.elf\");\n" ++
            "pub const cat = @embedFile(\"cat.elf\");\n" ++
            "pub const ls = @embedFile(\"ls.elf\");\n" ++
            "pub const dns = @embedFile(\"dns.elf\");\n" ++
            "pub const c_sdk = @embedFile(\"c-sdk.elf\");\n",
    );

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .msvc,
    });

    const build_options = b.addOptions();
    build_options.addOption(bool, "normal_boot", normal_boot);
    build_options.addOption(u64, "nvme_read_fault_lba", nvme_read_fault_lba);
    build_options.addOption(u64, "nvme_write_fault_lba", nvme_write_fault_lba);

    const kernel_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
        .stack_protector = false,
        .stack_check = false,
        .omit_frame_pointer = false,
    });
    kernel_module.addObjectFile(b.path("build/cpu.obj"));
    kernel_module.addOptions("build_options", build_options);
    kernel_module.addAnonymousImport("runtime_sdk", .{
        .root_source_file = sdk_embed_module,
    });

    const kernel = b.addExecutable(.{
        .name = "BOOTX64",
        .root_module = kernel_module,
    });
    kernel.step.dependOn(&assets.step);

    const install_efi = b.addInstallFile(
        kernel.getEmittedBin(),
        "EFI/BOOT/BOOTX64.EFI",
    );
    const install_service = b.addInstallFile(
        b.path("build/service-user.elf"),
        "artifacts/service-user.elf",
    );
    const install_process = b.addInstallFile(
        b.path("build/process-user.elf"),
        "artifacts/process-user.elf",
    );
    const install_exec = b.addInstallFile(
        b.path("build/process-exec.elf"),
        "artifacts/process-exec.elf",
    );
    const install_sdk = b.addInstallFile(
        sdk_conformance.getEmittedBin(),
        "artifacts/sdk.elf",
    );
    const install_init = b.addInstallFile(
        userspace_init.getEmittedBin(),
        "artifacts/init.elf",
    );
    const install_shell = b.addInstallFile(
        userspace_shell.getEmittedBin(),
        "artifacts/sh.elf",
    );
    const install_fs = b.addInstallFile(
        fs_conformance.getEmittedBin(),
        "artifacts/fs.elf",
    );
    const install_ps = b.addInstallFile(
        userspace_ps.getEmittedBin(),
        "artifacts/ps.elf",
    );
    const install_hexdump = b.addInstallFile(
        userspace_hexdump.getEmittedBin(),
        "artifacts/hexdump.elf",
    );
    const install_head = b.addInstallFile(
        userspace_head.getEmittedBin(),
        "artifacts/head.elf",
    );
    const install_tail = b.addInstallFile(
        userspace_tail.getEmittedBin(),
        "artifacts/tail.elf",
    );
    const install_wc = b.addInstallFile(
        userspace_wc.getEmittedBin(),
        "artifacts/wc.elf",
    );
    const install_grep = b.addInstallFile(
        userspace_grep.getEmittedBin(),
        "artifacts/grep.elf",
    );
    const install_stat = b.addInstallFile(
        userspace_stat.getEmittedBin(),
        "artifacts/stat.elf",
    );
    const install_mv = b.addInstallFile(
        userspace_mv.getEmittedBin(),
        "artifacts/mv.elf",
    );
    const install_cp = b.addInstallFile(
        userspace_cp.getEmittedBin(),
        "artifacts/cp.elf",
    );
    const install_rm = b.addInstallFile(
        userspace_rm.getEmittedBin(),
        "artifacts/rm.elf",
    );
    const install_rmdir = b.addInstallFile(
        userspace_rmdir.getEmittedBin(),
        "artifacts/rmdir.elf",
    );
    const install_mkdir = b.addInstallFile(
        userspace_mkdir.getEmittedBin(),
        "artifacts/mkdir.elf",
    );
    const install_pwd = b.addInstallFile(
        userspace_pwd.getEmittedBin(),
        "artifacts/pwd.elf",
    );
    const install_echo = b.addInstallFile(
        userspace_echo.getEmittedBin(),
        "artifacts/echo.elf",
    );
    const install_cat = b.addInstallFile(
        userspace_cat.getEmittedBin(),
        "artifacts/cat.elf",
    );
    const install_ls = b.addInstallFile(
        userspace_ls.getEmittedBin(),
        "artifacts/ls.elf",
    );
    const install_dns = b.addInstallFile(
        dns_conformance.getEmittedBin(),
        "artifacts/dns.elf",
    );
    const install_c_sdk = b.addInstallFile(
        c_sdk_conformance.getEmittedBin(),
        "artifacts/c-sdk.elf",
    );
    install_service.step.dependOn(&assets.step);
    install_process.step.dependOn(&assets.step);
    install_exec.step.dependOn(&assets.step);
    inline for (.{ "hello", "sleep", "wait-short", "crash", "spin", "pipe-reader", "pipe-writer", "wait", "vm", "io", "socket" }) |program| {
        const source = b.fmt("build/runtime-{s}.elf", .{program});
        const destination = b.fmt("artifacts/runtime-{s}.elf", .{program});
        const install_runtime_program = b.addInstallFile(b.path(source), destination);
        install_runtime_program.step.dependOn(&assets.step);
        b.getInstallStep().dependOn(&install_runtime_program.step);
    }

    b.getInstallStep().dependOn(&install_efi.step);
    b.getInstallStep().dependOn(&install_service.step);
    b.getInstallStep().dependOn(&install_process.step);
    b.getInstallStep().dependOn(&install_exec.step);
    b.getInstallStep().dependOn(&install_sdk.step);
    b.getInstallStep().dependOn(&install_init.step);
    b.getInstallStep().dependOn(&install_shell.step);
    b.getInstallStep().dependOn(&install_fs.step);
    b.getInstallStep().dependOn(&install_ps.step);
    b.getInstallStep().dependOn(&install_hexdump.step);
    b.getInstallStep().dependOn(&install_head.step);
    b.getInstallStep().dependOn(&install_tail.step);
    b.getInstallStep().dependOn(&install_wc.step);
    b.getInstallStep().dependOn(&install_grep.step);
    b.getInstallStep().dependOn(&install_stat.step);
    b.getInstallStep().dependOn(&install_mv.step);
    b.getInstallStep().dependOn(&install_cp.step);
    b.getInstallStep().dependOn(&install_rm.step);
    b.getInstallStep().dependOn(&install_rmdir.step);
    b.getInstallStep().dependOn(&install_mkdir.step);
    b.getInstallStep().dependOn(&install_pwd.step);
    b.getInstallStep().dependOn(&install_echo.step);
    b.getInstallStep().dependOn(&install_cat.step);
    b.getInstallStep().dependOn(&install_ls.step);
    b.getInstallStep().dependOn(&install_dns.step);
    b.getInstallStep().dependOn(&install_c_sdk.step);

    const verify_efi = b.addSystemCommand(&.{ python, "scripts/verify-efi.py" });
    verify_efi.addFileArg(kernel.getEmittedBin());
    const verify_sdk = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_sdk.addFileArg(sdk_conformance.getEmittedBin());
    const verify_init = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_init.addFileArg(userspace_init.getEmittedBin());
    const verify_shell = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_shell.addFileArg(userspace_shell.getEmittedBin());
    const verify_fs = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_fs.addFileArg(fs_conformance.getEmittedBin());
    const verify_ps = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_ps.addFileArg(userspace_ps.getEmittedBin());
    const verify_hexdump = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_hexdump.addFileArg(userspace_hexdump.getEmittedBin());
    const verify_head = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_head.addFileArg(userspace_head.getEmittedBin());
    const verify_tail = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_tail.addFileArg(userspace_tail.getEmittedBin());
    const verify_wc = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_wc.addFileArg(userspace_wc.getEmittedBin());
    const verify_grep = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_grep.addFileArg(userspace_grep.getEmittedBin());
    const verify_stat = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_stat.addFileArg(userspace_stat.getEmittedBin());
    const verify_mv = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_mv.addFileArg(userspace_mv.getEmittedBin());
    const verify_cp = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_cp.addFileArg(userspace_cp.getEmittedBin());
    const verify_rm = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_rm.addFileArg(userspace_rm.getEmittedBin());
    const verify_rmdir = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_rmdir.addFileArg(userspace_rmdir.getEmittedBin());
    const verify_mkdir = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_mkdir.addFileArg(userspace_mkdir.getEmittedBin());
    const verify_pwd = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_pwd.addFileArg(userspace_pwd.getEmittedBin());
    const verify_echo = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_echo.addFileArg(userspace_echo.getEmittedBin());
    const verify_cat = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_cat.addFileArg(userspace_cat.getEmittedBin());
    const verify_ls = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_ls.addFileArg(userspace_ls.getEmittedBin());
    const verify_dns = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_dns.addFileArg(dns_conformance.getEmittedBin());
    const verify_c_sdk = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_c_sdk.addFileArg(c_sdk_conformance.getEmittedBin());
    const verify_permanent_userspace = b.addSystemCommand(&.{ python, "scripts/verify-permanent-userspace.py" });
    verify_permanent_userspace.setCwd(b.path("."));
    verify_permanent_userspace.step.dependOn(&assets.step);

    const fmt = if (comptime builtin.zig_version.minor >= 17)
        b.addFmt(.{
            .paths = &.{ b.path("build.zig"), b.path("src"), b.path("sdk") },
            .check = true,
        })
    else
        b.addFmt(.{
            .paths = &.{ "build.zig", "src", "sdk" },
            .check = true,
        });

    const unit_step = b.step("test", "Run isolated runtime unit tests");
    inline for (.{
        "src/runtime_fd.zig",
        "src/runtime_command.zig",
        "src/runtime_process.zig",
        "src/runtime_pseudo_fs.zig",
        "src/runtime_tty.zig",
        "src/runtime_vfs.zig",
        "src/runtime_boot_fat.zig",
        "src/runtime_abi.zig",
        "src/runtime_page_pool.zig",
        "src/runtime_persist.zig",
        "src/elf64.zig",
        "sdk/zig/dns.zig",
    }) |source_path| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(source_path),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        tests.step.dependOn(&assets.step);
        const run_tests = b.addRunArtifact(tests);
        unit_step.dependOn(&run_tests.step);
    }

    const nvme_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/nvme.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    nvme_tests.step.dependOn(&assets.step);
    const run_nvme_tests = b.addRunArtifact(nvme_tests);
    unit_step.dependOn(&run_nvme_tests.step);

    const check_step = b.step("check", "Format, unit-test, build, and verify the x86-64 image");
    check_step.dependOn(&fmt.step);
    check_step.dependOn(unit_step);
    check_step.dependOn(&verify_efi.step);
    check_step.dependOn(&verify_sdk.step);
    check_step.dependOn(&verify_init.step);
    check_step.dependOn(&verify_shell.step);
    check_step.dependOn(&verify_fs.step);
    check_step.dependOn(&verify_ps.step);
    check_step.dependOn(&verify_hexdump.step);
    check_step.dependOn(&verify_head.step);
    check_step.dependOn(&verify_tail.step);
    check_step.dependOn(&verify_wc.step);
    check_step.dependOn(&verify_grep.step);
    check_step.dependOn(&verify_stat.step);
    check_step.dependOn(&verify_mv.step);
    check_step.dependOn(&verify_cp.step);
    check_step.dependOn(&verify_rm.step);
    check_step.dependOn(&verify_rmdir.step);
    check_step.dependOn(&verify_mkdir.step);
    check_step.dependOn(&verify_pwd.step);
    check_step.dependOn(&verify_echo.step);
    check_step.dependOn(&verify_cat.step);
    check_step.dependOn(&verify_ls.step);
    check_step.dependOn(&verify_dns.step);
    check_step.dependOn(&verify_c_sdk.step);
    check_step.dependOn(&verify_permanent_userspace.step);
}
