;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 felixdrp
;;
;; 02_simd.wat — 128-bit SIMD byte scanners.
;;
;; Every scanner processes 16 bytes per step: i8x16.eq against splatted
;; targets, i8x16.bitmask packs one bit per lane, i32.ctz gives the offset of
;; the first hit. The final partial block (< 16 bytes) is scanned byte by
;; byte, so nothing is ever read past ptr + len.

;; First index >= `start` where s[i] == c, or -1.
(func $find_byte (param $s i32) (param $len i32) (param $start i32) (param $c i32) (result i32)
  (local $i i32) (local $m i32) (local $vc v128)
  (local.set $vc (i8x16.splat (local.get $c)))
  (local.set $i (local.get $start))
  (block $tail
    (loop $vec
      (br_if $tail (i32.gt_u (i32.add (local.get $i) (i32.const 16)) (local.get $len)))
      (local.set $m (i8x16.bitmask (i8x16.eq (v128.load (i32.add (local.get $s) (local.get $i))) (local.get $vc))))
      (if (local.get $m) (then (return (i32.add (local.get $i) (i32.ctz (local.get $m))))))
      (local.set $i (i32.add (local.get $i) (i32.const 16)))
      (br $vec)))
  (block $done
    (loop $byte
      (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
      (if (i32.eq (i32.load8_u (i32.add (local.get $s) (local.get $i))) (local.get $c)) (then (return (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $byte)))
  (i32.const -1))

;; First index >= `start` where s[i] is c1 or c2, or -1.
(func $find_any2 (param $s i32) (param $len i32) (param $start i32) (param $c1 i32) (param $c2 i32) (result i32)
  (local $i i32) (local $m i32) (local $b i32) (local $v v128) (local $v1 v128) (local $v2 v128)
  (local.set $v1 (i8x16.splat (local.get $c1)))
  (local.set $v2 (i8x16.splat (local.get $c2)))
  (local.set $i (local.get $start))
  (block $tail
    (loop $vec
      (br_if $tail (i32.gt_u (i32.add (local.get $i) (i32.const 16)) (local.get $len)))
      (local.set $v (v128.load (i32.add (local.get $s) (local.get $i))))
      (local.set $m (i8x16.bitmask (v128.or (i8x16.eq (local.get $v) (local.get $v1)) (i8x16.eq (local.get $v) (local.get $v2)))))
      (if (local.get $m) (then (return (i32.add (local.get $i) (i32.ctz (local.get $m))))))
      (local.set $i (i32.add (local.get $i) (i32.const 16)))
      (br $vec)))
  (block $done
    (loop $byte
      (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
      (local.set $b (i32.load8_u (i32.add (local.get $s) (local.get $i))))
      (if (i32.or (i32.eq (local.get $b) (local.get $c1)) (i32.eq (local.get $b) (local.get $c2))) (then (return (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $byte)))
  (i32.const -1))

;; First index >= `start` where s[i] is c1, c2 or c3, or -1.
(func $find_any3 (param $s i32) (param $len i32) (param $start i32) (param $c1 i32) (param $c2 i32) (param $c3 i32) (result i32)
  (local $i i32) (local $m i32) (local $b i32) (local $v v128) (local $v1 v128) (local $v2 v128) (local $v3 v128)
  (local.set $v1 (i8x16.splat (local.get $c1)))
  (local.set $v2 (i8x16.splat (local.get $c2)))
  (local.set $v3 (i8x16.splat (local.get $c3)))
  (local.set $i (local.get $start))
  (block $tail
    (loop $vec
      (br_if $tail (i32.gt_u (i32.add (local.get $i) (i32.const 16)) (local.get $len)))
      (local.set $v (v128.load (i32.add (local.get $s) (local.get $i))))
      (local.set $m (i8x16.bitmask
        (v128.or (v128.or (i8x16.eq (local.get $v) (local.get $v1)) (i8x16.eq (local.get $v) (local.get $v2)))
                 (i8x16.eq (local.get $v) (local.get $v3)))))
      (if (local.get $m) (then (return (i32.add (local.get $i) (i32.ctz (local.get $m))))))
      (local.set $i (i32.add (local.get $i) (i32.const 16)))
      (br $vec)))
  (block $done
    (loop $byte
      (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
      (local.set $b (i32.load8_u (i32.add (local.get $s) (local.get $i))))
      (if (i32.or (i32.or (i32.eq (local.get $b) (local.get $c1)) (i32.eq (local.get $b) (local.get $c2)))
                  (i32.eq (local.get $b) (local.get $c3)))
        (then (return (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $byte)))
  (i32.const -1))

;; Number of bytes equal to c (popcnt over block masks).
(func $count_byte (param $s i32) (param $len i32) (param $c i32) (result i32)
  (local $i i32) (local $n i32) (local $vc v128)
  (local.set $vc (i8x16.splat (local.get $c)))
  (block $tail
    (loop $vec
      (br_if $tail (i32.gt_u (i32.add (local.get $i) (i32.const 16)) (local.get $len)))
      (local.set $n (i32.add (local.get $n)
        (i32.popcnt (i8x16.bitmask (i8x16.eq (v128.load (i32.add (local.get $s) (local.get $i))) (local.get $vc))))))
      (local.set $i (i32.add (local.get $i) (i32.const 16)))
      (br $vec)))
  (block $done
    (loop $byte
      (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
      (if (i32.eq (i32.load8_u (i32.add (local.get $s) (local.get $i))) (local.get $c))
        (then (local.set $n (i32.add (local.get $n) (i32.const 1)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $byte)))
  (local.get $n))

;; First index of a byte that is '"', '\' or < 0x20, or -1 (string escaping).
(func $find_escape (param $s i32) (param $len i32) (param $start i32) (result i32)
  (local $i i32) (local $m i32) (local $b i32) (local $v v128)
  (local.set $i (local.get $start))
  (block $tail
    (loop $vec
      (br_if $tail (i32.gt_u (i32.add (local.get $i) (i32.const 16)) (local.get $len)))
      (local.set $v (v128.load (i32.add (local.get $s) (local.get $i))))
      (local.set $m (i8x16.bitmask
        (v128.or (v128.or (i8x16.eq (local.get $v) (i8x16.splat (i32.const 0x22)))
                          (i8x16.eq (local.get $v) (i8x16.splat (i32.const 0x5c))))
                 (i8x16.lt_u (local.get $v) (i8x16.splat (i32.const 0x20))))))
      (if (local.get $m) (then (return (i32.add (local.get $i) (i32.ctz (local.get $m))))))
      (local.set $i (i32.add (local.get $i) (i32.const 16)))
      (br $vec)))
  (block $done
    (loop $byte
      (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
      (local.set $b (i32.load8_u (i32.add (local.get $s) (local.get $i))))
      (if (i32.or (i32.or (i32.eq (local.get $b) (i32.const 0x22)) (i32.eq (local.get $b) (i32.const 0x5c)))
                  (i32.lt_u (local.get $b) (i32.const 0x20)))
        (then (return (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $byte)))
  (i32.const -1))

;; 1 when [s, s+len) contains '\' or a byte < 0x20 (slow path for strings).
(func $has_backslash_or_control (param $s i32) (param $len i32) (result i32)
  (local $i i32) (local $b i32) (local $v v128)
  (block $tail
    (loop $vec
      (br_if $tail (i32.gt_u (i32.add (local.get $i) (i32.const 16)) (local.get $len)))
      (local.set $v (v128.load (i32.add (local.get $s) (local.get $i))))
      (if (v128.any_true (v128.or (i8x16.eq (local.get $v) (i8x16.splat (i32.const 0x5c)))
                                  (i8x16.lt_u (local.get $v) (i8x16.splat (i32.const 0x20)))))
        (then (return (i32.const 1))))
      (local.set $i (i32.add (local.get $i) (i32.const 16)))
      (br $vec)))
  (block $done
    (loop $byte
      (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
      (local.set $b (i32.load8_u (i32.add (local.get $s) (local.get $i))))
      (if (i32.or (i32.eq (local.get $b) (i32.const 0x5c)) (i32.lt_u (local.get $b) (i32.const 0x20)))
        (then (return (i32.const 1))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $byte)))
  (i32.const 0))

;; Byte equality of two strings (8 bytes per step, like gcf.zig `eql`).
(func $str_eq (param $a i32) (param $alen i32) (param $b i32) (param $blen i32) (result i32)
  (local $i i32)
  (if (i32.ne (local.get $alen) (local.get $blen)) (then (return (i32.const 0))))
  (if (i32.eq (local.get $a) (local.get $b)) (then (return (i32.const 1))))
  (block $tail
    (loop $words
      (br_if $tail (i32.gt_u (i32.add (local.get $i) (i32.const 8)) (local.get $alen)))
      (if (i64.ne (i64.load (i32.add (local.get $a) (local.get $i))) (i64.load (i32.add (local.get $b) (local.get $i))))
        (then (return (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 8)))
      (br $words)))
  (block $done
    (loop $bytes
      (br_if $done (i32.ge_u (local.get $i) (local.get $alen)))
      (if (i32.ne (i32.load8_u (i32.add (local.get $a) (local.get $i))) (i32.load8_u (i32.add (local.get $b) (local.get $i))))
        (then (return (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $bytes)))
  (i32.const 1))

;; Does the string start with the given prefix?
(func $starts_with (param $s i32) (param $len i32) (param $p i32) (param $plen i32) (result i32)
  (if (i32.lt_u (local.get $len) (local.get $plen)) (then (return (i32.const 0))))
  (call $str_eq (local.get $s) (local.get $plen) (local.get $p) (local.get $plen)))

;; Unsigned byte-order comparison: -1, 0, 1.
(func $str_cmp (param $a i32) (param $alen i32) (param $b i32) (param $blen i32) (result i32)
  (local $i i32) (local $n i32) (local $x i32) (local $y i32)
  (local.set $n (select (local.get $alen) (local.get $blen) (i32.lt_u (local.get $alen) (local.get $blen))))
  (block $done
    (loop $bytes
      (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $x (i32.load8_u (i32.add (local.get $a) (local.get $i))))
      (local.set $y (i32.load8_u (i32.add (local.get $b) (local.get $i))))
      (if (i32.ne (local.get $x) (local.get $y))
        (then (return (select (i32.const -1) (i32.const 1) (i32.lt_u (local.get $x) (local.get $y))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $bytes)))
  (if (i32.lt_u (local.get $alen) (local.get $blen)) (then (return (i32.const -1))))
  (if (i32.gt_u (local.get $alen) (local.get $blen)) (then (return (i32.const 1))))
  (i32.const 0))
