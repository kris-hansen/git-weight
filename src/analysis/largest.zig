const std = @import("std");
const object_id = @import("../git/object_id.zig");
const object_store = @import("objects.zig");
const paths_mod = @import("paths.zig");

pub const LargestError = error{
    OutOfMemory,
    CorruptRepository,
    Unexpected,
};

pub const Status = enum {
    current,
    historical,

    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .current => "current",
            .historical => "historical",
        };
    }
};

pub const BlobEntry = struct {
    id: object_id.ObjectId,
    size: u64,
    /// Representative path, or null if the blob was not found in any
    /// reachable history tree.
    path: ?[]const u8,
    status: Status,
    /// Whether the blob is a Git LFS candidate (see isLfsCandidate).
    lfs_candidate: bool,
};

/// Logical size at or above which a blob is a Git LFS candidate regardless
/// of its path.
pub const lfs_size_threshold: u64 = 5 * 1024 * 1024;

/// Known-binary extensions: blobs with one of these extensions belong in
/// Git LFS even below the size threshold (database dumps included — they do
/// not diff or merge usefully).
const lfs_extensions = [_][]const u8{
    "png",  "jpg",  "jpeg", "gif",  "bmp",  "ico",  "webp", "tiff",
    "pdf",  "psd",  "ai",
    "zip",  "gz",   "tgz",  "bz2",  "xz",   "7z",   "rar",  "tar",
    "mp4",  "mov",  "avi",  "mkv",  "webm", "mp3",  "wav",  "flac", "ogg",
    "so",   "dll",  "dylib", "exe",  "o",    "a",    "class", "jar",
    "pyc",  "pyo",  "whl",  "wasm",
    "woff", "woff2", "ttf", "otf", "eot",
    "parquet", "h5", "onnx", "pkl", "sql",
};

/// File extension (after the final '.', excluding dotfiles and trailing
/// dots), lowercased by the caller's comparison, or null when absent.
pub fn extensionOf(path: []const u8) ?[]const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    if (dot == 0 or dot == base.len - 1) return null;
    return base[dot + 1 ..];
}

/// Git LFS candidate heuristic: logical size at or above 5 MiB, or any
/// known-binary extension. Paths are optional — a large extensionless blob
/// still qualifies via its size.
pub fn isLfsCandidate(size: u64, path: ?[]const u8) bool {
    if (size >= lfs_size_threshold) return true;
    const ext = extensionOf(path orelse return false) orelse return false;
    for (lfs_extensions) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

pub const Filter = enum {
    all,
    current_only,
    historical_only,
};

pub fn sizeGreater(_: void, a: BlobEntry, b: BlobEntry) std.math.Order {
    return std.math.order(a.size, b.size); // min-heap by size: peek = smallest
}

/// Deterministic presentation order: size descending, ties by oid ascending.
pub fn entryOrderDesc(_: void, a: BlobEntry, b: BlobEntry) bool {
    if (a.size != b.size) return a.size > b.size;
    return std.mem.order(u8, a.id.bytes[0..a.id.rawLen()], b.id.bytes[0..b.id.rawLen()]) == .lt;
}

test "isLfsCandidate size threshold" {
    const just_under = lfs_size_threshold - 1;
    try std.testing.expect(isLfsCandidate(lfs_size_threshold, null));
    try std.testing.expect(isLfsCandidate(lfs_size_threshold, "src/main.zig"));
    try std.testing.expect(isLfsCandidate(just_under, "assets/blob.bin") == false); // .bin unknown
    try std.testing.expect(isLfsCandidate(just_under, null) == false);
}

test "isLfsCandidate known-binary extensions" {
    try std.testing.expect(isLfsCandidate(1024, "assets/demo.mov"));
    try std.testing.expect(isLfsCandidate(1024, "photo.PNG")); // case-insensitive
    try std.testing.expect(isLfsCandidate(1024, "deep/nested/dir/archive.tar.gz")); // final ext .gz
    try std.testing.expect(isLfsCandidate(1024, "database/prod.sql"));
    try std.testing.expect(isLfsCandidate(1024, "lib/native.so"));
}

test "isLfsCandidate rejects non-candidates" {
    try std.testing.expect(isLfsCandidate(1024, "README.md") == false);
    try std.testing.expect(isLfsCandidate(1024, "Makefile") == false); // no extension
    try std.testing.expect(isLfsCandidate(1024, ".gitignore") == false); // dotfile
    try std.testing.expect(isLfsCandidate(1024, "notes.") == false); // trailing dot
    try std.testing.expect(isLfsCandidate(1024, null) == false);
}

test "extensionOf" {
    try std.testing.expectEqualStrings("sql", extensionOf("database/prod.sql").?);
    try std.testing.expectEqualStrings("gz", extensionOf("a/b/c.tar.gz").?);
    try std.testing.expect(extensionOf("noext") == null);
    try std.testing.expect(extensionOf(".hidden") == null);
    try std.testing.expect(extensionOf("trailing.") == null);
}
