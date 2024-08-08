const std = @import("std");

const LOG_TIME_FMT = "({d:<5} ms){s}";

/// Timer struct to help with measuring code blocks. Very cheap to create/copy, make as many of these as you want.
pub const Timer = struct {
    const Self = @This();

    start_timestamp_ms: i64 = 0,
    last_timestamp_ms: i64 = 0,

    pub fn init() Self {
        var timer = Self{};
        timer.begin();
        return timer;
    }

    pub fn begin(self: *Self) void {
        self.start_timestamp_ms = std.time.milliTimestamp();
        self.last_timestamp_ms = self.start_timestamp_ms;
    }

    pub fn elapsed(self: *Self) i64 {
        const now = std.time.milliTimestamp();
        const result = now - self.last_timestamp_ms;
        self.last_timestamp_ms = now;
        return result;
    }

    pub fn elapsedTotal(self: *Self) i64 {
        self.last_timestamp_ms = std.time.milliTimestamp();
        return self.last_timestamp_ms - self.start_timestamp_ms;
    }

    pub inline fn logInfoElapsed(self: *Self, msg: []const u8) void {
        std.log.info(LOG_TIME_FMT, .{ self.elapsed(), msg });
    }

    pub inline fn logInfoElapsedTotal(self: *Self, msg: []const u8) void {
        std.log.info(LOG_TIME_FMT, .{ self.elapsedTotal(), msg });
    }
};

test "timer" {
    var timer = Timer.init();
    try std.testing.expect(timer.start_timestamp_ms > 0);
    try std.testing.expect(timer.last_timestamp_ms == timer.start_timestamp_ms);

    timer.start_timestamp_ms = 0;
    timer.last_timestamp_ms = 1; // so that elapsedTotal is larger than elapsed.
    const elapsed1 = timer.elapsed();
    try std.testing.expect(elapsed1 > 0); 
    try std.testing.expect(timer.elapsedTotal() > elapsed1);
}