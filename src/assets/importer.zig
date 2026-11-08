//! Asset importers: transform source asset bytes into derived, engine-ready
//! artifacts.
//!
//! An `Importer` is a stable identity (`id` + `version`) plus a pure function
//! `source bytes -> derived bytes`. The version participates in the cache key,
//! so changing an importer's behavior and bumping its version invalidates the
//! affected cache entries automatically.
//!
//! Built-in importers shipped here are complete, honest transformations:
//! - `raw`  — identity copy for opaque binary assets (no decoder yet).
//! - `text` — UTF-8 validation, BOM removal and line-ending normalization.
//! - `json` — strict JSON validation (duplicate fields rejected) and lossless
//!            minified re-serialization.
//!
//! Format-specific decoders (texture/audio/model) and the scene importer are
//! registered by higher layers; this module depends only on the standard
//! library so it stays independently testable and loosely coupled.
//!
//! Ownership: import functions return bytes allocated with the passed
//! allocator; the caller frees them. Importers must not retain `source`.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ImportError = error{
    /// The source bytes are not valid for this importer.
    InvalidAsset,
    OutOfMemory,
};

/// A named, versioned source->derived transformation.
pub const Importer = struct {
    id: []const u8,
    version: u32,
    importFn: *const fn (gpa: Allocator, source: []const u8) ImportError![]u8,

    pub fn run(self: Importer, gpa: Allocator, source: []const u8) ImportError![]u8 {
        return self.importFn(gpa, source);
    }
};

/// A extension->importer registry with a fallback for unmatched extensions.
/// Selection is by file extension (case-insensitive, including the dot).
pub const Registry = struct {
    bindings: []const Binding,
    fallback: Importer,

    pub const Binding = struct {
        extensions: []const []const u8,
        importer: Importer,
    };

    pub fn select(self: Registry, ext: []const u8) Importer {
        for (self.bindings) |b| {
            for (b.extensions) |candidate| {
                if (std.ascii.eqlIgnoreCase(ext, candidate)) return b.importer;
            }
        }
        return self.fallback;
    }
};

// --- built-in importers ----------------------------------------------------

/// Identity importer for opaque binary assets. Stores the source verbatim; no
/// decoding is performed (decoders are registered by higher layers when they
/// exist). This is a complete, defined behavior, not a placeholder.
pub fn importRaw(gpa: Allocator, source: []const u8) ImportError![]u8 {
    return gpa.dupe(u8, source) catch return error.OutOfMemory;
}

pub const raw_importer = Importer{ .id = "raw", .version = 1, .importFn = importRaw };

/// Text importer: validate UTF-8, strip a leading UTF-8 BOM, and normalize
/// CRLF / lone CR line endings to LF. Rejects invalid UTF-8.
pub fn importText(gpa: Allocator, source: []const u8) ImportError![]u8 {
    var body = source;
    if (body.len >= 3 and body[0] == 0xEF and body[1] == 0xBB and body[2] == 0xBF) {
        body = body[3..];
    }
    if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidAsset;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    out.ensureTotalCapacity(gpa, body.len) catch return error.OutOfMemory;

    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '\r') {
            out.appendAssumeCapacity('\n');
            if (i + 1 < body.len and body[i + 1] == '\n') i += 1;
        } else {
            out.appendAssumeCapacity(c);
        }
    }
    return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

pub const text_importer = Importer{ .id = "text", .version = 1, .importFn = importText };

/// JSON importer: strictly validate (duplicate fields rejected) and re-serialize
/// losslessly in minified form. Numbers are preserved verbatim (no float
/// rounding). Rejects malformed JSON.
pub fn importJson(gpa: Allocator, source: []const u8) ImportError![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, source, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = source.len,
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAsset,
    };
    defer parsed.deinit();

    return std.json.Stringify.valueAlloc(gpa, parsed.value, .{ .whitespace = .minified }) catch
        return error.OutOfMemory;
}

pub const json_importer = Importer{ .id = "json", .version = 1, .importFn = importJson };

const text_extensions = [_][]const u8{
    ".txt",  ".csv",    ".xml",  ".md",   ".lua",
    ".glsl", ".vert",   ".frag", ".hlsl", ".wgsl",
    ".comp", ".shader",
};

/// The built-in extension bindings (JSON + text). Public so higher layers can
/// prepend format-specific importers (e.g. scenes) while reusing these.
pub const builtin_bindings = [_]Registry.Binding{
    .{ .extensions = &[_][]const u8{".json"}, .importer = json_importer },
    .{ .extensions = &text_extensions, .importer = text_importer },
};

/// The default registry: JSON and text importers, with `raw` as the fallback
/// for binary/unknown extensions. Higher layers extend this (e.g. with a scene
/// importer) via `Registry{ .bindings = ..., .fallback = raw_importer }`.
pub fn defaultRegistry() Registry {
    return .{ .bindings = &builtin_bindings, .fallback = raw_importer };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const alloc_probe = @import("../core/alloc_probe.zig");

test "raw importer copies bytes verbatim" {
    const src = [_]u8{ 0x00, 0xFF, 0x89, 'P', 'N', 'G', 0x0D, 0x0A };
    const out = try importRaw(testing.allocator, &src);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &src, out);
}

test "text importer normalizes CRLF and CR to LF" {
    const out = try importText(testing.allocator, "a\r\nb\rc\nd");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a\nb\nc\nd", out);
}

test "text importer strips a UTF-8 BOM" {
    const out = try importText(testing.allocator, "\xEF\xBB\xBFhello");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "text importer preserves valid multibyte UTF-8" {
    const out = try importText(testing.allocator, "a\xC3\xA7\xE2\x82\xACb");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a\xC3\xA7\xE2\x82\xACb", out);
}

test "text importer rejects invalid UTF-8" {
    try testing.expectError(error.InvalidAsset, importText(testing.allocator, "ok\xFF\xFEbad"));
}

test "text importer handles empty input" {
    const out = try importText(testing.allocator, "");
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "json importer minifies losslessly" {
    const out = try importJson(testing.allocator, "{ \"a\" : 1,  \"b\" : [1, 2, 3] }");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"a\":1,\"b\":[1,2,3]}", out);
}

test "json importer preserves large integers verbatim" {
    const out = try importJson(testing.allocator, "{\"n\":123456789012345678901234567890}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"n\":123456789012345678901234567890}", out);
}

test "json importer rejects duplicate fields" {
    try testing.expectError(error.InvalidAsset, importJson(testing.allocator, "{\"a\":1,\"a\":2}"));
}

test "json importer rejects malformed JSON" {
    try testing.expectError(error.InvalidAsset, importJson(testing.allocator, "{not json"));
}

test "registry selects by extension case-insensitively" {
    const reg = defaultRegistry();
    try testing.expectEqualStrings("json", reg.select(".json").id);
    try testing.expectEqualStrings("json", reg.select(".JSON").id);
    try testing.expectEqualStrings("text", reg.select(".lua").id);
    try testing.expectEqualStrings("text", reg.select(".GLSL").id);
    try testing.expectEqualStrings("raw", reg.select(".png").id);
    try testing.expectEqualStrings("raw", reg.select(".unknown").id);
    try testing.expectEqualStrings("raw", reg.select("").id);
}

test "registry fallback is used for unmatched extensions" {
    const reg = Registry{ .bindings = &.{}, .fallback = raw_importer };
    try testing.expectEqualStrings("raw", reg.select(".json").id);
}

test "importers survive allocation failure" {
    try alloc_probe.check(
        struct {
            fn f(alloc: Allocator) !void {
                const t = try importText(alloc, "a\r\nb\xC3\xA7");
                alloc.free(t);
                const j = try importJson(alloc, "{\"a\":[1,2,3]}");
                alloc.free(j);
                const r = try importRaw(alloc, "bytes");
                alloc.free(r);
            }
        }.f,
        .{},
    );
}
