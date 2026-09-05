const std = @import("std");
const summary_mod = @import("../analysis/summary.zig");
const largest_mod = @import("../analysis/largest.zig");
const objects_mod = @import("../analysis/objects.zig");
const packs_mod = @import("../analysis/packs.zig");
const reachability = @import("../analysis/reachability.zig");
const refs_analysis = @import("../analysis/refs.zig");
const explain_mod = @import("../analysis/explain.zig");
const changed_mod = @import("../analysis/changed.zig");
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
    try printSizeLine(w, "Unreachable objects", s.unreachable_bytes);

    for (s.contributors) |c| {
        if (c.path) |p| {
            try w.writeAll("\nLargest contributor:\n");
            try w.print("  {s}\n\n", .{p});
            try w.writeAll("Run:\n\n");
            try w.print("  git weight explain {s}\n", .{p});
            break;
        }
    }
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

fn printPadded(w: *std.Io.Writer, label: []const u8, value: []const u8, col: usize) WriteError!void {
    try w.print("  {s}", .{label});
    var pad: usize = if (label.len + 2 < col) col - label.len - 2 else 1;
    while (pad > 0) : (pad -= 1) try w.writeByte(' ');
    try w.print("{s}\n", .{value});
}

pub fn printUnreachable(w: *std.Io.Writer, stats: *const reachability.UnreachableStats) WriteError!void {
    var sbuf: [32]u8 = undefined;
    var cbuf: [24]u8 = undefined;
    try w.writeAll("Unreachable objects\n\n");
    const count_str = std.fmt.bufPrint(&cbuf, "{d}", .{stats.count}) catch unreachable;
    try printPadded(w, "Count", count_str, 19);
    try printPadded(w, "Logical size", formatSize(&sbuf, stats.logical_bytes), 19);
    try printPadded(w, "Physical size", formatSize(&sbuf, stats.physical_bytes), 19);
    try w.writeAll("\n");
    try w.print("Likely reclaimable after garbage collection: {s}\n", .{formatSize(&sbuf, stats.physical_bytes)});
}

pub fn printRefs(w: *std.Io.Writer, refs: []const refs_analysis.RefWeight) WriteError!void {
    try w.writeAll("REFERENCE                 UNIQUE WEIGHT\n");
    var hbuf: [64]u8 = undefined;
    for (refs) |r| {
        try w.print("{s}", .{r.name});
        var pad: usize = if (r.name.len < 26) 26 - r.name.len else 1;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        try w.print("{s}\n", .{formatSize(&hbuf, r.unique_bytes)});
    }
}

pub fn printExplain(w: *std.Io.Writer, report: *const explain_mod.Report) WriteError!void {
    var hbuf: [64]u8 = undefined;
    var sbuf: [32]u8 = undefined;
    var dbuf: [16]u8 = undefined;

    // Header: representative path when known, otherwise the full oid.
    if (report.path) |p| {
        try w.print("{s}\n\n", .{p});
    } else {
        try w.print("{s}\n\n", .{report.id.hex(&hbuf)});
    }

    // Object block, headed by the capitalized type name.
    const tname = report.object_type.name();
    var tbuf: [16]u8 = undefined;
    if (tname.len > 0 and tname.len <= tbuf.len) {
        tbuf[0] = std.ascii.toUpper(tname[0]);
        @memcpy(tbuf[1..tname.len], tname[1..]);
    }
    try w.print("{s}\n", .{tbuf[0..tname.len]});
    try printPadded(w, "Object", report.id.hex(&hbuf), 15);
    try printPadded(w, "Logical size", formatSize(&sbuf, report.logical_bytes), 15);
    try printPadded(w, "Packed size", formatSize(&sbuf, report.physical_bytes), 15);

    if (report.introduced) |intro| {
        try w.writeAll("\nHistory\n");
        try printPadded(w, "Introduced", explain_mod.formatDate(&dbuf, intro.timestamp), 15);
        try printPadded(w, "Commit", intro.id.abbrev(&hbuf, 7), 15);
        if (intro.author) |a| try printPadded(w, "Author", a, 15);
    }
    if (report.deleted) |del| {
        try w.writeAll("\n");
        try printPadded(w, "Deleted", explain_mod.formatDate(&dbuf, del.timestamp), 15);
        try printPadded(w, "Commit", del.id.abbrev(&hbuf, 7), 15);
    }

    try w.writeAll("\nReferences retaining this object\n\n");
    for (report.retained_by) |name| {
        try w.print("  {s}\n", .{name});
    }

    try w.writeAll("\nReachability\n\n");
    try printPadded(w, "Reachable", if (report.reachable) "yes" else "no", 15);
    try printPadded(w, "From HEAD", if (report.reachable_from_head) "yes" else "no", 15);

    try w.writeAll("\nEstimated reclaimable storage\n\n");
    if (!report.reachable) {
        try w.print("  {s} via standard git garbage collection\n", .{formatSize(&sbuf, report.reclaimable_bytes)});
    } else if (!report.reachable_from_head) {
        try w.print("  {s} if all retaining refs and history are rewritten\n", .{formatSize(&sbuf, report.reclaimable_bytes)});
    } else {
        try w.writeAll("  none — this object is part of the current tree\n");
    }
}

pub fn printChanged(w: *std.Io.Writer, report: *const changed_mod.ChangedReport) WriteError!void {
    var hbuf: [64]u8 = undefined;

    const path = if (report.path.len == 0) "." else report.path;
    try w.print("{s}\n\n", .{path});

    try w.print("Base       {s} ({s})\n", .{ report.base_ref, report.base_commit.abbrev(&hbuf, 7) });
    try w.print("To         {s} ({s})\n\n", .{ report.to_ref, report.to_commit.abbrev(&hbuf, 7) });

    // Label from whichever side has the entry (both absent is an error
    // handled before output).
    const is_tree = if (report.to_entry) |e|
        e.is_tree
    else if (report.base_entry) |e|
        e.is_tree
    else
        true;
    const label: []const u8 = if (is_tree) "Tree" else "Blob";
    try printChangedSide(w, label, "base", report.base_entry);
    try printChangedSide(w, label, "to", report.to_entry);
    try w.writeAll("\n");

    try w.print("Changed: {s}\n", .{if (report.changed) "yes" else "no"});
}

fn printChangedSide(w: *std.Io.Writer, label: []const u8, side: []const u8, entry: ?changed_mod.Entry) WriteError!void {
    var lbuf: [32]u8 = undefined;
    var hbuf: [64]u8 = undefined;
    const full = std.fmt.bufPrint(&lbuf, "{s} ({s})", .{ label, side }) catch unreachable;
    try w.print("{s}", .{full});
    var pad: usize = if (full.len < 14) 14 - full.len else 1;
    while (pad > 0) : (pad -= 1) try w.writeByte(' ');
    if (entry) |e| {
        try w.print("{s}...\n", .{e.id.abbrev(&hbuf, 8)});
    } else {
        try w.writeAll("absent\n");
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
