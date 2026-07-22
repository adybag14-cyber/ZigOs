const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Kernel optimization mode (default: ReleaseSmall)",
    ) orelse .ReleaseSmall;

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

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .msvc,
    });

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
    install_service.step.dependOn(&assets.step);
    install_process.step.dependOn(&assets.step);
    install_exec.step.dependOn(&assets.step);

    b.getInstallStep().dependOn(&install_efi.step);
    b.getInstallStep().dependOn(&install_service.step);
    b.getInstallStep().dependOn(&install_process.step);
    b.getInstallStep().dependOn(&install_exec.step);

    const verify_efi = b.addSystemCommand(&.{ python, "scripts/verify-efi.py" });
    verify_efi.addFileArg(kernel.getEmittedBin());

    const fmt = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("src") },
        .check = true,
    });

    const unit_step = b.step("test", "Run isolated runtime unit tests");
    inline for (.{
        "src/runtime_fd.zig",
        "src/runtime_command.zig",
    }) |source_path| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(source_path),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        const run_tests = b.addRunArtifact(tests);
        unit_step.dependOn(&run_tests.step);
    }

    const check_step = b.step("check", "Format, unit-test, build, and verify the x86-64 image");
    check_step.dependOn(&fmt.step);
    check_step.dependOn(unit_step);
    check_step.dependOn(&verify_efi.step);
}
