;; WASI Preview 2 filesystem component pinning "one object, one identity"
;; across the two 0.2 hash routes: after get-directories + open-at "a.txt",
;; it calls descriptor.metadata-hash on the fd and descriptor.metadata-hash-at
;; on the preopen with the path "a.txt", and asserts the two 16-byte
;; metadata-hash-values are equal. metadata-hash-at on "b.txt" must differ
;; (a distinct object), and on "nope" must return err(no-entry) (20). The host
;; seeds a.txt and b.txt. A mismatch traps (unreachable).
(component
  ;; ---- import wasi:filesystem/types ----
  (import "wasi:filesystem/types@0.2.0" (instance $types
    (export "descriptor" (type $descriptor (sub resource)))
    (type $err-def (enum "access" "would-block"))
    (export "error-code" (type $error-code (eq $err-def)))
    (type $of-def (flags "create" "directory" "exclusive" "truncate"))
    (export "open-flags" (type $open-flags (eq $of-def)))
    (type $pf-def (flags "symlink-follow"))
    (export "path-flags" (type $path-flags (eq $pf-def)))
    (type $df-def (flags "read" "write"))
    (export "descriptor-flags" (type $descriptor-flags (eq $df-def)))
    (type $mhv-def (record (field "lower" u64) (field "upper" u64)))
    (export "metadata-hash-value" (type $metadata-hash-value (eq $mhv-def)))
    (type $borrow-desc (borrow $descriptor))
    (type $own-desc (own $descriptor))
    (export "[method]descriptor.open-at"
      (func (param "self" $borrow-desc) (param "path-flags" $path-flags) (param "path" string)
            (param "open-flags" $open-flags) (param "flags" $descriptor-flags)
            (result (result $own-desc (error $error-code)))))
    (export "[method]descriptor.metadata-hash"
      (func (param "self" $borrow-desc)
            (result (result $metadata-hash-value (error $error-code)))))
    (export "[method]descriptor.metadata-hash-at"
      (func (param "self" $borrow-desc) (param "path-flags" $path-flags) (param "path" string)
            (result (result $metadata-hash-value (error $error-code)))))))
  (alias export $types "descriptor" (type $descriptor))

  ;; ---- import wasi:filesystem/preopens (get-directories) ----
  (import "wasi:filesystem/preopens@0.2.0" (instance $preopens
    (alias outer 1 $descriptor (type $desc-in))
    (export "descriptor" (type $desc-ex (eq $desc-in)))
    (type $own-d (own $desc-ex))
    (type $tup (tuple $own-d string))
    (type $dirlist (list $tup))
    (export "get-directories" (func (result $dirlist)))))

  ;; ---- libc: memory + a bump cabi_realloc ----
  (core module $libc
    (memory (export "memory") 1)
    (global $bump (mut i32) (i32.const 1024))
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
      (local $p i32)
      (local.set $p (global.get $bump))
      (global.set $bump (i32.add (global.get $bump) (local.get 3)))
      (local.get $p)))
  (core instance $libc (instantiate $libc))
  (alias core export $libc "cabi_realloc" (core func $cabi_realloc))

  ;; ---- lower the imported component funcs to core funcs ----
  (core func $getdirs
    (canon lower (func $preopens "get-directories") (memory (core memory $libc "memory")) (realloc $cabi_realloc)))
  (core func $openat
    (canon lower (func $types "[method]descriptor.open-at") (memory (core memory $libc "memory")) (realloc $cabi_realloc)))
  (core func $hash
    (canon lower (func $types "[method]descriptor.metadata-hash") (memory (core memory $libc "memory"))))
  (core func $hashat
    (canon lower (func $types "[method]descriptor.metadata-hash-at") (memory (core memory $libc "memory"))))
  (core func $dropdesc
    (canon resource.drop $descriptor))

  ;; ---- core module that drives the two hash routes ----
  (core module $M
    (import "fs" "get-directories" (func $getdirs (param i32)))
    (import "fs" "open-at" (func $openat (param i32 i32 i32 i32 i32 i32 i32)))
    (import "fs" "metadata-hash" (func $hash (param i32 i32)))
    (import "fs" "metadata-hash-at" (func $hashat (param i32 i32 i32 i32 i32)))
    (import "fs" "drop" (func $dropdesc (param i32)))
    (import "libc" "memory" (memory 1))
    (data (i32.const 16) "a.txt")
    (data (i32.const 24) "b.txt")
    (data (i32.const 32) "nope")
    (func $check (param $cond i32) (if (local.get $cond) (then (unreachable))))
    (func (export "run") (result i32)
      (local $dir i32) (local $file i32)
      (call $getdirs (i32.const 256))
      (local.set $dir (i32.load (i32.load (i32.const 256))))
      ;; open-at(dir, pf=0, path=16, len=5, oflags=0, dflags=READ=1, ret=288)
      (call $openat (local.get $dir) (i32.const 0) (i32.const 16) (i32.const 5) (i32.const 0) (i32.const 1) (i32.const 288))
      (call $check (i32.load8_u (i32.const 288)))            ;; open-at ok
      (local.set $file (i32.load (i32.const 292)))
      ;; metadata-hash(file, ret=320): disc@320, lower@328, upper@336
      (call $hash (local.get $file) (i32.const 320))
      (call $check (i32.load8_u (i32.const 320)))            ;; metadata-hash ok
      ;; metadata-hash-at(dir, pf=symlink-follow, "a.txt", ret=352): lower@360, upper@368
      (call $hashat (local.get $dir) (i32.const 1) (i32.const 16) (i32.const 5) (i32.const 352))
      (call $check (i32.load8_u (i32.const 352)))            ;; metadata-hash-at ok
      ;; one object, one identity: the fd route and the path route agree
      (call $check (i64.ne (i64.load (i32.const 328)) (i64.load (i32.const 360))))
      (call $check (i64.ne (i64.load (i32.const 336)) (i64.load (i32.const 368))))
      ;; metadata-hash-at(dir, "b.txt", ret=384): lower@392, upper@400, another object
      (call $hashat (local.get $dir) (i32.const 1) (i32.const 24) (i32.const 5) (i32.const 384))
      (call $check (i32.load8_u (i32.const 384)))            ;; metadata-hash-at ok
      (call $check (i32.and
        (i64.eq (i64.load (i32.const 392)) (i64.load (i32.const 360)))
        (i64.eq (i64.load (i32.const 400)) (i64.load (i32.const 368)))))
      ;; metadata-hash-at(dir, "nope", ret=416): disc 1, error-code@424 == no-entry (20)
      (call $hashat (local.get $dir) (i32.const 1) (i32.const 32) (i32.const 4) (i32.const 416))
      (call $check (i32.ne (i32.load8_u (i32.const 416)) (i32.const 1)))
      (call $check (i32.ne (i32.load8_u (i32.const 424)) (i32.const 20)))
      (call $dropdesc (local.get $file))
      (i32.const 0)))

  (core instance $deps (export "get-directories" (func $getdirs))
                       (export "open-at" (func $openat))
                       (export "metadata-hash" (func $hash))
                       (export "metadata-hash-at" (func $hashat))
                       (export "drop" (func $dropdesc)))
  (core instance $m (instantiate $M
    (with "fs" (instance $deps))
    (with "libc" (instance $libc))))

  ;; ---- lift run to wasi:cli/run ----
  (type $run-result (result))
  (func $run (result $run-result) (canon lift (core func $m "run")))
  (component $RunShim
    (import "import-func-run" (func $rf (result (result))))
    (export "run" (func $rf)))
  (instance $run-inst (instantiate $RunShim (with "import-func-run" (func $run))))
  (export "wasi:cli/run@0.2.0" (instance $run-inst))
)
