//! Tests that need no reference: the original's own suite, properties
//! checked against an independent model, and the Ranges layer.

comptime {
    _ = @import("original_test.zig");
    _ = @import("property_test.zig");
    _ = @import("ranges_test.zig");
}
