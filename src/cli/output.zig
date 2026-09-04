const std = @import("std");
const summary_mod = @import("../analysis/summary.zig");
const largest_mod = @import("../analysis/largest.zig");
const objects_mod = @import("../analysis/objects.zig");
const packs_mod = @import("../analysis/packs.zig");
const object_id = @import("../git/object_id.zig");

pub const WriteError = std.Io.Writer.Error;

/// Format `bytes` using base-2 units with up to 3 significant figures
/// ("312 KB", "92.1 MB", "2.74 GB"). `buf` must be at least 32 bytes.
pub fn formatSize(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024 and unit + 1 < units.len) {
        value /= 1024;
        unit += 1;
    }
    if (unit == 0) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch unreachable;
    }
    const decimals: usize = if (value >= 100) 0 else if (value >= 10) 1 else 2;
    return switch (decimals) {
        0 => std.fmt.bufPrint(buf, "{d:.0} {s}", .{ value, units[unit] }) catch unreachable,
        1 => std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch unreachable,
        else => std.fmt.bufPrint(buf, "{d:.2} {s}", .{ value, units[unit] }) catch unreachable,
    };
}

fn printSizeLine(w: *std.Io.Writer, label: []const u8, bytes: u64) WriteError!void {
    var sbuf: [32]u8 = undefined;
    try w.print("  {s}", .{label});
    var pad: usize = if (label.len + 2 < 30) 30 - label.len - 2 else 1;
    while (pad > 0) : (pad -= 1) try w.writeByte(' ');
    try w.print("{s}\n", .{formatSize(&sbuf, bytes)});
}

pub fn printSummary(w: *std.Io.Writer, s: *const summary_mod.Summary) WriteError!void {
    try w.print("Repository: {s}\n\n", .{s.name});

    try w.writeAll("Repository weight\n");
    try printSizeLine(w, "Total .git size", s.git_bytes);
    try printSizeLine(w, "Object database", s.object_bytes);
    if (s.worktree_path != null) {
        try printSizeLine(w, "Working tree", s.working_tree_bytes);
    }
    try w.writeAll("\n");

    try w.writeAll("Objects\n");
    try printSizeLine(w, "Blobs", s.stats.blob.logical_bytes);
    try printSizeLine(w, "Trees", s.stats.tree.logical_bytes);
    try printSizeLine(w, "Commits", s.stats.commit.logical_bytes);
    try printSizeLine(w, "Tags", s.stats.tag.logical_bytes);
    try w.writeAll("\n");

    try w.writeAll("Storage\n");
    try printSizeLine(w, "Packfiles", s.pack_bytes);
    try printSizeLine(w, "Loose objects", s.loose_bytes);
    try w.writeAll("\n");

    try w.writeAll("Largest contributors\n\n");
    try w.writeAll("  SIZE       PATH                         STATUS\n");
    var hbuf: [64]u8 = undefined;
    for (s.contributors) |c| {
        const size_str = formatSize(&hbuf, c.size);
        const path = c.path orelse "(unknown)";
        try w.print("  {s}", .{size_str});
        var pad: usize = if (size_str.len < 11) 11 - size_str.len else 1;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        try w.print("{s}", .{path});
        pad = if (path.len < 29) 29 - path.len else 1;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        try w.print("{s}\n", .{c.status.name()});
    }
    try w.writeAll("\n");

    try w.writeAll("Potential cleanup\n");
    try printSizeLine(w, "Historical deleted files", s.historical_bytes);
}

pub fn printLargest(w: *std.Io.Writer, entries: []const largest_mod.BlobEntry) WriteError!void {
    try w.writeAll("SIZE       OBJECT        PATH\n");
    var hbuf: [64]u8 = undefined;
    var obuf: [64]u8 = undefined;
    for (entries) |e| {
        const size_str = formatSize(&hbuf, e.size);
        const oid_str = e.id.abbrev(&obuf, 7);
        try w.print("{s}", .{size_str});
        var pad: usize = if (size_str.len < 11) 11 - size_str.len else 1;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        try w.print("{s}", .{oid_str});
        pad = if (oid_str.len < 14) 14 - oid_str.len else 1;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        try w.print("{s}", .{e.path orelse "(unknown)"});
        try w.writeAll("\n");
    }
}

pub fn printObjects(w: *std.Io.Writer, stats: *const objects_mod.ObjectStats) WriteError!void {
    try w.writeAll("TYPE       COUNT        LOGICAL SIZE\n");
    var hbuf: [64]u8 = undefined;
    const rows = .{
        .{ "blob", stats.blob },
        .{ "tree", stats.tree },
        .{ "commit", stats.commit },
        .{ "tag", stats.tag },
    };
    inline for (rows) |row| {
        try w.print("{s}", .{row[0]});
        var pad: usize = 11 - row[0].len;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        const count_str = std.fmt.bufPrint(&hbuf, "{d}", .{row[1].count}) catch unreachable;
        try w.print("{s}", .{count_str});
        pad = if (count_str.len < 13) 13 - count_str.len else 1;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        try w.print("{s}\n", .{formatSize(&hbuf, row[1].logical_bytes)});
    }
}

pub fn printPacks(w: *std.Io.Writer, packs: []const packs_mod.PackInfo) WriteError!void {
    try w.writeAll("PACK                          OBJECTS     PHYSICAL SIZE\n");
    var hbuf: [64]u8 = undefined;
    for (packs) |p| {
        try w.print("{s}", .{p.name});
        var pad: usize = if (p.name.len < 30) 30 - p.name.len else 1;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        const count_str = std.fmt.bufPrint(&hbuf, "{d}", .{p.object_count}) catch unreachable;
        try w.print("{s}", .{count_str});
        pad = if (count_str.len < 12) 12 - count_str.len else 1;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        try w.print("{s}\n", .{formatSize(&hbuf, p.pack_bytes)});
    }
}

test "format size" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", formatSize(&buf, 512));
    try std.testing.expectEqualStrings("312 KB", formatSize(&buf, 312 * 1024));
    try std.testing.expectEqualStrings("5.00 MB", formatSize(&buf, 5 * 1024 * 1024));
    try std.testing.expectEqualStrings("92.1 MB", formatSize(&buf, 96_563_149));
    try std.testing.expectEqualStrings("18.7 MB", formatSize(&buf, 19_607_168));
    try std.testing.expectEqualStrings("2.74 GB", formatSize(&buf, 2_942_054_932));
    try std.testing.expectEqualStrings("731 MB", formatSize(&buf, 731 * 1024 * 1024));
    try std.testing.expectEqualStrings("48.3 MB", formatSize(&buf, 50_644_992));
    try std.testing.expectEqualStrings("1.10 GB", formatSize(&buf, 1_181_116_314));
}
