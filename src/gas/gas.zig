const std = @import("std");

/// Gas cost for Move VM operations
pub const GasCost = struct {
    /// Instruction cost
    instruction: u64,
    /// Memory cost per byte
    memory: u64,
};

/// Gas parameters for the Move VM
pub const GasParams = struct {
    /// Stack height gas conversion factor
    stack_height_gas: u64 = 1,
    /// Instruction gas per operation
    instruction_gas: u64 = 1,
    /// Memory gas per byte
    memory_gas_per_byte: u64 = 1,
    /// Maximum gas allowed
    max_gas: u64 = std.math.maxInt(u64),
};

/// Gas tracker for the Move VM
pub const Gas = struct {
    /// Current gas remaining
    remaining: u64,
    /// Gas parameters
    params: GasParams,
    /// Initial gas amount (for calculating gas used)
    initial: u64,

    /// Initialize gas with initial amount
    pub fn init(initial_gas: u64) Gas {
        return .{
            .remaining = initial_gas,
            .params = GasParams{},
            .initial = initial_gas,
        };
    }

    /// Initialize with custom parameters
    pub fn initWithParams(initial_gas: u64, params: GasParams) Gas {
        return .{
            .remaining = initial_gas,
            .params = params,
            .initial = initial_gas,
        };
    }

    /// Check if we have enough gas for an operation
    pub fn canConsume(self: Gas, amount: u64) bool {
        return self.remaining >= amount;
    }

    /// Consume gas for an operation
    pub fn consume(self: *Gas, amount: u64) !void {
        if (self.remaining < amount) {
            return error.OutOfGas;
        }
        self.remaining -= amount;
    }

    /// Get remaining gas
    pub fn getRemaining(self: Gas) u64 {
        return self.remaining;
    }

    /// Get initial gas amount
    pub fn getInitial(self: Gas) u64 {
        return self.initial;
    }

    /// Get amount of gas used
    pub fn getUsed(self: Gas) u64 {
        return self.initial - self.remaining;
    }

    /// Reset gas to new amount
    pub fn reset(self: *Gas, amount: u64) void {
        self.remaining = amount;
        self.initial = amount;
    }
};

var initialized = false;

pub fn isInitialized() bool {
    return initialized;
}

pub fn init() void {
    initialized = true;
}

test "Gas basic" {
    var gas = Gas.init(1000);
    try std.testing.expectEqual(@as(u64, 1000), gas.getRemaining());

    try gas.consume(100);
    try std.testing.expectEqual(@as(u64, 900), gas.getRemaining());
}

test "Gas out of gas" {
    var gas = Gas.init(100);
    try std.testing.expectError(error.OutOfGas, gas.consume(200));
}
