const std = @import("std");

/// Gas tracker for the Move VM.
pub const Gas = struct {
    remaining: u64,
    initial: u64,

    pub fn init(initial_gas: u64) Gas {
        return .{
            .remaining = initial_gas,
            .initial = initial_gas,
        };
    }

    pub fn canConsume(self: Gas, amount: u64) bool {
        return self.remaining >= amount;
    }

    pub fn consume(self: *Gas, amount: u64) !void {
        if (self.remaining < amount) {
            return error.OutOfGas;
        }
        self.remaining -= amount;
    }

    pub fn getRemaining(self: Gas) u64 {
        return self.remaining;
    }

    pub fn getInitial(self: Gas) u64 {
        return self.initial;
    }

    pub fn getUsed(self: Gas) u64 {
        return self.initial - self.remaining;
    }

    pub fn reset(self: *Gas, amount: u64) void {
        self.remaining = amount;
        self.initial = amount;
    }
};

// ==================== Tests ====================

test "Gas basic" {
    var g = Gas.init(1000);
    try std.testing.expectEqual(@as(u64, 1000), g.getRemaining());
    try g.consume(100);
    try std.testing.expectEqual(@as(u64, 900), g.getRemaining());
    try std.testing.expectEqual(@as(u64, 100), g.getUsed());
}

test "Gas out of gas" {
    var g = Gas.init(100);
    try std.testing.expectError(error.OutOfGas, g.consume(200));
}
