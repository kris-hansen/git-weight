const std = @import("std");
const summary_mod = @import("summary.zig");

pub const CheckError = error{OutOfMemory};

pub const Threshold = struct {
    name: []const u8,
    limit: u64,
    actual: u64,

    pub fn ok(self: Threshold) bool {
        return self.actual <= self.limit;
    }
};

pub const Check = struct {
    thresholds: []Threshold,

    pub fn allOk(self: *const Check) bool {
        for (self.thresholds) |t| {
            if (!t.ok()) return false;
        }
        return true;
    }
};

/// Evaluate the configured thresholds against a built summary. The largest
/// blob is the head of the summary's contributors (sorted size descending);
/// a repository without blobs has a largest blob of 0.
pub fn build(
    allocator: std.mem.Allocator,
    s: *const summary_mod.Summary,
    max_size: ?u64,
    max_historical: ?u64,
    max_unreachable: ?u64,
    max_blob: ?u64,
) CheckError!Check {
    var list: [4]Threshold = undefined;
    var n: usize = 0;
    if (max_size) |limit| {
        list[n] = .{ .name = "max-size", .limit = limit, .actual = s.git_bytes };
        n += 1;
    }
    if (max_historical) |limit| {
        list[n] = .{ .name = "max-historical", .limit = limit, .actual = s.historical_bytes };
        n += 1;
    }
    if (max_unreachable) |limit| {
        list[n] = .{ .name = "max-unreachable", .limit = limit, .actual = s.unreachable_bytes };
        n += 1;
    }
    if (max_blob) |limit| {
        const largest: u64 = if (s.contributors.len > 0) s.contributors[0].size else 0;
        list[n] = .{ .name = "max-blob", .limit = limit, .actual = largest };
        n += 1;
    }
    const thresholds = try allocator.dupe(Threshold, list[0..n]);
    return .{ .thresholds = thresholds };
}
