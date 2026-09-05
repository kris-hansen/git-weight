const std = @import("std");

pub const version_string = "0.3.0";

pub const Command = enum {
    summary,
    largest,
    objects,
    packs,
    explain,
    refs,
    @"unreachable",
    changed,
};

pub const ParseError = error{
    InvalidArguments,
    OutOfMemory,
};

pub const Options = struct {
    command: Command = .summary,
    /// Repository path (from positional argument or --repo).
    repo_path: ?[]const u8 = null,
    /// Target argument for `explain` (path or object id).
    explain_target: ?[]const u8 = null,
    /// Path argument for `changed`.
    changed_path: ?[]const u8 = null,
    /// Base revision for `changed` (default HEAD~1).
    base_ref: ?[]const u8 = null,
    /// Target revision for `changed` (default HEAD).
    to_ref: ?[]const u8 = null,
    /// For `changed`: exit 1 when changed, 0 when unchanged.
    exit_code: bool = false,
    json: bool = false,
    limit: usize = 20,
    min_size: u64 = 0,
    threads: ?usize = null,
    no_color: bool = false,
    verbose: bool = false,
    quiet: bool = false,
    current_only: bool = false,
    historical_only: bool = false,
    help: bool = false,
    version: bool = false,
};

pub const usage_text =
    \\git-weight — find out what's weighing down your Git repository.
    \\
    \\Usage:
    \\  git weight [COMMAND] [PATH] [OPTIONS]
    \\
    \\Commands:
    \\  summary      High-level repository report (default)
    \\  largest      Largest blobs in repository history
    \\  objects      Per-type object counts and logical sizes
    \\  packs        Packfile statistics
    \\  explain      Explain why a path or object contributes to repository weight
    \\  refs         Refs retaining historical weight
    \\  unreachable  Unreachable objects reclaimable via git gc
    \\  changed      Whether a path changed between two revisions (CI)
    \\
    \\Options:
    \\  --json             Machine-readable JSON output
    \\  --limit N          Maximum entries to list (default 20; applies to largest/refs)
    \\  --base REF         Base revision for 'changed' (default HEAD~1)
    \\  --to REF           Target revision for 'changed' (default HEAD)
    \\  --exit-code        For 'changed': exit 1 when changed, 0 when unchanged
    \\  --min-size SIZE    Only include blobs at least SIZE (e.g. 10MB, 500KiB)
    \\  --threads N        Worker thread count (accepted; v0.1 runs single-threaded)
    \\  --current          Only blobs present in the tree at HEAD
    \\  --historical       Only blobs not present in the tree at HEAD
    \\  --no-color         Disable colored output
    \\  --verbose          Additional diagnostics on stderr
    \\  --quiet            Suppress non-essential output
    \\  --repo PATH        Repository path (equivalent to positional PATH)
    \\  --version          Print version and exit
    \\  --help             Print this help and exit
    \\
    \\Exit codes: 0 success, 1 general error, 2 invalid arguments,
    \\  3 repository not found, 4 unsupported Git format, 5 corrupt repository
    \\
;

fn commandFromName(s: []const u8) ?Command {
    inline for (@typeInfo(Command).@"enum".fields) |field| {
        if (std.mem.eql(u8, s, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

/// Parse human sizes: plain bytes, or a number followed by KB/MB/GB/TB or
/// KiB/MiB/GiB/TiB (case-insensitive). Units are base-2 (1 KB = 1024 bytes).
pub fn parseSize(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var end: usize = 0;
    while (end < s.len and (std.ascii.isDigit(s[end]) or s[end] == '.')) end += 1;
    if (end == 0) return null;
    const num = std.fmt.parseFloat(f64, s[0..end]) catch return null;
    const unit = std.mem.trim(u8, s[end..], " \t");
    const mult: f64 = if (unit.len == 0)
        1
    else if (std.ascii.eqlIgnoreCase(unit, "B"))
        1
    else if (std.ascii.eqlIgnoreCase(unit, "KB") or std.ascii.eqlIgnoreCase(unit, "K") or std.ascii.eqlIgnoreCase(unit, "KIB"))
        1024
    else if (std.ascii.eqlIgnoreCase(unit, "MB") or std.ascii.eqlIgnoreCase(unit, "M") or std.ascii.eqlIgnoreCase(unit, "MIB"))
        1024 * 1024
    else if (std.ascii.eqlIgnoreCase(unit, "GB") or std.ascii.eqlIgnoreCase(unit, "G") or std.ascii.eqlIgnoreCase(unit, "GIB"))
        1024 * 1024 * 1024
    else if (std.ascii.eqlIgnoreCase(unit, "TB") or std.ascii.eqlIgnoreCase(unit, "T") or std.ascii.eqlIgnoreCase(unit, "TIB"))
        1024 * 1024 * 1024 * 1024
    else
        return null;
    const bytes = num * mult;
    if (bytes < 0) return null;
    return @intFromFloat(bytes);
}

pub fn parse(argv: []const []const u8) ParseError!Options {
    var opts: Options = .{};
    var positional_seen: usize = 0;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (arg.len == 0) continue;

        if (arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--json")) {
                opts.json = true;
            } else if (std.mem.eql(u8, arg, "--no-color")) {
                opts.no_color = true;
            } else if (std.mem.eql(u8, arg, "--verbose")) {
                opts.verbose = true;
            } else if (std.mem.eql(u8, arg, "--quiet")) {
                opts.quiet = true;
            } else if (std.mem.eql(u8, arg, "--current")) {
                opts.current_only = true;
            } else if (std.mem.eql(u8, arg, "--historical")) {
                opts.historical_only = true;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                opts.help = true;
            } else if (std.mem.eql(u8, arg, "--version")) {
                opts.version = true;
            } else if (std.mem.eql(u8, arg, "--exit-code")) {
                opts.exit_code = true;
            } else if (std.mem.eql(u8, arg, "--base")) {
                i += 1;
                if (i >= argv.len) return error.InvalidArguments;
                opts.base_ref = argv[i];
            } else if (std.mem.eql(u8, arg, "--to")) {
                i += 1;
                if (i >= argv.len) return error.InvalidArguments;
                opts.to_ref = argv[i];
            } else if (std.mem.eql(u8, arg, "--limit")) {
                i += 1;
                if (i >= argv.len) return error.InvalidArguments;
                opts.limit = std.fmt.parseUnsigned(usize, argv[i], 10) catch return error.InvalidArguments;
            } else if (std.mem.eql(u8, arg, "--min-size")) {
                i += 1;
                if (i >= argv.len) return error.InvalidArguments;
                opts.min_size = parseSize(argv[i]) orelse return error.InvalidArguments;
            } else if (std.mem.eql(u8, arg, "--threads")) {
                i += 1;
                if (i >= argv.len) return error.InvalidArguments;
                opts.threads = std.fmt.parseUnsigned(usize, argv[i], 10) catch return error.InvalidArguments;
            } else if (std.mem.eql(u8, arg, "--repo")) {
                i += 1;
                if (i >= argv.len) return error.InvalidArguments;
                opts.repo_path = argv[i];
            } else {
                return error.InvalidArguments;
            }
            continue;
        }

        // Positional: command name first; the second positional is the
        // explain target for `explain`, otherwise the repository path.
        if (positional_seen == 0) {
            if (commandFromName(arg)) |cmd| {
                opts.command = cmd;
            } else {
                opts.repo_path = arg;
            }
        } else if (positional_seen == 1) {
            if (opts.command == .explain) {
                if (opts.explain_target != null) return error.InvalidArguments;
                opts.explain_target = arg;
            } else if (opts.command == .changed) {
                if (opts.changed_path != null) return error.InvalidArguments;
                opts.changed_path = arg;
            } else if (opts.repo_path == null and opts.command != .summary) {
                opts.repo_path = arg;
            } else {
                return error.InvalidArguments;
            }
        } else {
            return error.InvalidArguments;
        }
        positional_seen += 1;
    }

    if (opts.command == .explain and opts.explain_target == null) return error.InvalidArguments;
    if (opts.command == .changed and opts.changed_path == null) return error.InvalidArguments;
    if (opts.current_only and opts.historical_only) return error.InvalidArguments;
    return opts;
}

test "parse size" {
    try std.testing.expectEqual(@as(?u64, 0), parseSize("0"));
    try std.testing.expectEqual(@as(?u64, 10 * 1024 * 1024), parseSize("10MB"));
    try std.testing.expectEqual(@as(?u64, 10 * 1024 * 1024), parseSize("10mb"));
    try std.testing.expectEqual(@as(?u64, 10240), parseSize("10KB"));
    try std.testing.expectEqual(@as(?u64, 500 * 1024), parseSize("500KiB"));
    try std.testing.expectEqual(@as(?u64, 1024), parseSize("1K"));
    try std.testing.expectEqual(@as(?u64, 100), parseSize("100"));
    try std.testing.expectEqual(@as(?u64, @intFromFloat(1.5 * 1024 * 1024 * 1024)), parseSize("1.5GB"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("ten"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("10XB"));
}

test "parse args" {
    const a1 = try parse(&.{ "largest", "--limit", "50", "--min-size", "10MB" });
    try std.testing.expectEqual(@as(usize, 50), a1.limit);
    try std.testing.expectEqual(@as(u64, 10 * 1024 * 1024), a1.min_size);
    try std.testing.expectEqual(Command.largest, a1.command);
    try std.testing.expect(a1.repo_path == null);

    const a2 = try parse(&.{ "/path/to/repo" });
    try std.testing.expectEqual(Command.summary, a2.command);
    try std.testing.expectEqualStrings("/path/to/repo", a2.repo_path.?);

    const a3 = try parse(&.{ "packs", "/repo", "--json" });
    try std.testing.expectEqual(Command.packs, a3.command);
    try std.testing.expectEqualStrings("/repo", a3.repo_path.?);
    try std.testing.expect(a3.json);

    const a4 = try parse(&.{ "explain", "database/prod.sql" });
    try std.testing.expectEqual(Command.explain, a4.command);
    try std.testing.expectEqualStrings("database/prod.sql", a4.explain_target.?);
    try std.testing.expect(a4.repo_path == null);

    const a5 = try parse(&.{ "refs", "--limit", "5" });
    try std.testing.expectEqual(Command.refs, a5.command);
    try std.testing.expectEqual(@as(usize, 5), a5.limit);

    try std.testing.expectError(error.InvalidArguments, parse(&.{"explain"}));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "explain", "a", "b" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "unreachable", "a", "b" }));

    const a6 = try parse(&.{ "changed", "services/api", "--base", "origin/main", "--exit-code" });
    try std.testing.expectEqual(Command.changed, a6.command);
    try std.testing.expectEqualStrings("services/api", a6.changed_path.?);
    try std.testing.expectEqualStrings("origin/main", a6.base_ref.?);
    try std.testing.expect(a6.exit_code);
    try std.testing.expect(a6.to_ref == null);

    try std.testing.expectError(error.InvalidArguments, parse(&.{"changed"}));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "changed", "a", "b" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "changed", "--base" }));

    try std.testing.expectError(error.InvalidArguments, parse(&.{ "--nope" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "largest", "a", "b" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "--current", "--historical" }));
}
