//! 2D painting primitives for the GUI, drawn into a caller-owned RGBA8 buffer.
//!
//! The canvas is the same layout the rest of the engine already speaks:
//! row-major, top-down, 4 bytes per pixel — exactly `assets.image.Image.pixels`
//! and `raster.Target.color`. A GUI frame therefore composites onto a rendered
//! scene with no copy and no format conversion, and the result can be encoded as
//! QOI or shown by whatever backend eventually owns a window.
//!
//! Everything here is **allocation-free** and clips to the canvas: a rectangle
//! that runs off the edge writes only the part inside, and a zero-size canvas
//! writes nothing. That is what lets the immediate-mode layer issue draws without
//! checking bounds first, and it is the property the tests lean on.
//!
//! Alpha: `fillRect`/`line` composite **over** the destination with straight-alpha
//! source-over, quantized once per channel. A fully opaque colour is a plain
//! store, so an opaque GUI over a scene writes exactly the colour asked for.

const std = @import("std");

/// Straight-alpha RGBA8 colour, the same encoding as `raster`'s `[4]u8`.
pub const Color = [4]u8;

pub const transparent: Color = .{ 0, 0, 0, 0 };
pub const black: Color = .{ 0, 0, 0, 255 };
pub const white: Color = .{ 255, 255, 255, 255 };
pub const red: Color = .{ 255, 0, 0, 255 };
pub const green: Color = .{ 0, 255, 0, 255 };
pub const blue: Color = .{ 0, 0, 255, 255 };

/// Derive a colour from `base` with each channel multiplied by `percent`
/// (`0..100`) and alpha kept. Used for hover/pressed tints without a theme table.
pub fn shade(base: Color, percent: u8) Color {
    const p: u32 = @min(percent, 100);
    // Round half up rather than truncate: `shade(white, 50)` must be 128, not 127,
    // or a 50% tint would drift a level below the colour it is meant to halve.
    return .{
        @intCast((@as(u32, base[0]) * p + 50) / 100),
        @intCast((@as(u32, base[1]) * p + 50) / 100),
        @intCast((@as(u32, base[2]) * p + 50) / 100),
        base[3],
    };
}

/// `base` with its alpha replaced.
pub fn withAlpha(base: Color, alpha: u8) Color {
    return .{ base[0], base[1], base[2], alpha };
}

/// An integer rectangle: position plus **extent**, never a corner. Kept integer
/// on purpose — a GUI drawn on whole pixels has no half-pixel seams, and the
/// hit-test a widget does is the same rectangle it painted.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    /// A rectangle with no area, used as the "nothing" value and as the initial
    /// value of a layout rect.
    pub const none: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    pub fn init(x: i32, y: i32, w: i32, h: i32) Rect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    pub fn right(self: Rect) i32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn area(self: Rect) i64 {
        return @as(i64, self.w) * @as(i64, self.h);
    }

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.right() and py >= self.y and py < self.bottom();
    }

    pub fn containsPoint(self: Rect, p: Point) bool {
        return self.contains(p.x, p.y);
    }

    /// Whether the two rectangles share at least one pixel.
    /// Whether `other` lies entirely inside this rectangle. Used by the GUI to
    /// tell a widget *inside* an overlay (reachable) from one merely overlapped by
    /// it (blocked), so a modal panel does not disable its own children.
    pub fn containsRect(self: Rect, other: Rect) bool {
        if (other.isEmpty()) return true;
        return other.x >= self.x and other.y >= self.y and
            other.right() <= self.right() and other.bottom() <= self.bottom();
    }

    pub fn intersects(self: Rect, other: Rect) bool {
        return self.x < other.right() and other.x < self.right() and
            self.y < other.bottom() and other.y < self.bottom();
    }

    /// The overlapping rectangle, or `.none` when they do not touch.
    pub fn intersect(self: Rect, other: Rect) Rect {
        const x0 = @max(self.x, other.x);
        const y0 = @max(self.y, other.y);
        const x1 = @min(self.right(), other.right());
        const y1 = @min(self.bottom(), other.bottom());
        if (x1 <= x0 or y1 <= y0) return .none;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// This rectangle inset by `by` on every side. Never goes negative: a rect
    /// inset past its own size becomes empty rather than inverted.
    pub fn inset(self: Rect, by: i32) Rect {
        const w = self.w - 2 * by;
        const h = self.h - 2 * by;
        if (w <= 0 or h <= 0) return .none;
        return .{ .x = self.x + by, .y = self.y + by, .w = w, .h = h };
    }

    /// This rectangle moved by `(dx, dy)`.
    pub fn offset(self: Rect, dx: i32, dy: i32) Rect {
        return .{ .x = self.x + dx, .y = self.y + dy, .w = self.w, .h = self.h };
    }

    /// The first `height` pixels of this rectangle from the top — the layout
    /// primitive a vertical stack is built from.
    pub fn sliceTop(self: Rect, height: i32) Rect {
        return .{ .x = self.x, .y = self.y, .w = self.w, .h = @min(height, self.h) };
    }

    /// The last `height` pixels of this rectangle — a footer or a bottom bar.
    pub fn sliceBottom(self: Rect, height: i32) Rect {
        const h = @min(height, self.h);
        return .{ .x = self.x, .y = self.bottom() - h, .w = self.w, .h = h };
    }

    /// The left `width` pixels of this rectangle.
    pub fn sliceLeft(self: Rect, width: i32) Rect {
        return .{ .x = self.x, .y = self.y, .w = @min(width, self.w), .h = self.h };
    }

    /// The right `width` pixels of this rectangle.
    pub fn sliceRight(self: Rect, width: i32) Rect {
        const w = @min(width, self.w);
        return .{ .x = self.right() - w, .y = self.y, .w = w, .h = self.h };
    }

    /// This rectangle with `height` taken off the top — the remainder after a
    /// `sliceTop`. Never inverts: the result is empty once the slice consumed all.
    /// Negative heights are clamped to zero (nothing is taken off).
    pub fn below(self: Rect, height: i32) Rect {
        const cut = @min(@max(height, 0), self.h);
        return .{ .x = self.x, .y = self.y + cut, .w = self.w, .h = self.h - cut };
    }

    /// This rectangle with `width` taken off the left. Negative widths are
    /// clamped to zero (nothing is taken off).
    pub fn after(self: Rect, width: i32) Rect {
        const cut = @min(@max(width, 0), self.w);
        return .{ .x = self.x + cut, .y = self.y, .w = self.w - cut, .h = self.h };
    }
};

/// A point in canvas pixels.
pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,
};

/// Borrowed RGBA8 canvas with clipping and allocation-free primitives.
pub const Canvas = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn init(width: u32, height: u32, pixels: []u8) !Canvas {
        const need = @as(usize, width) * height * 4;
        if (pixels.len < need) return error.BufferTooSmall;
        return .{ .width = width, .height = height, .pixels = pixels[0..need] };
    }

    pub fn bounds(self: Canvas) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
    }

    /// The colour at `(x, y)`, or `null` outside the canvas.
    pub fn get(self: Canvas, x: i32, y: i32) ?Color {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.width)) or y >= @as(i32, @intCast(self.height))) return null;
        const i = (@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 4;
        return .{ self.pixels[i], self.pixels[i + 1], self.pixels[i + 2], self.pixels[i + 3] };
    }

    /// Overwrite the whole canvas.
    pub fn clear(self: Canvas, color: Color) void {
        var i: usize = 0;
        while (i < self.pixels.len) : (i += 4) {
            self.pixels[i + 0] = color[0];
            self.pixels[i + 1] = color[1];
            self.pixels[i + 2] = color[2];
            self.pixels[i + 3] = color[3];
        }
    }

    /// Composite a single pixel. Clipped to the canvas; `0` alpha is a no-op.
    /// The text layer draws glyphs one pixel at a time through this, and widgets
    /// use it for the few one-pixel details (carets, ticks) a rect cannot express.
    pub fn plot(self: Canvas, x: i32, y: i32, color: Color) void {
        self.blendPixel(x, y, color);
    }

    /// Composite one pixel with straight-alpha source-over. `0` alpha is an exact
    /// no-op and `255` is an exact store, so opaque GUI elements never pick up
    /// rounding from what is underneath them.
    fn blendPixel(self: Canvas, x: i32, y: i32, color: Color) void {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.width)) or y >= @as(i32, @intCast(self.height))) return;
        const i = (@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 4;
        const sa = color[3];
        if (sa == 0) return;
        if (sa == 255) {
            self.pixels[i + 0] = color[0];
            self.pixels[i + 1] = color[1];
            self.pixels[i + 2] = color[2];
            self.pixels[i + 3] = 255;
            return;
        }
        // Straight-alpha source-over: out_a = a + da*(1-a), and out_rgb is the
        // alpha-weighted sum normalised by out_a — not the premultiplied sum,
        // which darkens translucent layers and misfeeds later blends.
        const a = @as(f64, @floatFromInt(sa)) / 255.0;
        const keep = 1.0 - a;
        const da = @as(f64, @floatFromInt(self.pixels[i + 3])) / 255.0;
        const out_a = a + da * keep;
        const inv_out_a = if (out_a > 0.0) 1.0 / out_a else 0.0;
        inline for (0..3) |c| {
            const src = @as(f64, @floatFromInt(color[c])) * a;
            const dst = @as(f64, @floatFromInt(self.pixels[i + c])) * da * keep;
            self.pixels[i + c] = @intFromFloat(std.math.clamp(std.math.floor((src + dst) * inv_out_a + 0.5), 0.0, 255.0));
        }
        self.pixels[i + 3] = @intFromFloat(std.math.clamp(std.math.floor(out_a * 255.0 + 0.5), 0.0, 255.0));
    }

    /// Fill `rect`, clipped to the canvas. Empty and off-screen rectangles are
    /// no-ops rather than errors: layout produces them routinely.
    pub fn fillRect(self: Canvas, rect: Rect, color: Color) void {
        if (rect.isEmpty() or color[3] == 0) return;
        const clip = rect.intersect(self.bounds());
        if (clip.isEmpty()) return;
        var y = clip.y;
        while (y < clip.bottom()) : (y += 1) {
            var x = clip.x;
            while (x < clip.right()) : (x += 1) self.blendPixel(x, y, color);
        }
    }

    /// Fill the canvas outside `rect` with `color` — the dimming pass a modal uses.
    pub fn fillOutside(self: Canvas, rect: Rect, color: Color) void {
        if (color[3] == 0) return;
        const b = self.bounds();
        const inner = rect.intersect(b);
        if (inner.isEmpty()) {
            self.fillRect(b, color);
            return;
        }
        self.fillRect(.{ .x = b.x, .y = b.y, .w = b.w, .h = inner.y - b.y }, color);
        self.fillRect(.{ .x = b.x, .y = inner.bottom(), .w = b.w, .h = b.bottom() - inner.bottom() }, color);
        self.fillRect(.{ .x = b.x, .y = inner.y, .w = inner.x - b.x, .h = inner.h }, color);
        self.fillRect(.{ .x = inner.right(), .y = inner.y, .w = b.right() - inner.right(), .h = inner.h }, color);
    }

    /// Draw a one-pixel rectangle outline **inside** `rect`, so a bordered box is
    /// exactly the size the caller asked for and two adjacent boxes share an edge
    /// without overlapping.
    pub fn strokeRect(self: Canvas, rect: Rect, color: Color) void {
        if (rect.isEmpty() or color[3] == 0) return;
        self.fillRect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 1 }, color);
        if (rect.h > 1) self.fillRect(.{ .x = rect.x, .y = rect.bottom() - 1, .w = rect.w, .h = 1 }, color);
        self.fillRect(.{ .x = rect.x, .y = rect.y + 1, .w = 1, .h = @max(rect.h - 2, 0) }, color);
        if (rect.w > 1) self.fillRect(.{ .x = rect.right() - 1, .y = rect.y + 1, .w = 1, .h = @max(rect.h - 2, 0) }, color);
    }

    /// A horizontal line of one pixel from `x0` to `x0 + w`, at `y`.
    pub fn hline(self: Canvas, x0: i32, y: i32, w: i32, color: Color) void {
        self.fillRect(.{ .x = x0, .y = y, .w = w, .h = 1 }, color);
    }

    /// A vertical line of one pixel from `y0` to `y0 + h`, at `x`.
    pub fn vline(self: Canvas, x: i32, y0: i32, h: i32, color: Color) void {
        self.fillRect(.{ .x = x, .y = y0, .w = 1, .h = h }, color);
    }

    /// A freeform line from `(x0, y0)` to `(x1, y1)`, one pixel wide, clipped to
    /// the canvas. Bresenham's algorithm: integer only, no float, no division in
    /// the inner loop. Used by the viewport gizmos to draw their axis handles.
    pub fn line(self: Canvas, x0: i32, y0: i32, x1: i32, y1: i32, color: Color) void {
        const dx = if (x1 > x0) x1 - x0 else x0 - x1;
        const dy = if (y1 > y0) y1 - y0 else y0 - y1;
        const sx = @as(i32, if (x0 < x1) 1 else -1);
        const sy = @as(i32, if (y0 < y1) 1 else -1);
        var err = dx - dy;
        var cx = x0;
        var cy = y0;
        while (true) {
            self.blendPixel(cx, cy, color);
            if (cx == x1 and cy == y1) break;
            const e2 = 2 * err;
            if (e2 > -dy) {
                err -= dy;
                cx += sx;
            }
            if (e2 < dx) {
                err += dx;
                cy += sy;
            }
        }
    }

    /// Blit an RGBA8 image scaled to fill `dst`, nearest-neighbour, clipped to both
    /// the destination and the canvas.
    ///
    /// This is how a rendered frame is shown inside a smaller viewport: the scene
    /// is drawn at the surface resolution and sampled down here, so the viewport
    /// shows the whole frame rather than a crop of it. Nearest-neighbour is the
    /// deliberate choice — it is one memory read per pixel, has no ringing, and a
    /// pixel-art editor wants exactly this. Pixels outside `dst` are never touched,
    /// which is what makes it safe to call with a destination that overlaps the
    /// editor's own panels.
    pub fn blitScaled(
        self: Canvas,
        dst: Rect,
        src: []const u8,
        src_w: u32,
        src_h: u32,
    ) void {
        if (dst.isEmpty() or src_w == 0 or src_h == 0) return;
        const need = @as(usize, src_w) * src_h * 4;
        if (src.len < need) return;
        const clip = dst.intersect(self.bounds());
        if (clip.isEmpty()) return;
        const sw: i64 = @intCast(src_w);
        const sh: i64 = @intCast(src_h);
        var y = clip.y;
        while (y < clip.bottom()) : (y += 1) {
            const sy = @divFloor(@as(i64, y - dst.y) * sh, @as(i64, dst.h));
            var x = clip.x;
            while (x < clip.right()) : (x += 1) {
                const sx = @divFloor(@as(i64, x - dst.x) * sw, @as(i64, dst.w));
                const si = (@as(usize, @intCast(sy)) * src_w + @as(usize, @intCast(sx))) * 4;
                self.blendPixel(x, y, .{ src[si], src[si + 1], src[si + 2], src[si + 3] });
            }
        }
    }

    /// Blit an RGBA8 image at `(dx, dy)`, clipped, honouring the source alpha by
    /// compositing rather than replacing. `src_w`/`src_h` describe the source so a
    /// sub-rectangle can be copied without building a view.
    pub fn blit(self: Canvas, dx: i32, dy: i32, src: []const u8, src_w: u32, src_h: u32) void {
        const need = @as(usize, src_w) * src_h * 4;
        if (src.len < need) return;
        var y: i32 = 0;
        while (y < @as(i32, @intCast(src_h))) : (y += 1) {
            var x: i32 = 0;
            while (x < @as(i32, @intCast(src_w))) : (x += 1) {
                const si = (@as(usize, @intCast(y)) * src_w + @as(usize, @intCast(x))) * 4;
                self.blendPixel(dx + x, dy + y, .{ src[si], src[si + 1], src[si + 2], src[si + 3] });
            }
        }
    }
};

// --- tests ------------------------------------------------------------------

const testing = std.testing;

fn testCanvas(comptime w: u32, comptime h: u32) struct { pixels: [w * h * 4]u8, canvas: Canvas } {
    return .{ .pixels = @splat(0), .canvas = Canvas.init(w, h, undefined) catch unreachable };
}

test "canvas: init rejects a short buffer and get reports outside pixels" {
    var buf: [3 * 2 * 4]u8 = @splat(0);
    const c = try Canvas.init(3, 2, &buf);
    try testing.expectEqual(@as(u32, 3), c.width);
    try testing.expectError(error.BufferTooSmall, Canvas.init(3, 2, buf[0 .. buf.len - 1]));
    try testing.expectEqual(@as(?Color, null), c.get(-1, 0));
    try testing.expectEqual(@as(?Color, null), c.get(3, 0));
    try testing.expect(c.get(2, 1) != null);
}

test "canvas: plot blends one pixel and ignores points outside the canvas" {
    var buf: [2 * 2 * 4]u8 = @splat(0);
    var c = try Canvas.init(2, 2, &buf);
    c.plot(0, 0, red);
    try testing.expectEqual(red, c.get(0, 0).?);
    try testing.expectEqual(Color{ 0, 0, 0, 0 }, c.get(1, 0).?);
    c.plot(5, 5, green); // outside: no write, no panic
    c.plot(-1, 0, green);
    try testing.expectEqual(Color{ 0, 0, 0, 0 }, c.get(1, 0).?);
    // Alpha 0 is a no-op even in the middle of the canvas.
    c.plot(0, 0, .{ 0, 255, 0, 0 });
    try testing.expectEqual(red, c.get(0, 0).?);
}

test "canvas: an opaque fill stores the colour exactly and clips to the edge" {
    var buf: [4 * 4 * 4]u8 = @splat(0);
    var c = try Canvas.init(4, 4, &buf);
    c.fillRect(.{ .x = -2, .y = -2, .w = 4, .h = 4 }, red);
    // The part inside the canvas is red, everything else untouched.
    try testing.expectEqual(Color{ 255, 0, 0, 255 }, c.get(0, 0).?);
    try testing.expectEqual(Color{ 255, 0, 0, 255 }, c.get(1, 1).?);
    try testing.expectEqual(Color{ 0, 0, 0, 0 }, c.get(2, 2).?);
    // A rectangle entirely off-canvas is a no-op.
    c.fillRect(.{ .x = 40, .y = 40, .w = 4, .h = 4 }, green);
    try testing.expectEqual(Color{ 0, 0, 0, 0 }, c.get(3, 3).?);
    // An empty rectangle is a no-op too, not a zero-size special case.
    c.fillRect(.{ .x = 0, .y = 0, .w = 0, .h = 4 }, blue);
    try testing.expectEqual(Color{ 255, 0, 0, 255 }, c.get(0, 0).?);
}

test "canvas: blending onto a translucent destination normalises by out_a" {
    var buf: [1 * 1 * 4]u8 = @splat(0);
    var c = try Canvas.init(1, 1, &buf);
    // Opaque black with 50% alpha: premultiplied rgb would be (0,0,0,128).
    c.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ 0, 0, 0, 128 });
    // Half-transparent white source-over it: out_a = 128 + 128*(1-0.5) = 192,
    // and rgb = 255*0.5 / (192/255) = 170, not 128 (the premultiplied result).
    c.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ 255, 255, 255, 128 });
    const px = c.get(0, 0).?;
    try testing.expectEqual(@as(u8, 192), px[3]);
    try testing.expectEqual(@as(u8, 170), px[0]);
    try testing.expectEqual(@as(u8, 170), px[1]);
    try testing.expectEqual(@as(u8, 170), px[2]);
}

test "canvas: alpha compositing is source-over and opaque is exact" {
    var buf: [2 * 1 * 4]u8 = @splat(0);
    var c = try Canvas.init(2, 1, &buf);
    c.fillRect(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, .{ 0, 0, 255, 255 });
    // Half-transparent white over opaque blue: the source-over result, rounded once.
    c.fillRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ 255, 255, 255, 128 });
    // Source-over with straight alpha: a = 128/255, so each channel is
    // 255 * a + 0 * (1 - a) for red and 255 * a + 255 * (1 - a) = 255 for blue.
    const blended = c.get(0, 0).?;
    try testing.expectEqual(@as(u8, 255), blended[3]);
    // White source over opaque blue at 50% alpha: red has no destination
    // contribution (destination red is 0), blue stays saturated, alpha stays 255.
    try testing.expectEqual(@as(u8, 128), blended[0]);
    try testing.expectEqual(@as(u8, 128), blended[1]);
    try testing.expectEqual(@as(u8, 255), blended[2]);
    // Zero alpha writes nothing at all.
    c.fillRect(.{ .x = 1, .y = 0, .w = 1, .h = 1 }, .{ 255, 0, 0, 0 });
    try testing.expectEqual(Color{ 0, 0, 255, 255 }, c.get(1, 0).?);
}

test "canvas: strokeRect draws inside the rectangle and shares edges" {
    var buf: [4 * 4 * 4]u8 = @splat(0);
    var c = try Canvas.init(4, 4, &buf);
    c.strokeRect(.{ .x = 1, .y = 1, .w = 3, .h = 3 }, white);
    // Border pixels are white, the inside is not, and nothing outside is touched.
    try testing.expectEqual(Color{ 255, 255, 255, 255 }, c.get(1, 1).?);
    try testing.expectEqual(Color{ 255, 255, 255, 255 }, c.get(3, 3).?);
    try testing.expectEqual(Color{ 255, 255, 255, 255 }, c.get(2, 1).?);
    try testing.expectEqual(Color{ 0, 0, 0, 0 }, c.get(2, 2).?);
    try testing.expectEqual(Color{ 0, 0, 0, 0 }, c.get(0, 0).?);
    try testing.expectEqual(Color{ 0, 0, 0, 0 }, c.get(4 - 1 + 1 - 1, 0).?);
    // A one-pixel-wide box is a line, not an empty shape.
    var buf2: [3 * 1 * 4]u8 = @splat(0);
    var c2 = try Canvas.init(3, 1, &buf2);
    c2.strokeRect(.{ .x = 0, .y = 0, .w = 3, .h = 1 }, green);
    try testing.expectEqual(Color{ 0, 255, 0, 255 }, c2.get(0, 0).?);
    try testing.expectEqual(Color{ 0, 255, 0, 255 }, c2.get(2, 0).?);
}

test "rect: layout slices never invert and intersections are exact" {
    const r = Rect.init(10, 20, 100, 50);
    try testing.expectEqual(@as(i32, 110), r.right());
    try testing.expectEqual(@as(i32, 70), r.bottom());
    try testing.expect(r.contains(10, 20));
    try testing.expect(!r.contains(110, 70));

    const top = r.sliceTop(15);
    try testing.expectEqual(Rect.init(10, 20, 100, 15), top);
    const rest = r.below(15);
    try testing.expectEqual(Rect.init(10, 35, 100, 35), rest);
    // Consuming more than there is yields an empty remainder, never a negative.
    try testing.expect(rest.below(1000).isEmpty());
    try testing.expectEqual(@as(i32, 0), rest.after(1000).w);
    try testing.expectEqual(@as(i32, 0), r.sliceBottom(1000).y + r.sliceBottom(1000).h - r.bottom());

    try testing.expectEqual(Rect.init(10, 20, 100, 50), r.intersect(r));
    try testing.expect(r.intersect(Rect.init(200, 200, 5, 5)).isEmpty());
    try testing.expect(r.intersects(Rect.init(100, 60, 50, 50)));
    try testing.expect(!r.intersects(Rect.init(110, 20, 5, 5)));
    // Inset past half the size collapses to empty rather than inverting.
    try testing.expect(Rect.init(0, 0, 4, 4).inset(3).isEmpty());
    try testing.expectEqual(@as(i64, 0), Rect.none.area());
}

test "canvas: fillOutside dims everything but the given rect" {
    var buf: [5 * 5 * 4]u8 = @splat(0);
    var c = try Canvas.init(5, 5, &buf);
    c.fillOutside(.{ .x = 1, .y = 1, .w = 3, .h = 3 }, .{ 0, 0, 0, 255 });
    try testing.expectEqual(Color{ 0, 0, 0, 255 }, c.get(0, 0).?);
    try testing.expectEqual(Color{ 0, 0, 0, 0 }, c.get(1, 1).?);
    try testing.expectEqual(Color{ 0, 0, 0, 0 }, c.get(3, 3).?);
    try testing.expectEqual(Color{ 0, 0, 0, 255 }, c.get(4, 4).?);
    try testing.expectEqual(Color{ 0, 0, 0, 255 }, c.get(0, 2).?);
}

test "canvas: blit composites a source image and ignores an inconsistent one" {
    var buf: [2 * 2 * 4]u8 = @splat(0);
    var c = try Canvas.init(2, 2, &buf);
    const src = [_]u8{
        255, 0, 0,   255, 0, 255, 0, 255,
        0,   0, 255, 255, 0, 0,   0, 0,
    };
    c.blit(0, 0, &src, 2, 2);
    try testing.expectEqual(Color{ 255, 0, 0, 255 }, c.get(0, 0).?);
    try testing.expectEqual(Color{ 0, 255, 0, 255 }, c.get(1, 0).?);
    try testing.expectEqual(Color{ 0, 0, 255, 255 }, c.get(0, 1).?);
    // A fully transparent source pixel leaves the destination alone.
    try testing.expectEqual(Color{ 0, 0, 0, 0 }, c.get(1, 1).?);
    // A source shorter than its stated size is rejected outright.
    c.blit(0, 0, src[0..4], 2, 2);
    try testing.expectEqual(Color{ 255, 0, 0, 255 }, c.get(0, 0).?);
}

test "canvas: a scaled blit fills the destination, samples nearest and clips" {
    // 2x2 source: red, green / blue, white.
    const src = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 255,
    };
    var buf: [8 * 8 * 4]u8 = @splat(0);
    var c = try Canvas.init(8, 8, &buf);

    // 4x4 destination starting at (2,2): each source pixel becomes a 2x2 block.
    c.blitScaled(Rect.init(2, 2, 4, 4), &src, 2, 2);
    try testing.expectEqual(Color{ 255, 0, 0, 255 }, c.get(2, 2).?);
    try testing.expectEqual(Color{ 255, 0, 0, 255 }, c.get(3, 3).?);
    try testing.expectEqual(Color{ 0, 255, 0, 255 }, c.get(4, 2).?);
    try testing.expectEqual(Color{ 0, 0, 255, 255 }, c.get(2, 4).?);
    try testing.expectEqual(Color{ 255, 255, 255, 255 }, c.get(5, 5).?);
    // Outside the destination nothing was written.
    try testing.expectEqual(Color{ 0, 0, 0, 0 }, c.get(1, 2).?);
    try testing.expectEqual(Color{ 0, 0, 0, 0 }, c.get(6, 2).?);

    // A destination that runs off the canvas writes only the visible part.
    var small: [2 * 2 * 4]u8 = @splat(0);
    var c2 = try Canvas.init(2, 2, &small);
    c2.blitScaled(Rect.init(1, 1, 8, 8), &src, 2, 2);
    try testing.expectEqual(Color{ 255, 0, 0, 255 }, c2.get(1, 1).?);
    try testing.expectEqual(Color{ 0, 0, 0, 0 }, c2.get(0, 0).?);

    // Degenerate and truncated inputs are no-ops, not errors.
    c2.blitScaled(Rect.none, &src, 2, 2);
    c2.blitScaled(Rect.init(0, 0, 2, 2), src[0..4], 2, 2);
    c2.blitScaled(Rect.init(0, 0, 2, 2), &src, 0, 2);
    try testing.expectEqual(Color{ 255, 0, 0, 255 }, c2.get(1, 1).?);
}

test "canvas: shade and withAlpha keep the alpha and scale the colour" {
    try testing.expectEqual(Color{ 128, 128, 128, 255 }, shade(white, 50));
    try testing.expectEqual(Color{ 255, 0, 0, 255 }, shade(red, 200)); // clamped to 100
    try testing.expectEqual(Color{ 51, 0, 0, 255 }, shade(red, 20)); // 255 * 20% = 51
    try testing.expectEqual(Color{ 51, 0, 0, 128 }, withAlpha(shade(red, 20), 128));
}
