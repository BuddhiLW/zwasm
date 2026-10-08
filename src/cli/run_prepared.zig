//! A WASI command compiled once and run many times (`PreparedWasi`).
//!
//! `runWasmCapturedFull` validates, JIT-compiles and instantiates on every
//! call. For an embedder that runs the same command repeatedly (one process,
//! many requests) the first two are per-MODULE work: `PreparedWasi.init` does
//! them once, and `run` pays only the per-call half — a fresh store, WASI host
//! and instance, with argv / stdio / preopens / env / limits applied exactly as
//! the cold path applies them. Output, exit codes and diagnostics match
//! `runWasmCapturedFull` on the same bytes.
//!
//! Zone 3, beside `run.zig`.

const std = @import("std");

const cli_run = @import("run.zig");
const runner = @import("../engine/runner.zig");
const api_instance = @import("../api/instance.zig");
const instantiate = @import("../runtime/instance/instantiate.zig");
const diagnostic = @import("../diagnostic/diagnostic.zig");

pub const EngineKind = api_instance.EngineKind;

pub const PrepareError = error{ ModuleAllocFailed, OutOfMemory };

pub const PreparedWasi = struct {
    alloc: std.mem.Allocator,
    /// Owned copy of the module bytes.
    bytes: []u8,
    /// The engine every run uses. `.auto` whose JIT compile declined the
    /// module becomes `.interp` here, so later runs skip the doomed compile.
    engine: EngineKind,
    /// The JIT code every run instantiates from; null when the engine is
    /// `.interp` or the compile did not succeed.
    compiled: ?*runner.CompiledWasm,
    /// The default entry (`_start`, else `main`), owned; null when the policy
    /// refuses the module, in which case each run reports the refusal itself.
    entry_name: ?[]u8,

    /// Validate `bytes` and, unless `engine` is `.interp`, JIT-compile them.
    /// A module the front end rejects fails here with the same diagnostic
    /// `runWasmCapturedFull` sets. A JIT validity verdict is not raised here:
    /// `compiled` stays null and every run reports it as the cold path does.
    pub fn init(alloc: std.mem.Allocator, bytes: []const u8, engine: EngineKind) PrepareError!PreparedWasi {
        diagnostic.clearDiag();
        if (!instantiate.frontendValidate(alloc, bytes)) {
            if (diagnostic.lastDiagnostic() == null) {
                diagnostic.setDiag(.instantiate, .module_alloc_failed, .unknown, "module decode/validate failed", .{});
            }
            return error.ModuleAllocFailed;
        }
        const owned = try alloc.dupe(u8, bytes);
        errdefer alloc.free(owned);

        var effective = engine;
        var compiled: ?*runner.CompiledWasm = null;
        errdefer if (compiled) |c| {
            c.deinit(alloc);
            alloc.destroy(c);
        };
        if (engine != .interp) {
            const slot = try alloc.create(runner.CompiledWasm);
            if (runner.compileWasm(alloc, owned)) |c| {
                slot.* = c;
                compiled = slot;
            } else |err| {
                alloc.destroy(slot);
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (engine == .auto and !api_instance.isValidityVerdict(err)) effective = .interp;
            }
        }

        const entry_name: ?[]u8 = if (cli_run.resolveDefaultEntry(alloc, owned)) |name|
            try alloc.dupe(u8, name)
        else |_|
            null;
        diagnostic.clearDiag();

        return .{ .alloc = alloc, .bytes = owned, .engine = effective, .compiled = compiled, .entry_name = entry_name };
    }

    /// Free the compiled code and bytes. No run may be in progress.
    pub fn deinit(self: *PreparedWasi) void {
        if (self.compiled) |c| {
            c.deinit(self.alloc);
            self.alloc.destroy(c);
        }
        if (self.entry_name) |n| self.alloc.free(n);
        self.alloc.free(self.bytes);
        self.* = undefined;
    }

    /// One run of the command's default entry: `runWasmCapturedFull`'s
    /// contract with no `--invoke`. `limits.engine` is ignored; the engine is
    /// the one fixed at `init`. `self` is never written, so a run adds no
    /// shared state beyond what `runWasmCapturedFull` already has; the
    /// engine's process-wide threading rule (ROADMAP §7) applies unchanged.
    pub fn run(
        self: *const PreparedWasi,
        alloc: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
        stdout_capture: ?*std.ArrayList(u8),
        stderr_capture: ?*std.ArrayList(u8),
        stdin: cli_run.StdinSource,
        preopens: []const cli_run.PreopenDir,
        env_keys: []const []const u8,
        env_vals: []const []const u8,
        limits: cli_run.Limits,
    ) !u8 {
        var l = limits;
        l.engine = self.engine;
        return cli_run.runCapturedPrecompiled(
            alloc,
            io,
            self.bytes,
            .{ .validated = true, .jit = self.compiled },
            argv,
            stdout_capture,
            stderr_capture,
            stdin,
            self.entry_name,
            preopens,
            env_keys,
            env_vals,
            null,
            l,
        );
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

// `(module (import "wasi_snapshot_preview1" "proc_exit" (func (param i32)))
//          (func (export "main") i32.const 42 call 0))`
const proc_exit_42_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x02, 0x60, 0x01, 0x7F, 0x00, 0x60,
    0x00, 0x00, 0x02, 0x24, 0x01, 0x16, 0x77, 0x61,
    0x73, 0x69, 0x5F, 0x73, 0x6E, 0x61, 0x70, 0x73,
    0x68, 0x6F, 0x74, 0x5F, 0x70, 0x72, 0x65, 0x76,
    0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6F,
    0x63, 0x5F, 0x65, 0x78, 0x69, 0x74, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x01, 0x07, 0x08, 0x01, 0x04,
    0x6D, 0x61, 0x69, 0x6E, 0x00, 0x01, 0x0A, 0x08,
    0x01, 0x06, 0x00, 0x41, 0x2A, 0x10, 0x00, 0x0B,
};

// `test/wasi/stdin_echo.wat` (issue #257): fd_read <=32 bytes from fd 0,
// fd_write them to fd 1, proc_exit(nread).
const stdin_echo_wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x10, 0x03, 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x00, 0x02, 0x67, 0x03, 0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x07, 0x66, 0x64, 0x5f, 0x72, 0x65, 0x61, 0x64, 0x00, 0x00, 0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x08, 0x66, 0x64, 0x5f, 0x77, 0x72, 0x69, 0x74, 0x65, 0x00, 0x00, 0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e, 0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6f, 0x63, 0x5f, 0x65, 0x78, 0x69, 0x74, 0x00, 0x01, 0x03, 0x02, 0x01, 0x02, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x13, 0x02, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x03, 0x0a, 0x5e, 0x01, 0x5c, 0x01, 0x02, 0x7f, 0x03, 0x40, 0x41, 0x00, 0x41, 0xc0, 0x00, 0x36, 0x02, 0x00, 0x41, 0x04, 0x41, 0x20, 0x36, 0x02, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x01, 0x41, 0x10, 0x10, 0x00, 0x21, 0x01, 0x20, 0x01, 0x04, 0x40, 0x41, 0xe4, 0x00, 0x20, 0x01, 0x6a, 0x10, 0x02, 0x0b, 0x41, 0x10, 0x28, 0x02, 0x00, 0x04, 0x40, 0x41, 0x04, 0x41, 0x10, 0x28, 0x02, 0x00, 0x36, 0x02, 0x00, 0x41, 0x01, 0x41, 0x00, 0x41, 0x01, 0x41, 0x14, 0x10, 0x01, 0x1a, 0x20, 0x00, 0x41, 0x10, 0x28, 0x02, 0x00, 0x6a, 0x21, 0x00, 0x0c, 0x01, 0x0b, 0x0b, 0x20, 0x00, 0x10, 0x02, 0x0b, 0x00, 0x43, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x01, 0x1f, 0x03, 0x00, 0x07, 0x66, 0x64, 0x5f, 0x72, 0x65, 0x61, 0x64, 0x01, 0x08, 0x66, 0x64, 0x5f, 0x77, 0x72, 0x69, 0x74, 0x65, 0x02, 0x09, 0x70, 0x72, 0x6f, 0x63, 0x5f, 0x65, 0x78, 0x69, 0x74, 0x02, 0x0f, 0x01, 0x03, 0x02, 0x00, 0x05, 0x74, 0x6f, 0x74, 0x61, 0x6c, 0x01, 0x03, 0x65, 0x72, 0x72, 0x03, 0x0a, 0x01, 0x03, 0x01, 0x00, 0x05, 0x61, 0x67, 0x61, 0x69, 0x6e };

// `(module (func (export "_start") unreachable))` — a trap with no exit code.
const unreachable_start_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x05,
    0x01, 0x03, 0x00, 0x00, 0x0b,
};

// `(module (func (export "_start") (loop br 0)))` — runs until a limit stops it.
const infinite_loop_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x09,
    0x01, 0x07, 0x00, 0x03, 0x40, 0x0c, 0x00, 0x0b,
    0x0b,
};

fn runEcho(p: *const PreparedWasi, input: []const u8, out: *std.ArrayList(u8)) !u8 {
    return p.run(testing.allocator, testing.io, &.{}, out, null, .{ .bytes = input }, &.{}, &.{}, &.{}, .{});
}

test "PreparedWasi: each run gets its own stdin and capture; output matches the cold path on every engine" {
    inline for (.{ EngineKind.auto, EngineKind.jit, EngineKind.interp }) |kind| {
        var p = try PreparedWasi.init(testing.allocator, &stdin_echo_wasm, kind);
        defer p.deinit();
        try testing.expectEqual(kind == .interp, p.compiled == null);

        for ([_][]const u8{ "hello\n", "", "a second, longer line\n" }) |input| {
            var warm: std.ArrayList(u8) = .empty;
            defer warm.deinit(testing.allocator);
            const warm_code = try runEcho(&p, input, &warm);

            var cold: std.ArrayList(u8) = .empty;
            defer cold.deinit(testing.allocator);
            const cold_code = try cli_run.runWasmCapturedFull(testing.allocator, testing.io, &stdin_echo_wasm, &.{}, &cold, null, .{ .bytes = input }, null, &.{}, &.{}, &.{}, null, .{ .engine = kind });

            try testing.expectEqual(@as(u8, @intCast(input.len)), warm_code);
            try testing.expectEqual(cold_code, warm_code);
            try testing.expectEqualStrings(cold.items, warm.items);
            try testing.expectEqualStrings(input, warm.items);
        }
    }
}

test "PreparedWasi: proc_exit and a trap map to the cold path's exit codes, run after run" {
    var exit42 = try PreparedWasi.init(testing.allocator, &proc_exit_42_wasm, .auto);
    defer exit42.deinit();
    var trap = try PreparedWasi.init(testing.allocator, &unreachable_start_wasm, .auto);
    defer trap.deinit();
    for (0..3) |_| {
        try testing.expectEqual(@as(u8, 42), try exit42.run(testing.allocator, testing.io, &.{}, null, null, .none, &.{}, &.{}, &.{}, .{}));
        try testing.expectEqual(@as(u8, 1), try trap.run(testing.allocator, testing.io, &.{}, null, null, .none, &.{}, &.{}, &.{}, .{}));
    }
}

test "PreparedWasi: fuel and timeout are per run, not per module" {
    var p = try PreparedWasi.init(testing.allocator, &infinite_loop_wasm, .auto);
    defer p.deinit();
    try testing.expectEqual(@as(u8, 1), try p.run(testing.allocator, testing.io, &.{}, null, null, .none, &.{}, &.{}, &.{}, .{ .fuel = 10_000 }));
    try testing.expectEqual(@as(u8, 1), try p.run(testing.allocator, testing.io, &.{}, null, null, .none, &.{}, &.{}, &.{}, .{ .timeout_ms = 20 }));
}

test "PreparedWasi: a module the front end rejects fails at init with the cold path's error" {
    const malformed = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0xff, 0xff, 0xff, 0xff };
    try testing.expectError(error.ModuleAllocFailed, PreparedWasi.init(testing.allocator, &malformed, .auto));
    try testing.expect(diagnostic.lastDiagnostic() != null);
}

test "PreparedWasi: two prepared modules interleave; each store frees its instance, the code survives" {
    var a = try PreparedWasi.init(testing.allocator, &stdin_echo_wasm, .jit);
    defer a.deinit();
    var b = try PreparedWasi.init(testing.allocator, &stdin_echo_wasm, .jit);
    defer b.deinit();
    for ([_][]const u8{ "abc", "de", "f" }) |input| {
        inline for (.{ &a, &b }) |p| {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(testing.allocator);
            try testing.expectEqual(@as(u8, @intCast(input.len)), try runEcho(p, input, &out));
            try testing.expectEqualStrings(input, out.items);
        }
    }
}
