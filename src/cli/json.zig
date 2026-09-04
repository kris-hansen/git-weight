const std = @import("std");
const summary_mod = @import("../analysis/summary.zig");
const largest_mod = @import("../analysis/largest.zig");
const objects_mod = @import("../analysis/objects.zig");
const packs_mod = @import("../analysis/packs.zig");

pub const WriteError = std.Io.Writer.Error;

/// Minimal JSON writer over std.Io.Writer with indentation.
pub const JsonWriter = struct {
    w: *std.Io.Writer,
    depth: usize = 0,
    first: [16]bool = [_]bool{true} ** 16,

    pub fn beginObject(self: *JsonWriter) WriteError!void {
        try self.w.writeByte('{');
        self.depth += 1;
        self.first[self.depth] = true;
    }

    pub fn endObject(self: *JsonWriter) WriteError!void {
        self.depth -= 1;
        if (!self.first[self.depth + 1]) try self.newline();
        try self.indent();
        try self.w.writeByte('}');
    }

    pub fn beginArray(self: *JsonWriter) WriteError!void {
        try self.w.writeByte('[');
        self.depth += 1;
        self.first[self.depth] = true;
    }

    pub fn endArray(self: *JsonWriter) WriteError!void {
        self.depth -= 1;
        if (!self.first[self.depth + 1]) try self.newline();
        try self.indent();
        try self.w.writeByte(']');
    }

    fn newline(self: *JsonWriter) WriteError!void {
        try self.w.writeByte('\n');
    }

    fn indent(self: *JsonWriter) WriteError!void {
        var i: usize = 0;
        while (i < self.depth) : (i += 1) try self.w.writeAll("  ");
    }

    fn beforeField(self: *JsonWriter) WriteError!void {
        if (!self.first[self.depth]) {
            try self.w.writeByte(',');
        }
        try self.newline();
        try self.indent();
        self.first[self.depth] = false;
    }

    pub fn field(self: *JsonWriter, name: []const u8) WriteError!void {
        try self.beforeField();
        try self.writeString(name);
        try self.w.writeAll(": ");
    }

    pub fn writeString(self: *JsonWriter, s: []const u8) WriteError!void {
        try self.w.writeByte('"');
        for (s) |c| {
            switch (c) {
                '"' => try self.w.writeAll("\\\""),
                '\\' => try self.w.writeAll("\\\\"),
                '\n' => try self.w.writeAll("\\n"),
                '\r' => try self.w.writeAll("\\r"),
                '\t' => try self.w.writeAll("\\t"),
                else => {
                    if (c < 0x20) {
                        try self.w.print("\\u{x:0>4}", .{c});
                    } else {
                        try self.w.writeByte(c);
                    }
                },
            }
        }
        try self.w.writeByte('"');
    }

    pub fn writeU64(self: *JsonWriter, v: u64) WriteError!void {
        try self.w.print("{d}", .{v});
    }

    pub fn writeOptPath(self: *JsonWriter, p: ?[]const u8) WriteError!void {
        if (p) |v| try self.writeString(v) else try self.w.writeAll("null");
    }
};

fn writeTypeStats(jw: *JsonWriter, s: objects_mod.TypeStats) WriteError!void {
    try jw.beginObject();
    try jw.field("count");
    try jw.writeU64(s.count);
    try jw.field("logical_bytes");
    try jw.writeU64(s.logical_bytes);
    try jw.endObject();
}

pub fn printSummary(jw: *JsonWriter, s: *const summary_mod.Summary) WriteError!void {
    try jw.beginObject();

    try jw.field("repository");
    try jw.beginObject();
    try jw.field("path");
    try jw.writeOptPath(s.worktree_path);
    try jw.field("git_dir");
    try jw.writeString(s.git_dir_path);
    try jw.endObject();

    try jw.field("weight");
    try jw.beginObject();
    try jw.field("git_bytes");
    try jw.writeU64(s.git_bytes);
    try jw.field("object_bytes");
    try jw.writeU64(s.object_bytes);
    try jw.field("working_tree_bytes");
    try jw.writeU64(s.working_tree_bytes);
    try jw.endObject();

    try jw.field("objects");
    try jw.beginObject();
    inline for (.{
        .{ "blob", s.stats.blob },
        .{ "tree", s.stats.tree },
        .{ "commit", s.stats.commit },
        .{ "tag", s.stats.tag },
    }) |row| {
        try jw.field(row[0]);
        try writeTypeStats(jw, row[1]);
    }
    try jw.endObject();

    try jw.field("storage");
    try jw.beginObject();
    try jw.field("pack_bytes");
    try jw.writeU64(s.pack_bytes);
    try jw.field("loose_bytes");
    try jw.writeU64(s.loose_bytes);
    try jw.endObject();

    try jw.field("largest_contributors");
    try jw.beginArray();
    for (s.contributors) |c| {
        try jw.beforeField();
        try writeBlobEntry(jw, &c);
    }
    try jw.endArray();

    try jw.field("historical_bytes");
    try jw.writeU64(s.historical_bytes);

    try jw.endObject();
    try jw.w.writeByte('\n');
}

fn writeBlobEntry(jw: *JsonWriter, c: *const largest_mod.BlobEntry) WriteError!void {
    try jw.beginObject();
    var hbuf: [64]u8 = undefined;
    try jw.field("oid");
    try jw.writeString(c.id.hex(&hbuf));
    try jw.field("logical_bytes");
    try jw.writeU64(c.size);
    try jw.field("path");
    try jw.writeOptPath(c.path);
    try jw.field("status");
    try jw.writeString(c.status.name());
    try jw.endObject();
}

pub fn printLargest(jw: *JsonWriter, entries: []const largest_mod.BlobEntry) WriteError!void {
    try jw.beginObject();
    try jw.field("blobs");
    try jw.beginArray();
    for (entries) |*e| {
        try jw.beforeField();
        try writeBlobEntry(jw, e);
    }
    try jw.endArray();
    try jw.endObject();
    try jw.w.writeByte('\n');
}

pub fn printObjects(jw: *JsonWriter, stats: *const objects_mod.ObjectStats) WriteError!void {
    try jw.beginObject();
    try jw.field("objects");
    try jw.beginObject();
    inline for (.{
        .{ "blob", stats.blob },
        .{ "tree", stats.tree },
        .{ "commit", stats.commit },
        .{ "tag", stats.tag },
    }) |row| {
        try jw.field(row[0]);
        try writeTypeStats(jw, row[1]);
    }
    try jw.endObject();
    try jw.endObject();
    try jw.w.writeByte('\n');
}

pub fn printPacks(jw: *JsonWriter, packs: []const packs_mod.PackInfo) WriteError!void {
    try jw.beginObject();
    try jw.field("packs");
    try jw.beginArray();
    for (packs) |p| {
        try jw.beforeField();
        try jw.beginObject();
        try jw.field("name");
        try jw.writeString(p.name);
        try jw.field("objects");
        try jw.writeU64(p.object_count);
        try jw.field("pack_bytes");
        try jw.writeU64(p.pack_bytes);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try jw.w.writeByte('\n');
}
