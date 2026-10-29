;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 felixdrp
;;
;; 04_numbers.wat — numbers: JSON grammar, exact int64, decimal -> double
;; (correctly rounded) and double -> shortest decimal (Ryu), plus the
;; canonical GCF number format (SPEC §2.3.1).
;;
;;   decimal -> double: Clinger's fast path (<= 15 digits, |e| <= 22: one
;;     exact IEEE operation), then Eisel-Lemire with the 128-bit powers of ten
;;     table, then an exact big-integer comparison against the midpoints of
;;     neighbouring doubles for the rare ambiguous cases and > 19 digits.
;;   double -> shortest decimal: Ryu (Adams, PLDI 2018), table-driven.
;;   wasm has no 64x64->128 multiply, so $umul128 builds it from four 32-bit
;;   products.

(global $TMP i32 (i32.const 0x7A00))   ;; 64-byte scratch for digit formatting

;; ---------------------------------------------------------------------------
;; 128-bit helpers
;; ---------------------------------------------------------------------------

;; Full 64x64 -> 128-bit product: returns (lo, hi).
(func $umul128 (param $a i64) (param $b i64) (result i64 i64)
  (local $a0 i64) (local $a1 i64) (local $b0 i64) (local $b1 i64)
  (local $p00 i64) (local $p01 i64) (local $p10 i64) (local $p11 i64) (local $mid i64)
  (local.set $a0 (i64.and (local.get $a) (i64.const 0xFFFFFFFF)))
  (local.set $a1 (i64.shr_u (local.get $a) (i64.const 32)))
  (local.set $b0 (i64.and (local.get $b) (i64.const 0xFFFFFFFF)))
  (local.set $b1 (i64.shr_u (local.get $b) (i64.const 32)))
  (local.set $p00 (i64.mul (local.get $a0) (local.get $b0)))
  (local.set $p01 (i64.mul (local.get $a0) (local.get $b1)))
  (local.set $p10 (i64.mul (local.get $a1) (local.get $b0)))
  (local.set $p11 (i64.mul (local.get $a1) (local.get $b1)))
  ;; mid = (p00 >> 32) + lo32(p01) + lo32(p10): at most 34 bits, no overflow
  (local.set $mid (i64.add (i64.add (i64.shr_u (local.get $p00) (i64.const 32))
                                    (i64.and (local.get $p01) (i64.const 0xFFFFFFFF)))
                           (i64.and (local.get $p10) (i64.const 0xFFFFFFFF))))
  (i64.or (i64.and (local.get $p00) (i64.const 0xFFFFFFFF)) (i64.shl (local.get $mid) (i64.const 32)))
  (i64.add (i64.add (i64.add (local.get $p11) (i64.shr_u (local.get $p01) (i64.const 32)))
                    (i64.shr_u (local.get $p10) (i64.const 32)))
           (i64.shr_u (local.get $mid) (i64.const 32))))

;; High 64 bits of a 64x64 product.
(func $umulh (param $a i64) (param $b i64) (result i64)
  (local $hi i64)
  (call $umul128 (local.get $a) (local.get $b))
  (local.set $hi) (drop)
  (local.get $hi))

;; Divisions by constants as multiply-high (Ryu's d2s_intrinsics.h).
(func $div5 (param $x i64) (result i64) (i64.shr_u (call $umulh (local.get $x) (i64.const 0xCCCCCCCCCCCCCCCD)) (i64.const 2)))
(func $div10 (param $x i64) (result i64) (i64.shr_u (call $umulh (local.get $x) (i64.const 0xCCCCCCCCCCCCCCCD)) (i64.const 3)))
(func $div100 (param $x i64) (result i64)
  (i64.shr_u (call $umulh (i64.shr_u (local.get $x) (i64.const 2)) (i64.const 0x28F5C28F5C28F5C3)) (i64.const 2)))

;; ---------------------------------------------------------------------------
;; JSON number grammar and exact int64
;; ---------------------------------------------------------------------------

;; 0 = not a number, 1 = integer literal, 2 = fraction/exponent (double).
;; number = [ "-" ] ( "0" / 1-9 *DIGIT ) [ "." 1*DIGIT ] [ ("e"/"E") ["+"/"-"] 1*DIGIT ]
(func $number_kind (param $s i32) (param $len i32) (result i32)
  (local $i i32) (local $c i32) (local $kind i32) (local $d0 i32)
  (if (i32.eqz (local.get $len)) (then (return (i32.const 0))))
  (if (i32.eq (i32.load8_u (local.get $s)) (i32.const 0x2D)) (then (local.set $i (i32.const 1))))  ;; '-'
  (if (i32.ge_u (local.get $i) (local.get $len)) (then (return (i32.const 0))))
  (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
  (if (i32.eq (local.get $c) (i32.const 0x30))
    (then (local.set $i (i32.add (local.get $i) (i32.const 1))))
    (else
      (if (i32.or (i32.lt_u (local.get $c) (i32.const 0x31)) (i32.gt_u (local.get $c) (i32.const 0x39))) (then (return (i32.const 0))))
      (block $d (loop $l
        (br_if $d (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (br_if $d (i32.gt_u (i32.sub (local.get $c) (i32.const 0x30)) (i32.const 9)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))))
  (local.set $kind (i32.const 1))
  (if (i32.lt_u (local.get $i) (local.get $len))
    (then (if (i32.eq (i32.load8_u (i32.add (local.get $s) (local.get $i))) (i32.const 0x2E))  ;; '.'
      (then
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (local.set $d0 (local.get $i))
        (block $d (loop $l
          (br_if $d (i32.ge_u (local.get $i) (local.get $len)))
          (br_if $d (i32.gt_u (i32.sub (i32.load8_u (i32.add (local.get $s) (local.get $i))) (i32.const 0x30)) (i32.const 9)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $l)))
        (if (i32.eq (local.get $i) (local.get $d0)) (then (return (i32.const 0))))
        (local.set $kind (i32.const 2))))))
  (if (i32.lt_u (local.get $i) (local.get $len))
    (then
      (local.set $c (i32.or (i32.load8_u (i32.add (local.get $s) (local.get $i))) (i32.const 0x20)))  ;; lower-case
      (if (i32.eq (local.get $c) (i32.const 0x65))  ;; 'e'
        (then
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (if (i32.lt_u (local.get $i) (local.get $len))
            (then
              (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
              (if (i32.or (i32.eq (local.get $c) (i32.const 0x2B)) (i32.eq (local.get $c) (i32.const 0x2D)))
                (then (local.set $i (i32.add (local.get $i) (i32.const 1)))))))
          (local.set $d0 (local.get $i))
          (block $d (loop $l
            (br_if $d (i32.ge_u (local.get $i) (local.get $len)))
            (br_if $d (i32.gt_u (i32.sub (i32.load8_u (i32.add (local.get $s) (local.get $i))) (i32.const 0x30)) (i32.const 9)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $l)))
          (if (i32.eq (local.get $i) (local.get $d0)) (then (return (i32.const 0))))
          (local.set $kind (i32.const 2))))))
  (select (local.get $kind) (i32.const 0) (i32.eq (local.get $i) (local.get $len))))

;; Integer literal -> exact int64; out_of_range outside [-2^63, 2^63-1]
;; (SPEC §2.3.2: the closed interval, not the magnitude).
(func $parse_int64 (param $s i32) (param $len i32) (param $line i32) (result i64)
  (local $i i32) (local $neg i32) (local $mag i64)
  (if (i32.eq (i32.load8_u (local.get $s)) (i32.const 0x2D)) (then (local.set $neg (i32.const 1)) (local.set $i (i32.const 1))))
  ;; at most 19 digits can be in range (no leading zeros in the grammar)
  (if (i32.gt_u (i32.sub (local.get $len) (local.get $i)) (i32.const 19))
    (then (call $fail (i32.const 14) (local.get $line)) (return (i64.const 0))))
  (block $d (loop $l
    (br_if $d (i32.ge_u (local.get $i) (local.get $len)))
    (local.set $mag (i64.add (i64.mul (local.get $mag) (i64.const 10))
                             (i64.extend_i32_u (i32.sub (i32.load8_u (i32.add (local.get $s) (local.get $i))) (i32.const 0x30)))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (if (local.get $neg)
    (then
      (if (i64.gt_u (local.get $mag) (i64.const 0x8000000000000000))
        (then (call $fail (i32.const 14) (local.get $line)) (return (i64.const 0))))
      (return (i64.sub (i64.const 0) (local.get $mag)))))
  (if (i64.gt_u (local.get $mag) (i64.const 0x7FFFFFFFFFFFFFFF))
    (then (call $fail (i32.const 14) (local.get $line)) (return (i64.const 0))))
  (local.get $mag))

;; ---------------------------------------------------------------------------
;; decimal -> double
;; ---------------------------------------------------------------------------

;; Eisel-Lemire (Go strconv eiselLemire64). Returns (bits, ok). `man` != 0.
;; When ok = 0 the bits are still a candidate within one ulp (or garbage at
;; the exponent extremes), used to seed the exact fallback.
(func $eisel_lemire (param $man i64) (param $e10 i32) (result i64 i32)
  (local $clz i64) (local $exp2 i64) (local $hi i64) (local $lo i64) (local $yhi i64) (local $ylo i64)
  (local $mlo i64) (local $mhi i64) (local $msb i64) (local $ret i64) (local $tab i32) (local $ok i32)
  (if (i32.or (i32.lt_s (local.get $e10) (i32.const -348)) (i32.gt_s (local.get $e10) (i32.const 347)))
    (then (return (i64.const 0) (i32.const 0))))
  (local.set $tab (i32.add (i32.const 0x4C00) (i32.shl (i32.add (local.get $e10) (i32.const 348)) (i32.const 4))))
  (local.set $clz (i64.clz (local.get $man)))
  (local.set $man (i64.shl (local.get $man) (local.get $clz)))
  ;; exp2 = (217706 * e10 >> 16) + 64 + 1023 - clz
  (local.set $exp2 (i64.sub (i64.extend_i32_s (i32.add (i32.shr_s (i32.mul (local.get $e10) (i32.const 217706)) (i32.const 16))
                                                       (i32.const 1087)))
                            (local.get $clz)))
  (call $umul128 (local.get $man) (i64.load offset=8 (local.get $tab)))
  (local.set $hi) (local.set $lo)
  (local.set $ok (i32.const 1))
  ;; wider approximation when the low bits are all ones
  (if (i32.and (i64.eq (i64.and (local.get $hi) (i64.const 0x1FF)) (i64.const 0x1FF))
               (i64.lt_u (i64.add (local.get $lo) (local.get $man)) (local.get $man)))
    (then
      (call $umul128 (local.get $man) (i64.load (local.get $tab)))
      (local.set $yhi) (local.set $ylo)
      (local.set $mhi (local.get $hi))
      (local.set $mlo (i64.add (local.get $lo) (local.get $yhi)))
      (if (i64.lt_u (local.get $mlo) (local.get $lo)) (then (local.set $mhi (i64.add (local.get $mhi) (i64.const 1)))))
      (if (i32.and (i32.and (i64.eq (i64.and (local.get $mhi) (i64.const 0x1FF)) (i64.const 0x1FF))
                            (i64.eq (i64.add (local.get $mlo) (i64.const 1)) (i64.const 0)))
                   (i64.lt_u (i64.add (local.get $ylo) (local.get $man)) (local.get $man)))
        (then (local.set $ok (i32.const 0))))
      (local.set $hi (local.get $mhi))
      (local.set $lo (local.get $mlo))))
  ;; shift to 54 bits
  (local.set $msb (i64.shr_u (local.get $hi) (i64.const 63)))
  (local.set $ret (i64.shr_u (local.get $hi) (i64.add (local.get $msb) (i64.const 9))))
  (local.set $exp2 (i64.sub (local.get $exp2) (i64.xor (local.get $msb) (i64.const 1))))
  ;; half-way ambiguity
  (if (i32.and (i32.and (i64.eqz (local.get $lo)) (i64.eqz (i64.and (local.get $hi) (i64.const 0x1FF))))
               (i64.eq (i64.and (local.get $ret) (i64.const 3)) (i64.const 1)))
    (then (local.set $ok (i32.const 0))))
  ;; 54 -> 53 bits, round half up (ties handled by the ambiguity check)
  (local.set $ret (i64.shr_u (i64.add (local.get $ret) (i64.and (local.get $ret) (i64.const 1))) (i64.const 1)))
  (if (i64.ne (i64.shr_u (local.get $ret) (i64.const 53)) (i64.const 0))
    (then (local.set $ret (i64.shr_u (local.get $ret) (i64.const 1)))
          (local.set $exp2 (i64.add (local.get $exp2) (i64.const 1)))))
  ;; subnormal or infinite: not handled here
  (if (i64.ge_u (i64.sub (local.get $exp2) (i64.const 1)) (i64.const 0x7FE))
    (then (return (i64.const 0) (i32.const 0))))
  (i64.or (i64.shl (local.get $exp2) (i64.const 52)) (i64.and (local.get $ret) (i64.const 0x000FFFFFFFFFFFFF)))
  (local.get $ok))

;; ---- exact fallback: big integers (little-endian u32 limbs in the arena) ----
;; A bignum is (ptr, n): n limbs at ptr. Buffers are sized by the caller.

;; x = x * m + add (in place), returns new limb count. m, add < 2^32.
(func $big_muladd (param $p i32) (param $n i32) (param $m i32) (param $add i32) (result i32)
  (local $i i32) (local $carry i64) (local $t i64)
  (local.set $carry (i64.extend_i32_u (local.get $add)))
  (block $d (loop $l
    (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $t (i64.add (i64.mul (i64.load32_u (i32.add (local.get $p) (i32.shl (local.get $i) (i32.const 2))))
                                    (i64.extend_i32_u (local.get $m)))
                           (local.get $carry)))
    (i64.store32 (i32.add (local.get $p) (i32.shl (local.get $i) (i32.const 2))) (local.get $t))
    (local.set $carry (i64.shr_u (local.get $t) (i64.const 32)))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (if (i64.ne (local.get $carry) (i64.const 0))
    (then (i64.store32 (i32.add (local.get $p) (i32.shl (local.get $n) (i32.const 2))) (local.get $carry))
          (local.set $n (i32.add (local.get $n) (i32.const 1)))))
  (local.get $n))

;; x = x * 10^k
(func $big_mul_pow10 (param $p i32) (param $n i32) (param $k i32) (result i32)
  (block $d (loop $l
    (br_if $d (i32.lt_s (local.get $k) (i32.const 9)))
    (local.set $n (call $big_muladd (local.get $p) (local.get $n) (i32.const 1000000000) (i32.const 0)))
    (local.set $k (i32.sub (local.get $k) (i32.const 9)))
    (br $l)))
  (block $d2 (loop $l2
    (br_if $d2 (i32.le_s (local.get $k) (i32.const 0)))
    (local.set $n (call $big_muladd (local.get $p) (local.get $n) (i32.const 10) (i32.const 0)))
    (local.set $k (i32.sub (local.get $k) (i32.const 1)))
    (br $l2)))
  (local.get $n))

;; x = x << bits
(func $big_shl (param $p i32) (param $n i32) (param $bits i32) (result i32)
  (local $words i32) (local $sh i32) (local $i i32) (local $cur i64) (local $prev i64)
  (local.set $words (i32.shr_u (local.get $bits) (i32.const 5)))
  (local.set $sh (i32.and (local.get $bits) (i32.const 31)))
  (if (local.get $sh)
    (then
      ;; bit shift within limbs, from the top down
      (i32.store (i32.add (local.get $p) (i32.shl (local.get $n) (i32.const 2))) (i32.const 0))
      (local.set $i (local.get $n))
      (block $d (loop $l
        (br_if $d (i32.eqz (local.get $i)))
        (local.set $cur (i64.load32_u (i32.add (local.get $p) (i32.shl (i32.sub (local.get $i) (i32.const 1)) (i32.const 2)))))
        (local.set $prev (i64.load32_u (i32.add (local.get $p) (i32.shl (local.get $i) (i32.const 2)))))
        (i64.store32 (i32.add (local.get $p) (i32.shl (local.get $i) (i32.const 2)))
          (i64.or (i64.shl (local.get $prev) (i64.extend_i32_u (local.get $sh)))
                  (i64.shr_u (local.get $cur) (i64.extend_i32_u (i32.sub (i32.const 32) (local.get $sh))))))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (br $l)))
      (i32.store (local.get $p) (i32.shl (i32.load (local.get $p)) (local.get $sh)))
      (if (i32.load (i32.add (local.get $p) (i32.shl (local.get $n) (i32.const 2))))
        (then (local.set $n (i32.add (local.get $n) (i32.const 1)))))))
  (if (local.get $words)
    (then
      (memory.copy (i32.add (local.get $p) (i32.shl (local.get $words) (i32.const 2))) (local.get $p) (i32.shl (local.get $n) (i32.const 2)))
      (memory.fill (local.get $p) (i32.const 0) (i32.shl (local.get $words) (i32.const 2)))
      (local.set $n (i32.add (local.get $n) (local.get $words)))))
  (local.get $n))

;; Compare two bignums (leading zero limbs allowed): -1, 0, 1.
(func $big_cmp (param $a i32) (param $an i32) (param $b i32) (param $bn i32) (result i32)
  (local $i i32) (local $x i32) (local $y i32)
  ;; strip leading zero limbs
  (block $d (loop $l (br_if $d (i32.eqz (local.get $an)))
    (br_if $d (i32.load (i32.add (local.get $a) (i32.shl (i32.sub (local.get $an) (i32.const 1)) (i32.const 2)))))
    (local.set $an (i32.sub (local.get $an) (i32.const 1))) (br $l)))
  (block $d (loop $l (br_if $d (i32.eqz (local.get $bn)))
    (br_if $d (i32.load (i32.add (local.get $b) (i32.shl (i32.sub (local.get $bn) (i32.const 1)) (i32.const 2)))))
    (local.set $bn (i32.sub (local.get $bn) (i32.const 1))) (br $l)))
  (if (i32.ne (local.get $an) (local.get $bn))
    (then (return (select (i32.const 1) (i32.const -1) (i32.gt_u (local.get $an) (local.get $bn))))))
  (local.set $i (local.get $an))
  (block $d (loop $l
    (br_if $d (i32.eqz (local.get $i)))
    (local.set $i (i32.sub (local.get $i) (i32.const 1)))
    (local.set $x (i32.load (i32.add (local.get $a) (i32.shl (local.get $i) (i32.const 2)))))
    (local.set $y (i32.load (i32.add (local.get $b) (i32.shl (local.get $i) (i32.const 2)))))
    (if (i32.ne (local.get $x) (local.get $y))
      (then (return (select (i32.const 1) (i32.const -1) (i32.gt_u (local.get $x) (local.get $y))))))
    (br $l)))
  (i32.const 0))

;; Integer mantissa and exponent of a finite positive double: x = m * 2^e.
(func $f64_split (param $bits i64) (result i64 i32)
  (local $ex i32)
  (local.set $ex (i32.wrap_i64 (i64.and (i64.shr_u (local.get $bits) (i64.const 52)) (i64.const 0x7FF))))
  (if (i32.eqz (local.get $ex))
    (then (return (i64.and (local.get $bits) (i64.const 0x000FFFFFFFFFFFFF)) (i32.const -1074))))
  (i64.or (i64.and (local.get $bits) (i64.const 0x000FFFFFFFFFFFFF)) (i64.const 0x0010000000000000))
  (i32.sub (local.get $ex) (i32.const 1075)))

;; Compare the decimal D = digits * 10^e10 with the midpoint of the adjacent
;; positive doubles a < b (b may be the virtual successor of the maximum).
;; `digits` is the significant-digit string (dot already removed).
(func $cmp_decimal_midpoint (param $ds i32) (param $dn i32) (param $e10 i32) (param $abits i64) (param $bbits i64) (result i32)
  (local $ma i64) (local $ea i32) (local $mb i64) (local $eb i32) (local $e i32) (local $k i64) (local $f i32)
  (local $limbs i32) (local $A i32) (local $An i32) (local $B i32) (local $Bn i32) (local $i i32) (local $chunk i32) (local $mul i32) (local $c i32)
  (call $f64_split (local.get $abits)) (local.set $ea) (local.set $ma)
  (if (i64.eq (local.get $bbits) (i64.const 0x7FF0000000000000))
    (then (local.set $mb (i64.const 0x0020000000000000)) (local.set $eb (i32.const 971)))
    (else (call $f64_split (local.get $bbits)) (local.set $eb) (local.set $mb)))
  ;; midpoint = (ma*2^(ea-e) + mb*2^(eb-e)) * 2^(e-1) = K * 2^f
  (local.set $e (select (local.get $ea) (local.get $eb) (i32.lt_s (local.get $ea) (local.get $eb))))
  (local.set $k (i64.add (i64.shl (local.get $ma) (i64.extend_i32_s (i32.sub (local.get $ea) (local.get $e))))
                         (i64.shl (local.get $mb) (i64.extend_i32_s (i32.sub (local.get $eb) (local.get $e))))))
  (local.set $f (i32.sub (local.get $e) (i32.const 1)))
  ;; Size both buffers generously: digits*log2(10) + |e10|*log2(10) + |f| bits.
  (local.set $limbs (i32.add (i32.shr_u (i32.mul (i32.add (i32.add (local.get $dn)
      (select (local.get $e10) (i32.sub (i32.const 0) (local.get $e10)) (i32.ge_s (local.get $e10) (i32.const 0))))
      (i32.const 40)) (i32.const 4)) (i32.const 5))
    (i32.add (i32.shr_u (select (local.get $f) (i32.sub (i32.const 0) (local.get $f)) (i32.ge_s (local.get $f) (i32.const 0))) (i32.const 5)) (i32.const 8))))
  (local.set $A (call $alloc (i32.shl (local.get $limbs) (i32.const 2))))
  (local.set $B (call $alloc (i32.shl (local.get $limbs) (i32.const 2))))
  (if (global.get $err) (then (return (i32.const 0))))
  (memory.fill (local.get $A) (i32.const 0) (i32.shl (local.get $limbs) (i32.const 2)))
  (memory.fill (local.get $B) (i32.const 0) (i32.shl (local.get $limbs) (i32.const 2)))
  ;; A = digits, 9 at a time
  (local.set $An (i32.const 0))
  (block $d (loop $l
    (br_if $d (i32.ge_u (local.get $i) (local.get $dn)))
    (local.set $chunk (i32.const 0)) (local.set $mul (i32.const 1))
    (block $cd (loop $cl
      (br_if $cd (i32.or (i32.ge_u (local.get $i) (local.get $dn)) (i32.eq (local.get $mul) (i32.const 1000000000))))
      (local.set $chunk (i32.add (i32.mul (local.get $chunk) (i32.const 10)) (i32.sub (i32.load8_u (i32.add (local.get $ds) (local.get $i))) (i32.const 0x30))))
      (local.set $mul (i32.mul (local.get $mul) (i32.const 10)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $cl)))
    (local.set $An (call $big_muladd (local.get $A) (local.get $An) (local.get $mul) (local.get $chunk)))
    (br $l)))
  ;; B = K
  (i64.store32 (local.get $B) (local.get $k))
  (i64.store32 offset=4 (local.get $B) (i64.shr_u (local.get $k) (i64.const 32)))
  (local.set $Bn (i32.const 2))
  ;; scale to integers: A = N * 10^max(e,0) * 2^max(-f,0); B = K * 2^max(f,0) * 10^max(-e,0)
  (if (i32.ge_s (local.get $e10) (i32.const 0))
    (then (local.set $An (call $big_mul_pow10 (local.get $A) (local.get $An) (local.get $e10))))
    (else (local.set $Bn (call $big_mul_pow10 (local.get $B) (local.get $Bn) (i32.sub (i32.const 0) (local.get $e10))))))
  (if (i32.ge_s (local.get $f) (i32.const 0))
    (then (local.set $Bn (call $big_shl (local.get $B) (local.get $Bn) (local.get $f))))
    (else (local.set $An (call $big_shl (local.get $A) (local.get $An) (i32.sub (i32.const 0) (local.get $f))))))
  (call $big_cmp (local.get $A) (local.get $An) (local.get $B) (local.get $Bn)))

;; Correctly rounded double for digits * 10^e10, starting from `bits`
;; (within a few ulps). Walks to the right neighbour by exact comparisons.
(func $refine_exact (param $ds i32) (param $dn i32) (param $e10 i32) (param $bits i64) (result i64)
  (local $iter i32) (local $c i32) (local $up i64) (local $down i64)
  (block $done
    (loop $l
      (br_if $done (i32.ge_u (local.get $iter) (i32.const 64)))
      (local.set $iter (i32.add (local.get $iter) (i32.const 1)))
      (br_if $done (i64.ge_u (local.get $bits) (i64.const 0x7FF0000000000000)))
      ;; compare with the midpoint to the successor
      (local.set $up (i64.add (local.get $bits) (i64.const 1)))
      (local.set $c (call $cmp_decimal_midpoint (local.get $ds) (local.get $dn) (local.get $e10) (local.get $bits) (local.get $up)))
      (if (global.get $err) (then (return (i64.const 0))))
      (if (i32.gt_s (local.get $c) (i32.const 0)) (then (local.set $bits (local.get $up)) (br $l)))
      (if (i32.eqz (local.get $c))
        (then (if (i64.ne (i64.and (local.get $bits) (i64.const 1)) (i64.const 0)) (then (local.set $bits (local.get $up))))
              (br $done)))
      ;; compare with the midpoint to the predecessor
      (br_if $done (i64.eqz (local.get $bits)))
      (local.set $down (i64.sub (local.get $bits) (i64.const 1)))
      (local.set $c (call $cmp_decimal_midpoint (local.get $ds) (local.get $dn) (local.get $e10) (local.get $down) (local.get $bits)))
      (if (global.get $err) (then (return (i64.const 0))))
      (if (i32.lt_s (local.get $c) (i32.const 0)) (then (local.set $bits (local.get $down)) (br $l)))
      (if (i32.eqz (local.get $c))
        (then (if (i64.ne (i64.and (local.get $bits) (i64.const 1)) (i64.const 0)) (then (local.set $bits (local.get $down))))))
      (br $done)))
  (local.get $bits))

;; Parse a token that matched the number grammar (kind 2) as a double.
;; Infinite results are out_of_range (SPEC §2.3.2: doubles only).
(func $parse_f64 (param $s i32) (param $len i32) (param $line i32) (result f64)
  (local $i i32) (local $neg i32) (local $c i32) (local $man i64) (local $nd i32) (local $e10 i32)
  (local $trunc i32) (local $seen_dot i32) (local $exp i32) (local $eneg i32) (local $edigits i32)
  (local $ds i32) (local $dn i32) (local $bits i64) (local $ok i32) (local $bits2 i64) (local $ok2 i32) (local $v f64) (local $top0 i32)
  (if (i32.eq (i32.load8_u (local.get $s)) (i32.const 0x2D)) (then (local.set $neg (i32.const 1)) (local.set $i (i32.const 1))))
  ;; Significant digits go to a scratch string (for the exact path) and the
  ;; first 19 into `man`; `e10` tracks the decimal exponent of `man`. The
  ;; scratch string is released at the end when nothing was allocated after
  ;; it (the exact path's big integers are), so floats leave no garbage.
  (local.set $top0 (global.get $arena_top))
  (local.set $ds (call $alloc (local.get $len)))
  (if (global.get $err) (then (return (f64.const 0))))
  (block $mant_done
    (loop $l
      (br_if $mant_done (i32.ge_u (local.get $i) (local.get $len)))
      (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
      (if (i32.eq (local.get $c) (i32.const 0x2E))
        (then (local.set $seen_dot (i32.const 1)) (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))
      (br_if $mant_done (i32.gt_u (i32.sub (local.get $c) (i32.const 0x30)) (i32.const 9)))
      (if (i32.and (i32.eqz (local.get $dn)) (i32.eq (local.get $c) (i32.const 0x30)))
        (then
          ;; leading zero: not significant
          (if (local.get $seen_dot) (then (local.set $e10 (i32.sub (local.get $e10) (i32.const 1))))))
        (else
          (i32.store8 (i32.add (local.get $ds) (local.get $dn)) (local.get $c))
          (local.set $dn (i32.add (local.get $dn) (i32.const 1)))
          (if (i32.le_u (local.get $dn) (i32.const 19))
            (then
              (local.set $man (i64.add (i64.mul (local.get $man) (i64.const 10)) (i64.extend_i32_u (i32.sub (local.get $c) (i32.const 0x30)))))
              (if (local.get $seen_dot) (then (local.set $e10 (i32.sub (local.get $e10) (i32.const 1))))))
            (else
              (if (i32.ne (local.get $c) (i32.const 0x30)) (then (local.set $trunc (i32.const 1))))
              (if (i32.eqz (local.get $seen_dot)) (then (local.set $e10 (i32.add (local.get $e10) (i32.const 1)))))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)))
  ;; exponent part
  (if (i32.lt_u (local.get $i) (local.get $len))
    (then
      (local.set $i (i32.add (local.get $i) (i32.const 1)))  ;; e / E
      (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
      (if (i32.eq (local.get $c) (i32.const 0x2D)) (then (local.set $eneg (i32.const 1))))
      (if (i32.or (i32.eq (local.get $c) (i32.const 0x2D)) (i32.eq (local.get $c) (i32.const 0x2B)))
        (then (local.set $i (i32.add (local.get $i) (i32.const 1)))))
      (block $ed (loop $el
        (br_if $ed (i32.ge_u (local.get $i) (local.get $len)))
        (if (i32.lt_u (local.get $exp) (i32.const 100000))  ;; clamp: far beyond any finite double
          (then (local.set $exp (i32.add (i32.mul (local.get $exp) (i32.const 10))
                                         (i32.sub (i32.load8_u (i32.add (local.get $s) (local.get $i))) (i32.const 0x30))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $el)))
      (local.set $e10 (i32.add (local.get $e10) (select (i32.sub (i32.const 0) (local.get $exp)) (local.get $exp) (local.get $eneg))))))
  ;; the digit string stands for digits * 10^(e10 - (dn - min(dn,19)) ... ) — rebase it
  ;; so that D = digits * 10^dexp exactly:
  (block $value
    (if (i64.eqz (local.get $man))
      (then (if (i32.eqz (local.get $trunc)) (then (local.set $v (f64.const 0)) (br $value)))))
    ;; overflow / underflow far outside the double range
    (if (i32.gt_s (i32.add (local.get $e10) (select (local.get $dn) (i32.const 19) (i32.lt_u (local.get $dn) (i32.const 19)))) (i32.const 310))
      (then (call $fail (i32.const 14) (local.get $line)) (return (f64.const 0))))
    (if (i32.lt_s (i32.add (local.get $e10) (i32.const 19)) (i32.const -380))
      (then (local.set $v (f64.const 0)) (br $value)))
    ;; Clinger: exact integer mantissa and exact power of ten
    (if (i32.and (i32.eqz (local.get $trunc))
                 (i32.and (i64.le_u (local.get $man) (i64.const 0x20000000000000))
                          (i32.le_u (i32.add (local.get $e10) (i32.const 22)) (i32.const 44))))
      (then
        (local.set $v (f64.convert_i64_u (local.get $man)))
        (if (i32.lt_s (local.get $e10) (i32.const 0))
          (then (local.set $v (f64.div (local.get $v) (f64.load (i32.add (i32.const 0x0200) (i32.shl (i32.sub (i32.const 0) (local.get $e10)) (i32.const 3)))))))
          (else (local.set $v (f64.mul (local.get $v) (f64.load (i32.add (i32.const 0x0200) (i32.shl (local.get $e10) (i32.const 3))))))))
        (br $value)))
    ;; Eisel-Lemire
    (call $eisel_lemire (local.get $man) (local.get $e10)) (local.set $ok) (local.set $bits)
    (if (i32.and (local.get $ok) (i32.eqz (local.get $trunc)))
      (then (local.set $v (f64.reinterpret_i64 (local.get $bits))) (br $value)))
    (if (i32.and (local.get $ok) (local.get $trunc))
      (then
        (call $eisel_lemire (i64.add (local.get $man) (i64.const 1)) (local.get $e10)) (local.set $ok2) (local.set $bits2)
        (if (i32.and (local.get $ok2) (i64.eq (local.get $bits) (local.get $bits2)))
          (then (local.set $v (f64.reinterpret_i64 (local.get $bits))) (br $value)))))
    ;; Exact path. Seed: the EL candidate, or a rough f64 estimate.
    (if (i64.eqz (local.get $bits))
      (then
        (local.set $v (f64.convert_i64_u (local.get $man)))
        (local.set $exp (local.get $e10))
        (block $sd (loop $sl (br_if $sd (i32.le_s (local.get $exp) (i32.const 0)))
          (local.set $v (f64.mul (local.get $v) (f64.const 10))) (local.set $exp (i32.sub (local.get $exp) (i32.const 1))) (br $sl)))
        (block $sd (loop $sl (br_if $sd (i32.ge_s (local.get $exp) (i32.const 0)))
          (local.set $v (f64.div (local.get $v) (f64.const 10))) (local.set $exp (i32.add (local.get $exp) (i32.const 1))) (br $sl)))
        (local.set $bits (i64.reinterpret_f64 (local.get $v)))))
    ;; digits * 10^(e10 - (dn - 19)) when truncated, else digits * 10^e10
    (local.set $exp (local.get $e10))
    (if (i32.gt_u (local.get $dn) (i32.const 19)) (then (local.set $exp (i32.sub (local.get $e10) (i32.sub (local.get $dn) (i32.const 19))))))
    (local.set $bits (call $refine_exact (local.get $ds) (local.get $dn) (local.get $exp) (local.get $bits)))
    (if (global.get $err) (then (return (f64.const 0))))
    (local.set $v (f64.reinterpret_i64 (local.get $bits))))
  (if (f64.eq (f64.abs (local.get $v)) (f64.const inf))
    (then (call $fail (i32.const 14) (local.get $line)) (return (f64.const 0))))
  (if (i32.eq (global.get $arena_top) (i32.add (local.get $ds) (local.get $len)))
    (then (global.set $arena_top (local.get $top0))))
  (select (f64.neg (local.get $v)) (local.get $v) (local.get $neg)))

;; ---------------------------------------------------------------------------
;; Digits out
;; ---------------------------------------------------------------------------

;; Write the decimal digits of v at TMP+44 backwards; returns (ptr, len).
(func $u64_digits (param $v i64) (result i32 i32)
  (local $p i32) (local $r i32)
  (local.set $p (i32.add (global.get $TMP) (i32.const 44)))
  ;; two digits per division ("00".."99" table at 0x0100)
  (block $d (loop $l
    (br_if $d (i64.lt_u (local.get $v) (i64.const 100)))
    (local.set $r (i32.wrap_i64 (i64.rem_u (local.get $v) (i64.const 100))))
    (local.set $v (i64.div_u (local.get $v) (i64.const 100)))
    (local.set $p (i32.sub (local.get $p) (i32.const 2)))
    (i32.store16 (local.get $p) (i32.load16_u (i32.add (i32.const 0x0100) (i32.shl (local.get $r) (i32.const 1)))))
    (br $l)))
  (if (i64.ge_u (local.get $v) (i64.const 10))
    (then
      (local.set $p (i32.sub (local.get $p) (i32.const 2)))
      (i32.store16 (local.get $p) (i32.load16_u (i32.add (i32.const 0x0100) (i32.shl (i32.wrap_i64 (local.get $v)) (i32.const 1))))))
    (else
      (local.set $p (i32.sub (local.get $p) (i32.const 1)))
      (i32.store8 (local.get $p) (i32.add (i32.wrap_i64 (local.get $v)) (i32.const 0x30)))))
  (local.get $p)
  (i32.sub (i32.add (global.get $TMP) (i32.const 44)) (local.get $p)))

(func $out_u64 (param $v i64)
  (call $u64_digits (local.get $v))
  (call $out_bytes))

;; Signed integer; also flags |v| > 2^53-1 for the JS host's largeInt policy.
(func $out_i64 (param $v i64)
  (if (i32.or (i64.gt_s (local.get $v) (i64.const 9007199254740991)) (i64.lt_s (local.get $v) (i64.const -9007199254740991)))
    (then (global.set $unsafe_ints (i32.const 1))))
  (if (i64.lt_s (local.get $v) (i64.const 0))
    (then (call $out_byte (i32.const 0x2D))
          ;; |v|, correct for -2^63 too (wraps to 2^63 as unsigned)
          (local.set $v (i64.sub (i64.const 0) (local.get $v)))))
  (call $out_u64 (local.get $v)))

;; ---------------------------------------------------------------------------
;; double -> shortest decimal (Ryu)
;; ---------------------------------------------------------------------------

(func $pow5bits (param $e i32) (result i32) (i32.add (i32.shr_u (i32.mul (local.get $e) (i32.const 1217359)) (i32.const 19)) (i32.const 1)))
(func $log10pow2 (param $e i32) (result i32) (i32.shr_u (i32.mul (local.get $e) (i32.const 78913)) (i32.const 18)))
(func $log10pow5 (param $e i32) (result i32) (i32.shr_u (i32.mul (local.get $e) (i32.const 732923)) (i32.const 20)))

(func $pow5factor (param $v i64) (result i32)
  (local $n i32) (local $q i64)
  (block $d (loop $l
    (local.set $q (call $div5 (local.get $v)))
    (br_if $d (i64.ne (i64.sub (local.get $v) (i64.mul (local.get $q) (i64.const 5))) (i64.const 0)))
    (local.set $v (local.get $q))
    (local.set $n (i32.add (local.get $n) (i32.const 1)))
    (br $l)))
  (local.get $n))

;; (m * table[128-bit at ptr]) >> j, with 64 < j < 128.
(func $mulshift64 (param $m i64) (param $tab i32) (param $j i32) (result i64)
  (local $lo1 i64) (local $hi1 i64) (local $hi0 i64) (local $sum i64) (local $d i64)
  (call $umul128 (local.get $m) (i64.load offset=8 (local.get $tab))) (local.set $hi1) (local.set $lo1)
  (call $umul128 (local.get $m) (i64.load (local.get $tab))) (local.set $hi0) (drop)
  (local.set $sum (i64.add (local.get $hi0) (local.get $lo1)))
  (if (i64.lt_u (local.get $sum) (local.get $hi0)) (then (local.set $hi1 (i64.add (local.get $hi1) (i64.const 1)))))
  (local.set $d (i64.extend_i32_u (i32.sub (local.get $j) (i32.const 64))))
  (i64.or (i64.shl (local.get $hi1) (i64.sub (i64.const 64) (local.get $d))) (i64.shr_u (local.get $sum) (local.get $d))))

;; Shortest decimal of a positive finite double: (mantissa, exponent10).
(func $ryu_d2d (param $bits i64) (result i64 i32)
  (local $ieee_m i64) (local $ieee_e i32) (local $e2 i32) (local $m2 i64) (local $even i32) (local $mv i64)
  (local $mmshift i64) (local $vr i64) (local $vp i64) (local $vm i64) (local $e10 i32) (local $q i32) (local $k i32)
  (local $i i32) (local $j i32) (local $tab i32) (local $vm_tz i32) (local $vr_tz i32) (local $removed i32)
  (local $last i32) (local $output i64) (local $vpd i64) (local $vmd i64) (local $vrd i64) (local $vrm i32) (local $vmm i32)
  (local $roundup i32)
  (local.set $ieee_m (i64.and (local.get $bits) (i64.const 0x000FFFFFFFFFFFFF)))
  (local.set $ieee_e (i32.wrap_i64 (i64.and (i64.shr_u (local.get $bits) (i64.const 52)) (i64.const 0x7FF))))
  (if (i32.eqz (local.get $ieee_e))
    (then (local.set $e2 (i32.const -1076)) (local.set $m2 (local.get $ieee_m)))   ;; 1 - 1023 - 52 - 2
    (else (local.set $e2 (i32.sub (local.get $ieee_e) (i32.const 1077)))         ;; e - 1023 - 52 - 2
          (local.set $m2 (i64.or (local.get $ieee_m) (i64.const 0x0010000000000000)))))
  (local.set $even (i64.eqz (i64.and (local.get $m2) (i64.const 1))))
  (local.set $mv (i64.shl (local.get $m2) (i64.const 2)))
  (local.set $mmshift (i64.extend_i32_u (i32.or (i64.ne (local.get $ieee_m) (i64.const 0)) (i32.le_u (local.get $ieee_e) (i32.const 1)))))
  (if (i32.ge_s (local.get $e2) (i32.const 0))
    (then
      (local.set $q (i32.sub (call $log10pow2 (local.get $e2)) (i32.gt_s (local.get $e2) (i32.const 3))))
      (local.set $e10 (local.get $q))
      (local.set $k (i32.add (i32.const 124) (call $pow5bits (local.get $q))))       ;; 125 + pow5bits(q) - 1
      (local.set $i (i32.add (i32.sub (local.get $q) (local.get $e2)) (local.get $k)))
      (local.set $tab (i32.add (i32.const 0x2000) (i32.shl (local.get $q) (i32.const 4))))
      (local.set $vr (call $mulshift64 (local.get $mv) (local.get $tab) (local.get $i)))
      (local.set $vp (call $mulshift64 (i64.add (local.get $mv) (i64.const 2)) (local.get $tab) (local.get $i)))
      (local.set $vm (call $mulshift64 (i64.sub (i64.sub (local.get $mv) (i64.const 1)) (local.get $mmshift)) (local.get $tab) (local.get $i)))
      (if (i32.le_u (local.get $q) (i32.const 21))
        (then
          (if (i64.eqz (i64.sub (local.get $mv) (i64.mul (call $div5 (local.get $mv)) (i64.const 5))))
            (then (local.set $vr_tz (i32.ge_u (call $pow5factor (local.get $mv)) (local.get $q))))
            (else (if (local.get $even)
              (then (local.set $vm_tz (i32.ge_u (call $pow5factor (i64.sub (i64.sub (local.get $mv) (i64.const 1)) (local.get $mmshift))) (local.get $q))))
              (else (local.set $vp (i64.sub (local.get $vp)
                      (i64.extend_i32_u (i32.ge_u (call $pow5factor (i64.add (local.get $mv) (i64.const 2))) (local.get $q))))))))))))
    (else
      (local.set $q (i32.sub (call $log10pow5 (i32.sub (i32.const 0) (local.get $e2))) (i32.gt_s (i32.sub (i32.const 0) (local.get $e2)) (i32.const 1))))
      (local.set $e10 (i32.add (local.get $q) (local.get $e2)))
      (local.set $i (i32.sub (i32.sub (i32.const 0) (local.get $e2)) (local.get $q)))
      (local.set $k (i32.sub (call $pow5bits (local.get $i)) (i32.const 125)))
      (local.set $j (i32.sub (local.get $q) (local.get $k)))
      (local.set $tab (i32.add (i32.const 0x3600) (i32.shl (local.get $i) (i32.const 4))))
      (local.set $vr (call $mulshift64 (local.get $mv) (local.get $tab) (local.get $j)))
      (local.set $vp (call $mulshift64 (i64.add (local.get $mv) (i64.const 2)) (local.get $tab) (local.get $j)))
      (local.set $vm (call $mulshift64 (i64.sub (i64.sub (local.get $mv) (i64.const 1)) (local.get $mmshift)) (local.get $tab) (local.get $j)))
      (if (i32.le_u (local.get $q) (i32.const 1))
        (then
          (local.set $vr_tz (i32.const 1))
          (if (local.get $even)
            (then (local.set $vm_tz (i64.eq (local.get $mmshift) (i64.const 1))))
            (else (local.set $vp (i64.sub (local.get $vp) (i64.const 1))))))
        (else (if (i32.lt_u (local.get $q) (i32.const 63))
          (then (local.set $vr_tz (i64.eqz (i64.and (local.get $mv)
                   (i64.sub (i64.shl (i64.const 1) (i64.extend_i32_u (local.get $q))) (i64.const 1)))))))))))
  (if (i32.or (local.get $vm_tz) (local.get $vr_tz))
    (then
      ;; general case (~0.7%)
      (block $d1 (loop $l1
        (local.set $vpd (call $div10 (local.get $vp)))
        (local.set $vmd (call $div10 (local.get $vm)))
        (br_if $d1 (i64.le_u (local.get $vpd) (local.get $vmd)))
        (local.set $vmm (i32.wrap_i64 (i64.sub (local.get $vm) (i64.mul (local.get $vmd) (i64.const 10)))))
        (local.set $vrd (call $div10 (local.get $vr)))
        (local.set $vrm (i32.wrap_i64 (i64.sub (local.get $vr) (i64.mul (local.get $vrd) (i64.const 10)))))
        (local.set $vm_tz (i32.and (local.get $vm_tz) (i32.eqz (local.get $vmm))))
        (local.set $vr_tz (i32.and (local.get $vr_tz) (i32.eqz (local.get $last))))
        (local.set $last (local.get $vrm))
        (local.set $vr (local.get $vrd)) (local.set $vp (local.get $vpd)) (local.set $vm (local.get $vmd))
        (local.set $removed (i32.add (local.get $removed) (i32.const 1)))
        (br $l1)))
      (if (local.get $vm_tz)
        (then (block $d2 (loop $l2
          (local.set $vmd (call $div10 (local.get $vm)))
          (br_if $d2 (i64.ne (i64.sub (local.get $vm) (i64.mul (local.get $vmd) (i64.const 10))) (i64.const 0)))
          (local.set $vpd (call $div10 (local.get $vp)))
          (local.set $vrd (call $div10 (local.get $vr)))
          (local.set $vrm (i32.wrap_i64 (i64.sub (local.get $vr) (i64.mul (local.get $vrd) (i64.const 10)))))
          (local.set $vr_tz (i32.and (local.get $vr_tz) (i32.eqz (local.get $last))))
          (local.set $last (local.get $vrm))
          (local.set $vr (local.get $vrd)) (local.set $vp (local.get $vpd)) (local.set $vm (local.get $vmd))
          (local.set $removed (i32.add (local.get $removed) (i32.const 1)))
          (br $l2)))))
      (if (i32.and (i32.and (local.get $vr_tz) (i32.eq (local.get $last) (i32.const 5)))
                   (i64.eqz (i64.and (local.get $vr) (i64.const 1))))
        (then (local.set $last (i32.const 4))))  ;; round to even on .5 exactly
      (local.set $output (i64.add (local.get $vr) (i64.extend_i32_u
        (i32.or (i32.and (i64.eq (local.get $vr) (local.get $vm))
                         (i32.or (i32.eqz (local.get $even)) (i32.eqz (local.get $vm_tz))))
                (i32.ge_u (local.get $last) (i32.const 5)))))))
    (else
      ;; common case (~99.3%): no trailing-zero bookkeeping
      (local.set $vpd (call $div100 (local.get $vp)))
      (local.set $vmd (call $div100 (local.get $vm)))
      (if (i64.gt_u (local.get $vpd) (local.get $vmd))
        (then
          (local.set $vrd (call $div100 (local.get $vr)))
          (local.set $roundup (i32.ge_u (i32.wrap_i64 (i64.sub (local.get $vr) (i64.mul (local.get $vrd) (i64.const 100)))) (i32.const 50)))
          (local.set $vr (local.get $vrd)) (local.set $vp (local.get $vpd)) (local.set $vm (local.get $vmd))
          (local.set $removed (i32.add (local.get $removed) (i32.const 2)))))
      (block $d3 (loop $l3
        (local.set $vpd (call $div10 (local.get $vp)))
        (local.set $vmd (call $div10 (local.get $vm)))
        (br_if $d3 (i64.le_u (local.get $vpd) (local.get $vmd)))
        (local.set $vrd (call $div10 (local.get $vr)))
        (local.set $roundup (i32.ge_u (i32.wrap_i64 (i64.sub (local.get $vr) (i64.mul (local.get $vrd) (i64.const 10)))) (i32.const 5)))
        (local.set $vr (local.get $vrd)) (local.set $vp (local.get $vpd)) (local.set $vm (local.get $vmd))
        (local.set $removed (i32.add (local.get $removed) (i32.const 1)))
        (br $l3)))
      (local.set $output (i64.add (local.get $vr) (i64.extend_i32_u (i32.or (i64.eq (local.get $vr) (local.get $vm)) (local.get $roundup)))))))
  (local.get $output)
  (i32.add (local.get $e10) (local.get $removed)))

;; ---------------------------------------------------------------------------
;; Canonical number output (SPEC §2.3.1; identical to gcf.zig formatDouble)
;; ---------------------------------------------------------------------------

;; Short-decimal fast path (same as gcf.zig shortDecimal): for 1e-6 <= av < 1e9
;; try k = 1..6 decimals and accept the first k with round(av*10^k)/10^k == av.
;; Below 1e9 one ulp is < 1.2e-7, so no other string with <= k decimals maps
;; to the same double: the result is exactly the shortest round-trip form.
;; Returns (k, integer part, fraction digits) with k = 0 when no k <= 6 fits.
(func $short_decimal (param $av f64) (result i32 i32 i32)
  (local $k i32) (local $scale f64) (local $c f64) (local $ip i32)
  (local.set $ip (i32.trunc_f64_u (f64.floor (local.get $av))))
  (local.set $k (i32.const 1))
  (block $done (loop $l
    (br_if $done (i32.gt_u (local.get $k) (i32.const 6)))
    (local.set $scale (f64.load (i32.add (i32.const 0x0200) (i32.shl (local.get $k) (i32.const 3)))))
    (local.set $c (f64.nearest (f64.mul (local.get $av) (local.get $scale))))
    (if (f64.eq (f64.div (local.get $c) (local.get $scale)) (local.get $av))
      (then (return (local.get $k) (local.get $ip)
        ;; c = ip * 10^k + frac exactly (c < 1e15 < 2^53)
        (i32.wrap_i64 (i64.sub (i64.trunc_f64_u (local.get $c))
                               (i64.mul (i64.extend_i32_u (local.get $ip)) (i64.trunc_f64_u (local.get $scale))))))))
    (local.set $k (i32.add (local.get $k) (i32.const 1)))
    (br $l)))
  (i32.const 0) (i32.const 0) (i32.const 0))

;; Writes the canonical form of a double to the output buffer:
;;   0 for +-0; plain integer digits for integral |v| < 2^53;
;;   plain decimal for 1e-6 <= |v| < 2^53; else d[.ddd]e(+|-)x.
(func $out_f64 (param $v f64)
  (local $av f64) (local $m i64) (local $e10 i32) (local $dp i32) (local $dn i32) (local $point i32) (local $sci i32) (local $z i32)
  (if (f64.eq (local.get $v) (f64.const 0)) (then (call $out_byte (i32.const 0x30)) (return)))
  (local.set $av (f64.abs (local.get $v)))
  (if (i32.and (f64.lt (local.get $av) (f64.const 9007199254740992)) (f64.eq (f64.floor (local.get $av)) (local.get $av)))
    (then (call $out_i64 (i64.trunc_f64_s (local.get $v))) (return)))
  (if (f64.lt (local.get $v) (f64.const 0)) (then (call $out_byte (i32.const 0x2D))))
  (if (i32.and (f64.ge (local.get $av) (f64.const 1e-6)) (f64.lt (local.get $av) (f64.const 1e9)))
    (then
      (call $short_decimal (local.get $av)) (local.set $z) (local.set $point) (local.set $sci)
      (if (local.get $sci)
        (then
          (call $out_u64 (i64.extend_i32_u (local.get $point)))
          (call $out_byte (i32.const 0x2E))
          ;; fraction, zero-padded on the left to k digits
          (call $u64_digits (i64.extend_i32_u (local.get $z))) (local.set $dn) (local.set $dp)
          (local.set $sci (i32.sub (local.get $sci) (local.get $dn)))
          (block $zd (loop $zl (br_if $zd (i32.le_s (local.get $sci) (i32.const 0)))
            (call $out_byte (i32.const 0x30)) (local.set $sci (i32.sub (local.get $sci) (i32.const 1))) (br $zl)))
          (call $out_bytes (local.get $dp) (local.get $dn))
          (return)))))
  (call $ryu_d2d (i64.reinterpret_f64 (local.get $av))) (local.set $e10) (local.set $m)
  (call $u64_digits (local.get $m)) (local.set $dn) (local.set $dp)
  (if (i32.and (f64.ge (local.get $av) (f64.const 1e-6)) (f64.lt (local.get $av) (f64.const 9007199254740992)))
    (then
      ;; plain decimal; non-integral here, so e10 < 0
      (local.set $point (i32.add (local.get $dn) (local.get $e10)))
      (if (i32.gt_s (local.get $point) (i32.const 0))
        (then
          (call $out_bytes (local.get $dp) (local.get $point))
          (call $out_byte (i32.const 0x2E))
          (call $out_bytes (i32.add (local.get $dp) (local.get $point)) (i32.sub (local.get $dn) (local.get $point))))
        (else
          (call $out_byte (i32.const 0x30))
          (call $out_byte (i32.const 0x2E))
          (local.set $z (i32.sub (i32.const 0) (local.get $point)))
          (block $zd (loop $zl (br_if $zd (i32.eqz (local.get $z)))
            (call $out_byte (i32.const 0x30)) (local.set $z (i32.sub (local.get $z) (i32.const 1))) (br $zl)))
          (call $out_bytes (local.get $dp) (local.get $dn))))
      (return)))
  ;; exponent form
  (local.set $sci (i32.add (local.get $e10) (i32.sub (local.get $dn) (i32.const 1))))
  (call $out_byte (i32.load8_u (local.get $dp)))
  (if (i32.gt_u (local.get $dn) (i32.const 1))
    (then (call $out_byte (i32.const 0x2E)) (call $out_bytes (i32.add (local.get $dp) (i32.const 1)) (i32.sub (local.get $dn) (i32.const 1)))))
  (call $out_byte (i32.const 0x65))
  (call $out_byte (select (i32.const 0x2D) (i32.const 0x2B) (i32.lt_s (local.get $sci) (i32.const 0))))
  (call $out_u64 (i64.extend_i32_u (select (i32.sub (i32.const 0) (local.get $sci)) (local.get $sci) (i32.lt_s (local.get $sci) (i32.const 0))))))

;; ---------------------------------------------------------------------------
;; Diagnostics exports (used by the test suite to validate the algorithms)
;; ---------------------------------------------------------------------------

;; Parse the current input as a number token; returns the double (NaN on error).
(func (export "gcf_debug_parse_f64") (param $len i32) (result f64)
  (local $k i32) (local $v f64)
  (local.set $k (call $number_kind (global.get $in_ptr) (local.get $len)))
  (if (i32.eqz (local.get $k)) (then (return (f64.const nan))))
  (if (i32.eq (local.get $k) (i32.const 1))
    (then (local.set $v (f64.convert_i64_s (call $parse_int64 (global.get $in_ptr) (local.get $len) (i32.const 1)))))
    (else (local.set $v (call $parse_f64 (global.get $in_ptr) (local.get $len) (i32.const 1)))))
  (select (f64.const nan) (local.get $v) (global.get $err)))

;; Canonical formatting of a double into the output buffer.
(func (export "gcf_debug_format_f64") (param $v f64)
  (call $out_f64 (local.get $v))
  (call $out_finish))
