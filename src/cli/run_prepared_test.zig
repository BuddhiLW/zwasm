//! `PreparedWasi` against the cold path: a golden table of module shapes and
//! property tests over random inputs and limit sequences.

const std = @import("std");

const cli_run = @import("run.zig");
const run_prepared = @import("run_prepared.zig");
const diagnostic = @import("../diagnostic/diagnostic.zig");

const PreparedWasi = run_prepared.PreparedWasi;
const EngineKind = run_prepared.EngineKind;
const testing = std.testing;

const engines = [_]EngineKind{ .auto, .jit, .interp };

const Shape = struct { name: []const u8, bytes: []const u8 };

const shapes = [_]Shape{
    .{ .name = "proc_exit_42", .bytes = &run_prepared.test_modules.proc_exit_42 },
    .{ .name = "unreachable", .bytes = &run_prepared.test_modules.unreachable_start },
    .{ .name = "duplicate_export", .bytes = &run_prepared.test_modules.duplicate_export },
    .{ .name = "tail_decline", .bytes = &run_prepared.test_modules.tail_decline_start },
    .{ .name = "no_entry", .bytes = &no_entry_wasm },
    .{ .name = "entry_with_params", .bytes = &entry_with_params_wasm },
    .{ .name = "memory_import", .bytes = &memory_import_wasm },
    .{ .name = "malformed", .bytes = &malformed_wasm },
};

// `(module)`
const no_entry_wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

// `(module (func (export "_start") (param i32)))`
const entry_with_params_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x01, 0x7f, 0x00, 0x03,
    0x02, 0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f,
    0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a,
    0x04, 0x01, 0x02, 0x00, 0x0b,
};

// `(module (import "env" "mem" (memory 1)) (func (export "_start")))`
const memory_import_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x02, 0x0c,
    0x01, 0x03, 0x65, 0x6e, 0x76, 0x03, 0x6d, 0x65,
    0x6d, 0x02, 0x00, 0x01, 0x03, 0x02, 0x01, 0x00,
    0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61,
    0x72, 0x74, 0x00, 0x00, 0x0a, 0x04, 0x01, 0x02,
    0x00, 0x0b,
};

const malformed_wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0xff, 0xff, 0xff, 0xff };

fn noLimitsRun(p: *const PreparedWasi) anyerror!u8 {
    return p.run(testing.allocator, testing.io, &.{}, null, null, .none, &.{}, &.{}, &.{}, .{});
}

fn coldRun(bytes: []const u8, kind: EngineKind) anyerror!u8 {
    return cli_run.runWasmCapturedFull(testing.allocator, testing.io, bytes, &.{}, null, null, .none, null, &.{}, &.{}, &.{}, null, .{ .engine = kind });
}

const Outcome = union(enum) { code: u8, err: anyerror };

fn outcomeOf(r: anyerror!u8) Outcome {
    return if (r) |c| .{ .code = c } else |e| .{ .err = e };
}

fn expectOutcome(want: Outcome, want_diag: ?[]const u8, got: Outcome) !void {
    try testing.expectEqual(want, got);
    const diag: ?[]const u8 = if (diagnostic.lastDiagnostic()) |d| d.message() else null;
    if (want_diag) |m| {
        try testing.expectEqualStrings(m, diag orelse return error.TestExpectedDiagnostic);
    } else {
        try testing.expect(diag == null);
    }
}

/// One shape on one engine: what the cold path and every prepared run return,
/// and what `init` records. `prepared == null` means `init` itself fails with
/// `outcome` and `diag`.
const Cell = struct {
    outcome: Outcome,
    diag: ?[]const u8 = null,
    prepared: ?struct { engine: EngineKind, compiled: bool },
};

fn exits(code: u8, engine: EngineKind, compiled: bool) Cell {
    return .{ .outcome = .{ .code = code }, .prepared = .{ .engine = engine, .compiled = compiled } };
}

fn fails(err: anyerror, diag: []const u8, engine: EngineKind, compiled: bool) Cell {
    return .{ .outcome = .{ .err = err }, .diag = diag, .prepared = .{ .engine = engine, .compiled = compiled } };
}

const no_detail = "instantiation failed (no further detail in phase 1)";
const no_entry_diag = "no exported function found (looked for _start, main)";
const params_diag = "the default entry '_start' takes 1 parameter and none were supplied";
const malformed_diag = "unsupported binary version 4294967295 at offset 0x4 (expected 1)";

/// Golden outcomes, one row per shape in `shapes` order, columns in `engines`
/// order (.auto, .jit, .interp).
const golden = [shapes.len][engines.len]Cell{
    // proc_exit_42
    .{ exits(42, .auto, true), exits(42, .jit, true), exits(42, .interp, false) },
    // unreachable
    .{ exits(1, .auto, true), exits(1, .jit, true), exits(1, .interp, false) },
    // duplicate_export: a validity verdict, not a decline; the interpreter does not check it
    .{
        fails(error.InstanceAllocFailed, "invalid module: DuplicateExport", .auto, false),
        fails(error.InstanceAllocFailed, "invalid module: DuplicateExport", .jit, false),
        exits(0, .interp, false),
    },
    // tail_decline: `.auto` records `.interp` at init
    .{ exits(0, .interp, false), fails(error.InstanceAllocFailed, no_detail, .jit, false), exits(0, .interp, false) },
    // no_entry
    .{
        fails(error.NoFuncExport, no_entry_diag, .auto, true),
        fails(error.NoFuncExport, no_entry_diag, .jit, true),
        fails(error.NoFuncExport, no_entry_diag, .interp, false),
    },
    // entry_with_params
    .{
        fails(error.ArgCountMismatch, params_diag, .auto, true),
        fails(error.ArgCountMismatch, params_diag, .jit, true),
        fails(error.ArgCountMismatch, params_diag, .interp, false),
    },
    // memory_import: unresolved, so linking fails before any JIT setup
    .{
        fails(error.InstanceAllocFailed, no_detail, .auto, true),
        fails(error.InstanceAllocFailed, no_detail, .jit, true),
        fails(error.InstanceAllocFailed, no_detail, .interp, false),
    },
    // malformed: `init` fails as the cold path does
    .{
        .{ .outcome = .{ .err = error.ModuleAllocFailed }, .diag = malformed_diag, .prepared = null },
        .{ .outcome = .{ .err = error.ModuleAllocFailed }, .diag = malformed_diag, .prepared = null },
        .{ .outcome = .{ .err = error.ModuleAllocFailed }, .diag = malformed_diag, .prepared = null },
    },
};

test "PreparedWasi golden: every shape on every engine, cold and warm, run after run" {
    for (shapes, golden) |s, row| {
        for (engines, row) |kind, cell| {
            errdefer std.debug.print("golden cell: {s} on .{s}\n", .{ s.name, @tagName(kind) });
            try expectOutcome(cell.outcome, cell.diag, outcomeOf(coldRun(s.bytes, kind)));

            const want = cell.prepared orelse {
                try expectOutcome(cell.outcome, cell.diag, if (PreparedWasi.init(testing.allocator, s.bytes, kind)) |p| blk: {
                    var q = p;
                    q.deinit();
                    break :blk .{ .code = 0 };
                } else |e| .{ .err = e });
                continue;
            };
            var p = try PreparedWasi.init(testing.allocator, s.bytes, kind);
            defer p.deinit();
            try testing.expectEqual(want.engine, p.engine);
            try testing.expectEqual(want.compiled, p.compiled != null);
            for (0..2) |_| try expectOutcome(cell.outcome, cell.diag, outcomeOf(noLimitsRun(&p)));
        }
    }
}

// ---- Property tests ----------------------------------------------------
//
// Seeded from `testing.random_seed` (the runner's `--seed`), so a failure
// reprints with the seed and the case that broke.

test "PreparedWasi property: any stdin is echoed, and the warm run equals the cold run" {
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const rand = prng.random();

    var prepared: [engines.len]PreparedWasi = undefined;
    var n_init: usize = 0;
    defer for (prepared[0..n_init]) |*p| p.deinit();
    for (engines, 0..) |kind, i| {
        prepared[i] = try PreparedWasi.init(testing.allocator, &run_prepared.test_modules.stdin_echo, kind);
        n_init += 1;
    }

    var input_buf: [64]u8 = undefined;
    for (0..48) |case| {
        const ei = rand.uintLessThan(usize, engines.len);
        const input = input_buf[0..rand.uintAtMost(usize, input_buf.len)];
        rand.bytes(input);
        errdefer std.debug.print("seed 0x{x} case {d}: .{s} stdin {any}\n", .{ testing.random_seed, case, @tagName(engines[ei]), input });

        var warm: std.ArrayList(u8) = .empty;
        defer warm.deinit(testing.allocator);
        const warm_code = try prepared[ei].run(testing.allocator, testing.io, &.{}, &warm, null, .{ .bytes = input }, &.{}, &.{}, &.{}, .{});

        var cold: std.ArrayList(u8) = .empty;
        defer cold.deinit(testing.allocator);
        const cold_code = try cli_run.runWasmCapturedFull(testing.allocator, testing.io, &run_prepared.test_modules.stdin_echo, &.{}, &cold, null, .{ .bytes = input }, null, &.{}, &.{}, &.{}, null, .{ .engine = engines[ei] });

        try testing.expectEqual(@as(u8, @intCast(input.len)), warm_code);
        try testing.expectEqualSlices(u8, input, warm.items);
        try testing.expectEqual(cold_code, warm_code);
        try testing.expectEqualSlices(u8, cold.items, warm.items);
    }
}

/// One step of a random run sequence: which prepared module, and its fuel.
const Step = struct { module: enum { exit42, trap, echo }, fuel: ?u64 };

/// The model: a step's exit code depends on that step alone.
fn modelCode(step: Step, echo_len: usize) u8 {
    if (step.fuel) |f| if (f == 0) return 1;
    return switch (step.module) {
        .exit42 => 42,
        .trap => 1,
        .echo => @intCast(echo_len),
    };
}

test "PreparedWasi property: in any interleaving of runs and limits, each run's result depends on that run alone" {
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const rand = prng.random();
    const fuels = [_]?u64{ null, 0, 1_000_000 };

    for (0..24) |seq| {
        const kind = engines[rand.uintLessThan(usize, engines.len)];
        var exit42 = try PreparedWasi.init(testing.allocator, &run_prepared.test_modules.proc_exit_42, kind);
        defer exit42.deinit();
        var trap = try PreparedWasi.init(testing.allocator, &run_prepared.test_modules.unreachable_start, kind);
        defer trap.deinit();
        var echo = try PreparedWasi.init(testing.allocator, &run_prepared.test_modules.stdin_echo, kind);
        defer echo.deinit();

        const len = 1 + rand.uintLessThan(usize, 12);
        for (0..len) |i| {
            const step: Step = .{
                .module = rand.enumValue(@FieldType(Step, "module")),
                .fuel = fuels[rand.uintLessThan(usize, fuels.len)],
            };
            const echo_input = "abcdefghij"[0..rand.uintAtMost(usize, 10)];
            errdefer std.debug.print("seed 0x{x} seq {d} step {d}: .{s} {s} fuel {?d}\n", .{ testing.random_seed, seq, i, @tagName(kind), @tagName(step.module), step.fuel });

            const p: *const PreparedWasi = switch (step.module) {
                .exit42 => &exit42,
                .trap => &trap,
                .echo => &echo,
            };
            const stdin: cli_run.StdinSource = if (step.module == .echo) .{ .bytes = echo_input } else .none;
            const code = try p.run(testing.allocator, testing.io, &.{}, null, null, stdin, &.{}, &.{}, &.{}, .{ .fuel = step.fuel });
            try testing.expectEqual(modelCode(step, echo_input.len), code);
        }
    }
}
