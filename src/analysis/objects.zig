const std = @import("std");
const Io = std.Io;
const Repository = @import("../git/repository.zig").Repository;
const object_id = @import("../git/object_id.zig");
const git_object = @import("../git/object.zig");
const loose_mod = @import("../git/loose.zig");
const pack_mod = @import("../git/pack/pack.zig");
const index_mod = @import("../git/pack/index.zig");
const mmap = @import("../platform/mmap.zig");

pub const StoreError = error{
    OutOfMemory,
    SystemResources,
    Unexpected,
    CorruptRepository,
    UnsupportedFormat,
};

pub const PackFile = struct {
    pack: pack_mod.Pack,
    mapped_pack: mmap.MappedFile,
    mapped_index: mmap.MappedFile,
    /// Absolute path of the .pack file.
    path: []const u8,
    /// Heap-allocated so `info` stays callable through `*const ObjectStore`:
    /// the field is const, the pointee is not.
    info_cache: *pack_mod.Pack.InfoCache,
    /// Same trick: memoized reconstructed payloads (git's delta base cache).
    payload_cache: *pack_mod.Pack.PayloadCache,
    /// All entry offsets sorted ascending (backing for Pack.sorted_offsets).
    sorted_offsets: []u64,

    pub fn objectCount(self: *const PackFile) u32 {
        return self.pack.index.count;
    }
};

pub const Located = union(enum) {
    loose: usize, // index into store.loose.objects
    /// Loose object found by direct path probe before the loose index is
    /// built; path owned by the store allocator.
    loose_path: []const u8,
    pack: struct { pack_id: usize, offset: u64 },
    missing,
};

/// Unified read-only view over a repository's object database (loose objects
/// plus all packfiles, all memory-mapped).
///
/// The full object index (loose scan + pack entry map) is built lazily via
/// ensureIndexed: commands that only resolve a handful of objects (changed)
/// skip the O(objects) index build and probe pack indexes / loose paths on
/// demand instead.
pub const ObjectStore = struct {
    allocator: std.mem.Allocator,
    algorithm: object_id.HashAlgorithm,
    loose: loose_mod.LooseList,
    packs: std.ArrayList(PackFile),
    /// oid -> location for loose objects and pack entries; complete only
    /// after ensureIndexed().
    locations: std.HashMapUnmanaged(object_id.ObjectId, Located, object_id.ObjectId.Context, 80),
    /// Owned copy of the objects directory path, for lazy loose probes.
    objects_dir: []const u8,
    indexed: bool,

    pub fn open(allocator: std.mem.Allocator, repo: *const Repository) StoreError!ObjectStore {
        var obuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const objects_dir = try allocator.dupe(u8, repo.objectsDir(&obuf));
        errdefer allocator.free(objects_dir);

        var store: ObjectStore = .{
            .allocator = allocator,
            .algorithm = repo.hash_algorithm,
            .loose = .{ .allocator = allocator, .objects = .empty },
            .packs = .empty,
            .locations = .empty,
            .objects_dir = objects_dir,
            .indexed = false,
        };
        errdefer store.deinit();

        try store.openPacks(objects_dir);
        return store;
    }

    /// Build the full oid -> location index (loose scan + pack entries).
    /// Idempotent; required before iterating `locations`.
    pub fn ensureIndexed(self: *ObjectStore) StoreError!void {
        if (self.indexed) return;
        self.indexed = true;

        self.loose = loose_mod.scan(self.allocator, self.objects_dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CorruptRepository => return error.CorruptRepository,
            else => return error.Unexpected,
        };
        for (self.loose.objects.items, 0..) |*o, i| {
            try self.locations.put(self.allocator, o.id, .{ .loose = i });
        }

        for (self.packs.items, 0..) |*pf, pack_id| {
            // Sorted offsets enable O(log n) physical-size lookups; built
            // here rather than at open so cheap commands skip the sort.
            if (pf.sorted_offsets.len == 0) {
                const sorted = try self.allocator.alloc(u64, pf.pack.index.count);
                for (sorted, 0..) |*o, i| o.* = pf.pack.index.offsetAt(i);
                std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
                pf.sorted_offsets = sorted;
                pf.pack.sorted_offsets = sorted;
            }

            var i: usize = 0;
            while (i < pf.pack.index.count) : (i += 1) {
                const id = pf.pack.index.oidAt(i);
                const gop = try self.locations.getOrPut(self.allocator, id);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .pack = .{ .pack_id = pack_id, .offset = pf.pack.index.offsetAt(i) } };
                }
            }
        }
    }

    fn openPacks(self: *ObjectStore, objects_dir: []const u8) StoreError!void {
        var pbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const pack_dir_path = std.fmt.bufPrint(&pbuf, "{s}/pack", .{objects_dir}) catch return error.Unexpected;

        var dir = std.Io.Dir.cwd().openDir(io(), pack_dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return error.Unexpected,
        };
        defer dir.close(io());

        var it = dir.iterate();
        while (it.next(io()) catch return error.Unexpected) |ent| {
            if (ent.kind != .file) continue;
            if (!std.mem.endsWith(u8, ent.name, ".idx")) continue;

            const idx_path = try std.fmt.allocPrint(self.allocator, "{s}/pack/{s}", .{ objects_dir, ent.name });
            defer self.allocator.free(idx_path);
            const pack_file_name = try std.fmt.allocPrint(self.allocator, "{s}.pack", .{ent.name[0 .. ent.name.len - 4]});
            defer self.allocator.free(pack_file_name);
            const pack_path = try std.fmt.allocPrint(self.allocator, "{s}/pack/{s}", .{ objects_dir, pack_file_name });
            defer self.allocator.free(pack_path);

            var mapped_index = mmap.MappedFile.init(idx_path) catch return error.CorruptRepository;
            errdefer mapped_index.deinit();
            var mapped_pack = mmap.MappedFile.init(pack_path) catch return error.CorruptRepository;
            errdefer mapped_pack.deinit();

            const idx = index_mod.PackIndex.init(mapped_index.data, self.algorithm) catch |err| switch (err) {
                error.UnsupportedVersion => return error.UnsupportedFormat,
                else => return error.CorruptRepository,
            };
            const p = pack_mod.Pack.init(mapped_pack.data, idx, self.algorithm) catch return error.CorruptRepository;

            const info_cache = try self.allocator.create(pack_mod.Pack.InfoCache);
            errdefer self.allocator.destroy(info_cache);
            info_cache.* = .empty;

            // The payload cache evicts and frees entries; it must use a
            // freeing allocator, not the process-wide arena.
            const payload_cache = try self.allocator.create(pack_mod.Pack.PayloadCache);
            errdefer self.allocator.destroy(payload_cache);
            payload_cache.* = .{ .allocator = std.heap.page_allocator };

            const path_copy = try self.allocator.dupe(u8, pack_path);
            errdefer self.allocator.free(path_copy);
            try self.packs.append(self.allocator, .{
                .pack = p,
                .mapped_pack = mapped_pack,
                .mapped_index = mapped_index,
                .path = path_copy,
                .info_cache = info_cache,
                .payload_cache = payload_cache,
                .sorted_offsets = &.{},
            });
        }
    }

    pub fn deinit(self: *ObjectStore) void {
        for (self.packs.items) |*pf| {
            pf.mapped_pack.deinit();
            pf.mapped_index.deinit();
            self.allocator.free(pf.path);
            pf.info_cache.deinit(self.allocator);
            self.allocator.destroy(pf.info_cache);
            pf.payload_cache.deinit();
            self.allocator.destroy(pf.payload_cache);
            self.allocator.free(pf.sorted_offsets);
        }
        self.packs.deinit(self.allocator);
        self.loose.deinit();
        self.locations.deinit(self.allocator);
        self.allocator.free(self.objects_dir);
    }

    pub fn locate(self: *const ObjectStore, id: *const object_id.ObjectId) Located {
        if (self.indexed) return self.locations.get(id.*) orelse .missing;
        // Lazy mode: binary-search pack indexes, then probe the loose path.
        for (self.packs.items, 0..) |*pf, pack_id| {
            if (pf.pack.find(id)) |offset| {
                return .{ .pack = .{ .pack_id = pack_id, .offset = offset } };
            }
        }
        var hex_buf: [64]u8 = undefined;
        const h = id.hex(&hex_buf);
        const path = std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ self.objects_dir, h[0..2], h[2..] }) catch return .missing;
        _ = std.Io.Dir.cwd().statFile(io(), path, .{}) catch {
            self.allocator.free(path);
            return .missing;
        };
        return .{ .loose_path = path };
    }

    pub const Info = struct {
        object_type: git_object.ObjectType,
        size: u64,
    };

    /// Resolve type and logical size for an object (delta chains walked).
    pub fn info(self: *const ObjectStore, id: *const object_id.ObjectId) StoreError!Info {
        switch (self.locate(id)) {
            .missing => return error.CorruptRepository,
            .loose => |i| {
                const header = loose_mod.resolveHeader(&self.loose.objects.items[i]) catch return error.CorruptRepository;
                return .{ .object_type = header.object_type, .size = header.size };
            },
            .loose_path => |p| {
                const header = loose_mod.readHeaderFromPath(p) catch return error.CorruptRepository;
                return .{ .object_type = header.object_type, .size = header.size };
            },
            .pack => |loc| {
                const pf = &self.packs.items[loc.pack_id];
                const inf = pf.pack.infoAtCached(pf.info_cache, self.allocator, loc.offset) catch return error.CorruptRepository;
                return .{ .object_type = inf.object_type, .size = inf.size };
            },
        }
    }

    pub const Payload = struct {
        object_type: git_object.ObjectType,
        data: []u8,
    };

    /// Fully reconstruct an object's payload. Caller frees `data`.
    pub fn readPayload(self: *const ObjectStore, allocator: std.mem.Allocator, id: *const object_id.ObjectId) StoreError!Payload {
        switch (self.locate(id)) {
            .missing => return error.CorruptRepository,
            .loose => |i| {
                const o = &self.loose.objects.items[i];
                const header = loose_mod.resolveHeader(o) catch return error.CorruptRepository;
                return readLoosePayload(allocator, o.path, header);
            },
            .loose_path => |p| {
                const header = loose_mod.readHeaderFromPath(p) catch return error.CorruptRepository;
                return readLoosePayload(allocator, p, header);
            },
            .pack => |loc| {
                const pf = &self.packs.items[loc.pack_id];
                const r = pf.pack.readPayload(allocator, loc.offset, pf.payload_cache) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.CorruptRepository,
                };
                return .{ .object_type = r.object_type, .data = r.data };
            },
        }
    }

    fn readLoosePayload(allocator: std.mem.Allocator, path: []const u8, header: git_object.Header) StoreError!Payload {
        var mf = mmap.MappedFile.init(path) catch return error.CorruptRepository;
        defer mf.deinit();
        const size: usize = @intCast(header.size);
        const out = allocator.alloc(u8, size) catch return error.OutOfMemory;
        errdefer allocator.free(out);
        var in = Io.Reader.fixed(mf.data);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decomp = std.compress.flate.Decompress.init(&in, .zlib, &window);
        var first: [512]u8 = undefined;
        const n = decomp.reader.readSliceShort(&first) catch return error.CorruptRepository;
        const parsed = git_object.parseHeader(first[0..n]) catch return error.CorruptRepository;
        if (parsed.payload_start > n) return error.CorruptRepository;
        const avail = n - parsed.payload_start;
        const take = @min(avail, size);
        @memcpy(out[0..take], first[parsed.payload_start .. parsed.payload_start + take]);
        if (take < size) {
            decomp.reader.readSliceAll(out[take..]) catch return error.CorruptRepository;
        }
        return .{ .object_type = header.object_type, .data = out };
    }

    /// Physical (on-disk) size of an object: the loose file size, or the
    /// span between pack entry offsets.
    pub fn physicalSize(self: *const ObjectStore, id: *const object_id.ObjectId) StoreError!u64 {
        switch (self.locate(id)) {
            .missing => return error.CorruptRepository,
            .loose => |i| return self.loose.objects.items[i].file_size,
            .loose_path => |p| {
                const st = std.Io.Dir.cwd().statFile(io(), p, .{}) catch return error.CorruptRepository;
                return st.size;
            },
            .pack => |loc| {
                const pf = &self.packs.items[loc.pack_id];
                return pf.pack.nextOffsetAfter(loc.offset) - loc.offset;
            },
        }
    }

    /// Total number of distinct objects known to the store.
    pub fn objectCount(self: *const ObjectStore) usize {
        return self.locations.count();
    }
};

fn io() Io {
    return Io.Threaded.global_single_threaded.io();
}

pub const TypeStats = struct {
    count: u64 = 0,
    logical_bytes: u64 = 0,
};

pub const ObjectStats = struct {
    blob: TypeStats = .{},
    tree: TypeStats = .{},
    commit: TypeStats = .{},
    tag: TypeStats = .{},

    pub fn forType(self: *ObjectStats, t: git_object.ObjectType) *TypeStats {
        return switch (t) {
            .blob => &self.blob,
            .tree => &self.tree,
            .commit => &self.commit,
            .tag => &self.tag,
            else => unreachable,
        };
    }
};

/// Aggregate per-type counts and logical sizes across all objects.
pub fn computeStats(store: *const ObjectStore) StoreError!ObjectStats {
    var stats: ObjectStats = .{};
    var it = store.locations.iterator();
    while (it.next()) |e| {
        const inf = try store.info(&e.key_ptr.*);
        if (!inf.object_type.isReal()) continue;
        const s = stats.forType(inf.object_type);
        s.count += 1;
        s.logical_bytes += inf.size;
    }
    return stats;
}
