//! The `DrawResources` provider of the anisotropic-quality test in `raster.zig`.
//!
//! It lives in its own file because the test's provider methods must be named
//! `mesh`/`color` — the contract's duck-typed names — and those names are already
//! bound to locals inside that test body. Declaring it here keeps the test honest
//! (it drives the real contract) without renaming the numbers it works with.

const raster = @import("raster.zig");

pub const Provider = struct {
    tex: raster.Texture,
    quad: raster.Mesh,

    pub fn mesh(self: Provider, _: u32) ?raster.Mesh {
        return self.quad;
    }

    pub fn color(self: Provider, _: u32) ?[4]f32 {
        _ = self;
        return .{ 1, 1, 1, 1 };
    }

    pub fn texture(self: Provider, _: u32) ?raster.Texture {
        return self.tex;
    }
};
