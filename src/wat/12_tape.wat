;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 felixdrp
;;
;; 12_tape.wat — binary tape for lazy decoding (host.ts `decodeLazy`),
;; byte-identical to gcf.zig TapeWriter.
;;
;; Layout (little-endian):
;;   u32 magic "GCFT" | u32 version (1) | u32 root node | u32 word count W |
;;   u32 pool length P | W x u32 node words | P bytes UTF-8 string pool
;; Node at word i, tag in the low 4 bits:
;;   0 null | 1 false | 2 true | 3 int inline (value = word >> 4, signed 28-bit)
;;   4 int64 (2 words follow) | 5 f64 (2 words follow)
;;   6 string: len = word >> 4, next word = pool offset
;;   7 array: count = word >> 4, then count child indices
;;   8 object: count = word >> 4, then count x (key offset, key len, child)
;; Keys are interned (each distinct key has a distinct offset; an empty key
;; takes one padding byte).
;;
;; Words grow on STK_ROW and the pool on STK_MISC; positions are kept as
;; indices because a growing stack may move.

;; Words live in one arena block written through a cursor (one capacity check
;; per node); the string pool likewise, filled with vector copies. Interned
;; key offsets are cached by (pointer, length): tabular rows and graph
;; objects repeat the same key slices, so most lookups skip the hash.
(global $tape_keys (mut i32) (i32.const 0))
(global $tw_base (mut i32) (i32.const 0))   ;; words
(global $tw_n (mut i32) (i32.const 0))
(global $tw_cap (mut i32) (i32.const 0))
(global $tp_base (mut i32) (i32.const 0))   ;; string pool
(global $tp_n (mut i32) (i32.const 0))
(global $tp_cap (mut i32) (i32.const 0))
(global $TW_CACHE (mut i32) (i32.const 0))  ;; 64 x (ptr, len, offset): an arena block per call

;; Make room for k more words.
(func $tw_reserve (param $k i32)
  (local $cap i32) (local $nb i32)
  (if (i32.le_u (i32.add (global.get $tw_n) (local.get $k)) (global.get $tw_cap)) (then (return)))
  (local.set $cap (i32.shl (global.get $tw_cap) (i32.const 1)))
  (if (i32.lt_u (local.get $cap) (i32.add (global.get $tw_n) (local.get $k))) (then (local.set $cap (i32.add (global.get $tw_n) (local.get $k)))))
  (if (i32.lt_u (local.get $cap) (i32.const 1024)) (then (local.set $cap (i32.const 1024))))
  (local.set $nb (call $alloc (i32.shl (local.get $cap) (i32.const 2))))
  (if (global.get $err) (then (return)))
  (memory.copy (local.get $nb) (global.get $tw_base) (i32.shl (global.get $tw_n) (i32.const 2)))
  (global.set $tw_base (local.get $nb))
  (global.set $tw_cap (local.get $cap)))

;; Append one word (capacity reserved by the caller).
(func $tw_put (param $w i32)
  (i32.store (i32.add (global.get $tw_base) (i32.shl (global.get $tw_n) (i32.const 2))) (local.get $w))
  (global.set $tw_n (i32.add (global.get $tw_n) (i32.const 1))))

(func $tw_set (param $idx i32) (param $w i32)
  (i32.store (i32.add (global.get $tw_base) (i32.shl (local.get $idx) (i32.const 2))) (local.get $w)))

;; Append bytes to the pool (plus room for a padding byte); returns their offset.
(func $tw_str (param $p i32) (param $n i32) (result i32)
  (local $off i32) (local $cap i32) (local $nb i32)
  (local.set $off (global.get $tp_n))
  (if (i32.gt_u (i32.add (i32.add (global.get $tp_n) (local.get $n)) (i32.const 17)) (global.get $tp_cap))
    (then
      (local.set $cap (i32.shl (global.get $tp_cap) (i32.const 1)))
      (if (i32.lt_u (local.get $cap) (i32.add (i32.add (global.get $tp_n) (local.get $n)) (i32.const 17)))
        (then (local.set $cap (i32.add (i32.add (global.get $tp_n) (local.get $n)) (i32.const 17)))))
      (if (i32.lt_u (local.get $cap) (i32.const 4096)) (then (local.set $cap (i32.const 4096))))
      (local.set $nb (call $alloc (local.get $cap)))
      (if (global.get $err) (then (return (i32.const 0))))
      (memory.copy (local.get $nb) (global.get $tp_base) (global.get $tp_n))
      (global.set $tp_base (local.get $nb))
      (global.set $tp_cap (local.get $cap))))
  (call $copy_short (i32.add (global.get $tp_base) (global.get $tp_n)) (local.get $p) (local.get $n))
  (global.set $tp_n (i32.add (global.get $tp_n) (local.get $n)))
  (local.get $off))

(func $tw_key (param $p i32) (param $n i32) (result i32)
  (local $off i32) (local $c i32)
  ;; cache hit: same slice as a key seen before
  (local.set $c (i32.add (global.get $TW_CACHE)
    (i32.mul (i32.and (i32.xor (i32.shr_u (local.get $p) (i32.const 2)) (local.get $n)) (i32.const 63)) (i32.const 12))))
  (if (i32.and (i32.eq (i32.load (local.get $c)) (local.get $p)) (i32.eq (i32.load offset=4 (local.get $c)) (local.get $n)))
    (then (return (i32.load offset=8 (local.get $c)))))
  (local.set $off (call $sm_find (global.get $tape_keys) (local.get $p) (local.get $n) (i32.const 0) (i32.const 0)))
  (if (i32.lt_s (local.get $off) (i32.const 0))
    (then
      (local.set $off (call $tw_str (local.get $p) (local.get $n)))
      (drop (call $sm_find (global.get $tape_keys) (local.get $p) (local.get $n) (i32.const 1) (local.get $off)))
      (if (i32.eqz (local.get $n))
        (then
          (i32.store8 (i32.add (global.get $tp_base) (global.get $tp_n)) (i32.const 0))
          (global.set $tp_n (i32.add (global.get $tp_n) (i32.const 1)))))))
  (i32.store (local.get $c) (local.get $p))
  (i32.store offset=4 (local.get $c) (local.get $n))
  (i32.store offset=8 (local.get $c) (local.get $off))
  (local.get $off))

(func $tw_node (param $t i32) (param $a i32) (param $b i64) (result i32)
  (local $idx i32) (local $n i32) (local $i i32) (local $base i32) (local $q i32) (local $ko i32) (local $c i32)
  (local.set $idx (global.get $tw_n))
  (if (i32.le_u (local.get $t) (i32.const 2))
    (then (call $tw_reserve (i32.const 1)) (call $tw_put (local.get $t)) (return (local.get $idx))))
  (if (i32.eq (local.get $t) (i32.const 3))
    (then
      (call $tw_reserve (i32.const 3))
      (if (i32.and (i64.ge_s (local.get $b) (i64.const -134217728)) (i64.lt_s (local.get $b) (i64.const 134217728)))
        (then (call $tw_put (i32.or (i32.shl (i32.wrap_i64 (local.get $b)) (i32.const 4)) (i32.const 3))) (return (local.get $idx))))
      (call $tw_put (i32.const 4))
      (call $tw_put (i32.wrap_i64 (local.get $b)))
      (call $tw_put (i32.wrap_i64 (i64.shr_u (local.get $b) (i64.const 32))))
      (return (local.get $idx))))
  (if (i32.eq (local.get $t) (i32.const 4))
    (then
      (call $tw_reserve (i32.const 3))
      (call $tw_put (i32.const 5))
      (call $tw_put (i32.wrap_i64 (local.get $b)))
      (call $tw_put (i32.wrap_i64 (i64.shr_u (local.get $b) (i64.const 32))))
      (return (local.get $idx))))
  (local.set $n (i32.wrap_i64 (local.get $b)))
  (if (i32.eq (local.get $t) (i32.const 5))
    (then
      (local.set $q (call $tw_str (local.get $a) (local.get $n)))
      (call $tw_reserve (i32.const 2))
      (call $tw_put (i32.or (i32.shl (local.get $n) (i32.const 4)) (i32.const 6)))
      (call $tw_put (local.get $q))
      (return (local.get $idx))))
  (if (i32.eq (local.get $t) (i32.const 6))
    (then
      (call $tw_reserve (i32.add (local.get $n) (i32.const 1)))
      (if (global.get $err) (then (return (i32.const 0))))
      (call $tw_put (i32.or (i32.shl (local.get $n) (i32.const 4)) (i32.const 7)))
      (local.set $base (global.get $tw_n))
      (global.set $tw_n (i32.add (global.get $tw_n) (local.get $n)))
      (block $d (loop $l
        (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $q (i32.add (local.get $a) (i32.shl (local.get $i) (i32.const 4))))
        (local.set $c (call $tw_node (i32.load (local.get $q)) (i32.load offset=4 (local.get $q)) (i64.load offset=8 (local.get $q))))
        (if (global.get $err) (then (return (i32.const 0))))
        (call $tw_set (i32.add (local.get $base) (local.get $i)) (local.get $c))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (return (local.get $idx))))
  ;; object
  (call $tw_reserve (i32.add (i32.mul (local.get $n) (i32.const 3)) (i32.const 1)))
  (if (global.get $err) (then (return (i32.const 0))))
  (call $tw_put (i32.or (i32.shl (local.get $n) (i32.const 4)) (i32.const 8)))
  (local.set $base (global.get $tw_n))
  (global.set $tw_n (i32.add (global.get $tw_n) (i32.mul (local.get $n) (i32.const 3))))
  (block $d (loop $l
    (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $q (i32.add (local.get $a) (i32.mul (local.get $i) (i32.const 24))))
    (local.set $ko (call $tw_key (i32.load (local.get $q)) (i32.load offset=4 (local.get $q))))
    (local.set $c (call $tw_node (i32.load offset=8 (local.get $q)) (i32.load offset=12 (local.get $q)) (i64.load offset=16 (local.get $q))))
    (if (global.get $err) (then (return (i32.const 0))))
    (call $tw_set (i32.add (local.get $base) (i32.mul (local.get $i) (i32.const 3))) (local.get $ko))
    (call $tw_set (i32.add (local.get $base) (i32.add (i32.mul (local.get $i) (i32.const 3)) (i32.const 1))) (i32.load offset=4 (local.get $q)))
    (call $tw_set (i32.add (local.get $base) (i32.add (i32.mul (local.get $i) (i32.const 3)) (i32.const 2))) (local.get $c))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.get $idx))

;; GCF -> tape.
(func (export "gcf_decode_tape") (param $len i32) (result i32)
  (local $vt i32) (local $va i32) (local $vb i64) (local $root i32) (local $wb i32) (local $pl i32) (local $out i32)
  (call $decode_doc (global.get $in_ptr) (local.get $len))
  (local.set $vb) (local.set $va) (local.set $vt)
  (if (global.get $err) (then (return (global.get $err))))
  (global.set $tape_keys (call $ks_new))
  (global.set $tw_base (i32.const 0)) (global.set $tw_n (i32.const 0)) (global.set $tw_cap (i32.const 0))
  (global.set $tp_base (i32.const 0)) (global.set $tp_n (i32.const 0)) (global.set $tp_cap (i32.const 0))
  (global.set $TW_CACHE (call $alloc (i32.const 768)))
  (if (global.get $err) (then (return (global.get $err))))
  (memory.fill (global.get $TW_CACHE) (i32.const 0) (i32.const 768))
  ;; sizing hint, as in the Zig writer: words ~ input/2, pool ~ input
  (call $tw_reserve (i32.add (i32.shr_u (local.get $len) (i32.const 3)) (i32.const 16)))
  (local.set $root (call $tw_node (local.get $vt) (local.get $va) (local.get $vb)))
  (if (global.get $err) (then (return (global.get $err))))
  (local.set $wb (i32.shl (global.get $tw_n) (i32.const 2)))
  (local.set $pl (global.get $tp_n))
  (local.set $out (call $alloc (i32.add (i32.add (i32.const 20) (local.get $wb)) (local.get $pl))))
  (if (global.get $err) (then (return (global.get $err))))
  (i32.store (local.get $out) (i32.const 0x54464347))
  (i32.store offset=4 (local.get $out) (i32.const 1))
  (i32.store offset=8 (local.get $out) (local.get $root))
  (i32.store offset=12 (local.get $out) (i32.shr_u (local.get $wb) (i32.const 2)))
  (i32.store offset=16 (local.get $out) (local.get $pl))
  (memory.copy (i32.add (local.get $out) (i32.const 20)) (global.get $tw_base) (local.get $wb))
  (memory.copy (i32.add (local.get $out) (i32.add (i32.const 20) (local.get $wb))) (global.get $tp_base) (local.get $pl))
  (global.set $out_ptr (local.get $out))
  (global.set $out_len (i32.add (i32.add (i32.const 20) (local.get $wb)) (local.get $pl)))
  (i32.const 0))

;; ---------------------------------------------------------------------------
;; Structural scanner diagnostics (same contract as the Zig exports)
;; ---------------------------------------------------------------------------

;; Bitmask of the structural bytes \n " # , : = @ [ ] ^ { | } ~ in a block:
;; nibble-table classification (two swizzles and an AND), as in Module A.
(func $structural_mask (param $v v128) (result i32)
  (local $lo v128) (local $hi v128)
  (local.set $lo (i8x16.swizzle (v128.load (i32.const 0x7800)) (v128.and (local.get $v) (i8x16.splat (i32.const 0x0F)))))
  (local.set $hi (i8x16.swizzle (v128.load (i32.const 0x7810))
                   (v128.and (i16x8.shr_u (local.get $v) (i32.const 4)) (i8x16.splat (i32.const 0x0F)))))
  (i8x16.bitmask (i8x16.ne (v128.and (local.get $lo) (local.get $hi)) (v128.const i64x2 0 0))))

;; Structural count, or (out != 0) the offsets written as u32 to out[0..cap).
(func $scan_structural (param $s i32) (param $n i32) (param $out i32) (param $cap i32) (result i32)
  (local $i i32) (local $m i32) (local $cnt i32) (local $buf v128) (local $tail i32)
  (block $done (loop $l
    (br_if $done (i32.gt_u (i32.add (local.get $i) (i32.const 16)) (local.get $n)))
    (local.set $m (call $structural_mask (v128.load (i32.add (local.get $s) (local.get $i)))))
    (if (local.get $out)
      (then
        (block $md (loop $ml
          (br_if $md (i32.eqz (local.get $m)))
          (if (i32.lt_u (local.get $cnt) (local.get $cap))
            (then (i32.store (i32.add (local.get $out) (i32.shl (local.get $cnt) (i32.const 2))) (i32.add (local.get $i) (i32.ctz (local.get $m))))))
          (local.set $cnt (i32.add (local.get $cnt) (i32.const 1)))
          (local.set $m (i32.and (local.get $m) (i32.sub (local.get $m) (i32.const 1))))
          (br $ml))))
      (else (local.set $cnt (i32.add (local.get $cnt) (i32.popcnt (local.get $m))))))
    (local.set $i (i32.add (local.get $i) (i32.const 16)))
    (br $l)))
  ;; tail: copy the last < 16 bytes into a zeroed block (0 is not structural)
  (local.set $tail (i32.sub (local.get $n) (local.get $i)))
  (if (local.get $tail)
    (then
      (v128.store (global.get $TMP) (v128.const i64x2 0 0))
      (memory.copy (global.get $TMP) (i32.add (local.get $s) (local.get $i)) (local.get $tail))
      (local.set $m (i32.and (call $structural_mask (v128.load (global.get $TMP))) (i32.sub (i32.shl (i32.const 1) (local.get $tail)) (i32.const 1))))
      (if (local.get $out)
        (then
          (block $md (loop $ml
            (br_if $md (i32.eqz (local.get $m)))
            (if (i32.lt_u (local.get $cnt) (local.get $cap))
              (then (i32.store (i32.add (local.get $out) (i32.shl (local.get $cnt) (i32.const 2))) (i32.add (local.get $i) (i32.ctz (local.get $m))))))
            (local.set $cnt (i32.add (local.get $cnt) (i32.const 1)))
            (local.set $m (i32.and (local.get $m) (i32.sub (local.get $m) (i32.const 1))))
            (br $ml))))
        (else (local.set $cnt (i32.add (local.get $cnt) (i32.popcnt (local.get $m))))))))
  (local.get $cnt))

(func (export "gcf_scan_structural") (param $len i32) (result i32)
  (call $scan_structural (global.get $in_ptr) (local.get $len) (i32.const 0) (i32.const 0)))

;; Byte-at-a-time baseline (for the SIMD speed-up measurements).
(func (export "gcf_scan_structural_scalar") (param $len i32) (result i32)
  (local $i i32) (local $n i32) (local $b i32)
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
    (local.set $b (call $at (global.get $in_ptr) (local.get $i)))
    (if (i32.or (i32.or (i32.or (i32.or (i32.eq (local.get $b) (i32.const 0x0A)) (i32.eq (local.get $b) (i32.const 0x22)))
                                (i32.or (i32.eq (local.get $b) (i32.const 0x23)) (i32.eq (local.get $b) (i32.const 0x2C))))
                        (i32.or (i32.or (i32.eq (local.get $b) (i32.const 0x3A)) (i32.eq (local.get $b) (i32.const 0x3D)))
                                (i32.or (i32.eq (local.get $b) (i32.const 0x40)) (i32.eq (local.get $b) (i32.const 0x5B)))))
                (i32.or (i32.or (i32.or (i32.eq (local.get $b) (i32.const 0x5D)) (i32.eq (local.get $b) (i32.const 0x5E)))
                                (i32.or (i32.eq (local.get $b) (i32.const 0x7B)) (i32.eq (local.get $b) (i32.const 0x7C))))
                        (i32.or (i32.eq (local.get $b) (i32.const 0x7D)) (i32.eq (local.get $b) (i32.const 0x7E)))))
      (then (local.set $n (i32.add (local.get $n) (i32.const 1)))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.get $n))

;; Offsets into out[0..cap); returns the total count (> cap: nothing reliable written past cap).
(func (export "gcf_scan_structural_positions") (param $len i32) (param $out i32) (param $cap i32) (result i32)
  (local $n i32)
  (local.set $n (call $scan_structural (global.get $in_ptr) (local.get $len) (i32.const 0) (i32.const 0)))
  (if (i32.gt_u (local.get $n) (local.get $cap)) (then (return (local.get $n))))
  (call $scan_structural (global.get $in_ptr) (local.get $len) (local.get $out) (local.get $cap)))
