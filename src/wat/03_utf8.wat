;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 felixdrp
;;
;; 03_utf8.wat — UTF-8 validation (SPEC §2.2: reject malformed UTF-8 first).
;;
;; ASCII fast path: a 16-byte block whose bytes are all < 0x80 is skipped
;; with one i8x16.bitmask (the top bit of each lane). Multi-byte sequences
;; are checked for truncation, bad continuation bytes, overlong forms, values
;; above U+10FFFF and literal surrogates (reported as invalid_surrogate).

;; 1-based line number of byte offset `pos` (error path only).
(func $line_of (param $s i32) (param $pos i32) (result i32)
  (i32.add (call $count_byte (local.get $s) (local.get $pos) (i32.const 10)) (i32.const 1)))

;; Validates [s, s+len); on failure sets the error and returns 0.
(func $validate_utf8 (param $s i32) (param $len i32) (result i32)
  (local $i i32) (local $b i32) (local $need i32) (local $cp i32) (local $min i32) (local $k i32) (local $c i32)
  (block $ok
    (loop $next
      (br_if $ok (i32.ge_u (local.get $i) (local.get $len)))
      ;; ASCII fast path: whole block with no high bit set.
      (if (i32.le_u (i32.add (local.get $i) (i32.const 16)) (local.get $len))
        (then
          (if (i32.eqz (i8x16.bitmask (v128.load (i32.add (local.get $s) (local.get $i)))))
            (then (local.set $i (i32.add (local.get $i) (i32.const 16))) (br $next)))))
      (local.set $b (i32.load8_u (i32.add (local.get $s) (local.get $i))))
      (if (i32.lt_u (local.get $b) (i32.const 0x80))
        (then (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $next)))
      ;; Lead byte: number of continuation bytes, initial bits, minimum value.
      (if (i32.eq (i32.and (local.get $b) (i32.const 0xE0)) (i32.const 0xC0))
        (then (local.set $need (i32.const 1)) (local.set $cp (i32.and (local.get $b) (i32.const 0x1F))) (local.set $min (i32.const 0x80)))
        (else (if (i32.eq (i32.and (local.get $b) (i32.const 0xF0)) (i32.const 0xE0))
          (then (local.set $need (i32.const 2)) (local.set $cp (i32.and (local.get $b) (i32.const 0x0F))) (local.set $min (i32.const 0x800)))
          (else (if (i32.eq (i32.and (local.get $b) (i32.const 0xF8)) (i32.const 0xF0))
            (then (local.set $need (i32.const 3)) (local.set $cp (i32.and (local.get $b) (i32.const 0x07))) (local.set $min (i32.const 0x10000)))
            (else
              (call $fail (i32.const 12) (call $line_of (local.get $s) (local.get $i)))  ;; invalid_utf8
              (return (i32.const 0))))))))
      (if (i32.ge_u (i32.add (local.get $i) (local.get $need)) (local.get $len))
        (then (call $fail (i32.const 12) (call $line_of (local.get $s) (local.get $i))) (return (i32.const 0))))
      (local.set $k (i32.const 1))
      (block $cont_done
        (loop $cont
          (br_if $cont_done (i32.gt_u (local.get $k) (local.get $need)))
          (local.set $c (i32.load8_u (i32.add (local.get $s) (i32.add (local.get $i) (local.get $k)))))
          (if (i32.ne (i32.and (local.get $c) (i32.const 0xC0)) (i32.const 0x80))
            (then (call $fail (i32.const 12) (call $line_of (local.get $s) (local.get $i))) (return (i32.const 0))))
          (local.set $cp (i32.or (i32.shl (local.get $cp) (i32.const 6)) (i32.and (local.get $c) (i32.const 0x3F))))
          (local.set $k (i32.add (local.get $k) (i32.const 1)))
          (br $cont)))
      (if (i32.or (i32.lt_u (local.get $cp) (local.get $min)) (i32.gt_u (local.get $cp) (i32.const 0x10FFFF)))
        (then (call $fail (i32.const 12) (call $line_of (local.get $s) (local.get $i))) (return (i32.const 0))))
      (if (i32.and (i32.ge_u (local.get $cp) (i32.const 0xD800)) (i32.le_u (local.get $cp) (i32.const 0xDFFF)))
        (then (call $fail (i32.const 11) (call $line_of (local.get $s) (local.get $i))) (return (i32.const 0))))  ;; invalid_surrogate
      (local.set $i (i32.add (local.get $i) (i32.add (local.get $need) (i32.const 1))))
      (br $next)))
  (i32.const 1))
