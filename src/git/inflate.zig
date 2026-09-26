const std = @import("std");
const build_options = @import("build_options");

const use_zlib = build_options.system_zlib;

const c = if (use_zlib) @cImport({
    @cInclude("zlib.h");
}) else struct {};

pub const Error = error{CorruptStream};

/// Streaming zlib-stream inflater. Selects libz or std.compress.flate at
/// comptime via the build_options `system_zlib` flag; both backends accept
/// the same zlib-wrapped deflate streams Git stores in packs and loose
/// objects. Initialized in place because the pure-Zig backend holds
/// self-references into the struct.
pub const Inflater = struct {
    compressed: []const u8,
    in: if (use_zlib) void else std.Io.Reader,
    window: if (use_zlib) void else [std.compress.flate.max_window_len]u8,
    decomp: if (use_zlib) void else std.compress.flate.Decompress,
    strm: if (use_zlib) c.z_stream else void,
    in_pos: if (use_zlib) usize else void,

    pub fn init(self: *Inflater, data: []const u8) void {
        self.compressed = data;
        if (use_zlib) {
            self.strm = std.mem.zeroes(c.z_stream);
            // A failed inflateInit_ leaves state null, which both inflate and
            // inflateEnd treat as an error, surfacing as CorruptStream later.
            _ = c.inflateInit_(&self.strm, c.ZLIB_VERSION, @sizeOf(c.z_stream));
            self.in_pos = 0;
        } else {
            self.in = std.Io.Reader.fixed(data);
            self.decomp = std.compress.flate.Decompress.init(&self.in, .zlib, &self.window);
        }
    }

    pub fn deinit(self: *Inflater) void {
        if (use_zlib) _ = c.inflateEnd(&self.strm);
    }

    /// Inflate up to `buf.len` bytes, returning the number produced. The
    /// count is short only when the stream ends first; stops inflating as
    /// soon as the buffer is full.
    pub fn read(self: *Inflater, buf: []u8) Error!usize {
        if (use_zlib) {
            var out_pos: usize = 0;
            while (out_pos < buf.len) {
                if (self.strm.avail_in == 0) {
                    if (self.in_pos == self.compressed.len) return error.CorruptStream;
                    self.feedIn();
                }
                const n: c.uInt = @intCast(@min(buf.len - out_pos, std.math.maxInt(c.uInt)));
                self.strm.next_out = buf.ptr + out_pos;
                self.strm.avail_out = n;
                const ret = c.inflate(&self.strm, 0);
                out_pos += n - self.strm.avail_out;
                if (ret == c.Z_STREAM_END) break;
                if (ret != c.Z_OK) return error.CorruptStream;
            }
            return out_pos;
        } else {
            return self.decomp.reader.readSliceShort(buf) catch return error.CorruptStream;
        }
    }

    /// Inflate the entire stream into `out`, which must be exactly the
    /// decompressed size.
    pub fn readAll(self: *Inflater, out: []u8) Error!void {
        if (use_zlib) {
            var out_pos: usize = 0;
            while (true) {
                if (self.strm.avail_in == 0) {
                    if (self.in_pos == self.compressed.len) return error.CorruptStream;
                    self.feedIn();
                }
                const n: c.uInt = @intCast(@min(out.len - out_pos, std.math.maxInt(c.uInt)));
                self.strm.next_out = out.ptr + out_pos;
                self.strm.avail_out = n;
                const ret = c.inflate(&self.strm, 0);
                out_pos += n - self.strm.avail_out;
                if (ret == c.Z_STREAM_END) return;
                if (ret != c.Z_OK) return error.CorruptStream;
                if (out_pos == out.len) {
                    // Output full but the stream is not ended; legal only if
                    // nothing but the trailing checksum remains.
                    self.strm.avail_out = 0;
                    const end_ret = c.inflate(&self.strm, 0);
                    if (end_ret != c.Z_STREAM_END) return error.CorruptStream;
                    return;
                }
            }
        } else {
            self.decomp.reader.readSliceAll(out) catch return error.CorruptStream;
        }
    }

    fn feedIn(self: *Inflater) void {
        const chunk = @min(self.compressed.len - self.in_pos, std.math.maxInt(c.uInt));
        self.strm.next_in = @constCast(self.compressed.ptr + self.in_pos);
        self.strm.avail_in = @intCast(chunk);
        self.in_pos += chunk;
    }
};

fn compressForTest(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(&aw.writer, &window, .zlib, .{});
    try comp.writer.writeAll(data);
    try comp.finish();
    return aw.toOwnedSlice();
}

test "round trip full inflate" {
    const allocator = std.testing.allocator;
    const payload = "the quick brown fox jumps over the lazy dog " ** 64;
    const compressed = try compressForTest(allocator, payload);
    defer allocator.free(compressed);

    var infl: Inflater = undefined;
    infl.init(compressed);
    defer infl.deinit();
    var out: [payload.len]u8 = undefined;
    try infl.readAll(&out);
    try std.testing.expectEqualStrings(payload, &out);
}

test "round trip prefix read stops early" {
    const allocator = std.testing.allocator;
    const payload = "0123456789abcdef" ** 128;
    const compressed = try compressForTest(allocator, payload);
    defer allocator.free(compressed);

    var infl: Inflater = undefined;
    infl.init(compressed);
    defer infl.deinit();
    var buf: [32]u8 = undefined;
    const n = try infl.read(&buf);
    try std.testing.expectEqual(32, n);
    try std.testing.expectEqualStrings(payload[0..32], buf[0..n]);

    // The stream must continue where the prefix read stopped.
    var rest: [payload.len - 32]u8 = undefined;
    try infl.readAll(&rest);
    try std.testing.expectEqualStrings(payload[32..], &rest);
}

test "prefix read at stream end returns short count" {
    const allocator = std.testing.allocator;
    const compressed = try compressForTest(allocator, "short");
    defer allocator.free(compressed);

    var infl: Inflater = undefined;
    infl.init(compressed);
    defer infl.deinit();
    var buf: [64]u8 = undefined;
    const n = try infl.read(&buf);
    try std.testing.expectEqual(5, n);
    try std.testing.expectEqualStrings("short", buf[0..n]);
}

test "delta header probe reads leading varints" {
    const allocator = std.testing.allocator;
    // Delta stream: src size 100, tgt size 200, then filler instructions.
    var delta: [64]u8 = undefined;
    delta[0] = 100;
    delta[1] = 200;
    for (delta[2..]) |*b| b.* = 1; // literal inserts of one byte
    const compressed = try compressForTest(allocator, &delta);
    defer allocator.free(compressed);

    var infl: Inflater = undefined;
    infl.init(compressed);
    defer infl.deinit();
    var buf: [32]u8 = undefined;
    const n = try infl.read(&buf);
    const delta_mod = @import("pack/delta.zig");
    var pos: usize = 0;
    const src_size = delta_mod.readVarint(buf[0..n], &pos).?;
    const tgt_size = delta_mod.readVarint(buf[0..n], &pos).?;
    try std.testing.expectEqual(100, src_size);
    try std.testing.expectEqual(200, tgt_size);
}

test "corrupt stream is rejected" {
    var infl: Inflater = undefined;
    infl.init(&[_]u8{ 0x78, 0x9c, 1, 2, 3 });
    defer infl.deinit();
    var buf: [32]u8 = undefined;
    try std.testing.expectError(error.CorruptStream, infl.read(&buf));
}

test "truncated stream is rejected" {
    const allocator = std.testing.allocator;
    const payload = "compress me " ** 32;
    const compressed = try compressForTest(allocator, payload);
    defer allocator.free(compressed);

    var infl: Inflater = undefined;
    infl.init(compressed[0 .. compressed.len - 4]);
    defer infl.deinit();
    var out: [payload.len]u8 = undefined;
    try std.testing.expectError(error.CorruptStream, infl.readAll(&out));
}
