//! Content-addressed artifact cache for the asset import pipeline.
//!
//! Imported (derived) asset data is stored under a key derived from the source
//! content hash, the importer identity and version, and an options hash. This
//! makes the cache incremental and reproducible: unchanged source + unchanged
//! importer => cache hit, no re-import. Bumping an importer version or the cache
//! format version invalidates affected entries automatically.
//!
//! On-disk layout: one self-describing file per key, named by the lowercase hex
//! digest. Each file is a small binary header + a JSON metadata object + the raw
//! payload:
//!
//!   magic "CXAC" (4 bytes) | format_version u32 LE | meta_len u32 LE | meta | payload
//!
//! Writes are atomic (temp file + rename). Reads verify the payload hash and
//! size recorded in the metadata; a corrupt or truncated entry is reported as a
//! miss so the pipeline re-imports it (self-healing).
//!
//! This module depends only on the standard library (low coupling). It does not
//! know about asset kinds or importers; callers pass opaque strings/hashes.
//!
//! Ownership: a `Cache` owns an open directory handle and a temp-file counter.
//! Initialize with `open`, release with `deinit`. It is used by reference and
//! must not be copied after `open`. `get` returns payload bytes owned by the
//! caller (free with the same allocator).

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Blake3 = std.crypto.hash.Blake3;

/// Cache on-disk format version. Bump to invalidate all existing entries.
pub const format_version: u32 = 1;

/// Maximum accepted cache file size (256 MiB). Bounds memory on read.
pub const max_cache_file_bytes: usize = 256 * 1024 * 1024;

const magic = "CXAC";
const header_len = 12;

pub const Key = [32]u8;
pub const key_hex_len = 64;

pub const Error = error{
    CacheIo,
    OutOfMemory,
    Canceled,
};

/// Hash arbitrary bytes with BLAKE3-256.
pub fn hashBytes(data: []const u8) Key {
    var key: Key = undefined;
    Blake3.hash(data, &key, .{});
    return key;
}

/// Derive a cache key from the source hash, importer identity/version and an
/// options hash. A domain separator and the format version are folded in so
/// keys never collide across cache formats or unrelated subsystems.
pub fn deriveKey(source_hash: Key, importer_id: []const u8, importer_version: u32, options_hash: Key) Key {
    var hasher = Blake3.init(.{});
    hasher.update("corex-asset-cache-v" ++ std.fmt.comptimePrint("{d}", .{format_version}));
    hasher.update(&source_hash);
    hasher.update(importer_id);
    var version_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &version_bytes, importer_version, .little);
    hasher.update(&version_bytes);
    hasher.update(&options_hash);
    var key: Key = undefined;
    hasher.final(&key);
    return key;
}

/// Lowercase hex encoding of a key (filename-safe).
pub fn keyHex(key: Key) [key_hex_len]u8 {
    return std.fmt.bytesToHex(key, .lower);
}

/// Source-side inputs recorded in an entry's metadata. The cache computes the
/// output hash/size and the key hex itself.
pub const PutInfo = struct {
    path: []const u8,
    source_hash: Key,
    importer_id: []const u8,
    importer_version: u32,
    kind: []const u8,
};

const Meta = struct {
    key: []const u8,
    source_path: []const u8,
    source_hash: []const u8,
    importer: []const u8,
    importer_version: u32,
    output_hash: []const u8,
    output_size: u64,
    kind: []const u8,
};

pub const Cache = struct {
    io: Io,
    dir: Io.Dir,
    tmp_counter: std.atomic.Value(u64),

    /// Open (creating if needed) the cache directory at `path`.
    pub fn open(io: Io, path: []const u8) Error!Cache {
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(io, path) catch return error.CacheIo;
        const dir = if (std.fs.path.isAbsolute(path))
            Io.Dir.openDirAbsolute(io, path, .{}) catch return error.CacheIo
        else
            cwd.openDir(io, path, .{}) catch return error.CacheIo;
        return .{ .io = io, .dir = dir, .tmp_counter = .init(0) };
    }

    pub fn deinit(self: *Cache) void {
        self.dir.close(self.io);
        self.* = undefined;
    }

    /// Read and verify the artifact for `key`. Returns null on miss or on a
    /// corrupt/truncated entry (self-healing: the caller re-imports). Caller
    /// owns the returned bytes.
    pub fn get(self: *Cache, gpa: Allocator, key: Key) Error!?[]u8 {
        const hex = keyHex(key);
        const data = self.dir.readFileAlloc(self.io, &hex, gpa, .limited(max_cache_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CacheIo,
        };
        defer gpa.free(data);

        const payload = verify(gpa, data, key) orelse return null;
        return gpa.dupe(u8, payload) catch return error.OutOfMemory;
    }

    /// Whether a valid entry exists for `key`. Reads and verifies like `get`
    /// but discards the payload.
    pub fn has(self: *Cache, gpa: Allocator, key: Key) Error!bool {
        const bytes = try self.get(gpa, key);
        if (bytes) |b| {
            gpa.free(b);
            return true;
        }
        return false;
    }

    /// Store `payload` under `key` atomically. `tmp_suffix` distinguishes
    /// concurrent writers staging the same key; pass a unique value per task.
    pub fn put(self: *Cache, gpa: Allocator, key: Key, info: PutInfo, payload: []const u8, tmp_suffix: u64) Error!void {
        const hex = keyHex(key);
        const output_hash = hashBytes(payload);
        const output_hex = keyHex(output_hash);
        const source_hex = keyHex(info.source_hash);

        const meta = Meta{
            .key = &hex,
            .source_path = info.path,
            .source_hash = &source_hex,
            .importer = info.importer_id,
            .importer_version = info.importer_version,
            .output_hash = &output_hex,
            .output_size = payload.len,
            .kind = info.kind,
        };
        const meta_bytes = std.json.Stringify.valueAlloc(gpa, meta, .{ .whitespace = .minified }) catch
            return error.OutOfMemory;
        defer gpa.free(meta_bytes);

        var header: [header_len]u8 = undefined;
        @memcpy(header[0..4], magic);
        std.mem.writeInt(u32, header[4..8], format_version, .little);
        std.mem.writeInt(u32, header[8..12], @intCast(meta_bytes.len), .little);

        const suffix = self.tmp_counter.fetchAdd(1, .monotonic) +% tmp_suffix;
        const tmp_name = std.fmt.allocPrint(gpa, "{s}.tmp.{d}", .{ hex, suffix }) catch return error.OutOfMemory;
        defer gpa.free(tmp_name);

        var file = self.dir.createFile(self.io, tmp_name, .{}) catch return error.CacheIo;
        var closed = false;
        errdefer {
            if (!closed) file.close(self.io);
            self.dir.deleteFile(self.io, tmp_name) catch {};
        }
        file.writeStreamingAll(self.io, &header) catch return error.CacheIo;
        file.writeStreamingAll(self.io, meta_bytes) catch return error.CacheIo;
        file.writeStreamingAll(self.io, payload) catch return error.CacheIo;
        file.close(self.io);
        closed = true;

        self.dir.rename(tmp_name, self.dir, &hex, self.io) catch return error.CacheIo;
    }

    /// Remove the entry for `key` if present. Missing entries are not an error.
    pub fn remove(self: *Cache, key: Key) Error!void {
        const hex = keyHex(key);
        self.dir.deleteFile(self.io, &hex) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.CacheIo,
        };
    }
};

/// Validate a raw cache file image and return its payload slice, or null if the
/// image is corrupt, truncated, for a different key, or a different format.
fn verify(gpa: Allocator, data: []const u8, key: Key) ?[]const u8 {
    if (data.len < header_len) return null;
    if (!std.mem.eql(u8, data[0..4], magic)) return null;
    const version = std.mem.readInt(u32, data[4..8], .little);
    if (version != format_version) return null;
    const meta_len = std.mem.readInt(u32, data[8..12], .little);
    if (meta_len > data.len - header_len) return null;

    const meta_bytes = data[header_len .. header_len + meta_len];
    const payload = data[header_len + meta_len ..];

    var parsed = std.json.parseFromSlice(Meta, gpa, meta_bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = meta_bytes.len,
    }) catch return null;
    defer parsed.deinit();
    const meta = parsed.value;

    const hex = keyHex(key);
    if (!std.mem.eql(u8, meta.key, &hex)) return null;
    if (meta.output_size != payload.len) return null;

    var stored_hash: Key = undefined;
    const decoded = std.fmt.hexToBytes(&stored_hash, meta.output_hash) catch return null;
    if (decoded.len != stored_hash.len) return null;
    const actual_hash = hashBytes(payload);
    if (!std.mem.eql(u8, &stored_hash, &actual_hash)) return null;

    return payload;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn testCache(dir_path: []const u8) !Cache {
    return Cache.open(testing.io, dir_path);
}

test "hashBytes is deterministic and sensitive to content" {
    const a = hashBytes("hello");
    const b = hashBytes("hello");
    const c = hashBytes("hellp");
    try testing.expectEqualSlices(u8, &a, &b);
    try testing.expect(!std.mem.eql(u8, &a, &c));
}

test "deriveKey separates source, importer, version and options" {
    const sh = hashBytes("source");
    const oh = hashBytes("");
    const base = deriveKey(sh, "text", 1, oh);
    try testing.expect(!std.mem.eql(u8, &base, &deriveKey(hashBytes("other"), "text", 1, oh)));
    try testing.expect(!std.mem.eql(u8, &base, &deriveKey(sh, "json", 1, oh)));
    try testing.expect(!std.mem.eql(u8, &base, &deriveKey(sh, "text", 2, oh)));
    try testing.expect(!std.mem.eql(u8, &base, &deriveKey(sh, "text", 1, hashBytes("opt"))));
    try testing.expectEqualSlices(u8, &base, &deriveKey(sh, "text", 1, oh));
}

test "cache: put then get round-trips payload" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var cache = try testCache(buf[0..n]);
    defer cache.deinit();

    const key = deriveKey(hashBytes("src"), "text", 1, hashBytes(""));
    const payload = "normalized text payload";
    try cache.put(testing.allocator, key, .{
        .path = "assets/a.txt",
        .source_hash = hashBytes("src"),
        .importer_id = "text",
        .importer_version = 1,
        .kind = "data",
    }, payload, 0);

    const got = (try cache.get(testing.allocator, key)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(payload, got);
    try testing.expect(try cache.has(testing.allocator, key));
}

test "cache: get on missing key returns null" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var cache = try testCache(buf[0..n]);
    defer cache.deinit();

    const key = deriveKey(hashBytes("absent"), "text", 1, hashBytes(""));
    try testing.expectEqual(@as(?[]u8, null), try cache.get(testing.allocator, key));
    try testing.expect(!try cache.has(testing.allocator, key));
}

test "cache: importer version bump invalidates the key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var cache = try testCache(buf[0..n]);
    defer cache.deinit();

    const sh = hashBytes("src");
    const oh = hashBytes("");
    const k1 = deriveKey(sh, "text", 1, oh);
    const k2 = deriveKey(sh, "text", 2, oh);
    try cache.put(testing.allocator, k1, .{
        .path = "a.txt",
        .source_hash = sh,
        .importer_id = "text",
        .importer_version = 1,
        .kind = "data",
    }, "v1", 0);
    try testing.expect(try cache.has(testing.allocator, k1));
    try testing.expect(!try cache.has(testing.allocator, k2));
}

test "cache: corrupt payload is detected as a miss" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var cache = try testCache(buf[0..n]);
    defer cache.deinit();

    const key = deriveKey(hashBytes("src"), "text", 1, hashBytes(""));
    try cache.put(testing.allocator, key, .{
        .path = "a.txt",
        .source_hash = hashBytes("src"),
        .importer_id = "text",
        .importer_version = 1,
        .kind = "data",
    }, "payload", 0);

    // Flip a payload byte on disk (last byte of the file).
    const hex = keyHex(key);
    const data = try tmp.dir.readFileAlloc(testing.io, &hex, testing.allocator, .limited(max_cache_file_bytes));
    defer testing.allocator.free(data);
    data[data.len - 1] ^= 0xFF;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = &hex, .data = data });

    try testing.expectEqual(@as(?[]u8, null), try cache.get(testing.allocator, key));
}

test "cache: truncated file is detected as a miss" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var cache = try testCache(buf[0..n]);
    defer cache.deinit();

    const key = deriveKey(hashBytes("src"), "text", 1, hashBytes(""));
    try cache.put(testing.allocator, key, .{
        .path = "a.txt",
        .source_hash = hashBytes("src"),
        .importer_id = "text",
        .importer_version = 1,
        .kind = "data",
    }, "payload", 0);

    const hex = keyHex(key);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = &hex, .data = "CXAC" });
    try testing.expectEqual(@as(?[]u8, null), try cache.get(testing.allocator, key));
}

test "cache: put overwrites an existing entry atomically" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var cache = try testCache(buf[0..n]);
    defer cache.deinit();

    const key = deriveKey(hashBytes("src"), "text", 1, hashBytes(""));
    const info = PutInfo{ .path = "a.txt", .source_hash = hashBytes("src"), .importer_id = "text", .importer_version = 1, .kind = "data" };
    try cache.put(testing.allocator, key, info, "first", 0);
    try cache.put(testing.allocator, key, info, "second-longer", 1);

    const got = (try cache.get(testing.allocator, key)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("second-longer", got);
}

test "cache: remove deletes an entry and tolerates missing keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var cache = try testCache(buf[0..n]);
    defer cache.deinit();

    const key = deriveKey(hashBytes("src"), "text", 1, hashBytes(""));
    try cache.put(testing.allocator, key, .{
        .path = "a.txt",
        .source_hash = hashBytes("src"),
        .importer_id = "text",
        .importer_version = 1,
        .kind = "data",
    }, "payload", 0);
    try cache.remove(key);
    try testing.expect(!try cache.has(testing.allocator, key));
    try cache.remove(key); // no error on missing
}

test "cache: empty payload round-trips" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var cache = try testCache(buf[0..n]);
    defer cache.deinit();

    const key = deriveKey(hashBytes(""), "raw", 1, hashBytes(""));
    try cache.put(testing.allocator, key, .{
        .path = "a.bin",
        .source_hash = hashBytes(""),
        .importer_id = "raw",
        .importer_version = 1,
        .kind = "unknown",
    }, "", 0);
    const got = (try cache.get(testing.allocator, key)).?;
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}
