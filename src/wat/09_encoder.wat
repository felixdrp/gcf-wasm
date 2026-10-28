;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 felixdrp
;;
;; 09_encoder.wat — canonical generic-profile encoder (JSON value -> GCF).
;;
;; Mirrors encoder.zig's Encoder function for function, so both builds emit
;; byte-identical canonical output (SPEC §2.3.1, §7.11). Output goes through
;; the raw write cursor of 07_json_out.wat. One structural difference: the
;; Zig encoder renders each tabular row into a scratch buffer and copies it,
;; because the `@N ` prefix depends on whether the row has attachments; here
;; that is decided first (a cheap pre-pass over the row's fields) and the row
;; is written straight to the output.
;;
;; Lists of strings are arrays of (ptr, len) pairs.
;; Flat leaf (16 bytes): +0 path ptr, +4 path len, +8 keys list, +12 key count.
;; Column (32 bytes): +0 kind (0 flat, 1 original), +4 field ptr, +8 field len,
;;   +12 keys list, +16 key count, +20 header ptr, +24 header len, +28 hint.
;; Attachment (32 bytes, on STK_ROW): +0 name ptr, +4 name len, +8 value node,
;;   +24 inline fields list (0 = none), +28 field index (for shared schemas).

(data (i32.const 0x7B50) "GCF profile=generic\0a]: \20{}\0a =:]{]{}\0a [0]\0a]\0a^{__proto__constructorprototypekey")
(global $S_GENHDR i32 (i32.const 0x7B50))   ;; "GCF profile=generic\n"  20
(global $S_CLOSE_COLON i32 (i32.const 0x7B64)) ;; "]: "                3
(global $S_EMPTYOBJ i32 (i32.const 0x7B67)) ;; " {}\n"                    4
(global $S_SPEQ i32 (i32.const 0x7B6B))     ;; " ="                      2
(global $S_KEYED i32 (i32.const 0x7B6D))    ;; ":]{"                     3
(global $S_TAB i32 (i32.const 0x7B70))      ;; "]{"                      2
(global $S_HDREND i32 (i32.const 0x7B72))   ;; "}\n"                     2
(global $S_ZERO i32 (i32.const 0x7B74))     ;; " [0]\n"                  5
(global $S_CLOSE_NL i32 (i32.const 0x7B79)) ;; "]\n"                     2
(global $S_INLINE i32 (i32.const 0x7B7B))   ;; "^{"                      2
(global $S_PROTO i32 (i32.const 0x7B7D))    ;; "__proto__"               9
(global $S_CTOR i32 (i32.const 0x7B86))     ;; "constructor"            11
(global $S_PROTOTYPE i32 (i32.const 0x7B91)) ;; "prototype"              9
(global $S_KEY i32 (i32.const 0x7B9A))      ;; "key"                     3

(global $no_flatten (mut i32) (i32.const 0))

;; ---------------------------------------------------------------------------
;; Output helpers (cursor based)
;; ---------------------------------------------------------------------------

(func $o_byte (param $c i32)
  (call $w_need (i32.const 1))
  (i32.store8 (global.get $wp) (local.get $c))
  (global.set $wp (i32.add (global.get $wp) (i32.const 1))))

(func $o_bytes (param $p i32) (param $n i32)
  (call $w_need (i32.add (local.get $n) (i32.const 16)))
  (call $copy_short (global.get $wp) (local.get $p) (local.get $n))
  (global.set $wp (i32.add (global.get $wp) (local.get $n))))

(func $o_indent (param $depth i32)
  (local $p i32) (local $end i32)
  (call $w_need (i32.shl (local.get $depth) (i32.const 1)))
  (local.set $p (global.get $wp))
  (local.set $end (i32.add (local.get $p) (i32.shl (local.get $depth) (i32.const 1))))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $p) (local.get $end)))
    (i32.store16 (local.get $p) (i32.const 0x2020))
    (local.set $p (i32.add (local.get $p) (i32.const 2)))
    (br $l)))
  (global.set $wp (local.get $end)))

(func $o_u32 (param $x i32)
  (call $w_need (i32.const 10))
  (call $w_u32 (local.get $x)))

(func $o_quoted (param $p i32) (param $n i32)
  (call $w_need (i32.add (i32.mul (local.get $n) (i32.const 6)) (i32.const 18)))
  (call $w_string (local.get $p) (local.get $n)))

;; Key grammar (SPEC §2a): bare when valid, otherwise quoted.
(func $o_key (param $p i32) (param $n i32)
  (if (call $is_bare_key (local.get $p) (local.get $n))
    (then (call $o_bytes (local.get $p) (local.get $n)))
    (else (call $o_quoted (local.get $p) (local.get $n)))))

;; Any scalar in canonical form; null is `-`.
(func $o_scalar (param $t i32) (param $a i32) (param $b i64)
  (if (i32.eq (local.get $t) (i32.const 5))
    (then
      (if (call $needs_quote (local.get $a) (i32.wrap_i64 (local.get $b)))
        (then (call $o_quoted (local.get $a) (i32.wrap_i64 (local.get $b))))
        (else (call $o_bytes (local.get $a) (i32.wrap_i64 (local.get $b)))))
      (return)))
  (if (i32.eq (local.get $t) (i32.const 3)) (then (call $w_i64 (local.get $b)) (return)))
  (if (i32.eq (local.get $t) (i32.const 4)) (then (call $w_f64 (f64.reinterpret_i64 (local.get $b))) (return)))
  (if (i32.eqz (local.get $t)) (then (call $o_byte (i32.const 0x2D)) (return)))
  (if (i32.eq (local.get $t) (i32.const 2)) (then (call $o_bytes (global.get $S_TRUE) (i32.const 4)) (return)))
  (call $o_bytes (global.get $S_FALSE) (i32.const 5)))

(func $o_scalar_at (param $q i32)
  (call $o_scalar (i32.load (local.get $q)) (i32.load offset=4 (local.get $q)) (i64.load offset=8 (local.get $q))))

;; Constant-column value (SPEC §7.4.7.2): also quoted when it contains '}'.
(func $o_const_value (param $q i32)
  (if (i32.eq (i32.load (local.get $q)) (i32.const 5))
    (then (if (i32.ge_s (call $find_byte (i32.load offset=4 (local.get $q)) (i32.load offset=8 (local.get $q)) (i32.const 0) (i32.const 0x7D)) (i32.const 0))
      (then (call $o_quoted (i32.load offset=4 (local.get $q)) (i32.load offset=8 (local.get $q))) (return)))))
  (call $o_scalar_at (local.get $q)))

(func $o_primitive_list (param $arr i32) (param $n i32)
  (local $i i32)
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (if (local.get $i) (then (call $o_byte (i32.const 0x2C))))
    (call $o_scalar_at (i32.add (local.get $arr) (i32.shl (local.get $i) (i32.const 4))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l))))

;; How a header line starts. kind: 0 root "## ", 1 named "## key ",
;; 2 attachment ".key ", 3 item "@id ".
(func $o_prefix (param $depth i32) (param $kind i32) (param $np i32) (param $nn i32) (param $id i32)
  (call $o_indent (local.get $depth))
  (if (i32.eq (local.get $kind) (i32.const 0)) (then (call $o_bytes (global.get $S_SECTION) (i32.const 3)) (return)))
  (if (i32.eq (local.get $kind) (i32.const 1))
    (then (call $o_bytes (global.get $S_SECTION) (i32.const 3)) (call $o_key (local.get $np) (local.get $nn)) (call $o_byte (i32.const 0x20)) (return)))
  (if (i32.eq (local.get $kind) (i32.const 2))
    (then (call $o_byte (i32.const 0x2E)) (call $o_key (local.get $np) (local.get $nn)) (call $o_byte (i32.const 0x20)) (return)))
  (call $o_byte (i32.const 0x40)) (call $o_u32 (local.get $id)) (call $o_byte (i32.const 0x20)))

;; ---------------------------------------------------------------------------
;; Quoting (SPEC §2.4, as applied by the reference SDKs: '|' and ',' force
;; quoting in every context)
;; ---------------------------------------------------------------------------

;; `\[[^\]]*\]\s*:` — would read as an inline array header at line level.
(func $inline_array_pattern (param $p i32) (param $n i32) (result i32)
  (local $open i32) (local $i i32) (local $j i32) (local $c i32)
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $c (call $at (local.get $p) (local.get $i)))
    (if (i32.eq (local.get $c) (i32.const 0x5B)) (then (local.set $open (i32.const 1))))
    (if (i32.and (i32.eq (local.get $c) (i32.const 0x5D)) (local.get $open))
      (then
        (local.set $j (i32.add (local.get $i) (i32.const 1)))
        (block $wd (loop $wl
          (br_if $wd (i32.ge_u (local.get $j) (local.get $n)))
          (local.set $c (call $at (local.get $p) (local.get $j)))
          (br_if $wd (i32.eqz (i32.or (i32.eq (local.get $c) (i32.const 0x20)) (i32.lt_u (i32.sub (local.get $c) (i32.const 0x09)) (i32.const 5)))))
          (local.set $j (i32.add (local.get $j) (i32.const 1)))
          (br $wl)))
        (if (i32.and (i32.lt_u (local.get $j) (local.get $n)) (i32.eq (call $at (local.get $p) (local.get $j)) (i32.const 0x3A)))
          (then (return (i32.const 1))))
        (local.set $open (i32.const 0))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (i32.const 0))

;; Non-ASCII code points that force quoting: C1 controls and the Unicode
;; whitespace set (U+00A0, U+1680, U+2000..200A, U+2028/9, U+202F, U+205F,
;; U+3000, U+FEFF). p[i] is a UTF-8 lead byte.
(func $non_ascii_forces_quote (param $p i32) (param $n i32) (param $i i32) (result i32)
  (local $b0 i32) (local $b1 i32) (local $b2 i32)
  (local.set $b0 (call $at (local.get $p) (local.get $i)))
  (if (i32.and (i32.eq (local.get $b0) (i32.const 0xC2)) (i32.lt_u (i32.add (local.get $i) (i32.const 1)) (local.get $n)))
    (then (return (i32.le_u (i32.sub (call $at (local.get $p) (i32.add (local.get $i) (i32.const 1))) (i32.const 0x80)) (i32.const 0x20)))))
  (if (i32.ge_u (i32.add (local.get $i) (i32.const 2)) (local.get $n)) (then (return (i32.const 0))))
  (local.set $b1 (call $at (local.get $p) (i32.add (local.get $i) (i32.const 1))))
  (local.set $b2 (call $at (local.get $p) (i32.add (local.get $i) (i32.const 2))))
  (if (i32.eq (local.get $b0) (i32.const 0xE1))
    (then (return (i32.and (i32.eq (local.get $b1) (i32.const 0x9A)) (i32.eq (local.get $b2) (i32.const 0x80))))))
  (if (i32.eq (local.get $b0) (i32.const 0xE2))
    (then (return (i32.or
      (i32.and (i32.eq (local.get $b1) (i32.const 0x80))
               (i32.or (i32.le_u (i32.sub (local.get $b2) (i32.const 0x80)) (i32.const 0x0A))
                       (i32.or (i32.eq (local.get $b2) (i32.const 0xA8)) (i32.or (i32.eq (local.get $b2) (i32.const 0xA9)) (i32.eq (local.get $b2) (i32.const 0xAF))))))
      (i32.and (i32.eq (local.get $b1) (i32.const 0x81)) (i32.eq (local.get $b2) (i32.const 0x9F)))))))
  (if (i32.eq (local.get $b0) (i32.const 0xE3))
    (then (return (i32.and (i32.eq (local.get $b1) (i32.const 0x80)) (i32.eq (local.get $b2) (i32.const 0x80))))))
  (if (i32.eq (local.get $b0) (i32.const 0xEF))
    (then (return (i32.and (i32.eq (local.get $b1) (i32.const 0xBB)) (i32.eq (local.get $b2) (i32.const 0xBF))))))
  (i32.const 0))

(func $utf8_len (param $b i32) (result i32)
  (if (i32.lt_u (local.get $b) (i32.const 0xC0)) (then (return (i32.const 1))))
  (if (i32.lt_u (local.get $b) (i32.const 0xE0)) (then (return (i32.const 2))))
  (if (i32.lt_u (local.get $b) (i32.const 0xF0)) (then (return (i32.const 3))))
  (i32.const 4))

(func $is_digit (param $c i32) (result i32) (i32.lt_u (i32.sub (local.get $c) (i32.const 0x30)) (i32.const 10)))

;; Does this string value need quotes?
(func $needs_quote (param $p i32) (param $n i32) (result i32)
  (local $c0 i32) (local $i i32) (local $j i32) (local $m i32) (local $v v128) (local $b i32)
  (if (i32.eqz (local.get $n)) (then (return (i32.const 1))))
  (local.set $c0 (i32.load8_u (local.get $p)))
  (if (i32.eq (local.get $n) (i32.const 1))
    (then (if (i32.or (i32.or (i32.eq (local.get $c0) (i32.const 0x2D)) (i32.eq (local.get $c0) (i32.const 0x7E))) (i32.eq (local.get $c0) (i32.const 0x5E)))
      (then (return (i32.const 1))))))
  (if (i32.eq (local.get $n) (i32.const 4)) (then (if (i32.eq (i32.load (local.get $p)) (i32.const 0x65757274)) (then (return (i32.const 1))))))
  (if (i32.eq (local.get $n) (i32.const 5))
    (then (if (i32.and (i32.eq (i32.load (local.get $p)) (i32.const 0x736C6166)) (i32.eq (call $at (local.get $p) (i32.const 4)) (i32.const 0x65)))
      (then (return (i32.const 1))))))
  (if (i32.and (i32.and (i32.ge_u (local.get $n) (i32.const 3)) (i32.eq (local.get $c0) (i32.const 0x5E)))
               (i32.and (i32.eq (call $at (local.get $p) (i32.const 1)) (i32.const 0x7B))
                        (i32.eq (call $at (local.get $p) (i32.sub (local.get $n) (i32.const 1))) (i32.const 0x7D))))
    (then (return (i32.const 1))))
  ;; a string starting with a letter can be neither number-like nor start
  ;; with ' ', '#', '@' or '.': skip straight to the remaining checks
  (if (i32.lt_u (i32.sub (i32.or (local.get $c0) (i32.const 0x20)) (i32.const 0x61)) (i32.const 26))
    (then (return (call $needs_quote_rest (local.get $p) (local.get $n)))))
  (if (call $number_kind (local.get $p) (local.get $n)) (then (return (i32.const 1))))
  ;; numeric-like: ^[+-]\.?\d | ^\.\d | ^0\d
  (if (i32.or (i32.eq (local.get $c0) (i32.const 0x2B)) (i32.eq (local.get $c0) (i32.const 0x2D)))
    (then
      (local.set $i (i32.const 1))
      (if (i32.and (i32.lt_u (local.get $i) (local.get $n)) (i32.eq (call $at (local.get $p) (local.get $i)) (i32.const 0x2E)))
        (then (local.set $i (i32.const 2))))
      (if (i32.lt_u (local.get $i) (local.get $n))
        (then (if (call $is_digit (call $at (local.get $p) (local.get $i))) (then (return (i32.const 1))))))))
  (if (i32.and (i32.or (i32.eq (local.get $c0) (i32.const 0x2E)) (i32.eq (local.get $c0) (i32.const 0x30))) (i32.gt_u (local.get $n) (i32.const 1)))
    (then (if (call $is_digit (call $at (local.get $p) (i32.const 1))) (then (return (i32.const 1))))))
  (if (i32.or (i32.eq (local.get $c0) (i32.const 0x20)) (i32.eq (call $at (local.get $p) (i32.sub (local.get $n) (i32.const 1))) (i32.const 0x20)))
    (then (return (i32.const 1))))
  (if (i32.or (i32.or (i32.eq (local.get $c0) (i32.const 0x23)) (i32.eq (local.get $c0) (i32.const 0x40))) (i32.eq (local.get $c0) (i32.const 0x2E)))
    (then (return (i32.const 1))))
  (call $needs_quote_rest (local.get $p) (local.get $n)))

;; The checks of needs_quote that do not depend on the first byte: trailing
;; space, an inline-array-like `[...]:`, then one SIMD pass.
(func $needs_quote_rest (param $p i32) (param $n i32) (result i32)
  (local $i i32) (local $j i32) (local $m i32) (local $v v128) (local $b i32)
  (if (i32.eq (call $at (local.get $p) (i32.sub (local.get $n) (i32.const 1))) (i32.const 0x20)) (then (return (i32.const 1))))
  (if (i32.ge_s (call $find_byte (local.get $p) (local.get $n) (i32.const 0) (i32.const 0x5B)) (i32.const 0))
    (then (if (call $inline_array_pattern (local.get $p) (local.get $n)) (then (return (i32.const 1))))))
  ;; one SIMD pass: " \ | , C0 controls, and non-ASCII (bitmask of the top bits)
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (if (i32.le_u (i32.add (local.get $i) (i32.const 16)) (local.get $n))
      (then
        (local.set $v (v128.load (i32.add (local.get $p) (local.get $i))))
        (local.set $m (i32.or
          (i8x16.bitmask (v128.or (v128.or (i8x16.eq (local.get $v) (i8x16.splat (i32.const 0x22))) (i8x16.eq (local.get $v) (i8x16.splat (i32.const 0x5C))))
                                  (v128.or (v128.or (i8x16.eq (local.get $v) (i8x16.splat (i32.const 0x7C))) (i8x16.eq (local.get $v) (i8x16.splat (i32.const 0x2C))))
                                           (i8x16.lt_u (local.get $v) (i8x16.splat (i32.const 0x20))))))
          (i8x16.bitmask (local.get $v))))
        (if (i32.eqz (local.get $m)) (then (local.set $i (i32.add (local.get $i) (i32.const 16))) (br $l)))
        (local.set $j (i32.add (local.get $i) (i32.ctz (local.get $m))))
        (local.set $b (call $at (local.get $p) (local.get $j)))
        (if (i32.lt_u (local.get $b) (i32.const 0x80)) (then (return (i32.const 1))))
        (if (call $non_ascii_forces_quote (local.get $p) (local.get $n) (local.get $j)) (then (return (i32.const 1))))
        (local.set $i (i32.add (local.get $j) (call $utf8_len (local.get $b))))
        (br $l)))
    (local.set $b (call $at (local.get $p) (local.get $i)))
    (if (i32.lt_u (local.get $b) (i32.const 0x80))
      (then
        (if (i32.or (i32.or (i32.or (i32.eq (local.get $b) (i32.const 0x22)) (i32.eq (local.get $b) (i32.const 0x5C)))
                            (i32.or (i32.eq (local.get $b) (i32.const 0x7C)) (i32.eq (local.get $b) (i32.const 0x2C))))
                    (i32.lt_u (local.get $b) (i32.const 0x20)))
          (then (return (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1))))
      (else
        (if (call $non_ascii_forces_quote (local.get $p) (local.get $n) (local.get $i)) (then (return (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (call $utf8_len (local.get $b))))))
    (br $l)))
  (i32.const 0))

;; ---------------------------------------------------------------------------
;; Value helpers
;; ---------------------------------------------------------------------------

(func $is_composite (param $t i32) (result i32) (i32.or (i32.eq (local.get $t) (i32.const 6)) (i32.eq (local.get $t) (i32.const 7))))

(func $all_primitives (param $arr i32) (param $n i32) (result i32)
  (local $i i32)
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (if (call $is_composite (i32.load (i32.add (local.get $arr) (i32.shl (local.get $i) (i32.const 4))))) (then (return (i32.const 0))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (i32.const 1))

;; Member of an object (members, count) named (k, kn), or 0. `hint` is the
;; expected index: rows usually repeat one key order, so it is probed first.
(func $field (param $obj i32) (param $n i32) (param $k i32) (param $kn i32) (param $hint i32) (result i32)
  (local $m i32) (local $end i32)
  (if (i32.lt_u (local.get $hint) (local.get $n))
    (then
      (local.set $m (i32.add (local.get $obj) (i32.mul (local.get $hint) (i32.const 24))))
      (if (i32.eq (i32.load (local.get $m)) (local.get $k)) (then (if (i32.eq (i32.load offset=4 (local.get $m)) (local.get $kn)) (then (return (local.get $m))))))
      (if (call $str_eq (i32.load (local.get $m)) (i32.load offset=4 (local.get $m)) (local.get $k) (local.get $kn)) (then (return (local.get $m))))))
  (local.set $m (local.get $obj))
  (local.set $end (i32.add (local.get $obj) (i32.mul (local.get $n) (i32.const 24))))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $m) (local.get $end)))
    (if (call $str_eq (i32.load (local.get $m)) (i32.load offset=4 (local.get $m)) (local.get $k) (local.get $kn)) (then (return (local.get $m))))
    (local.set $m (i32.add (local.get $m) (i32.const 24)))
    (br $l)))
  (i32.const 0))

;; Member of a node (0 unless the node is an object).
(func $field_of (param $node i32) (param $k i32) (param $kn i32) (param $hint i32) (result i32)
  (if (i32.ne (i32.load (local.get $node)) (i32.const 7)) (then (return (i32.const 0))))
  (call $field (i32.load offset=4 (local.get $node)) (i32.load offset=8 (local.get $node)) (local.get $k) (local.get $kn) (local.get $hint)))

;; Add a key to an ordered union collected on STK_MISC since `mark` (count
;; `cnt`, optional hash set `set` used once more than 8 keys are present).
;; Returns the new (cnt, set).
(func $union_add (param $mark i32) (param $cnt i32) (param $set i32) (param $k i32) (param $kn i32) (result i32 i32)
  (local $i i32) (local $q i32)
  (if (i32.eqz (local.get $set))
    (then
      (local.set $q (i32.add (call $stack_base (global.get $STK_MISC)) (local.get $mark)))
      (block $done (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $cnt)))
        (if (call $str_eq (i32.load (local.get $q)) (i32.load offset=4 (local.get $q)) (local.get $k) (local.get $kn))
          (then (return (local.get $cnt) (local.get $set))))
        (local.set $q (i32.add (local.get $q) (i32.const 8)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (call $push_pair (global.get $STK_MISC) (local.get $k) (local.get $kn))
      (local.set $cnt (i32.add (local.get $cnt) (i32.const 1)))
      (if (i32.gt_u (local.get $cnt) (i32.const 8))
        (then
          (local.set $set (call $ks_new))
          (if (global.get $err) (then (return (local.get $cnt) (i32.const 0))))
          (local.set $i (i32.const 0))
          (block $done (loop $l
            (br_if $done (i32.ge_u (local.get $i) (local.get $cnt)))
            (local.set $q (i32.add (call $stack_base (global.get $STK_MISC)) (i32.add (local.get $mark) (i32.shl (local.get $i) (i32.const 3)))))
            (drop (call $ks_insert (local.get $set) (i32.load (local.get $q)) (i32.load offset=4 (local.get $q))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $l)))))
      (return (local.get $cnt) (local.get $set))))
  (if (i32.eqz (call $ks_insert (local.get $set) (local.get $k) (local.get $kn)))
    (then
      (call $push_pair (global.get $STK_MISC) (local.get $k) (local.get $kn))
      (local.set $cnt (i32.add (local.get $cnt) (i32.const 1)))))
  (local.get $cnt) (local.get $set))

;; Union of the keys of objects (members, count) in `members` order.
(func $union_object (param $mark i32) (param $cnt i32) (param $set i32) (param $obj i32) (param $n i32) (result i32 i32)
  (local $i i32) (local $m i32) (local $u i32)
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $m (i32.add (local.get $obj) (i32.mul (local.get $i) (i32.const 24))))
    ;; rows usually repeat the union's key slices in order (the JSON reader
    ;; shares key pointers between sibling objects): present, no search
    (if (i32.lt_u (local.get $i) (local.get $cnt))
      (then
        (local.set $u (i32.add (call $stack_base (global.get $STK_MISC)) (i32.add (local.get $mark) (i32.shl (local.get $i) (i32.const 3)))))
        (if (i32.and (i32.eq (i32.load (local.get $u)) (i32.load (local.get $m))) (i32.eq (i32.load offset=4 (local.get $u)) (i32.load offset=4 (local.get $m))))
          (then (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))))
    (call $union_add (local.get $mark) (local.get $cnt) (local.get $set) (i32.load (local.get $m)) (i32.load offset=4 (local.get $m)))
    (local.set $set) (local.set $cnt)
    (if (global.get $err) (then (return (i32.const 0) (i32.const 0))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.get $cnt) (local.get $set))

;; Ordered field union of an all-object array (SPEC §7.4.3): (list, count),
;; count 0 when the array is empty, has a non-object, or no keys at all.
(func $tabular_fields (param $arr i32) (param $n i32) (result i32 i32)
  (local $mark i32) (local $cnt i32) (local $set i32) (local $i i32) (local $q i32)
  (if (i32.eqz (local.get $n)) (then (return (i32.const 0) (i32.const 0))))
  (local.set $mark (call $stack_len (global.get $STK_MISC)))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $q (i32.add (local.get $arr) (i32.shl (local.get $i) (i32.const 4))))
    (if (i32.ne (i32.load (local.get $q)) (i32.const 7))
      (then (call $stack_truncate (global.get $STK_MISC) (local.get $mark)) (return (i32.const 0) (i32.const 0))))
    (call $union_object (local.get $mark) (local.get $cnt) (local.get $set) (i32.load offset=4 (local.get $q)) (i32.load offset=8 (local.get $q)))
    (local.set $set) (local.set $cnt)
    (if (global.get $err) (then (return (i32.const 0) (i32.const 0))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (call $stack_pop_to_arena (global.get $STK_MISC) (local.get $mark))
  (local.get $cnt))

(func $same_strings (param $x i32) (param $xn i32) (param $y i32) (param $yn i32) (result i32)
  (local $i i32) (local $p i32) (local $q i32)
  (if (i32.ne (local.get $xn) (local.get $yn)) (then (return (i32.const 0))))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $xn)))
    (local.set $p (i32.add (local.get $x) (i32.shl (local.get $i) (i32.const 3))))
    (local.set $q (i32.add (local.get $y) (i32.shl (local.get $i) (i32.const 3))))
    (if (i32.eqz (call $str_eq (i32.load (local.get $p)) (i32.load offset=4 (local.get $p)) (i32.load (local.get $q)) (i32.load offset=4 (local.get $q))))
      (then (return (i32.const 0))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (i32.const 1))

(func $contains_gt (param $p i32) (param $n i32) (result i32)
  (i32.ge_s (call $find_byte (local.get $p) (local.get $n) (i32.const 0) (i32.const 0x3E)) (i32.const 0)))

;; Concatenate (a, an) + sep + (b, bn) into the arena (sep < 0: none).
(func $concat (param $a i32) (param $an i32) (param $sep i32) (param $b i32) (param $bn i32) (result i32 i32)
  (local $q i32) (local $n i32) (local $o i32)
  (local.set $n (i32.add (i32.add (local.get $an) (local.get $bn)) (i32.ge_s (local.get $sep) (i32.const 0))))
  (local.set $q (call $alloc (local.get $n)))
  (if (global.get $err) (then (return (i32.const 0) (i32.const 0))))
  (memory.copy (local.get $q) (local.get $a) (local.get $an))
  (local.set $o (i32.add (local.get $q) (local.get $an)))
  (if (i32.ge_s (local.get $sep) (i32.const 0))
    (then (i32.store8 (local.get $o) (local.get $sep)) (local.set $o (i32.add (local.get $o) (i32.const 1)))))
  (memory.copy (local.get $o) (local.get $b) (local.get $bn))
  (local.get $q) (local.get $n))

;; Do two scalar nodes render identically (scalar or constant-column form)?
;; Strings: same bytes (the quoting decision depends on the bytes alone).
;; null / false / true: same tag. Numbers: the canonical form is unique per
;; numeric value, and an integral double below 2^53 is written like the
;; integer (5 and 5.0 both render "5", -0.0 renders "0").
(func $same_rendering (param $x i32) (param $y i32) (result i32)
  (local $tx i32) (local $ty i32) (local $i i64) (local $f f64)
  (local.set $tx (i32.load (local.get $x)))
  (local.set $ty (i32.load (local.get $y)))
  (if (i32.or (i32.eq (local.get $tx) (i32.const 5)) (i32.eq (local.get $ty) (i32.const 5)))
    (then
      (if (i32.ne (local.get $tx) (local.get $ty)) (then (return (i32.const 0))))
      (return (call $str_eq (i32.load offset=4 (local.get $x)) (i32.load offset=8 (local.get $x)) (i32.load offset=4 (local.get $y)) (i32.load offset=8 (local.get $y))))))
  (if (i32.or (i32.le_u (local.get $tx) (i32.const 2)) (i32.le_u (local.get $ty) (i32.const 2)))
    (then (return (i32.eq (local.get $tx) (local.get $ty)))))
  (if (i32.and (i32.eq (local.get $tx) (i32.const 3)) (i32.eq (local.get $ty) (i32.const 3)))
    (then (return (i64.eq (i64.load offset=8 (local.get $x)) (i64.load offset=8 (local.get $y))))))
  (if (i32.and (i32.eq (local.get $tx) (i32.const 4)) (i32.eq (local.get $ty) (i32.const 4)))
    (then (return (f64.eq (f64.load offset=8 (local.get $x)) (f64.load offset=8 (local.get $y))))))
  ;; integer vs double
  (if (i32.eq (local.get $tx) (i32.const 3))
    (then (local.set $i (i64.load offset=8 (local.get $x))) (local.set $f (f64.load offset=8 (local.get $y))))
    (else (local.set $i (i64.load offset=8 (local.get $y))) (local.set $f (f64.load offset=8 (local.get $x)))))
  (if (i32.eqz (i32.and (f64.eq (f64.floor (local.get $f)) (local.get $f)) (f64.lt (f64.abs (local.get $f)) (f64.const 9007199254740992))))
    (then (return (i32.const 0))))
  (i64.eq (local.get $i) (i64.trunc_f64_s (local.get $f))))

;; ---------------------------------------------------------------------------
;; Roots and objects
;; ---------------------------------------------------------------------------

(func $enc_root (param $t i32) (param $a i32) (param $b i64)
  (local $km i32)
  (call $o_bytes (global.get $S_GENHDR) (i32.const 20))
  (if (i32.eq (local.get $t) (i32.const 6)) (then (call $enc_root_array (local.get $a) (i32.wrap_i64 (local.get $b))) (return)))
  (if (i32.eq (local.get $t) (i32.const 7))
    (then
      (local.set $km (call $keyed_eligible (local.get $a) (i32.wrap_i64 (local.get $b))))
      (if (global.get $err) (then (return)))
      (if (local.get $km)
        (then (call $keyed_map (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (local.get $a) (i32.wrap_i64 (local.get $b)) (local.get $km) (i32.const 0)))
        (else (call $enc_object (local.get $a) (i32.wrap_i64 (local.get $b)) (i32.const 0))))
      (return)))
  (call $o_byte (i32.const 0x3D))
  (call $o_scalar (local.get $t) (local.get $a) (local.get $b))
  (call $o_byte (i32.const 0x0A)))

(func $enc_root_array (param $arr i32) (param $n i32)
  (local $fp i32) (local $fn i32)
  (if (i32.eqz (local.get $n))
    (then (call $o_bytes (global.get $S_HDRARR) (i32.const 4)) (call $o_byte (i32.const 0x30)) (call $o_bytes (global.get $S_CLOSE_NL) (i32.const 2)) (return)))
  (if (call $all_primitives (local.get $arr) (local.get $n))
    (then
      (call $o_bytes (global.get $S_HDRARR) (i32.const 4))
      (call $o_u32 (local.get $n))
      (call $o_bytes (global.get $S_CLOSE_COLON) (i32.const 3))
      (call $o_primitive_list (local.get $arr) (local.get $n))
      (call $o_byte (i32.const 0x0A))
      (return)))
  (call $tabular_fields (local.get $arr) (local.get $n)) (local.set $fn) (local.set $fp)
  (if (global.get $err) (then (return)))
  (if (local.get $fn)
    (then (call $enc_tabular (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0)
                             (local.get $arr) (local.get $n) (local.get $fp) (local.get $fn) (i32.const 0) (i32.const 0) (i32.const 1)))
    (else (call $enc_expanded (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (local.get $arr) (local.get $n) (i32.const 0)))))

(func $enc_object (param $obj i32) (param $n i32) (param $depth i32)
  (local $i i32) (local $m i32) (local $t i32) (local $km i32)
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $m (i32.add (local.get $obj) (i32.mul (local.get $i) (i32.const 24))))
    (local.set $t (i32.load offset=8 (local.get $m)))
    (block $next
      (if (i32.eq (local.get $t) (i32.const 6))
        (then
          (call $named_array (i32.load (local.get $m)) (i32.load offset=4 (local.get $m)) (i32.load offset=12 (local.get $m)) (i32.load offset=16 (local.get $m)) (local.get $depth))
          (br $next)))
      (if (i32.eq (local.get $t) (i32.const 7))
        (then
          (local.set $km (call $keyed_eligible (i32.load offset=12 (local.get $m)) (i32.load offset=16 (local.get $m))))
          (if (global.get $err) (then (return)))
          (if (local.get $km)
            (then
              (call $keyed_map (local.get $depth) (i32.const 1) (i32.load (local.get $m)) (i32.load offset=4 (local.get $m)) (i32.const 0)
                               (i32.load offset=12 (local.get $m)) (i32.load offset=16 (local.get $m)) (local.get $km) (local.get $depth))
              (br $next)))
          (call $o_indent (local.get $depth))
          (call $o_bytes (global.get $S_SECTION) (i32.const 3))
          (call $o_key (i32.load (local.get $m)) (i32.load offset=4 (local.get $m)))
          (call $o_byte (i32.const 0x0A))
          (call $enc_object (i32.load offset=12 (local.get $m)) (i32.load offset=16 (local.get $m)) (i32.add (local.get $depth) (i32.const 1)))
          (br $next)))
      (call $o_indent (local.get $depth))
      (call $o_key (i32.load (local.get $m)) (i32.load offset=4 (local.get $m)))
      (call $o_byte (i32.const 0x3D))
      (call $o_scalar_at (i32.add (local.get $m) (i32.const 8)))
      (call $o_byte (i32.const 0x0A)))
    (if (global.get $err) (then (return)))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l))))

;; Keyed-table eligibility (SPEC §7.2a.1). Returns a 16-byte record
;; (value fields, count, label ptr, label len) or 0.
(func $keyed_eligible (param $obj i32) (param $n i32) (result i32)
  (local $i i32) (local $m i32) (local $mark i32) (local $cnt i32) (local $set i32) (local $any i32) (local $q i32)
  (local $lp i32) (local $ln i32) (local $clash i32) (local $fp i32) (local $km i32)
  (if (i32.lt_u (local.get $n) (i32.const 2)) (then (return (i32.const 0))))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (if (i32.ne (i32.load offset=8 (i32.add (local.get $obj) (i32.mul (local.get $i) (i32.const 24)))) (i32.const 7)) (then (return (i32.const 0))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.set $mark (call $stack_len (global.get $STK_MISC)))
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $m (i32.add (local.get $obj) (i32.mul (local.get $i) (i32.const 24))))
    (call $union_object (local.get $mark) (local.get $cnt) (local.get $set) (i32.load offset=12 (local.get $m)) (i32.load offset=16 (local.get $m)))
    (local.set $set) (local.set $cnt)
    (if (global.get $err) (then (return (i32.const 0))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.set $fp (call $stack_pop_to_arena (global.get $STK_MISC) (local.get $mark)))
  (if (i32.eqz (local.get $cnt)) (then (return (i32.const 0))))
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $cnt)))
    (local.set $q (i32.add (local.get $fp) (i32.shl (local.get $i) (i32.const 3))))
    (if (i32.eqz (call $contains_gt (i32.load (local.get $q)) (i32.load offset=4 (local.get $q)))) (then (local.set $any (i32.const 1))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (if (i32.eqz (local.get $any)) (then (return (i32.const 0))))
  ;; key-column label: "key", prefixed with "_" until unique
  (local.set $lp (global.get $S_KEY))
  (local.set $ln (i32.const 3))
  (loop $again
    (local.set $clash (i32.const 0))
    (local.set $i (i32.const 0))
    (block $done (loop $l
      (br_if $done (i32.ge_u (local.get $i) (local.get $cnt)))
      (local.set $q (i32.add (local.get $fp) (i32.shl (local.get $i) (i32.const 3))))
      (if (call $str_eq (i32.load (local.get $q)) (i32.load offset=4 (local.get $q)) (local.get $lp) (local.get $ln)) (then (local.set $clash (i32.const 1))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
    (if (local.get $clash)
      (then
        (call $concat (i32.const 0) (i32.const 0) (i32.const 0x5F) (local.get $lp) (local.get $ln)) (local.set $ln) (local.set $lp)
        (if (global.get $err) (then (return (i32.const 0))))
        (br $again))))
  (local.set $km (call $alloc (i32.const 16)))
  (if (global.get $err) (then (return (i32.const 0))))
  (i32.store (local.get $km) (local.get $fp))
  (i32.store offset=4 (local.get $km) (local.get $cnt))
  (i32.store offset=8 (local.get $km) (local.get $lp))
  (i32.store offset=12 (local.get $km) (local.get $ln))
  (local.get $km))

;; Keyed map: rows are the member values with the label column prepended.
(func $keyed_map (param $pd i32) (param $pk i32) (param $pnp i32) (param $pnn i32) (param $pid i32) (param $obj i32) (param $n i32) (param $km i32) (param $depth i32)
  (local $nf i32) (local $fields i32) (local $rows i32) (local $i i32) (local $m i32) (local $inner i32) (local $in i32) (local $mem i32)
  (local.set $nf (i32.load offset=4 (local.get $km)))
  (local.set $fields (call $alloc (i32.shl (i32.add (local.get $nf) (i32.const 1)) (i32.const 3))))
  (local.set $rows (call $alloc (i32.shl (local.get $n) (i32.const 4))))
  (if (global.get $err) (then (return)))
  (i32.store (local.get $fields) (i32.load offset=8 (local.get $km)))
  (i32.store offset=4 (local.get $fields) (i32.load offset=12 (local.get $km)))
  (memory.copy (i32.add (local.get $fields) (i32.const 8)) (i32.load (local.get $km)) (i32.shl (local.get $nf) (i32.const 3)))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $m (i32.add (local.get $obj) (i32.mul (local.get $i) (i32.const 24))))
    (local.set $inner (i32.load offset=12 (local.get $m)))
    (local.set $in (i32.load offset=16 (local.get $m)))
    (local.set $mem (call $alloc (i32.mul (i32.add (local.get $in) (i32.const 1)) (i32.const 24))))
    (if (global.get $err) (then (return)))
    (call $store_member (local.get $mem) (i32.load offset=8 (local.get $km)) (i32.load offset=12 (local.get $km))
                        (i32.const 5) (i32.load (local.get $m)) (i64.extend_i32_u (i32.load offset=4 (local.get $m))))
    (memory.copy (i32.add (local.get $mem) (i32.const 24)) (local.get $inner) (i32.mul (local.get $in) (i32.const 24)))
    (call $store_node (i32.add (local.get $rows) (i32.shl (local.get $i) (i32.const 4))) (i32.const 7) (local.get $mem) (i64.extend_i32_u (i32.add (local.get $in) (i32.const 1))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (call $enc_tabular (local.get $pd) (local.get $pk) (local.get $pnp) (local.get $pnn) (local.get $pid)
                     (local.get $rows) (local.get $n) (local.get $fields) (i32.add (local.get $nf) (i32.const 1)) (local.get $depth) (i32.const 1) (i32.const 0)))

;; ---------------------------------------------------------------------------
;; Arrays
;; ---------------------------------------------------------------------------

(func $named_array (param $np i32) (param $nn i32) (param $arr i32) (param $n i32) (param $depth i32)
  (local $fp i32) (local $fn i32)
  (if (i32.eqz (local.get $n))
    (then
      (call $o_indent (local.get $depth))
      (call $o_bytes (global.get $S_SECTION) (i32.const 3))
      (call $o_key (local.get $np) (local.get $nn))
      (call $o_bytes (global.get $S_ZERO) (i32.const 5))
      (return)))
  (if (call $all_primitives (local.get $arr) (local.get $n))
    (then
      (call $o_indent (local.get $depth))
      (call $o_key (local.get $np) (local.get $nn))
      (call $o_byte (i32.const 0x5B))
      (call $o_u32 (local.get $n))
      (call $o_bytes (global.get $S_CLOSE_COLON) (i32.const 3))
      (call $o_primitive_list (local.get $arr) (local.get $n))
      (call $o_byte (i32.const 0x0A))
      (return)))
  (call $tabular_fields (local.get $arr) (local.get $n)) (local.set $fn) (local.set $fp)
  (if (global.get $err) (then (return)))
  (if (local.get $fn)
    (then (call $enc_tabular (local.get $depth) (i32.const 1) (local.get $np) (local.get $nn) (i32.const 0)
                             (local.get $arr) (local.get $n) (local.get $fp) (local.get $fn) (local.get $depth) (i32.const 0) (i32.const 1)))
    (else (call $enc_expanded (local.get $depth) (i32.const 1) (local.get $np) (local.get $nn) (i32.const 0) (local.get $arr) (local.get $n) (local.get $depth)))))

(func $enc_expanded (param $pd i32) (param $pk i32) (param $pnp i32) (param $pnn i32) (param $pid i32) (param $arr i32) (param $n i32) (param $depth i32)
  (local $i i32) (local $q i32) (local $t i32) (local $km i32)
  (call $o_prefix (local.get $pd) (local.get $pk) (local.get $pnp) (local.get $pnn) (local.get $pid))
  (call $o_byte (i32.const 0x5B))
  (call $o_u32 (local.get $n))
  (call $o_bytes (global.get $S_CLOSE_NL) (i32.const 2))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $q (i32.add (local.get $arr) (i32.shl (local.get $i) (i32.const 4))))
    (local.set $t (i32.load (local.get $q)))
    (block $next
      (if (i32.eq (local.get $t) (i32.const 6))
        (then (call $expanded_array_item (local.get $depth) (local.get $i) (i32.load offset=4 (local.get $q)) (i32.load offset=8 (local.get $q))) (br $next)))
      (if (i32.eq (local.get $t) (i32.const 7))
        (then
          (local.set $km (call $keyed_eligible (i32.load offset=4 (local.get $q)) (i32.load offset=8 (local.get $q))))
          (if (global.get $err) (then (return)))
          (if (local.get $km)
            (then
              (call $keyed_map (local.get $depth) (i32.const 3) (i32.const 0) (i32.const 0) (local.get $i)
                               (i32.load offset=4 (local.get $q)) (i32.load offset=8 (local.get $q)) (local.get $km) (i32.add (local.get $depth) (i32.const 1)))
              (br $next)))
          (call $o_indent (local.get $depth))
          (call $o_byte (i32.const 0x40))
          (call $o_u32 (local.get $i))
          (call $o_bytes (global.get $S_EMPTYOBJ) (i32.const 4))
          (call $enc_object (i32.load offset=4 (local.get $q)) (i32.load offset=8 (local.get $q)) (i32.add (local.get $depth) (i32.const 1)))
          (br $next)))
      (call $o_indent (local.get $depth))
      (call $o_byte (i32.const 0x40))
      (call $o_u32 (local.get $i))
      (call $o_bytes (global.get $S_SPEQ) (i32.const 2))
      (call $o_scalar_at (local.get $q))
      (call $o_byte (i32.const 0x0A)))
    (if (global.get $err) (then (return)))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l))))

;; Writes ` [n]\n` (n = 0) or ` [n]: a,b,c\n` after a line start.
(func $o_inline_list (param $arr i32) (param $n i32)
  (call $o_bytes (global.get $S_SPBR) (i32.const 2))
  (call $o_u32 (local.get $n))
  (if (i32.eqz (local.get $n)) (then (call $o_bytes (global.get $S_CLOSE_NL) (i32.const 2)) (return)))
  (call $o_bytes (global.get $S_CLOSE_COLON) (i32.const 3))
  (call $o_primitive_list (local.get $arr) (local.get $n))
  (call $o_byte (i32.const 0x0A)))

(func $expanded_array_item (param $depth i32) (param $idx i32) (param $arr i32) (param $n i32)
  (local $fp i32) (local $fn i32)
  (if (i32.or (i32.eqz (local.get $n)) (call $all_primitives (local.get $arr) (local.get $n)))
    (then
      (call $o_indent (local.get $depth))
      (call $o_byte (i32.const 0x40))
      (call $o_u32 (local.get $idx))
      (call $o_inline_list (local.get $arr) (local.get $n))
      (return)))
  (call $tabular_fields (local.get $arr) (local.get $n)) (local.set $fn) (local.set $fp)
  (if (global.get $err) (then (return)))
  (if (local.get $fn)
    (then (call $enc_tabular (local.get $depth) (i32.const 3) (i32.const 0) (i32.const 0) (local.get $idx)
                             (local.get $arr) (local.get $n) (local.get $fp) (local.get $fn) (i32.add (local.get $depth) (i32.const 1)) (i32.const 0) (i32.const 0)))
    (else (call $enc_expanded (local.get $depth) (i32.const 3) (i32.const 0) (i32.const 0) (local.get $idx) (local.get $arr) (local.get $n) (i32.add (local.get $depth) (i32.const 1))))))

(func $attachment_array (param $rd i32) (param $np i32) (param $nn i32) (param $arr i32) (param $n i32) (param $depth i32)
  (local $fp i32) (local $fn i32)
  (if (i32.or (i32.eqz (local.get $n)) (call $all_primitives (local.get $arr) (local.get $n)))
    (then
      (call $o_indent (local.get $rd))
      (call $o_byte (i32.const 0x2E))
      (call $o_key (local.get $np) (local.get $nn))
      (call $o_inline_list (local.get $arr) (local.get $n))
      (return)))
  (call $tabular_fields (local.get $arr) (local.get $n)) (local.set $fn) (local.set $fp)
  (if (global.get $err) (then (return)))
  (if (local.get $fn)
    (then (call $enc_tabular (local.get $rd) (i32.const 2) (local.get $np) (local.get $nn) (i32.const 0)
                             (local.get $arr) (local.get $n) (local.get $fp) (local.get $fn) (local.get $depth) (i32.const 0) (i32.const 0)))
    (else (call $enc_expanded (local.get $rd) (i32.const 2) (local.get $np) (local.get $nn) (i32.const 0) (local.get $arr) (local.get $n) (local.get $depth)))))

;; `.field [N]` reusing an established shared array schema (SPEC §7.4.5.3).
(func $attachment_array_shared (param $rd i32) (param $np i32) (param $nn i32) (param $arr i32) (param $n i32) (param $depth i32) (param $sh i32) (param $shn i32)
  (local $fp i32) (local $fn i32) (local $i i32) (local $j i32) (local $q i32) (local $f i32) (local $m i32)
  (if (i32.and (i32.gt_u (local.get $n) (i32.const 0)) (i32.eqz (call $all_primitives (local.get $arr) (local.get $n))))
    (then
      (call $tabular_fields (local.get $arr) (local.get $n)) (local.set $fn) (local.set $fp)
      (if (global.get $err) (then (return)))
      (if (local.get $fn)
        (then (if (call $same_strings (local.get $fp) (local.get $fn) (local.get $sh) (local.get $shn))
          (then
            (call $o_indent (local.get $rd))
            (call $o_byte (i32.const 0x2E))
            (call $o_key (local.get $np) (local.get $nn))
            (call $o_bytes (global.get $S_SPBR) (i32.const 2))
            (call $o_u32 (local.get $n))
            (call $o_bytes (global.get $S_CLOSE_NL) (i32.const 2))
            (block $done (loop $l
              (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
              (local.set $q (i32.add (local.get $arr) (i32.shl (local.get $i) (i32.const 4))))
              (call $o_indent (local.get $depth))
              (local.set $j (i32.const 0))
              (block $jd (loop $jl
                (br_if $jd (i32.ge_u (local.get $j) (local.get $shn)))
                (if (local.get $j) (then (call $o_byte (i32.const 0x7C))))
                (local.set $f (i32.add (local.get $sh) (i32.shl (local.get $j) (i32.const 3))))
                (local.set $m (call $field (i32.load offset=4 (local.get $q)) (i32.load offset=8 (local.get $q)) (i32.load (local.get $f)) (i32.load offset=4 (local.get $f)) (local.get $j)))
                (if (local.get $m) (then (call $o_scalar_at (i32.add (local.get $m) (i32.const 8)))) (else (call $o_byte (i32.const 0x7E))))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $jl)))
              (call $o_byte (i32.const 0x0A))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $l)))
            (return)))))))
  (call $attachment_array (local.get $rd) (local.get $np) (local.get $nn) (local.get $arr) (local.get $n) (local.get $depth)))

;; ---------------------------------------------------------------------------
;; Flattening (SPEC §7.4.6)
;; ---------------------------------------------------------------------------

(func $is_unsafe_key (param $p i32) (param $n i32) (result i32)
  (i32.or (i32.or (call $str_eq (local.get $p) (local.get $n) (global.get $S_PROTO) (i32.const 9))
                  (call $str_eq (local.get $p) (local.get $n) (global.get $S_CTOR) (i32.const 11)))
          (call $str_eq (local.get $p) (local.get $n) (global.get $S_PROTOTYPE) (i32.const 9))))

;; Follow a key chain from a row node: returns (exists, node ptr). A null at
;; the first key exists (as null); any later non-object breaks the chain.
(func $resolve_chain (param $item i32) (param $keys i32) (param $kn i32) (result i32 i32)
  (local $m i32) (local $cur i32) (local $i i32) (local $k i32)
  (if (i32.or (i32.eqz (local.get $kn)) (i32.ne (i32.load (local.get $item)) (i32.const 7))) (then (return (i32.const 0) (i32.const 0))))
  (local.set $m (call $field_of (local.get $item) (i32.load (local.get $keys)) (i32.load offset=4 (local.get $keys)) (i32.const 0)))
  (if (i32.eqz (local.get $m)) (then (return (i32.const 0) (i32.const 0))))
  (local.set $cur (i32.add (local.get $m) (i32.const 8)))
  (if (i32.eqz (i32.load (local.get $cur))) (then (return (i32.const 1) (local.get $cur))))
  (local.set $i (i32.const 1))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $kn)))
    (if (i32.ne (i32.load (local.get $cur)) (i32.const 7)) (then (return (i32.const 0) (i32.const 0))))
    (local.set $k (i32.add (local.get $keys) (i32.shl (local.get $i) (i32.const 3))))
    (local.set $m (call $field_of (local.get $cur) (i32.load (local.get $k)) (i32.load offset=4 (local.get $k)) (i32.const 0)))
    (if (i32.eqz (local.get $m)) (then (return (i32.const 0) (i32.const 0))))
    (local.set $cur (i32.add (local.get $m) (i32.const 8)))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (i32.const 1) (local.get $cur))

;; Leaves for flattening field `name` across the rows `arr`, or ok = 0 when
;; ineligible. `parent` is the key chain from the row to the object holding
;; `name`. Returns (leaves, count, ok).
;; Shape entry (12 bytes): key ptr, key len, nested flag.
(func $analyze_flattenable (param $arr i32) (param $n i32) (param $np i32) (param $nn i32) (param $par i32) (param $parn i32) (result i32 i32 i32)
  (local $shape i32) (local $shn i32) (local $i i32) (local $q i32) (local $m i32) (local $v i32) (local $vt i32) (local $mem i32) (local $mn i32)
  (local $j i32) (local $mm i32) (local $s i32) (local $k i32) (local $found i32) (local $nested i32)
  (local $chain i32) (local $chn i32) (local $pp i32) (local $pn i32) (local $mark i32) (local $cnt i32) (local $keys i32)
  (local $lp i32) (local $ln i32) (local $sub i32) (local $slp i32) (local $sln i32) (local $sok i32) (local $allnull i32) (local $leaf i32)
  (local $ex i32) (local $node i32)
  (if (i32.or (i32.eqz (local.get $nn)) (call $contains_gt (local.get $np) (local.get $nn))) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
  (local.set $shape (i32.const -1))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $q (i32.add (local.get $arr) (i32.shl (local.get $i) (i32.const 4))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (local.set $m (call $field_of (local.get $q) (local.get $np) (local.get $nn) (i32.const 0)))
    (br_if $l (i32.eqz (local.get $m)))
    (local.set $vt (i32.load offset=8 (local.get $m)))
    (if (i32.eqz (local.get $vt))
      (then
        (if (local.get $parn) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
        (br $l)))
    (if (i32.ne (local.get $vt) (i32.const 7)) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
    (local.set $mem (i32.load offset=12 (local.get $m)))
    (local.set $mn (i32.load offset=16 (local.get $m)))
    (if (i32.ge_s (local.get $shape) (i32.const 0))
      (then
        (if (i32.ne (local.get $mn) (local.get $shn)) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
        (local.set $j (i32.const 0))
        (block $jd (loop $jl
          (br_if $jd (i32.ge_u (local.get $j) (local.get $mn)))
          (local.set $mm (i32.add (local.get $mem) (i32.mul (local.get $j) (i32.const 24))))
          (local.set $found (i32.const -1))
          (local.set $k (i32.const 0))
          (block $kd (loop $kl
            (br_if $kd (i32.ge_u (local.get $k) (local.get $shn)))
            (local.set $s (i32.add (local.get $shape) (i32.mul (local.get $k) (i32.const 12))))
            (if (call $str_eq (i32.load (local.get $s)) (i32.load offset=4 (local.get $s)) (i32.load (local.get $mm)) (i32.load offset=4 (local.get $mm)))
              (then (local.set $found (i32.load offset=8 (local.get $s)))))
            (local.set $k (i32.add (local.get $k) (i32.const 1)))
            (br $kl)))
          (if (i32.lt_s (local.get $found) (i32.const 0)) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
          (local.set $vt (i32.load offset=8 (local.get $mm)))
          (if (i32.eqz (local.get $found))
            (then (if (call $is_composite (local.get $vt)) (then (return (i32.const 0) (i32.const 0) (i32.const 0)))))
            (else (if (i32.and (i32.ne (local.get $vt) (i32.const 0)) (i32.ne (local.get $vt) (i32.const 7))) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))))
          (local.set $j (i32.add (local.get $j) (i32.const 1)))
          (br $jl))))
      (else
        (local.set $shape (call $alloc (i32.mul (local.get $mn) (i32.const 12))))
        (if (global.get $err) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
        (local.set $shn (local.get $mn))
        (local.set $j (i32.const 0))
        (block $jd (loop $jl
          (br_if $jd (i32.ge_u (local.get $j) (local.get $mn)))
          (local.set $mm (i32.add (local.get $mem) (i32.mul (local.get $j) (i32.const 24))))
          (if (i32.or (i32.or (i32.eqz (i32.load offset=4 (local.get $mm))) (call $contains_gt (i32.load (local.get $mm)) (i32.load offset=4 (local.get $mm))))
                      (call $is_unsafe_key (i32.load (local.get $mm)) (i32.load offset=4 (local.get $mm))))
            (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
          (local.set $vt (i32.load offset=8 (local.get $mm)))
          (if (i32.eq (local.get $vt) (i32.const 6)) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
          (local.set $s (i32.add (local.get $shape) (i32.mul (local.get $j) (i32.const 12))))
          (i32.store (local.get $s) (i32.load (local.get $mm)))
          (i32.store offset=4 (local.get $s) (i32.load offset=4 (local.get $mm)))
          (i32.store offset=8 (local.get $s) (i32.eq (local.get $vt) (i32.const 7)))
          (local.set $j (i32.add (local.get $j) (i32.const 1)))
          (br $jl)))))
    (br $l)))
  (if (i32.lt_s (local.get $shape) (i32.const 0)) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
  ;; chain = parent + [name]; path = join(">", chain)
  (local.set $chn (i32.add (local.get $parn) (i32.const 1)))
  (local.set $chain (call $alloc (i32.shl (local.get $chn) (i32.const 3))))
  (if (global.get $err) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
  (memory.copy (local.get $chain) (local.get $par) (i32.shl (local.get $parn) (i32.const 3)))
  (i32.store (i32.add (local.get $chain) (i32.shl (local.get $parn) (i32.const 3))) (local.get $np))
  (i32.store offset=4 (i32.add (local.get $chain) (i32.shl (local.get $parn) (i32.const 3))) (local.get $nn))
  (local.set $pp (i32.load (local.get $chain)))
  (local.set $pn (i32.load offset=4 (local.get $chain)))
  (local.set $j (i32.const 1))
  (block $jd (loop $jl
    (br_if $jd (i32.ge_u (local.get $j) (local.get $chn)))
    (local.set $s (i32.add (local.get $chain) (i32.shl (local.get $j) (i32.const 3))))
    (call $concat (local.get $pp) (local.get $pn) (i32.const 0x3E) (i32.load (local.get $s)) (i32.load offset=4 (local.get $s)))
    (local.set $pn) (local.set $pp)
    (if (global.get $err) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
    (local.set $j (i32.add (local.get $j) (i32.const 1)))
    (br $jl)))
  ;; leaves: collected on STK_SLOTS (16-byte entries) and copied out at the end
  (local.set $mark (call $stack_len (global.get $STK_SLOTS)))
  (local.set $k (i32.const 0))
  (block $kd (loop $kl
    (br_if $kd (i32.ge_u (local.get $k) (local.get $shn)))
    (local.set $s (i32.add (local.get $shape) (i32.mul (local.get $k) (i32.const 12))))
    (if (i32.eqz (i32.load offset=8 (local.get $s)))
      (then
        (local.set $keys (call $alloc (i32.shl (i32.add (local.get $chn) (i32.const 1)) (i32.const 3))))
        (if (global.get $err) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
        (memory.copy (local.get $keys) (local.get $chain) (i32.shl (local.get $chn) (i32.const 3)))
        (i32.store (i32.add (local.get $keys) (i32.shl (local.get $chn) (i32.const 3))) (i32.load (local.get $s)))
        (i32.store offset=4 (i32.add (local.get $keys) (i32.shl (local.get $chn) (i32.const 3))) (i32.load offset=4 (local.get $s)))
        (call $concat (local.get $pp) (local.get $pn) (i32.const 0x3E) (i32.load (local.get $s)) (i32.load offset=4 (local.get $s)))
        (local.set $ln) (local.set $lp)
        (local.set $leaf (call $stack_push (global.get $STK_SLOTS) (i32.const 16)))
        (if (global.get $err) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
        (i32.store (local.get $leaf) (local.get $lp))
        (i32.store offset=4 (local.get $leaf) (local.get $ln))
        (i32.store offset=8 (local.get $leaf) (local.get $keys))
        (i32.store offset=12 (local.get $leaf) (i32.add (local.get $chn) (i32.const 1))))
      (else
        ;; nested object: recurse over the sub-objects (absent/null -> {})
        (local.set $sub (call $alloc (i32.shl (local.get $n) (i32.const 4))))
        (if (global.get $err) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
        (local.set $i (i32.const 0))
        (block $id (loop $il
          (br_if $id (i32.ge_u (local.get $i) (local.get $n)))
          (local.set $q (i32.add (local.get $arr) (i32.shl (local.get $i) (i32.const 4))))
          (local.set $m (call $field_of (local.get $q) (local.get $np) (local.get $nn) (i32.const 0)))
          (if (i32.and (i32.ne (local.get $m) (i32.const 0)) (i32.eq (i32.load offset=8 (local.get $m)) (i32.const 7)))
            (then (v128.store (i32.add (local.get $sub) (i32.shl (local.get $i) (i32.const 4))) (v128.load offset=8 (local.get $m))))
            (else (call $store_node (i32.add (local.get $sub) (i32.shl (local.get $i) (i32.const 4))) (i32.const 7) (i32.const 0) (i64.const 0))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $il)))
        (call $analyze_flattenable (local.get $sub) (local.get $n) (i32.load (local.get $s)) (i32.load offset=4 (local.get $s)) (local.get $chain) (local.get $chn))
        (local.set $sok) (local.set $sln) (local.set $slp)
        (if (global.get $err) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
        (if (i32.or (i32.eqz (local.get $sok)) (i32.eqz (local.get $sln)))
          (then (call $stack_truncate (global.get $STK_SLOTS) (local.get $mark)) (return (i32.const 0) (i32.const 0) (i32.const 0))))
        (local.set $leaf (call $stack_push (global.get $STK_SLOTS) (i32.shl (local.get $sln) (i32.const 4))))
        (if (global.get $err) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
        (memory.copy (local.get $leaf) (local.get $slp) (i32.shl (local.get $sln) (i32.const 4)))))
    (local.set $k (i32.add (local.get $k) (i32.const 1)))
    (br $kl)))
  (local.set $cnt (i32.shr_u (i32.sub (call $stack_len (global.get $STK_SLOTS)) (local.get $mark)) (i32.const 4)))
  (local.set $lp (call $stack_pop_to_arena (global.get $STK_SLOTS) (local.get $mark)))
  ;; reject when a present, non-null object has every leaf null
  (if (local.get $cnt)
    (then
      (local.set $i (i32.const 0))
      (block $id (loop $il
        (br_if $id (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $q (i32.add (local.get $arr) (i32.shl (local.get $i) (i32.const 4))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (local.set $m (call $field_of (local.get $q) (local.get $np) (local.get $nn) (i32.const 0)))
        (br_if $il (i32.eqz (local.get $m)))
        (br_if $il (i32.eqz (i32.load offset=8 (local.get $m))))
        (local.set $allnull (i32.const 1))
        (local.set $k (i32.const 0))
        (block $kd (loop $kl
          (br_if $kd (i32.ge_u (local.get $k) (local.get $cnt)))
          (local.set $leaf (i32.add (local.get $lp) (i32.shl (local.get $k) (i32.const 4))))
          (call $resolve_chain (local.get $q) (i32.load offset=8 (local.get $leaf)) (i32.load offset=12 (local.get $leaf)))
          (local.set $node) (local.set $ex)
          (if (i32.eqz (i32.and (local.get $ex) (i32.eqz (i32.load (local.get $node)))))
            (then (local.set $allnull (i32.const 0)) (br $kd)))
          (local.set $k (i32.add (local.get $k) (i32.const 1)))
          (br $kl)))
        (if (local.get $allnull) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
        (br $il)))))
  (local.get $lp) (local.get $cnt) (i32.const 1))

;; ---------------------------------------------------------------------------
;; Inline and shared schemas (SPEC §7.4.5)
;; ---------------------------------------------------------------------------

(func $inline_schema (param $arr i32) (param $n i32) (param $np i32) (param $nn i32) (result i32 i32)
  (local $m i32) (local $i i32) (local $q i32) (local $vt i32) (local $mem i32) (local $mn i32) (local $cm i32) (local $cn i32)
  (local $j i32) (local $keys i32)
  (local.set $m (call $field_of (local.get $arr) (local.get $np) (local.get $nn) (i32.const 0)))
  (if (i32.eqz (local.get $m)) (then (return (i32.const 0) (i32.const 0))))
  (if (i32.ne (i32.load offset=8 (local.get $m)) (i32.const 7)) (then (return (i32.const 0) (i32.const 0))))
  (local.set $cm (i32.const -1))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $q (i32.add (local.get $arr) (i32.shl (local.get $i) (i32.const 4))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (local.set $m (call $field_of (local.get $q) (local.get $np) (local.get $nn) (i32.const 0)))
    (br_if $l (i32.eqz (local.get $m)))
    (local.set $vt (i32.load offset=8 (local.get $m)))
    (br_if $l (i32.eqz (local.get $vt)))
    (if (i32.ne (local.get $vt) (i32.const 7)) (then (return (i32.const 0) (i32.const 0))))
    (local.set $mem (i32.load offset=12 (local.get $m)))
    (local.set $mn (i32.load offset=16 (local.get $m)))
    (local.set $j (i32.const 0))
    (block $jd (loop $jl
      (br_if $jd (i32.ge_u (local.get $j) (local.get $mn)))
      (if (call $is_composite (i32.load offset=8 (i32.add (local.get $mem) (i32.mul (local.get $j) (i32.const 24))))) (then (return (i32.const 0) (i32.const 0))))
      (local.set $j (i32.add (local.get $j) (i32.const 1)))
      (br $jl)))
    (if (i32.ge_s (local.get $cm) (i32.const 0))
      (then
        (if (i32.ne (local.get $cn) (local.get $mn)) (then (return (i32.const 0) (i32.const 0))))
        (local.set $j (i32.const 0))
        (block $jd (loop $jl
          (br_if $jd (i32.ge_u (local.get $j) (local.get $mn)))
          (local.set $q (i32.add (local.get $cm) (i32.mul (local.get $j) (i32.const 24))))
          (local.set $vt (i32.add (local.get $mem) (i32.mul (local.get $j) (i32.const 24))))
          (if (i32.eqz (call $str_eq (i32.load (local.get $q)) (i32.load offset=4 (local.get $q)) (i32.load (local.get $vt)) (i32.load offset=4 (local.get $vt))))
            (then (return (i32.const 0) (i32.const 0))))
          (local.set $j (i32.add (local.get $j) (i32.const 1)))
          (br $jl))))
      (else (local.set $cm (local.get $mem)) (local.set $cn (local.get $mn))))
    (br $l)))
  (if (i32.lt_s (local.get $cm) (i32.const 0)) (then (return (i32.const 0) (i32.const 0))))
  (if (i32.lt_u (local.get $cn) (i32.const 3)) (then (return (i32.const 0) (i32.const 0))))
  (local.set $keys (call $alloc (i32.shl (local.get $cn) (i32.const 3))))
  (if (global.get $err) (then (return (i32.const 0) (i32.const 0))))
  (local.set $j (i32.const 0))
  (block $jd (loop $jl
    (br_if $jd (i32.ge_u (local.get $j) (local.get $cn)))
    (i32.store (i32.add (local.get $keys) (i32.shl (local.get $j) (i32.const 3))) (i32.load (i32.add (local.get $cm) (i32.mul (local.get $j) (i32.const 24)))))
    (i32.store offset=4 (i32.add (local.get $keys) (i32.shl (local.get $j) (i32.const 3))) (i32.load offset=4 (i32.add (local.get $cm) (i32.mul (local.get $j) (i32.const 24)))))
    (local.set $j (i32.add (local.get $j) (i32.const 1)))
    (br $jl)))
  (local.get $keys) (local.get $cn))

(func $shared_array_schema (param $arr i32) (param $n i32) (param $np i32) (param $nn i32) (result i32 i32)
  (local $m i32) (local $i i32) (local $q i32) (local $vt i32) (local $fp i32) (local $fn i32) (local $cp i32) (local $cn i32) (local $have i32)
  (local $j i32) (local $inner i32) (local $k i32) (local $ia i32) (local $ian i32)
  (local.set $m (call $field_of (local.get $arr) (local.get $np) (local.get $nn) (i32.const 0)))
  (if (i32.eqz (local.get $m)) (then (return (i32.const 0) (i32.const 0))))
  (if (i32.ne (i32.load offset=8 (local.get $m)) (i32.const 6)) (then (return (i32.const 0) (i32.const 0))))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $q (i32.add (local.get $arr) (i32.shl (local.get $i) (i32.const 4))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (local.set $m (call $field_of (local.get $q) (local.get $np) (local.get $nn) (i32.const 0)))
    (br_if $l (i32.eqz (local.get $m)))
    (local.set $vt (i32.load offset=8 (local.get $m)))
    (br_if $l (i32.eqz (local.get $vt)))
    (if (i32.ne (local.get $vt) (i32.const 6)) (then (return (i32.const 0) (i32.const 0))))
    (local.set $ia (i32.load offset=12 (local.get $m)))
    (local.set $ian (i32.load offset=16 (local.get $m)))
    (call $tabular_fields (local.get $ia) (local.get $ian)) (local.set $fn) (local.set $fp)
    (if (global.get $err) (then (return (i32.const 0) (i32.const 0))))
    (if (i32.eqz (local.get $fn)) (then (return (i32.const 0) (i32.const 0))))
    (local.set $j (i32.const 0))
    (block $jd (loop $jl
      (br_if $jd (i32.ge_u (local.get $j) (local.get $ian)))
      (local.set $inner (i32.add (local.get $ia) (i32.shl (local.get $j) (i32.const 4))))
      (local.set $k (i32.const 0))
      (block $kd (loop $kl
        (br_if $kd (i32.ge_u (local.get $k) (i32.load offset=8 (local.get $inner))))
        (if (call $is_composite (i32.load offset=8 (i32.add (i32.load offset=4 (local.get $inner)) (i32.mul (local.get $k) (i32.const 24)))))
          (then (return (i32.const 0) (i32.const 0))))
        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $kl)))
      (local.set $j (i32.add (local.get $j) (i32.const 1)))
      (br $jl)))
    (if (local.get $have)
      (then (if (i32.eqz (call $same_strings (local.get $cp) (local.get $cn) (local.get $fp) (local.get $fn))) (then (return (i32.const 0) (i32.const 0)))))
      (else (local.set $have (i32.const 1)) (local.set $cp (local.get $fp)) (local.set $cn (local.get $fn))))
    (br $l)))
  (if (i32.eqz (local.get $have)) (then (return (i32.const 0) (i32.const 0))))
  (local.get $cp) (local.get $cn))

;; ---------------------------------------------------------------------------
;; Tabular (SPEC §7.4)
;; ---------------------------------------------------------------------------

(func $enc_tabular (param $pd i32) (param $pk i32) (param $pnp i32) (param $pnn i32) (param $pid i32)
                   (param $arr i32) (param $n i32) (param $fields i32) (param $nf i32) (param $depth i32) (param $keyed i32) (param $factor i32)
  (local $leaves i32) (local $gt i32) (local $i i32) (local $f i32) (local $lp i32) (local $ln i32) (local $ok i32) (local $mark i32)
  (local $col i32) (local $cols i32) (local $nc i32) (local $j i32) (local $leaf i32) (local $inl i32) (local $shr i32) (local $x i32) (local $y i32)
  (local $isc i32) (local $cval i32) (local $r i32) (local $q i32) (local $m i32) (local $first i32) (local $fln i32) (local $wmark i32) (local $bare i32)
  (local $row i32) (local $has i32) (local $emit i32) (local $firstcell i32) (local $amark i32) (local $att i32) (local $na i32) (local $k i32)
  (local $ex i32) (local $node i32) (local $vt i32) (local $sh i32) (local $km i32) (local $an i32)
  ;; phase 0: flattening analysis -> leaves_of[i] (list, count)
  (local.set $leaves (call $alloc (i32.shl (local.get $nf) (i32.const 3))))
  (local.set $gt (call $alloc (local.get $nf)))
  (if (global.get $err) (then (return)))
  (memory.fill (local.get $leaves) (i32.const 0) (i32.shl (local.get $nf) (i32.const 3)))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $nf)))
    (local.set $f (i32.add (local.get $fields) (i32.shl (local.get $i) (i32.const 3))))
    (if (i32.eqz (global.get $no_flatten))
      (then
        (call $analyze_flattenable (local.get $arr) (local.get $n) (i32.load (local.get $f)) (i32.load offset=4 (local.get $f)) (i32.const 0) (i32.const 0))
        (local.set $ok) (local.set $ln) (local.set $lp)
        (if (global.get $err) (then (return)))
        (if (i32.and (local.get $ok) (i32.ne (local.get $ln) (i32.const 0)))
          (then
            (i32.store (i32.add (local.get $leaves) (i32.shl (local.get $i) (i32.const 3))) (local.get $lp))
            (i32.store offset=4 (i32.add (local.get $leaves) (i32.shl (local.get $i) (i32.const 3))) (local.get $ln))))))
    ;; '>' fields that are not flattened become per-row attachments
    (i32.store8 (i32.add (local.get $gt) (local.get $i))
      (i32.and (i32.eqz (i32.load offset=4 (i32.add (local.get $leaves) (i32.shl (local.get $i) (i32.const 3)))))
               (call $contains_gt (i32.load (local.get $f)) (i32.load offset=4 (local.get $f)))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  ;; columns (collected on STK_SLOTS, 32 bytes each)
  (local.set $mark (call $stack_len (global.get $STK_SLOTS)))
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $nf)))
    (local.set $f (i32.add (local.get $fields) (i32.shl (local.get $i) (i32.const 3))))
    (block $next
      (br_if $next (call $at (local.get $gt) (local.get $i)))
      (local.set $ln (i32.load offset=4 (i32.add (local.get $leaves) (i32.shl (local.get $i) (i32.const 3)))))
      (if (local.get $ln)
        (then
          (local.set $lp (i32.load (i32.add (local.get $leaves) (i32.shl (local.get $i) (i32.const 3)))))
          (local.set $j (i32.const 0))
          (block $jd (loop $jl
            (br_if $jd (i32.ge_u (local.get $j) (local.get $ln)))
            (local.set $leaf (i32.add (local.get $lp) (i32.shl (local.get $j) (i32.const 4))))
            (local.set $col (call $stack_push (global.get $STK_SLOTS) (i32.const 32)))
            (if (global.get $err) (then (return)))
            (i32.store (local.get $col) (i32.const 0))
            (i32.store offset=4 (local.get $col) (i32.load (local.get $f)))
            (i32.store offset=8 (local.get $col) (i32.load offset=4 (local.get $f)))
            (i32.store offset=12 (local.get $col) (i32.load offset=8 (local.get $leaf)))
            (i32.store offset=16 (local.get $col) (i32.load offset=12 (local.get $leaf)))
            (i32.store offset=20 (local.get $col) (i32.load (local.get $leaf)))
            (i32.store offset=24 (local.get $col) (i32.load offset=4 (local.get $leaf)))
            (i32.store offset=28 (local.get $col) (local.get $i))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $jl)))
          (br $next)))
      (local.set $col (call $stack_push (global.get $STK_SLOTS) (i32.const 32)))
      (if (global.get $err) (then (return)))
      (i32.store (local.get $col) (i32.const 1))
      (i32.store offset=4 (local.get $col) (i32.load (local.get $f)))
      (i32.store offset=8 (local.get $col) (i32.load offset=4 (local.get $f)))
      (i32.store offset=12 (local.get $col) (i32.const 0))
      (i32.store offset=16 (local.get $col) (i32.const 0))
      (i32.store offset=20 (local.get $col) (i32.load (local.get $f)))
      (i32.store offset=24 (local.get $col) (i32.load offset=4 (local.get $f)))
      (i32.store offset=28 (local.get $col) (local.get $i)))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.set $nc (i32.shr_u (i32.sub (call $stack_len (global.get $STK_SLOTS)) (local.get $mark)) (i32.const 5)))
  (local.set $cols (call $stack_pop_to_arena (global.get $STK_SLOTS) (local.get $mark)))
  (if (i32.eqz (local.get $nc))
    (then (call $enc_expanded (local.get $pd) (local.get $pk) (local.get $pnp) (local.get $pnn) (local.get $pid) (local.get $arr) (local.get $n) (local.get $depth)) (return)))
  ;; inline and shared array schemas (non-flattened fields): (list, count) each
  (local.set $inl (call $alloc (i32.shl (local.get $nf) (i32.const 3))))
  (local.set $shr (call $alloc (i32.shl (local.get $nf) (i32.const 3))))
  (if (global.get $err) (then (return)))
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $nf)))
    (local.set $f (i32.add (local.get $fields) (i32.shl (local.get $i) (i32.const 3))))
    (local.set $x (i32.const 0)) (local.set $y (i32.const 0))
    (local.set $lp (i32.const 0)) (local.set $ln (i32.const 0))
    (if (i32.eqz (i32.load offset=4 (i32.add (local.get $leaves) (i32.shl (local.get $i) (i32.const 3)))))
      (then
        (call $inline_schema (local.get $arr) (local.get $n) (i32.load (local.get $f)) (i32.load offset=4 (local.get $f)))
        (local.set $y) (local.set $x)
        (call $shared_array_schema (local.get $arr) (local.get $n) (i32.load (local.get $f)) (i32.load offset=4 (local.get $f)))
        (local.set $ln) (local.set $lp)
        (if (global.get $err) (then (return)))))
    (i32.store (i32.add (local.get $inl) (i32.shl (local.get $i) (i32.const 3))) (local.get $x))
    (i32.store offset=4 (i32.add (local.get $inl) (i32.shl (local.get $i) (i32.const 3))) (local.get $y))
    (i32.store (i32.add (local.get $shr) (i32.shl (local.get $i) (i32.const 3))) (local.get $lp))
    (i32.store offset=4 (i32.add (local.get $shr) (i32.shl (local.get $i) (i32.const 3))) (local.get $ln))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  ;; constant-column factoring (SPEC §7.4.7): compare canonical renderings,
  ;; rendered at the output cursor and rewound
  (local.set $isc (call $alloc (local.get $nc)))
  (local.set $cval (call $alloc (i32.shl (local.get $nc) (i32.const 2))))
  (if (global.get $err) (then (return)))
  (memory.fill (local.get $isc) (i32.const 0) (local.get $nc))
  (if (i32.and (i32.and (local.get $factor) (i32.eqz (local.get $keyed))) (i32.ge_u (local.get $n) (i32.const 2)))
    (then
      (local.set $j (i32.const 0))
      (block $jd (loop $jl
        (br_if $jd (i32.ge_u (local.get $j) (local.get $nc)))
        (local.set $col (i32.add (local.get $cols) (i32.shl (local.get $j) (i32.const 5))))
        (block $skip
          (br_if $skip (i32.eqz (i32.load (local.get $col))))
          (local.set $ok (i32.const 1))
          (local.set $r (i32.const 0))
          (block $rd (loop $rl
            (br_if $rd (i32.ge_u (local.get $r) (local.get $n)))
            (local.set $q (i32.add (local.get $arr) (i32.shl (local.get $r) (i32.const 4))))
            (local.set $m (call $field (i32.load offset=4 (local.get $q)) (i32.load offset=8 (local.get $q))
                                       (i32.load offset=4 (local.get $col)) (i32.load offset=8 (local.get $col)) (i32.load offset=28 (local.get $col))))
            (if (i32.eqz (local.get $m)) (then (local.set $ok (i32.const 0)) (br $rd)))
            (if (call $is_composite (i32.load offset=8 (local.get $m))) (then (local.set $ok (i32.const 0)) (br $rd)))
            ;; same canonical rendering as the first row's value? (decided on
            ;; the values, without rendering them)
            (if (i32.eqz (local.get $r))
              (then (i32.store (i32.add (local.get $cval) (i32.shl (local.get $j) (i32.const 2))) (i32.add (local.get $m) (i32.const 8))))
              (else
                (if (i32.eqz (call $same_rendering (i32.load (i32.add (local.get $cval) (i32.shl (local.get $j) (i32.const 2)))) (i32.add (local.get $m) (i32.const 8))))
                  (then (local.set $ok (i32.const 0))))))
            (br_if $rd (i32.eqz (local.get $ok)))
            (local.set $r (i32.add (local.get $r) (i32.const 1)))
            (br $rl)))
          (i32.store8 (i32.add (local.get $isc) (local.get $j)) (local.get $ok)))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $jl)))
      (local.set $bare (i32.const 0))
      (local.set $j (i32.const 0))
      (block $jd (loop $jl
        (br_if $jd (i32.ge_u (local.get $j) (local.get $nc)))
        (if (i32.eqz (call $at (local.get $isc) (local.get $j))) (then (local.set $bare (i32.add (local.get $bare) (i32.const 1)))))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $jl)))
      (if (i32.eqz (local.get $bare)) (then (i32.store8 (i32.add (local.get $isc) (i32.sub (local.get $nc) (i32.const 1))) (i32.const 0))))))
  ;; header
  (call $o_prefix (local.get $pd) (local.get $pk) (local.get $pnp) (local.get $pnn) (local.get $pid))
  (call $o_byte (i32.const 0x5B))
  (call $o_u32 (local.get $n))
  (if (local.get $keyed) (then (call $o_bytes (global.get $S_KEYED) (i32.const 3))) (else (call $o_bytes (global.get $S_TAB) (i32.const 2))))
  (local.set $j (i32.const 0))
  (block $jd (loop $jl
    (br_if $jd (i32.ge_u (local.get $j) (local.get $nc)))
    (local.set $col (i32.add (local.get $cols) (i32.shl (local.get $j) (i32.const 5))))
    (if (local.get $j) (then (call $o_byte (i32.const 0x2C))))
    (call $o_key (i32.load offset=20 (local.get $col)) (i32.load offset=24 (local.get $col)))
    (if (call $at (local.get $isc) (local.get $j))
      (then (call $o_byte (i32.const 0x3D)) (call $o_const_value (i32.load (i32.add (local.get $cval) (i32.shl (local.get $j) (i32.const 2)))))))
    (local.set $j (i32.add (local.get $j) (i32.const 1)))
    (br $jl)))
  (call $o_bytes (global.get $S_HDREND) (i32.const 2))
  ;; rows
  (local.set $r (i32.const 0))
  (block $rd (loop $rl
    (br_if $rd (i32.ge_u (local.get $r) (local.get $n)))
    (local.set $row (i32.add (local.get $arr) (i32.shl (local.get $r) (i32.const 4))))
    ;; pre-pass: does the row carry attachments? (composite column values or
    ;; present '>' attachment fields) — decides the `@N ` prefix up front
    (local.set $has (i32.const 0))
    (local.set $j (i32.const 0))
    (block $hd (loop $hl
      (br_if $hd (i32.ge_u (local.get $j) (local.get $nc)))
      (local.set $col (i32.add (local.get $cols) (i32.shl (local.get $j) (i32.const 5))))
      (if (i32.load (local.get $col))
        (then
          (local.set $m (call $field (i32.load offset=4 (local.get $row)) (i32.load offset=8 (local.get $row))
                                     (i32.load offset=4 (local.get $col)) (i32.load offset=8 (local.get $col)) (i32.load offset=28 (local.get $col))))
          (if (local.get $m) (then (if (call $is_composite (i32.load offset=8 (local.get $m))) (then (local.set $has (i32.const 1)) (br $hd)))))))
      (local.set $j (i32.add (local.get $j) (i32.const 1)))
      (br $hl)))
    (if (i32.eqz (local.get $has))
      (then
        (local.set $i (i32.const 0))
        (block $gd (loop $gl
          (br_if $gd (i32.ge_u (local.get $i) (local.get $nf)))
          (if (call $at (local.get $gt) (local.get $i))
            (then
              (local.set $f (i32.add (local.get $fields) (i32.shl (local.get $i) (i32.const 3))))
              (if (call $field (i32.load offset=4 (local.get $row)) (i32.load offset=8 (local.get $row)) (i32.load (local.get $f)) (i32.load offset=4 (local.get $f)) (local.get $i))
                (then (local.set $has (i32.const 1)) (br $gd)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $gl)))))
    (call $o_indent (local.get $depth))
    (if (local.get $has) (then (call $o_byte (i32.const 0x40)) (call $o_u32 (local.get $r)) (call $o_byte (i32.const 0x20))))
    (local.set $amark (call $stack_len (global.get $STK_ROW)))
    (local.set $firstcell (i32.const 1))
    (local.set $j (i32.const 0))
    (block $cd (loop $cl
      (br_if $cd (i32.ge_u (local.get $j) (local.get $nc)))
      (local.set $col (i32.add (local.get $cols) (i32.shl (local.get $j) (i32.const 5))))
      (local.set $j (i32.add (local.get $j) (i32.const 1)))
      (local.set $emit (i32.eqz (call $at (local.get $isc) (i32.sub (local.get $j) (i32.const 1)))))
      (if (local.get $emit)
        (then
          (if (i32.eqz (local.get $firstcell)) (then (call $o_byte (i32.const 0x7C))))
          (local.set $firstcell (i32.const 0))))
      (if (i32.eqz (i32.load (local.get $col)))
        (then
          ;; flattened leaf
          (br_if $cl (i32.eqz (local.get $emit)))
          (local.set $k (i32.load offset=12 (local.get $col)))
          (local.set $m (call $field (i32.load offset=4 (local.get $row)) (i32.load offset=8 (local.get $row)) (i32.load (local.get $k)) (i32.load offset=4 (local.get $k)) (i32.load offset=28 (local.get $col))))
          (if (i32.eqz (local.get $m)) (then (call $o_byte (i32.const 0x7E)) (br $cl)))
          (if (i32.eqz (i32.load offset=8 (local.get $m))) (then (call $o_byte (i32.const 0x2D)) (br $cl)))
          (call $resolve_chain (local.get $row) (local.get $k) (i32.load offset=16 (local.get $col)))
          (local.set $node) (local.set $ex)
          (if (i32.eqz (local.get $ex)) (then (call $o_byte (i32.const 0x7E)) (br $cl)))
          (if (i32.eqz (i32.load (local.get $node))) (then (call $o_byte (i32.const 0x2D)) (br $cl)))
          (call $o_scalar_at (local.get $node))
          (br $cl)))
      (local.set $m (call $field (i32.load offset=4 (local.get $row)) (i32.load offset=8 (local.get $row))
                                 (i32.load offset=4 (local.get $col)) (i32.load offset=8 (local.get $col)) (i32.load offset=28 (local.get $col))))
      (if (i32.eqz (local.get $m)) (then (if (local.get $emit) (then (call $o_byte (i32.const 0x7E)))) (br $cl)))
      (local.set $vt (i32.load offset=8 (local.get $m)))
      (if (i32.eqz (local.get $vt)) (then (if (local.get $emit) (then (call $o_byte (i32.const 0x2D)))) (br $cl)))
      (if (call $is_composite (local.get $vt))
        (then
          (local.set $x (i32.add (local.get $inl) (i32.shl (i32.load offset=28 (local.get $col)) (i32.const 3))))
          (local.set $att (call $stack_push (global.get $STK_ROW) (i32.const 32)))
          (if (global.get $err) (then (return)))
          (i32.store (local.get $att) (i32.load offset=4 (local.get $col)))
          (i32.store offset=4 (local.get $att) (i32.load offset=8 (local.get $col)))
          (v128.store offset=8 (local.get $att) (v128.load offset=8 (local.get $m)))
          (i32.store offset=24 (local.get $att) (i32.const 0))
          (i32.store offset=28 (local.get $att) (i32.load offset=28 (local.get $col)))
          (if (i32.and (i32.ne (i32.load (local.get $x)) (i32.const 0)) (i32.eq (local.get $vt) (i32.const 7)))
            (then
              (i32.store offset=24 (local.get $att) (local.get $x))
              (if (i32.eqz (local.get $r))
                (then
                  (call $o_bytes (global.get $S_INLINE) (i32.const 2))
                  (local.set $k (i32.const 0))
                  (block $kd (loop $kl
                    (br_if $kd (i32.ge_u (local.get $k) (i32.load offset=4 (local.get $x))))
                    (if (local.get $k) (then (call $o_byte (i32.const 0x2C))))
                    (local.set $y (i32.add (i32.load (local.get $x)) (i32.shl (local.get $k) (i32.const 3))))
                    (call $o_key (i32.load (local.get $y)) (i32.load offset=4 (local.get $y)))
                    (local.set $k (i32.add (local.get $k) (i32.const 1)))
                    (br $kl)))
                  (call $o_byte (i32.const 0x7D)))
                (else (call $o_byte (i32.const 0x5E)))))
            (else (call $o_byte (i32.const 0x5E))))
          (br $cl)))
      (if (local.get $emit) (then (call $o_scalar_at (i32.add (local.get $m) (i32.const 8)))))
      (br $cl)))
    ;; '>' attachment fields
    (local.set $i (i32.const 0))
    (block $gd (loop $gl
      (br_if $gd (i32.ge_u (local.get $i) (local.get $nf)))
      (if (call $at (local.get $gt) (local.get $i))
        (then
          (local.set $f (i32.add (local.get $fields) (i32.shl (local.get $i) (i32.const 3))))
          (local.set $m (call $field (i32.load offset=4 (local.get $row)) (i32.load offset=8 (local.get $row)) (i32.load (local.get $f)) (i32.load offset=4 (local.get $f)) (local.get $i)))
          (if (local.get $m)
            (then
              (local.set $att (call $stack_push (global.get $STK_ROW) (i32.const 32)))
              (if (global.get $err) (then (return)))
              (i32.store (local.get $att) (i32.load (local.get $f)))
              (i32.store offset=4 (local.get $att) (i32.load offset=4 (local.get $f)))
              (v128.store offset=8 (local.get $att) (v128.load offset=8 (local.get $m)))
              (i32.store offset=24 (local.get $att) (i32.const 0))
              (i32.store offset=28 (local.get $att) (local.get $i))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $gl)))
    (call $o_byte (i32.const 0x0A))
    ;; attachment bodies (the stack may move: re-derive each entry's address)
    (local.set $na (i32.shr_u (i32.sub (call $stack_len (global.get $STK_ROW)) (local.get $amark)) (i32.const 5)))
    (local.set $an (i32.const 0))
    (block $ad (loop $al
      (br_if $ad (i32.ge_u (local.get $an) (local.get $na)))
      (local.set $att (i32.add (call $stack_base (global.get $STK_ROW)) (i32.add (local.get $amark) (i32.shl (local.get $an) (i32.const 5)))))
      (local.set $an (i32.add (local.get $an) (i32.const 1)))
      (local.set $x (i32.load offset=24 (local.get $att)))
      (if (local.get $x)
        (then
          ;; positional inline body
          (call $o_indent (local.get $depth))
          (local.set $k (i32.const 0))
          (block $kd (loop $kl
            (br_if $kd (i32.ge_u (local.get $k) (i32.load offset=4 (local.get $x))))
            (if (local.get $k) (then (call $o_byte (i32.const 0x7C))))
            (local.set $y (i32.add (i32.load (local.get $x)) (i32.shl (local.get $k) (i32.const 3))))
            (local.set $m (call $field (i32.load offset=12 (local.get $att)) (i32.load offset=16 (local.get $att)) (i32.load (local.get $y)) (i32.load offset=4 (local.get $y)) (local.get $k)))
            (if (local.get $m) (then (call $o_scalar_at (i32.add (local.get $m) (i32.const 8)))) (else (call $o_byte (i32.const 0x7E))))
            (local.set $k (i32.add (local.get $k) (i32.const 1)))
            (br $kl)))
          (call $o_byte (i32.const 0x0A))
          (br $al)))
      (local.set $vt (i32.load offset=8 (local.get $att)))
      (if (i32.eq (local.get $vt) (i32.const 6))
        (then
          (local.set $sh (i32.add (local.get $shr) (i32.shl (i32.load offset=28 (local.get $att)) (i32.const 3))))
          (if (i32.and (i32.ne (i32.load (local.get $sh)) (i32.const 0)) (i32.gt_u (local.get $r) (i32.const 0)))
            (then (call $attachment_array_shared (local.get $depth) (i32.load (local.get $att)) (i32.load offset=4 (local.get $att))
                                                 (i32.load offset=12 (local.get $att)) (i32.load offset=16 (local.get $att)) (i32.add (local.get $depth) (i32.const 2))
                                                 (i32.load (local.get $sh)) (i32.load offset=4 (local.get $sh))))
            (else (call $attachment_array (local.get $depth) (i32.load (local.get $att)) (i32.load offset=4 (local.get $att))
                                          (i32.load offset=12 (local.get $att)) (i32.load offset=16 (local.get $att)) (i32.add (local.get $depth) (i32.const 2)))))
          (if (global.get $err) (then (return)))
          (br $al)))
      (if (i32.eq (local.get $vt) (i32.const 7))
        (then
          (local.set $km (call $keyed_eligible (i32.load offset=12 (local.get $att)) (i32.load offset=16 (local.get $att))))
          (if (global.get $err) (then (return)))
          ;; keyed_eligible may grow STK_MISC only; STK_ROW is untouched
          (local.set $att (i32.add (call $stack_base (global.get $STK_ROW)) (i32.add (local.get $amark) (i32.shl (i32.sub (local.get $an) (i32.const 1)) (i32.const 5)))))
          (if (local.get $km)
            (then (call $keyed_map (local.get $depth) (i32.const 2) (i32.load (local.get $att)) (i32.load offset=4 (local.get $att)) (i32.const 0)
                                   (i32.load offset=12 (local.get $att)) (i32.load offset=16 (local.get $att)) (local.get $km) (i32.add (local.get $depth) (i32.const 2))))
            (else
              (call $o_indent (local.get $depth))
              (call $o_byte (i32.const 0x2E))
              (call $o_key (i32.load (local.get $att)) (i32.load offset=4 (local.get $att)))
              (call $o_bytes (global.get $S_EMPTYOBJ) (i32.const 4))
              (call $enc_object (i32.load offset=12 (local.get $att)) (i32.load offset=16 (local.get $att)) (i32.add (local.get $depth) (i32.const 2)))))
          (if (global.get $err) (then (return)))
          (br $al)))
      (call $o_indent (local.get $depth))
      (call $o_byte (i32.const 0x2E))
      (call $o_key (i32.load (local.get $att)) (i32.load offset=4 (local.get $att)))
      (call $o_bytes (global.get $S_SPEQ) (i32.const 2))
      (call $o_scalar_at (i32.add (local.get $att) (i32.const 8)))
      (call $o_byte (i32.const 0x0A))
      (br $al)))
    (call $stack_truncate (global.get $STK_ROW) (local.get $amark))
    (if (global.get $err) (then (return)))
    (local.set $r (i32.add (local.get $r) (i32.const 1)))
    (br $rl))))

;; ---------------------------------------------------------------------------
;; Encoding export
;; ---------------------------------------------------------------------------

;; JSON value -> generic-profile GCF. flags bit 0: no_flatten; bit 1: JS-host numbers.

;; Optional features of this module (the Zig build does not export this):
;; bit 0: gcf_encode_graph_cols, bit 1: gcf_encode flags bit 1.
(func (export "gcf_features") (result i32) (i32.const 3))
(func (export "gcf_encode") (param $len i32) (param $flags i32) (result i32)
  (local $vt i32) (local $va i32) (local $vb i64)
  (global.set $no_flatten (i32.and (local.get $flags) (i32.const 1)))
  ;; bit 1: the JSON came from JSON.stringify on a JS value, so an integer
  ;; token of magnitude >= 2^53 is a double (WAT module; see gcf_features)
  (global.set $jhost (i32.ne (i32.and (local.get $flags) (i32.const 2)) (i32.const 0)))
  (call $parse_json (global.get $in_ptr) (local.get $len) (i32.const 1))
  (global.set $jhost (i32.const 0))
  (local.set $vb) (local.set $va) (local.set $vt)
  (if (global.get $err) (then (return (global.get $err))))
  (call $w_begin (i32.add (local.get $len) (i32.const 64)))
  (call $enc_root (local.get $vt) (local.get $va) (local.get $vb))
  (call $w_sync)
  ;; the largeInt flag describes decoder output only
  (global.set $unsafe_ints (i32.const 0))
  (if (global.get $err) (then (return (global.get $err))))
  (call $out_finish)
  (i32.const 0))
