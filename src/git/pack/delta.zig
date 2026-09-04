const std = @import("std");

/// Apply a Git delta instruction stream to `base`, producing the target
/// object payload. `delta` is the fully decompressed delta stream:
/// `<src_size varint><tgt_size varint><instructions...>`.
pub fn applyDelta(allocator: std.mem.Allocator, base: []const u8, delta: []const u8) ![]u8 {
    var pos: usize = 0;
    const src_size = readVarint(delta, &pos) orelse return error.InvalidDelta;
    if (src_size != base.len) return error.InvalidDelta;
    const tgt_size = readVarint(delta, &pos) orelse return error.InvalidDelta;

    const out = try allocator.alloc(u8, tgt_size);
    errdefer allocator.free(out);

    var out_pos: usize = 0;
    while (pos < delta.len) {
        const cmd = delta[pos];
        pos += 1;
        if (cmd & 0x80 != 0) {
            // Copy from base.
            var copy_off: usize = 0;
            var copy_size: usize = 0;
            inline for (0..4) |i| {
                if (cmd & (@as(u8, 1) << i) != 0) {
                    if (pos >= delta.len) return error.InvalidDelta;
                    copy_off |= @as(usize, delta[pos]) << (8 * i);
                    pos += 1;
                }
            }
            inline for (0..3) |i| {
                if (cmd & (@as(u8, 0x10) << i) != 0) {
                    if (pos >= delta.len) return error.InvalidDelta;
                    copy_size |= @as(usize, delta[pos]) << (8 * i);
                    pos += 1;
                }
            }
            if (copy_size == 0) copy_size = 0x10000;
            if (copy_off + copy_size > base.len) return error.InvalidDelta;
            if (out_pos + copy_size > out.len) return error.InvalidDelta;
            @memcpy(out[out_pos..][0..copy_size], base[copy_off..][0..copy_size]);
            out_pos += copy_size;
        } else if (cmd != 0) {
            // Literal insert.
            const n: usize = cmd;
            if (pos + n > delta.len) return error.InvalidDelta;
            if (out_pos + n > out.len) return error.InvalidDelta;
            @memcpy(out[out_pos..][0..n], delta[pos..][0..n]);
            pos += n;
            out_pos += n;
        } else {
            return error.InvalidDelta;
        }
    }
    if (out_pos != out.len) return error.InvalidDelta;
    return out;
}

/// Git's variable-length integer encoding used in delta streams (7 bits per
/// byte, little-endian groups, continuation bit).
pub fn readVarint(data: []const u8, pos: *usize) ?u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (pos.* < data.len) {
        const b = data[pos.*];
        pos.* += 1;
        result |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return result;
        shift += 7;
        if (shift > 63) return null;
    }
    return null;
}

test "apply delta insert" {
    // base "hello", delta: src=5, tgt=11, insert " world", copy 5 from off 0
    const base = "hello";
    const delta = [_]u8{
        5, // src size
        11, // tgt size
        0x90, 5, // copy: offset 0 (implied), size 5
        6, ' ', 'w', 'o', 'r', 'l', 'd', // insert 6 bytes
    };
    const out = try applyDelta(std.testing.allocator, base, &delta);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello world", out);
}

test "read varint" {
    var pos: usize = 0;
    try std.testing.expectEqual(@as(?u64, 300), readVarint(&[_]u8{ 0xac, 0x02 }, &pos));
    try std.testing.expectEqual(@as(usize, 2), pos);
}
