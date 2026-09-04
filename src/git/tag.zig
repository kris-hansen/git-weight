const std = @import("std");
const object_id = @import("object_id.zig");
const git_object = @import("object.zig");

pub const TagError = error{InvalidTag};

pub const Tag = struct {
    object: object_id.ObjectId,
    object_type: git_object.ObjectType,
    name: []const u8,
    tagger: []const u8,
};

/// Parse an annotated tag payload (zero-copy views into `data`).
pub fn parse(data: []const u8, algorithm: object_id.HashAlgorithm) TagError!Tag {
    _ = algorithm; // oid width currently fixed at SHA-1; kept for SHA-256
    var obj: ?object_id.ObjectId = null;
    var obj_type: ?git_object.ObjectType = null;
    var name: []const u8 = "";
    var tagger: []const u8 = "";

    var pos: usize = 0;
    while (pos < data.len) {
        const line_end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
        const line = data[pos..line_end];
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "object ")) {
            obj = object_id.ObjectId.fromHex(line[7..]) catch return error.InvalidTag;
        } else if (std.mem.startsWith(u8, line, "type ")) {
            obj_type = git_object.ObjectType.fromName(line[5..]);
        } else if (std.mem.startsWith(u8, line, "tag ")) {
            name = line[4..];
        } else if (std.mem.startsWith(u8, line, "tagger ")) {
            tagger = line[7..];
        }
        if (line_end == data.len) break;
        pos = line_end + 1;
    }

    return .{
        .object = obj orelse return error.InvalidTag,
        .object_type = obj_type orelse return error.InvalidTag,
        .name = name,
        .tagger = tagger,
    };
}

test "parse tag" {
    const payload = "object 81f43dc8215a9b66a3bb71b11ffde1a3542e1e0d\ntype commit\ntag v1.0\ntagger Alice <a@b.c> 1552272000 +0000\n\nmessage\n";
    const t = try parse(payload, .sha1);
    try std.testing.expectEqualStrings("v1.0", t.name);
    try std.testing.expectEqual(git_object.ObjectType.commit, t.object_type);
    try std.testing.expectEqualStrings("Alice <a@b.c> 1552272000 +0000", t.tagger);
}
