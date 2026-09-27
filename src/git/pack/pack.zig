const std = @import("std");
const object_id = @import("../object_id.zig");
const git_object = @import("../object.zig");
const inflate = @import("../inflate.zig");
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
    /// Delta chain depth: 0 for base objects, 1 + base depth for deltas.
    delta_depth: u32 = 0,
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
                .delta_depth = 0,
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
                    .delta_depth = base_info.delta_depth + 1,
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
                        .delta_depth = 0,
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
        // stream header; the type propagates up from the base. Chain depth is
        // the base's depth plus the number of delta hops above it.
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
                .delta_depth = base_info.delta_depth + @as(u32, @intCast(chain.items.len - i)),
            };
            try cache.put(allocator, entry_off, resolved);
        }
        return resolved;
    }

    /// Inflate just enough of the delta stream at `data_offset` to read the
    /// source and target size varints.
    fn deltaTargetSize(self: *const Pack, data_offset: u64) PackError!u64 {
        var infl: inflate.Inflater = undefined;
        infl.init(self.data[@intCast(data_offset)..]);
        defer infl.deinit();
        var buf: [32]u8 = undefined;
        const n = infl.read(&buf) catch return error.CorruptPack;
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
        var infl: inflate.Inflater = undefined;
        infl.init(self.data[@intCast(data_offset)..]);
        defer infl.deinit();
        const buf = allocator.alloc(u8, @intCast(stream_size)) catch return error.OutOfMemory;
        errdefer allocator.free(buf);
        // Delta entries: entry size is the decompressed delta stream length.
        infl.readAll(buf) catch return error.CorruptPack;
        return buf;
    }

    pub const Payload = struct {
        object_type: git_object.ObjectType,
        /// Borrowed from the cache when `pin` is set (valid until `release`);
        /// caller-owned otherwise (loose objects, oversized payloads).
        data: []const u8,
        pin: ?PayloadCache.Pin = null,

        /// Drop the cache borrow, if any. `data` must not be used afterwards.
        /// Call exactly once; skipping it on an error path between
        /// readPayload and release only leaks the borrow until the store
        /// (and its caches) is torn down.
        pub fn release(self: Payload) void {
            if (self.pin) |p| p.unpin();
        }
    };

    /// Cache of reconstructed payloads by pack offset (the equivalent of
    /// git's delta base cache). Thread-safe: sharded by offset, each shard
    /// spinlocked. Entries are heap-allocated and handed out as borrowed
    /// slices pinned by a refcount, so readers never copy: a pin keeps the
    /// entry's bytes valid even after the shard evicts it; the entry is
    /// reclaimed once no pins remain (at the next eviction sweep or at
    /// deinit). When a shard exceeds its share of `budget` it is cleared —
    /// delta chains are resolved and consumed in one burst, so chain-local
    /// reuse (the common case) survives clearing. Entries larger than
    /// `max_entry_size` are never cached. Owns all cached bytes; live memory
    /// stays within roughly 2x `budget` (map plus evicted-but-pinned).
    pub const PayloadCache = struct {
        pub const Entry = struct {
            object_type: git_object.ObjectType,
            data: []u8,
            /// Outstanding pins. Bumped under the shard lock (lookup) and by
            /// insert; dropped with a plain atomic in `Pin.unpin`, which
            /// never touches any other field — so a concurrent unpin can
            /// never race a reclaim.
            refs: std.atomic.Value(u32) = .init(0),
            /// Per-shard list of evicted entries awaiting reclaim.
            orphan_next: ?*Entry = null,
        };

        /// A borrow of a cache entry. The entry's bytes stay valid until
        /// `unpin` is called, even if the shard evicts the entry meanwhile.
        pub const Pin = struct {
            cache: *PayloadCache,
            shard: *Shard,
            entry: *Entry,

            /// Drop the borrow. After the last unpin the entry is reclaimed
            /// at the next eviction sweep or at deinit; the payload bytes
            /// must not be used after this call.
            pub fn unpin(self: Pin) void {
                _ = self.entry.refs.fetchSub(1, .release);
            }
        };

        // Shard count trades contention against cache locality: delta chains
        // live at nearby pack offsets, so neighbouring shards fill together
        // during a burst, and the per-shard budget must survive one burst
        // (plus in-flight neighbours) or resolution re-inflates evicted
        // bases repeatedly.
        const n_shards = 16;
        const Shard = struct {
            mutex: std.atomic.Mutex = .unlocked,
            map: std.AutoHashMapUnmanaged(u64, *Entry) = .empty,
            total_bytes: u64 = 0,
            /// Evicted entries with outstanding pins; swept (reclaiming
            /// unpinned ones) at the next eviction.
            orphans: ?*Entry = null,
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
                while (it.next()) |e| {
                    const entry = e.value_ptr.*;
                    self.allocator.free(entry.data);
                    self.allocator.destroy(entry);
                }
                s.map.deinit(self.allocator);
                var orphan = s.orphans;
                while (orphan) |entry| {
                    orphan = entry.orphan_next;
                    self.allocator.free(entry.data);
                    self.allocator.destroy(entry);
                }
            }
        }

        fn shardFor(self: *PayloadCache, offset: u64) *Shard {
            return &self.shards[@intCast((offset >> 12) % n_shards)];
        }

        /// Whether a payload of `size` bytes may be cached.
        pub fn cacheable(size: u64) bool {
            return size <= max_entry_size;
        }

        /// Look up `offset`, returning a pinned borrow of the cached payload
        /// (no copy), or null on a miss. Call `Pin.unpin` when done.
        fn pin(self: *PayloadCache, offset: u64) ?Pin {
            const s = self.shardFor(offset);
            lockSpin(&s.mutex);
            defer s.mutex.unlock();
            const entry = s.map.get(offset) orelse return null;
            _ = entry.refs.fetchAdd(1, .monotonic);
            return .{ .cache = self, .shard = s, .entry = entry };
        }

        const InsertResult = struct { pin: Pin, dup: bool };

        /// Insert `data` (cache-allocator owned; ownership transfers on
        /// success) and return it pinned. On a duplicate offset the existing
        /// entry is returned instead, `dup` is true, and `data` is left
        /// unfreed for the caller to release. On allocator failure the
        /// insert is skipped, null is returned, and `data` stays with the
        /// caller. Freed eviction victims are unlinked under the lock but
        /// released after it, so syscalls stay out of the critical section.
        fn insert(self: *PayloadCache, offset: u64, object_type: git_object.ObjectType, data: []u8) ?InsertResult {
            const s = self.shardFor(offset);
            const shard_budget = self.budget / n_shards;
            var victims: std.ArrayListUnmanaged(*Entry) = .empty;
            defer victims.deinit(self.allocator);
            lockSpin(&s.mutex);
            var result: ?InsertResult = null;
            if (s.map.get(offset)) |existing| {
                _ = existing.refs.fetchAdd(1, .monotonic);
                result = .{ .pin = .{ .cache = self, .shard = s, .entry = existing }, .dup = true };
            } else {
                if (s.total_bytes + data.len > shard_budget) self.evictAllLocked(s, &victims);
                if (self.allocator.create(Entry)) |entry| {
                    entry.* = .{ .object_type = object_type, .data = data };
                    if (s.map.put(self.allocator, offset, entry)) {
                        s.total_bytes += data.len;
                        _ = entry.refs.fetchAdd(1, .monotonic);
                        result = .{ .pin = .{ .cache = self, .shard = s, .entry = entry }, .dup = false };
                    } else |_| {
                        self.allocator.destroy(entry);
                    }
                } else |_| {}
            }
            s.mutex.unlock();
            for (victims.items) |victim| {
                self.allocator.free(victim.data);
                self.allocator.destroy(victim);
            }
            return result;
        }

        /// Clear the shard when over budget. First reclaim orphaned entries
        /// whose pins have been dropped, then move the map's entries to the
        /// orphan list — entries with pins stay valid for their borrowers;
        /// entries without pins are collected as victims and freed by the
        /// caller once the lock is released. Caller holds the lock; no pin
        /// or unpin can touch a victim (none are reachable from the map or
        /// the orphan list, and unpins only ever touch `refs`).
        fn evictAllLocked(self: *PayloadCache, s: *Shard, victims: *std.ArrayListUnmanaged(*Entry)) void {
            var olink = &s.orphans;
            while (olink.*) |entry| {
                if (entry.refs.load(.acquire) == 0) {
                    olink.* = entry.orphan_next;
                    victims.append(self.allocator, entry) catch {
                        // Tracking failed: reclaim inline (no pins, so no
                        // borrower can race).
                        self.allocator.free(entry.data);
                        self.allocator.destroy(entry);
                    };
                } else {
                    olink = &entry.orphan_next;
                }
            }
            var it = s.map.iterator();
            while (it.next()) |e| {
                const entry = e.value_ptr.*;
                s.total_bytes -= entry.data.len;
                if (entry.refs.load(.acquire) == 0) {
                    victims.append(self.allocator, entry) catch {
                        self.allocator.free(entry.data);
                        self.allocator.destroy(entry);
                    };
                } else {
                    entry.orphan_next = s.orphans;
                    s.orphans = entry;
                }
            }
            s.map.clearRetainingCapacity();
        }
    };

    /// Fully reconstruct the object payload at `offset`. Payloads are
    /// decompressed and delta-resolved. When `cache` is given, reconstructed
    /// entries (including delta bases) are memoized so repeated walks pay one
    /// inflation per object, and the returned payload borrows the cache entry
    /// (pinned): call `Payload.release` when done. Without a cache (or for
    /// payloads too large to cache) the caller owns the memory as before.
    pub fn readPayload(self: *const Pack, allocator: std.mem.Allocator, offset: u64, cache: ?*PayloadCache) PackError!Payload {
        return self.readPayloadDepth(allocator, offset, cache, 0);
    }

    fn readPayloadDepth(self: *const Pack, allocator: std.mem.Allocator, offset: u64, cache: ?*PayloadCache, depth: usize) PackError!Payload {
        if (depth > max_delta_depth) return error.CorruptPack;
        if (cache) |c| {
            if (c.pin(offset)) |p| {
                return .{ .object_type = p.entry.object_type, .data = p.entry.data, .pin = p };
            }
        }
        const raw = try self.readRawEntry(offset);
        switch (raw.entry_type) {
            .commit, .tree, .blob, .tag => {
                var infl: inflate.Inflater = undefined;
                infl.init(self.data[@intCast(raw.data_offset)..]);
                defer infl.deinit();
                // Cacheable payloads are allocated in cache-owned memory so
                // the cache can hand them out without a copy; oversized ones
                // stay caller-owned and are never cached.
                const store = if (cache != null and PayloadCache.cacheable(raw.size)) cache.? else null;
                const alloc = if (store) |c| c.allocator else allocator;
                const buf = alloc.alloc(u8, @intCast(raw.size)) catch return error.OutOfMemory;
                infl.readAll(buf) catch {
                    alloc.free(buf);
                    return error.CorruptPack;
                };
                if (store) |c| {
                    if (c.insert(offset, raw.entry_type, buf)) |r| {
                        if (r.dup) alloc.free(buf);
                        return .{ .object_type = raw.entry_type, .data = r.pin.entry.data, .pin = r.pin };
                    }
                    // Insert failed (OOM): hand caller-owned memory back, as
                    // the pin-null contract requires.
                    const copy = allocator.dupe(u8, buf) catch {
                        alloc.free(buf);
                        return error.OutOfMemory;
                    };
                    alloc.free(buf);
                    return .{ .object_type = raw.entry_type, .data = copy };
                }
                return .{ .object_type = raw.entry_type, .data = buf };
            },
            .ofs_delta, .ref_delta => {
                const base_offset = try self.baseOffset(raw.base);
                const base = try self.readPayloadDepth(allocator, base_offset, cache, depth + 1);
                defer base.release();
                defer if (base.pin == null) allocator.free(base.data);
                const stream = try self.inflateDeltaStream(allocator, raw.data_offset, raw.size);
                defer allocator.free(stream);
                // Peek the reconstructed size to pick the owner up front.
                var vpos: usize = 0;
                _ = delta.readVarint(stream, &vpos) orelse return error.CorruptPack;
                const tgt_size = delta.readVarint(stream, &vpos) orelse return error.CorruptPack;
                const store = if (cache != null and PayloadCache.cacheable(tgt_size)) cache.? else null;
                const alloc = if (store) |c| c.allocator else allocator;
                const out = delta.applyDelta(alloc, base.data, stream) catch return error.CorruptPack;
                if (store) |c| {
                    if (c.insert(offset, base.object_type, out)) |r| {
                        if (r.dup) alloc.free(out);
                        return .{ .object_type = base.object_type, .data = r.pin.entry.data, .pin = r.pin };
                    }
                    const copy = allocator.dupe(u8, out) catch {
                        alloc.free(out);
                        return error.OutOfMemory;
                    };
                    alloc.free(out);
                    return .{ .object_type = base.object_type, .data = copy };
                }
                return .{ .object_type = base.object_type, .data = out };
            },
        }
    }
};
