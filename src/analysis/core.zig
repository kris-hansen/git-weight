//! Git-free repository complexity scoring core.
//! Depends only on `std` and `domain_complexity.zig`, so it builds for wasm32-freestanding.
//! Feed it (path, bytes) pairs from any source: git trees, a tarball, a zip, or the filesystem.
const std = @import("std");
pub const domain = @import("domain_complexity.zig");

pub const score_version = "complexity-2";

/// Counted signals and derived scores for one snapshot of a source tree.
pub const Metrics = struct {
    total_points: u64 = 0,
    size_points: u64 = 0,
    structural_points: u64 = 0,
    domain_points: u64 = 0,
    points_per_kloc: u64 = 0,
    structural_points_per_kloc: u64 = 0,
    domain_points_per_kloc: u64 = 0,
    source_files: u64 = 0,
    source_lines: u64 = 0,
    branch_lines: u64 = 0,
    internal_imports: u64 = 0,
    external_host_references: u64 = 0,
    dependency_manifests: u64 = 0,
    ui_components: u64 = 0,
    crypto_files: u64 = 0,
    algorithm_files: u64 = 0,
    excluded_files: u64 = 0,
    binary_files: u64 = 0,
    terraform_files: u64 = 0,
    sql_files: u64 = 0,
    sql_migration_files: u64 = 0,
    domain_counts: domain.Counts = .{},
};

pub fn source(path: []const u8) bool {
    if (domain.isTerraform(path) or domain.isSql(path)) return true;
    const extensions = [_][]const u8{ ".zig", ".go", ".py", ".js", ".jsx", ".ts", ".tsx", ".vue", ".svelte", ".java", ".kt", ".swift", ".rs", ".c", ".cc", ".cpp", ".h", ".hpp", ".cs", ".rb", ".php", ".sh" };
    for (extensions) |ext| if (std.mem.endsWith(u8, path, ext)) return true;
    return false;
}

pub fn excluded(path: []const u8) bool {
    const parts = [_][]const u8{ "vendor/", "node_modules/", "dist/", "build/", "generated/", ".gen.", "_generated.", ".min." };
    for (parts) |part| if (std.mem.indexOf(u8, path, part) != null) return true;
    return false;
}

pub fn dependencyManifest(path: []const u8) bool {
    const names = [_][]const u8{ "package.json", "go.mod", "Cargo.toml", "pyproject.toml", "requirements.txt", "Gemfile", "build.zig.zon", "Package.swift" };
    for (names) |name| if (std.mem.endsWith(u8, path, name)) return true;
    return false;
}

pub fn uiComponent(path: []const u8) bool {
    const ui = std.mem.endsWith(u8, path, ".tsx") or std.mem.endsWith(u8, path, ".jsx") or std.mem.endsWith(u8, path, ".vue") or std.mem.endsWith(u8, path, ".svelte");
    return ui and (std.mem.indexOf(u8, path, "components/") != null or std.mem.indexOf(u8, path, "Components/") != null);
}

fn containsAny(line: []const u8, words: []const []const u8) bool {
    for (words) |word| if (std.mem.indexOf(u8, line, word) != null) return true;
    return false;
}

fn branchLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const words = [_][]const u8{ "if ", "if(", "else if", "elif ", "for ", "for(", "while ", "while(", "case ", "catch ", "catch(", "except ", "switch ", "switch(", "match " };
    for (words) |word| if (std.mem.startsWith(u8, trimmed, word)) return true;
    return false;
}

fn scanFile(allocator: std.mem.Allocator, path: []const u8, text: []const u8, go_module_prefix: ?[]const u8, report: *Metrics) !void {
    var seen_imports: std.StringHashMapUnmanaged(void) = .empty;
    var seen_hosts: std.StringHashMapUnmanaged(void) = .empty;
    var crypto = false;
    var algorithm = false;
    const domain_file = domain.isTerraform(path) or domain.isSql(path);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        report.source_lines += 1;
        if (branchLine(line)) report.branch_lines += 1;
        if (domain_file) continue; // Domain-specific scanner owns these signals.
        const is_import = containsAny(line, &.{ "import ", "from ", "require(", "@import(", "#include " });
        const local_import = (is_import and containsAny(line, &.{ "./", "../", "@/", "crate::", "self::", "super::" })) or
            (std.mem.endsWith(u8, path, ".go") and go_module_prefix != null and std.mem.indexOf(u8, line, go_module_prefix.?) != null);
        if (local_import) {
            const entry = try seen_imports.getOrPut(allocator, line);
            if (!entry.found_existing) report.internal_imports += 1;
        }
        if (std.mem.indexOf(u8, line, "https://") orelse std.mem.indexOf(u8, line, "http://")) |start| {
            const scheme_len: usize = if (std.mem.startsWith(u8, line[start..], "https://")) 8 else 7;
            const rest = line[start + scheme_len ..];
            const end = std.mem.indexOfAny(u8, rest, "/\"' \t:)}") orelse rest.len;
            const host = rest[0..end];
            if (host.len > 0 and !std.mem.eql(u8, host, "localhost")) {
                const entry = try seen_hosts.getOrPut(allocator, host);
                if (!entry.found_existing) report.external_host_references += 1;
            }
        }
        if (containsAny(line, &.{ "crypto", "Crypto", "cipher", "Cipher", "encrypt", "decrypt", "signature", "hmac", "HMAC" })) crypto = true;
        if (containsAny(line, &.{ "algorithm", "Algorithm", "state machine", "binarySearch", "dijkstra", "quicksort", "dynamic programming" })) algorithm = true;
    }
    if (crypto) report.crypto_files += 1;
    if (algorithm) report.algorithm_files += 1;
}

/// Extract the `module` path from go.mod contents, returned as "<module>/".
pub fn goModulePrefix(allocator: std.mem.Allocator, go_mod: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, go_mod, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "module ")) continue;
        const module = std.mem.trim(u8, line[7..], " \t");
        if (module.len > 0) return try std.fmt.allocPrint(allocator, "{s}/", .{module});
    }
    return null;
}

/// Streaming scorer: begin, then `wants`/`addFile` for every blob path, then finish.
pub const Scanner = struct {
    metrics: Metrics = .{},
    go_module_prefix: ?[]const u8 = null,

    pub fn begin(go_module_prefix: ?[]const u8) Scanner {
        return .{ .go_module_prefix = go_module_prefix };
    }

    /// Records path-only signals and reports whether the file's contents should be scored.
    /// Call once per blob path; when it returns true, call `addFile` with the contents.
    pub fn wants(self: *Scanner, path: []const u8) bool {
        if (excluded(path)) {
            self.metrics.excluded_files += 1;
            return false;
        }
        if (dependencyManifest(path)) self.metrics.dependency_manifests += 1;
        if (!source(path)) {
            self.metrics.excluded_files += 1;
            return false;
        }
        return true;
    }

    /// Scores one wanted file. `allocator` may be an arena; memory is not freed per file.
    pub fn addFile(self: *Scanner, allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
        const report = &self.metrics;
        if (std.mem.indexOfScalar(u8, data, 0) != null) {
            report.binary_files += 1;
            return;
        }
        report.source_files += 1;
        if (domain.isTerraform(path)) report.terraform_files += 1;
        if (domain.isSql(path)) {
            report.sql_files += 1;
            if (std.mem.indexOf(u8, path, "migration") != null) report.sql_migration_files += 1;
        }
        if (uiComponent(path)) report.ui_components += 1;
        try scanFile(allocator, path, data, self.go_module_prefix, report);
        report.domain_counts.add(try domain.scan(allocator, path, data));
    }

    pub fn finish(self: *Scanner) Metrics {
        var report = self.metrics;
        report.size_points = report.source_lines;
        report.structural_points = 4 * report.branch_lines + 3 * report.source_files +
            6 * report.internal_imports + 12 * report.external_host_references +
            4 * report.dependency_manifests + 6 * report.ui_components +
            10 * report.crypto_files + 8 * report.algorithm_files;
        report.domain_points = report.domain_counts.points();
        report.total_points = report.size_points + report.structural_points + report.domain_points;
        if (report.source_lines > 0) {
            report.points_per_kloc = (report.total_points * 1000 + report.source_lines / 2) / report.source_lines;
            report.structural_points_per_kloc = (report.structural_points * 1000 + report.source_lines / 2) / report.source_lines;
            report.domain_points_per_kloc = (report.domain_points * 1000 + report.source_lines / 2) / report.source_lines;
        }
        return report;
    }
};

test "snapshot counts active signals, not removed files" {
    var report: Metrics = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try scanFile(arena.allocator(), "src/app.ts", "import x from './lib';\nif (x) {\nhttps://partner.example/v1\ncrypto.encrypt(x)\n", null, &report);
    try std.testing.expectEqual(@as(u64, 4), report.source_lines);
    try std.testing.expectEqual(@as(u64, 1), report.branch_lines);
    try std.testing.expectEqual(@as(u64, 1), report.internal_imports);
    try std.testing.expectEqual(@as(u64, 1), report.external_host_references);
    try std.testing.expectEqual(@as(u64, 1), report.crypto_files);
}

test "go module imports count as internal coupling" {
    var report: Metrics = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try scanFile(arena.allocator(), "src/main.go", "\"example.com/project/internal/api\"\n\"net/http\"\n", "example.com/project/", &report);
    try std.testing.expectEqual(@as(u64, 1), report.internal_imports);
}

test "scanner matches in-memory snapshot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = Scanner.begin(null);
    try std.testing.expect(s.wants("src/app.ts"));
    try s.addFile(arena.allocator(), "src/app.ts", "import x from './lib';\nif (x) {}\n");
    try std.testing.expect(!s.wants("node_modules/a.js"));
    try std.testing.expect(!s.wants("README.md"));
    const m = s.finish();
    try std.testing.expectEqual(@as(u64, 1), m.source_files);
    try std.testing.expectEqual(@as(u64, 2), m.excluded_files);
    try std.testing.expectEqual(m.size_points + m.structural_points + m.domain_points, m.total_points);
}
