//! Engine-ready mesh artifact (`CXMH`) and the OBJ mesh importer.
//!
//! The importer decodes a Wavefront OBJ source (geometry-only subset) into an
//! indexed triangle mesh with interleaved position/normal/UV vertices, then
//! serializes it into a self-describing `CXMH` container the renderer can upload
//! without re-parsing the source. The container is the derived artifact stored
//! in the content-addressed cache; its identity is the importer `id` + `version`,
//! so changing the layout and bumping the version invalidates affected entries.
//!
//! OBJ subset (documented, honest — unsupported features are skipped, not faked):
//! - `v x y z [w]`   positions (w ignored); `vn x y z` normals (normalized);
//!   `vt u v [w]`    UVs (w ignored, passed through unchanged).
//! - `f a b c ...`   polygonal faces, fan-triangulated. Corners may be `v`,
//!   `v/vt`, `v//vn` or `v/vt/vn`; indices are 1-based, negative = relative to
//!   the current end. Missing normals get a flat per-face normal; missing UVs
//!   get (0,0). Vertices are deduplicated by (position, uv, normal) reference.
//! - `#` comments, blank lines, CRLF, and group/material directives (`o`, `g`,
//!   `s`, `usemtl`, `mtllib`, ...) are skipped — materials are future work.
//!
//! Layout (little-endian):
//!   bytes 0..4    magic "CXMH"
//!   bytes 4..8    format_version (u32 = 1)
//!   bytes 8..12   vertex_format  (u32 = 0, p3n3t2: pos3+normal3+uv2, all f32)
//!   bytes 12..16  vertex_count   (u32)
//!   bytes 16..20  index_count    (u32, multiple of 3)
//!   bytes 20..32  bounds_min     ([3]f32)
//!   bytes 32..44  bounds_max     ([3]f32)
//!   bytes 44..    vertex_count*32 interleaved f32 vertices, then
//!                 index_count*4 u32 indices (triangle list)
//!
//! `parse` is zero-copy and alignment-safe: it returns byte views plus accessors
//! that read little-endian fields explicitly (no pointer casts), and validates
//! structure, index range and float finiteness in one linear pass so downstream
//! consumers never see an out-of-range index or a NaN. This module depends only
//! on `std` and `importer.zig`, so it stays independently testable.

const std = @import("std");
const importer = @import("importer.zig");

const Allocator = std.mem.Allocator;
const ImportError = importer.ImportError;
const Importer = importer.Importer;

pub const DecodeError = error{
    /// The source bytes are not a valid OBJ mesh of the supported subset.
    InvalidMesh,
    OutOfMemory,
};

/// Maximum vertices accepted (4M * 32 B = 128 MB vertex buffer).
pub const max_vertices: u32 = 4_000_000;
/// Maximum indices accepted (12M * 4 B = 48 MB index buffer).
pub const max_indices: u32 = 12_000_000;

pub const format_version: u32 = 1;
pub const magic = "CXMH";
pub const header_size: usize = 44;

/// Interleaved vertex layout: position(3) + normal(3) + uv(2), all f32.
pub const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    uv: [2]f32,
};
pub const vertex_stride: usize = @sizeOf(Vertex);
comptime {
    std.debug.assert(vertex_stride == 32);
}

/// Vertex layout selector stored in the artifact. Only p3n3t2 exists today.
pub const VertexFormat = enum(u32) {
    p3n3t2 = 0,
};

/// An owned, decoded indexed triangle mesh. The caller frees it with `deinit`.
pub const Mesh = struct {
    vertices: []Vertex,
    indices: []u32,
    bounds_min: [3]f32,
    bounds_max: [3]f32,

    pub fn deinit(self: *Mesh, gpa: Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.indices);
        self.* = undefined;
    }

    pub fn triangleCount(self: Mesh) usize {
        return self.indices.len / 3;
    }
};

/// A parsed, zero-copy view into a `CXMH` artifact. The caller owns the backing
/// bytes; this struct holds no allocation. Accessors read little-endian fields
/// explicitly, so they are safe regardless of the backing buffer's alignment.
pub const MeshView = struct {
    vertex_count: u32,
    index_count: u32,
    bounds_min: [3]f32,
    bounds_max: [3]f32,
    vertex_bytes: []const u8,
    index_bytes: []const u8,

    pub fn triangleCount(self: MeshView) u32 {
        return self.index_count / 3;
    }

    pub fn vertexAt(self: MeshView, i: usize) Vertex {
        const base = i * vertex_stride;
        const b = self.vertex_bytes;
        return .{
            .position = .{ readF32(b, base), readF32(b, base + 4), readF32(b, base + 8) },
            .normal = .{ readF32(b, base + 12), readF32(b, base + 16), readF32(b, base + 20) },
            .uv = .{ readF32(b, base + 24), readF32(b, base + 28) },
        };
    }

    pub fn indexAt(self: MeshView, i: usize) u32 {
        return std.mem.readInt(u32, self.index_bytes[i * 4 ..][0..4], .little);
    }
};

fn readF32(bytes: []const u8, off: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[off..][0..4], .little));
}

fn writeF32(bytes: []u8, off: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[off..][0..4], @bitCast(value), .little);
}

fn finite3(v: [3]f32) bool {
    return std.math.isFinite(v[0]) and std.math.isFinite(v[1]) and std.math.isFinite(v[2]);
}

// --- OBJ decoding ----------------------------------------------------------

const CornerRef = struct { v: u32, vt: u32, vn: u32 };

fn parseFiniteF32(tok: []const u8) DecodeError!f32 {
    const f = std.fmt.parseFloat(f32, tok) catch return error.InvalidMesh;
    if (!std.math.isFinite(f)) return error.InvalidMesh;
    return f;
}

/// Resolve a 1-based (possibly negative/relative) OBJ index against `count`.
/// Returns a 1-based index, or `error.InvalidMesh` if out of range or zero.
fn resolveIndex(tok: []const u8, count: usize) DecodeError!u32 {
    const n = std.fmt.parseInt(i64, tok, 10) catch return error.InvalidMesh;
    if (n == 0) return error.InvalidMesh;
    const resolved: i64 = if (n < 0) @as(i64, @intCast(count)) + n + 1 else n;
    if (resolved < 1 or resolved > @as(i64, @intCast(count))) return error.InvalidMesh;
    return @intCast(resolved);
}

fn parseCorner(tok: []const u8, npos: usize, nvt: usize, nvn: usize) DecodeError!CornerRef {
    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, tok, '/');
    while (it.next()) |part| {
        if (count == 3) return error.InvalidMesh; // more than v/vt/vn
        parts[count] = part;
        count += 1;
    }
    if (count == 0 or parts[0].len == 0) return error.InvalidMesh;
    const v = try resolveIndex(parts[0], npos);
    const vt = if (count >= 2 and parts[1].len > 0) try resolveIndex(parts[1], nvt) else 0;
    const vn = if (count >= 3 and parts[2].len > 0) try resolveIndex(parts[2], nvn) else 0;
    return .{ .v = v, .vt = vt, .vn = vn };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn sub3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

/// Normalize a vector; returns null for a degenerate (near-zero) length.
fn normalize3(v: [3]f32) ?[3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (!(len > 1e-12)) return null;
    const inv = 1.0 / len;
    return .{ v[0] * inv, v[1] * inv, v[2] * inv };
}

/// Decode a Wavefront OBJ (geometry subset) into an indexed triangle mesh.
/// Rejects malformed input, out-of-range indices, non-finite floats and meshes
/// that exceed the vertex/index ceilings or contain no faces.
pub fn decodeObj(gpa: Allocator, source: []const u8) DecodeError!Mesh {
    var positions: std.ArrayList([3]f32) = .empty;
    defer positions.deinit(gpa);
    var normals: std.ArrayList([3]f32) = .empty;
    defer normals.deinit(gpa);
    var uvs: std.ArrayList([2]f32) = .empty;
    defer uvs.deinit(gpa);

    var vertices: std.ArrayList(Vertex) = .empty;
    errdefer vertices.deinit(gpa);
    var indices: std.ArrayList(u32) = .empty;
    errdefer indices.deinit(gpa);

    // Dedup map keyed by (position, uv, normal) reference packed into 96 bits.
    // A high-bit marker on the normal component distinguishes generated flat
    // normals (per face) from explicit `vn` references, so flat-shaded corners
    // only dedup within their own face.
    var dedup: std.AutoHashMap(u96, u32) = .init(gpa);
    defer dedup.deinit();

    var corners: std.ArrayList(CornerRef) = .empty;
    defer corners.deinit(gpa);

    var bounds_min = [3]f32{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var bounds_max = [3]f32{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    var face_serial: u32 = 0;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (std.mem.indexOfScalar(u8, line, '#')) |h| line = line[0..h];

        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const directive = tokens.next() orelse continue;

        if (std.mem.eql(u8, directive, "v")) {
            if (positions.items.len >= max_vertices) return error.InvalidMesh;
            var vals: [4]f32 = undefined;
            var n: usize = 0;
            while (tokens.next()) |tok| {
                if (n == 4) return error.InvalidMesh;
                vals[n] = try parseFiniteF32(tok);
                n += 1;
            }
            if (n < 3) return error.InvalidMesh;
            try positions.append(gpa, .{ vals[0], vals[1], vals[2] });
        } else if (std.mem.eql(u8, directive, "vn")) {
            if (normals.items.len >= max_vertices) return error.InvalidMesh;
            var vals: [3]f32 = undefined;
            var n: usize = 0;
            while (tokens.next()) |tok| {
                if (n == 3) return error.InvalidMesh;
                vals[n] = try parseFiniteF32(tok);
                n += 1;
            }
            if (n != 3) return error.InvalidMesh;
            const unit = normalize3(vals) orelse return error.InvalidMesh;
            try normals.append(gpa, unit);
        } else if (std.mem.eql(u8, directive, "vt")) {
            if (uvs.items.len >= max_vertices) return error.InvalidMesh;
            var vals: [3]f32 = undefined;
            var n: usize = 0;
            while (tokens.next()) |tok| {
                if (n == 3) return error.InvalidMesh;
                vals[n] = try parseFiniteF32(tok);
                n += 1;
            }
            if (n < 2) return error.InvalidMesh;
            try uvs.append(gpa, .{ vals[0], vals[1] });
        } else if (std.mem.eql(u8, directive, "f")) {
            corners.clearRetainingCapacity();
            while (tokens.next()) |tok| {
                const ref = try parseCorner(tok, positions.items.len, uvs.items.len, normals.items.len);
                try corners.append(gpa, ref);
            }
            if (corners.items.len < 3) return error.InvalidMesh;
            if (face_serial >= 0x8000_0000) return error.InvalidMesh;

            // Flat face normal from the first triangle (used when vn is absent).
            const p0 = positions.items[corners.items[0].v - 1];
            const p1 = positions.items[corners.items[1].v - 1];
            const p2 = positions.items[corners.items[2].v - 1];
            const face_normal = normalize3(cross(sub3(p1, p0), sub3(p2, p0))) orelse
                [3]f32{ 0, 0, 0 };
            const flat_marker: u32 = 0x8000_0000 | face_serial;
            face_serial += 1;

            // Fan triangulation: (0, i, i+1) for i in 1..len-2.
            var i: usize = 1;
            while (i + 1 < corners.items.len) : (i += 1) {
                const tri = [_]CornerRef{ corners.items[0], corners.items[i], corners.items[i + 1] };
                for (tri) |c| {
                    if (indices.items.len >= max_indices) return error.InvalidMesh;
                    const nref = if (c.vn != 0) c.vn else flat_marker;
                    const key = (@as(u96, c.v) << 64) | (@as(u96, c.vt) << 32) | @as(u96, nref);
                    const idx = if (dedup.get(key)) |existing| existing else blk: {
                        if (vertices.items.len >= max_vertices) return error.InvalidMesh;
                        const new_idx: u32 = @intCast(vertices.items.len);
                        const pos = positions.items[c.v - 1];
                        const normal = if (c.vn != 0) normals.items[c.vn - 1] else face_normal;
                        const uv = if (c.vt != 0) uvs.items[c.vt - 1] else [2]f32{ 0, 0 };
                        try vertices.append(gpa, .{ .position = pos, .normal = normal, .uv = uv });
                        try dedup.put(key, new_idx);
                        for (0..3) |a| {
                            bounds_min[a] = @min(bounds_min[a], pos[a]);
                            bounds_max[a] = @max(bounds_max[a], pos[a]);
                        }
                        break :blk new_idx;
                    };
                    try indices.append(gpa, idx);
                }
            }
        }
        // Other directives (o/g/s/usemtl/mtllib/...) are intentionally skipped.
    }

    if (indices.items.len == 0) return error.InvalidMesh;
    // Transfer ownership in two phases; if the second transfer fails, free the
    // first (the list errdefers no longer own it after toOwnedSlice succeeds).
    const verts = try vertices.toOwnedSlice(gpa);
    errdefer gpa.free(verts);
    const idxs = try indices.toOwnedSlice(gpa);
    return .{
        .vertices = verts,
        .indices = idxs,
        .bounds_min = bounds_min,
        .bounds_max = bounds_max,
    };
}

// --- CXMH artifact ---------------------------------------------------------

fn validateCounts(vertex_count: u32, index_count: u32) bool {
    if (vertex_count == 0 or vertex_count > max_vertices) return false;
    if (index_count == 0 or index_count > max_indices) return false;
    if (index_count % 3 != 0) return false;
    return true;
}

fn validateMesh(m: Mesh) bool {
    if (!validateCounts(@intCast(m.vertices.len), @intCast(m.indices.len))) return false;
    if (!finite3(m.bounds_min) or !finite3(m.bounds_max)) return false;
    for (0..3) |a| if (m.bounds_min[a] > m.bounds_max[a]) return false;
    for (m.vertices) |v| {
        if (!finite3(v.position) or !finite3(v.normal)) return false;
        if (!std.math.isFinite(v.uv[0]) or !std.math.isFinite(v.uv[1])) return false;
    }
    for (m.indices) |idx| if (idx >= m.vertices.len) return false;
    return true;
}

/// Serialize a mesh into a `CXMH` artifact. Validates counts, index range,
/// finiteness and bounds; rejects an invalid mesh rather than writing garbage.
/// The caller frees the result.
pub fn serialize(gpa: Allocator, m: Mesh) ImportError![]u8 {
    if (m.vertices.len > max_vertices or m.indices.len > max_indices) return error.InvalidAsset;
    if (!validateMesh(m)) return error.InvalidAsset;
    const vertex_count: u32 = @intCast(m.vertices.len);
    const index_count: u32 = @intCast(m.indices.len);

    const vbytes = std.math.mul(usize, m.vertices.len, vertex_stride) catch return error.InvalidAsset;
    const ibytes = std.math.mul(usize, m.indices.len, 4) catch return error.InvalidAsset;
    const total = std.math.add(usize, std.math.add(usize, header_size, vbytes) catch return error.InvalidAsset, ibytes) catch return error.InvalidAsset;

    const out = gpa.alloc(u8, total) catch return error.OutOfMemory;
    errdefer gpa.free(out);
    @memcpy(out[0..4], magic);
    std.mem.writeInt(u32, out[4..8], format_version, .little);
    std.mem.writeInt(u32, out[8..12], @backingInt(VertexFormat.p3n3t2), .little);
    std.mem.writeInt(u32, out[12..16], vertex_count, .little);
    std.mem.writeInt(u32, out[16..20], index_count, .little);
    for (0..3) |a| {
        writeF32(out, 20 + a * 4, m.bounds_min[a]);
        writeF32(out, 32 + a * 4, m.bounds_max[a]);
    }
    var off = header_size;
    for (m.vertices) |v| {
        writeF32(out, off, v.position[0]);
        writeF32(out, off + 4, v.position[1]);
        writeF32(out, off + 8, v.position[2]);
        writeF32(out, off + 12, v.normal[0]);
        writeF32(out, off + 16, v.normal[1]);
        writeF32(out, off + 20, v.normal[2]);
        writeF32(out, off + 24, v.uv[0]);
        writeF32(out, off + 28, v.uv[1]);
        off += vertex_stride;
    }
    for (m.indices) |idx| {
        std.mem.writeInt(u32, out[off..][0..4], idx, .little);
        off += 4;
    }
    return out;
}

/// Parse a `CXMH` artifact into a zero-copy view, validating magic, version,
/// vertex format, counts, exact length, bounds, index range and float finiteness
/// (one linear pass). Rejects anything malformed with `error.InvalidAsset`.
pub fn parse(bytes: []const u8) error{InvalidAsset}!MeshView {
    if (bytes.len < header_size) return error.InvalidAsset;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidAsset;
    if (std.mem.readInt(u32, bytes[4..8], .little) != format_version) return error.InvalidAsset;
    if (std.mem.readInt(u32, bytes[8..12], .little) != @backingInt(VertexFormat.p3n3t2)) return error.InvalidAsset;
    const vertex_count = std.mem.readInt(u32, bytes[12..16], .little);
    const index_count = std.mem.readInt(u32, bytes[16..20], .little);
    if (!validateCounts(vertex_count, index_count)) return error.InvalidAsset;

    var bounds_min: [3]f32 = undefined;
    var bounds_max: [3]f32 = undefined;
    for (0..3) |a| {
        bounds_min[a] = readF32(bytes, 20 + a * 4);
        bounds_max[a] = readF32(bytes, 32 + a * 4);
    }
    if (!finite3(bounds_min) or !finite3(bounds_max)) return error.InvalidAsset;
    for (0..3) |a| if (bounds_min[a] > bounds_max[a]) return error.InvalidAsset;

    const vbytes = std.math.mul(usize, vertex_count, vertex_stride) catch return error.InvalidAsset;
    const ibytes = std.math.mul(usize, index_count, 4) catch return error.InvalidAsset;
    const expected = std.math.add(usize, std.math.add(usize, header_size, vbytes) catch return error.InvalidAsset, ibytes) catch return error.InvalidAsset;
    if (bytes.len != expected) return error.InvalidAsset;

    const vertex_bytes = bytes[header_size .. header_size + vbytes];
    const index_bytes = bytes[header_size + vbytes ..];

    // Linear validation: every vertex float finite, every index in range.
    var off: usize = 0;
    while (off < vbytes) : (off += 4) {
        if (!std.math.isFinite(readF32(vertex_bytes, off))) return error.InvalidAsset;
    }
    var ioff: usize = 0;
    while (ioff < ibytes) : (ioff += 4) {
        if (std.mem.readInt(u32, index_bytes[ioff..][0..4], .little) >= vertex_count) return error.InvalidAsset;
    }

    return .{
        .vertex_count = vertex_count,
        .index_count = index_count,
        .bounds_min = bounds_min,
        .bounds_max = bounds_max,
        .vertex_bytes = vertex_bytes,
        .index_bytes = index_bytes,
    };
}

fn mapDecodeError(err: DecodeError) ImportError {
    return switch (err) {
        error.InvalidMesh => error.InvalidAsset,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Decode an OBJ source then serialize it to a `CXMH` artifact.
pub fn importObj(gpa: Allocator, source: []const u8) ImportError![]u8 {
    var m = decodeObj(gpa, source) catch |err| return mapDecodeError(err);
    defer m.deinit(gpa);
    return serialize(gpa, m);
}

pub const obj_importer = Importer{ .id = "obj", .version = 1, .importFn = importObj };

/// Extension bindings for the engine registry (prepended by `assets.zig`).
pub const bindings = [_]importer.Registry.Binding{
    .{ .extensions = &[_][]const u8{".obj"}, .importer = obj_importer },
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const tri_obj =
    \\# a right triangle in the XY plane
    \\v 0 0 0
    \\v 1 0 0
    \\v 0 1 0
    \\vn 0 0 1
    \\vt 0 0
    \\vt 1 0
    \\vt 0 1
    \\f 1/1/1 2/2/1 3/3/1
;

test "obj: decodes a triangle with positions, normals and uvs" {
    var m = try decodeObj(testing.allocator, tri_obj);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), m.vertices.len);
    try testing.expectEqual(@as(usize, 3), m.indices.len);
    try testing.expectEqual(@as(usize, 1), m.triangleCount());
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0 }, &m.vertices[0].position);
    try testing.expectEqualSlices(f32, &.{ 1, 0, 0 }, &m.vertices[1].position);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 1 }, &m.vertices[0].normal);
    try testing.expectEqualSlices(f32, &.{ 1, 0 }, &m.vertices[1].uv);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, m.indices);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0 }, &m.bounds_min);
    try testing.expectEqualSlices(f32, &.{ 1, 1, 0 }, &m.bounds_max);
}

test "obj: fan-triangulates a quad" {
    const src =
        \\v 0 0 0
        \\v 1 0 0
        \\v 1 1 0
        \\v 0 1 0
        \\f 1 2 3 4
    ;
    var m = try decodeObj(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), m.vertices.len);
    try testing.expectEqual(@as(usize, 6), m.indices.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 2, 3 }, m.indices);
    // Flat normals point +Z for this CCW quad.
    try testing.expectApproxEqAbs(@as(f32, 1), m.vertices[0].normal[2], 1e-5);
}

test "obj: negative indices resolve relative to the current end" {
    const src =
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\f -3 -2 -1
    ;
    var m = try decodeObj(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, m.indices);
}

test "obj: flat-shaded faces keep per-face vertices (no cross-face dedup)" {
    // Two triangles sharing edge (2,3) but without explicit normals. Flat
    // shading requires a distinct normal per face, so shared positions are NOT
    // merged across faces: each face emits its own 3 vertices => 6 total.
    const src =
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\v 1 1 0
        \\f 1 2 3
        \\f 2 4 3
    ;
    var m = try decodeObj(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6), m.indices.len);
    try testing.expectEqual(@as(usize, 6), m.vertices.len);
}

test "obj: explicit normals allow cross-face dedup" {
    const src =
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\v 1 1 0
        \\vn 0 0 1
        \\f 1//1 2//1 3//1
        \\f 2//1 4//1 3//1
    ;
    var m = try decodeObj(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), m.vertices.len);
    try testing.expectEqual(@as(usize, 6), m.indices.len);
}

test "obj: handles v/vt and v//vn corner forms, comments and CRLF" {
    const src = "v 0 0 0\r\nv 1 0 0\r\nv 0 1 0\r\nvt 0 0\r\nvt 1 0\r\nvt 0 1\r\nvn 0 0 1\r\n" ++
        "o group\ns 1\nusemtl mat\n# comment\nf 1/1 2/2 3/3\r\n";
    var m = try decodeObj(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), m.vertices.len);
    // No vn referenced -> flat normal; uvs present.
    try testing.expectEqualSlices(f32, &.{ 1, 0 }, &m.vertices[1].uv);
    try testing.expectApproxEqAbs(@as(f32, 1), m.vertices[0].normal[2], 1e-5);
}

test "obj: normalizes declared normals and rejects zero-length" {
    const src =
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\vn 0 0 5
        \\f 1//1 2//1 3//1
    ;
    var m = try decodeObj(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f32, 1), m.vertices[0].normal[2], 1e-5);

    const bad =
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\vn 0 0 0
        \\f 1//1 2//1 3//1
    ;
    try testing.expectError(error.InvalidMesh, decodeObj(testing.allocator, bad));
}

test "obj: rejects malformed and out-of-range input" {
    const cases = [_][]const u8{
        "", // no faces
        "# only a comment\n",
        "v 0 0 0\nv 1 0 0\nf 1 2\n", // face with < 3 corners
        "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 0 1 2\n", // index 0
        "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 9\n", // out of range
        "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 x\n", // non-numeric
        "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1/2/3/4 2 3\n", // too many corner parts
        "v 0 0 nan\nv 1 0 0\nv 0 1 0\nf 1 2 3\n", // non-finite position
        "v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 inf\nf 1/1 2/1 3/1\n", // non-finite uv
        "v 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n", // position with < 3 floats
        "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 4\n", // forward reference out of range
    };
    for (cases) |src| {
        try testing.expectError(error.InvalidMesh, decodeObj(testing.allocator, src));
    }
}

test "mesh: serialize/parse roundtrip preserves vertices, indices and bounds" {
    var m = try decodeObj(testing.allocator, tri_obj);
    defer m.deinit(testing.allocator);
    const bytes = try serialize(testing.allocator, m);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(bytes.len, header_size + m.vertices.len * 32 + m.indices.len * 4);

    const view = try parse(bytes);
    try testing.expectEqual(@as(u32, 3), view.vertex_count);
    try testing.expectEqual(@as(u32, 3), view.index_count);
    try testing.expectEqual(@as(u32, 1), view.triangleCount());
    try testing.expectEqualSlices(f32, &m.bounds_min, &view.bounds_min);
    try testing.expectEqualSlices(f32, &m.bounds_max, &view.bounds_max);
    for (m.vertices, 0..) |v, i| {
        const got = view.vertexAt(i);
        try testing.expectEqualSlices(f32, &v.position, &got.position);
        try testing.expectEqualSlices(f32, &v.normal, &got.normal);
        try testing.expectEqualSlices(f32, &v.uv, &got.uv);
    }
    for (m.indices, 0..) |idx, i| try testing.expectEqual(idx, view.indexAt(i));
}

test "mesh: parse rejects bad magic, version, format, counts and length" {
    var m = try decodeObj(testing.allocator, tri_obj);
    defer m.deinit(testing.allocator);
    const bytes = try serialize(testing.allocator, m);
    defer testing.allocator.free(bytes);
    var bad = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(bad);

    bad[0] = 'X';
    try testing.expectError(error.InvalidAsset, parse(bad));
    bad[0] = 'C';

    std.mem.writeInt(u32, bad[4..8], 99, .little);
    try testing.expectError(error.InvalidAsset, parse(bad));
    std.mem.writeInt(u32, bad[4..8], format_version, .little);

    std.mem.writeInt(u32, bad[8..12], 7, .little); // bad vertex format
    try testing.expectError(error.InvalidAsset, parse(bad));
    std.mem.writeInt(u32, bad[8..12], 0, .little);

    std.mem.writeInt(u32, bad[12..16], 0, .little); // zero vertices
    try testing.expectError(error.InvalidAsset, parse(bad));
    std.mem.writeInt(u32, bad[12..16], 3, .little);

    std.mem.writeInt(u32, bad[16..20], 4, .little); // index count not multiple of 3
    try testing.expectError(error.InvalidAsset, parse(bad));
    std.mem.writeInt(u32, bad[16..20], 3, .little);

    std.mem.writeInt(u32, bad[12..16], max_vertices + 1, .little); // over ceiling
    try testing.expectError(error.InvalidAsset, parse(bad));

    try testing.expectError(error.InvalidAsset, parse(bytes[0 .. bytes.len - 1])); // truncated
    try testing.expectError(error.InvalidAsset, parse(bytes[0..10])); // short header
}

test "mesh: parse rejects out-of-range indices and non-finite vertices" {
    var m = try decodeObj(testing.allocator, tri_obj);
    defer m.deinit(testing.allocator);
    const bytes = try serialize(testing.allocator, m);
    defer testing.allocator.free(bytes);
    var bad = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(bad);

    // First index -> vertex_count (out of range).
    const idx_off = header_size + 3 * vertex_stride;
    std.mem.writeInt(u32, bad[idx_off..][0..4], 3, .little);
    try testing.expectError(error.InvalidAsset, parse(bad));
    std.mem.writeInt(u32, bad[idx_off..][0..4], 0, .little);

    // First position.x -> NaN.
    std.mem.writeInt(u32, bad[header_size..][0..4], 0x7FC00000, .little);
    try testing.expectError(error.InvalidAsset, parse(bad));
}

test "mesh: serialize rejects an invalid mesh" {
    var m = try decodeObj(testing.allocator, tri_obj);
    defer m.deinit(testing.allocator);
    m.indices[0] = 99; // out of range
    try testing.expectError(error.InvalidAsset, serialize(testing.allocator, m));
}

test "obj: importObj produces a valid CXMH artifact and rejects invalid sources" {
    const bytes = try importObj(testing.allocator, tri_obj);
    defer testing.allocator.free(bytes);
    const view = try parse(bytes);
    try testing.expectEqual(@as(u32, 3), view.vertex_count);
    try testing.expectError(error.InvalidAsset, importObj(testing.allocator, "not an obj"));
}

test "mesh: bindings select the obj importer by extension" {
    const reg = importer.Registry{ .bindings = &bindings, .fallback = importer.raw_importer };
    try testing.expectEqualStrings("obj", reg.select(".obj").id);
    try testing.expectEqualStrings("obj", reg.select(".OBJ").id);
    try testing.expectEqualStrings("raw", reg.select(".gltf").id);
}

test "mesh: decode, serialize and import survive allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(alloc: Allocator) !void {
            var m = try decodeObj(alloc, tri_obj);
            defer m.deinit(alloc);
            const bytes = try serialize(alloc, m);
            alloc.free(bytes);
            const imported = try importObj(alloc, tri_obj);
            alloc.free(imported);
        }
    }.f, .{});
}
