const std = @import("std");
const object_id = @import("../object_id.zig");

pub const IndexError = error{
    UnsupportedVersion,
    InvalidIndex,
    CorruptIndex,
};

const magic: u32 = 0xff744f63; // "\xfftOc"

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
///   pack checksum, idx checksum.
pub const PackIndex = struct {
    data: []const u8,
    count: u32,
    oid_len: usize,
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

        // Large offset table: everything up to the two trailing checksums.
        if (data.len < pos + 40) return error.InvalidIndex;
        const large = data[pos .. data.len - 40];

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
            .oid_len = oid_len,
            .oids = oids,
            .crcs = crcs,
            .offsets32 = offsets32,
            .large_offsets = large,
        };
    }

    pub fn oidAt(self: *const PackIndex, i: usize) object_id.ObjectId {
        std.debug.assert(i < self.count);
        var id: object_id.ObjectId = .{ .algorithm = if (self.oid_len == 20) .sha1 else .sha256 };
        const start = i * self.oid_len;
        @memcpy(id.bytes[0..self.oid_len], self.oids[start .. start + self.oid_len]);
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
