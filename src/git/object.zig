const std = @import("std");

pub const ObjectType = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,

    pub fn name(self: ObjectType) []const u8 {
        return switch (self) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
            .ofs_delta => "ofs-delta",
            .ref_delta => "ref-delta",
        };
    }

    pub fn fromName(s: []const u8) ?ObjectType {
        inline for (@typeInfo(ObjectType).@"enum".fields) |field| {
            if (std.mem.eql(u8, s, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    /// Types that exist as real Git objects (not delta placeholders).
    pub fn isReal(self: ObjectType) bool {
        return switch (self) {
            .commit, .tree, .blob, .tag => true,
            .ofs_delta, .ref_delta => false,
        };
    }
};

pub const Header = struct {
    object_type: ObjectType,
    size: u64,
};

/// Parse the uncompressed Git object header at the start of an object payload:
/// `<type> <size>\x00`. Returns the header and the payload start index, or
/// null if the buffer does not contain a complete header.
pub fn parseHeader(data: []const u8) !struct { header: Header, payload_start: usize } {
    const nul = std.mem.indexOfScalar(u8, data, 0) orelse return error.InvalidObjectHeader;
    const sp = std.mem.indexOfScalar(u8, data[0..nul], ' ') orelse return error.InvalidObjectHeader;
    const type_name = data[0..sp];
    const size_str = data[sp + 1 .. nul];
    const object_type = ObjectType.fromName(type_name) orelse return error.InvalidObjectHeader;
    const size = std.fmt.parseUnsigned(u64, size_str, 10) catch return error.InvalidObjectHeader;
    return .{ .header = .{ .object_type = object_type, .size = size }, .payload_start = nul + 1 };
}

test "parse header" {
    const r = try parseHeader("blob 1234\x00hello");
    try std.testing.expectEqual(ObjectType.blob, r.header.object_type);
    try std.testing.expectEqual(@as(u64, 1234), r.header.size);
    try std.testing.expectEqual(@as(usize, 10), r.payload_start);
    try std.testing.expectEqualStrings("hello", "blob 1234\x00hello"[r.payload_start..]);

    try std.testing.expectError(error.InvalidObjectHeader, parseHeader("blob 12"));
    try std.testing.expectError(error.InvalidObjectHeader, parseHeader("weird 12\x00"));
}
