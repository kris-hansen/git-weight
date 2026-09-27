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
/// a repository without blobs has a largest blob of 0. `max_growth` compares
/// against `growth_latest_month_bytes` — logical bytes introduced in the most
/// recent calendar month of reachable history (0 when history is empty).
pub fn build(
    allocator: std.mem.Allocator,
    s: *const summary_mod.Summary,
    max_size: ?u64,
    max_historical: ?u64,
    max_unreachable: ?u64,
    max_blob: ?u64,
    max_growth: ?u64,
    growth_latest_month_bytes: ?u64,
) CheckError!Check {
    var list: [5]Threshold = undefined;
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
    if (max_growth) |limit| {
        list[n] = .{ .name = "max-growth", .limit = limit, .actual = growth_latest_month_bytes orelse 0 };
        n += 1;
    }
    const thresholds = try allocator.dupe(Threshold, list[0..n]);
    return .{ .thresholds = thresholds };
}

test "max-growth threshold compares latest month" {
    const s: summary_mod.Summary = std.mem.zeroInit(summary_mod.Summary, .{ .name = "r", .git_dir_path = ".git" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const pass = try build(arena.allocator(), &s, null, null, null, null, 100, 80);
    try std.testing.expectEqual(@as(usize, 1), pass.thresholds.len);
    try std.testing.expectEqualStrings("max-growth", pass.thresholds[0].name);
    try std.testing.expectEqual(@as(u64, 80), pass.thresholds[0].actual);
    try std.testing.expect(pass.allOk());

    const fail = try build(arena.allocator(), &s, null, null, null, null, 100, 120);
    try std.testing.expect(!fail.allOk());

    // Missing growth data (empty history) counts as 0 and passes.
    const empty = try build(arena.allocator(), &s, null, null, null, null, 100, null);
    try std.testing.expect(empty.allOk());
}
