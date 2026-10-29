;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 felixdrp
;;
;; 12_tape.wat — binary tape for lazy decoding (host.ts `decodeLazy`),
;; byte-identical to gcf.zig TapeWriter.
;;
;; Layout (little-endian):
;;   u32 magic "GCFT" | u32 version (1) | u32 root node | u32 word count W |
;;   u32 pool length P | W x u32 node words | P bytes UTF-8 string pool
;; Nodes are in post-order (children before their container, the root last),
;; as in the Zig writer. Node at word i, tag in the low 4 bits:
;;   0 null | 1 false | 2 true | 3 int inline (value = word >> 4, signed 28-bit)
;;   4 int64 (2 words follow) | 5 f64 (2 words follow)
;;   6 string: len = word >> 4, next word = pool offset
;;   7 array: count = word >> 4, then count child indices
;;   8 object: count = word >> 4, then count x (key offset, key len, child)
;; Keys are interned (each distinct key has a distinct offset; an empty key
;; takes one padding byte).
;;
;; Generic documents are written while they are parsed (streaming mode,
;; see 07_json_out.wat): each value is written as soon as it is complete,
;; which is exactly post-order. Other payloads are written from their tree.

;; The tape is built in one region of the arena, laid out as the result:
;;   20-byte header | words (capacity tw_cap) | string pool (capacity tp_cap)
;; It is created at the first write, after the line table, so while a large
;; table streams it is normally the last arena block and grows in place:
;; more pool capacity extends the region; more word capacity extends it and
;; moves the (smaller) pool up. Only when something else was allocated after
;; it is the region copied to the arena top. At the end the pool is moved
;; down next to the words and the region is the output, with no final copy.
;; Interned key offsets are cached by (pointer, length): tabular rows and
;; graph objects repeat the same key slices, so most lookups skip the hash.
(global $tape_keys (mut i32) (i32.const 0))
(global $tr_base (mut i32) (i32.const 0))   ;; region (0 = not created yet)
(global $tr_hint (mut i32) (i32.const 0))   ;; input length, for the first sizes
(global $tw_base (mut i32) (i32.const 0))   ;; words = tr_base + 20
(global $tw_n (mut i32) (i32.const 0))
(global $tw_cap (mut i32) (i32.const 0))
(global $tp_base (mut i32) (i32.const 0))   ;; pool = words + 4 * tw_cap
(global $tp_n (mut i32) (i32.const 0))
(global $tp_cap (mut i32) (i32.const 0))
(global $TW_CACHE (mut i32) (i32.const 0))  ;; 64 x (ptr, len, offset): an arena block per call
(global $twc_hi (mut i32) (i32.const 0))    ;; end of the highest slice in the cache

;; Give the region `wcap` words and `pcap` pool bytes (both at least the
;; current ones): in place when it is the last arena block, otherwise by
;; copying it to the arena top. wcap is even and pcap is 4 modulo 8, so the
;; region's size (20 + 4 wcap + pcap) is a multiple of 8 and the region ends
;; exactly where the next (8-aligned) allocation starts.
(func $tr_resize (param $wcap i32) (param $pcap i32)
  (local $end i32) (local $nb i32) (local $np i32)
  (local.set $end (i32.add (global.get $tp_base) (global.get $tp_cap)))
  (if (i32.and (i32.ne (global.get $tr_base) (i32.const 0)) (i32.eq (local.get $end) (global.get $arena_top)))
    (then
      (drop (call $alloc (i32.add (i32.shl (i32.sub (local.get $wcap) (global.get $tw_cap)) (i32.const 2))
                                  (i32.sub (local.get $pcap) (global.get $tp_cap)))))
      (if (global.get $err) (then (return)))
      (local.set $np (i32.add (global.get $tw_base) (i32.shl (local.get $wcap) (i32.const 2))))
      (memory.copy (local.get $np) (global.get $tp_base) (global.get $tp_n))
      (global.set $tp_base (local.get $np))
      (global.set $tw_cap (local.get $wcap))
      (global.set $tp_cap (local.get $pcap))
      (global.set $pin (global.get $arena_top))
      (return)))
  (local.set $nb (call $alloc (i32.add (i32.add (i32.const 20) (i32.shl (local.get $wcap) (i32.const 2))) (local.get $pcap))))
  (if (global.get $err) (then (return)))
  (local.set $np (i32.add (i32.add (local.get $nb) (i32.const 20)) (i32.shl (local.get $wcap) (i32.const 2))))
  (if (global.get $tr_base)
    (then
      (memory.copy (i32.add (local.get $nb) (i32.const 20)) (global.get $tw_base) (i32.shl (global.get $tw_n) (i32.const 2)))
      (memory.copy (local.get $np) (global.get $tp_base) (global.get $tp_n))))
  (global.set $tr_base (local.get $nb))
  (global.set $tw_base (i32.add (local.get $nb) (i32.const 20)))
  (global.set $tp_base (local.get $np))
  (global.set $tw_cap (local.get $wcap))
  (global.set $tp_cap (local.get $pcap))
  (global.set $pin (global.get $arena_top)))

;; Create the region at the first write: words ~ input/2 bytes, pool ~
;; input/8. What would otherwise be allocated right after it is set up
;; first: child indices of streamed containers (STK_TAPE), one per line, and
;; room for 32 interned keys.
(func $tr_init
  (local $q i32)
  (call $sm_grow (global.get $tape_keys))
  (call $sm_grow (global.get $tape_keys))
  (if (global.get $err) (then (return)))
  (local.set $q (call $stack_push (global.get $STK_TAPE) (i32.add (i32.shl (global.get $nlines) (i32.const 2)) (i32.const 64))))
  (if (global.get $err) (then (return)))
  (call $stack_truncate (global.get $STK_TAPE) (i32.sub (call $stack_len (global.get $STK_TAPE))
                                                        (i32.add (i32.shl (global.get $nlines) (i32.const 2)) (i32.const 64))))
  (call $tr_resize (i32.and (i32.add (i32.shr_u (global.get $tr_hint) (i32.const 3)) (i32.const 1025)) (i32.const -2))
                   (call $pool_cap (i32.add (i32.shr_u (global.get $tr_hint) (i32.const 3)) (i32.const 4096)))))

;; At least `n` pool bytes, 4 modulo 8.
(func $pool_cap (param $n i32) (result i32)
  (i32.add (i32.and (i32.add (local.get $n) (i32.const 7)) (i32.const -8)) (i32.const 4)))

;; Growth step for a capacity: +25% while the region is the last arena block
;; (growing in place only moves the pool), x2 when it has to be copied.
(func $tr_grow (param $cap i32) (result i32)
  (if (result i32) (i32.eq (i32.add (global.get $tp_base) (global.get $tp_cap)) (global.get $arena_top))
    (then (i32.add (i32.add (local.get $cap) (i32.shr_u (local.get $cap) (i32.const 2))) (i32.const 4096)))
    (else (i32.shl (local.get $cap) (i32.const 1)))))

;; Streamed rows: the largest row written so far (words, pool bytes). After a
;; row is released the region is the last arena block again, and room for
;; two such rows is made there, so the next row (whose tree is allocated
;; above the region) does not have to copy the region to grow it.
(global $row_wmax (mut i32) (i32.const 0))
(global $row_pmax (mut i32) (i32.const 0))

(func $tr_headroom
  (local $w i32) (local $p i32)
  (if (i32.eqz (global.get $tr_base)) (then (return)))
  (if (i32.ne (i32.add (global.get $tp_base) (global.get $tp_cap)) (global.get $arena_top)) (then (return)))
  (local.set $w (i32.add (global.get $tw_n) (i32.add (i32.shl (global.get $row_wmax) (i32.const 1)) (i32.const 64))))
  (local.set $p (i32.add (global.get $tp_n) (i32.add (i32.shl (global.get $row_pmax) (i32.const 1)) (i32.const 64))))
  (if (i32.and (i32.le_u (local.get $w) (global.get $tw_cap)) (i32.le_u (local.get $p) (global.get $tp_cap))) (then (return)))
  (if (i32.gt_u (local.get $w) (global.get $tw_cap))
    (then (local.set $w (select (local.get $w) (call $tr_grow (global.get $tw_cap)) (i32.gt_u (local.get $w) (call $tr_grow (global.get $tw_cap))))))
    (else (local.set $w (global.get $tw_cap))))
  (if (i32.gt_u (local.get $p) (global.get $tp_cap))
    (then (local.set $p (select (local.get $p) (call $tr_grow (global.get $tp_cap)) (i32.gt_u (local.get $p) (call $tr_grow (global.get $tp_cap))))))
    (else (local.set $p (global.get $tp_cap))))
  (call $tr_resize (i32.and (i32.add (local.get $w) (i32.const 1)) (i32.const -2))
                   (if (result i32) (i32.eq (local.get $p) (global.get $tp_cap)) (then (local.get $p)) (else (call $pool_cap (local.get $p))))))

;; Write a streamed row, recording its size for $tr_headroom.
(func $tw_row (param $a i32) (param $n i32) (result i32)
  (local $w0 i32) (local $p0 i32) (local $c i32)
  (local.set $w0 (global.get $tw_n))
  (local.set $p0 (global.get $tp_n))
  (local.set $c (call $tw_append (i32.const 7) (local.get $a) (i64.extend_i32_u (local.get $n))))
  (if (i32.gt_u (i32.sub (global.get $tw_n) (local.get $w0)) (global.get $row_wmax))
    (then (global.set $row_wmax (i32.sub (global.get $tw_n) (local.get $w0)))))
  (if (i32.gt_u (i32.sub (global.get $tp_n) (local.get $p0)) (global.get $row_pmax))
    (then (global.set $row_pmax (i32.sub (global.get $tp_n) (local.get $p0)))))
  (local.get $c))

;; Make room for k more words.
(func $tw_reserve (param $k i32)
  (local $cap i32)
  (if (i32.eqz (global.get $tr_base)) (then (call $tr_init) (if (global.get $err) (then (return)))))
  (if (i32.le_u (i32.add (global.get $tw_n) (local.get $k)) (global.get $tw_cap)) (then (return)))
  (local.set $cap (call $tr_grow (global.get $tw_cap)))
  (if (i32.lt_u (local.get $cap) (i32.add (global.get $tw_n) (local.get $k))) (then (local.set $cap (i32.add (global.get $tw_n) (local.get $k)))))
  (call $tr_resize (i32.and (i32.add (local.get $cap) (i32.const 1)) (i32.const -2)) (global.get $tp_cap)))

;; Append one word (capacity reserved by the caller).
(func $tw_put (param $w i32)
  (i32.store (i32.add (global.get $tw_base) (i32.shl (global.get $tw_n) (i32.const 2))) (local.get $w))
  (global.set $tw_n (i32.add (global.get $tw_n) (i32.const 1))))

(func $tw_set (param $idx i32) (param $w i32)
  (i32.store (i32.add (global.get $tw_base) (i32.shl (local.get $idx) (i32.const 2))) (local.get $w)))

;; Append bytes to the pool (plus room for a padding byte); returns their offset.
(func $tw_str (param $p i32) (param $n i32) (result i32)
  (local $off i32) (local $cap i32)
  (if (i32.eqz (global.get $tr_base)) (then (call $tr_init) (if (global.get $err) (then (return (i32.const 0))))))
  (local.set $off (global.get $tp_n))
  (if (i32.gt_u (i32.add (i32.add (global.get $tp_n) (local.get $n)) (i32.const 17)) (global.get $tp_cap))
    (then
      (local.set $cap (call $tr_grow (global.get $tp_cap)))
      (if (i32.lt_u (local.get $cap) (i32.add (i32.add (global.get $tp_n) (local.get $n)) (i32.const 17)))
        (then (local.set $cap (i32.add (i32.add (global.get $tp_n) (local.get $n)) (i32.const 17)))))
      (call $tr_resize (global.get $tw_cap) (call $pool_cap (local.get $cap)))
      (if (global.get $err) (then (return (i32.const 0))))))
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
      ;; the map keeps the key's slice, which may be a row's decoded string
      (global.set $pin (global.get $arena_top))
      (drop (call $sm_find (global.get $tape_keys) (local.get $p) (local.get $n) (i32.const 1) (local.get $off)))
      (if (i32.eqz (local.get $n))
        (then
          (i32.store8 (i32.add (global.get $tp_base) (global.get $tp_n)) (i32.const 0))
          (global.set $tp_n (i32.add (global.get $tp_n) (i32.const 1)))))))
  (i32.store (local.get $c) (local.get $p))
  (i32.store offset=4 (local.get $c) (local.get $n))
  (i32.store offset=8 (local.get $c) (local.get $off))
  (if (i32.gt_u (i32.add (local.get $p) (local.get $n)) (global.get $twc_hi))
    (then (global.set $twc_hi (i32.add (local.get $p) (local.get $n)))))
  (local.get $off))

(func $tw_node (param $t i32) (param $a i32) (param $b i64) (result i32)
  (local $idx i32) (local $n i32) (local $i i32) (local $mark i32) (local $q i32) (local $ko i32) (local $c i32)
  (if (i32.eq (local.get $t) (i32.const 10)) (then (return (local.get $a))))  ;; already on the tape
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
      (local.set $idx (global.get $tw_n))
      (call $tw_put (i32.or (i32.shl (local.get $n) (i32.const 4)) (i32.const 6)))
      (call $tw_put (local.get $q))
      (return (local.get $idx))))
  ;; containers, in post-order: the children first (their indices kept on
  ;; STK_TAPE), then the container's own words
  ;; one slot per child, reserved up front (children push above it; the
  ;; stack may move while they do, so slots are addressed from its base)
  (local.set $mark (call $stack_len (global.get $STK_TAPE)))
  (drop (call $stack_push (global.get $STK_TAPE) (i32.shl (local.get $n) (i32.const 2))))
  (if (global.get $err) (then (return (i32.const 0))))
  (block $d (loop $l
    (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $q (if (result i32) (i32.eq (local.get $t) (i32.const 6))
      (then (i32.add (local.get $a) (i32.shl (local.get $i) (i32.const 4))))
      (else (i32.add (i32.add (local.get $a) (i32.mul (local.get $i) (i32.const 24))) (i32.const 8)))))
    (local.set $c (call $tw_node (i32.load (local.get $q)) (i32.load offset=4 (local.get $q)) (i64.load offset=8 (local.get $q))))
    (if (global.get $err) (then (return (i32.const 0))))
    (i32.store (i32.add (call $stack_base (global.get $STK_TAPE)) (i32.add (local.get $mark) (i32.shl (local.get $i) (i32.const 2))))
               (local.get $c))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.set $idx (call $tw_container (local.get $t) (local.get $a) (local.get $n) (local.get $mark)))
  (call $stack_truncate (global.get $STK_TAPE) (local.get $mark))
  (local.get $idx))

;; Write a value unless it is already on the tape, and push its index on
;; STK_TAPE as the next child of the container being streamed.
(func $tw_append (param $t i32) (param $a i32) (param $b i64) (result i32)
  (local $c i32) (local $q i32)
  (local.set $c (call $tw_node (local.get $t) (local.get $a) (local.get $b)))
  (if (global.get $err) (then (return (i32.const 0))))
  (local.set $q (call $stack_push (global.get $STK_TAPE) (i32.const 4)))
  (if (global.get $err) (then (return (i32.const 0))))
  (i32.store (local.get $q) (local.get $c))
  (local.get $c))

;; Write a container node whose `n` child indices are on STK_TAPE from
;; `mark`. Objects: `a` is the member array (keys are read from it; their
;; values are already written), interned in member order. Returns its index.
(func $tw_container (param $t i32) (param $a i32) (param $n i32) (param $mark i32) (result i32)
  (local $idx i32) (local $i i32) (local $kids i32) (local $q i32)
  (if (i32.eq (local.get $t) (i32.const 6))
    (then
      (call $tw_reserve (i32.add (local.get $n) (i32.const 1)))
      (if (global.get $err) (then (return (i32.const 0))))
      (local.set $idx (global.get $tw_n))
      (call $tw_put (i32.or (i32.shl (local.get $n) (i32.const 4)) (i32.const 7)))
      (memory.copy (i32.add (global.get $tw_base) (i32.shl (global.get $tw_n) (i32.const 2)))
                   (i32.add (call $stack_base (global.get $STK_TAPE)) (local.get $mark)) (i32.shl (local.get $n) (i32.const 2)))
      (global.set $tw_n (i32.add (global.get $tw_n) (local.get $n)))
      (return (local.get $idx))))
  (call $tw_reserve (i32.add (i32.mul (local.get $n) (i32.const 3)) (i32.const 1)))
  (if (global.get $err) (then (return (i32.const 0))))
  (local.set $idx (global.get $tw_n))
  (call $tw_put (i32.or (i32.shl (local.get $n) (i32.const 4)) (i32.const 8)))
  (block $d (loop $l
    (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $q (i32.add (local.get $a) (i32.mul (local.get $i) (i32.const 24))))
    (call $tw_put (call $tw_key (i32.load (local.get $q)) (i32.load offset=4 (local.get $q))))
    (if (global.get $err) (then (return (i32.const 0))))
    (call $tw_put (i32.load offset=4 (local.get $q)))
    (call $tw_put (i32.load (i32.add (call $stack_base (global.get $STK_TAPE)) (i32.add (local.get $mark) (i32.shl (local.get $i) (i32.const 2))))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.get $idx))

;; GCF -> tape.
(func (export "gcf_decode_tape") (param $len i32) (result i32)
  (local $vt i32) (local $va i32) (local $vb i64) (local $root i32) (local $wb i32)
  ;; the tape of a generic document is written while it is parsed
  (global.set $tape_keys (call $ks_new))
  (global.set $tr_base (i32.const 0)) (global.set $tr_hint (local.get $len))
  (global.set $row_wmax (i32.const 0)) (global.set $row_pmax (i32.const 0)) (global.set $twc_hi (i32.const 0))
  (global.set $tw_base (i32.const 0)) (global.set $tw_n (i32.const 0)) (global.set $tw_cap (i32.const 0))
  (global.set $tp_base (i32.const 0)) (global.set $tp_n (i32.const 0)) (global.set $tp_cap (i32.const 0))
  (global.set $TW_CACHE (call $alloc (i32.const 768)))
  (if (global.get $err) (then (return (global.get $err))))
  (memory.fill (global.get $TW_CACHE) (i32.const 0) (i32.const 768))
  (global.set $smode (i32.const 2))
  (call $decode_doc (global.get $in_ptr) (local.get $len))
  (local.set $vb) (local.set $va) (local.set $vt)
  (global.set $smode (i32.const 0))
  (global.set $sact (i32.const 0))
  (if (global.get $err) (then (return (global.get $err))))
  ;; graph and delta payloads, and scalar roots, come back as a tree
  (local.set $root (call $tw_node (local.get $vt) (local.get $va) (local.get $vb)))
  (if (global.get $err) (then (return (global.get $err))))
  ;; header, words, then the pool moved down next to the words
  (local.set $wb (i32.shl (global.get $tw_n) (i32.const 2)))
  (memory.copy (i32.add (global.get $tw_base) (local.get $wb)) (global.get $tp_base) (global.get $tp_n))
  (i32.store (global.get $tr_base) (i32.const 0x54464347))
  (i32.store offset=4 (global.get $tr_base) (i32.const 1))
  (i32.store offset=8 (global.get $tr_base) (local.get $root))
  (i32.store offset=12 (global.get $tr_base) (global.get $tw_n))
  (i32.store offset=16 (global.get $tr_base) (global.get $tp_n))
  (global.set $out_ptr (global.get $tr_base))
  (global.set $out_len (i32.add (i32.add (i32.const 20) (local.get $wb)) (global.get $tp_n)))
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
