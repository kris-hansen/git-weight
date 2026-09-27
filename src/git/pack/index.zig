const std = @import("std");
const object_id = @import("../object_id.zig");

pub const IndexError = error{
    UnsupportedVersion,
    InvalidIndex,
    CorruptIndex,
};

const magic: u32 = 0xff744f63; // "\xfftOc"; idx v2 uses this magic for both
// SHA-1 and SHA-256 repositories — only the oid width and the trailer
// checksums (2 * hash width) differ.

/// Fanout entries are big-endian u32s at data[8 + 4*i].
fn fanoutAt(data: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, data[8 + 4 * i ..][0..4], .big);
}

/// Parser for Git pack index version 2, operating directly on the mapped
/// index bytes (zero-copy; object IDs are slices into the mapping).
///
/// Layout:
///   4B magic, 4B version (2), 256*4B fanout,
///   N * oid_len  object IDs (sorted),
///   N * 4B       CRC32,
///   N * 4B       offsets (MSB set => index into 64-bit table),
///   M * 8B       large offsets,
///   pack checksum + idx checksum (each oid_len bytes; 40B total for
///   SHA-1, 64B for SHA-256).
pub const PackIndex = struct {
    data: []const u8,
    count: u32,
    algorithm: object_id.HashAlgorithm,
    oids: []const u8, // count * oid_len bytes
    crcs: []const u8, // count * 4 bytes
    offsets32: []const u8, // count * 4 bytes
    large_offsets: []const u8, // remaining 8B entries

    pub fn init(data: []const u8, algorithm: object_id.HashAlgorithm) IndexError!PackIndex {
        if (data.len < 8 + 256 * 4) return error.InvalidIndex;
        const version = std.mem.readInt(u32, data[4..8], .big);
        if (version != 2) return error.UnsupportedVersion;
        if (std.mem.readInt(u32, data[0..4], .big) != magic) return error.InvalidIndex;

        const oid_len = algorithm.rawLen();
        const count = fanoutAt(data, 255);
        if (count == 0) return error.InvalidIndex;

        var pos: usize = 8 + 256 * 4;
        const oid_bytes = @as(usize, count) * oid_len;
        if (data.len < pos + oid_bytes) return error.InvalidIndex;
        const oids = data[pos .. pos + oid_bytes];
        pos += oid_bytes;

        const crc_bytes = @as(usize, count) * 4;
        if (data.len < pos + crc_bytes) return error.InvalidIndex;
        const crcs = data[pos .. pos + crc_bytes];
        pos += crc_bytes;

        const off_bytes = @as(usize, count) * 4;
        if (data.len < pos + off_bytes) return error.InvalidIndex;
        const offsets32 = data[pos .. pos + off_bytes];
        pos += off_bytes;

        // Large offset table: everything up to the two trailing checksums
        // (pack checksum + idx checksum, one hash width each).
        const trailer = 2 * oid_len;
        if (data.len < pos + trailer) return error.InvalidIndex;
        const large = data[pos .. data.len - trailer];

        // Fanout must be monotonic.
        var prev: u32 = 0;
        for (0..256) |i| {
            const f = fanoutAt(data, i);
            if (f < prev) return error.CorruptIndex;
            prev = f;
        }

        return .{
            .data = data,
            .count = count,
            .algorithm = algorithm,
            .oids = oids,
            .crcs = crcs,
            .offsets32 = offsets32,
            .large_offsets = large,
        };
    }

    pub fn oidAt(self: *const PackIndex, i: usize) object_id.ObjectId {
        std.debug.assert(i < self.count);
        const oid_len = self.algorithm.rawLen();
        var id: object_id.ObjectId = .{ .algorithm = self.algorithm };
        const start = i * oid_len;
        @memcpy(id.bytes[0..oid_len], self.oids[start .. start + oid_len]);
        return id;
    }

    pub fn offsetAt(self: *const PackIndex, i: usize) u64 {
        std.debug.assert(i < self.count);
        const off32 = std.mem.readInt(u32, self.offsets32[i * 4 ..][0..4], .big);
        if (off32 & 0x80000000 != 0) {
            const large_idx = off32 & 0x7fffffff;
            const start = @as(usize, large_idx) * 8;
            if (start + 8 > self.large_offsets.len) return 0;
            return std.mem.readInt(u64, self.large_offsets[start..][0..8], .big);
        }
        return off32;
    }

    /// Binary search for `id`; returns the entry index or null.
    pub fn find(self: *const PackIndex, id: *const object_id.ObjectId) ?usize {
        const first_byte = id.bytes[0];
        var lo: usize = if (first_byte == 0) 0 else fanoutAt(self.data, first_byte - 1);
        var hi: usize = fanoutAt(self.data, first_byte);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const mid_oid = self.oidAt(mid);
            switch (id.order(&mid_oid)) {
                .eq => return mid,
                .lt => hi = mid,
                .gt => lo = mid + 1,
            }
        }
        return null;
    }
};

test "idx v2 parse rejects junk" {
    const junk = [_]u8{0} ** 2048;
    try std.testing.expectError(error.UnsupportedVersion, PackIndex.init(&junk, .sha1));
}

/// Build a minimal but valid idx v2 for `ids` (must be sorted and distinct)
/// with 32-bit offsets `offsets`, sized for `algorithm` (this is what makes
/// the trailer width hash-dependent).
fn makeIdxV2(algorithm: object_id.HashAlgorithm, ids: []const object_id.ObjectId, offsets: []const u32, out: []u8) []const u8 {
    const oid_len = algorithm.rawLen();
    var pos: usize = 0;
    std.mem.writeInt(u32, out[pos..][0..4], magic, .big);
    std.mem.writeInt(u32, out[pos + 4 ..][0..4], 2, .big);
    pos += 8;
    for (0..256) |i| {
        var n: u32 = 0;
        for (ids) |id| {
            if (id.bytes[0] <= i) n += 1;
        }
        std.mem.writeInt(u32, out[pos + 4 * i ..][0..4], n, .big);
    }
    pos += 256 * 4;
    for (ids) |id| {
        @memcpy(out[pos .. pos + oid_len], id.bytes[0..oid_len]);
        pos += oid_len;
    }
    for (ids, 0..) |_, i| {
        std.mem.writeInt(u32, out[pos + 4 * i ..][0..4], @intCast(i * 12345), .big);
    }
    pos += ids.len * 4;
    for (offsets) |o| {
        std.mem.writeInt(u32, out[pos..][0..4], o, .big);
        pos += 4;
    }
    @memset(out[pos .. pos + 2 * oid_len], 0xab); // pack checksum + idx checksum
    return out[0 .. pos + 2 * oid_len];
}

test "idx v2 round trip sha1 and sha256" {
    var id_a: object_id.ObjectId = .{ .algorithm = .sha1 };
    id_a.bytes[0] = 0x10;
    id_a.bytes[19] = 0xaa;
    var id_b: object_id.ObjectId = .{ .algorithm = .sha1 };
    id_b.bytes[0] = 0x20;
    id_b.bytes[19] = 0xbb;
    const ids = [_]object_id.ObjectId{ id_a, id_b };
    const offsets = [_]u32{ 12, 3456 };

    var buf: [2048]u8 = undefined;
    const data = makeIdxV2(.sha1, &ids, &offsets, &buf);
    const idx = try PackIndex.init(data, .sha1);
    try std.testing.expectEqual(@as(u32, 2), idx.count);
    try std.testing.expect(id_a.eql(&idx.oidAt(0)));
    try std.testing.expect(id_b.eql(&idx.oidAt(1)));
    try std.testing.expectEqual(@as(usize, 0), idx.find(&id_a).?);
    try std.testing.expectEqual(@as(usize, 1), idx.find(&id_b).?);
    try std.testing.expect(idx.find(&object_id.ObjectId.zero_sha1) == null);
    try std.testing.expectEqual(@as(u64, 12), idx.offsetAt(0));
    try std.testing.expectEqual(@as(u64, 3456), idx.offsetAt(1));

    // Same construction at SHA-1 width must not parse as SHA-256, and vice
    // versa: the trailer math differs (40 vs 64 bytes), so the large-offset
    // window lands differently.
    var sbuf: [2048]u8 = undefined;
    var sid: object_id.ObjectId = .{ .algorithm = .sha256 };
    sid.bytes[0] = 0x10;
    const sids = [_]object_id.ObjectId{sid};
    const soffsets = [_]u32{99};
    const sdata = makeIdxV2(.sha256, &sids, &soffsets, &sbuf);
    const sidx = try PackIndex.init(sdata, .sha256);
    try std.testing.expectEqual(@as(u32, 1), sidx.count);
    try std.testing.expect(sid.eql(&sidx.oidAt(0)));
    try std.testing.expectEqual(@as(u64, 99), sidx.offsetAt(0));
    try std.testing.expectEqual(@as(usize, 0), sidx.find(&sid).?);
}
