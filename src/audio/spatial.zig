//! Spatial audio math: listener basis, distance attenuation, stereo panning and
//! Doppler shift.
//!
//! Pure functions over `Vec3`, reusing the scene's transform math (the same
//! dependency `render/camera.zig` has). There is no mixer, ECS or asset
//! dependency here, so every rule is testable in isolation and the mixer stays
//! usable without any of it.
//!
//! Conventions (matching the render layer):
//! - Right-handed world space, the listener looks down its **-Z** axis.
//! - Pan is in [-1, 1] (left..right) and feeds `Mixer`'s pan law directly.
//! - Distances are in world units; the attenuation reference distance defaults
//!   to 1 unit, so a source at 1 unit plays at unity gain.
//!
//! What is implemented is a **stereo amplitude pan** with distance gain and
//! Doppler. There is no HRTF, no occlusion/reverb and no per-ear delay: a source
//! directly in front and directly behind pan identically, which is inherent to
//! amplitude panning and documented rather than hidden.

const std = @import("std");
const transform = @import("../scene/transform.zig");

pub const Vec3 = transform.Vec3;
pub const Mat4 = transform.Mat4;

/// Distances below this are treated as coincident (no direction, no Doppler).
pub const epsilon: f32 = 1e-6;

/// Distance attenuation models. The formulas follow the OpenAL 1.1 distance
/// models with the distance **clamped** to `[min_distance, max_distance]`, which
/// is the variant every engine uses in practice (it keeps gain bounded and
/// stops attenuation at the far plane).
pub const Attenuation = struct {
    pub const Model = enum {
        /// No distance attenuation (gain 1 everywhere). Useful for 2D sounds.
        none,
        /// `1 - rolloff * (d - min) / (max - min)` — reaches silence at `max`.
        linear,
        /// `min / (min + rolloff * (d - min))` — physically plausible falloff.
        inverse,
        /// `(d / min) ^ -rolloff` — power-law falloff.
        exponential,
    };

    model: Model = .inverse,
    /// Reference distance: gain is 1 at or below it. Must be > 0.
    min_distance: f32 = 1.0,
    /// Far clamp: attenuation stops changing beyond it. Must be >= min_distance.
    max_distance: f32 = 100.0,
    /// How fast gain falls off. 0 disables falloff; must be >= 0.
    rolloff: f32 = 1.0,

    pub fn isValid(self: Attenuation) bool {
        if (!std.math.isFinite(self.min_distance) or self.min_distance <= 0) return false;
        if (!std.math.isFinite(self.max_distance) or self.max_distance < self.min_distance) return false;
        if (!std.math.isFinite(self.rolloff) or self.rolloff < 0) return false;
        return true;
    }

    /// Gain in [0, 1] for a distance. Non-finite distances yield silence rather
    /// than propagating NaN into the mix.
    pub fn gainAt(self: Attenuation, distance: f32) f32 {
        if (!std.math.isFinite(distance)) return 0;
        if (self.model == .none) return 1;
        const d = std.math.clamp(distance, self.min_distance, self.max_distance);
        switch (self.model) {
            .none => return 1,
            .linear => {
                // A zero-width range has no slope; everything inside it is unity.
                const span = self.max_distance - self.min_distance;
                if (span <= 0) return 1;
                const g = 1.0 - self.rolloff * (d - self.min_distance) / span;
                return std.math.clamp(g, 0, 1);
            },
            .inverse => {
                const den = self.min_distance + self.rolloff * (d - self.min_distance);
                if (den <= 0) return 1;
                return std.math.clamp(self.min_distance / den, 0, 1);
            },
            .exponential => {
                const ratio = d / self.min_distance;
                if (ratio <= 0) return 1;
                return std.math.clamp(std.math.pow(f32, ratio, -self.rolloff), 0, 1);
            },
        }
    }
};

/// Doppler settings. `factor` scales the effect (0 disables it, 1 is physical);
/// the speed of sound and the pitch clamp are properties of the world, not of a
/// single source, so the audio system keeps them in its configuration.
pub const Doppler = struct {
    factor: f32 = 0.0,
    /// Speed of sound in world units per second (air at ~20 C by default).
    speed_of_sound: f32 = 343.3,
    /// Hard clamp on the resulting pitch multiplier, applied symmetrically as
    /// `[1 / max_pitch, max_pitch]`. Must be >= 1.
    max_pitch: f32 = 2.0,

    pub fn isValid(self: Doppler) bool {
        if (!std.math.isFinite(self.factor) or self.factor < 0) return false;
        if (!std.math.isFinite(self.speed_of_sound) or self.speed_of_sound <= 0) return false;
        if (!std.math.isFinite(self.max_pitch) or self.max_pitch < 1) return false;
        return true;
    }
};

/// A listener pose in world space. `forward` and `up` need not be unit length or
/// exactly perpendicular: the basis is orthonormalized when the right vector is
/// derived, so a scaled world matrix is safe.
pub const Listener = struct {
    position: Vec3 = .{ 0, 0, 0 },
    /// Viewing direction (the world matrix's -Z column).
    forward: Vec3 = .{ 0, 0, -1 },
    up: Vec3 = .{ 0, 1, 0 },
    /// World-space velocity, used only by Doppler.
    velocity: Vec3 = .{ 0, 0, 0 },

    pub const identity: Listener = .{};

    pub fn isValid(self: Listener) bool {
        for (self.position) |v| if (!std.math.isFinite(v)) return false;
        for (self.forward) |v| if (!std.math.isFinite(v)) return false;
        for (self.up) |v| if (!std.math.isFinite(v)) return false;
        for (self.velocity) |v| if (!std.math.isFinite(v)) return false;
        // A degenerate basis (zero or parallel forward/up) has no left/right.
        return transform.length(transform.cross(self.forward, self.up)) > epsilon;
    }

    /// Unit right vector (`forward x up`, right-handed). Zero for a degenerate
    /// basis; callers guard with `isValid`.
    pub fn right(self: Listener) Vec3 {
        return transform.normalize(transform.cross(self.forward, self.up));
    }

    /// Build a listener from an entity's world matrix: translation from the
    /// fourth column, forward from -Z, up from +Y. Scale is normalized away and
    /// the up vector is re-orthogonalized against forward. A degenerate matrix
    /// falls back to the identity basis at the same position, so a broken
    /// transform silences panning instead of producing NaN. Velocity is zero;
    /// the caller sets it (there is no automatic differentiation).
    pub fn fromMatrix(world: Mat4) Listener {
        const position: Vec3 = .{ world[12], world[13], world[14] };
        var listener = Listener{
            .position = position,
            .forward = transform.normalize(.{ -world[8], -world[9], -world[10] }),
            .up = transform.normalize(.{ world[4], world[5], world[6] }),
        };
        if (!listener.isValid()) {
            listener.forward = .{ 0, 0, -1 };
            listener.up = .{ 0, 1, 0 };
            return listener;
        }
        listener.up = transform.cross(listener.right(), listener.forward);
        return listener;
    }
};

/// Per-source spatialization parameters.
pub const Params = struct {
    attenuation: Attenuation = .{},
    doppler: Doppler = .{},
    /// 0 = 2D (unity gain, center pan, no Doppler), 1 = fully spatialized.
    /// Values in between cross-fade, which is how a sound is faded from
    /// diegetic 3D to a flat 2D mix.
    blend: f32 = 1.0,

    pub fn isValid(self: Params) bool {
        if (!std.math.isFinite(self.blend)) return false;
        return self.attenuation.isValid() and self.doppler.isValid();
    }
};

/// The three values a mixer voice needs, already blended.
pub const SpatialResult = struct {
    /// Distance gain in [0, 1] (before the source's own gain).
    gain: f32,
    /// Stereo position in [-1, 1].
    pan: f32,
    /// Doppler pitch multiplier (> 0), to be folded into the voice's pitch.
    pitch: f32,
};

/// Doppler pitch multiplier for a moving source and/or listener.
///
/// With `dir` pointing from the listener to the source, the classic formula is
/// `(c + v_listener·dir) / (c + v_source·dir)`: a listener moving toward the
/// source raises the pitch, and a source moving toward the listener (negative
/// projection) raises it too. The denominator is floored so a supersonic source
/// cannot divide by zero or invert the sign, and the result is clamped to
/// `[1 / max_pitch, max_pitch]`.
pub fn dopplerScale(listener: Listener, source_position: Vec3, source_velocity: Vec3, settings: Doppler) f32 {
    if (!(settings.factor > 0)) return 1;
    const delta = transform.sub(source_position, listener.position);
    const distance = transform.length(delta);
    if (distance <= epsilon) return 1;
    const dir = transform.scale(delta, 1.0 / distance);
    const c = settings.speed_of_sound;
    const floor = c * 0.01;
    const numerator = @max(c + settings.factor * transform.dot(listener.velocity, dir), floor);
    const denominator = @max(c + settings.factor * transform.dot(source_velocity, dir), floor);
    const raw = numerator / denominator;
    if (!std.math.isFinite(raw)) return 1;
    return std.math.clamp(raw, 1.0 / settings.max_pitch, settings.max_pitch);
}

/// Amplitude pan for a source position: the sine of the azimuth relative to the
/// listener's right axis, so a source abeam pans hard and a source ahead or
/// behind pans center. Coincident sources pan center.
pub fn panFor(listener: Listener, source_position: Vec3) f32 {
    const delta = transform.sub(source_position, listener.position);
    const distance = transform.length(delta);
    if (distance <= epsilon) return 0;
    const dir = transform.scale(delta, 1.0 / distance);
    return std.math.clamp(transform.dot(dir, listener.right()), -1, 1);
}

/// Full spatialization of one source: distance gain, stereo pan and Doppler,
/// cross-faded by `params.blend`.
pub fn spatialize(listener: Listener, source_position: Vec3, source_velocity: Vec3, params: Params) SpatialResult {
    const blend = std.math.clamp(params.blend, 0, 1);
    const distance = transform.length(transform.sub(source_position, listener.position));
    const attenuation = params.attenuation.gainAt(distance);
    const doppler = dopplerScale(listener, source_position, source_velocity, params.doppler);
    return .{
        .gain = 1.0 + (attenuation - 1.0) * blend,
        .pan = panFor(listener, source_position) * blend,
        .pitch = 1.0 + (doppler - 1.0) * blend,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "spatial: attenuation models match their formulas and clamp the distance" {
    const linear = Attenuation{ .model = .linear, .min_distance = 2, .max_distance = 10, .rolloff = 1 };
    try testing.expectEqual(@as(f32, 1), linear.gainAt(0));
    try testing.expectEqual(@as(f32, 1), linear.gainAt(2));
    try testing.expectEqual(@as(f32, 0.5), linear.gainAt(6));
    try testing.expectEqual(@as(f32, 0), linear.gainAt(10));
    try testing.expectEqual(@as(f32, 0), linear.gainAt(1000)); // clamped at max

    const inverse = Attenuation{ .model = .inverse, .min_distance = 1, .max_distance = 100, .rolloff = 1 };
    try testing.expectEqual(@as(f32, 1), inverse.gainAt(0));
    try testing.expectEqual(@as(f32, 1), inverse.gainAt(1));
    try testing.expectEqual(@as(f32, 0.5), inverse.gainAt(2));
    try testing.expectEqual(@as(f32, 0.1), inverse.gainAt(10));
    // Beyond max_distance the gain freezes at its value at max_distance.
    try testing.expectEqual(inverse.gainAt(100), inverse.gainAt(1000));

    const expo = Attenuation{ .model = .exponential, .min_distance = 1, .max_distance = 100, .rolloff = 2 };
    try testing.expectEqual(@as(f32, 1), expo.gainAt(1));
    try testing.expectEqual(@as(f32, 0.25), expo.gainAt(2));
    try testing.expectEqual(@as(f32, 0.01), expo.gainAt(10));

    const none = Attenuation{ .model = .none, .min_distance = 1, .max_distance = 2 };
    try testing.expectEqual(@as(f32, 1), none.gainAt(1000));
}

test "spatial: rolloff zero disables falloff and degenerate ranges stay unity" {
    const flat = Attenuation{ .model = .inverse, .rolloff = 0 };
    try testing.expectEqual(@as(f32, 1), flat.gainAt(50));
    const flat_expo = Attenuation{ .model = .exponential, .rolloff = 0 };
    try testing.expectEqual(@as(f32, 1), flat_expo.gainAt(50));

    // A zero-width range has no slope: no division by zero, no NaN.
    const point = Attenuation{ .model = .linear, .min_distance = 5, .max_distance = 5 };
    try testing.expectEqual(@as(f32, 1), point.gainAt(1));
    try testing.expectEqual(@as(f32, 1), point.gainAt(99));

    // A rolloff greater than 1 clamps at silence instead of going negative.
    const steep = Attenuation{ .model = .linear, .min_distance = 0, .max_distance = 10, .rolloff = 4 };
    try testing.expectEqual(@as(f32, 0), steep.gainAt(10));
}

test "spatial: attenuation rejects invalid settings and non-finite distances" {
    try testing.expect(!(Attenuation{ .min_distance = 0 }).isValid());
    try testing.expect(!(Attenuation{ .min_distance = -1 }).isValid());
    try testing.expect(!(Attenuation{ .min_distance = 10, .max_distance = 1 }).isValid());
    try testing.expect(!(Attenuation{ .rolloff = -1 }).isValid());
    try testing.expect(!(Attenuation{ .min_distance = std.math.nan(f32) }).isValid());
    try testing.expect(!(Attenuation{ .max_distance = std.math.inf(f32) }).isValid());
    try testing.expect((Attenuation{}).isValid());

    const a = Attenuation{};
    try testing.expectEqual(@as(f32, 0), a.gainAt(std.math.nan(f32)));
    try testing.expectEqual(@as(f32, 0), a.gainAt(std.math.inf(f32)));
}

test "spatial: listener basis is right-handed and survives a scaled matrix" {
    const listener = Listener{};
    try testing.expect(listener.isValid());
    // Default looks down -Z with +Y up, so right is +X.
    const r = listener.right();
    try testing.expectApproxEqAbs(@as(f32, 1), r[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), r[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), r[2], 1e-6);

    // A world matrix with translation, a 90-degree Y rotation and uniform scale.
    const world = transform.fromTransform(.{
        .position = .{ 3, 4, 5 },
        .rotation = transform.quatFromAxisAngle(.{ 0, 1, 0 }, std.math.pi / 2.0),
        .scale = .{ 2, 2, 2 },
    });
    const rotated = Listener.fromMatrix(world);
    try testing.expect(rotated.isValid());
    try testing.expectEqualSlices(f32, &[_]f32{ 3, 4, 5 }, &rotated.position);
    // Forward was -Z; rotating +90 degrees about Y points it at -X.
    try testing.expectApproxEqAbs(@as(f32, -1), rotated.forward[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), rotated.forward[2], 1e-5);
    // Basis stays orthonormal despite the scale.
    try testing.expectApproxEqAbs(@as(f32, 1), transform.length(rotated.forward), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), transform.length(rotated.up), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), transform.length(rotated.right()), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), transform.dot(rotated.forward, rotated.up), 1e-5);
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 0, 0 }, &rotated.velocity);
}

test "spatial: a degenerate listener matrix falls back to the identity basis" {
    var world = transform.identity();
    world[12] = 7;
    world[13] = 8;
    world[14] = 9;
    // Collapse the rotation/scale block to zero.
    world[4] = 0;
    world[5] = 0;
    world[6] = 0;
    const listener = Listener.fromMatrix(world);
    try testing.expect(listener.isValid());
    try testing.expectEqualSlices(f32, &[_]f32{ 7, 8, 9 }, &listener.position);
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 0, -1 }, &listener.forward);
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 1, 0 }, &listener.up);

    // Parallel forward/up is degenerate too.
    try testing.expect(!(Listener{ .forward = .{ 0, 1, 0 }, .up = .{ 0, 2, 0 } }).isValid());
    try testing.expect(!(Listener{ .forward = .{ 0, 0, 0 } }).isValid());
    try testing.expect(!(Listener{ .position = .{ std.math.nan(f32), 0, 0 } }).isValid());
    try testing.expect(!(Listener{ .velocity = .{ 0, std.math.inf(f32), 0 } }).isValid());
}

test "spatial: panning follows the azimuth and ignores elevation" {
    const listener = Listener{};
    try testing.expectApproxEqAbs(@as(f32, 1), panFor(listener, .{ 10, 0, 0 }), 1e-6); // right
    try testing.expectApproxEqAbs(@as(f32, -1), panFor(listener, .{ -10, 0, 0 }), 1e-6); // left
    try testing.expectApproxEqAbs(@as(f32, 0), panFor(listener, .{ 0, 0, -10 }), 1e-6); // ahead
    try testing.expectApproxEqAbs(@as(f32, 0), panFor(listener, .{ 0, 0, 10 }), 1e-6); // behind
    try testing.expectApproxEqAbs(@as(f32, 0), panFor(listener, .{ 0, 10, 0 }), 1e-6); // above
    try testing.expectApproxEqAbs(@as(f32, 0), panFor(listener, .{ 0, 0, 0 }), 1e-6); // coincident
    // 45 degrees to the right pans by sin(45).
    try testing.expectApproxEqAbs(@as(f32, 0.70710678), panFor(listener, .{ 10, 0, -10 }), 1e-6);

    // A listener facing +X has its right axis at +Z.
    const turned = Listener{ .forward = .{ 1, 0, 0 }, .up = .{ 0, 1, 0 } };
    try testing.expectApproxEqAbs(@as(f32, 1), panFor(turned, .{ 0, 0, 10 }), 1e-6);
}

test "spatial: doppler rises when closing and falls when opening" {
    const settings = Doppler{ .factor = 1, .speed_of_sound = 340, .max_pitch = 2 };
    const listener = Listener{};
    const ahead: Vec3 = .{ 0, 0, -100 };

    // Nothing moves: no shift.
    try testing.expectEqual(@as(f32, 1), dopplerScale(listener, ahead, .{ 0, 0, 0 }, settings));
    // Factor 0 disables the effect entirely.
    try testing.expectEqual(@as(f32, 1), dopplerScale(listener, ahead, .{ 0, 0, 100 }, .{ .factor = 0 }));

    // Source approaching the listener (moving +Z toward the origin).
    const closing = dopplerScale(listener, ahead, .{ 0, 0, 34 }, settings);
    try testing.expectApproxEqAbs(@as(f32, 340.0 / 306.0), closing, 1e-5);
    try testing.expect(closing > 1);
    // Source receding.
    const opening = dopplerScale(listener, ahead, .{ 0, 0, -34 }, settings);
    try testing.expectApproxEqAbs(@as(f32, 340.0 / 374.0), opening, 1e-5);
    try testing.expect(opening < 1);

    // Listener chasing the source raises the pitch as well.
    const chasing = dopplerScale(
        Listener{ .velocity = .{ 0, 0, -34 } },
        ahead,
        .{ 0, 0, 0 },
        settings,
    );
    try testing.expectApproxEqAbs(@as(f32, 374.0 / 340.0), chasing, 1e-5);

    // Both moving identically: relative velocity is zero, no shift.
    const together = dopplerScale(
        Listener{ .velocity = .{ 0, 0, -34 } },
        ahead,
        .{ 0, 0, -34 },
        settings,
    );
    try testing.expectApproxEqAbs(@as(f32, 1), together, 1e-6);
}

test "spatial: doppler is clamped and safe for supersonic and coincident cases" {
    const settings = Doppler{ .factor = 1, .speed_of_sound = 340, .max_pitch = 2 };
    const listener = Listener{};
    const ahead: Vec3 = .{ 0, 0, -100 };

    // A source faster than sound would invert the denominator; it is floored
    // and the result clamps at max_pitch instead of exploding or going negative.
    const supersonic = dopplerScale(listener, ahead, .{ 0, 0, 10000 }, settings);
    try testing.expectEqual(@as(f32, 2), supersonic);
    const runaway = dopplerScale(listener, ahead, .{ 0, 0, -10000 }, settings);
    try testing.expectEqual(@as(f32, 0.5), runaway);
    try testing.expect(std.math.isFinite(supersonic) and std.math.isFinite(runaway));

    // Coincident source has no direction, so no shift.
    try testing.expectEqual(@as(f32, 1), dopplerScale(listener, .{ 0, 0, 0 }, .{ 0, 0, 500 }, settings));

    try testing.expect(!(Doppler{ .factor = -1 }).isValid());
    try testing.expect(!(Doppler{ .speed_of_sound = 0 }).isValid());
    try testing.expect(!(Doppler{ .max_pitch = 0.5 }).isValid());
    try testing.expect((Doppler{}).isValid());
}

test "spatial: spatialize blends between 2D and 3D" {
    const listener = Listener{};
    const source: Vec3 = .{ 10, 0, 0 }; // hard right, 10 units away
    const attenuation = Attenuation{ .model = .inverse, .min_distance = 1, .max_distance = 100 };

    const full = spatialize(listener, source, .{ 0, 0, 0 }, .{ .attenuation = attenuation, .blend = 1 });
    try testing.expectApproxEqAbs(@as(f32, 0.1), full.gain, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), full.pan, 1e-6);
    try testing.expectEqual(@as(f32, 1), full.pitch);

    const flat = spatialize(listener, source, .{ 0, 0, 0 }, .{ .attenuation = attenuation, .blend = 0 });
    try testing.expectEqual(@as(f32, 1), flat.gain);
    try testing.expectEqual(@as(f32, 0), flat.pan);
    try testing.expectEqual(@as(f32, 1), flat.pitch);

    const half = spatialize(listener, source, .{ 0, 0, 0 }, .{ .attenuation = attenuation, .blend = 0.5 });
    try testing.expectApproxEqAbs(@as(f32, 0.55), half.gain, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), half.pan, 1e-6);

    // Out-of-range blend is clamped, never extrapolated.
    const over = spatialize(listener, source, .{ 0, 0, 0 }, .{ .attenuation = attenuation, .blend = 5 });
    try testing.expectApproxEqAbs(full.gain, over.gain, 1e-6);
    try testing.expect(!(Params{ .blend = std.math.nan(f32) }).isValid());
    try testing.expect(!(Params{ .attenuation = .{ .rolloff = -1 } }).isValid());
    try testing.expect((Params{}).isValid());
}

test "spatial: spatialize folds doppler into the pitch and scales it by blend" {
    const listener = Listener{};
    const params = Params{
        .attenuation = .{ .model = .none },
        .doppler = .{ .factor = 1, .speed_of_sound = 340, .max_pitch = 2 },
        .blend = 1,
    };
    const approaching = spatialize(listener, .{ 0, 0, -100 }, .{ 0, 0, 34 }, params);
    try testing.expectApproxEqAbs(@as(f32, 340.0 / 306.0), approaching.pitch, 1e-5);
    try testing.expectEqual(@as(f32, 1), approaching.gain); // .none attenuation

    var half = params;
    half.blend = 0.5;
    const blended = spatialize(listener, .{ 0, 0, -100 }, .{ 0, 0, 34 }, half);
    try testing.expectApproxEqAbs(1.0 + (approaching.pitch - 1.0) * 0.5, blended.pitch, 1e-6);

    // Every result is finite and usable by the mixer even at extreme inputs.
    const extreme = spatialize(listener, .{ 1e30, 0, 0 }, .{ 1e30, 0, 0 }, params);
    try testing.expect(std.math.isFinite(extreme.gain));
    try testing.expect(std.math.isFinite(extreme.pan));
    try testing.expect(std.math.isFinite(extreme.pitch));
    try testing.expect(extreme.pitch > 0);
}
