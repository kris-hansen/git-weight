const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    const package = @import("build.zig.zon");
    const version = b.option([]const u8, "version", "Version reported by --version") orelse package.version;
    options.addOption([]const u8, "version", version);
    const system_zlib = b.option(bool, "system-zlib", "Inflate via system libz instead of the pure-Zig flate implementation") orelse false;
    options.addOption(bool, "system_zlib", system_zlib);

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("build_options", options);
    if (system_zlib) {
        module.link_libc = true;
        module.linkSystemLibrary("z", .{});
    }

    const exe = b.addExecutable(.{
        .name = "git-weight",
        .root_module = module,
    });
    b.installArtifact(exe);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_module });
    test_module.addOptions("build_options", options);
    if (system_zlib) {
        test_module.link_libc = true;
        test_module.linkSystemLibrary("z", .{});
    }
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ReleaseSmall is ~17 KB; ReleaseFast is larger but ~2.7x less CPU per scanned byte.
    const wasm_optimize = b.option(std.builtin.OptimizeMode, "wasm-optimize", "Optimize mode for the wasm step (default ReleaseSmall)") orelse .ReleaseSmall;
    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm/complexity_wasm.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = wasm_optimize,
    });
    wasm_module.addImport("complexity_core", b.createModule(.{
        .root_source_file = b.path("src/analysis/core.zig"),
        .target = wasm_module.resolved_target,
        .optimize = wasm_optimize,
    }));
    const wasm = b.addExecutable(.{ .name = "git-weight-complexity", .root_module = wasm_module });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const install_wasm = b.addInstallArtifact(wasm, .{});
    const wasm_step = b.step("wasm", "Build the complexity core as wasm32-freestanding");
    wasm_step.dependOn(&install_wasm.step);
}
