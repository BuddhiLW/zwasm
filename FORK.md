# BuddhiLW/zwasm: the ClojureWasm fork

This fork is the zwasm that [ClojureWasm](https://github.com/BuddhiLW/ClojureWasm)
(`cljw`) embeds. `main` here is upstream [zwasm/zwasm](https://github.com/zwasm/zwasm)
`main` plus the patches below, and cljw's `build.zig.zon` pins a commit of this
`main`.

## How patches move

1. **Found in cljw.** A cljw card, a failing cljw test and a measured repro.
2. **Fixed here** on a `fix/<name>` branch off the fork's `main`, with a zwasm
   unit test. CI must be green on every platform before it merges into the
   fork's `main`.
3. **Proven in cljw.** cljw pins the new fork `main`, ships it in a release,
   and its suites and benches keep the evidence current.
4. **Upstreamed** as a PR to zwasm/zwasm, using the entry below as the PR body.
   Once upstream merges it, the fork's `main` rebases onto upstream and the
   entry moves to "Upstreamed".

The fork never carries a patch without an entry here, and an entry never claims
more than its evidence shows.

## Carried patches

| Patch | Area | Fork PR | Fork `main` | Proven in cljw | Upstream |
|---|---|---|---|---|---|
| Interp native-stack limit per calling thread | interp | [#2](https://github.com/BuddhiLW/zwasm/pull/2) | merged `6d38dfcd` | [cljw#74](https://github.com/BuddhiLW/ClojureWasm/pull/74) merged to cljw staging, not yet released | not yet |
| JIT by-name invoke served from `CompiledWasm.exports` | JIT | [#3](https://github.com/BuddhiLW/zwasm/pull/3) | merged `e9d74934` | [cljw#76](https://github.com/BuddhiLW/ClojureWasm/pull/76), not yet released | not yet |

### Interp native-stack limit per calling thread

**Problem.** `checkNativeStackLimit` computed the native-stack low limit once,
from the first thread that called the instance, and cached it on the
`Runtime`. An embedder that calls the same instance from a second thread whose
stack lies below that limit trapped `CallStackExhausted` on every call.

**How it showed up.** In cljw, a wasm handle on the `:interp` engine used on the
runtime thread and then called inside a `future` trapped
(`wasm/call: 'add' (i32 i32) -> (i32) trapped on the interp engine`). `:jit` and
`:auto` handles, and a fresh handle first called on the worker, were fine.

**Fix.** `79f3d63a`: the limit is computed once per thread in a threadlocal; the
`Runtime` field stays as an explicit override for tests.

**Evidence.**
- zwasm unit test, filter `per calling thread`, green in the fork's CI on
  aarch64-linux, aarch64-macos, x86_64-linux and x86_64-windows.
- cljw suite `test/clj/suites/wasm_thread_hop_test.clj` (`:interp`, `:jit` and
  `:auto`, used 1x and 5000x on the runtime thread, then from a `future`, then
  back; plus a handle first called on a worker): 14 of 14 assertions pass on
  this patch, 2 fail on cljw v1.15.3 (zwasm `d74e63b4`), both the `:interp`
  hops.

**Upstream.** Not yet: waits for a cljw release carrying it.

### JIT by-name invoke served from `CompiledWasm.exports`

**Problem.** Every by-name JIT invoke resolved the export with
`findExportFunc`, a section walk plus an export-section decode, twice per
facade call (upstream D-585, #208). The cost of one call grew with the size of
the module, not with the callee.

**How it showed up.** In cljw, `wasm/call` of a trivial export on the `:jit`
engine cost 1.3 µs on a tiny module but 5.6 to 6.6 µs on a 47 KB module, while
the interpreter stayed at about 0.55 µs on both.

**Fix.** `22a99bb1`: the name is served from `CompiledWasm.exports`, resolved
once at compile time.

**Evidence.**
- zwasm unit test `src/engine/runner_export_lookup_test.zig`.
- cljw `bench/wasm_percall.clj`, median ns per call, 7 x 20k calls,
  ReleaseSafe, same host back to back:

  | cell | before | after |
  |---|---|---|
  | `:jit`, 47 KB module (`bench/wasm/percall/zigcool.wasm`) | 5883 | 833 |
  | `:jit`, `add.wasm` | 1031 | 882 |
  | `:interp`, either module | 463 to 496 | 600 to 649 (lookup unchanged; noise on a loaded host) |

**Upstream.** Not yet: waits for a cljw release carrying it (fork CI green on all four platforms).

## Upstreamed

None yet.
