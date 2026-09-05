const std = @import("std");
const object_id = @import("object_id.zig");
const refs_mod = @import("refs.zig");
const commit_mod = @import("commit.zig");
const object_store = @import("../analysis/objects.zig");
const paths_mod = @import("../analysis/paths.zig");

pub const ResolveError = error{
    UnknownRevision,
    OutOfMemory,
};

/// One ancestry operation parsed off the end of a revision expression.
pub const Op = union(enum) {
    /// `~N`: N first-parent steps.
    first_parent: u32,
    /// `^N`: N-th parent (`^0` is the commit itself).
    nth_parent: u32,
};

pub const max_ops = 32;

/// A revision expression split into a base name and ancestry operations.
pub const ParsedRev = struct {
    base: []const u8,
    ops: [max_ops]Op = undefined,
    op_count: usize = 0,

    pub fn opsSlice(self: *const ParsedRev) []const Op {
        return self.ops[0..self.op_count];
    }
};

/// Split a revision expression like `HEAD~2^1` into its base name (`HEAD`)
/// and ancestry operations. Returns null when the expression is malformed
/// (empty base, non-digit suffix, too many operations).
pub fn parse(name: []const u8) ?ParsedRev {
    var parsed: ParsedRev = .{ .base = name };
    const suffix_start = std.mem.indexOfAny(u8, name, "~^") orelse name.len;
    parsed.base = name[0..suffix_start];
    if (parsed.base.len == 0 and suffix_start != name.len) return null;

    var i = suffix_start;
    while (i < name.len) {
        const c = name[i];
        if (c != '~' and c != '^') return null;
        i += 1;
        var n: u32 = 0;
        var has_digits = false;
        while (i < name.len and std.ascii.isDigit(name[i])) : (i += 1) {
            n = std.math.mul(u32, n, 10) catch return null;
            n = std.math.add(u32, n, name[i] - '0') catch return null;
            has_digits = true;
        }
        if (!has_digits) n = 1;
        if (parsed.op_count >= max_ops) return null;
        parsed.ops[parsed.op_count] = switch (c) {
            '~' => .{ .first_parent = n },
            else => .{ .nth_parent = n },
        };
        parsed.op_count += 1;
    }
    return parsed;
}

/// Resolve a revision expression (ref name, hex oid, or either with
/// ancestry suffixes) to a commit oid. Annotated tags are peeled.
pub fn resolve(
    store: *const object_store.ObjectStore,
    refs: *const refs_mod.Refs,
    name: []const u8,
    allocator: std.mem.Allocator,
) ResolveError!object_id.ObjectId {
    const parsed = parse(name) orelse return error.UnknownRevision;
    const base_id = try resolveBase(store, refs, parsed.base);
    var commit = paths_mod.peelToCommit(store, &base_id, 0) orelse return error.UnknownRevision;

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    for (parsed.opsSlice()) |op| {
        switch (op) {
            .first_parent => |n| {
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    commit = try stepParent(store, &scratch, &commit, 1);
                }
            },
            .nth_parent => |n| {
                if (n == 0) continue; // ^0 is the commit itself
                commit = try stepParent(store, &scratch, &commit, n);
            },
        }
    }
    return commit;
}

/// Resolve the base name: full hex oid that exists in the store, or a ref
/// name tried as-is and under refs/heads/, refs/tags/, refs/remotes/
/// (a bare "HEAD" matches via the as-is case).
fn resolveBase(
    store: *const object_store.ObjectStore,
    refs: *const refs_mod.Refs,
    base: []const u8,
) ResolveError!object_id.ObjectId {
    if (object_id.ObjectId.fromHex(base) catch null) |id| {
        switch (store.locate(&id)) {
            .missing => {},
            else => return id,
        }
    }
    for ([_][]const u8{ "", "refs/heads/", "refs/tags/", "refs/remotes/" }) |prefix| {
        for (refs.refs.items) |r| {
            if (r.name.len != prefix.len + base.len) continue;
            if (!std.mem.startsWith(u8, r.name, prefix)) continue;
            if (std.mem.eql(u8, r.name[prefix.len..], base)) return r.target;
        }
    }
    return error.UnknownRevision;
}

/// Step to the `n`-th parent of `commit` (n is 1-based).
fn stepParent(
    store: *const object_store.ObjectStore,
    scratch: *std.heap.ArenaAllocator,
    commit: *const object_id.ObjectId,
    n: u32,
) ResolveError!object_id.ObjectId {
    _ = scratch.reset(.retain_capacity);
    const payload = store.readPayload(scratch.allocator(), commit) catch return error.UnknownRevision;
    if (payload.object_type != .commit) return error.UnknownRevision;
    const c = commit_mod.parse(payload.data, commit.algorithm, scratch.allocator()) catch return error.UnknownRevision;
    if (n == 0 or n > c.parents.len) return error.UnknownRevision;
    return c.parents[n - 1];
}

test "parse revision suffixes" {
    const p1 = parse("HEAD").?;
    try std.testing.expectEqualStrings("HEAD", p1.base);
    try std.testing.expectEqual(@as(usize, 0), p1.op_count);

    const p2 = parse("HEAD~2^1").?;
    try std.testing.expectEqualStrings("HEAD", p2.base);
    try std.testing.expectEqual(@as(usize, 2), p2.op_count);
    try std.testing.expectEqual(Op{ .first_parent = 2 }, p2.opsSlice()[0]);
    try std.testing.expectEqual(Op{ .nth_parent = 1 }, p2.opsSlice()[1]);

    const p3 = parse("v1.0^").?;
    try std.testing.expectEqualStrings("v1.0", p3.base);
    try std.testing.expectEqual(Op{ .nth_parent = 1 }, p3.opsSlice()[0]);

    const p4 = parse("main~").?;
    try std.testing.expectEqual(Op{ .first_parent = 1 }, p4.opsSlice()[0]);

    const p5 = parse("HEAD^0").?;
    try std.testing.expectEqual(Op{ .nth_parent = 0 }, p5.opsSlice()[0]);

    const p6 = parse("origin/main~10").?;
    try std.testing.expectEqualStrings("origin/main", p6.base);
    try std.testing.expectEqual(Op{ .first_parent = 10 }, p6.opsSlice()[0]);

    const p7 = parse("a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2~1").?;
    try std.testing.expectEqual(@as(usize, 40), p7.base.len);

    try std.testing.expectEqual(@as(?ParsedRev, null), parse("HEAD~x"));
    try std.testing.expectEqual(@as(?ParsedRev, null), parse("~2"));
    try std.testing.expectEqual(@as(?ParsedRev, null), parse("HEAD^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1^1"));
}
