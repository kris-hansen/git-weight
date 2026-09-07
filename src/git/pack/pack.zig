const std = @import("std");
const Io = std.Io;
const object_id = @import("../object_id.zig");
const git_object = @import("../object.zig");
const PackIndex = @import("index.zig").PackIndex;
const delta = @import("delta.zig");

pub const PackError = error{
    InvalidPack,
    CorruptPack,
    ObjectNotFound,
    OutOfMemory,
    UnsupportedDelta,
};

pub const DeltaBase = union(enum) {
    none,
    ofs: u64,
    ref: object_id.ObjectId,
};

/// Resolved metadata for one pack entry (delta chains walked to completion).
pub const ObjectInfo = struct {
    /// Real Git object type (delta placeholders resolved away).
    object_type: git_object.ObjectType,
    /// Logical (reconstructed) object size in bytes.
    size: u64,
    /// Offset of the entry within the packfile.
    offset: u64,
    /// Offset where the zlib stream (or delta stream) begins.
    data_offset: u64,
    delta_base: DeltaBase,
};

const max_delta_depth = 4096;

fn orderU64(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}

fn lockSpin(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

/// A packfile plus its index, both memory-mapped.
pub const Pack = struct {
    data: []const u8,
    index: PackIndex,
    oid_len: usize,
    /// All entry offsets, sorted ascending; enables O(log n) nextOffsetAfter.
    /// Owned by the ObjectStore that built it; empty means "not built".
    sorted_offsets: []const u64 = &.{},

    /// Raw entry header as stored in the pack.
    const RawEntry = struct {
        entry_type: git_object.ObjectType,
        /// For real objects: logical size. For deltas: decompressed delta
        /// stream length.
        size: u64,
        data_offset: u64,
        base: DeltaBase,
    };

    pub fn init(pack_data: []const u8, index: PackIndex, algorithm: object_id.HashAlgorithm) PackError!Pack {
        if (pack_data.len < 12) return error.InvalidPack;
        if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return error.InvalidPack;
        const version = std.mem.readInt(u32, pack_data[4..8], .big);
        if (version != 2 and version != 3) return error.UnsupportedDelta;
        const entry_count = std.mem.readInt(u32, pack_data[8..12], .big);
        if (entry_count != index.count) return error.InvalidPack;
        return .{
            .data = pack_data,
            .index = index,
            .oid_len = algorithm.rawLen(),
        };
    }

    fn readRawEntry(self: *const Pack, offset: u64) PackError!RawEntry {
        var pos: u64 = offset;
        if (pos >= self.data.len) return error.CorruptPack;
        var c: u8 = self.data[pos];
        pos += 1;
        const entry_type: git_object.ObjectType = @enumFromInt((c >> 4) & 7);
        var size: u64 = c & 0x0f;
        var shift: u6 = 4;
        while (c & 0x80 != 0) {
            if (pos >= self.data.len) return error.CorruptPack;
            c = self.data[pos];
            pos += 1;
            size |= @as(u64, c & 0x7f) << shift;
            shift += 7;
            if (shift > 63) return error.CorruptPack;
        }

        var base: DeltaBase = .none;
        switch (entry_type) {
            .ofs_delta => {
                // Base offset encoded as a negative offset from this entry.
                if (pos >= self.data.len) return error.CorruptPack;
                var b: u8 = self.data[pos];
                pos += 1;
                var ofs: u64 = b & 0x7f;
                while (b & 0x80 != 0) {
                    if (pos >= self.data.len) return error.CorruptPack;
                    b = self.data[pos];
                    pos += 1;
                    ofs = ((ofs + 1) << 7) | (b & 0x7f);
                }
                if (ofs > offset) return error.CorruptPack;
                base = .{ .ofs = offset - ofs };
            },
            .ref_delta => {
                if (pos + self.oid_len > self.data.len) return error.CorruptPack;
                var id: object_id.ObjectId = .{ .algorithm = if (self.oid_len == 20) .sha1 else .sha256 };
                @memcpy(id.bytes[0..self.oid_len], self.data[pos .. pos + self.oid_len]);
                pos += self.oid_len;
                base = .{ .ref = id };
            },
            else => {},
        }

        return .{
            .entry_type = entry_type,
            .size = size,
            .data_offset = pos,
            .base = base,
        };
    }

    fn baseOffset(self: *const Pack, base: DeltaBase) PackError!u64 {
        return switch (base) {
            .none => unreachable,
            .ofs => |o| o,
            .ref => |id| blk: {
                const i = self.index.find(&id) orelse return error.UnsupportedDelta;
                break :blk self.index.offsetAt(i);
            },
        };
    }

    /// Resolve the real object type and logical size for the entry at
    /// `offset`, walking delta chains. For delta entries the logical size
    /// comes from the delta stream header, which requires inflating the first
    /// bytes of the delta stream.
    pub fn infoAt(self: *const Pack, offset: u64) PackError!ObjectInfo {
        return self.infoAtDepth(offset, 0);
    }

    fn infoAtDepth(self: *const Pack, offset: u64, depth: usize) PackError!ObjectInfo {
        if (depth > max_delta_depth) return error.CorruptPack;
        const raw = try self.readRawEntry(offset);
        switch (raw.entry_type) {
            .commit, .tree, .blob, .tag => return .{
                .object_type = raw.entry_type,
                .size = raw.size,
                .offset = offset,
                .data_offset = raw.data_offset,
                .delta_base = .none,
            },
            .ofs_delta, .ref_delta => {
                const base_offset = try self.baseOffset(raw.base);
                const base_info = try self.infoAtDepth(base_offset, depth + 1);
                const tgt_size = try self.deltaTargetSize(raw.data_offset);
                return .{
                    .object_type = base_info.object_type,
                    .size = tgt_size,
                    .offset = offset,
                    .data_offset = raw.data_offset,
                    .delta_base = raw.base,
                };
            },
        }
    }

    /// Resolved pack entry infos keyed by entry offset.
    pub const InfoCache = std.AutoHashMapUnmanaged(u64, ObjectInfo);

    /// Like `infoAt`, but iterative and memoized: every chain entry resolved
    /// along the way is cached, so resolving all entries in a pack costs one
    /// header read (and one partial inflate) per delta entry total.
    pub fn infoAtCached(self: *const Pack, cache: *InfoCache, allocator: std.mem.Allocator, offset: u64) PackError!ObjectInfo {
        if (cache.get(offset)) |inf| return inf;

        var chain: std.ArrayList(u64) = .empty;
        defer chain.deinit(allocator);

        var base_info: ObjectInfo = undefined;
        var cur = offset;
        walk: while (true) {
            if (cache.get(cur)) |inf| {
                base_info = inf;
                break :walk;
            }
            const raw = try self.readRawEntry(cur);
            switch (raw.entry_type) {
                .commit, .tree, .blob, .tag => {
                    base_info = .{
                        .object_type = raw.entry_type,
                        .size = raw.size,
                        .offset = cur,
                        .data_offset = raw.data_offset,
                        .delta_base = .none,
                    };
                    break :walk;
                },
                .ofs_delta, .ref_delta => {
                    if (chain.items.len >= max_delta_depth) return error.CorruptPack;
                    try chain.append(allocator, cur);
                    cur = try self.baseOffset(raw.base);
                },
            }
        }

        if (chain.items.len == 0) return base_info;
        try cache.put(allocator, cur, base_info);

        // Unwind deepest-first: each delta's logical size comes from its own
        // stream header; the type propagates up from the base.
        var resolved = base_info;
        var i = chain.items.len;
        while (i > 0) {
            i -= 1;
            const entry_off = chain.items[i];
            const raw = try self.readRawEntry(entry_off);
            const tgt_size = try self.deltaTargetSize(raw.data_offset);
            resolved = .{
                .object_type = resolved.object_type,
                .size = tgt_size,
                .offset = entry_off,
                .data_offset = raw.data_offset,
                .delta_base = raw.base,
            };
            try cache.put(allocator, entry_off, resolved);
        }
        return resolved;
    }

    /// Inflate just enough of the delta stream at `data_offset` to read the
    /// source and target size varints.
    fn deltaTargetSize(self: *const Pack, data_offset: u64) PackError!u64 {
        var in = Io.Reader.fixed(self.data[@intCast(data_offset)..]);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decomp = std.compress.flate.Decompress.init(&in, .zlib, &window);
        var buf: [32]u8 = undefined;
        const n = decomp.reader.readSliceShort(&buf) catch return error.CorruptPack;
        var pos: usize = 0;
        _ = delta.readVarint(buf[0..n], &pos) orelse return error.CorruptPack;
        return delta.readVarint(buf[0..n], &pos) orelse return error.CorruptPack;
    }

    /// Find an object by id.
    pub fn find(self: *const Pack, id: *const object_id.ObjectId) ?u64 {
        const i = self.index.find(id) orelse return null;
        return self.index.offsetAt(i);
    }

    /// The smallest entry offset in the index greater than `offset`, or the
    /// offset of the trailing pack checksum if none. Used to derive an
    /// entry's physical (on-disk) span.
    pub fn nextOffsetAfter(self: *const Pack, offset: u64) u64 {
        const end: u64 = self.data.len - self.oid_len; // trailing pack checksum
        if (self.sorted_offsets.len > 0) {
            const idx = std.sort.upperBound(u64, self.sorted_offsets, offset, orderU64);
            return if (idx < self.sorted_offsets.len) self.sorted_offsets[idx] else end;
        }
        var next: u64 = end;
        var i: usize = 0;
        while (i < self.index.count) : (i += 1) {
            const o = self.index.offsetAt(i);
            if (o > offset and o < next) next = o;
        }
        return next;
    }

    /// Inflate the decompressed delta instruction stream for the entry at
    /// `offset`. `stream_size` is the entry's declared (decompressed) size.
    fn inflateDeltaStream(self: *const Pack, allocator: std.mem.Allocator, data_offset: u64, stream_size: u64) PackError![]u8 {
        var in = Io.Reader.fixed(self.data[@intCast(data_offset)..]);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decomp = std.compress.flate.Decompress.init(&in, .zlib, &window);
        const buf = allocator.alloc(u8, @intCast(stream_size)) catch return error.OutOfMemory;
        errdefer allocator.free(buf);
        // Delta entries: entry size is the decompressed delta stream length.
        decomp.reader.readSliceAll(buf) catch return error.CorruptPack;
        return buf;
    }

    pub const Payload = struct {
        object_type: git_object.ObjectType,
        data: []u8,
    };

    /// Cache of reconstructed payloads by pack offset (the equivalent of
    /// git's delta base cache). Thread-safe: sharded by offset, each shard
    /// spinlocked. When a shard exceeds its share of `budget` it is cleared
    /// — delta chains are resolved and consumed in one burst, so chain-local
    /// reuse (the common case) survives clearing. Entries larger than
    /// `max_entry_size` are never cached. Owns all cached bytes.
    pub const PayloadCache = struct {
        pub const Entry = struct {
            object_type: git_object.ObjectType,
            data: []u8,
        };

        const n_shards = 16;
        const Shard = struct {
            mutex: std.atomic.Mutex = .unlocked,
            map: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
            total_bytes: u64 = 0,
        };

        allocator: std.mem.Allocator,
        shards: [n_shards]Shard,
        budget: u64 = 256 << 20,

        const max_entry_size = 4 << 20;

        pub fn init(allocator: std.mem.Allocator) PayloadCache {
            var c: PayloadCache = .{ .allocator = allocator, .shards = undefined };
            for (&c.shards) |*s| s.* = .{};
            return c;
        }

        pub fn deinit(self: *PayloadCache) void {
            for (&self.shards) |*s| {
                var it = s.map.iterator();
                while (it.next()) |e| self.allocator.free(e.value_ptr.data);
                s.map.deinit(self.allocator);
            }
        }

        fn shardFor(self: *PayloadCache, offset: u64) *Shard {
            return &self.shards[@intCast((offset >> 12) % n_shards)];
        }

        /// Returns a copy of the cached payload (allocated from `dest`),
        /// or null on a miss. The copy happens under the shard lock because
        /// entries can be cleared at any time.
        fn get(self: *PayloadCache, offset: u64, dest: std.mem.Allocator) ?Entry {
            const s = self.shardFor(offset);
            lockSpin(&s.mutex);
            defer s.mutex.unlock();
            const e = s.map.get(offset) orelse return null;
            const copy = dest.dupe(u8, e.data) catch return null;
            return .{ .object_type = e.object_type, .data = copy };
        }

        fn put(self: *PayloadCache, offset: u64, object_type: git_object.ObjectType, data: []const u8) void {
            if (data.len > max_entry_size) return;
            // Copy before taking the lock to shorten the critical section.
            const copy = self.allocator.dupe(u8, data) catch return;
            const s = self.shardFor(offset);
            const shard_budget = self.budget / n_shards;
            lockSpin(&s.mutex);
            defer s.mutex.unlock();
            if (s.map.contains(offset)) {
                self.allocator.free(copy);
                return;
            }
            if (s.total_bytes + data.len > shard_budget) {
                var it = s.map.iterator();
                while (it.next()) |e| self.allocator.free(e.value_ptr.data);
                s.map.clearRetainingCapacity();
                s.total_bytes = 0;
            }
            s.map.put(self.allocator, offset, .{ .object_type = object_type, .data = copy }) catch {
                self.allocator.free(copy);
                return;
            };
            s.total_bytes += copy.len;
        }
    };

    /// Fully reconstruct the object payload at `offset`. Payloads are
    /// decompressed and delta-resolved; caller owns the memory. When `cache`
    /// is given, reconstructed entries (including delta bases) are memoized
    /// so repeated walks pay one inflation per object.
    pub fn readPayload(self: *const Pack, allocator: std.mem.Allocator, offset: u64, cache: ?*PayloadCache) PackError!Payload {
        return self.readPayloadDepth(allocator, offset, cache, 0);
    }

    fn readPayloadDepth(self: *const Pack, allocator: std.mem.Allocator, offset: u64, cache: ?*PayloadCache, depth: usize) PackError!Payload {
        if (depth > max_delta_depth) return error.CorruptPack;
        if (cache) |c| {
            if (c.get(offset, allocator)) |cached| {
                return .{ .object_type = cached.object_type, .data = cached.data };
            }
        }
        const raw = try self.readRawEntry(offset);
        switch (raw.entry_type) {
            .commit, .tree, .blob, .tag => {
                var in = Io.Reader.fixed(self.data[@intCast(raw.data_offset)..]);
                var window: [std.compress.flate.max_window_len]u8 = undefined;
                var decomp = std.compress.flate.Decompress.init(&in, .zlib, &window);
                const buf = allocator.alloc(u8, @intCast(raw.size)) catch return error.OutOfMemory;
                errdefer allocator.free(buf);
                decomp.reader.readSliceAll(buf) catch return error.CorruptPack;
                if (cache) |c| c.put(offset, raw.entry_type, buf);
                return .{ .object_type = raw.entry_type, .data = buf };
            },
            .ofs_delta, .ref_delta => {
                const base_offset = try self.baseOffset(raw.base);
                const base = try self.readPayloadDepth(allocator, base_offset, cache, depth + 1);
                defer allocator.free(base.data);
                const stream = try self.inflateDeltaStream(allocator, raw.data_offset, raw.size);
                defer allocator.free(stream);
                const out = delta.applyDelta(allocator, base.data, stream) catch return error.CorruptPack;
                if (cache) |c| c.put(offset, base.object_type, out);
                return .{ .object_type = base.object_type, .data = out };
            },
        }
    }
};
