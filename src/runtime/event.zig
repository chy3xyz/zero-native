//! Runtime event and diagnostic types.

/// Lifecycle milestones delivered to the app while the runtime is running.
pub const LifecycleEvent = enum {
    /// App startup completed; initial windows may now be created.
    start,
    /// A frame is being published; useful for per-frame updates.
    frame,
    /// App shutdown initiated; release resources.
    stop,
};

/// A named command dispatched from the UI or system tray.
pub const CommandEvent = struct {
    /// Command identifier used for routing.
    name: []const u8,
};

/// Reasons the runtime may mark the next frame as needing a repaint.
pub const InvalidationReason = enum {
    /// Initial paint before the first frame.
    startup,
    /// Host surface resized.
    surface_resize,
    /// A bridge command changed state.
    command,
    /// Arbitrary state changed via `invalidate`.
    state,
};

/// Per-frame statistics exposed after a frame is published.
pub const FrameDiagnostics = struct {
    /// Monotonic frame counter at publish time.
    frame_index: u64 = 0,
    /// Bridge commands processed this frame.
    command_count: usize = 0,
    /// Dirty regions repainted this frame.
    dirty_region_count: usize = 0,
    /// Placeholder; currently unused.
    resource_upload_count: usize = 0,
    /// Elapsed nanoseconds producing the frame.
    duration_ns: u64 = 0,
};

/// Runtime event delivered to the app via `App.event`.
pub const Event = union(enum) {
    /// Lifecycle milestone such as startup or shutdown.
    lifecycle: LifecycleEvent,
    /// Named command from the UI or system tray.
    command: CommandEvent,

    /// Returns the event's routing name: the lifecycle tag name or command name.
    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .lifecycle => |event_value| @tagName(event_value),
            .command => |event_value| event_value.name,
        };
    }
};
