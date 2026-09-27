const std = @import("std");

pub const HashAlgorithm = enum {
    sha1,
    sha256,

    pub fn rawLen(self: HashAlgorithm) usize {
        return switch (self) {
            .sha1 => 20,
            .sha256 => 32,
        };
    }

    /// Length of the lowercase hex representation.
    pub fn hexLen(self: HashAlgorithm) usize {
        return self.rawLen() * 2;
    }
};

pub const max_raw_len = 32;

/// A Git object identifier. The byte payload lives inline so object IDs never
/// require heap allocation; `len` distinguishes SHA-1 (20) from SHA-256 (32).
pub const ObjectId = struct {
    algorithm: HashAlgorithm,
    bytes: [max_raw_len]u8 = [_]u8{0} ** max_raw_len,

    pub const zero_sha1: ObjectId = .{ .algorithm = .sha1 };

    pub fn rawLen(self: *const ObjectId) usize {
        return self.algorithm.rawLen();
    }

    pub fn eql(a: *const ObjectId, b: *const ObjectId) bool {
        if (a.algorithm != b.algorithm) return false;
        return std.mem.eql(u8, a.bytes[0..a.rawLen()], b.bytes[0..b.rawLen()]);
    }

    pub fn order(a: *const ObjectId, b: *const ObjectId) std.math.Order {
        return std.mem.order(u8, a.bytes[0..a.rawLen()], b.bytes[0..b.rawLen()]);
    }

    pub fn hash(self: *const ObjectId) u64 {
        return std.hash.Wyhash.hash(0, self.bytes[0..self.rawLen()]);
    }

    /// Lowercase hex representation. `buf` must be at least `hexLen` bytes.
    pub fn hex(self: *const ObjectId, buf: []u8) []const u8 {
        const n = self.rawLen();
        std.debug.assert(buf.len >= n * 2);
        const chars = "0123456789abcdef";
        for (self.bytes[0..n], 0..) |b, i| {
            buf[i * 2] = chars[b >> 4];
            buf[i * 2 + 1] = chars[b & 0xf];
        }
        return buf[0 .. n * 2];
    }

    pub fn hexLen(self: *const ObjectId) usize {
        return self.rawLen() * 2;
    }

    /// Abbreviated hex (first `n` chars), clamped to the full length.
    pub fn abbrev(self: *const ObjectId, buf: []u8, n: usize) []const u8 {
        const full = self.hex(buf);
        return full[0..@min(n, full.len)];
    }

    pub fn fromHex(hex_str: []const u8) !ObjectId {
        if (hex_str.len != 40 and hex_str.len != 64) return error.InvalidObjectId;
        var id: ObjectId = .{ .algorithm = if (hex_str.len == 40) .sha1 else .sha256 };
        const n = hex_str.len / 2;
        for (0..n) |i| {
            const hi = std.fmt.charToDigit(hex_str[i * 2], 16) catch return error.InvalidObjectId;
            const lo = std.fmt.charToDigit(hex_str[i * 2 + 1], 16) catch return error.InvalidObjectId;
            id.bytes[i] = (@as(u8, hi) << 4) | lo;
        }
        return id;
    }

    /// Parse a full hex object id whose width is dictated by `algorithm`
    /// (payload context), not inferred from the string length as in
    /// `fromHex`. Rejects ids of any other width.
    pub fn parseHex(hex_str: []const u8, algorithm: HashAlgorithm) !ObjectId {
        if (hex_str.len != algorithm.hexLen()) return error.InvalidObjectId;
        var id: ObjectId = .{ .algorithm = algorithm };
        for (0..algorithm.rawLen()) |i| {
            const hi = std.fmt.charToDigit(hex_str[i * 2], 16) catch return error.InvalidObjectId;
            const lo = std.fmt.charToDigit(hex_str[i * 2 + 1], 16) catch return error.InvalidObjectId;
            id.bytes[i] = (@as(u8, hi) << 4) | lo;
        }
        return id;
    }

    /// Context for std.HashMap / HashMapUnmanaged keyed by ObjectId.
    pub const Context = struct {
        pub fn hash(_: Context, key: ObjectId) u64 {
            return key.hash();
        }
        pub fn eql(_: Context, a: ObjectId, b: ObjectId) bool {
            return a.eql(&b);
        }
    };
};

test "object id round trip" {
    const id = try ObjectId.fromHex("81f43dc8215a9b66a3bb71b11ffde1a3542e1e0d");
    try std.testing.expectEqual(HashAlgorithm.sha1, id.algorithm);
    try std.testing.expectEqual(@as(usize, 20), id.rawLen());

    var buf: [64]u8 = undefined;
    const h = id.hex(&buf);
    try std.testing.expectEqualStrings("81f43dc8215a9b66a3bb71b11ffde1a3542e1e0d", h);
    try std.testing.expectEqualStrings("81f43dc8", id.abbrev(&buf, 8));

    const id2 = try ObjectId.fromHex(h);
    try std.testing.expect(id.eql(&id2));

    const bad = ObjectId.fromHex("xyz");
    try std.testing.expectError(error.InvalidObjectId, bad);
}

test "sha256 object id" {
    const id = try ObjectId.fromHex("a" ** 64);
    try std.testing.expectEqual(HashAlgorithm.sha256, id.algorithm);
    try std.testing.expectEqual(@as(usize, 32), id.rawLen());
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a" ** 64, id.hex(&buf));
}

test "parseHex round trip enforces algorithm width" {
    const sha1_hex = "81f43dc8215a9b66a3bb71b11ffde1a3542e1e0d";
    const sha256_hex = "a29495cd7ca6ee34e358698f44f6e334b497c284a192e8e8fba4c09700b6f254";

    var buf: [64]u8 = undefined;

    const a = try ObjectId.parseHex(sha1_hex, .sha1);
    try std.testing.expectEqual(HashAlgorithm.sha1, a.algorithm);
    try std.testing.expectEqualStrings(sha1_hex, a.hex(&buf));
    const a_rt = try ObjectId.parseHex(a.hex(&buf), .sha1);
    try std.testing.expect(a.eql(&a_rt));

    const b = try ObjectId.parseHex(sha256_hex, .sha256);
    try std.testing.expectEqual(HashAlgorithm.sha256, b.algorithm);
    try std.testing.expectEqualStrings(sha256_hex, b.hex(&buf));
    const b_rt = try ObjectId.parseHex(b.hex(&buf), .sha256);
    try std.testing.expect(b.eql(&b_rt));

    // Cross-width and malformed input are rejected.
    try std.testing.expectError(error.InvalidObjectId, ObjectId.parseHex(sha256_hex, .sha1));
    try std.testing.expectError(error.InvalidObjectId, ObjectId.parseHex(sha1_hex, .sha256));
    try std.testing.expectError(error.InvalidObjectId, ObjectId.parseHex(sha1_hex[0..39], .sha1));
}
