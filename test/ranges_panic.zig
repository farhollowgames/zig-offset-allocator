//! A program that frees a stale `Ranges` handle, which must panic in safe
//! builds. Zig 0.17 cannot catch a panic inside a test, so `zig build test`
//! runs this and expects it to abort with the panic message. The argument
//! picks the case: `double` frees a handle twice, `reset` frees one
//! allocated before a reset.

const std = @import("std");
const oa = @import("offset_allocator");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const case = args[1];

    var ranges = try oa.Ranges.init(init.gpa, 1 << 20, 64, 256);
    defer ranges.deinit(init.gpa);

    const a = try ranges.allocate(1000);
    if (std.mem.eql(u8, case, "double")) {
        ranges.free(a);
    } else if (std.mem.eql(u8, case, "reset")) {
        ranges.reset();
    } else unreachable;
    // Panics: the handle is stale.
    ranges.free(a);
}
