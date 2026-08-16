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
    check_step.dependOn(&verify_cat.step);
    check_step.dependOn(&verify_ls.step);
    check_step.dependOn(&verify_dns.step);
    check_step.dependOn(&verify_c_sdk.step);
    check_step.dependOn(&verify_permanent_userspace.step);
}
