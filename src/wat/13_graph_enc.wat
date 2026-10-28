;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 felixdrp
;;
;; 13_graph_enc.wat — graph profile encoders (SPEC §5, §9, §10.1, §16.1):
;; buffered payloads, session payloads and graph deltas. Mirrors
;; encoder.zig encodeGraph / encodeGraphSession / encodeGraphDelta.
;;
;; Input values are JSON trees (gcf_encode_graph* parse with duplicate keys
;; rejected); getters follow gcf.zig getMember (first match).

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

;; Insert or overwrite (StrMap.put).
(func $sm_set (param $s i32) (param $p i32) (param $n i32) (param $val i32)
  (local $h i32) (local $mask i32) (local $i i32) (local $e i32)
  (if (i32.ge_s (call $sm_find (local.get $s) (local.get $p) (local.get $n) (i32.const 1) (local.get $val)) (i32.const 0))
    (then
      ;; present: find the entry again and overwrite its value
      (local.set $h (i32.or (call $hash (local.get $p) (local.get $n)) (i32.const 1)))
      (local.set $mask (i32.sub (i32.load offset=4 (local.get $s)) (i32.const 1)))
      (local.set $i (i32.and (local.get $h) (local.get $mask)))
      (loop $probe
        (local.set $e (i32.add (i32.load offset=8 (local.get $s)) (i32.shl (local.get $i) (i32.const 4))))
        (if (i32.eq (i32.load (local.get $e)) (local.get $h))
          (then (if (call $str_eq (i32.load offset=4 (local.get $e)) (i32.load offset=8 (local.get $e)) (local.get $p) (local.get $n))
            (then (i32.store offset=12 (local.get $e) (local.get $val)) (return)))))
        (local.set $i (i32.and (i32.add (local.get $i) (i32.const 1)) (local.get $mask)))
        (br $probe)))))

;; gcf encoder.zig num(): integer or double as f64, else 0.
(func $num_of (param $v i32) (result f64)
  (if (i32.eqz (local.get $v)) (then (return (f64.const 0))))
  (if (i32.eq (i32.load (local.get $v)) (i32.const 3)) (then (return (f64.convert_i64_s (i64.load offset=8 (local.get $v))))))
  (if (i32.eq (i32.load (local.get $v)) (i32.const 4)) (then (return (f64.load offset=8 (local.get $v)))))
  (f64.const 0))

;; encoder.zig int(): integer, or a double truncated toward zero, else 0.
(func $int_of (param $v i32) (result i64)
  (if (i32.eqz (local.get $v)) (then (return (i64.const 0))))
  (if (i32.eq (i32.load (local.get $v)) (i32.const 3)) (then (return (i64.load offset=8 (local.get $v)))))
  (if (i32.eq (i32.load (local.get $v)) (i32.const 4)) (then (return (i64.trunc_sat_f64_s (f64.load offset=8 (local.get $v))))))
  (i64.const 0))

(func $o_u64 (param $v i64)
  (local $dp i32) (local $dn i32)
  (if (i64.lt_u (local.get $v) (i64.const 0x100000000)) (then (call $o_u32 (i32.wrap_i64 (local.get $v))) (return)))
  (call $u64_digits (local.get $v)) (local.set $dn) (local.set $dp)
  (call $o_bytes (local.get $dp) (local.get $dn)))

(func $o_i64 (param $v i64)
  (if (i64.lt_s (local.get $v) (i64.const 0))
    (then (call $o_byte (i32.const 0x2D)) (local.set $v (i64.sub (i64.const 0) (local.get $v)))))
  (call $o_u64 (local.get $v)))

;; " key=" (static key)
(func $o_kv (param $kp i32) (param $kn i32)
  (call $o_byte (i32.const 0x20))
  (call $o_bytes (local.get $kp) (local.get $kn))
  (call $o_byte (i32.const 0x3D)))

;; Two-decimal score, round-half-to-even on the exact double (SPEC §5):
;; x = mant * 2^e exactly, so 100x is decided with integer arithmetic.
(func $o_score (param $x f64)
  (local $bits i64) (local $eb i32) (local $mant i64) (local $e i32) (local $n i64) (local $cents i64) (local $k i64) (local $q i64) (local $r i64) (local $half i64) (local $rem i32)
  (local.set $bits (i64.reinterpret_f64 (f64.abs (local.get $x))))
  (local.set $eb (i32.wrap_i64 (i64.and (i64.shr_u (local.get $bits) (i64.const 52)) (i64.const 0x7FF))))
  (local.set $mant (i64.and (local.get $bits) (i64.const 0x000FFFFFFFFFFFFF)))
  (if (local.get $eb) (then (local.set $mant (i64.or (local.get $mant) (i64.const 0x0010000000000000)))))
  (local.set $e (select (i32.sub (local.get $eb) (i32.const 1075)) (i32.const -1074) (local.get $eb)))
  (local.set $n (i64.mul (local.get $mant) (i64.const 100)))
  (if (i32.ge_s (local.get $e) (i32.const 0))
    (then
      (if (i32.gt_s (local.get $e) (i32.const 3)) (then (call $fail (i32.const 44) (i32.const 0)) (return)))
      (local.set $cents (i64.shl (local.get $n) (i64.extend_i32_u (local.get $e)))))
    (else (if (i32.le_s (local.get $e) (i32.const -62))
      (then (local.set $cents (i64.const 0)))
      (else
        (local.set $k (i64.extend_i32_u (i32.sub (i32.const 0) (local.get $e))))
        (local.set $q (i64.shr_u (local.get $n) (local.get $k)))
        (local.set $r (i64.and (local.get $n) (i64.sub (i64.shl (i64.const 1) (local.get $k)) (i64.const 1))))
        (local.set $half (i64.shl (i64.const 1) (i64.sub (local.get $k) (i64.const 1))))
        (local.set $cents (local.get $q))
        (if (i32.or (i64.gt_u (local.get $r) (local.get $half))
                    (i32.and (i64.eq (local.get $r) (local.get $half)) (i64.ne (i64.and (local.get $q) (i64.const 1)) (i64.const 0))))
          (then (local.set $cents (i64.add (local.get $cents) (i64.const 1)))))))))
  (if (f64.lt (local.get $x) (f64.const 0)) (then (call $o_byte (i32.const 0x2D))))
  (call $o_u64 (i64.div_u (local.get $cents) (i64.const 100)))
  (call $o_byte (i32.const 0x2E))
  (local.set $rem (i32.wrap_i64 (i64.rem_u (local.get $cents) (i64.const 100))))
  (call $o_byte (i32.add (i32.const 0x30) (i32.div_u (local.get $rem) (i32.const 10))))
  (call $o_byte (i32.add (i32.const 0x30) (i32.rem_u (local.get $rem) (i32.const 10)))))

;; Writes a member string (or nothing when absent / not a string).
(func $o_member_str (param $node i32) (param $kp i32) (param $kn i32)
  (local $p i32) (local $n i32)
  (call $str_or_empty (local.get $node) (local.get $kp) (local.get $kn)) (local.set $n) (local.set $p)
  (call $o_bytes (local.get $p) (local.get $n)))

(func $group_name (param $d i64)
  (if (i64.eqz (local.get $d)) (then (call $o_bytes (global.get $K_targets) (global.get $K_targets_n)) (return)))
  (if (i64.eq (local.get $d) (i64.const 1)) (then (call $o_bytes (global.get $K_related) (global.get $K_related_n)) (return)))
  (if (i64.eq (local.get $d) (i64.const 2)) (then (call $o_bytes (global.get $K_extended) (global.get $K_extended_n)) (return)))
  (call $o_bytes (global.get $K_distance_) (global.get $K_distance__n))
  (call $o_i64 (local.get $d)))

;; `## <group>\n`
(func $o_group (param $d i64)
  (call $o_bytes (global.get $S_SECTION) (i32.const 3))
  (call $group_name (local.get $d))
  (call $o_byte (i32.const 0x0A)))

;; `@id kind qname score provenance` (no newline)
(func $o_node_line (param $id i64) (param $s i32)
  (local $p i32) (local $n i32) (local $kp i32) (local $kn i32)
  (call $o_byte (i32.const 0x40))
  (call $o_u64 (local.get $id))
  (call $o_byte (i32.const 0x20))
  (call $str_or_empty (local.get $s) (global.get $K_kind) (global.get $K_kind_n)) (local.set $n) (local.set $p)
  (call $abbreviate_kind (local.get $p) (local.get $n)) (local.set $kn) (local.set $kp)
  (call $o_bytes (local.get $kp) (local.get $kn))
  (call $o_byte (i32.const 0x20))
  (call $o_member_str (local.get $s) (global.get $K_qualifiedName) (global.get $K_qualifiedName_n))
  (call $o_byte (i32.const 0x20))
  (call $o_score (call $num_of (call $get (local.get $s) (global.get $K_score) (global.get $K_score_n))))
  (call $o_byte (i32.const 0x20))
  (call $o_member_str (local.get $s) (global.get $K_provenance) (global.get $K_provenance_n)))

(func $o_graph_header (param $p i32) (param $nsym i32) (param $nedge i32) (param $session i32)
  (local $sp i32) (local $sn i32) (local $v i64)
  (call $o_bytes (global.get $K_graph_hdr) (global.get $K_graph_hdr_n))
  (call $str_or_empty (local.get $p) (global.get $K_tool) (global.get $K_tool_n)) (local.set $sn) (local.set $sp)
  (if (local.get $sn) (then (call $o_kv (global.get $K_tool) (global.get $K_tool_n)) (call $o_bytes (local.get $sp) (local.get $sn))))
  (local.set $v (call $int_of (call $get (local.get $p) (global.get $K_tokenBudget) (global.get $K_tokenBudget_n))))
  (if (i64.ne (local.get $v) (i64.const 0)) (then (call $o_kv (global.get $K_budget) (global.get $K_budget_n)) (call $o_i64 (local.get $v))))
  (local.set $v (call $int_of (call $get (local.get $p) (global.get $K_tokensUsed) (global.get $K_tokensUsed_n))))
  (if (i64.ne (local.get $v) (i64.const 0)) (then (call $o_kv (global.get $K_tokens) (global.get $K_tokens_n)) (call $o_i64 (local.get $v))))
  (call $o_kv (global.get $K_symbols) (global.get $K_symbols_n))
  (call $o_u32 (local.get $nsym))
  (if (local.get $nedge) (then (call $o_kv (global.get $K_edges) (global.get $K_edges_n)) (call $o_u32 (local.get $nedge))))
  (if (local.get $session) (then (call $o_kv (global.get $K_session) (global.get $K_session_n)) (call $o_bytes (global.get $S_TRUE) (i32.const 4))))
  (call $str_or_empty (local.get $p) (global.get $K_packRoot) (global.get $K_packRoot_n)) (local.set $sn) (local.set $sp)
  (if (local.get $sn) (then (call $o_kv (global.get $K_pack_root) (global.get $K_pack_root_n)) (call $o_bytes (local.get $sp) (local.get $sn))))
  (call $o_byte (i32.const 0x0A)))

;; ` <status>` unless empty or "unchanged"
(func $o_edge_status (param $e i32)
  (local $p i32) (local $n i32)
  (call $str_or_empty (local.get $e) (global.get $K_status) (global.get $K_status_n)) (local.set $n) (local.set $p)
  (if (i32.and (i32.ne (local.get $n) (i32.const 0)) (i32.eqz (call $str_eq (local.get $p) (local.get $n) (global.get $K_unchanged) (global.get $K_unchanged_n))))
    (then (call $o_byte (i32.const 0x20)) (call $o_bytes (local.get $p) (local.get $n)))))

;; `@tgt<@src type[ status]\n`
(func $o_edge_line (param $tgt i64) (param $src i64) (param $e i32)
  (call $o_byte (i32.const 0x40))
  (call $o_u64 (local.get $tgt))
  (call $o_bytes (global.get $K_lt_at) (i32.const 2))
  (call $o_u64 (local.get $src))
  (call $o_byte (i32.const 0x20))
  (call $o_member_str (local.get $e) (global.get $K_edgeType) (global.get $K_edgeType_n))
  (call $o_edge_status (local.get $e))
  (call $o_byte (i32.const 0x0A)))

;; ---------------------------------------------------------------------------
;; Buffered graph payload
;;
;; Both entry points convert their input to one columnar form, then a single
;; encoder runs on it:
;;   gcf_encode_graph       JSON text -> value tree -> columns
;;   gcf_encode_graph_cols  columns written by the JS host straight into wasm
;;                          memory (no JSON.stringify, no JSON parsing)
;;
;; Columnar graph (internal, absolute pointers):
;;   header (48 bytes): +0 nsym, +4 nedge, +8 symbols, +12 edges,
;;     +16 tool ptr, +20 tool len, +24 packRoot ptr, +28 packRoot len,
;;     +32 tokenBudget i64, +40 tokensUsed i64
;;   symbol (40 bytes): +0 score f64, +8 distance i64, +16 qname ptr/len,
;;     +24 kind ptr/len, +32 provenance ptr/len
;;   edge (32 bytes): +0 source ptr/len, +8 target ptr/len, +16 type ptr/len,
;;     +24 status ptr/len
;; Absent or non-string strings are "" and absent or non-numeric numbers 0,
;; exactly as the getters of the JSON path (encoder.zig str/num/int).
;; ---------------------------------------------------------------------------

;; Store a member string (or "") as a (ptr, len) pair at q.
(func $put_member_str (param $q i32) (param $node i32) (param $kp i32) (param $kn i32)
  (local $p i32) (local $n i32)
  (call $str_or_empty (local.get $node) (local.get $kp) (local.get $kn)) (local.set $n) (local.set $p)
  (i32.store (local.get $q) (local.get $p))
  (i32.store offset=4 (local.get $q) (local.get $n)))

;; Value tree -> columnar graph (the JSON path).
(func $graph_cols_from_tree (param $p i32) (result i32)
  (local $h i32) (local $syms i32) (local $ns i32) (local $edges i32) (local $ne i32) (local $cs i32) (local $ce i32) (local $i i32) (local $s i32) (local $r i32)
  (call $array_of (call $get (local.get $p) (global.get $K_symbols) (global.get $K_symbols_n))) (local.set $ns) (local.set $syms)
  (call $array_of (call $get (local.get $p) (global.get $K_edges) (global.get $K_edges_n))) (local.set $ne) (local.set $edges)
  (local.set $h (call $alloc (i32.const 48)))
  (local.set $cs (call $alloc (i32.mul (local.get $ns) (i32.const 40))))
  (local.set $ce (call $alloc (i32.shl (local.get $ne) (i32.const 5))))
  (if (global.get $err) (then (return (i32.const 0))))
  (i32.store (local.get $h) (local.get $ns))
  (i32.store offset=4 (local.get $h) (local.get $ne))
  (i32.store offset=8 (local.get $h) (local.get $cs))
  (i32.store offset=12 (local.get $h) (local.get $ce))
  (call $put_member_str (i32.add (local.get $h) (i32.const 16)) (local.get $p) (global.get $K_tool) (global.get $K_tool_n))
  (call $put_member_str (i32.add (local.get $h) (i32.const 24)) (local.get $p) (global.get $K_packRoot) (global.get $K_packRoot_n))
  (i64.store offset=32 (local.get $h) (call $int_of (call $get (local.get $p) (global.get $K_tokenBudget) (global.get $K_tokenBudget_n))))
  (i64.store offset=40 (local.get $h) (call $int_of (call $get (local.get $p) (global.get $K_tokensUsed) (global.get $K_tokensUsed_n))))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ns)))
    (local.set $s (i32.add (local.get $syms) (i32.shl (local.get $i) (i32.const 4))))
    (local.set $r (i32.add (local.get $cs) (i32.mul (local.get $i) (i32.const 40))))
    (f64.store (local.get $r) (call $num_of (call $get (local.get $s) (global.get $K_score) (global.get $K_score_n))))
    (i64.store offset=8 (local.get $r) (call $int_of (call $get (local.get $s) (global.get $K_distance) (global.get $K_distance_n))))
    (call $put_member_str (i32.add (local.get $r) (i32.const 16)) (local.get $s) (global.get $K_qualifiedName) (global.get $K_qualifiedName_n))
    (call $put_member_str (i32.add (local.get $r) (i32.const 24)) (local.get $s) (global.get $K_kind) (global.get $K_kind_n))
    (call $put_member_str (i32.add (local.get $r) (i32.const 32)) (local.get $s) (global.get $K_provenance) (global.get $K_provenance_n))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ne)))
    (local.set $s (i32.add (local.get $edges) (i32.shl (local.get $i) (i32.const 4))))
    (local.set $r (i32.add (local.get $ce) (i32.shl (local.get $i) (i32.const 5))))
    (call $put_member_str (local.get $r) (local.get $s) (global.get $K_source) (global.get $K_source_n))
    (call $put_member_str (i32.add (local.get $r) (i32.const 8)) (local.get $s) (global.get $K_target) (global.get $K_target_n))
    (call $put_member_str (i32.add (local.get $r) (i32.const 16)) (local.get $s) (global.get $K_edgeType) (global.get $K_edgeType_n))
    (call $put_member_str (i32.add (local.get $r) (i32.const 24)) (local.get $s) (global.get $K_status) (global.get $K_status_n))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.get $h))

;; ---- stable LSD radix sort of 64-bit keys --------------------------------

;; Sort the permutation `idx` (n u32 indices) by keys[idx[i]] (u64, unsigned),
;; stably, 8 bits per pass; a pass whose digit is the same for every key is
;; skipped (high bytes of small keys). `tmp` holds n u32.
(func $radix_sort64 (param $keys i32) (param $idx i32) (param $tmp i32) (param $n i32)
  (local $cnt i32) (local $shift i64) (local $i i32) (local $d i32) (local $sum i32) (local $c i32) (local $t i32) (local $k i32) (local $src i32) (local $dst i32) (local $skip i32)
  (local.set $cnt (call $alloc (i32.const 1024)))
  (if (global.get $err) (then (return)))
  (local.set $src (local.get $idx))
  (local.set $dst (local.get $tmp))
  (block $pd (loop $pl
    (br_if $pd (i64.ge_u (local.get $shift) (i64.const 64)))
    (memory.fill (local.get $cnt) (i32.const 0) (i32.const 1024))
    (local.set $i (i32.const 0))
    (block $cd (loop $cl
      (br_if $cd (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $k (i32.load (i32.add (local.get $src) (i32.shl (local.get $i) (i32.const 2)))))
      (local.set $d (i32.wrap_i64 (i64.and (i64.shr_u (i64.load (i32.add (local.get $keys) (i32.shl (local.get $k) (i32.const 3)))) (local.get $shift)) (i64.const 255))))
      (local.set $c (i32.add (local.get $cnt) (i32.shl (local.get $d) (i32.const 2))))
      (i32.store (local.get $c) (i32.add (i32.load (local.get $c)) (i32.const 1)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $cl)))
    ;; every key has the same digit: this pass would not move anything
    (local.set $skip (i32.eq (i32.load (i32.add (local.get $cnt) (i32.shl (local.get $d) (i32.const 2)))) (local.get $n)))
    (if (i32.eqz (local.get $skip))
      (then
        ;; exclusive prefix sums
        (local.set $sum (i32.const 0))
        (local.set $i (i32.const 0))
        (block $sd (loop $sl
          (br_if $sd (i32.ge_u (local.get $i) (i32.const 256)))
          (local.set $c (i32.add (local.get $cnt) (i32.shl (local.get $i) (i32.const 2))))
          (local.set $t (i32.load (local.get $c)))
          (i32.store (local.get $c) (local.get $sum))
          (local.set $sum (i32.add (local.get $sum) (local.get $t)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $sl)))
        (local.set $i (i32.const 0))
        (block $md (loop $ml
          (br_if $md (i32.ge_u (local.get $i) (local.get $n)))
          (local.set $k (i32.load (i32.add (local.get $src) (i32.shl (local.get $i) (i32.const 2)))))
          (local.set $d (i32.wrap_i64 (i64.and (i64.shr_u (i64.load (i32.add (local.get $keys) (i32.shl (local.get $k) (i32.const 3)))) (local.get $shift)) (i64.const 255))))
          (local.set $c (i32.add (local.get $cnt) (i32.shl (local.get $d) (i32.const 2))))
          (i32.store (i32.add (local.get $dst) (i32.shl (i32.load (local.get $c)) (i32.const 2))) (local.get $k))
          (i32.store (local.get $c) (i32.add (i32.load (local.get $c)) (i32.const 1)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $ml)))
        (local.set $t (local.get $src)) (local.set $src (local.get $dst)) (local.set $dst (local.get $t))))
    (local.set $shift (i64.add (local.get $shift) (i64.const 8)))
    (br $pl)))
  (if (i32.ne (local.get $src) (local.get $idx))
    (then (memory.copy (local.get $idx) (local.get $src) (i32.shl (local.get $n) (i32.const 2))))))

;; Monotone u64 image of a double for ascending order (-0 already folded to +0).
(func $f64_key (param $x f64) (result i64)
  (local $b i64)
  (local.set $b (i64.reinterpret_f64 (local.get $x)))
  (select (i64.xor (local.get $b) (i64.const -1))
          (i64.xor (local.get $b) (i64.const 0x8000000000000000))
          (i64.lt_s (local.get $b) (i64.const 0))))

;; The encoder. Symbols: grouped by distance ascending, score descending,
;; input order; edges by source ID, target ID, type bytes, input order. Both
;; orders are total, so any stable sort gives the same result as the Zig
;; build: here two stable radix passes (score key, then distance key) for
;; symbols, and a radix pass on the packed source:target key for edges with
;; the rare equal-key runs finished by type and input order.
(func $encode_graph_cols (param $h i32)
  (local $ns i32) (local $ne i32) (local $cs i32) (local $ce i32) (local $keys i32) (local $idx i32) (local $tmp i32) (local $ids i32)
  (local $i i32) (local $j i32) (local $r i32) (local $s i32) (local $index i32) (local $src i32) (local $tgt i32) (local $nr i32)
  (local $ekeys i32) (local $eidx i32) (local $etgt i32) (local $cur i64) (local $have i32) (local $d i64) (local $x f64) (local $e i32)
  (local $sp i32) (local $sn i32) (local $v i64) (local $k i32) (local $kp i32) (local $kn i32) (local $run i32) (local $a i32) (local $b i32)
  (local.set $ns (i32.load (local.get $h)))
  (local.set $ne (i32.load offset=4 (local.get $h)))
  (local.set $cs (i32.load offset=8 (local.get $h)))
  (local.set $ce (i32.load offset=12 (local.get $h)))
  (local.set $keys (call $alloc (i32.shl (i32.add (local.get $ns) (local.get $ne)) (i32.const 3))))
  (local.set $idx (call $alloc (i32.shl (i32.add (local.get $ns) (i32.const 1)) (i32.const 2))))
  (local.set $tmp (call $alloc (i32.shl (i32.add (i32.add (local.get $ns) (local.get $ne)) (i32.const 1)) (i32.const 2))))
  (local.set $ids (call $alloc (i32.shl (i32.add (local.get $ns) (i32.const 1)) (i32.const 2))))  ;; symbol index -> sequential ID
  (local.set $index (call $ks_new))
  (if (global.get $err) (then (return)))
  ;; symbols: score descending (secondary), then distance ascending (primary)
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ns)))
    (local.set $x (f64.load (i32.add (local.get $cs) (i32.mul (local.get $i) (i32.const 40)))))
    (if (f64.eq (local.get $x) (f64.const 0)) (then (local.set $x (f64.const 0))))   ;; -0 sorts as +0
    (i64.store (i32.add (local.get $keys) (i32.shl (local.get $i) (i32.const 3))) (i64.xor (call $f64_key (local.get $x)) (i64.const -1)))
    (i32.store (i32.add (local.get $idx) (i32.shl (local.get $i) (i32.const 2))) (local.get $i))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (call $radix_sort64 (local.get $keys) (local.get $idx) (local.get $tmp) (local.get $ns))
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ns)))
    ;; signed distance -> unsigned order
    (i64.store (i32.add (local.get $keys) (i32.shl (local.get $i) (i32.const 3)))
      (i64.xor (i64.load offset=8 (i32.add (local.get $cs) (i32.mul (local.get $i) (i32.const 40)))) (i64.const 0x8000000000000000)))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (call $radix_sort64 (local.get $keys) (local.get $idx) (local.get $tmp) (local.get $ns))
  (if (global.get $err) (then (return)))
  ;; qualifiedName -> sequential ID (the last symbol with a name wins)
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ns)))
    (local.set $r (i32.add (local.get $cs) (i32.mul (i32.load (i32.add (local.get $idx) (i32.shl (local.get $i) (i32.const 2)))) (i32.const 40))))
    (call $sm_set (local.get $index) (i32.load offset=16 (local.get $r)) (i32.load offset=20 (local.get $r)) (local.get $i))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (if (global.get $err) (then (return)))
  ;; edges: resolve endpoints, key = source:target
  (local.set $ekeys (i32.add (local.get $keys) (i32.shl (local.get $ns) (i32.const 3))))
  (local.set $eidx (call $alloc (i32.shl (i32.add (local.get $ne) (i32.const 1)) (i32.const 2))))
  (if (global.get $err) (then (return)))
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ne)))
    (local.set $e (i32.add (local.get $ce) (i32.shl (local.get $i) (i32.const 5))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (local.set $src (call $sm_find (local.get $index) (i32.load (local.get $e)) (i32.load offset=4 (local.get $e)) (i32.const 0) (i32.const 0)))
    (br_if $l (i32.lt_s (local.get $src) (i32.const 0)))
    (local.set $tgt (call $sm_find (local.get $index) (i32.load offset=8 (local.get $e)) (i32.load offset=12 (local.get $e)) (i32.const 0) (i32.const 0)))
    (br_if $l (i32.lt_s (local.get $tgt) (i32.const 0)))
    ;; keys are indexed by edge number; eidx lists the resolved edges in input order
    (i64.store (i32.add (local.get $ekeys) (i32.shl (i32.sub (local.get $i) (i32.const 1)) (i32.const 3)))
      (i64.or (i64.shl (i64.extend_i32_u (local.get $src)) (i64.const 32)) (i64.extend_i32_u (local.get $tgt))))
    (i32.store (i32.add (local.get $eidx) (i32.shl (local.get $nr) (i32.const 2))) (i32.sub (local.get $i) (i32.const 1)))
    (local.set $nr (i32.add (local.get $nr) (i32.const 1)))
    (br $l)))
  (call $radix_sort64 (local.get $ekeys) (local.get $eidx) (local.get $tmp) (local.get $nr))
  (if (global.get $err) (then (return)))
  ;; equal source:target runs: order by type bytes, then input order (insertion sort, stable)
  (local.set $i (i32.const 1))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $nr)))
    (local.set $a (i32.load (i32.add (local.get $eidx) (i32.shl (local.get $i) (i32.const 2)))))
    (local.set $j (local.get $i))
    (block $id (loop $il
      (br_if $id (i32.eqz (local.get $j)))
      (local.set $b (i32.load (i32.add (local.get $eidx) (i32.shl (i32.sub (local.get $j) (i32.const 1)) (i32.const 2)))))
      (br_if $id (i64.ne (i64.load (i32.add (local.get $ekeys) (i32.shl (local.get $a) (i32.const 3))))
                         (i64.load (i32.add (local.get $ekeys) (i32.shl (local.get $b) (i32.const 3))))))
      (br_if $id (i32.le_s (call $str_cmp (i32.load offset=16 (i32.add (local.get $ce) (i32.shl (local.get $b) (i32.const 5))))
                                          (i32.load offset=20 (i32.add (local.get $ce) (i32.shl (local.get $b) (i32.const 5))))
                                          (i32.load offset=16 (i32.add (local.get $ce) (i32.shl (local.get $a) (i32.const 5))))
                                          (i32.load offset=20 (i32.add (local.get $ce) (i32.shl (local.get $a) (i32.const 5)))))
                           (i32.const 0)))
      (i32.store (i32.add (local.get $eidx) (i32.shl (local.get $j) (i32.const 2))) (local.get $b))
      (local.set $j (i32.sub (local.get $j) (i32.const 1)))
      (br $il)))
    (i32.store (i32.add (local.get $eidx) (i32.shl (local.get $j) (i32.const 2))) (local.get $a))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  ;; header
  (call $o_bytes (global.get $K_graph_hdr) (global.get $K_graph_hdr_n))
  (if (i32.load offset=20 (local.get $h))
    (then (call $o_kv (global.get $K_tool) (global.get $K_tool_n)) (call $o_bytes (i32.load offset=16 (local.get $h)) (i32.load offset=20 (local.get $h)))))
  (local.set $v (i64.load offset=32 (local.get $h)))
  (if (i64.ne (local.get $v) (i64.const 0)) (then (call $o_kv (global.get $K_budget) (global.get $K_budget_n)) (call $o_i64 (local.get $v))))
  (local.set $v (i64.load offset=40 (local.get $h)))
  (if (i64.ne (local.get $v) (i64.const 0)) (then (call $o_kv (global.get $K_tokens) (global.get $K_tokens_n)) (call $o_i64 (local.get $v))))
  (call $o_kv (global.get $K_symbols) (global.get $K_symbols_n))
  (call $o_u32 (local.get $ns))
  (if (local.get $nr) (then (call $o_kv (global.get $K_edges) (global.get $K_edges_n)) (call $o_u32 (local.get $nr))))
  (if (i32.load offset=28 (local.get $h))
    (then (call $o_kv (global.get $K_pack_root) (global.get $K_pack_root_n)) (call $o_bytes (i32.load offset=24 (local.get $h)) (i32.load offset=28 (local.get $h)))))
  (call $o_byte (i32.const 0x0A))
  ;; symbols
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ns)))
    (local.set $r (i32.add (local.get $cs) (i32.mul (i32.load (i32.add (local.get $idx) (i32.shl (local.get $i) (i32.const 2)))) (i32.const 40))))
    (local.set $d (i64.load offset=8 (local.get $r)))
    (if (i32.or (i32.eqz (local.get $have)) (i64.ne (local.get $cur) (local.get $d)))
      (then (call $o_group (local.get $d)) (local.set $cur (local.get $d)) (local.set $have (i32.const 1))))
    ;; `@id kind qname score provenance`
    (call $o_byte (i32.const 0x40))
    (call $o_u32 (local.get $i))
    (call $o_byte (i32.const 0x20))
    (call $abbreviate_kind (i32.load offset=24 (local.get $r)) (i32.load offset=28 (local.get $r))) (local.set $kn) (local.set $kp)
    (call $o_bytes (local.get $kp) (local.get $kn))
    (call $o_byte (i32.const 0x20))
    (call $o_bytes (i32.load offset=16 (local.get $r)) (i32.load offset=20 (local.get $r)))
    (call $o_byte (i32.const 0x20))
    (call $o_score (f64.load (local.get $r)))
    (call $o_byte (i32.const 0x20))
    (call $o_bytes (i32.load offset=32 (local.get $r)) (i32.load offset=36 (local.get $r)))
    (call $o_byte (i32.const 0x0A))
    (if (global.get $err) (then (return)))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  ;; edges (the section appears whenever the input had edges)
  (if (local.get $ne)
    (then
      (call $o_bytes (global.get $K_edges_hdr) (global.get $K_edges_hdr_n))
      (call $o_u32 (local.get $nr))
      (call $o_bytes (global.get $S_CLOSE_NL) (i32.const 2))
      (local.set $i (i32.const 0))
      (block $done (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $nr)))
        (local.set $k (i32.load (i32.add (local.get $eidx) (i32.shl (local.get $i) (i32.const 2)))))
        (local.set $e (i32.add (local.get $ce) (i32.shl (local.get $k) (i32.const 5))))
        (local.set $v (i64.load (i32.add (local.get $ekeys) (i32.shl (local.get $k) (i32.const 3)))))
        (call $o_byte (i32.const 0x40))
        (call $o_u32 (i32.wrap_i64 (local.get $v)))
        (call $o_bytes (global.get $K_lt_at) (i32.const 2))
        (call $o_u32 (i32.wrap_i64 (i64.shr_u (local.get $v) (i64.const 32))))
        (call $o_byte (i32.const 0x20))
        (call $o_bytes (i32.load offset=16 (local.get $e)) (i32.load offset=20 (local.get $e)))
        ;; ` <status>` unless empty or "unchanged"
        (local.set $sp (i32.load offset=24 (local.get $e)))
        (local.set $sn (i32.load offset=28 (local.get $e)))
        (if (i32.and (i32.ne (local.get $sn) (i32.const 0)) (i32.eqz (call $str_eq (local.get $sp) (local.get $sn) (global.get $K_unchanged) (global.get $K_unchanged_n))))
          (then (call $o_byte (i32.const 0x20)) (call $o_bytes (local.get $sp) (local.get $sn))))
        (call $o_byte (i32.const 0x0A))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l))))))

(func $encode_graph (param $p i32)
  (local $h i32)
  (local.set $h (call $graph_cols_from_tree (local.get $p)))
  (if (global.get $err) (then (return)))
  (call $encode_graph_cols (local.get $h)))

;; Host-written columnar input (gcf_encode_graph_cols), offsets relative to
;; the string area; the same shapes as the internal form except: numbers are
;; f64 (tokenBudget, tokensUsed, distance) and become i64 by truncation, as
;; the JSON path does for a double; string fields are (offset, length).
;;   +0 magic "GCFG", +4 nsym, +8 nedge, +12 string area offset S,
;;   +16 tool off/len, +24 packRoot off/len, +32 tokenBudget f64,
;;   +40 tokensUsed f64, +48 symbols (40 bytes each), then edges (32 each),
;;   string bytes from S to the end of the input.
;; Converted in place; any field out of bounds is invalid_input.
(func $graph_cols_from_input (param $base i32) (param $len i32) (result i32)
  (local $ns i32) (local $ne i32) (local $sa i32) (local $sl i32) (local $i i32) (local $r i32) (local $end i64) (local $f i32) (local $q i32)
  (if (i32.lt_u (local.get $len) (i32.const 48)) (then (call $fail (i32.const 44) (i32.const 0)) (return (i32.const 0))))
  (if (i32.ne (i32.load (local.get $base)) (i32.const 0x47464347)) (then (call $fail (i32.const 44) (i32.const 0)) (return (i32.const 0))))
  (local.set $ns (i32.load offset=4 (local.get $base)))
  (local.set $ne (i32.load offset=8 (local.get $base)))
  (local.set $sa (i32.load offset=12 (local.get $base)))
  ;; layout must fit: 48 + 40 ns + 32 ne <= S <= len
  (local.set $end (i64.add (i64.add (i64.const 48) (i64.mul (i64.extend_i32_u (local.get $ns)) (i64.const 40)))
                           (i64.mul (i64.extend_i32_u (local.get $ne)) (i64.const 32))))
  (if (i32.or (i64.gt_u (local.get $end) (i64.extend_i32_u (local.get $sa))) (i32.gt_u (local.get $sa) (local.get $len)))
    (then (call $fail (i32.const 44) (i32.const 0)) (return (i32.const 0))))
  (local.set $sl (i32.sub (local.get $len) (local.get $sa)))
  (local.set $sa (i32.add (local.get $base) (local.get $sa)))
  ;; header: string fields at +16, +24; f64 -> i64 at +32, +40
  (if (i32.eqz (call $fix_str (i32.add (local.get $base) (i32.const 16)) (local.get $sa) (local.get $sl))) (then (return (i32.const 0))))
  (if (i32.eqz (call $fix_str (i32.add (local.get $base) (i32.const 24)) (local.get $sa) (local.get $sl))) (then (return (i32.const 0))))
  (i64.store offset=32 (local.get $base) (i64.trunc_sat_f64_s (f64.load offset=32 (local.get $base))))
  (i64.store offset=40 (local.get $base) (i64.trunc_sat_f64_s (f64.load offset=40 (local.get $base))))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ns)))
    (local.set $r (i32.add (local.get $base) (i32.add (i32.const 48) (i32.mul (local.get $i) (i32.const 40)))))
    (i64.store offset=8 (local.get $r) (i64.trunc_sat_f64_s (f64.load offset=8 (local.get $r))))
    (local.set $f (i32.const 16))
    (block $fd (loop $fl
      (br_if $fd (i32.ge_u (local.get $f) (i32.const 40)))
      (if (i32.eqz (call $fix_str (i32.add (local.get $r) (local.get $f)) (local.get $sa) (local.get $sl))) (then (return (i32.const 0))))
      (local.set $f (i32.add (local.get $f) (i32.const 8)))
      (br $fl)))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ne)))
    (local.set $r (i32.add (local.get $base) (i32.add (i32.add (i32.const 48) (i32.mul (local.get $ns) (i32.const 40))) (i32.shl (local.get $i) (i32.const 5)))))
    (local.set $f (i32.const 0))
    (block $fd (loop $fl
      (br_if $fd (i32.ge_u (local.get $f) (i32.const 32)))
      (if (i32.eqz (call $fix_str (i32.add (local.get $r) (local.get $f)) (local.get $sa) (local.get $sl))) (then (return (i32.const 0))))
      (local.set $f (i32.add (local.get $f) (i32.const 8)))
      (br $fl)))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  ;; the input header becomes the internal header (pointers at +8, +12)
  (i32.store offset=8 (local.get $base) (i32.add (local.get $base) (i32.const 48)))
  (i32.store offset=12 (local.get $base) (i32.add (local.get $base) (i32.add (i32.const 48) (i32.mul (local.get $ns) (i32.const 40)))))
  (i32.store (local.get $base) (local.get $ns))
  (i32.store offset=4 (local.get $base) (local.get $ne))
  (local.get $base))

;; (offset, len) at q -> (ptr, len), bounds-checked against the string area.
(func $fix_str (param $q i32) (param $sa i32) (param $sl i32) (result i32)
  (local $off i32) (local $n i32)
  (local.set $off (i32.load (local.get $q)))
  (local.set $n (i32.load offset=4 (local.get $q)))
  (if (i64.gt_u (i64.add (i64.extend_i32_u (local.get $off)) (i64.extend_i32_u (local.get $n))) (i64.extend_i32_u (local.get $sl)))
    (then (call $fail (i32.const 44) (i32.const 0)) (return (i32.const 0))))
  (i32.store (local.get $q) (i32.add (local.get $sa) (local.get $off)))
  (i32.const 1))

;; ---------------------------------------------------------------------------
;; Session payload (SPEC §9): {payload, known: {qname: id}, next}
;; ---------------------------------------------------------------------------

(func $encode_graph_session (param $input i32)
  (local $p i32) (local $known i32) (local $next i64) (local $syms i32) (local $ns i32) (local $edges i32) (local $ne i32)
  (local $local i32) (local $ids i32) (local $nids i32) (local $isk i32) (local $i i32) (local $s i32) (local $qp i32) (local $qn i32) (local $kv i32)
  (local $slot i32) (local $cur i64) (local $have i32) (local $d i64) (local $e i32) (local $src i32) (local $tgt i32) (local $id i64)
  (local.set $p (call $get (local.get $input) (global.get $K_payload) (global.get $K_payload_n)))
  (if (i32.eqz (local.get $p)) (then (call $fail (i32.const 43) (i32.const 0)) (return)))
  (local.set $known (call $get (local.get $input) (global.get $K_known) (global.get $K_known_n)))
  (local.set $next (call $int_of (call $get (local.get $input) (global.get $K_next) (global.get $K_next_n))))
  (if (i64.lt_s (local.get $next) (i64.const 0)) (then (local.set $next (i64.const 0))))
  (call $array_of (call $get (local.get $p) (global.get $K_symbols) (global.get $K_symbols_n))) (local.set $ns) (local.set $syms)
  (call $array_of (call $get (local.get $p) (global.get $K_edges) (global.get $K_edges_n))) (local.set $ne) (local.set $edges)
  ;; qname -> slot in `ids` (u64 each); a later put overwrites the id
  (local.set $local (call $ks_new))
  (local.set $ids (call $alloc (i32.shl (i32.add (local.get $ns) (i32.const 1)) (i32.const 3))))
  (local.set $isk (call $alloc (i32.add (local.get $ns) (i32.const 1))))
  (if (global.get $err) (then (return)))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ns)))
    (local.set $s (i32.add (local.get $syms) (i32.shl (local.get $i) (i32.const 4))))
    (call $str_or_empty (local.get $s) (global.get $K_qualifiedName) (global.get $K_qualifiedName_n)) (local.set $qn) (local.set $qp)
    (i32.store8 (i32.add (local.get $isk) (local.get $i)) (i32.const 0))
    (local.set $kv (if (result i32) (local.get $known) (then (call $get (local.get $known) (local.get $qp) (local.get $qn))) (else (i32.const 0))))
    (if (local.get $kv)
      (then
        (i32.store8 (i32.add (local.get $isk) (local.get $i)) (i32.const 1))
        (call $session_put (local.get $local) (local.get $ids) (local.get $qp) (local.get $qn) (call $int_of (local.get $kv)) (local.get $nids))
        (local.set $nids)))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ns)))
    (local.set $s (i32.add (local.get $syms) (i32.shl (local.get $i) (i32.const 4))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br_if $l (call $at (local.get $isk) (i32.sub (local.get $i) (i32.const 1))))
    (call $str_or_empty (local.get $s) (global.get $K_qualifiedName) (global.get $K_qualifiedName_n)) (local.set $qn) (local.set $qp)
    (br_if $l (i32.ge_s (call $sm_find (local.get $local) (local.get $qp) (local.get $qn) (i32.const 0) (i32.const 0)) (i32.const 0)))
    (call $session_put (local.get $local) (local.get $ids) (local.get $qp) (local.get $qn) (local.get $next) (local.get $nids))
    (local.set $nids)
    (local.set $next (i64.add (local.get $next) (i64.const 1)))
    (br $l)))
  (if (global.get $err) (then (return)))
  (call $o_graph_header (local.get $p) (local.get $ns) (local.get $ne) (i32.const 1))
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ns)))
    (local.set $s (i32.add (local.get $syms) (i32.shl (local.get $i) (i32.const 4))))
    (local.set $d (call $int_of (call $get (local.get $s) (global.get $K_distance) (global.get $K_distance_n))))
    (if (i32.or (i32.eqz (local.get $have)) (i64.ne (local.get $cur) (local.get $d)))
      (then (call $o_group (local.get $d)) (local.set $cur (local.get $d)) (local.set $have (i32.const 1))))
    (call $str_or_empty (local.get $s) (global.get $K_qualifiedName) (global.get $K_qualifiedName_n)) (local.set $qn) (local.set $qp)
    (local.set $slot (call $sm_find (local.get $local) (local.get $qp) (local.get $qn) (i32.const 0) (i32.const 0)))
    (local.set $id (i64.load (i32.add (local.get $ids) (i32.shl (local.get $slot) (i32.const 3)))))
    (if (call $at (local.get $isk) (local.get $i))
      (then
        (call $o_byte (i32.const 0x40))
        (call $o_u64 (local.get $id))
        (call $o_bytes (global.get $K_prev_line) (global.get $K_prev_line_n)))
      (else
        (call $o_node_line (local.get $id) (local.get $s))
        (call $o_byte (i32.const 0x0A))))
    (if (global.get $err) (then (return)))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (if (local.get $ne)
    (then
      (call $o_bytes (global.get $K_edges_hdr) (global.get $K_edges_hdr_n))
      (call $o_u32 (local.get $ne))
      (call $o_bytes (global.get $S_CLOSE_NL) (i32.const 2))
      (local.set $i (i32.const 0))
      (block $done (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $ne)))
        (local.set $e (i32.add (local.get $edges) (i32.shl (local.get $i) (i32.const 4))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (call $str_or_empty (local.get $e) (global.get $K_source) (global.get $K_source_n)) (local.set $qn) (local.set $qp)
        (local.set $src (call $sm_find (local.get $local) (local.get $qp) (local.get $qn) (i32.const 0) (i32.const 0)))
        (br_if $l (i32.lt_s (local.get $src) (i32.const 0)))
        (call $str_or_empty (local.get $e) (global.get $K_target) (global.get $K_target_n)) (local.set $qn) (local.set $qp)
        (local.set $tgt (call $sm_find (local.get $local) (local.get $qp) (local.get $qn) (i32.const 0) (i32.const 0)))
        (br_if $l (i32.lt_s (local.get $tgt) (i32.const 0)))
        (call $o_edge_line (i64.load (i32.add (local.get $ids) (i32.shl (local.get $tgt) (i32.const 3))))
                           (i64.load (i32.add (local.get $ids) (i32.shl (local.get $src) (i32.const 3)))) (local.get $e))
        (br $l))))))

;; local.put(q, id): reuse the qname's slot or take slot `nids`; returns the new count.
(func $session_put (param $map i32) (param $ids i32) (param $p i32) (param $n i32) (param $id i64) (param $nids i32) (result i32)
  (local $slot i32)
  (local.set $slot (call $sm_find (local.get $map) (local.get $p) (local.get $n) (i32.const 1) (local.get $nids)))
  (if (i32.lt_s (local.get $slot) (i32.const 0))
    (then
      (i64.store (i32.add (local.get $ids) (i32.shl (local.get $nids) (i32.const 3))) (local.get $id))
      (return (i32.add (local.get $nids) (i32.const 1)))))
  (i64.store (i32.add (local.get $ids) (i32.shl (local.get $slot) (i32.const 3))) (local.get $id))
  (local.get $nids))

;; ---------------------------------------------------------------------------
;; Graph delta payload (SPEC §10.1)
;; ---------------------------------------------------------------------------

;; JavaScript Math.round (half toward +infinity) of 100 * (1 - delta/full).
(func $savings (param $dt f64) (param $full f64) (result i64)
  (i64.trunc_sat_f64_s (f64.floor (f64.add (f64.mul (f64.const 100) (f64.sub (f64.const 1) (f64.div (local.get $dt) (local.get $full)))) (f64.const 0.5)))))

(func $encode_graph_delta (param $d i32)
  (local $full f64) (local $dt f64) (local $sv i64) (local $p i32) (local $n i32) (local $list i32) (local $cnt i32) (local $i i32) (local $s i32)
  (local $kp i32) (local $kn i32) (local $k i32)
  (local.set $full (call $num_of (call $get (local.get $d) (global.get $K_fullTokens) (global.get $K_fullTokens_n))))
  (local.set $dt (call $num_of (call $get (local.get $d) (global.get $K_deltaTokens) (global.get $K_deltaTokens_n))))
  (if (f64.gt (local.get $full) (f64.const 0)) (then (local.set $sv (call $savings (local.get $dt) (local.get $full)))))
  (call $o_bytes (global.get $K_graph_hdr) (global.get $K_graph_hdr_n))
  (call $str_or_empty (local.get $d) (global.get $K_tool) (global.get $K_tool_n)) (local.set $n) (local.set $p)
  (if (local.get $n) (then (call $o_kv (global.get $K_tool) (global.get $K_tool_n)) (call $o_bytes (local.get $p) (local.get $n))))
  (call $o_kv (global.get $K_delta) (global.get $K_delta_n)) (call $o_bytes (global.get $S_TRUE) (i32.const 4))
  (call $o_kv (global.get $K_base_root) (global.get $K_base_root_n)) (call $o_member_str (local.get $d) (global.get $K_baseRoot) (global.get $K_baseRoot_n))
  (call $o_kv (global.get $K_new_root) (global.get $K_new_root_n)) (call $o_member_str (local.get $d) (global.get $K_newRoot) (global.get $K_newRoot_n))
  (call $o_kv (global.get $K_tokens) (global.get $K_tokens_n))
  (call $o_i64 (call $int_of (call $get (local.get $d) (global.get $K_deltaTokens) (global.get $K_deltaTokens_n))))
  (call $o_kv (global.get $K_savings) (global.get $K_savings_n)) (call $o_i64 (local.get $sv))
  (call $o_byte (i32.const 0x25)) (call $o_byte (i32.const 0x0A))
  (call $array_of (call $get (local.get $d) (global.get $K_removed) (global.get $K_removed_n))) (local.set $cnt) (local.set $list)
  (if (local.get $cnt)
    (then
      (call $o_bytes (global.get $S_SECTION) (i32.const 3)) (call $o_bytes (global.get $K_removed) (global.get $K_removed_n)) (call $o_byte (i32.const 0x0A))
      (block $done (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $cnt)))
        (local.set $s (i32.add (local.get $list) (i32.shl (local.get $i) (i32.const 4))))
        (call $str_or_empty (local.get $s) (global.get $K_kind) (global.get $K_kind_n)) (local.set $n) (local.set $p)
        (call $abbreviate_kind (local.get $p) (local.get $n)) (local.set $kn) (local.set $kp)
        (call $o_bytes (local.get $kp) (local.get $kn))
        (call $o_byte (i32.const 0x20))
        (call $o_member_str (local.get $s) (global.get $K_qualifiedName) (global.get $K_qualifiedName_n))
        (call $o_byte (i32.const 0x0A))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))))
  (call $array_of (call $get (local.get $d) (global.get $K_added) (global.get $K_added_n))) (local.set $cnt) (local.set $list)
  (if (local.get $cnt)
    (then
      (call $o_bytes (global.get $S_SECTION) (i32.const 3)) (call $o_bytes (global.get $K_added) (global.get $K_added_n)) (call $o_byte (i32.const 0x0A))
      (local.set $i (i32.const 0))
      (block $done (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $cnt)))
        (local.set $s (i32.add (local.get $list) (i32.shl (local.get $i) (i32.const 4))))
        (call $o_node_line (i64.extend_i32_u (local.get $i)) (local.get $s))
        (call $o_byte (i32.const 0x20))
        (call $o_i64 (call $int_of (call $get (local.get $s) (global.get $K_distance) (global.get $K_distance_n))))
        (call $o_byte (i32.const 0x0A))
        (if (global.get $err) (then (return)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))))
  (local.set $k (i32.const 0))
  (block $kd (loop $kl
    (br_if $kd (i32.ge_u (local.get $k) (i32.const 2)))
    (if (local.get $k)
      (then (call $array_of (call $get (local.get $d) (global.get $K_addedEdges) (global.get $K_addedEdges_n))) (local.set $cnt) (local.set $list)
            (local.set $kp (global.get $K_edges_added)) (local.set $kn (global.get $K_edges_added_n)))
      (else (call $array_of (call $get (local.get $d) (global.get $K_removedEdges) (global.get $K_removedEdges_n))) (local.set $cnt) (local.set $list)
            (local.set $kp (global.get $K_edges_removed)) (local.set $kn (global.get $K_edges_removed_n))))
    (if (local.get $cnt)
      (then
        (call $o_bytes (global.get $S_SECTION) (i32.const 3)) (call $o_bytes (local.get $kp) (local.get $kn)) (call $o_byte (i32.const 0x0A))
        (local.set $i (i32.const 0))
        (block $done (loop $l
          (br_if $done (i32.ge_u (local.get $i) (local.get $cnt)))
          (local.set $s (i32.add (local.get $list) (i32.shl (local.get $i) (i32.const 4))))
          (call $o_member_str (local.get $s) (global.get $K_source) (global.get $K_source_n))
          (call $o_bytes (global.get $K_sp_arrow) (i32.const 4))
          (call $o_member_str (local.get $s) (global.get $K_target) (global.get $K_target_n))
          (call $o_byte (i32.const 0x20))
          (call $o_member_str (local.get $s) (global.get $K_edgeType) (global.get $K_edgeType_n))
          (call $o_byte (i32.const 0x0A))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $l)))))
    (local.set $k (i32.add (local.get $k) (i32.const 1)))
    (br $kl))))

;; ---------------------------------------------------------------------------
;; Exports (input: JSON with unique keys; output: GCF text)
;; ---------------------------------------------------------------------------

;; Parse the input (duplicate keys rejected) into a node; 0 on error.
(func $json_input_strict (param $len i32) (result i32)
  (local $q i32) (local $vt i32) (local $va i32) (local $vb i64)
  (call $parse_json (global.get $in_ptr) (local.get $len) (i32.const 1)) (local.set $vb) (local.set $va) (local.set $vt)
  (if (global.get $err) (then (return (i32.const 0))))
  (local.set $q (call $alloc (i32.const 16)))
  (if (local.get $q) (then (call $store_node (local.get $q) (local.get $vt) (local.get $va) (local.get $vb))))
  (local.get $q))

;; Finish a cursor-written output.
(func $finish_out (result i32)
  (call $w_sync)
  (global.set $unsafe_ints (i32.const 0))
  (if (global.get $err) (then (return (global.get $err))))
  (call $out_finish)
  (i32.const 0))

(func (export "gcf_encode_graph") (param $len i32) (result i32)
  (local $in i32)
  (local.set $in (call $json_input_strict (local.get $len)))
  (if (global.get $err) (then (return (global.get $err))))
  (call $w_begin (i32.add (local.get $len) (i32.const 64)))
  (call $encode_graph (local.get $in))
  (call $finish_out))

(func (export "gcf_encode_graph_cols") (param $len i32) (result i32)
  (local $h i32)
  (local.set $h (call $graph_cols_from_input (global.get $in_ptr) (local.get $len)))
  (if (global.get $err) (then (return (global.get $err))))
  (call $w_begin (i32.add (local.get $len) (i32.const 64)))
  (call $encode_graph_cols (local.get $h))
  (call $finish_out))

(func (export "gcf_encode_graph_session") (param $len i32) (result i32)
  (local $in i32)
  (local.set $in (call $json_input_strict (local.get $len)))
  (if (global.get $err) (then (return (global.get $err))))
  (call $w_begin (i32.add (local.get $len) (i32.const 64)))
  (call $encode_graph_session (local.get $in))
  (call $finish_out))

(func (export "gcf_encode_graph_delta") (param $len i32) (result i32)
  (local $in i32)
  (local.set $in (call $json_input_strict (local.get $len)))
  (if (global.get $err) (then (return (global.get $err))))
  (call $w_begin (i32.add (local.get $len) (i32.const 64)))
  (call $encode_graph_delta (local.get $in))
  (call $finish_out))
