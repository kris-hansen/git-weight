const std = @import("std");
const object_id = @import("object_id.zig");

pub const fanout_size = 256 * 4;
/// Positions at or above this value are not real parents: 0x70000000 marks a
/// parent absent from the graph, and the MSB of the second parent slot marks
/// an EDGE-chunk reference (gitformat-commit-graph(5), "Commit Data").
pub const none_position: u32 = 0x70000000;
const edge_ref_bit: u32 = 0x80000000;

/// Zero-copy view over a `.git/objects/info/commit-graph` file (format v1,
/// gitformat-commit-graph(5)). All validation happens up front in `init`;
/// lookups are bounds-checked slices into the caller-owned `data`, which
/// must outlive this struct (normally a memory-mapped file).
///
/// `init` returns null for anything unusable — wrong magic/version, a hash
/// version that does not match the repository, a bad trailing checksum,
/// missing OIDF/OIDL/CDAT chunks, truncated chunks — so callers can silently
/// fall back to parsing commit objects, mirroring how git itself ignores a
/// bad commit-graph with a warning. Generation data (GDA2/GDO2) and Bloom
/// filter chunks are not interpreted; generation-based reachability pruning
/// is deliberately out of scope.
pub const CommitGraph = struct {
    algorithm: object_id.HashAlgorithm,
    hash_len: usize,
    /// Number of commits (fanout[255]); a commit's position is its index in
    /// `oid_lookup`, whose entries are sorted ascending.
    num_commits: u32,
    /// OIDF chunk: 256 u32 BE entries, F[i] = number of oids with first
    /// byte at most i.
    fanout: []const u8,
    /// OIDL chunk: num_commits * hash_len bytes of sorted oids.
    oid_lookup: []const u8,
    /// CDAT chunk: num_commits * (hash_len + 16) bytes per commit: tree oid,
    /// two parent positions, generation word, commit time.
    commit_data: []const u8,
    /// EDGE chunk (empty when absent): u32 positions holding the second
    /// through nth parents of octopus merges, MSB set on each commit's last
    /// entry.
    extra_edges: []const u8,

    pub fn init(data: []const u8, algorithm: object_id.HashAlgorithm) ?CommitGraph {
        const hash_len = algorithm.rawLen();
        // Header, OIDF/OIDL/CDAT table entries plus terminator, fanout, at
        // least one CDAT row, and the H-byte trailing checksum.
        const min_size = 8 + 3 * 12 + 12 + fanout_size + (hash_len + 16) + hash_len;
        if (data.len < min_size) return null;
        if (!std.mem.eql(u8, data[0..4], "CGPH")) return null;
        if (data[4] != 1) return null; // graph version
        const file_hash_len: usize = switch (data[5]) {
            1 => 20,
            2 => 32,
            else => return null,
        };
        if (file_hash_len != hash_len) return null;
        if (data[7] != 0) return null; // base graphs (split-chain layer): unsupported
        const num_chunks: usize = data[6];

        // TRAILER: H-byte checksum of all preceding bytes, in the
        // repository's hash algorithm.
        const body = data[0 .. data.len - hash_len];
        const trailer = data[data.len - hash_len ..];
        switch (algorithm) {
            .sha1 => {
                var digest: [20]u8 = undefined;
                std.crypto.hash.Sha1.hash(body, &digest, .{});
                if (!std.mem.eql(u8, &digest, trailer)) return null;
            },
            .sha256 => {
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
                if (!std.mem.eql(u8, &digest, trailer)) return null;
            },
        }

        // CHUNK LOOKUP: (C + 1) 12-byte entries: chunk id u32 BE followed by
        // an 8-byte BE offset (gitformat-chunk(5)); id 0 terminates. The
        // observed terminator carries the end-of-data offset, but that is a
        // writer detail — chunk lengths below derive from the smallest
        // following chunk offset or the trailer start, so any chunk order
        // and terminator content parse correctly.
        var off: [4]u64 = .{ 0, 0, 0, 0 }; // OIDF, OIDL, CDAT, EDGE
        var present: [4]bool = .{ false, false, false, false };
        var all_off: [256]u64 = undefined; // every chunk offset, for length derivation
        var n_off: usize = 0;
        {
            var i: usize = 0;
            while (i < num_chunks) : (i += 1) {
                const at = 8 + i * 12;
                if (at + 12 > body.len) return null;
                const id = std.mem.readInt(u32, data[at..][0..4], .big);
                const o = std.mem.readInt(u64, data[at + 4 ..][0..8], .big);
                if (o > body.len) return null;
                all_off[n_off] = o;
                n_off += 1;
                const slot: ?usize = switch (id) {
                    0x4f494446 => 0, // "OIDF"
                    0x4f49444c => 1, // "OIDL"
                    0x43444154 => 2, // "CDAT"
                    0x45444745 => 3, // "EDGE"
                    else => null,
                };
                if (slot) |s| {
                    if (present[s]) return null; // duplicate chunk id
                    present[s] = true;
                    off[s] = o;
                }
            }
        }
        if (!present[0] or !present[1] or !present[2]) return null;

        // Chunk lengths: up to the smallest chunk offset above (tracked or
        // ignored — e.g. GDA2 sits between CDAT and EDGE in git's output),
        // or the trailer start for the last chunk.
        const lens = [4]usize{
            chunkEnd(all_off[0..n_off], off[0], body.len),
            chunkEnd(all_off[0..n_off], off[1], body.len),
            chunkEnd(all_off[0..n_off], off[2], body.len),
            chunkEnd(all_off[0..n_off], off[3], body.len),
        };
        for (0..4) |i| {
            if (off[i] > body.len or lens[i] < off[i] or lens[i] > body.len) return null;
        }
        const fanout = body[@intCast(off[0])..lens[0]];
        if (fanout.len != fanout_size) return null;
        const oid_lookup = body[@intCast(off[1])..lens[1]];
        const commit_data = body[@intCast(off[2])..lens[2]];
        const extra_edges = if (present[3]) body[@intCast(off[3])..lens[3]] else body[0..0];

        const num_commits = std.mem.readInt(u32, fanout[255 * 4 ..][0..4], .big);
        if (num_commits == 0 or num_commits >= none_position) return null;
        if (oid_lookup.len != @as(usize, num_commits) * hash_len) return null;
        if (commit_data.len != @as(usize, num_commits) * (hash_len + 16)) return null;
        if (extra_edges.len % 4 != 0) return null;

        return .{
            .algorithm = algorithm,
            .hash_len = hash_len,
            .num_commits = num_commits,
            .fanout = fanout,
            .oid_lookup = oid_lookup,
            .commit_data = commit_data,
            .extra_edges = extra_edges,
        };
    }

    /// End of the chunk starting at `start`: the smallest chunk offset
    /// above it, capped by the end of the body (before the trailer).
    fn chunkEnd(offs: []const u64, start: u64, body_len: usize) usize {
        var end: u64 = body_len;
        for (offs) |o| {
            if (o > start and o < end) end = o;
        }
        return @intCast(end);
    }

    fn cdatRow(self: *const CommitGraph, pos: u32) []const u8 {
        const row_len = self.hash_len + 16;
        const start = @as(usize, pos) * row_len;
        return self.commit_data[start .. start + row_len];
    }

    /// Position of `id` in the graph, or null when absent. Fanout-guided
    /// binary search over the sorted OIDL chunk. A corrupt (unsorted)
    /// OIDL can at worst cause misses, which callers treat as "not in the
    /// graph" and answer from the object database instead.
    pub fn lookup(self: *const CommitGraph, id: *const object_id.ObjectId) ?u32 {
        const b = id.bytes[0];
        var lo: u32 = if (b == 0) 0 else std.mem.readInt(u32, self.fanout[@as(usize, b - 1) * 4 ..][0..4], .big);
        var hi: u32 = std.mem.readInt(u32, self.fanout[@as(usize, b) * 4 ..][0..4], .big);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const start = @as(usize, mid) * self.hash_len;
            const cand = self.oid_lookup[start .. start + self.hash_len];
            switch (std.mem.order(u8, cand, id.bytes[0..self.hash_len])) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
    }

    /// Oid of the commit at graph position `pos`.
    pub fn oidAt(self: *const CommitGraph, pos: u32) object_id.ObjectId {
        var id: object_id.ObjectId = .{ .algorithm = self.algorithm };
        const start = @as(usize, pos) * self.hash_len;
        @memcpy(id.bytes[0..self.hash_len], self.oid_lookup[start .. start + self.hash_len]);
        return id;
    }

    pub const Entry = struct {
        tree: object_id.ObjectId,
        /// Committer timestamp, seconds since epoch. CDAT stores the low 32
        /// bits plus bits 33-34 in the low two bits of the generation word;
        /// reconstructed as unsigned, so pre-epoch commits wrap — the same
        /// value git's own graph walks compare against.
        time: i64,
        /// Positions of the parents within the graph; empty for root
        /// commits. Borrowed from `parent_buf`.
        parents: []const u32,
    };

    pub const EntryError = error{ OutOfMemory, InvalidGraph };

    /// Commit data for the position returned by `lookup`, resolved without
    /// touching the object database. Returns error.InvalidGraph when the
    /// entry's parents are not fully described by the graph (a parent
    /// missing from the graph, an out-of-range position, or an
    /// inconsistent EDGE chunk): such commits must be re-read from their
    /// object payload so the walk discovers the same commits as pure object
    /// parsing would. `parent_buf` is caller scratch, reused per call.
    pub fn entry(self: *const CommitGraph, pos: u32, alloc: std.mem.Allocator, parent_buf: *std.ArrayList(u32)) EntryError!Entry {
        if (pos >= self.num_commits) return error.InvalidGraph;
        parent_buf.clearRetainingCapacity();
        const r = self.cdatRow(pos);

        var tree: object_id.ObjectId = .{ .algorithm = self.algorithm };
        @memcpy(tree.bytes[0..self.hash_len], r[0..self.hash_len]);

        const gen = std.mem.readInt(u32, r[self.hash_len + 8 ..][0..4], .big);
        const time_lo = std.mem.readInt(u32, r[self.hash_len + 12 ..][0..4], .big);
        const time: i64 = @intCast(@as(u64, time_lo) | (@as(u64, gen & 0x3) << 32));

        const p1 = std.mem.readInt(u32, r[self.hash_len + 0 ..][0..4], .big);
        if (p1 == none_position) {
            // Root commits and commits whose parent is absent from the
            // graph are indistinguishable here (both store 0x70000000 in
            // the first parent slot). Parse the payload instead: it costs
            // one inflation per root and keeps stale graphs (parent object
            // exists outside the graph) from truncating the walk.
            return error.InvalidGraph;
        }
        if (p1 >= self.num_commits) return error.InvalidGraph;
        try parent_buf.append(alloc, p1);

        const p2 = std.mem.readInt(u32, r[self.hash_len + 4 ..][0..4], .big);
        if (p2 == none_position) {
            // No second parent and no octopus edges: done.
        } else if (p2 & edge_ref_bit != 0) {
            var idx: u32 = p2 & ~edge_ref_bit;
            const n_edges: u32 = @intCast(self.extra_edges.len / 4);
            var steps: u32 = 0;
            while (true) {
                if (idx >= n_edges or steps > n_edges) return error.InvalidGraph;
                steps += 1;
                const v = std.mem.readInt(u32, self.extra_edges[@as(usize, idx) * 4 ..][0..4], .big);
                idx += 1;
                const parent = v & ~edge_ref_bit;
                if (parent >= self.num_commits) return error.InvalidGraph;
                try parent_buf.append(alloc, parent);
                if (v & edge_ref_bit != 0) break;
            }
        } else {
            if (p2 >= self.num_commits) return error.InvalidGraph;
            try parent_buf.append(alloc, p2);
        }

        return .{ .tree = tree, .time = time, .parents = parent_buf.items };
    }
};


// --- tests -------------------------------------------------------------------

const TestCommit = struct {
    oid: [20]u8,
    tree: [20]u8,
    /// Parent positions; none_position models a parent the graph does not
    /// cover. More than two parents produce an EDGE chunk (holding
    /// parents[1..], MSB set on the last).
    parents: []const u32,
    time: u64,
    generation: u32 = 1,
};

/// Serialize `commits` as a v1 commit-graph file, following the on-disk
/// layout (fanout, sorted OIDL, CDAT rows, optional EDGE, SHA-1 trailer).
/// Commits are emitted in lexicographic oid order, so a commit's position
/// is its index in the sorted list. Returns an owned slice.
fn buildGraph(allocator: std.mem.Allocator, commits: []const TestCommit) ![]u8 {
    const sorted = try allocator.dupe(TestCommit, commits);
    defer allocator.free(sorted);
    std.mem.sort(TestCommit, sorted, {}, struct {
        fn less(_: void, a: TestCommit, b: TestCommit) bool {
            return std.mem.order(u8, &a.oid, &b.oid) == .lt;
        }
    }.less);

    var n_edge: usize = 0;
    for (sorted) |c| {
        if (c.parents.len > 2) n_edge += c.parents.len - 1;
    }
    const has_edge = n_edge > 0;
    // A dummy GDA2 chunk always sits between CDAT and EDGE: ignored chunks
    // interleave with the parsed ones in real files, and chunk lengths must
    // be derived from every offset in the table, not just the parsed ones.
    const num_chunks: usize = if (has_edge) 5 else 4;

    const table_size = 8 + (num_chunks + 1) * 12;
    const off_oidf: u64 = table_size;
    const off_oidl: u64 = off_oidf + fanout_size;
    const off_cdat: u64 = off_oidl + sorted.len * 20;
    const off_gda2: u64 = off_cdat + sorted.len * (20 + 16);
    const off_edge: u64 = off_gda2 + 4;
    const body_end: u64 = off_edge + n_edge * 4;

    const total: usize = @intCast(body_end + 20);
    const out = try allocator.alloc(u8, total);
    @memset(out, 0);
    var pos: usize = 0;

    @memcpy(out[pos .. pos + 4], "CGPH");
    out[pos + 4] = 1; // version
    out[pos + 5] = 1; // sha1
    out[pos + 6] = @intCast(num_chunks);
    pos += 8;

    const Entry = struct { id: u32, off: u64 };
    const table = [_]Entry{
        .{ .id = 0x4f494446, .off = off_oidf }, // OIDF
        .{ .id = 0x4f49444c, .off = off_oidl }, // OIDL
        .{ .id = 0x43444154, .off = off_cdat }, // CDAT
        .{ .id = 0x47444132, .off = off_gda2 }, // GDA2 (ignored)
        .{ .id = 0x45444745, .off = off_edge }, // EDGE
    };
    for (table[0..num_chunks]) |e| {
        std.mem.writeInt(u32, out[pos..][0..4], e.id, .big);
        std.mem.writeInt(u64, out[pos + 4 ..][0..8], e.off, .big);
        pos += 12;
    }
    std.mem.writeInt(u32, out[pos..][0..4], 0, .big); // terminator
    std.mem.writeInt(u64, out[pos + 4 ..][0..8], body_end, .big);
    pos += 12;

    // OIDF fanout over sorted oids.
    for (0..256) |b| {
        var n: u32 = 0;
        for (sorted) |c| {
            if (c.oid[0] <= b) n += 1;
        }
        std.mem.writeInt(u32, out[pos + 4 * b ..][0..4], n, .big);
    }
    pos += fanout_size;

    // OIDL: sorted oids.
    for (sorted) |c| {
        @memcpy(out[pos .. pos + 20], &c.oid);
        pos += 20;
    }

    // CDAT rows in position order, remembering EDGE positions.
    var edge_list: std.ArrayList(u32) = .empty;
    defer edge_list.deinit(allocator);
    for (sorted) |c| {
        @memcpy(out[pos .. pos + 20], &c.tree);
        pos += 20;
        var p1: u32 = none_position;
        var p2: u32 = none_position;
        if (c.parents.len > 0) p1 = c.parents[0];
        if (c.parents.len == 2) {
            p2 = c.parents[1];
        } else if (c.parents.len > 2) {
            p2 = edge_ref_bit | @as(u32, @intCast(edge_list.items.len));
            for (c.parents[1..], 0..) |p, i| {
                const last = i == c.parents.len - 2;
                try edge_list.append(allocator, if (last) p | edge_ref_bit else p);
            }
        }
        std.mem.writeInt(u32, out[pos..][0..4], p1, .big);
        std.mem.writeInt(u32, out[pos + 4 ..][0..4], p2, .big);
        // Generation v1 in the high 30 bits; low two bits carry commit-time
        // bits 33-34 (CDAT layout).
        std.mem.writeInt(u32, out[pos + 8 ..][0..4], (c.generation << 2) | @as(u32, @intCast((c.time >> 32) & 0x3)), .big);
        std.mem.writeInt(u32, out[pos + 12 ..][0..4], @truncate(c.time), .big);
        pos += 16;
    }

    pos += 4; // dummy GDA2 chunk (4 zero bytes, already memset)

    // EDGE.
    for (edge_list.items) |v| {
        std.mem.writeInt(u32, out[pos..][0..4], v, .big);
        pos += 4;
    }

    std.crypto.hash.Sha1.hash(out[0..pos], out[pos..][0..20], .{});
    return out;
}

fn oidWith(first: u8, rest: u8) object_id.ObjectId {
    var id: object_id.ObjectId = .{ .algorithm = .sha1 };
    id.bytes[0] = first;
    @memset(id.bytes[1..20], rest);
    return id;
}

fn raw(id: object_id.ObjectId) [20]u8 {
    var b: [20]u8 = undefined;
    @memcpy(&b, id.bytes[0..20]);
    return b;
}

test "parse synthetic graph and resolve entries" {
    const a = std.testing.allocator;
    const oid_a = oidWith(0x10, 0xaa); // root
    const oid_b = oidWith(0x20, 0xbb); // child of a
    const oid_c = oidWith(0x30, 0xcc); // merge of a and b
    const oid_d = oidWith(0x40, 0xdd); // octopus: parents a, b, c
    const tree_id = oidWith(0x90, 0x01);
    const tree_x = raw(tree_id);
    const commits = [_]TestCommit{
        .{ .oid = raw(oid_a), .tree = tree_x, .parents = &.{}, .time = 1000 },
        .{ .oid = raw(oid_b), .tree = tree_x, .parents = &.{0}, .time = 2000 },
        .{ .oid = raw(oid_c), .tree = tree_x, .parents = &.{ 0, 1 }, .time = (1 << 32) + 42 },
        .{ .oid = raw(oid_d), .tree = tree_x, .parents = &.{ 0, 1, 2 }, .time = 3000 },
    };
    const bytes = try buildGraph(a, &commits);
    defer a.free(bytes);

    const g = CommitGraph.init(bytes, .sha1).?;
    try std.testing.expectEqual(@as(u32, 4), g.num_commits);

    // Positions follow lexicographic oid order.
    try std.testing.expectEqual(@as(u32, 0), g.lookup(&oid_a).?);
    try std.testing.expectEqual(@as(u32, 1), g.lookup(&oid_b).?);
    try std.testing.expectEqual(@as(u32, 2), g.lookup(&oid_c).?);
    try std.testing.expectEqual(@as(u32, 3), g.lookup(&oid_d).?);

    // Unknown oid: outside the fanout band and inside it.
    try std.testing.expect(g.lookup(&oidWith(0x15, 0x00)) == null);
    try std.testing.expect(g.lookup(&oidWith(0x10, 0xab)) == null);

    var buf: std.ArrayList(u32) = .empty;
    defer buf.deinit(a);

    // Root commits are not servable (see entry): ambiguous with a commit
    // whose parent is absent from the graph, so they re-read from payload.
    try std.testing.expectError(error.InvalidGraph, g.entry(0, a, &buf));

    const ec = try g.entry(2, a, &buf);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, ec.parents);
    // Time bit 33 reconstructs from the generation word's low two bits.
    try std.testing.expectEqual(@as(i64, (1 << 32) + 42), ec.time);

    const ed = try g.entry(3, a, &buf);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, ed.parents);

    try std.testing.expect(g.oidAt(2).eql(&oid_c));
}

test "entry with parent missing from graph is not servable" {
    const a = std.testing.allocator;
    const oid_a = oidWith(0x10, 0xaa);
    const oid_b = oidWith(0x20, 0xbb);
    const tree_x = raw(oidWith(0x90, 0x01));
    const commits = [_]TestCommit{
        .{ .oid = raw(oid_a), .tree = tree_x, .parents = &.{none_position}, .time = 1 },
        .{ .oid = raw(oid_b), .tree = tree_x, .parents = &.{}, .time = 2 },
    };
    const bytes = try buildGraph(a, &commits);
    defer a.free(bytes);
    const g = CommitGraph.init(bytes, .sha1).?;

    var buf: std.ArrayList(u32) = .empty;
    defer buf.deinit(a);
    try std.testing.expectError(error.InvalidGraph, g.entry(0, a, &buf));
    try std.testing.expectError(error.InvalidGraph, g.entry(1, a, &buf));
}

test "init rejects corrupt files" {
    const a = std.testing.allocator;
    const oid_a = oidWith(0x10, 0xaa);
    const tree_x = raw(oidWith(0x90, 0x01));
    const commits = [_]TestCommit{
        .{ .oid = raw(oid_a), .tree = tree_x, .parents = &.{}, .time = 1 },
    };
    const good = try buildGraph(a, &commits);
    defer a.free(good);
    try std.testing.expect(CommitGraph.init(good, .sha1) != null);

    // Bad magic.
    const bad_magic = try a.dupe(u8, good);
    defer a.free(bad_magic);
    bad_magic[0] = 'X';
    try std.testing.expect(CommitGraph.init(bad_magic, .sha1) == null);

    // Unsupported graph version (trailer recomputed so only the version
    // differs).
    const bad_version = try a.dupe(u8, good);
    defer a.free(bad_version);
    bad_version[4] = 2;
    fixTrailer(bad_version);
    try std.testing.expect(CommitGraph.init(bad_version, .sha1) == null);

    // Hash version does not match the repository algorithm.
    const bad_hash = try a.dupe(u8, good);
    defer a.free(bad_hash);
    bad_hash[5] = 2;
    fixTrailer(bad_hash);
    try std.testing.expect(CommitGraph.init(bad_hash, .sha1) == null);

    // Trailing checksum mismatch.
    const bad_sum = try a.dupe(u8, good);
    defer a.free(bad_sum);
    bad_sum[bad_sum.len - 1] ^= 0xff;
    try std.testing.expect(CommitGraph.init(bad_sum, .sha1) == null);

    // Truncated mid-chunk.
    try std.testing.expect(CommitGraph.init(good[0 .. good.len - 40], .sha1) == null);

    // Garbage.
    try std.testing.expect(CommitGraph.init("not a commit graph at all", .sha1) == null);
}

test "init rejects structural inconsistencies" {
    const a = std.testing.allocator;
    const oid_a = oidWith(0x10, 0xaa);
    const tree_x = raw(oidWith(0x90, 0x01));
    const commits = [_]TestCommit{
        .{ .oid = raw(oid_a), .tree = tree_x, .parents = &.{}, .time = 1 },
    };
    const good = try buildGraph(a, &commits);
    defer a.free(good);

    // CDAT entry dropped from the chunk table: claim only OIDF and OIDL.
    const no_cdat = try a.dupe(u8, good);
    defer a.free(no_cdat);
    no_cdat[6] = 2;
    fixTrailer(no_cdat);
    try std.testing.expect(CommitGraph.init(no_cdat, .sha1) == null);

    // Fanout claims two commits while OIDL/CDAT hold one.
    const bad_count = try a.dupe(u8, good);
    defer a.free(bad_count);
    const off_oidf = std.mem.readInt(u64, good[8 + 4 ..][0..8], .big);
    std.mem.writeInt(u32, bad_count[@intCast(off_oidf + 255 * 4)..][0..4], 2, .big);
    fixTrailer(bad_count);
    try std.testing.expect(CommitGraph.init(bad_count, .sha1) == null);

    // Empty graph: no commits at all.
    const empty = try buildGraph(a, &.{});
    defer a.free(empty);
    try std.testing.expect(CommitGraph.init(empty, .sha1) == null);
}

fn fixTrailer(bytes: []u8) void {
    std.crypto.hash.Sha1.hash(bytes[0 .. bytes.len - 20], bytes[bytes.len - 20 ..][0..20], .{});
}

