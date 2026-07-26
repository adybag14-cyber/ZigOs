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

    const sdk_embed = b.addWriteFiles();
    _ = sdk_embed.addCopyFile(sdk_conformance.getEmittedBin(), "sdk.elf");
    _ = sdk_embed.addCopyFile(userspace_shell.getEmittedBin(), "sh.elf");
    const sdk_embed_module = sdk_embed.add(
        "runtime_sdk.zig",
        "pub const sdk = @embedFile(\"sdk.elf\");\n" ++
            "pub const shell = @embedFile(\"sh.elf\");\n",
    );

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .msvc,
    });

    const build_options = b.addOptions();
    build_options.addOption(bool, "normal_boot", normal_boot);

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
    const install_shell = b.addInstallFile(
        userspace_shell.getEmittedBin(),
        "artifacts/sh.elf",
    );
    install_service.step.dependOn(&assets.step);
    install_process.step.dependOn(&assets.step);
    install_exec.step.dependOn(&assets.step);
    inline for (.{ "hello", "sleep", "crash", "spin", "pipe-reader", "pipe-writer", "wait", "vm", "io", "socket" }) |program| {
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
    b.getInstallStep().dependOn(&install_shell.step);

    const verify_efi = b.addSystemCommand(&.{ python, "scripts/verify-efi.py" });
    verify_efi.addFileArg(kernel.getEmittedBin());
    const verify_sdk = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_sdk.addFileArg(sdk_conformance.getEmittedBin());
    const verify_shell = b.addSystemCommand(&.{ python, "scripts/verify-zigos-sdk-elf.py" });
    verify_shell.addFileArg(userspace_shell.getEmittedBin());
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
        "src/runtime_tty.zig",
        "src/runtime_vfs.zig",
        "src/runtime_abi.zig",
        "src/runtime_page_pool.zig",
        "src/runtime_persist.zig",
        "src/elf64.zig",
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

    const check_step = b.step("check", "Format, unit-test, build, and verify the x86-64 image");
    check_step.dependOn(&fmt.step);
    check_step.dependOn(unit_step);
    check_step.dependOn(&verify_efi.step);
    check_step.dependOn(&verify_sdk.step);
    check_step.dependOn(&verify_shell.step);
    check_step.dependOn(&verify_permanent_userspace.step);
}
