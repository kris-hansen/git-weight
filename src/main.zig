const std = @import("std");
const args_mod = @import("cli/args.zig");
const output = @import("cli/output.zig");
const json = @import("cli/json.zig");
const repository = @import("git/repository.zig");
const refs_mod = @import("git/refs.zig");
const objects = @import("analysis/objects.zig");
const paths = @import("analysis/paths.zig");
const largest = @import("analysis/largest.zig");
const summary = @import("analysis/summary.zig");
const packs = @import("analysis/packs.zig");

const ExitCode = u8;
pub const exit_success: ExitCode = 0;
pub const exit_general: ExitCode = 1;
pub const exit_invalid_args: ExitCode = 2;
pub const exit_not_found: ExitCode = 3;
pub const exit_unsupported: ExitCode = 4;
pub const exit_corrupt: ExitCode = 5;

comptime {
    // Reference all modules so `zig build test` compiles and runs their tests.
    _ = @import("cli/args.zig");
    _ = @import("cli/output.zig");
    _ = @import("cli/json.zig");
    _ = @import("git/repository.zig");
    _ = @import("git/refs.zig");
    _ = @import("git/object_id.zig");
    _ = @import("git/object.zig");
    _ = @import("git/loose.zig");
    _ = @import("git/pack/index.zig");
    _ = @import("git/pack/pack.zig");
    _ = @import("git/pack/delta.zig");
    _ = @import("git/commit.zig");
    _ = @import("git/tree.zig");
    _ = @import("git/tag.zig");
    _ = @import("analysis/summary.zig");
    _ = @import("analysis/largest.zig");
    _ = @import("analysis/paths.zig");
    _ = @import("analysis/objects.zig");
    _ = @import("analysis/packs.zig");
    _ = @import("platform/mmap.zig");
    _ = @import("platform/filesystem.zig");
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const w = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const errw = &stderr_writer.interface;

    var flushed = false;
    defer if (!flushed) w.flush() catch {};

    const allocator = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(allocator);

    const opts = args_mod.parse(argv[1..]) catch {
        try errw.writeAll("error: invalid arguments\n\n");
        try errw.writeAll(args_mod.usage_text);
        try errw.flush();
        flushed = true;
        std.process.exit(exit_invalid_args);
    };

    if (opts.help) {
        try w.writeAll(args_mod.usage_text);
        try w.flush();
        flushed = true;
        return;
    }
    if (opts.version) {
        try w.print("git-weight {s}\n", .{args_mod.version_string});
        try w.flush();
        flushed = true;
        return;
    }

    const code = run(init.io, allocator, w, errw, &opts);
    try w.flush();
    try errw.flush();
    flushed = true;
    if (code != exit_success) std.process.exit(code);
}

fn run(io: std.Io, allocator: std.mem.Allocator, w: *std.Io.Writer, errw: *std.Io.Writer, opts: *const args_mod.Options) ExitCode {
    const start_ts = std.Io.Timestamp.now(io, .awake);

    const start_path = opts.repo_path orelse ".";
    var repo = repository.discover(allocator, start_path) catch |err| switch (err) {
        error.OutOfMemory => return fail(errw, exit_general, "error: out of memory"),
        else => return fail(errw, exit_not_found, "error: not inside a Git repository"),
    };

    var store = objects.ObjectStore.open(allocator, &repo) catch |err| switch (err) {
        error.OutOfMemory, error.SystemResources => return fail(errw, exit_general, "error: out of memory"),
        error.UnsupportedFormat => return fail(errw, exit_unsupported, "error: unsupported Git format"),
        error.CorruptRepository => {
            if (opts.verbose) errw.print("error: corrupt repository ({s})\n", .{@errorName(err)}) catch {};
            return fail(errw, exit_corrupt, "error: corrupt repository");
        },
        error.Unexpected => return fail(errw, exit_general, "error: failed to read object database"),
    };

    var refs = refs_mod.readAll(allocator, &repo) catch {
        return fail(errw, exit_general, "error: failed to read refs");
    };

    if (opts.verbose) {
        const elapsed_ms = start_ts.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
        errw.print("verbose: opened store with {d} objects in {d} ms\n", .{
            store.objectCount(),
            elapsed_ms,
        }) catch {};
    }

    switch (opts.command) {
        .summary => {
            const s = summary.build(allocator, &repo, &store, &refs) catch |err| {
                return reportAnalysisError(errw, err);
            };
            if (opts.json) {
                var jw: json.JsonWriter = .{ .w = w };
                json.printSummary(&jw, &s) catch return exit_general;
            } else {
                output.printSummary(w, &s) catch return exit_general;
            }
        },
        .largest => {
            var filter: largest.Filter = .all;
            if (opts.current_only) filter = .current_only;
            if (opts.historical_only) filter = .historical_only;

            var path_map = paths.compute(&store, &refs, allocator) catch {
                return fail(errw, exit_general, "error: failed to resolve paths");
            };
            const entries = largest.topBlobs(&store, &path_map, allocator, opts.limit, opts.min_size, filter) catch {
                return fail(errw, exit_general, "error: failed to analyze blobs");
            };
            if (opts.json) {
                var jw: json.JsonWriter = .{ .w = w };
                json.printLargest(&jw, entries) catch return exit_general;
            } else {
                output.printLargest(w, entries) catch return exit_general;
            }
        },
        .objects => {
            const stats = objects.computeStats(&store) catch {
                return fail(errw, exit_general, "error: failed to analyze objects");
            };
            if (opts.json) {
                var jw: json.JsonWriter = .{ .w = w };
                json.printObjects(&jw, &stats) catch return exit_general;
            } else {
                output.printObjects(w, &stats) catch return exit_general;
            }
        },
        .packs => {
            const list = packs.listPacks(&store, allocator) catch {
                return fail(errw, exit_general, "error: failed to analyze packs");
            };
            if (opts.json) {
                var jw: json.JsonWriter = .{ .w = w };
                json.printPacks(&jw, list) catch return exit_general;
            } else {
                output.printPacks(w, list) catch return exit_general;
            }
        },
    }

    if (opts.verbose) {
        const elapsed_ms = start_ts.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
        errw.print("verbose: total {d} ms\n", .{elapsed_ms}) catch {};
    }
    return exit_success;
}

fn fail(errw: *std.Io.Writer, code: ExitCode, msg: []const u8) ExitCode {
    errw.print("{s}\n", .{msg}) catch {};
    return code;
}

fn reportAnalysisError(errw: *std.Io.Writer, err: anyerror) ExitCode {
    return switch (err) {
        error.OutOfMemory, error.SystemResources => fail(errw, exit_general, "error: out of memory"),
        error.CorruptRepository => fail(errw, exit_corrupt, "error: corrupt repository"),
        error.UnsupportedFormat => fail(errw, exit_unsupported, "error: unsupported Git format"),
        else => fail(errw, exit_general, "error: analysis failed"),
    };
}
