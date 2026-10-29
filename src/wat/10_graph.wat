;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 felixdrp
;;
;; 10_graph.wat — graph profile decoding (SPEC §5, §9, §10.1) and generic
;; delta payloads (SPEC §10a.2), mirroring gcf.zig parseGraph /
;; graphToValue / graphToColumns / decodeGraphDelta / decodeGenericDelta.
;;
;; Graph data built by $parse_graph (all validation happens there):
;;   symbol (48 bytes): +0 id u64, +8 kind ptr, +12 kind len, +16 qname ptr,
;;     +20 qname len, +24 score f64, +32 provenance ptr, +36 prov len,
;;     +40 distance u64
;;   names: (ptr, len) pairs; names[i] is symbols[i].qname, then `@<id>`
;;     placeholders for session references, appended on first edge use
;;   edge (24 bytes): +0 source name index, +4 target name index,
;;     +8 type ptr, +12 type len, +16 status ptr, +20 status len

(global $FIELDS i32 (i32.const 0x7A40))   ;; up to 8 (ptr, len) graph fields of one line

(global $g_session (mut i32) (i32.const 0))
(global $g_syms (mut i32) (i32.const 0))
(global $g_nsyms (mut i32) (i32.const 0))
(global $g_names (mut i32) (i32.const 0))
(global $g_nnames (mut i32) (i32.const 0))
(global $g_edges (mut i32) (i32.const 0))
(global $g_nedges (mut i32) (i32.const 0))
(global $g_refs (mut i32) (i32.const 0))
(global $g_nrefs (mut i32) (i32.const 0))
(global $g_dense (mut i32) (i32.const 0))  ;; u32 per id below $g_ndense
(global $g_ndense (mut i32) (i32.const 0))
(global $g_sparse (mut i32) (i32.const 0)) ;; int map for larger ids

;; ---------------------------------------------------------------------------
;; Small helpers
;; ---------------------------------------------------------------------------

;; Header field value: (ptr, len, found).
(func $header_get (param $kp i32) (param $kn i32) (result i32 i32 i32)
  (local $j i32) (local $q i32)
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $j) (global.get $hdr_n)))
    (local.set $q (i32.add (global.get $hdr_pairs) (i32.shl (local.get $j) (i32.const 4))))
    (if (call $str_eq (i32.load (local.get $q)) (i32.load offset=4 (local.get $q)) (local.get $kp) (local.get $kn))
      (then (return (i32.load offset=8 (local.get $q)) (i32.load offset=12 (local.get $q)) (i32.const 1))))
    (local.set $j (i32.add (local.get $j) (i32.const 1)))
    (br $l)))
  (i32.const 0) (i32.const 0) (i32.const 0))

;; First index of the needle in the text, or -1.
(func $index_of (param $p i32) (param $n i32) (param $q i32) (param $qn i32) (result i32)
  (local $i i32)
  (if (i32.eqz (local.get $qn)) (then (return (i32.const 0))))
  (loop $l
    (local.set $i (call $find_byte (local.get $p) (local.get $n) (local.get $i) (i32.load8_u (local.get $q))))
    (if (i32.lt_s (local.get $i) (i32.const 0)) (then (return (i32.const -1))))
    (if (call $starts_with (i32.add (local.get $p) (local.get $i)) (i32.sub (local.get $n) (local.get $i)) (local.get $q) (local.get $qn))
      (then (return (local.get $i))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l))
  (unreachable))

;; std.fmt.parseInt(T, s, 10) exactly: optional '+'/'-', '_' between digits
;; (not first or last), overflow is an error; for unsigned T a '-' accepts
;; only zeros. Returns (value, ok).
(func $zig_parse_int (param $p i32) (param $n i32) (param $signed i32) (result i64 i32)
  (local $i i32) (local $neg i32) (local $acc i64) (local $c i32) (local $d i64)
  (if (i32.eqz (local.get $n)) (then (return (i64.const 0) (i32.const 0))))
  (local.set $c (i32.load8_u (local.get $p)))
  (if (i32.eq (local.get $c) (i32.const 0x2B)) (then (local.set $i (i32.const 1))))
  (if (i32.eq (local.get $c) (i32.const 0x2D)) (then (local.set $i (i32.const 1)) (local.set $neg (i32.const 1))))
  (if (i32.ge_u (local.get $i) (local.get $n)) (then (return (i64.const 0) (i32.const 0))))
  (if (i32.or (i32.eq (call $at (local.get $p) (local.get $i)) (i32.const 0x5F))
              (i32.eq (call $at (local.get $p) (i32.sub (local.get $n) (i32.const 1))) (i32.const 0x5F)))
    (then (return (i64.const 0) (i32.const 0))))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $c (call $at (local.get $p) (local.get $i)))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br_if $l (i32.eq (local.get $c) (i32.const 0x5F)))
    (if (i32.gt_u (i32.sub (local.get $c) (i32.const 0x30)) (i32.const 9)) (then (return (i64.const 0) (i32.const 0))))
    (local.set $d (i64.extend_i32_u (i32.sub (local.get $c) (i32.const 0x30))))
    (if (i32.and (local.get $neg) (i32.eqz (local.get $signed)))
      (then (if (i64.ne (local.get $d) (i64.const 0)) (then (return (i64.const 0) (i32.const 0)))) (br $l)))
    ;; magnitude must stay below 2^64 (unsigned), 2^63-1 (+) or 2^63 (-)
    (if (i32.or (i64.gt_u (local.get $acc) (i64.const 0x1999999999999999))
                (i32.and (i64.eq (local.get $acc) (i64.const 0x1999999999999999)) (i64.gt_u (local.get $d) (i64.const 5))))
      (then (return (i64.const 0) (i32.const 0))))
    (local.set $acc (i64.add (i64.mul (local.get $acc) (i64.const 10)) (local.get $d)))
    (if (local.get $signed)
      (then (if (i64.gt_u (local.get $acc) (i64.add (i64.const 0x7FFFFFFFFFFFFFFF) (i64.extend_i32_u (local.get $neg))))
        (then (return (i64.const 0) (i32.const 0))))))
    (br $l)))
  (if (i32.and (local.get $neg) (local.get $signed)) (then (return (i64.sub (i64.const 0) (local.get $acc)) (i32.const 1))))
  (local.get $acc) (i32.const 1))

;; Header integer field (absent = 0); malformed_header_field otherwise.
(func $header_int (param $kp i32) (param $kn i32) (result i64)
  (local $vp i32) (local $vn i32) (local $f i32) (local $v i64) (local $ok i32)
  (call $header_get (local.get $kp) (local.get $kn)) (local.set $f) (local.set $vn) (local.set $vp)
  (if (i32.eqz (local.get $f)) (then (return (i64.const 0))))
  (call $zig_parse_int (local.get $vp) (local.get $vn) (i32.const 1)) (local.set $ok) (local.set $v)
  (if (i32.eqz (local.get $ok)) (then (call $fail (i32.const 4) (i32.const 1))))
  (local.get $v))

;; Build an object on STK_MEMBERS: mark = (call $obj_begin), (call $obj_add ...), (call $obj_end mark).
(func $obj_begin (result i32) (call $stack_len (global.get $STK_MEMBERS)))
(func $obj_add (param $kp i32) (param $kn i32) (param $t i32) (param $a i32) (param $b i64)
  (local $q i32)
  (local.set $q (call $stack_push (global.get $STK_MEMBERS) (i32.const 24)))
  (if (local.get $q) (then (call $store_member (local.get $q) (local.get $kp) (local.get $kn) (local.get $t) (local.get $a) (local.get $b)))))
(func $obj_add_str (param $kp i32) (param $kn i32) (param $p i32) (param $n i32)
  (call $obj_add (local.get $kp) (local.get $kn) (i32.const 5) (local.get $p) (i64.extend_i32_u (local.get $n))))
(func $obj_end (param $mark i32) (result i32 i32 i64)
  (local $cnt i32)
  (local.set $cnt (i32.div_u (i32.sub (call $stack_len (global.get $STK_MEMBERS)) (local.get $mark)) (i32.const 24)))
  (i32.const 7) (call $stack_pop_to_arena (global.get $STK_MEMBERS) (local.get $mark)) (i64.extend_i32_u (local.get $cnt)))

;; ---------------------------------------------------------------------------
;; String map (string -> i32), for interning: 16-byte entries
;; (hash | 1, ptr, len, value), power-of-two capacity, at most half full.
;; Header (12 bytes): +0 count, +4 capacity, +8 table.
;; ---------------------------------------------------------------------------

(func $sm_grow (param $s i32)
  (local $old i32) (local $ocap i32) (local $cap i32) (local $t i32) (local $i i32) (local $e i32) (local $j i32) (local $d i32)
  (local.set $old (i32.load offset=8 (local.get $s)))
  (local.set $ocap (i32.load offset=4 (local.get $s)))
  (local.set $cap (select (i32.shl (local.get $ocap) (i32.const 1)) (i32.const 16) (local.get $ocap)))
  (local.set $t (call $alloc (i32.shl (local.get $cap) (i32.const 4))))
  (if (global.get $err) (then (return)))
  (global.set $pin (global.get $arena_top))
  (memory.fill (local.get $t) (i32.const 0) (i32.shl (local.get $cap) (i32.const 4)))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ocap)))
    (local.set $e (i32.add (local.get $old) (i32.shl (local.get $i) (i32.const 4))))
    (if (i32.load (local.get $e))
      (then
        (local.set $j (i32.and (i32.load (local.get $e)) (i32.sub (local.get $cap) (i32.const 1))))
        (block $pd (loop $pl
          (local.set $d (i32.add (local.get $t) (i32.shl (local.get $j) (i32.const 4))))
          (br_if $pd (i32.eqz (i32.load (local.get $d))))
          (local.set $j (i32.and (i32.add (local.get $j) (i32.const 1)) (i32.sub (local.get $cap) (i32.const 1))))
          (br $pl)))
        (v128.store (local.get $d) (v128.load (local.get $e)))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (i32.store offset=4 (local.get $s) (local.get $cap))
  (i32.store offset=8 (local.get $s) (local.get $t)))

;; Value for the key, or insert `val` and return -1 (when `insert` is set).
(func $sm_find (param $s i32) (param $p i32) (param $n i32) (param $insert i32) (param $val i32) (result i32)
  (local $h i32) (local $mask i32) (local $i i32) (local $e i32)
  (if (local.get $insert)
    (then (if (i32.ge_u (i32.shl (i32.add (i32.load (local.get $s)) (i32.const 1)) (i32.const 1)) (i32.load offset=4 (local.get $s)))
      (then (call $sm_grow (local.get $s)) (if (global.get $err) (then (return (i32.const -1))))))))
  (if (i32.eqz (i32.load offset=4 (local.get $s))) (then (return (i32.const -1))))
  (local.set $h (i32.or (call $hash (local.get $p) (local.get $n)) (i32.const 1)))
  (local.set $mask (i32.sub (i32.load offset=4 (local.get $s)) (i32.const 1)))
  (local.set $i (i32.and (local.get $h) (local.get $mask)))
  (loop $probe
    (local.set $e (i32.add (i32.load offset=8 (local.get $s)) (i32.shl (local.get $i) (i32.const 4))))
    (if (i32.eqz (i32.load (local.get $e)))
      (then
        (if (local.get $insert)
          (then
            (i32.store (local.get $e) (local.get $h))
            (i32.store offset=4 (local.get $e) (local.get $p))
            (i32.store offset=8 (local.get $e) (local.get $n))
            (i32.store offset=12 (local.get $e) (local.get $val))
            (i32.store (local.get $s) (i32.add (i32.load (local.get $s)) (i32.const 1)))))
        (return (i32.const -1))))
    (if (i32.eq (i32.load (local.get $e)) (local.get $h))
      (then (if (call $str_eq (i32.load offset=4 (local.get $e)) (i32.load offset=8 (local.get $e)) (local.get $p) (local.get $n))
        (then (return (i32.load offset=12 (local.get $e)))))))
    (local.set $i (i32.and (i32.add (local.get $i) (i32.const 1)) (local.get $mask)))
    (br $probe))
  (unreachable))

;; Interner: string map + ordered list of (ptr, len) on its own arena block.
;; Header (24 bytes): +0..12 string map, +12 list, +16 count, +20 capacity.
(func $interner_new (param $cap i32) (result i32)
  (local $s i32)
  (local.set $s (call $alloc (i32.const 24)))
  (if (global.get $err) (then (return (i32.const 0))))
  (memory.fill (local.get $s) (i32.const 0) (i32.const 24))
  (i32.store offset=12 (local.get $s) (call $alloc (i32.shl (i32.add (local.get $cap) (i32.const 1)) (i32.const 3))))
  (i32.store offset=20 (local.get $s) (local.get $cap))
  (local.get $s))

(func $intern (param $s i32) (param $p i32) (param $n i32) (result i32)
  (local $idx i32) (local $q i32)
  (local.set $idx (i32.load offset=16 (local.get $s)))
  (local.set $q (call $sm_find (local.get $s) (local.get $p) (local.get $n) (i32.const 1) (local.get $idx)))
  (if (i32.ge_s (local.get $q) (i32.const 0)) (then (return (local.get $q))))
  (local.set $q (i32.add (i32.load offset=12 (local.get $s)) (i32.shl (local.get $idx) (i32.const 3))))
  (i32.store (local.get $q) (local.get $p))
  (i32.store offset=4 (local.get $q) (local.get $n))
  (i32.store offset=16 (local.get $s) (i32.add (local.get $idx) (i32.const 1)))
  (local.get $idx))

;; ---------------------------------------------------------------------------
;; Integer map (u64 id -> u32): 16-byte entries (key, value, used).
;; Header (12 bytes): +0 count, +4 capacity, +8 table.
;; ---------------------------------------------------------------------------

(func $im_slot (param $t i32) (param $mask i32) (param $k i64) (result i32)
  (local $i i32) (local $e i32)
  (local.set $i (i32.and (i32.wrap_i64 (i64.shr_u (i64.mul (local.get $k) (i64.const 0x9E3779B97F4A7C15)) (i64.const 32))) (local.get $mask)))
  (loop $probe
    (local.set $e (i32.add (local.get $t) (i32.shl (local.get $i) (i32.const 4))))
    (if (i32.eqz (i32.load offset=12 (local.get $e))) (then (return (local.get $e))))
    (if (i64.eq (i64.load (local.get $e)) (local.get $k)) (then (return (local.get $e))))
    (local.set $i (i32.and (i32.add (local.get $i) (i32.const 1)) (local.get $mask)))
    (br $probe))
  (unreachable))

;; Entry for the key (inserting an empty one, which grows the map), or 0.
(func $im_entry (param $s i32) (param $k i64) (param $insert i32) (result i32)
  (local $cap i32) (local $old i32) (local $t i32) (local $i i32) (local $e i32) (local $d i32) (local $ocap i32)
  (if (i32.and (local.get $insert) (i32.ge_u (i32.shl (i32.add (i32.load (local.get $s)) (i32.const 1)) (i32.const 1)) (i32.load offset=4 (local.get $s))))
    (then
      (local.set $old (i32.load offset=8 (local.get $s)))
      (local.set $ocap (i32.load offset=4 (local.get $s)))
      (local.set $cap (select (i32.shl (local.get $ocap) (i32.const 1)) (i32.const 16) (local.get $ocap)))
      (local.set $t (call $alloc (i32.shl (local.get $cap) (i32.const 4))))
      (if (global.get $err) (then (return (i32.const 0))))
      (memory.fill (local.get $t) (i32.const 0) (i32.shl (local.get $cap) (i32.const 4)))
      (block $done (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $ocap)))
        (local.set $e (i32.add (local.get $old) (i32.shl (local.get $i) (i32.const 4))))
        (if (i32.load offset=12 (local.get $e))
          (then
            (local.set $d (call $im_slot (local.get $t) (i32.sub (local.get $cap) (i32.const 1)) (i64.load (local.get $e))))
            (v128.store (local.get $d) (v128.load (local.get $e)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (i32.store offset=4 (local.get $s) (local.get $cap))
      (i32.store offset=8 (local.get $s) (local.get $t))))
  (if (i32.eqz (i32.load offset=4 (local.get $s))) (then (return (i32.const 0))))
  (local.set $e (call $im_slot (i32.load offset=8 (local.get $s)) (i32.sub (i32.load offset=4 (local.get $s)) (i32.const 1)) (local.get $k)))
  (if (i32.load offset=12 (local.get $e)) (then (return (local.get $e))))
  (if (i32.eqz (local.get $insert)) (then (return (i32.const 0))))
  (i64.store (local.get $e) (local.get $k))
  (i32.store offset=8 (local.get $e) (i32.const -1))
  (i32.store offset=12 (local.get $e) (i32.const 1))
  (i32.store (local.get $s) (i32.add (i32.load (local.get $s)) (i32.const 1)))
  (local.get $e))

;; Symbol-ID table: dense for small IDs, int map for the rest.
;; Values: -1 none, -2 pending session reference, else a name index.
(func $id_get (param $id i64) (result i32)
  (local $e i32)
  (if (i64.lt_u (local.get $id) (i64.extend_i32_u (global.get $g_ndense)))
    (then (return (i32.load (i32.add (global.get $g_dense) (i32.shl (i32.wrap_i64 (local.get $id)) (i32.const 2)))))))
  (local.set $e (call $im_entry (global.get $g_sparse) (local.get $id) (i32.const 0)))
  (if (i32.eqz (local.get $e)) (then (return (i32.const -1))))
  (i32.load offset=8 (local.get $e)))

(func $id_set (param $id i64) (param $v i32)
  (local $e i32)
  (if (i64.lt_u (local.get $id) (i64.extend_i32_u (global.get $g_ndense)))
    (then (i32.store (i32.add (global.get $g_dense) (i32.shl (i32.wrap_i64 (local.get $id)) (i32.const 2))) (local.get $v)) (return)))
  (local.set $e (call $im_entry (global.get $g_sparse) (local.get $id) (i32.const 1)))
  (if (local.get $e) (then (i32.store offset=8 (local.get $e) (local.get $v)))))

;; Declare an ID; returns 0 when it was already declared.
(func $id_put (param $id i64) (param $v i32) (result i32)
  (if (i32.ne (call $id_get (local.get $id)) (i32.const -1)) (then (return (i32.const 0))))
  (call $id_set (local.get $id) (local.get $v))
  (i32.const 1))

;; ---------------------------------------------------------------------------
;; Graph line pieces
;; ---------------------------------------------------------------------------

;; Split on runs of spaces; stores up to `max` (ptr, len) pairs at $FIELDS and
;; returns the number of fields found (which may exceed `max`).
(func $graph_fields (param $p i32) (param $n i32) (param $max i32) (result i32)
  (local $i i32) (local $cnt i32) (local $e i32)
  (block $done (loop $l
    (block $sd (loop $sl
      (br_if $sd (i32.ge_u (local.get $i) (local.get $n)))
      (br_if $sd (i32.ne (call $at (local.get $p) (local.get $i)) (i32.const 0x20)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $sl)))
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $e (call $find_byte (local.get $p) (local.get $n) (local.get $i) (i32.const 0x20)))
    (if (i32.lt_s (local.get $e) (i32.const 0)) (then (local.set $e (local.get $n))))
    (if (i32.lt_u (local.get $cnt) (local.get $max))
      (then
        (i32.store (i32.add (global.get $FIELDS) (i32.shl (local.get $cnt) (i32.const 3))) (i32.add (local.get $p) (local.get $i)))
        (i32.store offset=4 (i32.add (global.get $FIELDS) (i32.shl (local.get $cnt) (i32.const 3))) (i32.sub (local.get $e) (local.get $i)))))
    (local.set $cnt (i32.add (local.get $cnt) (i32.const 1)))
    (local.set $i (local.get $e))
    (br $l)))
  (local.get $cnt))

(func $fp (param $k i32) (result i32) (i32.load (i32.add (global.get $FIELDS) (i32.shl (local.get $k) (i32.const 3)))))
(func $fn (param $k i32) (result i32) (i32.load offset=4 (i32.add (global.get $FIELDS) (i32.shl (local.get $k) (i32.const 3)))))

;; `@<digits>` -> u64 (invalid_symbol_id otherwise).
(func $parse_id (param $p i32) (param $n i32) (param $line i32) (result i64)
  (local $i i32) (local $v i64) (local $d i32)
  (if (i32.or (i32.or (i32.lt_u (local.get $n) (i32.const 2)) (i32.gt_u (local.get $n) (i32.const 20)))
              (i32.ne (i32.load8_u (local.get $p)) (i32.const 0x40)))
    (then (call $fail (i32.const 35) (local.get $line)) (return (i64.const 0))))
  (local.set $i (i32.const 1))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $d (i32.sub (call $at (local.get $p) (local.get $i)) (i32.const 0x30)))
    (if (i32.gt_u (local.get $d) (i32.const 9)) (then (call $fail (i32.const 35) (local.get $line)) (return (i64.const 0))))
    (if (i32.or (i64.gt_u (local.get $v) (i64.const 0x1999999999999999))
                (i32.and (i64.eq (local.get $v) (i64.const 0x1999999999999999)) (i32.gt_u (local.get $d) (i32.const 5))))
      (then (call $fail (i32.const 35) (local.get $line)) (return (i64.const 0))))
    (local.set $v (i64.add (i64.mul (local.get $v) (i64.const 10)) (i64.extend_i32_u (local.get $d))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.get $v))

;; score = [ "-" ] 1*DIGIT "." 2DIGIT
(func $is_score (param $p i32) (param $n i32) (result i32)
  (local $i i32) (local $d0 i32)
  (if (i32.and (i32.gt_u (local.get $n) (i32.const 0)) (i32.eq (i32.load8_u (local.get $p)) (i32.const 0x2D))) (then (local.set $i (i32.const 1))))
  (local.set $d0 (local.get $i))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (br_if $done (i32.eqz (call $is_digit (call $at (local.get $p) (local.get $i)))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (if (i32.or (i32.eq (local.get $i) (local.get $d0)) (i32.ne (i32.add (local.get $i) (i32.const 3)) (local.get $n))) (then (return (i32.const 0))))
  (if (i32.ne (call $at (local.get $p) (local.get $i)) (i32.const 0x2E)) (then (return (i32.const 0))))
  (i32.and (call $is_digit (call $at (local.get $p) (i32.add (local.get $i) (i32.const 1))))
           (call $is_digit (call $at (local.get $p) (i32.add (local.get $i) (i32.const 2))))))

;; Exact score value: cents / 100 is one correctly rounded IEEE division.
(func $score_value (param $p i32) (param $n i32) (result f64)
  (local $i i32) (local $neg i32) (local $cents i64) (local $c i32) (local $v f64)
  (if (i32.eq (i32.load8_u (local.get $p)) (i32.const 0x2D)) (then (local.set $neg (i32.const 1)) (local.set $i (i32.const 1))))
  (if (i32.gt_u (i32.sub (i32.sub (local.get $n) (local.get $i)) (i32.const 1)) (i32.const 15))
    (then (return (call $parse_f64 (local.get $p) (local.get $n) (i32.const 0)))))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $c (call $at (local.get $p) (local.get $i)))
    (if (i32.ne (local.get $c) (i32.const 0x2E))
      (then (local.set $cents (i64.add (i64.mul (local.get $cents) (i64.const 10)) (i64.extend_i32_u (i32.sub (local.get $c) (i32.const 0x30)))))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.set $v (f64.div (f64.convert_i64_u (local.get $cents)) (f64.const 100)))
  (select (f64.neg (local.get $v)) (local.get $v) (local.get $neg)))

;; Abbreviation -> full kind; unknown kinds pass through (SPEC §5).
(func $expand_kind (param $p i32) (param $n i32) (result i32 i32)
  (local $i i32) (local $e i32)
  (if (i32.eqz (local.get $n)) (then (return (local.get $p) (local.get $n))))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (i32.const 16)))
    (local.set $e (i32.add (i32.const 0x7C00) (i32.shl (local.get $i) (i32.const 4))))
    (if (call $str_eq (i32.load (local.get $e)) (i32.load offset=4 (local.get $e)) (local.get $p) (local.get $n))
      (then (return (i32.load offset=8 (local.get $e)) (i32.load offset=12 (local.get $e)))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.get $p) (local.get $n))

;; Full kind -> abbreviation (pack roots hash the wire form, SPEC §10.2).
(func $abbreviate_kind (param $p i32) (param $n i32) (result i32 i32)
  (local $i i32) (local $e i32)
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (i32.const 16)))
    (local.set $e (i32.add (i32.const 0x7C00) (i32.shl (local.get $i) (i32.const 4))))
    (if (call $str_eq (i32.load offset=8 (local.get $e)) (i32.load offset=12 (local.get $e)) (local.get $p) (local.get $n))
      (then (return (i32.load (local.get $e)) (i32.load offset=4 (local.get $e)))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.get $p) (local.get $n))

;; Node line `@id kind qname score provenance [distance]` into a 48-byte symbol.
(func $node_line (param $dst i32) (param $p i32) (param $n i32) (param $dist i64) (param $line i32) (param $with_dist i32)
  (local $cnt i32) (local $v i64) (local $ok i32)
  (local.set $cnt (call $graph_fields (local.get $p) (local.get $n) (i32.const 6)))
  (if (i32.ne (local.get $cnt) (i32.add (i32.const 5) (local.get $with_dist))) (then (call $fail (i32.const 34) (local.get $line)) (return)))
  (i64.store (local.get $dst) (call $parse_id (call $fp (i32.const 0)) (call $fn (i32.const 0)) (local.get $line)))
  (if (global.get $err) (then (return)))
  (if (i32.eqz (call $is_score (call $fp (i32.const 3)) (call $fn (i32.const 3)))) (then (call $fail (i32.const 36) (local.get $line)) (return)))
  (if (local.get $with_dist)
    (then
      (call $zig_parse_int (call $fp (i32.const 5)) (call $fn (i32.const 5)) (i32.const 0)) (local.set $ok) (local.set $dist)
      (if (i32.eqz (local.get $ok)) (then (call $fail (i32.const 40) (local.get $line)) (return)))))
  (i32.store offset=8 (local.get $dst) (call $fp (i32.const 1)))
  (i32.store offset=12 (local.get $dst) (call $fn (i32.const 1)))
  (i32.store offset=16 (local.get $dst) (call $fp (i32.const 2)))
  (i32.store offset=20 (local.get $dst) (call $fn (i32.const 2)))
  (f64.store offset=24 (local.get $dst) (call $score_value (call $fp (i32.const 3)) (call $fn (i32.const 3))))
  (i32.store offset=32 (local.get $dst) (call $fp (i32.const 4)))
  (i32.store offset=36 (local.get $dst) (call $fn (i32.const 4)))
  (i64.store offset=40 (local.get $dst) (local.get $dist)))

;; {qualifiedName, kind, score, provenance, distance}: written straight into
;; an exact-size arena block (no scratch stack round trip).
(func $symbol_value (param $s i32) (result i32 i32 i64)
  (local $m i32) (local $kp i32) (local $kn i32)
  (local.set $m (call $alloc (i32.const 120)))
  (if (global.get $err) (then (return (call $nil))))
  (call $expand_kind (i32.load offset=8 (local.get $s)) (i32.load offset=12 (local.get $s))) (local.set $kn) (local.set $kp)
  (call $store_member (local.get $m) (global.get $K_qualifiedName) (global.get $K_qualifiedName_n)
                      (i32.const 5) (i32.load offset=16 (local.get $s)) (i64.extend_i32_u (i32.load offset=20 (local.get $s))))
  (call $store_member (i32.add (local.get $m) (i32.const 24)) (global.get $K_kind) (global.get $K_kind_n) (i32.const 5) (local.get $kp) (i64.extend_i32_u (local.get $kn)))
  (call $store_member (i32.add (local.get $m) (i32.const 48)) (global.get $K_score) (global.get $K_score_n)
                      (i32.const 4) (i32.const 0) (i64.reinterpret_f64 (f64.load offset=24 (local.get $s))))
  (call $store_member (i32.add (local.get $m) (i32.const 72)) (global.get $K_provenance) (global.get $K_provenance_n)
                      (i32.const 5) (i32.load offset=32 (local.get $s)) (i64.extend_i32_u (i32.load offset=36 (local.get $s))))
  (call $store_member (i32.add (local.get $m) (i32.const 96)) (global.get $K_distance) (global.get $K_distance_n)
                      (i32.const 3) (i32.const 0) (i64.load offset=40 (local.get $s)))
  (i32.const 7) (local.get $m) (i64.const 5))

;; {source, target, edgeType[, status]}
(func $edge_value (param $sp i32) (param $sn i32) (param $tp i32) (param $tn i32) (param $yp i32) (param $yn i32) (param $stp i32) (param $stn i32) (param $has i32) (result i32 i32 i64)
  (local $m i32)
  (local.set $m (call $alloc (select (i32.const 96) (i32.const 72) (local.get $has))))
  (if (global.get $err) (then (return (call $nil))))
  (call $store_member (local.get $m) (global.get $K_source) (global.get $K_source_n) (i32.const 5) (local.get $sp) (i64.extend_i32_u (local.get $sn)))
  (call $store_member (i32.add (local.get $m) (i32.const 24)) (global.get $K_target) (global.get $K_target_n) (i32.const 5) (local.get $tp) (i64.extend_i32_u (local.get $tn)))
  (call $store_member (i32.add (local.get $m) (i32.const 48)) (global.get $K_edgeType) (global.get $K_edgeType_n) (i32.const 5) (local.get $yp) (i64.extend_i32_u (local.get $yn)))
  (if (local.get $has)
    (then (call $store_member (i32.add (local.get $m) (i32.const 72)) (global.get $K_status) (global.get $K_status_n) (i32.const 5) (local.get $stp) (i64.extend_i32_u (local.get $stn)))))
  (i32.const 7) (local.get $m) (select (i64.const 4) (i64.const 3) (local.get $has)))

;; ---------------------------------------------------------------------------
;; Non-delta graph payload
;; ---------------------------------------------------------------------------

;; Name index of an edge endpoint: a declared symbol, or a session reference
;; (named `@<id>` on first use).
(func $endpoint (param $id i64) (param $line i32) (result i32)
  (local $v i32) (local $idx i32) (local $q i32) (local $dp i32) (local $dn i32)
  (local.set $v (call $id_get (local.get $id)))
  (if (i32.eq (local.get $v) (i32.const -1)) (then (call $fail (i32.const 38) (local.get $line)) (return (i32.const 0))))
  (if (i32.ne (local.get $v) (i32.const -2)) (then (return (local.get $v))))
  (call $u64_digits (local.get $id)) (local.set $dn) (local.set $dp)
  (local.set $q (call $alloc (i32.add (local.get $dn) (i32.const 1))))
  (if (global.get $err) (then (return (i32.const 0))))
  (i32.store8 (local.get $q) (i32.const 0x40))
  (memory.copy (i32.add (local.get $q) (i32.const 1)) (local.get $dp) (local.get $dn))
  (local.set $idx (global.get $g_nnames))
  (i32.store (i32.add (global.get $g_names) (i32.shl (local.get $idx) (i32.const 3))) (local.get $q))
  (i32.store offset=4 (i32.add (global.get $g_names) (i32.shl (local.get $idx) (i32.const 3))) (i32.add (local.get $dn) (i32.const 1)))
  (global.set $g_nnames (i32.add (local.get $idx) (i32.const 1)))
  (call $id_set (local.get $id) (local.get $idx))
  (local.get $idx))

;; Section count check (count < 0: deferred or none).
(func $close_section (param $hasc i32) (param $c i64) (param $items i64) (param $line i32)
  (if (i32.and (local.get $hasc) (i64.ne (local.get $c) (local.get $items))) (then (call $fail (i32.const 18) (local.get $line)))))

(func $parse_graph
  (local $cap i32) (local $i i32) (local $l i32) (local $t i32) (local $tn i32) (local $no i32)
  (local $section i32) (local $dist i64) (local $hasc i32) (local $cnt i64) (local $items i64) (local $sline i32)
  (local $deferred i32) (local $groups i32) (local $k i32) (local $s i32) (local $e i32) (local $rp i32) (local $rn i32)
  (local $sp i32) (local $np i32) (local $nn i32) (local $close i32) (local $v i64) (local $ok i32) (local $id i64)
  (local $nf i32) (local $lt i32) (local $tid i64) (local $sid i64) (local $tq i32) (local $sq i32) (local $q i32) (local $f0p i32) (local $f0n i32)
  (local $yp i32) (local $yn i32) (local $stp i32) (local $stn i32) (local $tok i32) (local $te i32)
  (global.set $g_session (call $header_flag (global.get $K_session) (global.get $K_session_n)))
  (local.set $cap (i32.add (global.get $nlines) (i32.const 1)))
  (global.set $g_syms (call $alloc (i32.mul (local.get $cap) (i32.const 48))))
  (global.set $g_names (call $alloc (i32.shl (local.get $cap) (i32.const 3))))
  (global.set $g_edges (call $alloc (i32.mul (local.get $cap) (i32.const 24))))
  (global.set $g_refs (call $alloc (i32.shl (local.get $cap) (i32.const 3))))
  (global.set $g_dense (call $alloc (i32.shl (local.get $cap) (i32.const 2))))
  (global.set $g_sparse (call $ks_new))
  (local.set $groups (call $ks_new))
  (if (global.get $err) (then (return)))
  (global.set $g_ndense (local.get $cap))
  (memory.fill (global.get $g_dense) (i32.const 0xFF) (i32.shl (local.get $cap) (i32.const 2)))
  (global.set $g_nsyms (i32.const 0)) (global.set $g_nnames (i32.const 0)) (global.set $g_nedges (i32.const 0)) (global.set $g_nrefs (i32.const 0))
  (block $done (loop $next
    (br_if $done (i32.ge_u (local.get $i) (global.get $nlines)))
    (local.set $l (i32.add (global.get $lines) (i32.shl (local.get $i) (i32.const 4))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (local.set $t (call $lt (local.get $l))) (local.set $tn (call $ltn (local.get $l))) (local.set $no (call $lno (local.get $l)))
    (if (call $lind (local.get $l)) (then (call $fail (i32.const 21) (local.get $no)) (return)))
    (block $content
    ;; header lines start with '#': skip both prefix checks for node and edge lines
    (if (i32.ne (i32.load8_u (local.get $t)) (i32.const 0x23)) (then (br $content)))
    ;; summary trailer
    (if (call $lstarts (local.get $l) (global.get $S_SUMMARY) (i32.const 3))
      (then
        (call $close_section (local.get $hasc) (local.get $cnt) (local.get $items) (local.get $sline))
        (if (global.get $err) (then (return)))
        (local.set $section (i32.const 0)) (local.set $hasc (i32.const 0))
        (if (i32.eqz (call $lstarts (local.get $l) (global.get $S_SUMMARY) (i32.const 11))) (then (call $fail (i32.const 29) (local.get $no)) (return)))
        (if (i32.lt_u (local.get $i) (global.get $nlines))
          (then (call $fail (i32.const 29) (call $lno (i32.add (global.get $lines) (i32.shl (local.get $i) (i32.const 4))))) (return)))
        ;; graph trailer counts are informational; edges= is checked against a deferred edges section
        (local.set $tok (i32.const 11))
        (block $td (loop $tl
          (block $sd (loop $sl
            (br_if $sd (i32.ge_u (local.get $tok) (local.get $tn)))
            (br_if $sd (i32.ne (call $at (local.get $t) (local.get $tok)) (i32.const 0x20)))
            (local.set $tok (i32.add (local.get $tok) (i32.const 1)))
            (br $sl)))
          (br_if $td (i32.ge_u (local.get $tok) (local.get $tn)))
          (local.set $te (call $find_byte (local.get $t) (local.get $tn) (local.get $tok) (i32.const 0x20)))
          (if (i32.lt_s (local.get $te) (i32.const 0)) (then (local.set $te (local.get $tn))))
          (if (i32.and (local.get $deferred)
                       (call $starts_with (i32.add (local.get $t) (local.get $tok)) (i32.sub (local.get $te) (local.get $tok)) (global.get $K_edges_eq) (i32.const 6)))
            (then
              (call $zig_parse_int (i32.add (local.get $t) (i32.add (local.get $tok) (i32.const 6))) (i32.sub (i32.sub (local.get $te) (local.get $tok)) (i32.const 6)) (i32.const 0))
              (local.set $ok) (local.set $v)
              (if (i32.and (local.get $ok) (i64.ne (local.get $v) (i64.extend_i32_u (global.get $g_nedges))))
                (then (call $fail (i32.const 18) (local.get $no)) (return)))))
          (local.set $tok (local.get $te))
          (br $tl)))
        (br $next)))
    ;; group header
    (if (call $lstarts (local.get $l) (global.get $S_SECTION) (i32.const 3))
      (then
        (call $close_section (local.get $hasc) (local.get $cnt) (local.get $items) (local.get $sline))
        (if (global.get $err) (then (return)))
        (local.set $items (i64.const 0)) (local.set $hasc (i32.const 0)) (local.set $sline (local.get $no))
        (local.set $rp (i32.add (local.get $t) (i32.const 3)))
        (local.set $rn (i32.sub (local.get $tn) (i32.const 3)))
        (local.set $sp (call $find_byte (local.get $rp) (local.get $rn) (i32.const 0) (i32.const 0x20)))
        (local.set $np (local.get $rp))
        (if (i32.ge_s (local.get $sp) (i32.const 0))
          (then
            (local.set $nn (local.get $sp))
            (local.set $rp (i32.add (local.get $rp) (i32.add (local.get $sp) (i32.const 1))))
            (local.set $rn (i32.sub (local.get $rn) (i32.add (local.get $sp) (i32.const 1)))))
          (else (local.set $nn (local.get $rn)) (local.set $rn (i32.const 0))))
        (if (local.get $rn)
          (then
            (if (i32.ne (i32.load8_u (local.get $rp)) (i32.const 0x5B)) (then (call $fail (i32.const 29) (local.get $no)) (return)))
            (local.set $close (call $find_byte (local.get $rp) (local.get $rn) (i32.const 0) (i32.const 0x5D)))
            (if (i32.lt_s (local.get $close) (i32.const 0)) (then (call $fail (i32.const 19) (local.get $no)) (return)))
            (if (i32.and (i32.eq (local.get $close) (i32.const 2)) (i32.eq (call $at (local.get $rp) (i32.const 1)) (i32.const 0x3F)))
              (then
                (if (call $str_eq (local.get $np) (local.get $nn) (global.get $K_edges) (global.get $K_edges_n)) (then (local.set $deferred (i32.const 1)))))
              (else
                (local.set $cnt (call $count (i32.add (local.get $rp) (i32.const 1)) (i32.sub (local.get $close) (i32.const 1)) (local.get $no)))
                (if (global.get $err) (then (return)))
                (local.set $hasc (i32.const 1))))))
        (if (call $ks_insert (local.get $groups) (local.get $np) (local.get $nn)) (then (call $fail (i32.const 15) (local.get $no)) (return)))
        (if (call $str_eq (local.get $np) (local.get $nn) (global.get $K_edges) (global.get $K_edges_n))
          (then (local.set $section (i32.const 2)) (br $next)))
        (local.set $section (i32.const 1))
        (if (call $str_eq (local.get $np) (local.get $nn) (global.get $K_targets) (global.get $K_targets_n)) (then (local.set $dist (i64.const 0)) (br $next)))
        (if (call $str_eq (local.get $np) (local.get $nn) (global.get $K_related) (global.get $K_related_n)) (then (local.set $dist (i64.const 1)) (br $next)))
        (if (call $str_eq (local.get $np) (local.get $nn) (global.get $K_extended) (global.get $K_extended_n)) (then (local.set $dist (i64.const 2)) (br $next)))
        (if (i32.and (call $starts_with (local.get $np) (local.get $nn) (global.get $K_distance_) (global.get $K_distance__n)) (i32.gt_u (local.get $nn) (i32.const 9)))
          (then
            (call $zig_parse_int (i32.add (local.get $np) (i32.const 9)) (i32.sub (local.get $nn) (i32.const 9)) (i32.const 0)) (local.set $ok) (local.set $dist)
            (if (i32.eqz (local.get $ok)) (then (call $fail (i32.const 39) (local.get $no)) (return)))
            (br $next)))
        (if (i32.or (i32.or (call $str_eq (local.get $np) (local.get $nn) (global.get $K_removed) (global.get $K_removed_n))
                            (call $str_eq (local.get $np) (local.get $nn) (global.get $K_added) (global.get $K_added_n)))
                    (i32.or (call $str_eq (local.get $np) (local.get $nn) (global.get $K_edges_removed) (global.get $K_edges_removed_n))
                            (call $str_eq (local.get $np) (local.get $nn) (global.get $K_edges_added) (global.get $K_edges_added_n))))
          (then (call $fail (i32.const 40) (local.get $no)) (return)))
        (call $fail (i32.const 39) (local.get $no))
        (return))))
    (if (i32.eqz (local.get $section)) (then (call $fail (i32.const 29) (local.get $no)) (return)))
    (if (i32.eq (local.get $section) (i32.const 1))
      (then
        (if (i32.ne (i32.load8_u (local.get $t)) (i32.const 0x40)) (then (call $fail (i32.const 34) (local.get $no)) (return)))
        ;; session reference: "@<id>  # previously transmitted"
        (if (i32.ge_u (call $graph_fields (local.get $t) (local.get $tn) (i32.const 2)) (i32.const 2))
          (then (if (i32.and (call $str_eq (call $fp (i32.const 1)) (call $fn (i32.const 1)) (global.get $K_hash) (i32.const 1))
                             (i32.ge_s (call $index_of (local.get $t) (local.get $tn) (global.get $K_prev_tx) (global.get $K_prev_tx_n)) (i32.const 0)))
            (then
              (local.set $id (call $parse_id (call $fp (i32.const 0)) (call $fn (i32.const 0)) (local.get $no)))
              (if (global.get $err) (then (return)))
              (if (i32.eqz (global.get $g_session)) (then (call $fail (i32.const 34) (local.get $no)) (return)))
              (if (i32.eqz (call $id_put (local.get $id) (i32.const -2))) (then (call $fail (i32.const 35) (local.get $no)) (return)))
              (if (global.get $err) (then (return)))
              (i64.store (i32.add (global.get $g_refs) (i32.shl (global.get $g_nrefs) (i32.const 3))) (local.get $id))
              (global.set $g_nrefs (i32.add (global.get $g_nrefs) (i32.const 1)))
              (local.set $items (i64.add (local.get $items) (i64.const 1)))
              (br $next)))))
        (local.set $s (i32.add (global.get $g_syms) (i32.mul (global.get $g_nsyms) (i32.const 48))))
        (call $node_line (local.get $s) (local.get $t) (local.get $tn) (local.get $dist) (local.get $no) (i32.const 0))
        (if (global.get $err) (then (return)))
        (if (i32.eqz (call $id_put (i64.load (local.get $s)) (global.get $g_nsyms))) (then (call $fail (i32.const 35) (local.get $no)) (return)))
        (if (global.get $err) (then (return)))
        (call $push_name (i32.load offset=16 (local.get $s)) (i32.load offset=20 (local.get $s)))
        (global.set $g_nsyms (i32.add (global.get $g_nsyms) (i32.const 1)))
        (local.set $items (i64.add (local.get $items) (i64.const 1)))
        (br $next)))
    ;; edges
    (local.set $nf (call $graph_fields (local.get $t) (local.get $tn) (i32.const 3)))
    (local.set $f0p (call $fp (i32.const 0))) (local.set $f0n (call $fn (i32.const 0)))
    (local.set $yp (call $fp (i32.const 1))) (local.set $yn (call $fn (i32.const 1)))
    (local.set $stp (call $fp (i32.const 2))) (local.set $stn (call $fn (i32.const 2)))
    (local.set $lt (call $find_byte (local.get $f0p) (local.get $f0n) (i32.const 0) (i32.const 0x3C)))
    (if (i32.lt_s (local.get $lt) (i32.const 0)) (then (call $fail (i32.const 37) (local.get $no)) (return)))
    (if (i32.or (i32.lt_u (local.get $nf) (i32.const 2)) (i32.gt_u (local.get $nf) (i32.const 3))) (then (call $fail (i32.const 37) (local.get $no)) (return)))
    (local.set $tid (call $parse_id (local.get $f0p) (local.get $lt) (local.get $no)))
    (if (global.get $err) (then (return)))
    (local.set $sid (call $parse_id (i32.add (local.get $f0p) (i32.add (local.get $lt) (i32.const 1))) (i32.sub (local.get $f0n) (i32.add (local.get $lt) (i32.const 1))) (local.get $no)))
    (if (global.get $err) (then (return)))
    (local.set $tq (call $endpoint (local.get $tid) (local.get $no)))
    (if (global.get $err) (then (return)))
    (local.set $sq (call $endpoint (local.get $sid) (local.get $no)))
    (if (global.get $err) (then (return)))
    (local.set $q (i32.add (global.get $g_edges) (i32.mul (global.get $g_nedges) (i32.const 24))))
    (i32.store (local.get $q) (local.get $sq))
    (i32.store offset=4 (local.get $q) (local.get $tq))
    (i32.store offset=8 (local.get $q) (local.get $yp))
    (i32.store offset=12 (local.get $q) (local.get $yn))
    (i32.store offset=16 (local.get $q) (select (local.get $stp) (i32.const 0) (i32.eq (local.get $nf) (i32.const 3))))
    (i32.store offset=20 (local.get $q) (select (local.get $stn) (i32.const 0) (i32.eq (local.get $nf) (i32.const 3))))
    (global.set $g_nedges (i32.add (global.get $g_nedges) (i32.const 1)))
    (local.set $items (i64.add (local.get $items) (i64.const 1)))
    (br $next)))
  (call $close_section (local.get $hasc) (local.get $cnt) (local.get $items) (local.get $sline)))

(func $push_name (param $p i32) (param $n i32)
  (i32.store (i32.add (global.get $g_names) (i32.shl (global.get $g_nnames) (i32.const 3))) (local.get $p))
  (i32.store offset=4 (i32.add (global.get $g_names) (i32.shl (global.get $g_nnames) (i32.const 3))) (local.get $n))
  (global.set $g_nnames (i32.add (global.get $g_nnames) (i32.const 1))))

(func $name_p (param $i i32) (result i32) (i32.load (i32.add (global.get $g_names) (i32.shl (local.get $i) (i32.const 3)))))
(func $name_n (param $i i32) (result i32) (i32.load offset=4 (i32.add (global.get $g_names) (i32.shl (local.get $i) (i32.const 3)))))

;; Header string field, or "" when absent.
(func $header_str (param $kp i32) (param $kn i32) (result i32 i32)
  (local $p i32) (local $n i32) (local $f i32)
  (call $header_get (local.get $kp) (local.get $kn)) (local.set $f) (local.set $n) (local.set $p)
  (local.get $p) (local.get $n))

;; Spec-shaped value tree of the parsed graph.
(func $graph_to_value (result i32 i32 i64)
  (local $mark i32) (local $syms i32) (local $edges i32) (local $i i32) (local $e i32) (local $p i32) (local $n i32)
  (local $vt i32) (local $va i32) (local $vb i64) (local $budget i64) (local $tokens i64) (local $r i32)
  (local.set $budget (call $header_int (global.get $K_budget) (global.get $K_budget_n)))
  (if (global.get $err) (then (return (call $nil))))
  (local.set $tokens (call $header_int (global.get $K_tokens) (global.get $K_tokens_n)))
  (if (global.get $err) (then (return (call $nil))))
  (local.set $syms (call $alloc (i32.shl (global.get $g_nsyms) (i32.const 4))))
  (local.set $edges (call $alloc (i32.shl (global.get $g_nedges) (i32.const 4))))
  (if (global.get $err) (then (return (call $nil))))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (global.get $g_nsyms)))
    (call $symbol_value (i32.add (global.get $g_syms) (i32.mul (local.get $i) (i32.const 48))))
    (local.set $vb) (local.set $va) (local.set $vt)
    (call $store_node (i32.add (local.get $syms) (i32.shl (local.get $i) (i32.const 4))) (local.get $vt) (local.get $va) (local.get $vb))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (global.get $g_nedges)))
    (local.set $e (i32.add (global.get $g_edges) (i32.mul (local.get $i) (i32.const 24))))
    ;; the Zig decoder always emits "status" ("" when the line has none)
    (call $edge_value (call $name_p (i32.load (local.get $e))) (call $name_n (i32.load (local.get $e)))
                      (call $name_p (i32.load offset=4 (local.get $e))) (call $name_n (i32.load offset=4 (local.get $e)))
                      (i32.load offset=8 (local.get $e)) (i32.load offset=12 (local.get $e))
                      (i32.load offset=16 (local.get $e)) (i32.load offset=20 (local.get $e)) (i32.const 1))
    (local.set $vb) (local.set $va) (local.set $vt)
    (call $store_node (i32.add (local.get $edges) (i32.shl (local.get $i) (i32.const 4))) (local.get $vt) (local.get $va) (local.get $vb))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.set $mark (call $obj_begin))
  (call $header_str (global.get $K_tool) (global.get $K_tool_n)) (local.set $n) (local.set $p)
  (call $obj_add_str (global.get $K_tool) (global.get $K_tool_n) (local.get $p) (local.get $n))
  (call $obj_add (global.get $K_tokenBudget) (global.get $K_tokenBudget_n) (i32.const 3) (i32.const 0) (local.get $budget))
  (call $obj_add (global.get $K_tokensUsed) (global.get $K_tokensUsed_n) (i32.const 3) (i32.const 0) (local.get $tokens))
  (call $header_str (global.get $K_pack_root) (global.get $K_pack_root_n)) (local.set $n) (local.set $p)
  (call $obj_add_str (global.get $K_packRoot) (global.get $K_packRoot_n) (local.get $p) (local.get $n))
  (if (call $header_flag (global.get $K_unchanged) (global.get $K_unchanged_n))
    (then (call $obj_add (global.get $K_unchanged) (global.get $K_unchanged_n) (i32.const 2) (i32.const 0) (i64.const 0))))
  (if (global.get $g_session) (then (call $obj_add (global.get $K_session) (global.get $K_session_n) (i32.const 2) (i32.const 0) (i64.const 0))))
  (call $obj_add (global.get $K_symbols) (global.get $K_symbols_n) (i32.const 6) (local.get $syms) (i64.extend_i32_u (global.get $g_nsyms)))
  (call $obj_add (global.get $K_edges) (global.get $K_edges_n) (i32.const 6) (local.get $edges) (i64.extend_i32_u (global.get $g_nedges)))
  (if (global.get $g_nrefs)
    (then
      (local.set $r (call $alloc (i32.shl (global.get $g_nrefs) (i32.const 4))))
      (if (global.get $err) (then (return (call $nil))))
      (local.set $i (i32.const 0))
      (block $done (loop $l
        (br_if $done (i32.ge_u (local.get $i) (global.get $g_nrefs)))
        (call $store_node (i32.add (local.get $r) (i32.shl (local.get $i) (i32.const 4))) (i32.const 3) (i32.const 0)
                          (i64.load (i32.add (global.get $g_refs) (i32.shl (local.get $i) (i32.const 3)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (call $obj_add (global.get $K_references) (global.get $K_references_n) (i32.const 6) (local.get $r) (i64.extend_i32_u (global.get $g_nrefs)))))
  (call $obj_end (local.get $mark)))

;; ---------------------------------------------------------------------------
;; Columnar JSON (gcf_decode_graph_columns, rebuilt into objects by host.ts)
;; ---------------------------------------------------------------------------

(func $w_lit (param $p i32) (param $n i32)
  (call $w_need (i32.add (local.get $n) (i32.const 16)))
  (call $copy_short (global.get $wp) (local.get $p) (local.get $n))
  (global.set $wp (i32.add (global.get $wp) (local.get $n))))

;; `,"key":`
(func $w_key (param $p i32) (param $n i32)
  (call $w_need (i32.add (local.get $n) (i32.const 20)))
  (call $w_byte (i32.const 0x2C))
  (call $w_byte (i32.const 0x22))
  (call $copy_short (global.get $wp) (local.get $p) (local.get $n))
  (global.set $wp (i32.add (global.get $wp) (local.get $n)))
  (call $w_byte (i32.const 0x22))
  (call $w_byte (i32.const 0x3A)))

(func $w_str (param $p i32) (param $n i32)
  (call $w_need (i32.add (i32.mul (local.get $n) (i32.const 6)) (i32.const 18)))
  (call $w_string (local.get $p) (local.get $n)))

;; `,"key":["a","b",...]` from a (ptr, len) list
(func $w_str_list (param $kp i32) (param $kn i32) (param $list i32) (param $n i32)
  (local $i i32) (local $q i32)
  (call $w_key (local.get $kp) (local.get $kn))
  (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x5B))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (if (local.get $i) (then (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x2C))))
    (local.set $q (i32.add (local.get $list) (i32.shl (local.get $i) (i32.const 3))))
    (call $w_str (i32.load (local.get $q)) (i32.load offset=4 (local.get $q)))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x5D)))

;; `,"key":[1,2,...]` from u32 values at `base + i*stride`
(func $w_int_list (param $kp i32) (param $kn i32) (param $base i32) (param $stride i32) (param $n i32)
  (local $i i32)
  (call $w_key (local.get $kp) (local.get $kn))
  (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x5B))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (if (local.get $i) (then (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x2C))))
    (call $w_i64 (i64.load32_u (i32.add (local.get $base) (i32.mul (local.get $i) (local.get $stride)))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x5D)))

(func $graph_to_columns
  (local $kinds i32) (local $provs i32) (local $types i32) (local $statuses i32) (local $ix i32) (local $i i32) (local $s i32) (local $e i32)
  (local $kp i32) (local $kn i32) (local $p i32) (local $n i32) (local $budget i64) (local $tokens i64)
  (local.set $kinds (call $interner_new (global.get $g_nsyms)))
  (local.set $provs (call $interner_new (global.get $g_nsyms)))
  (local.set $types (call $interner_new (global.get $g_nedges)))
  (local.set $statuses (call $interner_new (global.get $g_nedges)))
  ;; per symbol: k (kind index), p (provenance index); per edge: ty, st
  (local.set $ix (call $alloc (i32.add (i32.shl (global.get $g_nsyms) (i32.const 3)) (i32.shl (global.get $g_nedges) (i32.const 3)))))
  (if (global.get $err) (then (return)))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (global.get $g_nsyms)))
    (local.set $s (i32.add (global.get $g_syms) (i32.mul (local.get $i) (i32.const 48))))
    (call $expand_kind (i32.load offset=8 (local.get $s)) (i32.load offset=12 (local.get $s))) (local.set $kn) (local.set $kp)
    (i32.store (i32.add (local.get $ix) (i32.shl (local.get $i) (i32.const 3))) (call $intern (local.get $kinds) (local.get $kp) (local.get $kn)))
    (i32.store offset=4 (i32.add (local.get $ix) (i32.shl (local.get $i) (i32.const 3)))
      (call $intern (local.get $provs) (i32.load offset=32 (local.get $s)) (i32.load offset=36 (local.get $s))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (global.get $g_nedges)))
    (local.set $e (i32.add (global.get $g_edges) (i32.mul (local.get $i) (i32.const 24))))
    (local.set $p (i32.add (local.get $ix) (i32.add (i32.shl (global.get $g_nsyms) (i32.const 3)) (i32.shl (local.get $i) (i32.const 3)))))
    (i32.store (local.get $p) (call $intern (local.get $types) (i32.load offset=8 (local.get $e)) (i32.load offset=12 (local.get $e))))
    (i32.store offset=4 (local.get $p) (call $intern (local.get $statuses) (i32.load offset=16 (local.get $e)) (i32.load offset=20 (local.get $e))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (if (global.get $err) (then (return)))
  (local.set $budget (call $header_int (global.get $K_budget) (global.get $K_budget_n)))
  (if (global.get $err) (then (return)))
  (local.set $tokens (call $header_int (global.get $K_tokens) (global.get $K_tokens_n)))
  (if (global.get $err) (then (return)))
  (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x7B))
  ;; "tool" first (no leading comma)
  (call $w_need (i32.const 8)) (call $w_byte (i32.const 0x22))
  (call $w_lit (global.get $K_tool) (global.get $K_tool_n))
  (call $w_need (i32.const 2)) (call $w_byte (i32.const 0x22)) (call $w_byte (i32.const 0x3A))
  (call $header_str (global.get $K_tool) (global.get $K_tool_n)) (local.set $n) (local.set $p)
  (call $w_str (local.get $p) (local.get $n))
  (call $w_key (global.get $K_tokenBudget) (global.get $K_tokenBudget_n)) (call $w_i64 (local.get $budget))
  (call $w_key (global.get $K_tokensUsed) (global.get $K_tokensUsed_n)) (call $w_i64 (local.get $tokens))
  (call $w_key (global.get $K_packRoot) (global.get $K_packRoot_n))
  (call $header_str (global.get $K_pack_root) (global.get $K_pack_root_n)) (local.set $n) (local.set $p)
  (call $w_str (local.get $p) (local.get $n))
  (if (call $header_flag (global.get $K_unchanged) (global.get $K_unchanged_n))
    (then (call $w_key (global.get $K_unchanged) (global.get $K_unchanged_n)) (call $w_lit (global.get $S_TRUE) (i32.const 4))))
  (if (global.get $g_session)
    (then (call $w_key (global.get $K_session) (global.get $K_session_n)) (call $w_lit (global.get $S_TRUE) (i32.const 4))))
  (call $w_str_list (global.get $K_names) (global.get $K_names_n) (global.get $g_names) (global.get $g_nnames))
  (call $w_str_list (global.get $K_kinds) (global.get $K_kinds_n) (i32.load offset=12 (local.get $kinds)) (i32.load offset=16 (local.get $kinds)))
  (call $w_str_list (global.get $K_provs) (global.get $K_provs_n) (i32.load offset=12 (local.get $provs)) (i32.load offset=16 (local.get $provs)))
  (call $w_str_list (global.get $K_types) (global.get $K_types_n) (i32.load offset=12 (local.get $types)) (i32.load offset=16 (local.get $types)))
  (call $w_str_list (global.get $K_statuses) (global.get $K_statuses_n) (i32.load offset=12 (local.get $statuses)) (i32.load offset=16 (local.get $statuses)))
  (call $w_int_list (global.get $K_c_k) (i32.const 1) (local.get $ix) (i32.const 8) (global.get $g_nsyms))
  (call $w_int_list (global.get $K_c_p) (i32.const 1) (i32.add (local.get $ix) (i32.const 4)) (i32.const 8) (global.get $g_nsyms))
  (call $w_int_list (global.get $K_c_es) (i32.const 2) (global.get $g_edges) (i32.const 24) (global.get $g_nedges))
  (call $w_int_list (global.get $K_c_et) (i32.const 2) (i32.add (global.get $g_edges) (i32.const 4)) (i32.const 24) (global.get $g_nedges))
  (local.set $p (i32.add (local.get $ix) (i32.shl (global.get $g_nsyms) (i32.const 3))))
  (call $w_int_list (global.get $K_c_ty) (i32.const 2) (local.get $p) (i32.const 8) (global.get $g_nedges))
  (call $w_int_list (global.get $K_c_st) (i32.const 2) (i32.add (local.get $p) (i32.const 4)) (i32.const 8) (global.get $g_nedges))
  (call $w_key (global.get $K_c_s) (i32.const 1))
  (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x5B))
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (global.get $g_nsyms)))
    (if (local.get $i) (then (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x2C))))
    (call $w_f64 (f64.load offset=24 (i32.add (global.get $g_syms) (i32.mul (local.get $i) (i32.const 48)))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x5D))
  (call $w_key (global.get $K_c_d) (i32.const 1))
  (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x5B))
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (global.get $g_nsyms)))
    (if (local.get $i) (then (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x2C))))
    (call $w_i64 (i64.load offset=40 (i32.add (global.get $g_syms) (i32.mul (local.get $i) (i32.const 48)))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x5D))
  (if (global.get $g_nrefs)
    (then
      (call $w_key (global.get $K_references) (global.get $K_references_n))
      (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x5B))
      (local.set $i (i32.const 0))
      (block $done (loop $l
        (br_if $done (i32.ge_u (local.get $i) (global.get $g_nrefs)))
        (if (local.get $i) (then (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x2C))))
        (call $w_i64 (i64.load (i32.add (global.get $g_refs) (i32.shl (local.get $i) (i32.const 3)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x5D))))
  (call $w_need (i32.const 1)) (call $w_byte (i32.const 0x7D)))

;; ---------------------------------------------------------------------------
;; Graph delta payload (SPEC §10.1)
;; ---------------------------------------------------------------------------

(func $graph_delta (result i32 i32 i64)
  (local $i i32) (local $l i32) (local $t i32) (local $tn i32) (local $no i32) (local $sec i32) (local $nf i32)
  (local $marks i32) (local $q i32) (local $vt i32) (local $va i32) (local $vb i64) (local $kp i32) (local $kn i32) (local $mark i32)
  (local $s i32) (local $k i32) (local $p i32) (local $n i32) (local $cnt i32)
  ;; four node lists (removed, added, edges_removed, edges_added) on STK_NODES,
  ;; kept as separate arena blocks: collect per section into STK_SLOTS records
  ;; (section, node) and split at the end
  (local.set $marks (call $stack_len (global.get $STK_SLOTS)))
  (local.set $s (call $alloc (i32.const 48)))
  (if (global.get $err) (then (return (call $nil))))
  (block $done (loop $next
    (br_if $done (i32.ge_u (local.get $i) (global.get $nlines)))
    (local.set $l (i32.add (global.get $lines) (i32.shl (local.get $i) (i32.const 4))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (local.set $t (call $lt (local.get $l))) (local.set $tn (call $ltn (local.get $l))) (local.set $no (call $lno (local.get $l)))
    (if (call $lind (local.get $l)) (then (call $fail (i32.const 40) (local.get $no)) (return (call $nil))))
    (if (call $lstarts (local.get $l) (global.get $S_SECTION) (i32.const 3))
      (then
        (local.set $p (i32.add (local.get $t) (i32.const 3))) (local.set $n (i32.sub (local.get $tn) (i32.const 3)))
        (local.set $sec (i32.const 0))
        (if (call $str_eq (local.get $p) (local.get $n) (global.get $K_removed) (global.get $K_removed_n)) (then (local.set $sec (i32.const 1))))
        (if (call $str_eq (local.get $p) (local.get $n) (global.get $K_added) (global.get $K_added_n)) (then (local.set $sec (i32.const 2))))
        (if (call $str_eq (local.get $p) (local.get $n) (global.get $K_edges_removed) (global.get $K_edges_removed_n)) (then (local.set $sec (i32.const 3))))
        (if (call $str_eq (local.get $p) (local.get $n) (global.get $K_edges_added) (global.get $K_edges_added_n)) (then (local.set $sec (i32.const 4))))
        (if (i32.eqz (local.get $sec)) (then (call $fail (i32.const 40) (local.get $no)) (return (call $nil))))
        (br $next)))
    (br_if $next (call $lstarts (local.get $l) (global.get $S_SUMMARY) (i32.const 3)))
    (local.set $nf (call $graph_fields (local.get $t) (local.get $tn) (i32.const 4)))
    (if (i32.eqz (local.get $sec)) (then (call $fail (i32.const 40) (local.get $no)) (return (call $nil))))
    (block $made
      (if (i32.eq (local.get $sec) (i32.const 1))
        (then
          (if (i32.ne (local.get $nf) (i32.const 2)) (then (call $fail (i32.const 40) (local.get $no)) (return (call $nil))))
          (local.set $mark (call $obj_begin))
          (call $expand_kind (call $fp (i32.const 0)) (call $fn (i32.const 0))) (local.set $kn) (local.set $kp)
          (call $obj_add_str (global.get $K_kind) (global.get $K_kind_n) (local.get $kp) (local.get $kn))
          (call $obj_add_str (global.get $K_qualifiedName) (global.get $K_qualifiedName_n) (call $fp (i32.const 1)) (call $fn (i32.const 1)))
          (call $obj_end (local.get $mark)) (local.set $vb) (local.set $va) (local.set $vt)
          (br $made)))
      (if (i32.eq (local.get $sec) (i32.const 2))
        (then
          (call $node_line (local.get $s) (local.get $t) (local.get $tn) (i64.const 0) (local.get $no) (i32.const 1))
          (if (global.get $err)
            (then (if (i32.eq (global.get $err) (i32.const 34)) (then (call $retag (i32.const 40)))) (return (call $nil))))
          (call $symbol_value (local.get $s)) (local.set $vb) (local.set $va) (local.set $vt)
          (br $made)))
      (if (i32.or (i32.ne (local.get $nf) (i32.const 4))
                  (i32.eqz (call $str_eq (call $fp (i32.const 1)) (call $fn (i32.const 1)) (global.get $K_arrow) (i32.const 2))))
        (then (call $fail (i32.const 40) (local.get $no)) (return (call $nil))))
      (call $edge_value (call $fp (i32.const 0)) (call $fn (i32.const 0)) (call $fp (i32.const 2)) (call $fn (i32.const 2))
                        (call $fp (i32.const 3)) (call $fn (i32.const 3)) (i32.const 0) (i32.const 0) (i32.const 0))
      (local.set $vb) (local.set $va) (local.set $vt))
    (if (global.get $err) (then (return (call $nil))))
    ;; record: section (4 bytes) + pad + node (16)
    (local.set $q (call $stack_push (global.get $STK_SLOTS) (i32.const 24)))
    (if (global.get $err) (then (return (call $nil))))
    (i32.store (local.get $q) (local.get $sec))
    (call $store_node (i32.add (local.get $q) (i32.const 8)) (local.get $vt) (local.get $va) (local.get $vb))
    (br $next)))
  ;; split the records into the four arrays, in order
  (local.set $mark (call $obj_begin))
  (call $header_str (global.get $K_tool) (global.get $K_tool_n)) (local.set $n) (local.set $p)
  (call $obj_add_str (global.get $K_tool) (global.get $K_tool_n) (local.get $p) (local.get $n))
  (call $obj_add (global.get $K_delta) (global.get $K_delta_n) (i32.const 2) (i32.const 0) (i64.const 0))
  (call $header_str (global.get $K_base_root) (global.get $K_base_root_n)) (local.set $n) (local.set $p)
  (call $obj_add_str (global.get $K_baseRoot) (global.get $K_baseRoot_n) (local.get $p) (local.get $n))
  (call $header_str (global.get $K_new_root) (global.get $K_new_root_n)) (local.set $n) (local.set $p)
  (call $obj_add_str (global.get $K_newRoot) (global.get $K_newRoot_n) (local.get $p) (local.get $n))
  (local.set $k (i32.const 1))
  (block $kd (loop $kl
    (br_if $kd (i32.gt_u (local.get $k) (i32.const 4)))
    (call $section_array (local.get $marks) (local.get $k)) (local.set $cnt) (local.set $q)
    (if (global.get $err) (then (return (call $nil))))
    (if (i32.eq (local.get $k) (i32.const 1)) (then (local.set $kp (global.get $K_removed)) (local.set $kn (global.get $K_removed_n))))
    (if (i32.eq (local.get $k) (i32.const 2)) (then (local.set $kp (global.get $K_added)) (local.set $kn (global.get $K_added_n))))
    (if (i32.eq (local.get $k) (i32.const 3)) (then (local.set $kp (global.get $K_edgesRemoved)) (local.set $kn (global.get $K_edgesRemoved_n))))
    (if (i32.eq (local.get $k) (i32.const 4)) (then (local.set $kp (global.get $K_edgesAdded)) (local.set $kn (global.get $K_edgesAdded_n))))
    (call $obj_add (local.get $kp) (local.get $kn) (i32.const 6) (local.get $q) (i64.extend_i32_u (local.get $cnt)))
    (local.set $k (i32.add (local.get $k) (i32.const 1)))
    (br $kl)))
  (call $stack_truncate (global.get $STK_SLOTS) (local.get $marks))
  (call $obj_end (local.get $mark)))

;; Nodes of section `k` among the 24-byte records on STK_SLOTS since `mark`.
(func $section_array (param $mark i32) (param $k i32) (result i32 i32)
  (local $n i32) (local $i i32) (local $cnt i32) (local $out i32) (local $r i32)
  (local.set $n (i32.div_u (i32.sub (call $stack_len (global.get $STK_SLOTS)) (local.get $mark)) (i32.const 24)))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (if (i32.eq (i32.load (i32.add (call $stack_base (global.get $STK_SLOTS)) (i32.add (local.get $mark) (i32.mul (local.get $i) (i32.const 24))))) (local.get $k))
      (then (local.set $cnt (i32.add (local.get $cnt) (i32.const 1)))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.set $out (call $alloc (i32.shl (local.get $cnt) (i32.const 4))))
  (if (global.get $err) (then (return (i32.const 0) (i32.const 0))))
  (local.set $cnt (i32.const 0))
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $r (i32.add (call $stack_base (global.get $STK_SLOTS)) (i32.add (local.get $mark) (i32.mul (local.get $i) (i32.const 24)))))
    (if (i32.eq (i32.load (local.get $r)) (local.get $k))
      (then
        (v128.store (i32.add (local.get $out) (i32.shl (local.get $cnt) (i32.const 4))) (v128.load offset=8 (local.get $r)))
        (local.set $cnt (i32.add (local.get $cnt) (i32.const 1)))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.get $out) (local.get $cnt))

;; ---------------------------------------------------------------------------
;; Generic delta payload (SPEC §10a.2)
;; ---------------------------------------------------------------------------

;; Parsed delta: 48-byte record (key, base_root, new_root as (ptr, len), then
;; added, changed, removed as (nodes, count)). Returns 0 on error.
(func $parse_generic_delta (result i32)
  (local $d i32) (local $l i32) (local $t i32) (local $tn i32) (local $no i32) (local $seen i32) (local $which i32)
  (local $kp i32) (local $kn i32) (local $rp i32) (local $rn i32) (local $h i32) (local $i i32) (local $f i32) (local $ok i32)
  (local $vt i32) (local $va i32) (local $vb i64) (local $n i32) (local $ids i32) (local $row i32) (local $p i32) (local $x i32)
  (local.set $d (call $alloc (i32.const 48)))
  (if (global.get $err) (then (return (i32.const 0))))
  (memory.fill (local.get $d) (i32.const 0) (i32.const 48))
  (call $header_str (global.get $K_key) (global.get $K_key_n)) (local.set $n) (local.set $p)
  (i32.store (local.get $d) (local.get $p)) (i32.store offset=4 (local.get $d) (local.get $n))
  (call $header_str (global.get $K_base_root) (global.get $K_base_root_n)) (local.set $n) (local.set $p)
  (i32.store offset=8 (local.get $d) (local.get $p)) (i32.store offset=12 (local.get $d) (local.get $n))
  (call $header_str (global.get $K_new_root) (global.get $K_new_root_n)) (local.set $n) (local.set $p)
  (i32.store offset=16 (local.get $d) (local.get $p)) (i32.store offset=20 (local.get $d) (local.get $n))
  (block $done (loop $next
    (local.set $l (call $peek))
    (br_if $done (i32.eqz (local.get $l)))
    (local.set $t (call $lt (local.get $l))) (local.set $tn (call $ltn (local.get $l))) (local.set $no (call $lno (local.get $l)))
    (if (call $lind (local.get $l)) (then (call $fail (i32.const 21) (local.get $no)) (return (i32.const 0))))
    (if (call $lstarts (local.get $l) (global.get $S_SUMMARY) (i32.const 3))
      (then
        (call $advance)
        (call $summary (local.get $l))
        (if (global.get $err) (then (return (i32.const 0))))
        (br $next)))
    (if (i32.eqz (call $lstarts (local.get $l) (global.get $S_SECTION) (i32.const 3))) (then (call $fail (i32.const 40) (local.get $no)) (return (i32.const 0))))
    (call $advance)
    (call $key (i32.add (local.get $t) (i32.const 3)) (i32.sub (local.get $tn) (i32.const 3)) (local.get $no))
    (local.set $rn) (local.set $rp) (local.set $kn) (local.set $kp)
    (if (global.get $err) (then (call $retag (i32.const 40)) (return (i32.const 0))))
    (local.set $which (i32.const 0))
    (if (call $str_eq (local.get $kp) (local.get $kn) (global.get $K_added) (global.get $K_added_n)) (then (local.set $which (i32.const 1))))
    (if (call $str_eq (local.get $kp) (local.get $kn) (global.get $K_changed) (global.get $K_changed_n)) (then (local.set $which (i32.const 2))))
    (if (call $str_eq (local.get $kp) (local.get $kn) (global.get $K_removed) (global.get $K_removed_n)) (then (local.set $which (i32.const 3))))
    (if (i32.eqz (local.get $which)) (then (call $fail (i32.const 40) (local.get $no)) (return (i32.const 0))))
    (if (i32.and (local.get $seen) (i32.shl (i32.const 1) (local.get $which))) (then (call $fail (i32.const 40) (local.get $no)) (return (i32.const 0))))
    (local.set $seen (i32.or (local.get $seen) (i32.shl (i32.const 1) (local.get $which))))
    (if (i32.eqz (call $starts_with (local.get $rp) (local.get $rn) (global.get $S_SPBR) (i32.const 2))) (then (call $fail (i32.const 40) (local.get $no)) (return (i32.const 0))))
    (local.set $h (call $array_header (i32.add (local.get $rp) (i32.const 1)) (i32.sub (local.get $rn) (i32.const 1)) (local.get $no)))
    (if (global.get $err) (then (return (i32.const 0))))
    (if (i32.eqz (i32.load offset=24 (local.get $h))) (then (call $fail (i32.const 40) (local.get $no)) (return (i32.const 0))))
    (if (i32.or (i32.or (i32.load offset=12 (local.get $h)) (i32.load offset=48 (local.get $h))) (i32.load offset=36 (local.get $h)))
      (then (call $fail (i32.const 40) (local.get $no)) (return (i32.const 0))))
    (local.set $ok (i32.const 0))
    (local.set $i (i32.const 0))
    (block $fd (loop $fl
      (br_if $fd (i32.ge_u (local.get $i) (i32.load offset=20 (local.get $h))))
      (if (i32.load offset=8 (i32.add (i32.load offset=16 (local.get $h)) (i32.shl (local.get $i) (i32.const 5)))) (then (local.set $ok (i32.const 1))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $fl)))
    (if (i32.eqz (local.get $ok)) (then (call $fail (i32.const 40) (local.get $no)) (return (i32.const 0))))
    (call $array_body (local.get $h) (i32.const 0) (i32.const 0) (local.get $no) (i32.const 0))
    (local.set $vb) (local.set $va) (local.set $vt)
    (if (global.get $err) (then (return (i32.const 0))))
    (local.set $n (i32.wrap_i64 (local.get $vb)))
    (if (i32.eq (local.get $which) (i32.const 3))
      (then
        (if (i32.ne (i32.load offset=20 (local.get $h)) (i32.const 1)) (then (call $fail (i32.const 40) (local.get $no)) (return (i32.const 0))))
        ;; removed: the identity values
        (local.set $ids (call $alloc (i32.shl (local.get $n) (i32.const 4))))
        (if (global.get $err) (then (return (i32.const 0))))
        (local.set $i (i32.const 0))
        (block $rd (loop $rl
          (br_if $rd (i32.ge_u (local.get $i) (local.get $n)))
          (local.set $row (i32.add (local.get $va) (i32.shl (local.get $i) (i32.const 4))))
          (local.set $x (i32.add (local.get $ids) (i32.shl (local.get $i) (i32.const 4))))
          (if (i32.eq (i32.load offset=8 (local.get $row)) (i32.const 1))
            (then (v128.store (local.get $x) (v128.load offset=8 (i32.load offset=4 (local.get $row)))))
            (else (call $store_node (local.get $x) (i32.const 0) (i32.const 0) (i64.const 0))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $rl)))
        (local.set $va (local.get $ids))))
    (local.set $p (i32.add (local.get $d) (i32.add (i32.const 16) (i32.shl (local.get $which) (i32.const 3)))))
    (i32.store (local.get $p) (local.get $va))
    (i32.store offset=4 (local.get $p) (local.get $n))
    (br $next)))
  (local.get $d))

(func $generic_delta_value (param $d i32) (result i32 i32 i64)
  (local $mark i32) (local $p i32) (local $n i32) (local $f i32)
  (local.set $mark (call $obj_begin))
  (call $header_get (global.get $K_tool) (global.get $K_tool_n)) (local.set $f) (local.set $n) (local.set $p)
  (if (local.get $f) (then (call $obj_add_str (global.get $K_tool) (global.get $K_tool_n) (local.get $p) (local.get $n))))
  (call $obj_add (global.get $K_delta) (global.get $K_delta_n) (i32.const 2) (i32.const 0) (i64.const 0))
  (call $obj_add_str (global.get $K_key) (global.get $K_key_n) (i32.load (local.get $d)) (i32.load offset=4 (local.get $d)))
  (call $obj_add_str (global.get $K_baseRoot) (global.get $K_baseRoot_n) (i32.load offset=8 (local.get $d)) (i32.load offset=12 (local.get $d)))
  (call $obj_add_str (global.get $K_newRoot) (global.get $K_newRoot_n) (i32.load offset=16 (local.get $d)) (i32.load offset=20 (local.get $d)))
  (call $obj_add (global.get $K_added) (global.get $K_added_n) (i32.const 6) (i32.load offset=24 (local.get $d)) (i64.extend_i32_u (i32.load offset=28 (local.get $d))))
  (call $obj_add (global.get $K_changed) (global.get $K_changed_n) (i32.const 6) (i32.load offset=32 (local.get $d)) (i64.extend_i32_u (i32.load offset=36 (local.get $d))))
  (call $obj_add (global.get $K_removed) (global.get $K_removed_n) (i32.const 6) (i32.load offset=40 (local.get $d)) (i64.extend_i32_u (i32.load offset=44 (local.get $d))))
  (call $obj_end (local.get $mark)))

;; ---------------------------------------------------------------------------
;; Exports
;; ---------------------------------------------------------------------------

;; Non-delta graph payload -> compact columnar JSON.
(func (export "gcf_decode_graph_columns") (param $len i32) (result i32)
  (global.set $pos (i32.const 0)) (global.set $depth (i32.const 0)) (global.set $nlines (i32.const 0))
  (call $build_document (global.get $in_ptr) (local.get $len))
  (if (global.get $err) (then (return (global.get $err))))
  (if (i32.or (i32.ne (global.get $profile) (i32.const 1)) (call $header_flag (global.get $S_DELTA) (i32.const 5)))
    (then (call $fail (i32.const 29) (i32.const 1)) (return (global.get $err))))
  (call $parse_graph)
  (if (global.get $err) (then (return (global.get $err))))
  (call $w_begin (i32.add (local.get $len) (i32.const 64)))
  (call $graph_to_columns)
  (call $w_sync)
  (if (global.get $err) (then (return (global.get $err))))
  (call $out_finish)
  (i32.const 0))
