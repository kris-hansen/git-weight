const std = @import("std");

/// Default spacing between heartbeat dots.
pub const default_interval: std.Io.Duration = .fromMilliseconds(250);

/// The heartbeat is shown only for a bare `git-weight` invocation (no
/// arguments at all) and only when stderr is a terminal, so redirected or
/// captured stderr stays byte-for-byte unchanged.
pub fn shouldShow(arg_count: usize, stderr_is_tty: bool) bool {
    return arg_count == 0 and stderr_is_tty;
}

/// Prints a '.' to `out` every `interval` from a background thread until
/// `finish` is called. `finish` terminates the dot line with a newline (only
/// if at least one dot was written), so subsequent output starts on a clean
/// line. `out` must not be written by anyone else between `start` and
/// `finish`; after `finish` returns the worker has exited.
pub const Heartbeat = struct {
    io: std.Io,
    out: *std.Io.Writer,
    interval: std.Io.Duration = default_interval,
    stop: std.Io.Event = .unset,
    thread: ?std.Thread = null,
    /// Dots written; owned by the worker until it is joined.
    dots: usize = 0,

    /// Spawns the worker. If spawning fails the run simply has no heartbeat.
    pub fn start(self: *Heartbeat) void {
        std.debug.assert(self.thread == null);
        self.thread = std.Thread.spawn(.{}, worker, .{self}) catch null;
    }

    /// Stops and joins the worker, then ends the dot line. Idempotent, and
    /// safe to call without a prior `start`.
    pub fn finish(self: *Heartbeat) void {
        const t = self.thread orelse return;
        self.stop.set(self.io);
        t.join();
        self.thread = null;
        if (self.dots > 0) {
            self.dots = 0;
            self.out.writeByte('\n') catch return;
            self.out.flush() catch {};
        }
    }

    fn worker(self: *Heartbeat) void {
        const clock: std.Io.Clock = .awake;
        const step: std.Io.Clock.Duration = .{ .raw = self.interval, .clock = clock };
        var deadline = std.Io.Clock.Timestamp.now(self.io, clock).addDuration(step);
        while (true) {
            self.stop.waitTimeout(self.io, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Timeout => {
                    // waitTimeout also reports spurious wakeups as Timeout.
                    if (std.Io.Clock.Timestamp.now(self.io, clock).compare(.lt, deadline)) continue;
                    self.out.writeByte('.') catch return;
                    self.out.flush() catch return;
                    self.dots += 1;
                    deadline = deadline.addDuration(step);
                    continue;
                },
                error.Canceled => return,
            };
            return;
        }
    }
};

test "shouldShow only for bare invocation on a terminal" {
    try std.testing.expect(shouldShow(0, true));
    try std.testing.expect(!shouldShow(0, false));
    try std.testing.expect(!shouldShow(1, true));
    try std.testing.expect(!shouldShow(3, true));
}

test "finish without start is a no-op" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var hb: Heartbeat = .{ .io = std.testing.io, .out = &buf.writer };
    hb.finish();
    hb.finish();
    try std.testing.expectEqualStrings("", buf.written());
}

test "finish before first tick writes nothing" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var hb: Heartbeat = .{ .io = std.testing.io, .out = &buf.writer, .interval = .fromSeconds(3600) };
    hb.start();
    hb.finish();
    try std.testing.expectEqualStrings("", buf.written());
    try std.testing.expect(hb.thread == null);
}

test "dots are terminated by exactly one newline" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var hb: Heartbeat = .{ .io = std.testing.io, .out = &buf.writer, .interval = .fromMilliseconds(1) };
    hb.start();
    try std.testing.io.sleep(.fromMilliseconds(50), .awake);
    hb.finish();
    hb.finish(); // idempotent: no second newline
    const out = buf.written();
    try std.testing.expect(out.len >= 2);
    try std.testing.expectEqual(@as(u8, '\n'), out[out.len - 1]);
    for (out[0 .. out.len - 1]) |c| try std.testing.expectEqual(@as(u8, '.'), c);
}
