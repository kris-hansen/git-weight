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
            tree = object_id.ObjectId.parseHex(line[5..], algorithm) catch return error.InvalidCommit;
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            const p = object_id.ObjectId.parseHex(line[7..], algorithm) catch return error.InvalidCommit;
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

test "parse sha256 commit" {
    const tree_hex = "a29495cd7ca6ee34e358698f44f6e334b497c284a192e8e8fba4c09700b6f254";
    const parent_hex = "19e3844a76c1e617ee4d23cbfbee2fc69f0a0373920e0b7db32b9ea47ce8f9a9";
    const payload = "tree " ++ tree_hex ++ "\n" ++
        "parent " ++ parent_hex ++ "\n" ++
        "author Alice Example <alice@example.com> 1552272000 +0000\n" ++
        "committer Bob <bob@example.com> 1552272001 +0000\n" ++
        "\n" ++
        "hello sha256\n";
    const c = try parse(payload, .sha256, std.testing.allocator);
    defer std.testing.allocator.free(c.parents);
    try std.testing.expectEqual(object_id.HashAlgorithm.sha256, c.tree.algorithm);
    try std.testing.expectEqual(object_id.HashAlgorithm.sha256, c.parents[0].algorithm);
    try std.testing.expectEqual(@as(usize, 1), c.parents.len);
    try std.testing.expectEqualStrings("hello sha256\n", c.message());
    var hexbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(tree_hex, c.tree.hex(&hexbuf));
    try std.testing.expectEqualStrings(parent_hex, c.parents[0].hex(&hexbuf));

    // The SHA-1 width must reject the same payload.
    const wrong = parse(payload, .sha1, std.testing.allocator);
    try std.testing.expectError(error.InvalidCommit, wrong);
}
