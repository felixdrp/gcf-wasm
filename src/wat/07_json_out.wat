;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 felixdrp
;;
;; 07_json_out.wat — value tree -> JSON text, and the decoding exports.

;; ---------------------------------------------------------------------------
;; Write cursor
;;
;; The writer appends through a raw cursor ($wp) into the STK_OUT block
;; instead of calling $out_byte per byte: capacity is checked once per value
;; (or per structural group) and the bytes are stored directly.
;; $w_sync publishes the cursor back to the stack length.
;; ---------------------------------------------------------------------------
(global $wp (mut i32) (i32.const 0))
(global $wend (mut i32) (i32.const 0))

;; Reserve `n` more bytes after the current length and set the cursor there.
(func $w_begin (param $n i32)
  (local $len i32)
  (local.set $len (call $stack_len (global.get $STK_OUT)))
  (drop (call $stack_push (global.get $STK_OUT) (local.get $n)))
  (global.set $wp (i32.add (call $stack_base (global.get $STK_OUT)) (local.get $len)))
  (global.set $wend (i32.add (call $stack_base (global.get $STK_OUT)) (i32.load offset=8 (global.get $STK_OUT)))))

(func $w_sync
  ;; no cursor active (reset by gcf_input_alloc)
  (if (i32.eqz (global.get $wp)) (then (return)))
  (call $stack_truncate (global.get $STK_OUT) (i32.sub (global.get $wp) (call $stack_base (global.get $STK_OUT)))))

;; Make room for `n` bytes at the cursor (grows by doubling).
(func $w_need (param $n i32)
  (if (i32.gt_u (i32.add (global.get $wp) (local.get $n)) (global.get $wend))
    (then (call $w_sync) (call $w_begin (local.get $n)))))

(func $w_byte (param $c i32)
  (i32.store8 (global.get $wp) (local.get $c))
  (global.set $wp (i32.add (global.get $wp) (i32.const 1))))

;; Decimal digits of a u32, written forward: count the digits, then fill
;; from the right two at a time. x / 100 is a multiply and a shift
;; ((x * 0x51EB851F) >> 37 is exact for every u32): wasm engines do not
;; strength-reduce divisions, so this replaces an i32.div_u per pair.
(func $w_u32 (param $x i32)
  (local $n i32) (local $p i32) (local $q i32) (local $t i64)
  ;; digit count: smallest n with x < 10^n
  (local.set $n (i32.const 1))
  (local.set $t (i64.const 10))
  (block $cd (loop $cl
    (br_if $cd (i64.lt_u (i64.extend_i32_u (local.get $x)) (local.get $t)))
    (local.set $n (i32.add (local.get $n) (i32.const 1)))
    (local.set $t (i64.mul (local.get $t) (i64.const 10)))
    (br $cl)))
  (local.set $p (i32.add (global.get $wp) (local.get $n)))
  (global.set $wp (local.get $p))
  (block $done (loop $l
    (br_if $done (i32.lt_u (local.get $x) (i32.const 100)))
    (local.set $q (i32.wrap_i64 (i64.shr_u (i64.mul (i64.extend_i32_u (local.get $x)) (i64.const 0x51EB851F)) (i64.const 37))))
    (local.set $p (i32.sub (local.get $p) (i32.const 2)))
    (i32.store16 (local.get $p)
      (i32.load16_u (i32.add (i32.const 0x0100) (i32.shl (i32.sub (local.get $x) (i32.mul (local.get $q) (i32.const 100))) (i32.const 1)))))
    (local.set $x (local.get $q))
    (br $l)))
  (if (i32.ge_u (local.get $x) (i32.const 10))
    (then (i32.store16 (i32.sub (local.get $p) (i32.const 2)) (i32.load16_u (i32.add (i32.const 0x0100) (i32.shl (local.get $x) (i32.const 1))))))
    (else (i32.store8 (i32.sub (local.get $p) (i32.const 1)) (i32.add (local.get $x) (i32.const 0x30))))))

;; Signed integer (flags |v| > 2^53-1 for the host's largeInt policy).
(func $w_i64 (param $v i64)
  (local $dp i32) (local $dn i32)
  (call $w_need (i32.const 24))
  (if (i64.lt_s (local.get $v) (i64.const 0))
    (then (call $w_byte (i32.const 0x2D)) (local.set $v (i64.sub (i64.const 0) (local.get $v)))))
  (if (i64.lt_u (local.get $v) (i64.const 0x100000000))
    (then (call $w_u32 (i32.wrap_i64 (local.get $v))) (return)))
  (if (i64.gt_u (local.get $v) (i64.const 9007199254740991)) (then (global.set $unsafe_ints (i32.const 1))))
  (call $u64_digits (local.get $v)) (local.set $dn) (local.set $dp)
  (memory.copy (global.get $wp) (local.get $dp) (local.get $dn))
  (global.set $wp (i32.add (global.get $wp) (local.get $dn))))

;; Double. The common short-decimal case is written at the cursor; the rest
;; goes through the shared $out_f64.
(func $w_f64 (param $v f64)
  (local $av f64) (local $k i32) (local $ip i32) (local $frac i32) (local $p i32)
  (local.set $av (f64.abs (local.get $v)))
  (if (i32.and (i32.and (f64.ge (local.get $av) (f64.const 1e-6)) (f64.lt (local.get $av) (f64.const 1e9)))
               (f64.ne (f64.floor (local.get $av)) (local.get $av)))
    (then
      (call $short_decimal (local.get $av)) (local.set $frac) (local.set $ip) (local.set $k)
      (if (local.get $k)
        (then
          (call $w_need (i32.const 24))
          (if (f64.lt (local.get $v) (f64.const 0)) (then (call $w_byte (i32.const 0x2D))))
          (call $w_u32 (local.get $ip))
          (call $w_byte (i32.const 0x2E))
          ;; k fraction digits, zero-padded: write from the right
          (local.set $p (i32.add (global.get $wp) (local.get $k)))
          (global.set $wp (local.get $p))
          (block $done (loop $l
            (br_if $done (i32.eq (local.get $p) (i32.sub (global.get $wp) (local.get $k))))
            (local.set $p (i32.sub (local.get $p) (i32.const 1)))
            (i32.store8 (local.get $p) (i32.add (i32.const 0x30) (i32.rem_u (local.get $frac) (i32.const 10))))
            (local.set $frac (i32.div_u (local.get $frac) (i32.const 10)))
            (br $l)))
          (return)))))
  (call $w_sync)
  (call $out_f64 (local.get $v))
  (call $w_begin (i32.const 0)))

;; JSON string. The caller guarantees n * 6 + 18 bytes at the cursor (the
;; worst case, every byte as \u00XX, plus the $copy_short slack). Runs that need no escaping are found
;; with the SIMD scanner and block-copied.
(func $w_string (param $p i32) (param $n i32)
  (local $o i32) (local $i i32) (local $j i32) (local $c i32)
  (local.set $o (global.get $wp))
  (i32.store8 (local.get $o) (i32.const 0x22))
  (local.set $o (i32.add (local.get $o) (i32.const 1)))
  (block $done (loop $l
    (local.set $j (call $find_escape (local.get $p) (local.get $n) (local.get $i)))
    (if (i32.lt_s (local.get $j) (i32.const 0)) (then (local.set $j (local.get $n))))
    (call $copy_short (local.get $o) (i32.add (local.get $p) (local.get $i)) (i32.sub (local.get $j) (local.get $i)))
    (local.set $o (i32.add (local.get $o) (i32.sub (local.get $j) (local.get $i))))
    (br_if $done (i32.eq (local.get $j) (local.get $n)))
    (local.set $c (call $at (local.get $p) (local.get $j)))
    (i32.store8 (local.get $o) (i32.const 0x5C))
    (block $esc
      (if (i32.eq (local.get $c) (i32.const 0x22)) (then (i32.store8 offset=1 (local.get $o) (i32.const 0x22)) (br $esc)))
      (if (i32.eq (local.get $c) (i32.const 0x5C)) (then (i32.store8 offset=1 (local.get $o) (i32.const 0x5C)) (br $esc)))
      (if (i32.eq (local.get $c) (i32.const 0x0A)) (then (i32.store8 offset=1 (local.get $o) (i32.const 0x6E)) (br $esc)))
      (if (i32.eq (local.get $c) (i32.const 0x0D)) (then (i32.store8 offset=1 (local.get $o) (i32.const 0x72)) (br $esc)))
      (if (i32.eq (local.get $c) (i32.const 0x09)) (then (i32.store8 offset=1 (local.get $o) (i32.const 0x74)) (br $esc)))
      (if (i32.eq (local.get $c) (i32.const 0x08)) (then (i32.store8 offset=1 (local.get $o) (i32.const 0x62)) (br $esc)))
      (if (i32.eq (local.get $c) (i32.const 0x0C)) (then (i32.store8 offset=1 (local.get $o) (i32.const 0x66)) (br $esc)))
      ;; other C0 controls: \u00XX (lower-case hex, like the Zig writer)
      (i32.store offset=1 (local.get $o) (i32.const 0x30303075))  ;; "u000"
      (i32.store8 offset=4 (local.get $o) (i32.add (i32.const 0x30) (i32.shr_u (local.get $c) (i32.const 4))))
      (i32.store8 offset=5 (local.get $o) (call $hex_digit (i32.and (local.get $c) (i32.const 15))))
      (local.set $o (i32.add (local.get $o) (i32.const 4))))
    (local.set $o (i32.add (local.get $o) (i32.const 2)))
    (local.set $i (i32.add (local.get $j) (i32.const 1)))
    (br $l)))
  (i32.store8 (local.get $o) (i32.const 0x22))
  (global.set $wp (i32.add (local.get $o) (i32.const 1))))

;; Copy n bytes with 16-byte vector moves when n <= 64: V8 lowers a
;; variable-length memory.copy to an out-of-line call, which dominates for the
;; short keys and cells of typical payloads. May write up to 15 bytes past
;; dst + n (callers reserve that slack) and reads up to 15 bytes past src + n
;; only when that stays inside linear memory.
(func $copy_short (param $dst i32) (param $src i32) (param $n i32)
  (local $i i32)
  (if (i32.or (i32.gt_u (local.get $n) (i32.const 64))
              (i32.gt_u (i32.add (i32.add (local.get $src) (local.get $n)) (i32.const 16)) (i32.shl (memory.size) (i32.const 16))))
    (then (memory.copy (local.get $dst) (local.get $src) (local.get $n)) (return)))
  (block $done (loop $l
    (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
    (v128.store (i32.add (local.get $dst) (local.get $i)) (v128.load (i32.add (local.get $src) (local.get $i))))
    (local.set $i (i32.add (local.get $i) (i32.const 16)))
    (br $l))))

(func $hex_digit (param $d i32) (result i32)
  (select (i32.add (local.get $d) (i32.const 0x57)) (i32.add (local.get $d) (i32.const 0x30)) (i32.ge_u (local.get $d) (i32.const 10))))

(func $w_value (param $t i32) (param $a i32) (param $b i64)
  (local $i i32) (local $n i32) (local $q i32)
  (if (i32.eq (local.get $t) (i32.const 5))
    (then
      (call $w_need (i32.add (i32.mul (i32.wrap_i64 (local.get $b)) (i32.const 6)) (i32.const 18)))
      (call $w_string (local.get $a) (i32.wrap_i64 (local.get $b)))
      (return)))
  (if (i32.eq (local.get $t) (i32.const 3)) (then (call $w_i64 (local.get $b)) (return)))
  (if (i32.eq (local.get $t) (i32.const 7))
    (then
      (local.set $n (i32.wrap_i64 (local.get $b)))
      (call $w_need (i32.const 2))
      (call $w_byte (i32.const 0x7B))
      (block $done (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $q (i32.add (local.get $a) (i32.mul (local.get $i) (i32.const 24))))
        ;; ',' + key + ':' in one capacity check
        (call $w_need (i32.add (i32.mul (i32.load offset=4 (local.get $q)) (i32.const 6)) (i32.const 20)))
        (if (local.get $i) (then (call $w_byte (i32.const 0x2C))))
        (call $w_string (i32.load (local.get $q)) (i32.load offset=4 (local.get $q)))
        (call $w_byte (i32.const 0x3A))
        (call $w_value (i32.load offset=8 (local.get $q)) (i32.load offset=12 (local.get $q)) (i64.load offset=16 (local.get $q)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (call $w_need (i32.const 1))
      (call $w_byte (i32.const 0x7D))
      (return)))
  (if (i32.eq (local.get $t) (i32.const 6))
    (then
      (local.set $n (i32.wrap_i64 (local.get $b)))
      (call $w_need (i32.const 2))
      (call $w_byte (i32.const 0x5B))
      (block $done (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (if (local.get $i) (then (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x2C))))
        (local.set $q (i32.add (local.get $a) (i32.shl (local.get $i) (i32.const 4))))
        (call $w_value (i32.load (local.get $q)) (i32.load offset=4 (local.get $q)) (i64.load offset=8 (local.get $q)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (call $w_need (i32.const 1))
      (call $w_byte (i32.const 0x5D))
      (return)))
  (if (i32.eq (local.get $t) (i32.const 4)) (then (call $w_f64 (f64.reinterpret_i64 (local.get $b))) (return)))
  (call $w_need (i32.const 5))
  (if (i32.eq (local.get $t) (i32.const 2))
    (then (i32.store (global.get $wp) (i32.const 0x65757274)) (global.set $wp (i32.add (global.get $wp) (i32.const 4))) (return)))  ;; "true"
  (if (i32.eq (local.get $t) (i32.const 1))
    (then (i32.store (global.get $wp) (i32.const 0x736C6166)) (i32.store8 offset=4 (global.get $wp) (i32.const 0x65))
          (global.set $wp (i32.add (global.get $wp) (i32.const 5))) (return)))  ;; "false"
  (i32.store (global.get $wp) (i32.const 0x6C6C756E))  ;; "null"
  (global.set $wp (i32.add (global.get $wp) (i32.const 4))))

;; ---------------------------------------------------------------------------
;; Streaming decode
;;
;; gcf_decode and gcf_decode_tape decode generic documents in a streaming
;; mode ($smode 1 = JSON, 2 = tape): the containers of the document write
;; their output while they are parsed, and each table row is assembled as a
;; small tree and written as soon as it is complete, so the whole document
;; never exists as a tree. Inside a row (attachments) the parser builds
;; trees as usual: $sact is 1 only at document level. A container that has
;; written itself returns the value (10, tape index, element count).
;;
;; JSON output is the same bytes as serialising the tree. While a document
;; streams JSON ($jlive), the output cursor stays open from $root to the end
;; of gcf_decode; the one parser path that uses STK_OUT as scratch (identity
;; keys) publishes it first and reopens it afterwards.
;; ---------------------------------------------------------------------------
(global $smode (mut i32) (i32.const 0))
(global $sact (mut i32) (i32.const 0))
(global $jsep (mut i32) (i32.const 0))   ;; the open JSON container has an element
(global $jlive (mut i32) (i32.const 0))  ;; the output cursor is open for streaming

;; Streaming in `mode` at this position?
(func $streaming (param $mode i32) (result i32)
  (i32.and (global.get $sact) (i32.eq (global.get $smode) (local.get $mode))))

(func $je_sep
  (if (global.get $jsep) (then (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x2C))))
  (global.set $jsep (i32.const 1)))

;; Separator before an array element.
(func $je_elem
  (call $je_sep))

;; Separator and `"key":` before an object member's value.
(func $je_key (param $p i32) (param $n i32)
  (call $je_sep)
  (call $w_need (i32.add (i32.mul (local.get $n) (i32.const 6)) (i32.const 20)))
  (call $w_string (local.get $p) (local.get $n))
  (call $w_byte (i32.const 0x3A)))

(func $je_open (param $c i32)
  (call $w_need (i32.const 1))
  (call $w_byte (local.get $c))
  (global.set $jsep (i32.const 0)))

(func $je_close (param $c i32)
  (call $w_need (i32.const 1))
  (call $w_byte (local.get $c))
  (global.set $jsep (i32.const 1)))

;; A streamed row: separator, `"key":` for a keyed map (klen >= 0), then
;; the row object.
(func $je_row (param $kp i32) (param $kn i32) (param $a i32) (param $n i32)
  (call $je_sep)
  (if (i32.ge_s (local.get $kn) (i32.const 0))
    (then
      (call $w_need (i32.add (i32.mul (local.get $kn) (i32.const 6)) (i32.const 20)))
      (call $w_string (local.get $kp) (local.get $kn))
      (call $w_byte (i32.const 0x3A))))
  (call $w_value (i32.const 7) (local.get $a) (i64.extend_i32_u (local.get $n))))

;; A value that has not written itself (a scalar, an inline array, a row).
(func $je_value (param $t i32) (param $a i32) (param $b i64)
  (if (i32.eq (local.get $t) (i32.const 10)) (then (return)))
  (call $w_value (local.get $t) (local.get $a) (local.get $b)))

;; Whole value -> JSON in the output buffer, reserving `hint` bytes first.
(func $json_value (param $t i32) (param $a i32) (param $b i64) (param $hint i32)
  (call $w_begin (local.get $hint))
  (call $w_value (local.get $t) (local.get $a) (local.get $b))
  (call $w_sync))

;; ---------------------------------------------------------------------------
;; Decoding exports (same contract as the Zig build, docs/WASM_ABI.md)
;; ---------------------------------------------------------------------------

;; GCF -> JSON. Returns 0 or an ErrorCode.
(func (export "gcf_decode") (param $len i32) (result i32)
  (local $vt i32) (local $va i32) (local $vb i64)
  ;; JSON output is typically about twice the GCF input: reserve it before
  ;; parsing, since a generic document is written while it is parsed
  (call $w_begin (i32.add (i32.shl (local.get $len) (i32.const 1)) (i32.const 64)))
  (call $w_sync)
  (global.set $smode (i32.const 1))
  (call $decode_doc (global.get $in_ptr) (local.get $len))
  (local.set $vb) (local.set $va) (local.set $vt)
  (if (global.get $jlive) (then (call $w_sync) (global.set $jlive (i32.const 0))))
  (global.set $smode (i32.const 0))
  (global.set $sact (i32.const 0))
  (if (global.get $err) (then (return (global.get $err))))
  ;; graph and delta payloads, and scalar roots, come back as a tree
  (if (i32.ne (local.get $vt) (i32.const 10))
    (then (call $json_value (local.get $vt) (local.get $va) (local.get $vb) (i32.const 0))))
  (if (global.get $err) (then (return (global.get $err))))
  (call $out_finish)
  (i32.const 0))

;; Decode to the value tree only (benchmarks); rewinds the arena to just
;; after the input, so it can be called repeatedly on one input.
(func (export "gcf_decode_tree") (param $len i32) (result i32)
  (local $mark i32) (local $vt i32) (local $va i32) (local $vb i64)
  (local.set $mark (global.get $arena_top))
  (global.set $err (i32.const 0))
  (call $reset_stacks)
  (call $decode_doc (global.get $in_ptr) (local.get $len))
  (local.set $vb) (local.set $va) (local.set $vt)
  (global.set $arena_top (local.get $mark))
  (call $reset_stacks)
  (global.get $err))
