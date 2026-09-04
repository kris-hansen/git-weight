const std = @import("std");
const object_id = @import("object_id.zig");

pub const TreeError = error{InvalidTree};

pub const EntryMode = enum {
    tree,
    blob,
    submodule,
    other,

    pub fn fromRaw(raw: u32) EntryMode {
        return switch (raw & 0o170000) {
            0o040000 => .tree,
            0o100000 => .blob,
            0o160000 => .submodule,
            else => .other,
        };
    }

    pub fn isFile(self: EntryMode) bool {
        return self == .blob or self == .other;
    }
};

pub const TreeEntry = struct {
    mode: u32,
    name: []const u8,
    id: object_id.ObjectId,

    pub fn entryMode(self: *const TreeEntry) EntryMode {
        return EntryMode.fromRaw(self.mode);
    }
};

/// Iterate tree entries zero-copy over the raw payload.
pub const TreeIterator = struct {
    data: []const u8,
    oid_len: usize,
    pos: usize = 0,

    pub fn init(data: []const u8, algorithm: object_id.HashAlgorithm) TreeIterator {
        return .{ .data = data, .oid_len = algorithm.rawLen() };
    }

    pub fn next(self: *TreeIterator) TreeError!?TreeEntry {
        if (self.pos >= self.data.len) return null;
        const sp = std.mem.indexOfScalarPos(u8, self.data, self.pos, ' ') orelse return error.InvalidTree;
        const mode = std.fmt.parseInt(u32, self.data[self.pos..sp], 8) catch return error.InvalidTree;
        const nul = std.mem.indexOfScalarPos(u8, self.data, sp + 1, 0) orelse return error.InvalidTree;
        const name = self.data[sp + 1 .. nul];
        const oid_start = nul + 1;
        if (oid_start + self.oid_len > self.data.len) return error.InvalidTree;
        var id: object_id.ObjectId = .{ .algorithm = if (self.oid_len == 20) .sha1 else .sha256 };
        @memcpy(id.bytes[0..self.oid_len], self.data[oid_start .. oid_start + self.oid_len]);
        self.pos = oid_start + self.oid_len;
        return .{ .mode = mode, .name = name, .id = id };
    }
};

test "iterate tree entries" {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..13], "100644 a.txt\x00");
    @memset(buf[13..33], 1);
    @memcpy(buf[33..43], "40000 dir\x00");
    @memset(buf[43..63], 2);
    const payload: []const u8 = buf[0..63];

    var it = TreeIterator.init(payload, .sha1);
    const e1 = (try it.next()).?;
    try std.testing.expectEqual(@as(u32, 0o100644), e1.mode);
    try std.testing.expectEqualStrings("a.txt", e1.name);
    try std.testing.expectEqual(@as(u8, 1), e1.id.bytes[0]);

    const e2 = (try it.next()).?;
    try std.testing.expectEqual(@as(u32, 0o040000), e2.mode);
    try std.testing.expectEqualStrings("dir", e2.name);
    try std.testing.expectEqual(@as(u8, 2), e2.id.bytes[0]);

    try std.testing.expectEqual(@as(?TreeEntry, null), try it.next());
}
