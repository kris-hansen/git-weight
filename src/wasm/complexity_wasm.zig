//! wasm32-freestanding entry for the git-free complexity core.
//!
//! Host protocol (all lengths in bytes, data in `io` at `ioPtr()`):
//!   begin(prefix_len)        io[0..prefix_len] = Go module prefix ("" for none)
//!   wants(path_len) -> u32   io[0..path_len] = path; 1 if contents should be scored
//!   addFile(path_len, len)   io = path ++ contents; returns 0 ok, 1 error
//!   finish() -> u32          writes compact JSON result into io, returns its length
const std = @import("std");
const core = @import("complexity_core");
const domain = core.domain;

pub const io_capacity = 8 << 20;
var io: [io_capacity]u8 = undefined;
var scratch: [64 << 20]u8 = undefined;
var prefix_buf: [256]u8 = undefined;
var scanner: core.Scanner = .{};

export fn ioPtr() [*]u8 {
    return &io;
}

export fn ioCapacity() u32 {
    return io_capacity;
}

export fn begin(prefix_len: u32) void {
    const n = @min(prefix_len, prefix_buf.len);
    @memcpy(prefix_buf[0..n], io[0..n]);
    scanner = core.Scanner.begin(if (n == 0) null else prefix_buf[0..n]);
}

export fn wants(path_len: u32) u32 {
    return @intFromBool(scanner.wants(io[0..path_len]));
}

export fn addFile(path_len: u32, data_len: u32) u32 {
    if (@as(usize, path_len) + data_len > io.len) return 1;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    scanner.addFile(fba.allocator(), io[0..path_len], io[path_len .. path_len + data_len]) catch return 1;
    return 0;
}

export fn finish() u32 {
    const m = scanner.finish();
    var w: std.Io.Writer = .fixed(&io);
    w.print("{{\"score_version\":\"{s}\"", .{core.score_version}) catch return 0;
    inline for (@typeInfo(core.Metrics).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "domain_counts")) continue;
        w.print(",\"{s}\":{d}", .{ f.name, @field(m, f.name) }) catch return 0;
    }
    w.writeAll(",\"domain_counts\":{") catch return 0;
    inline for (@typeInfo(domain.Counts).@"struct".fields, 0..) |f, i| {
        w.print("{s}\"{s}\":{d}", .{ if (i == 0) "" else ",", f.name, @field(m.domain_counts, f.name) }) catch return 0;
    }
    w.writeAll("}}") catch return 0;
    return @intCast(w.end);
}
