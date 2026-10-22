//! By-name JIT invoke resolves the export from `CompiledWasm.exports`, built
//! once at compile, never by re-parsing the module per call.
//!
//! Re-parsing made every `Instance.invoke` on the JIT cost time proportional
//! to the module (two section walks + an export-section decode per call), so a
//! trivial export on a 47 KB module paid ~5 us a call against ~0.5 us on the
//! interpreter (cljw card CLJW-WASM-JIT-PERCALL-SCALES). The re-parse
//! allocated; the table lookup does not, so a by-name invoke and signature
//! lookup that succeed under a failing allocator pin the fix.

const std = @import("std");
const testing = std.testing;

const runner = @import("runner.zig");
const JitInstance = runner.JitInstance;

// (module
//   (memory (export "mem") 1)
//   (func (export "add") (param i32 i32) (result i32)
//     local.get 0 local.get 1 i32.add))
const add_with_mem = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type: (i32 i32)->i32
    0x03, 0x02, 0x01, 0x00, // func: type 0
    0x05, 0x03, 0x01, 0x00, 0x01, // memory: min 1
    0x07, 0x0d, 0x02, // export section, 2 entries
    0x03, 0x6d, 0x65, 0x6d, 0x02, 0x00, // "mem" memory 0
    0x03, 0x61, 0x64, 0x64, 0x00, 0x00, // "add" func 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b, // code
};

test "by-name JIT invoke and signature lookup allocate nothing per call" {
    var inst = try JitInstance.init(testing.allocator, &add_with_mem);
    defer inst.deinit(testing.allocator);
    const no_alloc = testing.failing_allocator;
    try testing.expectEqual(@as(u32, 0), try inst.exportFuncIdx(no_alloc, "add"));
    const sig = inst.exportFuncSig(no_alloc, "add") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), sig.params.len);
    try testing.expectEqual(@as(?u64, 5), try inst.invoke(no_alloc, "add", &.{ 2, 3 }));
}

test "by-name JIT lookup keeps its error kinds for a non-func and a missing export" {
    var inst = try JitInstance.init(testing.allocator, &add_with_mem);
    defer inst.deinit(testing.allocator);
    try testing.expectError(runner.Error.ExportIsNotFunction, inst.exportFuncIdx(testing.allocator, "mem"));
    try testing.expectError(runner.Error.ExportNotFound, inst.exportFuncIdx(testing.allocator, "nope"));
    try testing.expect(inst.exportFuncSig(testing.allocator, "nope") == null);
}
