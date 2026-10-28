;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 felixdrp
;;
;; 08_json_in.wat — strict JSON reader (RFC 8259) producing the value tree.
;;
;; Integers without fraction/exponent are exact int64; everything else is a
;; double. Strings are found with one SIMD pass for '"', '\' and controls: if
;; the closing quote comes first the string is a zero-copy slice of the input.
;; Members and elements are collected on the scratch stacks and copied once,
;; at their exact size, when the container closes.

(global $js (mut i32) (i32.const 0))      ;; input text
(global $jn (mut i32) (i32.const 0))      ;; input length
(global $ji (mut i32) (i32.const 0))      ;; cursor
(global $jdepth (mut i32) (i32.const 0))
(global $jdups (mut i32) (i32.const 0))   ;; reject duplicate keys (encoder input, SPEC §2a.2)
(global $jhost (mut i32) (i32.const 0))   ;; numbers come from a JS host (gcf_encode flags bit 1)
;; Shape cache: per nesting depth, the keys (ptr, len) of the last object of
;; up to 32 members, all distinct. A later object whose keys repeat them in
;; order needs no duplicate check, and its keys take the cached pointers, so
;; the encoder's field lookups succeed on pointer equality.
;; Layout: 129 slots of 260 bytes: +0 key count, +4 32 x (ptr, len).
(global $jshape (mut i32) (i32.const 0))

(func $jr_err (call $fail (i32.const 43) (i32.const 0)))  ;; invalid_json

(func $jr_ws
  (local $c i32)
  (block $done (loop $l
    (br_if $done (i32.ge_u (global.get $ji) (global.get $jn)))
    (local.set $c (call $at (global.get $js) (global.get $ji)))
    (br_if $done (i32.eqz (i32.or (i32.or (i32.eq (local.get $c) (i32.const 0x20)) (i32.eq (local.get $c) (i32.const 0x0A)))
                                  (i32.or (i32.eq (local.get $c) (i32.const 0x0D)) (i32.eq (local.get $c) (i32.const 0x09))))))
    (global.set $ji (i32.add (global.get $ji) (i32.const 1)))
    (br $l))))

;; Current byte, or -1 at the end.
(func $jr_peek (result i32)
  (if (result i32) (i32.lt_u (global.get $ji) (global.get $jn))
    (then (call $at (global.get $js) (global.get $ji)))
    (else (i32.const -1))))

(func $jr_enter
  (global.set $jdepth (i32.add (global.get $jdepth) (i32.const 1)))
  (if (i32.gt_u (global.get $jdepth) (i32.const 128)) (then (call $fail (i32.const 45) (i32.const 0))))
  (global.set $ji (i32.add (global.get $ji) (i32.const 1))))

;; String at js[ji] == '"'.
(func $jr_str (result i32 i32)
  (local $open i32) (local $hit i32) (local $close i32)
  (local.set $open (global.get $ji))
  (local.set $hit (call $find_escape (global.get $js) (global.get $jn) (i32.add (local.get $open) (i32.const 1))))
  (if (i32.lt_s (local.get $hit) (i32.const 0)) (then (call $fail (i32.const 6) (i32.const 0)) (return (i32.const 0) (i32.const 0))))
  (if (i32.eq (call $at (global.get $js) (local.get $hit)) (i32.const 0x22))
    (then
      (global.set $ji (i32.add (local.get $hit) (i32.const 1)))
      (return (i32.add (global.get $js) (i32.add (local.get $open) (i32.const 1))) (i32.sub (local.get $hit) (i32.add (local.get $open) (i32.const 1))))))
  ;; escape or control byte: slow path
  (local.set $close (call $skip_quoted (global.get $js) (global.get $jn) (local.get $open) (i32.const 0)))
  (if (global.get $err) (then (return (i32.const 0) (i32.const 0))))
  (global.set $ji (i32.add (local.get $close) (i32.const 1)))
  (call $string_body (i32.add (global.get $js) (i32.add (local.get $open) (i32.const 1)))
                     (i32.sub (local.get $close) (i32.add (local.get $open) (i32.const 1))) (i32.const 0)))

(func $jr_number (result i32 i32 i64)
  (local $f f64) (local $start i32) (local $i i32) (local $neg i32) (local $mag i64) (local $d0 i32) (local $c i32) (local $nd i32) (local $k i32)
  (local $plain i32)
  (local.set $start (global.get $ji))
  (local.set $i (local.get $start))
  (if (i32.eq (call $jr_peek) (i32.const 0x2D)) (then (local.set $neg (i32.const 1)) (local.set $i (i32.add (local.get $i) (i32.const 1)))))
  ;; fast path: up to 18 plain digits (always fits in int64)
  (local.set $d0 (local.get $i))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (global.get $jn)))
    (local.set $c (i32.sub (call $at (global.get $js) (local.get $i)) (i32.const 0x30)))
    (br_if $done (i32.gt_u (local.get $c) (i32.const 9)))
    (br_if $done (i32.ge_u (i32.sub (local.get $i) (local.get $d0)) (i32.const 18)))
    (local.set $mag (i64.add (i64.mul (local.get $mag) (i64.const 10)) (i64.extend_i32_u (local.get $c))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.set $nd (i32.sub (local.get $i) (local.get $d0)))
  (local.set $plain (i32.const 1))
  (if (i32.lt_u (local.get $i) (global.get $jn))
    (then
      (local.set $c (call $at (global.get $js) (local.get $i)))
      (local.set $plain (i32.or (i32.or (i32.or (i32.eq (local.get $c) (i32.const 0x2C)) (i32.eq (local.get $c) (i32.const 0x7D)))
                                        (i32.or (i32.eq (local.get $c) (i32.const 0x5D)) (i32.eq (local.get $c) (i32.const 0x20))))
                                (i32.or (i32.or (i32.eq (local.get $c) (i32.const 0x0A)) (i32.eq (local.get $c) (i32.const 0x0D)))
                                        (i32.eq (local.get $c) (i32.const 0x09)))))))
  (if (i32.and (i32.and (i32.gt_u (local.get $nd) (i32.const 0)) (local.get $plain))
               (i32.eqz (i32.and (i32.gt_u (local.get $nd) (i32.const 1)) (i32.eq (call $at (global.get $js) (local.get $d0)) (i32.const 0x30)))))
    (then
      (global.set $ji (local.get $i))
      ;; a JS number of magnitude >= 2^53 is a double printed as digits
      (if (i32.and (global.get $jhost) (i64.ge_u (local.get $mag) (i64.const 9007199254740992)))
        (then (return (i32.const 4) (i32.const 0)
          (i64.reinterpret_f64 (select (f64.neg (f64.convert_i64_u (local.get $mag))) (f64.convert_i64_u (local.get $mag)) (local.get $neg))))))
      (return (i32.const 3) (i32.const 0) (select (i64.sub (i64.const 0) (local.get $mag)) (local.get $mag) (local.get $neg)))))
  ;; general path: full grammar, exact int64 range, doubles
  (local.set $i (local.get $start))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (global.get $jn)))
    (local.set $c (call $at (global.get $js) (local.get $i)))
    (br_if $done (i32.eqz (i32.or (i32.lt_u (i32.sub (local.get $c) (i32.const 0x30)) (i32.const 10))
                                  (i32.or (i32.or (i32.eq (local.get $c) (i32.const 0x2D)) (i32.eq (local.get $c) (i32.const 0x2B)))
                                          (i32.or (i32.eq (local.get $c) (i32.const 0x2E)) (i32.eq (i32.or (local.get $c) (i32.const 0x20)) (i32.const 0x65)))))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (global.set $ji (local.get $i))
  (local.set $k (call $number_kind (i32.add (global.get $js) (local.get $start)) (i32.sub (local.get $i) (local.get $start))))
  (if (i32.eqz (local.get $k)) (then (call $jr_err) (return (call $nil))))
  (if (i32.eq (local.get $k) (i32.const 1))
    (then
      (if (global.get $jhost)
        (then
          ;; JS host: integer tokens of magnitude >= 2^53 are doubles
          (local.set $f (call $parse_f64 (i32.add (global.get $js) (local.get $start)) (i32.sub (local.get $i) (local.get $start)) (i32.const 0)))
          (if (f64.ge (f64.abs (local.get $f)) (f64.const 9007199254740992))
            (then (return (i32.const 4) (i32.const 0) (i64.reinterpret_f64 (local.get $f)))))))
      (return (i32.const 3) (i32.const 0) (call $parse_int64 (i32.add (global.get $js) (local.get $start)) (i32.sub (local.get $i) (local.get $start)) (i32.const 0)))))
  (i32.const 4) (i32.const 0)
  (i64.reinterpret_f64 (call $parse_f64 (i32.add (global.get $js) (local.get $start)) (i32.sub (local.get $i) (local.get $start)) (i32.const 0))))

;; Literal word at the cursor (static string s, n).
(func $jr_lit (param $s i32) (param $n i32) (result i32)
  (if (i32.eqz (call $starts_with (i32.add (global.get $js) (global.get $ji)) (i32.sub (global.get $jn) (global.get $ji)) (local.get $s) (local.get $n)))
    (then (call $jr_err) (return (i32.const 0))))
  (global.set $ji (i32.add (global.get $ji) (local.get $n)))
  (i32.const 1))

(func $jr_value (result i32 i32 i64)
  (local $c i32) (local $p i32) (local $n i32)
  (call $jr_ws)
  (local.set $c (call $jr_peek))
  (if (i32.lt_s (local.get $c) (i32.const 0)) (then (call $jr_err) (return (call $nil))))
  (if (i32.eq (local.get $c) (i32.const 0x7B)) (then (return (call $jr_object))))
  (if (i32.eq (local.get $c) (i32.const 0x5B)) (then (return (call $jr_array))))
  (if (i32.eq (local.get $c) (i32.const 0x22))
    (then (call $jr_str) (local.set $n) (local.set $p) (return (i32.const 5) (local.get $p) (i64.extend_i32_u (local.get $n)))))
  (if (i32.eq (local.get $c) (i32.const 0x74)) (then (drop (call $jr_lit (global.get $S_TRUE) (i32.const 4))) (return (i32.const 2) (i32.const 0) (i64.const 0))))
  (if (i32.eq (local.get $c) (i32.const 0x66)) (then (drop (call $jr_lit (global.get $S_FALSE) (i32.const 5))) (return (i32.const 1) (i32.const 0) (i64.const 0))))
  (if (i32.eq (local.get $c) (i32.const 0x6E)) (then (drop (call $jr_lit (global.get $S_NULL) (i32.const 4))) (return (call $nil))))
  (call $jr_number))

(func $jr_object (result i32 i32 i64)
  (local $sh i32) (local $match i32) (local $mark i32) (local $cnt i32) (local $set i32) (local $kp i32) (local $kn i32) (local $c i32)
  (local $vt i32) (local $va i32) (local $vb i64) (local $m i32) (local $i i32) (local $q i32)
  (call $jr_enter)
  (if (global.get $err) (then (return (call $nil))))
  (local.set $mark (call $stack_len (global.get $STK_MEMBERS)))
  (call $jr_ws)
  (if (i32.eq (call $jr_peek) (i32.const 0x7D))
    (then
      (global.set $ji (i32.add (global.get $ji) (i32.const 1)))
      (global.set $jdepth (i32.sub (global.get $jdepth) (i32.const 1)))
      (return (i32.const 7) (i32.const 0) (i64.const 0))))
  (local.set $sh (i32.add (global.get $jshape) (i32.mul (global.get $jdepth) (i32.const 260))))
  (local.set $match (i32.const 1))
  (block $done (loop $next
    (call $jr_ws)
    (if (i32.ne (call $jr_peek) (i32.const 0x22)) (then (call $jr_err) (return (call $nil))))
    (local.set $kn (i32.const -1))
    ;; Predicted key: the key at this position in the previous object of this
    ;; depth. When that key is a slice of the input (it had no escapes), the
    ;; same bytes between quotes here are the same key: no scan needed.
    (if (local.get $match)
      (then
        (if (i32.lt_u (local.get $cnt) (i32.load (local.get $sh)))
          (then
            (local.set $m (i32.add (local.get $sh) (i32.add (i32.const 4) (i32.shl (local.get $cnt) (i32.const 3)))))
            (local.set $kp (i32.load (local.get $m)))
            (local.set $c (i32.load offset=4 (local.get $m)))
            (local.set $q (i32.add (global.get $js) (i32.add (global.get $ji) (i32.const 1))))
            (if (i32.and (i32.and (i32.ge_u (local.get $kp) (global.get $js)) (i32.lt_u (local.get $kp) (i32.add (global.get $js) (global.get $jn))))
                         (i32.lt_u (i32.add (i32.add (global.get $ji) (local.get $c)) (i32.const 1)) (global.get $jn)))
              (then
                (if (i32.eq (i32.load8_u (i32.add (local.get $q) (local.get $c))) (i32.const 0x22))
                  (then (if (call $str_eq (local.get $q) (local.get $c) (local.get $kp) (local.get $c))
                    (then
                      (local.set $kn (local.get $c))
                      (global.set $ji (i32.add (global.get $ji) (i32.add (local.get $c) (i32.const 2))))))))))))))
    (if (i32.lt_s (local.get $kn) (i32.const 0))
      (then
        (call $jr_str) (local.set $kn) (local.set $kp)
        (if (global.get $err) (then (return (call $nil))))
        ;; same key as at this position in the previous object of this depth?
        (if (local.get $match)
          (then
            (local.set $m (i32.add (local.get $sh) (i32.add (i32.const 4) (i32.shl (local.get $cnt) (i32.const 3)))))
            (if (i32.and (i32.lt_u (local.get $cnt) (i32.load (local.get $sh)))
                         (call $str_eq (i32.load (local.get $m)) (i32.load offset=4 (local.get $m)) (local.get $kp) (local.get $kn)))
              (then (local.set $kp (i32.load (local.get $m))))
              (else (local.set $match (i32.const 0))))))))
    (if (i32.and (global.get $jdups) (i32.eqz (local.get $match)))
      (then
        ;; linear scan for small objects, hash set from 8 members on
        (if (i32.and (i32.eqz (local.get $set)) (i32.ge_u (local.get $cnt) (i32.const 8)))
          (then
            (local.set $set (call $ks_new))
            (if (global.get $err) (then (return (call $nil))))
            (local.set $i (i32.const 0))
            (block $bd (loop $bl
              (br_if $bd (i32.ge_u (local.get $i) (local.get $cnt)))
              (local.set $m (i32.add (call $stack_base (global.get $STK_MEMBERS)) (i32.add (local.get $mark) (i32.mul (local.get $i) (i32.const 24)))))
              (drop (call $ks_insert (local.get $set) (i32.load (local.get $m)) (i32.load offset=4 (local.get $m))))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $bl)))))
        (if (local.get $set)
          (then
            (if (call $ks_insert (local.get $set) (local.get $kp) (local.get $kn))
              (then (call $fail_msg (i32.const 15) (i32.const 0) (i32.const 68)) (return (call $nil)))))
          (else
            (local.set $m (i32.add (call $stack_base (global.get $STK_MEMBERS)) (local.get $mark)))
            (local.set $i (i32.const 0))
            (block $sd (loop $sl
              (br_if $sd (i32.ge_u (local.get $i) (local.get $cnt)))
              (if (call $str_eq (i32.load (local.get $m)) (i32.load offset=4 (local.get $m)) (local.get $kp) (local.get $kn))
                (then (call $fail_msg (i32.const 15) (i32.const 0) (i32.const 68)) (return (call $nil))))
              (local.set $m (i32.add (local.get $m) (i32.const 24)))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $sl)))))))
    (call $jr_ws)
    (if (i32.ne (call $jr_peek) (i32.const 0x3A)) (then (call $jr_err) (return (call $nil))))
    (global.set $ji (i32.add (global.get $ji) (i32.const 1)))
    (call $jr_value) (local.set $vb) (local.set $va) (local.set $vt)
    (if (global.get $err) (then (return (call $nil))))
    (local.set $q (call $stack_push (global.get $STK_MEMBERS) (i32.const 24)))
    (if (global.get $err) (then (return (call $nil))))
    (call $store_member (local.get $q) (local.get $kp) (local.get $kn) (local.get $vt) (local.get $va) (local.get $vb))
    (local.set $cnt (i32.add (local.get $cnt) (i32.const 1)))
    (call $jr_ws)
    (local.set $c (call $jr_peek))
    (if (i32.lt_s (local.get $c) (i32.const 0)) (then (call $jr_err) (return (call $nil))))
    (global.set $ji (i32.add (global.get $ji) (i32.const 1)))
    (br_if $next (i32.eq (local.get $c) (i32.const 0x2C)))
    (br_if $done (i32.eq (local.get $c) (i32.const 0x7D)))
    (global.set $ji (i32.sub (global.get $ji) (i32.const 1)))
    (call $jr_err)
    (return (call $nil))))
  ;; remember this object's keys (distinct by now) for its next sibling
  (if (i32.le_u (local.get $cnt) (i32.const 32))
    (then
      (i32.store (local.get $sh) (local.get $cnt))
      (local.set $i (i32.const 0))
      (block $kd (loop $kl
        (br_if $kd (i32.ge_u (local.get $i) (local.get $cnt)))
        (local.set $m (i32.add (call $stack_base (global.get $STK_MEMBERS)) (i32.add (local.get $mark) (i32.mul (local.get $i) (i32.const 24)))))
        (i64.store (i32.add (local.get $sh) (i32.add (i32.const 4) (i32.shl (local.get $i) (i32.const 3)))) (i64.load (local.get $m)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $kl)))))
  (global.set $jdepth (i32.sub (global.get $jdepth) (i32.const 1)))
  (i32.const 7)
  (call $stack_pop_to_arena (global.get $STK_MEMBERS) (local.get $mark))
  (i64.extend_i32_u (local.get $cnt)))

(func $jr_array (result i32 i32 i64)
  (local $mark i32) (local $cnt i32) (local $c i32) (local $vt i32) (local $va i32) (local $vb i64) (local $q i32)
  (call $jr_enter)
  (if (global.get $err) (then (return (call $nil))))
  (local.set $mark (call $stack_len (global.get $STK_NODES)))
  (call $jr_ws)
  (if (i32.eq (call $jr_peek) (i32.const 0x5D))
    (then
      (global.set $ji (i32.add (global.get $ji) (i32.const 1)))
      (global.set $jdepth (i32.sub (global.get $jdepth) (i32.const 1)))
      (return (i32.const 6) (i32.const 0) (i64.const 0))))
  (block $done (loop $next
    (call $jr_value) (local.set $vb) (local.set $va) (local.set $vt)
    (if (global.get $err) (then (return (call $nil))))
    (local.set $q (call $stack_push (global.get $STK_NODES) (i32.const 16)))
    (if (global.get $err) (then (return (call $nil))))
    (call $store_node (local.get $q) (local.get $vt) (local.get $va) (local.get $vb))
    (local.set $cnt (i32.add (local.get $cnt) (i32.const 1)))
    (call $jr_ws)
    (local.set $c (call $jr_peek))
    (if (i32.lt_s (local.get $c) (i32.const 0)) (then (call $jr_err) (return (call $nil))))
    (global.set $ji (i32.add (global.get $ji) (i32.const 1)))
    (br_if $next (i32.eq (local.get $c) (i32.const 0x2C)))
    (br_if $done (i32.eq (local.get $c) (i32.const 0x5D)))
    (global.set $ji (i32.sub (global.get $ji) (i32.const 1)))
    (call $jr_err)
    (return (call $nil))))
  (global.set $jdepth (i32.sub (global.get $jdepth) (i32.const 1)))
  (i32.const 6)
  (call $stack_pop_to_arena (global.get $STK_NODES) (local.get $mark))
  (i64.extend_i32_u (local.get $cnt)))

;; Parse the whole text: one value, optional whitespace, end.
(func $parse_json (param $p i32) (param $n i32) (param $dups i32) (result i32 i32 i64)
  (local $vt i32) (local $va i32) (local $vb i64)
  (global.set $js (local.get $p))
  (global.set $jn (local.get $n))
  (global.set $ji (i32.const 0))
  (global.set $jdepth (i32.const 0))
  (global.set $jdups (local.get $dups))
  (global.set $jshape (call $alloc (i32.mul (i32.const 129) (i32.const 260))))
  (if (global.get $err) (then (return (call $nil))))
  (memory.fill (global.get $jshape) (i32.const 0) (i32.mul (i32.const 129) (i32.const 260)))
  (call $jr_value) (local.set $vb) (local.set $va) (local.set $vt)
  (if (global.get $err) (then (return (call $nil))))
  (call $jr_ws)
  (if (i32.ne (global.get $ji) (global.get $jn)) (then (call $jr_err) (return (call $nil))))
  (local.get $vt) (local.get $va) (local.get $vb))

;; JSON parse only (benchmarks): same contract as the Zig export.
(func (export "gcf_bench_parse_json") (param $len i32) (result i32)
  (local $mark i32)
  (local.set $mark (global.get $arena_top))
  (global.set $err (i32.const 0))
  (call $reset_stacks)
  (call $parse_json (global.get $in_ptr) (local.get $len) (i32.const 1))
  (drop) (drop) (drop)
  (global.set $arena_top (local.get $mark))
  (call $reset_stacks)
  (global.get $err))
