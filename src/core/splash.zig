//! Splash screen contract.
//!
//! The splash screen reports startup progress. It is defined as a small
//! interface (`SplashScreen`) so a graphical implementation (built on the
//! engine's own GUI library) can be plugged in later without changing the
//! startup pipeline. Until the GUI exists, `HeadlessSplash` reports progress
//! through the log.
//!
//! The startup pipeline opens the splash right after essential services are
//! initialized and closes it on every exit path.

const std = @import("std");

const log = std.log.scoped(.splash);

/// Interface for a splash screen. Implementations provide a vtable; the
/// pipeline only calls these three methods.
pub const SplashScreen = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        show: *const fn (ptr: *anyopaque, project_name: []const u8) void,
        setProgress: *const fn (ptr: *anyopaque, message: []const u8, fraction: f32) void,
        hide: *const fn (ptr: *anyopaque) void,
    };

    pub fn show(self: SplashScreen, project_name: []const u8) void {
        self.vtable.show(self.ptr, project_name);
    }

    /// `fraction` is in [0, 1].
    pub fn setProgress(self: SplashScreen, message: []const u8, fraction: f32) void {
        self.vtable.setProgress(self.ptr, message, fraction);
    }

    pub fn hide(self: SplashScreen) void {
        self.vtable.hide(self.ptr);
    }
};

/// Headless splash: logs progress and records the latest state. Used when no
/// graphical backend is available (the current default) or with `--headless`.
pub const HeadlessSplash = struct {
    is_open: bool = false,
    project_name: []const u8 = "",
    last_message: []const u8 = "",
    progress: f32 = 0,

    pub fn interface(self: *HeadlessSplash) SplashScreen {
        return .{
            .ptr = self,
            .vtable = &.{
                .show = show,
                .setProgress = setProgress,
                .hide = hide,
            },
        };
    }

    fn show(ptr: *anyopaque, project_name: []const u8) void {
        const self: *HeadlessSplash = @ptrCast(@alignCast(ptr));
        self.is_open = true;
        self.project_name = project_name;
        self.progress = 0;
        log.info("opening project \"{s}\"", .{project_name});
    }

    fn setProgress(ptr: *anyopaque, message: []const u8, fraction: f32) void {
        const self: *HeadlessSplash = @ptrCast(@alignCast(ptr));
        self.last_message = message;
        // Clamp to [0, 1] so a caller passing inf/nan/negative can't produce
        // garbled progress logs. Graphical implementations should do the same.
        self.progress = std.math.clamp(fraction, 0.0, 1.0);
        log.info("[{d:.0}%] {s}", .{ self.progress * 100.0, message });
    }

    fn hide(ptr: *anyopaque) void {
        const self: *HeadlessSplash = @ptrCast(@alignCast(ptr));
        self.is_open = false;
        self.progress = 1;
    }
};

test "headless splash records open/progress/close" {
    var splash = HeadlessSplash{};
    const iface = splash.interface();

    iface.show("MyGame");
    try std.testing.expect(splash.is_open);
    try std.testing.expectEqualStrings("MyGame", splash.project_name);

    iface.setProgress("validating manifest", 0.25);
    try std.testing.expectEqualStrings("validating manifest", splash.last_message);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), splash.progress, 0.0001);

    iface.setProgress("indexing assets", 0.6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), splash.progress, 0.0001);

    iface.hide();
    try std.testing.expect(!splash.is_open);
}

test "splash interface dispatches through vtable" {
    var splash = HeadlessSplash{};
    const iface = splash.interface();
    iface.show("X");
    iface.setProgress("step", 0.5);
    iface.hide();
    try std.testing.expect(!splash.is_open);
    try std.testing.expectEqualStrings("step", splash.last_message);
}
