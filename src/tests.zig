//! The test root: every unit test, and the tests that drive the package
//! from outside.
test {
    _ = @import("airlock.zig");
    _ = @import("sys.zig");
    _ = @import("Staged.zig");
    _ = @import("sync_test.zig");
    _ = @import("pending_test.zig");
    _ = @import("batch_test.zig");
    _ = @import("names_test.zig");
    _ = @import("testing/model.zig");
    _ = @import("every_fault_test.zig");
}
