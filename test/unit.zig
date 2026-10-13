//! Tests that need no reference: the original's own suite, and properties
//! checked against an independent model.

comptime {
    _ = @import("original_test.zig");
    _ = @import("property_test.zig");
}
