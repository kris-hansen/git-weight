const std = @import("std");
const object_id = @import("object_id.zig");

pub const CommitError = error{InvalidCommit};

pub const Signature = struct {
    /// "Name <email>" part.
    ident: []const u8,
    /// Seconds since epoch.
    timestamp: i64,
};

/// Zero-copy view over a commit object payload.
pub const Commit = struct {
    data: []const u8,
    tree: object_id.ObjectId,
    parents: []const object_id.ObjectId,
    author: ?Signature,
    committer: ?Signature,
    /// Offset of the commit message within `data`.
    message_start: usize,

    pub fn message(self: *const Commit) []const u8 {
        return self.data[self.message_start..];
    }
};

fn parseSignature(line: []const u8) ?Signature {
    // "Name <email> 1234567890 +0000"
    const gt = std.mem.lastIndexOfScalar(u8, line, '>') orelse return null;
    var rest = std.mem.trim(u8, line[gt + 1 ..], " ");
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const ts = std.fmt.parseInt(i64, rest[0..sp], 10) catch return null;
    return .{ .ident = line[0 .. gt + 1], .timestamp = ts };
}

/// Parse a commit payload. `algorithm` selects the oid width for tree/parent
/// hashes. Parent oids are copied into storage owned by the caller's
/// allocator (`alloc`); free with `alloc.free(c.parents)`. All other fields
/// are zero-copy views into `data`.
pub fn parse(
    data: []const u8,
    algorithm: object_id.HashAlgorithm,
    alloc: std.mem.Allocator,
) (CommitError || std.mem.Allocator.Error)!Commit {
    _ = algorithm; // oid width currently fixed at SHA-1; kept for SHA-256
    var tree: ?object_id.ObjectId = null;
    var author: ?Signature = null;
    var committer: ?Signature = null;
    var parents: std.ArrayList(object_id.ObjectId) = .empty;
    defer parents.deinit(alloc);

    var pos: usize = 0;
    while (pos < data.len) {
        const line_end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
        const line = data[pos..line_end];
        if (line.len == 0) {
            // Blank line: message begins after it.
            return .{
                .data = data,
                .tree = tree orelse return error.InvalidCommit,
                .parents = try parents.toOwnedSlice(alloc),
                .author = author,
                .committer = committer,
                .message_start = if (line_end < data.len) line_end + 1 else data.len,
            };
        }
        if (std.mem.startsWith(u8, line, "tree ")) {
            tree = object_id.ObjectId.fromHex(line[5..]) catch return error.InvalidCommit;
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            const p = object_id.ObjectId.fromHex(line[7..]) catch return error.InvalidCommit;
            try parents.append(alloc, p);
        } else if (std.mem.startsWith(u8, line, "author ")) {
            author = parseSignature(line[7..]);
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            committer = parseSignature(line[10..]);
        }
        if (line_end == data.len) break;
        pos = line_end + 1;
    }
    return error.InvalidCommit;
}

test "parse commit" {
    const payload =
        \\tree 81f43dc8215a9b66a3bb71b11ffde1a3542e1e0d
        \\parent 9ac810e5b4abe7ab5c977f0d0e20b7d46d383a4c
        \\author Alice Example <alice@example.com> 1552272000 +0000
        \\committer Bob <bob@example.com> 1552272001 +0000
        \\
        \\hello
    ;
    var buf: [256]u8 = undefined;
    _ = &buf;
    const c = try parse(payload, .sha1, std.testing.allocator);
    defer std.testing.allocator.free(c.parents);
    try std.testing.expectEqualStrings("hello", c.message());
    try std.testing.expectEqual(@as(usize, 1), c.parents.len);
    try std.testing.expectEqual(@as(i64, 1552272000), c.author.?.timestamp);
    var hexbuf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("81f43dc8215a9b66a3bb71b11ffde1a3542e1e0d", c.tree.hex(&hexbuf));
}
