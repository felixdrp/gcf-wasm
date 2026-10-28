;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 felixdrp
;;
;; 06_generic.wat — the generic-profile decoder (SPEC §2a, §4, §7, §8).
;;
;; A line-oriented recursive-descent parser over a line table, mirroring
;; gcf.zig's GenericParser function for function so both builds accept and
;; reject exactly the same inputs with the same error categories.
;;
;; Containers of unknown size are collected on the scratch stacks
;; (STK_NODES / STK_MEMBERS) and copied once into the arena when they close.
;; Pointers into a stack are never held across a call that may push to it.

;; Line record (16 bytes): +0 text ptr, +4 text len, +8 indent level, +12 line no.
(global $lines (mut i32) (i32.const 0))
(global $nlines (mut i32) (i32.const 0))
(global $pos (mut i32) (i32.const 0))
(global $depth (mut i32) (i32.const 0))
;; Header pairs (16 bytes): key ptr, key len, value ptr, value len.
(global $hdr_pairs (mut i32) (i32.const 0))
(global $hdr_n (mut i32) (i32.const 0))
(global $profile (mut i32) (i32.const 0))  ;; 0 generic, 1 graph

(func $peek (result i32)
  (if (result i32) (i32.lt_u (global.get $pos) (global.get $nlines))
    (then (i32.add (global.get $lines) (i32.shl (global.get $pos) (i32.const 4))))
    (else (i32.const 0))))

(func $advance (global.set $pos (i32.add (global.get $pos) (i32.const 1))))

(func $enter (param $line i32)
  (global.set $depth (i32.add (global.get $depth) (i32.const 1)))
  (if (i32.gt_u (global.get $depth) (i32.const 128)) (then (call $fail (i32.const 45) (local.get $line)))))

(func $leave (global.set $depth (i32.sub (global.get $depth) (i32.const 1))))

;; Line field accessors.
(func $lt (param $l i32) (result i32) (i32.load (local.get $l)))
(func $ltn (param $l i32) (result i32) (i32.load offset=4 (local.get $l)))
(func $lind (param $l i32) (result i32) (i32.load offset=8 (local.get $l)))
(func $lno (param $l i32) (result i32) (i32.load offset=12 (local.get $l)))

;; Does the line text start with the static string (s, n)?
(func $lstarts (param $l i32) (param $s i32) (param $n i32) (result i32)
  (call $starts_with (i32.load (local.get $l)) (i32.load offset=4 (local.get $l)) (local.get $s) (local.get $n)))

;; ---------------------------------------------------------------------------
;; Document: header + line table (SPEC §4.1, §11, §16.5)
;; ---------------------------------------------------------------------------

(func $parse_header (param $p i32) (param $n i32)
  (local $i i32) (local $s i32) (local $e i32) (local $first i32) (local $eq i32) (local $q i32) (local $j i32)
  (local $found i32) (local $vp i32) (local $vn i32)
  (global.set $hdr_pairs (call $alloc (i32.shl (i32.add (call $count_byte (local.get $p) (local.get $n) (i32.const 0x20)) (i32.const 1)) (i32.const 4))))
  (if (global.get $err) (then (return)))
  (global.set $hdr_n (i32.const 0))
  (local.set $first (i32.const 1))
  (block $done (loop $tok
    (block $sp (loop $sl
      (br_if $sp (i32.ge_u (local.get $i) (local.get $n)))
      (br_if $sp (i32.ne (call $at (local.get $p) (local.get $i)) (i32.const 0x20)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $sl)))
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $s (local.get $i))
    (local.set $e (call $find_byte (local.get $p) (local.get $n) (local.get $i) (i32.const 0x20)))
    (if (i32.lt_s (local.get $e) (i32.const 0)) (then (local.set $e (local.get $n))))
    (local.set $i (local.get $e))
    (if (local.get $first)
      (then
        (local.set $first (i32.const 0))
        (if (i32.eqz (call $str_eq (i32.add (local.get $p) (local.get $s)) (i32.sub (local.get $e) (local.get $s)) (global.get $S_GCF) (i32.const 3)))
          (then (call $fail (i32.const 1) (i32.const 1)) (return)))  ;; missing_header
        (br $tok)))
    (local.set $eq (call $find_byte (i32.add (local.get $p) (local.get $s)) (i32.sub (local.get $e) (local.get $s)) (i32.const 0) (i32.const 0x3D)))
    (if (i32.lt_s (local.get $eq) (i32.const 0)) (then (call $fail (i32.const 4) (i32.const 1)) (return)))
    (if (i32.eqz (call $is_bare_key (i32.add (local.get $p) (local.get $s)) (local.get $eq))) (then (call $fail (i32.const 4) (i32.const 1)) (return)))
    (local.set $j (i32.const 0))
    (block $dd (loop $dl
      (br_if $dd (i32.ge_u (local.get $j) (global.get $hdr_n)))
      (local.set $q (i32.add (global.get $hdr_pairs) (i32.shl (local.get $j) (i32.const 4))))
      (if (call $str_eq (i32.load (local.get $q)) (i32.load offset=4 (local.get $q)) (i32.add (local.get $p) (local.get $s)) (local.get $eq))
        (then (call $fail (i32.const 5) (i32.const 1)) (return)))  ;; duplicate_header_field
      (local.set $j (i32.add (local.get $j) (i32.const 1)))
      (br $dl)))
    (local.set $q (i32.add (global.get $hdr_pairs) (i32.shl (global.get $hdr_n) (i32.const 4))))
    (i32.store (local.get $q) (i32.add (local.get $p) (local.get $s)))
    (i32.store offset=4 (local.get $q) (local.get $eq))
    (i32.store offset=8 (local.get $q) (i32.add (i32.add (local.get $p) (local.get $s)) (i32.add (local.get $eq) (i32.const 1))))
    (i32.store offset=12 (local.get $q) (i32.sub (i32.sub (local.get $e) (local.get $s)) (i32.add (local.get $eq) (i32.const 1))))
    (global.set $hdr_n (i32.add (global.get $hdr_n) (i32.const 1)))
    (br $tok)))
  (if (local.get $first) (then (call $fail (i32.const 1) (i32.const 1)) (return)))
  ;; 'profile' must exist and be the first field
  (local.set $j (i32.const 0))
  (block $pd (loop $pl
    (br_if $pd (i32.ge_u (local.get $j) (global.get $hdr_n)))
    (local.set $q (i32.add (global.get $hdr_pairs) (i32.shl (local.get $j) (i32.const 4))))
    (if (call $str_eq (i32.load (local.get $q)) (i32.load offset=4 (local.get $q)) (global.get $S_PROFILE) (i32.const 7))
      (then
        (if (local.get $j) (then (call $fail (i32.const 4) (i32.const 1)) (return)))
        (local.set $found (i32.const 1))
        (local.set $vp (i32.load offset=8 (local.get $q)))
        (local.set $vn (i32.load offset=12 (local.get $q)))))
    (local.set $j (i32.add (local.get $j) (i32.const 1)))
    (br $pl)))
  (if (i32.eqz (local.get $found)) (then (call $fail (i32.const 2) (i32.const 1)) (return)))  ;; missing_profile
  (if (call $str_eq (local.get $vp) (local.get $vn) (global.get $S_GENERIC) (i32.const 7))
    (then (global.set $profile (i32.const 0)) (return)))
  (if (call $str_eq (local.get $vp) (local.get $vn) (global.get $S_GRAPH) (i32.const 5))
    (then (global.set $profile (i32.const 1)) (return)))
  (call $fail (i32.const 3) (i32.const 1)))  ;; unknown_profile

;; Header field value equals "true"?
(func $header_flag (param $kp i32) (param $kn i32) (result i32)
  (local $j i32) (local $q i32)
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $j) (global.get $hdr_n)))
    (local.set $q (i32.add (global.get $hdr_pairs) (i32.shl (local.get $j) (i32.const 4))))
    (if (call $str_eq (i32.load (local.get $q)) (i32.load offset=4 (local.get $q)) (local.get $kp) (local.get $kn))
      (then (return (call $str_eq (i32.load offset=8 (local.get $q)) (i32.load offset=12 (local.get $q)) (global.get $S_TRUE) (i32.const 4)))))
    (local.set $j (i32.add (local.get $j) (i32.const 1)))
    (br $l)))
  (i32.const 0))

;; Validate, read the header, and build the line table in one pass: the table
;; is sized with a SIMD LF count and line ends are found with the SIMD
;; scanner. Blank lines and '# ' comments are dropped; tab indentation and odd
;; indentation are rejected.
(func $build_document (param $src i32) (param $len i32)
  (local $he i32) (local $hn i32) (local $p i32) (local $no i32) (local $nl i32) (local $rp i32) (local $rn i32)
  (local $sp i32) (local $c i32) (local $q i32) (local $tn i32)
  (drop (call $validate_utf8 (local.get $src) (local.get $len)))
  (if (global.get $err) (then (return)))
  (if (i32.eqz (call $starts_with (local.get $src) (local.get $len) (global.get $S_GCF) (i32.const 3)))
    (then (call $fail (i32.const 1) (i32.const 1)) (return)))
  (local.set $he (call $find_byte (local.get $src) (local.get $len) (i32.const 0) (i32.const 0x0A)))
  (if (i32.lt_s (local.get $he) (i32.const 0)) (then (local.set $he (local.get $len))))
  (local.set $hn (local.get $he))
  (if (i32.and (i32.gt_u (local.get $hn) (i32.const 0)) (i32.eq (call $at (local.get $src) (i32.sub (local.get $hn) (i32.const 1))) (i32.const 0x0D)))
    (then (local.set $hn (i32.sub (local.get $hn) (i32.const 1)))))
  (call $parse_header (local.get $src) (local.get $hn))
  (if (global.get $err) (then (return)))
  (global.set $lines (call $alloc (i32.shl (i32.add (call $count_byte (local.get $src) (local.get $len) (i32.const 0x0A)) (i32.const 1)) (i32.const 4))))
  (if (global.get $err) (then (return)))
  (global.set $nlines (i32.const 0))
  (local.set $p (select (i32.add (local.get $he) (i32.const 1)) (local.get $len) (i32.lt_u (local.get $he) (local.get $len))))
  (local.set $no (i32.const 1))
  (block $done (loop $next
    (br_if $done (i32.ge_u (local.get $p) (local.get $len)))
    (local.set $no (i32.add (local.get $no) (i32.const 1)))
    (local.set $nl (call $find_byte (local.get $src) (local.get $len) (local.get $p) (i32.const 0x0A)))
    (if (i32.lt_s (local.get $nl) (i32.const 0)) (then (local.set $nl (local.get $len))))
    (local.set $rp (i32.add (local.get $src) (local.get $p)))
    (local.set $rn (i32.sub (local.get $nl) (local.get $p)))
    (local.set $p (i32.add (local.get $nl) (i32.const 1)))
    (if (i32.and (i32.gt_u (local.get $rn) (i32.const 0)) (i32.eq (call $at (local.get $rp) (i32.sub (local.get $rn) (i32.const 1))) (i32.const 0x0D)))
      (then (local.set $rn (i32.sub (local.get $rn) (i32.const 1)))))
    (br_if $next (i32.eqz (local.get $rn)))
    (local.set $sp (i32.const 0))
    (block $sd (loop $sl
      (br_if $sd (i32.ge_u (local.get $sp) (local.get $rn)))
      (br_if $sd (i32.ne (call $at (local.get $rp) (local.get $sp)) (i32.const 0x20)))
      (local.set $sp (i32.add (local.get $sp) (i32.const 1)))
      (br $sl)))
    (br_if $next (i32.eq (local.get $sp) (local.get $rn)))  ;; whitespace-only == blank
    (local.set $c (call $at (local.get $rp) (local.get $sp)))
    (if (i32.eq (local.get $c) (i32.const 0x09))
      (then
        (call $trim (local.get $rp) (local.get $rn)) (local.set $tn) (drop)
        (br_if $next (i32.eqz (local.get $tn)))
        (call $fail (i32.const 20) (local.get $no)) (return)))  ;; tab_indentation
    (local.set $tn (i32.sub (local.get $rn) (local.get $sp)))
    (if (i32.eq (local.get $c) (i32.const 0x23))  ;; '#' comment
      (then
        (br_if $next (i32.eq (local.get $tn) (i32.const 1)))
        (br_if $next (i32.eq (call $at (local.get $rp) (i32.add (local.get $sp) (i32.const 1))) (i32.const 0x20)))))
    (if (i32.and (local.get $sp) (i32.const 1)) (then (call $fail (i32.const 21) (local.get $no)) (return)))  ;; invalid_indent
    (local.set $q (i32.add (global.get $lines) (i32.shl (global.get $nlines) (i32.const 4))))
    (i32.store (local.get $q) (i32.add (local.get $rp) (local.get $sp)))
    (i32.store offset=4 (local.get $q) (local.get $tn))
    (i32.store offset=8 (local.get $q) (i32.shr_u (local.get $sp) (i32.const 1)))
    (i32.store offset=12 (local.get $q) (local.get $no))
    (global.set $nlines (i32.add (global.get $nlines) (i32.const 1)))
    (br $next))))

;; ---------------------------------------------------------------------------
;; Array headers
;; ---------------------------------------------------------------------------

;; `[N]`, `[?]`, `[N:]`, optional `{fields}`, then `: values` or ` group=col`.
;; Header record (56 bytes):
;;   +0 count (i64)  +8 has_count  +12 keyed
;;   +16 fields  +20 field count  +24 has_fields
;;   +28 inline ptr  +32 inline len  +36 has_inline
;;   +40 group ptr  +44 group len  +48 has_group
(func $array_header (param $p i32) (param $n i32) (param $line i32) (result i32)
  (local $h i32) (local $close i32) (local $cn i32) (local $rp i32) (local $rn i32)
  (local $kp i32) (local $kn i32) (local $kr i32) (local $krn i32) (local $fp i32) (local $fn i32)
  (local.set $close (call $find_byte (local.get $p) (local.get $n) (i32.const 1) (i32.const 0x5D)))
  (if (i32.lt_s (local.get $close) (i32.const 0)) (then (call $fail (i32.const 19) (local.get $line)) (return (i32.const 0))))
  (local.set $h (call $alloc (i32.const 56)))
  (if (global.get $err) (then (return (i32.const 0))))
  (memory.fill (local.get $h) (i32.const 0) (i32.const 56))
  ;; count text is p[1 .. close); a trailing ':' marks a keyed map
  (local.set $cn (i32.sub (local.get $close) (i32.const 1)))
  (if (i32.and (i32.gt_u (local.get $cn) (i32.const 0)) (i32.eq (call $at (local.get $p) (local.get $cn)) (i32.const 0x3A)))
    (then
      (i32.store offset=12 (local.get $h) (i32.const 1))
      (local.set $cn (i32.sub (local.get $cn) (i32.const 1)))))
  (if (i32.eqz (i32.and (i32.eq (local.get $cn) (i32.const 1)) (i32.eq (call $at (local.get $p) (i32.const 1)) (i32.const 0x3F))))
    (then
      (i64.store (local.get $h) (call $count (i32.add (local.get $p) (i32.const 1)) (local.get $cn) (local.get $line)))
      (if (global.get $err) (then (return (i32.const 0))))
      (i32.store offset=8 (local.get $h) (i32.const 1))))
  (local.set $rp (i32.add (local.get $p) (i32.add (local.get $close) (i32.const 1))))
  (local.set $rn (i32.sub (local.get $n) (i32.add (local.get $close) (i32.const 1))))
  (if (i32.and (i32.gt_u (local.get $rn) (i32.const 0)) (i32.eq (i32.load8_u (local.get $rp)) (i32.const 0x7B)))
    (then
      (call $field_decl (local.get $rp) (local.get $rn) (local.get $line) (i32.const 0))
      (local.set $rn) (local.set $rp) (local.set $fn) (local.set $fp)
      (if (global.get $err) (then (return (i32.const 0))))
      (i32.store offset=16 (local.get $h) (local.get $fp))
      (i32.store offset=20 (local.get $h) (local.get $fn))
      (i32.store offset=24 (local.get $h) (i32.const 1))))
  (if (i32.and (i32.gt_u (local.get $rn) (i32.const 0)) (i32.eq (i32.load8_u (local.get $rp)) (i32.const 0x3A)))
    (then
      (if (i32.or (i32.load offset=24 (local.get $h)) (i32.load offset=12 (local.get $h)))
        (then (call $fail (i32.const 29) (local.get $line)) (return (i32.const 0))))
      (call $trim (i32.add (local.get $rp) (i32.const 1)) (i32.sub (local.get $rn) (i32.const 1)))
      (local.set $kn) (local.set $kp)
      (i32.store offset=28 (local.get $h) (local.get $kp))
      (i32.store offset=32 (local.get $h) (local.get $kn))
      (i32.store offset=36 (local.get $h) (i32.const 1))
      (return (local.get $h))))
  (if (call $starts_with (local.get $rp) (local.get $rn) (global.get $S_GROUP) (i32.const 7))
    (then
      (if (i32.or (i32.eqz (i32.load offset=24 (local.get $h))) (i32.load offset=12 (local.get $h)))
        (then (call $fail (i32.const 32) (local.get $line)) (return (i32.const 0))))
      (call $key (i32.add (local.get $rp) (i32.const 7)) (i32.sub (local.get $rn) (i32.const 7)) (local.get $line))
      (local.set $krn) (local.set $kr) (local.set $kn) (local.set $kp)
      (if (global.get $err) (then (return (i32.const 0))))
      (call $trim (local.get $kr) (local.get $krn)) (local.set $krn) (drop)
      (if (local.get $krn) (then (call $fail (i32.const 32) (local.get $line)) (return (i32.const 0))))
      (i32.store offset=40 (local.get $h) (local.get $kp))
      (i32.store offset=44 (local.get $h) (local.get $kn))
      (i32.store offset=48 (local.get $h) (i32.const 1))
      (return (local.get $h))))
  (call $trim (local.get $rp) (local.get $rn)) (local.set $rn) (drop)
  (if (local.get $rn) (then (call $fail (i32.const 29) (local.get $line)) (return (i32.const 0))))
  (local.get $h))

;; ---------------------------------------------------------------------------
;; Root, summary trailer, objects
;; ---------------------------------------------------------------------------

(func $root (result i32 i32 i64)
  (local $l i32) (local $t i32) (local $tn i32) (local $no i32) (local $h i32)
  (local $vt i32) (local $va i32) (local $vb i64)
  (local.set $l (call $peek))
  (if (i32.eqz (local.get $l)) (then (return (i32.const 7) (i32.const 0) (i64.const 0))))
  (local.set $t (call $lt (local.get $l))) (local.set $tn (call $ltn (local.get $l))) (local.set $no (call $lno (local.get $l)))
  (if (call $lind (local.get $l)) (then (call $fail (i32.const 21) (local.get $no)) (return (call $nil))))
  (block $have
    (if (i32.eq (i32.load8_u (local.get $t)) (i32.const 0x3D))  ;; '=' scalar root
      (then
        (call $advance)
        (call $scalar (i32.add (local.get $t) (i32.const 1)) (i32.sub (local.get $tn) (i32.const 1)) (i32.const 1) (local.get $no))
        (local.set $vb) (local.set $va) (local.set $vt)
        (br $have)))
    (if (call $lstarts (local.get $l) (global.get $S_HDRARR) (i32.const 4))  ;; "## [" anonymous root array
      (then
        (call $advance)
        (local.set $h (call $array_header (i32.add (local.get $t) (i32.const 3)) (i32.sub (local.get $tn) (i32.const 3)) (local.get $no)))
        (if (global.get $err) (then (return (call $nil))))
        (call $array_body (local.get $h) (i32.const 0) (i32.const 0) (local.get $no) (i32.const 0))
        (local.set $vb) (local.set $va) (local.set $vt)
        (br $have)))
    (if (call $lstarts (local.get $l) (global.get $S_SUMMARY) (i32.const 3))
      (then (local.set $vt (i32.const 7)) (br $have)))
    (call $object_body (i32.const 0))
    (local.set $vb) (local.set $va) (local.set $vt))
  (if (global.get $err) (then (return (call $nil))))
  ;; optional trailer, then nothing else
  (local.set $l (call $peek))
  (if (local.get $l)
    (then
      (if (i32.and (i32.eqz (call $lind (local.get $l))) (call $lstarts (local.get $l) (global.get $S_SUMMARY) (i32.const 3)))
        (then
          (call $advance)
          (call $summary (local.get $l))
          (if (global.get $err) (then (return (call $nil))))))))
  (local.set $l (call $peek))
  (if (local.get $l) (then (call $fail_msg (i32.const 29) (call $lno (local.get $l)) (i32.const 70)) (return (call $nil))))
  (local.get $vt) (local.get $va) (local.get $vb))

;; `##! summary counts=a,b,...`: validate the deferred [?] sections in
;; document encounter order (SPEC §8.4, §13.2).
(func $summary (param $l i32)
  (local $t i32) (local $tn i32) (local $no i32) (local $i i32) (local $s i32) (local $e i32) (local $eq i32)
  (local $vp i32) (local $vn i32) (local $idx i32) (local $ps i32) (local $pe i32) (local $c i64) (local $nd i32) (local $d i32)
  (local.set $t (call $lt (local.get $l))) (local.set $tn (call $ltn (local.get $l))) (local.set $no (call $lno (local.get $l)))
  (if (i32.eqz (call $lstarts (local.get $l) (global.get $S_SUMMARY) (i32.const 11)))
    (then (call $fail (i32.const 29) (local.get $no)) (return)))
  (local.set $nd (i32.shr_u (call $stack_len (global.get $STK_DEFER)) (i32.const 4)))
  (local.set $i (i32.const 11))
  (block $done (loop $tok
    (block $sd (loop $sl
      (br_if $sd (i32.ge_u (local.get $i) (local.get $tn)))
      (br_if $sd (i32.ne (call $at (local.get $t) (local.get $i)) (i32.const 0x20)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $sl)))
    (br_if $done (i32.ge_u (local.get $i) (local.get $tn)))
    (local.set $s (local.get $i))
    (local.set $e (call $find_byte (local.get $t) (local.get $tn) (local.get $i) (i32.const 0x20)))
    (if (i32.lt_s (local.get $e) (i32.const 0)) (then (local.set $e (local.get $tn))))
    (local.set $i (local.get $e))
    (local.set $eq (call $find_byte (i32.add (local.get $t) (local.get $s)) (i32.sub (local.get $e) (local.get $s)) (i32.const 0) (i32.const 0x3D)))
    (if (i32.lt_s (local.get $eq) (i32.const 0)) (then (call $fail (i32.const 4) (local.get $no)) (return)))
    (br_if $tok (i32.eqz (call $str_eq (i32.add (local.get $t) (local.get $s)) (local.get $eq) (global.get $S_COUNTS) (i32.const 6))))
    (local.set $vp (i32.add (i32.add (local.get $t) (local.get $s)) (i32.add (local.get $eq) (i32.const 1))))
    (local.set $vn (i32.sub (i32.sub (local.get $e) (local.get $s)) (i32.add (local.get $eq) (i32.const 1))))
    (if (i32.ge_s (call $find_byte (local.get $vp) (local.get $vn) (i32.const 0) (i32.const 0x3A)) (i32.const 0))
      (then (call $fail (i32.const 4) (local.get $no)) (return)))  ;; generic counts are positional
    (local.set $idx (i32.const 0))
    (local.set $ps (i32.const 0))
    (block $pd (loop $pl
      (local.set $pe (call $find_byte (local.get $vp) (local.get $vn) (local.get $ps) (i32.const 0x2C)))
      (if (i32.lt_s (local.get $pe) (i32.const 0)) (then (local.set $pe (local.get $vn))))
      (local.set $c (call $count (i32.add (local.get $vp) (local.get $ps)) (i32.sub (local.get $pe) (local.get $ps)) (local.get $no)))
      (if (global.get $err) (then (return)))
      (if (i32.ge_u (local.get $idx) (local.get $nd)) (then (call $fail (i32.const 18) (local.get $no)) (return)))
      (local.set $d (i32.add (call $stack_base (global.get $STK_DEFER)) (i32.shl (local.get $idx) (i32.const 4))))
      (if (i64.ne (i64.load (local.get $d)) (local.get $c))
        (then (call $fail (i32.const 18) (i32.load offset=8 (local.get $d))) (return)))
      (local.set $idx (i32.add (local.get $idx) (i32.const 1)))
      (br_if $pd (i32.eq (local.get $pe) (local.get $vn)))
      (local.set $ps (i32.add (local.get $pe) (i32.const 1)))
      (br $pl)))
    (if (i32.ne (local.get $idx) (local.get $nd)) (then (call $fail (i32.const 18) (local.get $no)) (return)))
    (br $tok))))

;; Members at exactly `indent`; stops at a dedent or at a trailer.
(func $object_body (param $indent i32) (result i32 i32 i64)
  (local $l i32) (local $mark i32) (local $cnt i32) (local $set i32) (local $kp i32) (local $kn i32)
  (local $vt i32) (local $va i32) (local $vb i64) (local $m i32) (local $i i32) (local $q i32)
  (local.set $mark (call $stack_len (global.get $STK_MEMBERS)))
  (block $done (loop $next
    (local.set $l (call $peek))
    (br_if $done (i32.eqz (local.get $l)))
    (br_if $done (i32.lt_u (call $lind (local.get $l)) (local.get $indent)))
    (if (i32.gt_u (call $lind (local.get $l)) (local.get $indent))
      (then (call $fail (i32.const 21) (call $lno (local.get $l))) (return (call $nil))))
    (if (call $lstarts (local.get $l) (global.get $S_SUMMARY) (i32.const 3))
      (then
        (if (local.get $indent) (then (call $fail (i32.const 29) (call $lno (local.get $l))) (return (call $nil))))
        (br $done)))
    (call $advance)
    (call $member (local.get $l) (local.get $indent))
    (local.set $vb) (local.set $va) (local.set $vt) (local.set $kn) (local.set $kp)
    (if (global.get $err) (then (return (call $nil))))
    ;; duplicate keys: linear scan of the members so far, hash set from 8 on
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
          (then (call $fail (i32.const 15) (call $lno (local.get $l))) (return (call $nil)))))
      (else
        (local.set $m (i32.add (call $stack_base (global.get $STK_MEMBERS)) (local.get $mark)))
        (local.set $i (i32.const 0))
        (block $sd (loop $sl
          (br_if $sd (i32.ge_u (local.get $i) (local.get $cnt)))
          (if (call $str_eq (i32.load (local.get $m)) (i32.load offset=4 (local.get $m)) (local.get $kp) (local.get $kn))
            (then (call $fail (i32.const 15) (call $lno (local.get $l))) (return (call $nil))))
          (local.set $m (i32.add (local.get $m) (i32.const 24)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $sl)))))
    (local.set $q (call $stack_push (global.get $STK_MEMBERS) (i32.const 24)))
    (if (global.get $err) (then (return (call $nil))))
    (call $store_member (local.get $q) (local.get $kp) (local.get $kn) (local.get $vt) (local.get $va) (local.get $vb))
    (local.set $cnt (i32.add (local.get $cnt) (i32.const 1)))
    (br $next)))
  (i32.const 7)
  (call $stack_pop_to_arena (global.get $STK_MEMBERS) (local.get $mark))
  (i64.extend_i32_u (local.get $cnt)))

;; One object member line (and its body). Returns (key ptr, key len, value).
(func $member (param $l i32) (param $indent i32) (result i32 i32 i32 i32 i64)
  (local $t i32) (local $tn i32) (local $no i32) (local $kp i32) (local $kn i32) (local $rp i32) (local $rn i32) (local $h i32)
  (local $vt i32) (local $va i32) (local $vb i64)
  (local.set $t (call $lt (local.get $l))) (local.set $tn (call $ltn (local.get $l))) (local.set $no (call $lno (local.get $l)))
  (if (call $lstarts (local.get $l) (global.get $S_SECTION) (i32.const 3))  ;; "## "
    (then
      (if (i32.and (i32.gt_u (local.get $tn) (i32.const 3)) (i32.eq (call $at (local.get $t) (i32.const 3)) (i32.const 0x5B)))
        (then (call $fail (i32.const 29) (local.get $no)) (return (call $nil5))))  ;; anonymous array only at the root
      (call $key (i32.add (local.get $t) (i32.const 3)) (i32.sub (local.get $tn) (i32.const 3)) (local.get $no))
      (local.set $rn) (local.set $rp) (local.set $kn) (local.set $kp)
      (if (global.get $err) (then (return (call $nil5))))
      (if (i32.eqz (local.get $rn))
        (then
          ;; `## key`: nested object, body one level deeper
          (call $enter (local.get $no))
          (if (global.get $err) (then (return (call $nil5))))
          (call $object_body (i32.add (local.get $indent) (i32.const 1)))
          (local.set $vb) (local.set $va) (local.set $vt)
          (call $leave)
          (return (local.get $kp) (local.get $kn) (local.get $vt) (local.get $va) (local.get $vb))))
      (if (i32.eqz (call $starts_with (local.get $rp) (local.get $rn) (global.get $S_SPBR) (i32.const 2)))
        (then (call $fail (i32.const 29) (local.get $no)) (return (call $nil5))))
      (local.set $h (call $array_header (i32.add (local.get $rp) (i32.const 1)) (i32.sub (local.get $rn) (i32.const 1)) (local.get $no)))
      (if (global.get $err) (then (return (call $nil5))))
      (if (i32.load offset=36 (local.get $h)) (then (call $fail (i32.const 29) (local.get $no)) (return (call $nil5))))
      (call $enter (local.get $no))
      (if (global.get $err) (then (return (call $nil5))))
      ;; `## key [N]...`: rows at the header's own indentation
      (call $array_body (local.get $h) (local.get $indent) (i32.const 1) (local.get $no) (i32.const 0))
      (local.set $vb) (local.set $va) (local.set $vt)
      (call $leave)
      (return (local.get $kp) (local.get $kn) (local.get $vt) (local.get $va) (local.get $vb))))
  (if (i32.eq (i32.load8_u (local.get $t)) (i32.const 0x23)) (then (call $fail (i32.const 29) (local.get $no)) (return (call $nil5))))
  (call $key (local.get $t) (local.get $tn) (local.get $no))
  (local.set $rn) (local.set $rp) (local.set $kn) (local.set $kp)
  (if (global.get $err) (then (return (call $nil5))))
  (if (i32.and (i32.gt_u (local.get $rn) (i32.const 0)) (i32.eq (i32.load8_u (local.get $rp)) (i32.const 0x3D)))
    (then
      (call $scalar (i32.add (local.get $rp) (i32.const 1)) (i32.sub (local.get $rn) (i32.const 1)) (i32.const 1) (local.get $no))
      (local.set $vb) (local.set $va) (local.set $vt)
      (if (global.get $err) (then (return (call $nil5))))
      (call $no_children (local.get $indent))
      (return (local.get $kp) (local.get $kn) (local.get $vt) (local.get $va) (local.get $vb))))
  (if (i32.and (i32.gt_u (local.get $rn) (i32.const 0)) (i32.eq (i32.load8_u (local.get $rp)) (i32.const 0x5B)))
    (then
      (local.set $h (call $array_header (local.get $rp) (local.get $rn) (local.get $no)))
      (if (global.get $err) (then (return (call $nil5))))
      (if (i32.eqz (i32.load offset=36 (local.get $h))) (then (call $fail (i32.const 29) (local.get $no)) (return (call $nil5))))
      (call $array_body (local.get $h) (local.get $indent) (i32.const 1) (local.get $no) (i32.const 0))
      (local.set $vb) (local.set $va) (local.set $vt)
      (return (local.get $kp) (local.get $kn) (local.get $vt) (local.get $va) (local.get $vb))))
  (call $fail (i32.const 29) (local.get $no))
  (call $nil5))

;; Reject indented lines beneath a line that cannot own children.
(func $no_children (param $indent i32)
  (local $l i32)
  (local.set $l (call $peek))
  (if (local.get $l)
    (then (if (i32.gt_u (call $lind (local.get $l)) (local.get $indent))
      (then (call $fail (i32.const 21) (call $lno (local.get $l))))))))

;; ---------------------------------------------------------------------------
;; Arrays
;; ---------------------------------------------------------------------------

;; Dispatch on the header form (SPEC §7.3). `r` is the indentation of rows or
;; items; `cont` = 1 when sibling object members may follow; `shared` points
;; to the 8-byte (fields, count) shared-schema slot of a `.field [N]`
;; attachment column (SPEC §7.4.5.3), or is 0.
(func $array_body (param $h i32) (param $r i32) (param $cont i32) (param $line i32) (param $shared i32) (result i32 i32 i64)
  (local $di i32) (local $q i32) (local $cnt i64) (local $hasc i32) (local $vt i32) (local $va i32) (local $vb i64)
  (local.set $di (i32.const -1))
  (local.set $hasc (i32.load offset=8 (local.get $h)))
  (local.set $cnt (i64.load (local.get $h)))
  (if (i32.eqz (local.get $hasc))
    (then
      (local.set $di (call $stack_len (global.get $STK_DEFER)))
      (local.set $q (call $stack_push (global.get $STK_DEFER) (i32.const 16)))
      (if (global.get $err) (then (return (call $nil))))
      (i64.store (local.get $q) (i64.const 0))
      (i32.store offset=8 (local.get $q) (local.get $line))))
  (block $made
    (if (i32.load offset=48 (local.get $h))
      (then
        (if (i32.eqz (local.get $hasc)) (then (call $fail (i32.const 32) (local.get $line)) (return (call $nil))))
        (call $grouped_body (i32.load offset=16 (local.get $h)) (i32.load offset=20 (local.get $h))
                            (i32.load offset=40 (local.get $h)) (i32.load offset=44 (local.get $h)) (local.get $cnt) (local.get $r) (local.get $line))
        (local.set $vb) (local.set $va) (local.set $vt)
        (br $made)))
    (if (i32.load offset=36 (local.get $h))
      (then
        (call $inline_array (i32.load offset=28 (local.get $h)) (i32.load offset=32 (local.get $h)) (local.get $hasc) (local.get $cnt) (local.get $line))
        (local.set $vb) (local.set $va) (local.set $vt)
        (if (global.get $err) (then (return (call $nil))))
        (call $no_children (local.get $r))
        (br $made)))
    (if (i32.load offset=12 (local.get $h))
      (then
        (if (i32.eqz (i32.load offset=24 (local.get $h))) (then (call $fail (i32.const 4) (local.get $line)) (return (call $nil))))
        (if (i32.and (local.get $hasc) (i64.eqz (local.get $cnt)))
          (then (call $fail_msg (i32.const 19) (local.get $line) (i32.const 66)) (return (call $nil))))
        (if (i32.lt_u (i32.load offset=20 (local.get $h)) (i32.const 2))
          (then (call $fail_msg (i32.const 4) (local.get $line) (i32.const 65)) (return (call $nil))))
        (call $tabular_body (i32.load offset=16 (local.get $h)) (i32.load offset=20 (local.get $h)) (local.get $hasc) (local.get $cnt)
                            (local.get $r) (local.get $cont) (local.get $line) (i32.const 1))
        (local.set $vb) (local.set $va) (local.set $vt)
        (br $made)))
    (if (i32.load offset=24 (local.get $h))
      (then
        (if (local.get $shared)
          (then (if (i32.eqz (i32.load (local.get $shared)))
            (then
              (i32.store (local.get $shared) (i32.load offset=16 (local.get $h)))
              (i32.store offset=4 (local.get $shared) (i32.load offset=20 (local.get $h)))))))
        (call $tabular_body (i32.load offset=16 (local.get $h)) (i32.load offset=20 (local.get $h)) (local.get $hasc) (local.get $cnt)
                            (local.get $r) (local.get $cont) (local.get $line) (i32.const 0))
        (local.set $vb) (local.set $va) (local.set $vt)
        (br $made)))
    (if (i32.and (local.get $hasc) (i64.eqz (local.get $cnt)))
      (then (local.set $vt (i32.const 6)) (local.set $va (i32.const 0)) (local.set $vb (i64.const 0)) (br $made)))
    ;; `.field [N]` reusing the shared schema — unless the body's first line is
    ;; an `@N` item, which makes it an expanded array (reference rule).
    (if (local.get $shared)
      (then (if (i32.load (local.get $shared))
        (then (if (i32.eqz (call $next_is_item (local.get $r)))
          (then
            (call $tabular_body (i32.load (local.get $shared)) (i32.load offset=4 (local.get $shared)) (local.get $hasc) (local.get $cnt)
                                (local.get $r) (local.get $cont) (local.get $line) (i32.const 0))
            (local.set $vb) (local.set $va) (local.set $vt)
            (br $made)))))))
    (call $expanded_body (local.get $hasc) (local.get $cnt) (local.get $r) (local.get $line))
    (local.set $vb) (local.set $va) (local.set $vt))
  (if (global.get $err) (then (return (call $nil))))
  (if (i32.ge_s (local.get $di) (i32.const 0))
    (then (i64.store (i32.add (call $stack_base (global.get $STK_DEFER)) (local.get $di)) (local.get $vb))))
  (local.get $vt) (local.get $va) (local.get $vb))

(func $next_is_item (param $r i32) (result i32)
  (local $l i32)
  (local.set $l (call $peek))
  (if (i32.eqz (local.get $l)) (then (return (i32.const 0))))
  (i32.and (i32.eq (call $lind (local.get $l)) (local.get $r))
           (i32.eq (i32.load8_u (call $lt (local.get $l))) (i32.const 0x40))))

;; Split on `delim` outside quoted strings; pushes (ptr, len) pairs on
;; STK_MISC and returns their number.
(func $split (param $p i32) (param $n i32) (param $delim i32) (param $line i32) (result i32)
  (local $seg i32) (local $i i32) (local $hit i32) (local $cnt i32)
  (loop $l
    (local.set $hit (call $find_any2 (local.get $p) (local.get $n) (local.get $i) (local.get $delim) (i32.const 0x22)))
    (if (i32.lt_s (local.get $hit) (i32.const 0))
      (then
        (call $push_pair (global.get $STK_MISC) (i32.add (local.get $p) (local.get $seg)) (i32.sub (local.get $n) (local.get $seg)))
        (return (i32.add (local.get $cnt) (i32.const 1)))))
    (if (i32.eq (call $at (local.get $p) (local.get $hit)) (local.get $delim))
      (then
        (call $push_pair (global.get $STK_MISC) (i32.add (local.get $p) (local.get $seg)) (i32.sub (local.get $hit) (local.get $seg)))
        (local.set $cnt (i32.add (local.get $cnt) (i32.const 1)))
        (local.set $seg (i32.add (local.get $hit) (i32.const 1)))
        (local.set $i (local.get $seg)))
      (else
        (local.set $i (call $skip_quoted (local.get $p) (local.get $n) (local.get $hit) (local.get $line)))
        (if (global.get $err) (then (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))))
    (br $l))
  (unreachable))

;; `name[N]: a,b,"c,d"` (SPEC §7.5).
(func $inline_array (param $p i32) (param $n i32) (param $hasc i32) (param $exp i64) (param $line i32) (result i32 i32 i64)
  (local $mark i32) (local $cnt i32) (local $out i32) (local $i i32) (local $cell i32)
  (local $vt i32) (local $va i32) (local $vb i64)
  (if (i32.eqz (local.get $n))
    (then
      (if (i32.and (local.get $hasc) (i64.ne (local.get $exp) (i64.const 0)))
        (then (call $fail (i32.const 18) (local.get $line)) (return (call $nil))))
      (return (i32.const 6) (i32.const 0) (i64.const 0))))
  (local.set $mark (call $stack_len (global.get $STK_MISC)))
  (local.set $cnt (call $split (local.get $p) (local.get $n) (i32.const 0x2C) (local.get $line)))
  (if (global.get $err) (then (return (call $nil))))
  (if (i32.and (local.get $hasc) (i64.ne (local.get $exp) (i64.extend_i32_u (local.get $cnt))))
    (then (call $fail (i32.const 18) (local.get $line)) (return (call $nil))))
  (local.set $out (call $alloc (i32.shl (local.get $cnt) (i32.const 4))))
  (if (global.get $err) (then (return (call $nil))))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $cnt)))
    (local.set $cell (i32.add (call $stack_base (global.get $STK_MISC)) (i32.add (local.get $mark) (i32.shl (local.get $i) (i32.const 3)))))
    (call $scalar (i32.load (local.get $cell)) (i32.load offset=4 (local.get $cell)) (i32.const 1) (local.get $line))
    (local.set $vb) (local.set $va) (local.set $vt)
    (if (global.get $err) (then (return (call $nil))))
    (call $store_node (i32.add (local.get $out) (i32.shl (local.get $i) (i32.const 4))) (local.get $vt) (local.get $va) (local.get $vb))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (call $stack_truncate (global.get $STK_MISC) (local.get $mark))
  (i32.const 6) (local.get $out) (i64.extend_i32_u (local.get $cnt)))

;; Expanded per-item form: `@0 =x`, `@1 {}`, `@2 [M]...` (SPEC §7.6).
(func $expanded_body (param $hasc i32) (param $exp i64) (param $r i32) (param $line i32) (result i32 i32 i64)
  (local $mark i32) (local $items i64) (local $l i32) (local $t i32) (local $tn i32) (local $no i32) (local $sp i32) (local $id i64)
  (local $vt i32) (local $va i32) (local $vb i64) (local $q i32)
  (local.set $mark (call $stack_len (global.get $STK_NODES)))
  (block $done (loop $next
    (local.set $l (call $peek))
    (br_if $done (i32.eqz (local.get $l)))
    (br_if $done (i32.lt_u (call $lind (local.get $l)) (local.get $r)))
    (local.set $no (call $lno (local.get $l)))
    (if (i32.gt_u (call $lind (local.get $l)) (local.get $r)) (then (call $fail (i32.const 21) (local.get $no)) (return (call $nil))))
    (local.set $t (call $lt (local.get $l))) (local.set $tn (call $ltn (local.get $l)))
    (br_if $done (i32.ne (i32.load8_u (local.get $t)) (i32.const 0x40)))
    (if (i32.and (local.get $hasc) (i64.eq (local.get $items) (local.get $exp)))
      (then (call $fail (i32.const 18) (local.get $no)) (return (call $nil))))
    (call $advance)
    (local.set $sp (call $find_byte (local.get $t) (local.get $tn) (i32.const 0) (i32.const 0x20)))
    (if (i32.lt_s (local.get $sp) (i32.const 0)) (then (call $fail (i32.const 29) (local.get $no)) (return (call $nil))))
    (local.set $id (call $count (i32.add (local.get $t) (i32.const 1)) (i32.sub (local.get $sp) (i32.const 1)) (local.get $no)))
    (if (global.get $err) (then (call $retag (i32.const 22)) (return (call $nil))))  ;; invalid_item_id
    (if (i64.ne (local.get $id) (local.get $items)) (then (call $fail (i32.const 22) (local.get $no)) (return (call $nil))))
    (call $enter (local.get $no))
    (if (global.get $err) (then (return (call $nil))))
    (call $typed_value (i32.add (local.get $t) (i32.add (local.get $sp) (i32.const 1))) (i32.sub (local.get $tn) (i32.add (local.get $sp) (i32.const 1)))
                       (i32.add (local.get $r) (i32.const 1)) (local.get $no) (i32.const 1) (i32.const 0))
    (local.set $vb) (local.set $va) (local.set $vt)
    (if (global.get $err) (then (return (call $nil))))
    (call $leave)
    (local.set $q (call $stack_push (global.get $STK_NODES) (i32.const 16)))
    (if (global.get $err) (then (return (call $nil))))
    (call $store_node (local.get $q) (local.get $vt) (local.get $va) (local.get $vb))
    (local.set $items (i64.add (local.get $items) (i64.const 1)))
    (br $next)))
  (if (i32.and (local.get $hasc) (i64.ne (local.get $items) (local.get $exp)))
    (then (call $fail (i32.const 18) (local.get $line)) (return (call $nil))))
  (i32.const 6)
  (call $stack_pop_to_arena (global.get $STK_NODES) (local.get $mark))
  (local.get $items))

;; Value forms of expanded items and `.field` attachments: `=scalar` (items
;; only), `{}`, `[M]...`. Children live at indentation `child`.
(func $typed_value (param $p i32) (param $n i32) (param $child i32) (param $line i32) (param $allow_scalar i32) (param $shared i32) (result i32 i32 i64)
  (local $vt i32) (local $va i32) (local $vb i64) (local $tp i32) (local $tn i32) (local $h i32)
  (if (i32.and (local.get $allow_scalar) (i32.and (i32.gt_u (local.get $n) (i32.const 0)) (i32.eq (i32.load8_u (local.get $p)) (i32.const 0x3D))))
    (then
      (call $scalar (i32.add (local.get $p) (i32.const 1)) (i32.sub (local.get $n) (i32.const 1)) (i32.const 1) (local.get $line))
      (local.set $vb) (local.set $va) (local.set $vt)
      (if (global.get $err) (then (return (call $nil))))
      (call $no_children (i32.sub (local.get $child) (i32.const 1)))
      (return (local.get $vt) (local.get $va) (local.get $vb))))
  (call $trim (local.get $p) (local.get $n)) (local.set $tn) (local.set $tp)
  (if (call $str_eq (local.get $tp) (local.get $tn) (global.get $S_BRACES) (i32.const 2))
    (then (return (call $object_body (local.get $child)))))
  (if (i32.and (i32.gt_u (local.get $n) (i32.const 0)) (i32.eq (i32.load8_u (local.get $p)) (i32.const 0x5B)))
    (then
      (local.set $h (call $array_header (local.get $p) (local.get $n) (local.get $line)))
      (if (global.get $err) (then (return (call $nil))))
      (return (call $array_body (local.get $h) (local.get $child) (i32.const 0) (local.get $line) (local.get $shared)))))
  (call $fail (i32.const 29) (local.get $line))
  (call $nil))

;; ---------------------------------------------------------------------------
;; Tabular plan: columns and the record-assembly tree
;;
;; Plan (32 bytes): +0 columns, +4 column count, +8 bare cells, +12 nodes,
;;   +16 node count, +20 key column (-1 = none), +24 first root, +28 last root
;; Column (24 bytes): +0 name ptr, +4 name len, +8 kind (0 bare, 1 constant,
;;   2 group), +12 is_key, +16 constant node ptr, +20 cell index
;; Plan node (24 bytes): +0 name ptr, +4 name len, +8 column (-1 = interior),
;;   +12 first child, +16 last child, +20 next sibling (-1 = none)
;; ---------------------------------------------------------------------------

(func $plan (param $fields i32) (param $nf i32) (param $gp i32) (param $gn i32) (param $hasg i32) (param $skip i32) (param $line i32) (result i32)
  (local $pl i32) (local $cols i32) (local $i i32) (local $f i32) (local $c i32) (local $kind i32) (local $bare i32) (local $kc i32) (local $cap i32)
  (local.set $pl (call $alloc (i32.const 32)))
  (local.set $cols (call $alloc (i32.mul (local.get $nf) (i32.const 24))))
  (if (global.get $err) (then (return (i32.const 0))))
  (local.set $kc (i32.const -1))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $nf)))
    (local.set $f (i32.add (local.get $fields) (i32.shl (local.get $i) (i32.const 5))))
    (local.set $c (i32.add (local.get $cols) (i32.mul (local.get $i) (i32.const 24))))
    (local.set $kind (i32.const 0))
    (if (i32.load offset=12 (local.get $f))
      (then (local.set $kind (i32.const 1)))
      (else (if (local.get $hasg)
        (then (if (call $str_eq (i32.load (local.get $f)) (i32.load offset=4 (local.get $f)) (local.get $gp) (local.get $gn))
          (then (local.set $kind (i32.const 2))))))))
    (i32.store (local.get $c) (i32.load (local.get $f)))
    (i32.store offset=4 (local.get $c) (i32.load offset=4 (local.get $f)))
    (i32.store offset=8 (local.get $c) (local.get $kind))
    (i32.store offset=12 (local.get $c) (i32.load offset=8 (local.get $f)))
    (i32.store offset=16 (local.get $c) (i32.add (local.get $f) (i32.const 16)))
    (i32.store offset=20 (local.get $c) (local.get $bare))
    (if (i32.eqz (local.get $kind)) (then (local.set $bare (i32.add (local.get $bare) (i32.const 1)))))
    (if (i32.load offset=8 (local.get $f))
      (then
        (if (i32.and (i32.ge_s (local.get $kc) (i32.const 0)) (i32.eqz (local.get $hasg)))
          (then (call $fail (i32.const 4) (local.get $line)) (return (i32.const 0))))
        (local.set $kc (local.get $i))))
    (local.set $cap (i32.add (local.get $cap)
      (i32.add (call $count_byte (i32.load (local.get $f)) (i32.load offset=4 (local.get $f)) (i32.const 0x3E)) (i32.const 1))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (if (i32.eqz (local.get $bare)) (then (call $fail (i32.const 31) (local.get $line)) (return (i32.const 0))))  ;; no_bare_column
  (i32.store (local.get $pl) (local.get $cols))
  (i32.store offset=4 (local.get $pl) (local.get $nf))
  (i32.store offset=8 (local.get $pl) (local.get $bare))
  (i32.store offset=12 (local.get $pl) (call $alloc (i32.mul (local.get $cap) (i32.const 24))))
  (i32.store offset=16 (local.get $pl) (i32.const 0))
  (i32.store offset=20 (local.get $pl) (local.get $kc))
  (i32.store offset=24 (local.get $pl) (i32.const -1))
  (i32.store offset=28 (local.get $pl) (i32.const -1))
  (if (global.get $err) (then (return (i32.const 0))))
  (local.set $i (local.get $skip))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $nf)))
    (local.set $c (i32.add (local.get $cols) (i32.mul (local.get $i) (i32.const 24))))
    (call $insert_path (local.get $pl) (i32.load (local.get $c)) (i32.load offset=4 (local.get $c)) (local.get $i) (local.get $line))
    (if (global.get $err) (then (return (i32.const 0))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.get $pl))

(func $pnode (param $pl i32) (param $idx i32) (result i32)
  (i32.add (i32.load offset=12 (local.get $pl)) (i32.mul (local.get $idx) (i32.const 24))))

;; Child of `parent` (-1 = root level) named (p, n), or -1.
(func $plan_find (param $pl i32) (param $parent i32) (param $p i32) (param $n i32) (result i32)
  (local $idx i32) (local $nd i32)
  (local.set $idx (if (result i32) (i32.lt_s (local.get $parent) (i32.const 0))
    (then (i32.load offset=24 (local.get $pl)))
    (else (i32.load offset=12 (call $pnode (local.get $pl) (local.get $parent))))))
  (block $done (loop $l
    (br_if $done (i32.lt_s (local.get $idx) (i32.const 0)))
    (local.set $nd (call $pnode (local.get $pl) (local.get $idx)))
    (if (call $str_eq (i32.load (local.get $nd)) (i32.load offset=4 (local.get $nd)) (local.get $p) (local.get $n))
      (then (return (local.get $idx))))
    (local.set $idx (i32.load offset=20 (local.get $nd)))
    (br $l)))
  (i32.const -1))

;; Append a node under `parent` (-1 = root level); returns its index.
(func $plan_add (param $pl i32) (param $parent i32) (param $p i32) (param $n i32) (param $col i32) (result i32)
  (local $idx i32) (local $nd i32) (local $par i32)
  (local.set $idx (i32.load offset=16 (local.get $pl)))
  (i32.store offset=16 (local.get $pl) (i32.add (local.get $idx) (i32.const 1)))
  (local.set $nd (call $pnode (local.get $pl) (local.get $idx)))
  (i32.store (local.get $nd) (local.get $p))
  (i32.store offset=4 (local.get $nd) (local.get $n))
  (i32.store offset=8 (local.get $nd) (local.get $col))
  (i32.store offset=12 (local.get $nd) (i32.const -1))
  (i32.store offset=16 (local.get $nd) (i32.const -1))
  (i32.store offset=20 (local.get $nd) (i32.const -1))
  (if (i32.lt_s (local.get $parent) (i32.const 0))
    (then
      (if (i32.lt_s (i32.load offset=24 (local.get $pl)) (i32.const 0))
        (then (i32.store offset=24 (local.get $pl) (local.get $idx)))
        (else (i32.store offset=20 (call $pnode (local.get $pl) (i32.load offset=28 (local.get $pl))) (local.get $idx))))
      (i32.store offset=28 (local.get $pl) (local.get $idx)))
    (else
      (local.set $par (call $pnode (local.get $pl) (local.get $parent)))
      (if (i32.lt_s (i32.load offset=12 (local.get $par)) (i32.const 0))
        (then (i32.store offset=12 (local.get $par) (local.get $idx)))
        (else (i32.store offset=20 (call $pnode (local.get $pl) (i32.load offset=16 (local.get $par))) (local.get $idx))))
      (i32.store offset=16 (local.get $par) (local.get $idx))))
  (local.get $idx))

;; A field name containing '>' whose segments are all non-empty is a
;; flattened path column (SPEC §7.4.6.2); anything else is literal.
(func $insert_path (param $pl i32) (param $p i32) (param $n i32) (param $col i32) (param $line i32)
  (local $is_path i32) (local $i i32) (local $parent i32) (local $s i32) (local $e i32) (local $found i32)
  (local.set $is_path (i32.ge_s (call $find_byte (local.get $p) (local.get $n) (i32.const 0) (i32.const 0x3E)) (i32.const 0)))
  (if (local.get $is_path)
    (then
      (if (i32.or (i32.eq (i32.load8_u (local.get $p)) (i32.const 0x3E))
                  (i32.eq (call $at (local.get $p) (i32.sub (local.get $n) (i32.const 1))) (i32.const 0x3E)))
        (then (local.set $is_path (i32.const 0))))
      (local.set $i (i32.const 1))
      (block $done (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (if (i32.eq (i32.load16_u (i32.add (local.get $p) (i32.sub (local.get $i) (i32.const 1)))) (i32.const 0x3E3E))  ;; ">>"
          (then (local.set $is_path (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))))
  (if (i32.eqz (local.get $is_path))
    (then
      (if (i32.ge_s (call $plan_find (local.get $pl) (i32.const -1) (local.get $p) (local.get $n)) (i32.const 0))
        (then (call $fail (i32.const 15) (local.get $line)) (return)))
      (drop (call $plan_add (local.get $pl) (i32.const -1) (local.get $p) (local.get $n) (local.get $col)))
      (return)))
  (local.set $parent (i32.const -1))
  (block $done (loop $seg
    (local.set $e (call $find_byte (local.get $p) (local.get $n) (local.get $s) (i32.const 0x3E)))
    (br_if $done (i32.lt_s (local.get $e) (i32.const 0)))
    (local.set $found (call $plan_find (local.get $pl) (local.get $parent) (i32.add (local.get $p) (local.get $s)) (i32.sub (local.get $e) (local.get $s))))
    (if (i32.ge_s (local.get $found) (i32.const 0))
      (then
        (if (i32.ge_s (i32.load offset=8 (call $pnode (local.get $pl) (local.get $found))) (i32.const 0))
          (then (call $fail (i32.const 15) (local.get $line)) (return))))
      (else
        (local.set $found (call $plan_add (local.get $pl) (local.get $parent) (i32.add (local.get $p) (local.get $s)) (i32.sub (local.get $e) (local.get $s)) (i32.const -1)))))
    (local.set $parent (local.get $found))
    (local.set $s (i32.add (local.get $e) (i32.const 1)))
    (br $seg)))
  (if (i32.ge_s (call $plan_find (local.get $pl) (local.get $parent) (i32.add (local.get $p) (local.get $s)) (i32.sub (local.get $n) (local.get $s))) (i32.const 0))
    (then (call $fail (i32.const 15) (local.get $line)) (return)))
  (drop (call $plan_add (local.get $pl) (local.get $parent) (i32.add (local.get $p) (local.get $s)) (i32.sub (local.get $n) (local.get $s)) (local.get $col))))

;; Rebuild one level of a record from the row slots. Returns (kind, members,
;; count) with kind 0 = every leaf absent, 1 = every leaf null, 2 = mixed.
;; An interior node whose leaves are all `~` is omitted; all `-` leaves make a
;; *top-level* flattened field null (SPEC §7.4.6.2 rule 5).
(func $assemble_level (param $pl i32) (param $idx i32) (param $slots i32) (param $top i32) (result i32 i32 i32)
  (local $mark i32) (local $cnt i32) (local $absent i32) (local $allnull i32) (local $nd i32) (local $col i32) (local $s i32) (local $tag i32)
  (local $k i32) (local $sp i32) (local $sc i32) (local $q i32) (local $ptr i32)
  (local.set $mark (call $stack_len (global.get $STK_MEMBERS)))
  (local.set $absent (i32.const 1))
  (local.set $allnull (i32.const 1))
  (block $done (loop $l
    (br_if $done (i32.lt_s (local.get $idx) (i32.const 0)))
    (local.set $nd (call $pnode (local.get $pl) (local.get $idx)))
    (local.set $col (i32.load offset=8 (local.get $nd)))
    (if (i32.ge_s (local.get $col) (i32.const 0))
      (then
        (local.set $s (i32.add (local.get $slots) (i32.shl (local.get $col) (i32.const 4))))
        (local.set $tag (i32.load (local.get $s)))
        (if (i32.eq (local.get $tag) (i32.const 8))
          (then (local.set $allnull (i32.const 0)))
          (else
            (local.set $absent (i32.const 0))
            (if (local.get $tag) (then (local.set $allnull (i32.const 0))))
            (local.set $q (call $stack_push (global.get $STK_MEMBERS) (i32.const 24)))
            (if (global.get $err) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
            (i32.store (local.get $q) (i32.load (local.get $nd)))
            (i32.store offset=4 (local.get $q) (i32.load offset=4 (local.get $nd)))
            (v128.store offset=8 (local.get $q) (v128.load (local.get $s)))
            (local.set $cnt (i32.add (local.get $cnt) (i32.const 1))))))
      (else
        (call $assemble_level (local.get $pl) (i32.load offset=12 (local.get $nd)) (local.get $slots) (i32.const 0))
        (local.set $sc) (local.set $sp) (local.set $k)
        (if (global.get $err) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
        (if (i32.eqz (local.get $k))
          (then (local.set $allnull (i32.const 0)))
          (else
            (local.set $absent (i32.const 0))
            (if (i32.eq (local.get $k) (i32.const 2)) (then (local.set $allnull (i32.const 0))))
            (local.set $q (call $stack_push (global.get $STK_MEMBERS) (i32.const 24)))
            (if (global.get $err) (then (return (i32.const 0) (i32.const 0) (i32.const 0))))
            (if (i32.and (i32.eq (local.get $k) (i32.const 1)) (local.get $top))
              (then (call $store_member (local.get $q) (i32.load (local.get $nd)) (i32.load offset=4 (local.get $nd)) (i32.const 0) (i32.const 0) (i64.const 0)))
              (else (call $store_member (local.get $q) (i32.load (local.get $nd)) (i32.load offset=4 (local.get $nd))
                                        (i32.const 7) (local.get $sp) (i64.extend_i32_u (local.get $sc)))))
            (local.set $cnt (i32.add (local.get $cnt) (i32.const 1)))))))
    (local.set $idx (i32.load offset=20 (local.get $nd)))
    (br $l)))
  (local.set $ptr (call $stack_pop_to_arena (global.get $STK_MEMBERS) (local.get $mark)))
  (select (i32.const 0) (select (i32.const 1) (i32.const 2) (local.get $allnull)) (local.get $absent))
  (local.get $ptr)
  (local.get $cnt))

;; Column index by name, or -1.
(func $find_column (param $pl i32) (param $p i32) (param $n i32) (result i32)
  (local $i i32) (local $c i32)
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (i32.load offset=4 (local.get $pl))))
    (local.set $c (i32.add (i32.load (local.get $pl)) (i32.mul (local.get $i) (i32.const 24))))
    (if (call $str_eq (i32.load (local.get $c)) (i32.load offset=4 (local.get $c)) (local.get $p) (local.get $n))
      (then (return (local.get $i))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (i32.const -1))

;; ---------------------------------------------------------------------------
;; Rows
;; ---------------------------------------------------------------------------

;; Parse one row line into per-column slots (constants pre-filled).
;; Returns (row ID or -1, slots, number of attachment markers).
(func $row_line (param $l i32) (param $pl i32) (param $allow i32) (result i64 i32 i32)
  (local $t i32) (local $tn i32) (local $no i32) (local $id i64) (local $sp i32) (local $mark i32) (local $nc i32)
  (local $slots i32) (local $ncols i32) (local $i i32) (local $c i32) (local $s i32) (local $cell i32) (local $markers i32) (local $kind i32)
  (local $vt i32) (local $va i32) (local $vb i64)
  (local.set $t (call $lt (local.get $l))) (local.set $tn (call $ltn (local.get $l))) (local.set $no (call $lno (local.get $l)))
  (local.set $id (i64.const -1))
  (if (i32.eq (i32.load8_u (local.get $t)) (i32.const 0x40))
    (then
      (local.set $sp (call $find_byte (local.get $t) (local.get $tn) (i32.const 0) (i32.const 0x20)))
      (if (i32.lt_s (local.get $sp) (i32.const 0)) (then (call $fail (i32.const 22) (local.get $no)) (return (i64.const 0) (i32.const 0) (i32.const 0))))
      (local.set $id (call $count (i32.add (local.get $t) (i32.const 1)) (i32.sub (local.get $sp) (i32.const 1)) (local.get $no)))
      (if (global.get $err) (then (call $retag (i32.const 22)) (return (i64.const 0) (i32.const 0) (i32.const 0))))
      (local.set $t (i32.add (local.get $t) (i32.add (local.get $sp) (i32.const 1))))
      (local.set $tn (i32.sub (local.get $tn) (i32.add (local.get $sp) (i32.const 1))))))
  (local.set $mark (call $stack_len (global.get $STK_MISC)))
  (local.set $nc (call $split (local.get $t) (local.get $tn) (i32.const 0x7C) (local.get $no)))
  (if (global.get $err) (then (return (i64.const 0) (i32.const 0) (i32.const 0))))
  (if (i32.ne (local.get $nc) (i32.load offset=8 (local.get $pl)))
    (then (call $fail (i32.const 17) (local.get $no)) (return (i64.const 0) (i32.const 0) (i32.const 0))))  ;; row_width_mismatch
  (local.set $ncols (i32.load offset=4 (local.get $pl)))
  (local.set $slots (call $alloc (i32.shl (local.get $ncols) (i32.const 4))))
  (if (global.get $err) (then (return (i64.const 0) (i32.const 0) (i32.const 0))))
  (block $done (loop $lp
    (br_if $done (i32.ge_u (local.get $i) (local.get $ncols)))
    (local.set $c (i32.add (i32.load (local.get $pl)) (i32.mul (local.get $i) (i32.const 24))))
    (local.set $s (i32.add (local.get $slots) (i32.shl (local.get $i) (i32.const 4))))
    (local.set $kind (i32.load offset=8 (local.get $c)))
    (if (i32.eq (local.get $kind) (i32.const 1))
      (then (v128.store (local.get $s) (v128.load (i32.load offset=16 (local.get $c))))))
    (if (i32.eq (local.get $kind) (i32.const 2))
      (then (call $store_node (local.get $s) (i32.const 8) (i32.const 0) (i64.const 0))))
    (if (i32.eqz (local.get $kind))
      (then
        (local.set $cell (i32.add (call $stack_base (global.get $STK_MISC))
                                  (i32.add (local.get $mark) (i32.shl (i32.load offset=20 (local.get $c)) (i32.const 3)))))
        (call $scalar (i32.load (local.get $cell)) (i32.load offset=4 (local.get $cell)) (i32.const 0) (local.get $no))
        (local.set $vb) (local.set $va) (local.set $vt)
        (if (global.get $err) (then (return (i64.const 0) (i32.const 0) (i32.const 0))))
        (if (i32.eq (local.get $vt) (i32.const 9))
          (then
            (if (i32.eqz (local.get $allow)) (then (call $fail (i32.const 10) (local.get $no)) (return (i64.const 0) (i32.const 0) (i32.const 0))))
            (local.set $markers (i32.add (local.get $markers) (i32.const 1)))))
        (call $store_node (local.get $s) (local.get $vt) (local.get $va) (local.get $vb))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $lp)))
  (call $stack_truncate (global.get $STK_MISC) (local.get $mark))
  (local.get $id) (local.get $slots) (local.get $markers))

;; Next unmatched marker (header order) with an inline schema available.
(func $next_inline_marker (param $slots i32) (param $ncols i32) (param $inl i32) (result i32)
  (local $i i32) (local $s i32)
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ncols)))
    (local.set $s (i32.add (local.get $slots) (i32.shl (local.get $i) (i32.const 4))))
    (if (i32.eq (i32.load (local.get $s)) (i32.const 9))
      (then (if (i32.eqz (i32.load offset=12 (local.get $s)))
        (then (if (i32.or (i32.load offset=4 (local.get $s)) (i32.load (i32.add (local.get $inl) (i32.shl (local.get $i) (i32.const 3)))))
          (then (return (local.get $i))))))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (i32.const -1))

;; Consume the attachment bodies of the row at indent `r` (SPEC §7.4.4,
;; §7.4.5.2): `.field` headers at r or r+1 with bodies at r+2, and
;; positional inline bodies at r or r+1. Bare '>' attachments go to STK_EXTRA.
(func $attachments (param $slots i32) (param $pl i32) (param $r i32) (param $inl i32) (param $arr i32) (param $xmark i32) (param $row_line i32) (param $row_index i64)
  (local $ncols i32) (local $i i32) (local $s i32) (local $attached i32) (local $l i32) (local $t i32) (local $tn i32) (local $no i32)
  (local $kp i32) (local $kn i32) (local $rp i32) (local $rn i32) (local $ci i32) (local $tmp i32) (local $x i32) (local $xe i32)
  (local $vt i32) (local $va i32) (local $vb i64) (local $q i32) (local $mark i32) (local $nv i32) (local $schema i32) (local $sn i32)
  (local $members i32) (local $j i32) (local $f i32) (local $cell i32)
  (local.set $ncols (i32.load offset=4 (local.get $pl)))
  ;; markers with an inline schema in this row become the column's schema
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ncols)))
    (local.set $s (i32.add (local.get $slots) (i32.shl (local.get $i) (i32.const 4))))
    (if (i32.and (i32.eq (i32.load (local.get $s)) (i32.const 9)) (i32.ne (i32.load offset=4 (local.get $s)) (i32.const 0)))
      (then
        (i32.store (i32.add (local.get $inl) (i32.shl (local.get $i) (i32.const 3))) (i32.load offset=4 (local.get $s)))
        (i32.store offset=4 (i32.add (local.get $inl) (i32.shl (local.get $i) (i32.const 3))) (i32.load offset=8 (local.get $s)))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.set $attached (call $alloc (local.get $ncols)))
  (if (global.get $err) (then (return)))
  (memory.fill (local.get $attached) (i32.const 0) (local.get $ncols))
  (block $done (loop $next
    (local.set $l (call $peek))
    (br_if $done (i32.eqz (local.get $l)))
    (br_if $done (i32.lt_u (call $lind (local.get $l)) (local.get $r)))
    (local.set $no (call $lno (local.get $l)))
    (if (i32.gt_u (call $lind (local.get $l)) (i32.add (local.get $r) (i32.const 1)))
      (then (call $fail (i32.const 21) (local.get $no)) (return)))
    (local.set $t (call $lt (local.get $l))) (local.set $tn (call $ltn (local.get $l)))
    (if (i32.eq (i32.load8_u (local.get $t)) (i32.const 0x2E))  ;; '.field <value>'
      (then
        (call $advance)
        (call $key (i32.add (local.get $t) (i32.const 1)) (i32.sub (local.get $tn) (i32.const 1)) (local.get $no))
        (local.set $rn) (local.set $rp) (local.set $kn) (local.set $kp)
        (if (global.get $err) (then (return)))
        (if (i32.or (i32.eqz (local.get $rn)) (i32.ne (i32.load8_u (local.get $rp)) (i32.const 0x20)))
          (then (call $fail (i32.const 29) (local.get $no)) (return)))
        (local.set $ci (call $find_column (local.get $pl) (local.get $kp) (local.get $kn)))
        (call $enter (local.get $no))
        (if (global.get $err) (then (return)))
        (if (i32.ge_s (local.get $ci) (i32.const 0))
          (then
            (if (call $at (local.get $attached) (local.get $ci)) (then (call $fail (i32.const 26) (local.get $no)) (return)))
            (local.set $s (i32.add (local.get $slots) (i32.shl (local.get $ci) (i32.const 4))))
            (if (i32.ne (i32.load (local.get $s)) (i32.const 9)) (then (call $fail (i32.const 23) (local.get $no)) (return)))
            (if (i32.load offset=12 (local.get $s)) (then (call $fail (i32.const 26) (local.get $no)) (return)))
            (if (i32.load offset=4 (local.get $s)) (then (call $fail (i32.const 23) (local.get $no)) (return)))
            (i32.store offset=12 (local.get $s) (i32.const 1))
            ;; only the first row establishes a shared array schema
            (if (i64.eqz (local.get $row_index))
              (then (local.set $tmp (i32.add (local.get $arr) (i32.shl (local.get $ci) (i32.const 3)))))
              (else
                (local.set $tmp (call $alloc (i32.const 8)))
                (if (global.get $err) (then (return)))
                (i64.store (local.get $tmp) (i64.load (i32.add (local.get $arr) (i32.shl (local.get $ci) (i32.const 3)))))))
            (call $typed_value (i32.add (local.get $rp) (i32.const 1)) (i32.sub (local.get $rn) (i32.const 1))
                               (i32.add (local.get $r) (i32.const 2)) (local.get $no) (i32.const 0) (local.get $tmp))
            (local.set $vb) (local.set $va) (local.set $vt)
            (if (global.get $err) (then (return)))
            (call $store_node (local.get $s) (local.get $vt) (local.get $va) (local.get $vb))
            (i32.store8 (i32.add (local.get $attached) (local.get $ci)) (i32.const 1)))
          (else
            (if (i32.lt_s (call $find_byte (local.get $kp) (local.get $kn) (i32.const 0) (i32.const 0x3E)) (i32.const 0))
              (then (call $fail (i32.const 23) (local.get $no)) (return)))
            ;; SPEC §7.4.6.1.4: a '>'-containing field travels as a bare attachment
            (local.set $x (i32.add (call $stack_base (global.get $STK_EXTRA)) (local.get $xmark)))
            (local.set $xe (i32.add (call $stack_base (global.get $STK_EXTRA)) (call $stack_len (global.get $STK_EXTRA))))
            (block $xd (loop $xl
              (br_if $xd (i32.ge_u (local.get $x) (local.get $xe)))
              (if (call $str_eq (i32.load (local.get $x)) (i32.load offset=4 (local.get $x)) (local.get $kp) (local.get $kn))
                (then (call $fail (i32.const 26) (local.get $no)) (return)))
              (local.set $x (i32.add (local.get $x) (i32.const 24)))
              (br $xl)))
            (call $typed_value (i32.add (local.get $rp) (i32.const 1)) (i32.sub (local.get $rn) (i32.const 1))
                               (i32.add (local.get $r) (i32.const 2)) (local.get $no) (i32.const 1) (i32.const 0))
            (local.set $vb) (local.set $va) (local.set $vt)
            (if (global.get $err) (then (return)))
            (local.set $q (call $stack_push (global.get $STK_EXTRA) (i32.const 24)))
            (if (global.get $err) (then (return)))
            (call $store_member (local.get $q) (local.get $kp) (local.get $kn) (local.get $vt) (local.get $va) (local.get $vb))))
        (call $leave)
        (br $next)))
    ;; positional inline body
    (local.set $ci (call $next_inline_marker (local.get $slots) (local.get $ncols) (local.get $inl)))
    (br_if $done (i32.lt_s (local.get $ci) (i32.const 0)))
    (br_if $done (i32.and (i32.eq (call $lind (local.get $l)) (local.get $r)) (call $lstarts (local.get $l) (global.get $S_SUMMARY) (i32.const 2))))
    (call $advance)
    (local.set $schema (i32.load (i32.add (local.get $inl) (i32.shl (local.get $ci) (i32.const 3)))))
    (local.set $sn (i32.load offset=4 (i32.add (local.get $inl) (i32.shl (local.get $ci) (i32.const 3)))))
    (local.set $mark (call $stack_len (global.get $STK_MISC)))
    (local.set $nv (call $split (local.get $t) (local.get $tn) (i32.const 0x7C) (local.get $no)))
    (if (global.get $err) (then (return)))
    (if (i32.ne (local.get $nv) (local.get $sn)) (then (call $fail (i32.const 27) (local.get $no)) (return)))  ;; inline_width_mismatch
    (local.set $members (call $alloc (i32.mul (local.get $sn) (i32.const 24))))
    (if (global.get $err) (then (return)))
    (local.set $j (i32.const 0))
    (block $jd (loop $jl
      (br_if $jd (i32.ge_u (local.get $j) (local.get $sn)))
      (local.set $f (i32.add (local.get $schema) (i32.shl (local.get $j) (i32.const 5))))
      (local.set $cell (i32.add (call $stack_base (global.get $STK_MISC)) (i32.add (local.get $mark) (i32.shl (local.get $j) (i32.const 3)))))
      (call $scalar (i32.load (local.get $cell)) (i32.load offset=4 (local.get $cell)) (i32.const 1) (local.get $no))
      (local.set $vb) (local.set $va) (local.set $vt)
      (if (global.get $err) (then (return)))
      (call $store_member (i32.add (local.get $members) (i32.mul (local.get $j) (i32.const 24)))
                          (i32.load (local.get $f)) (i32.load offset=4 (local.get $f)) (local.get $vt) (local.get $va) (local.get $vb))
      (local.set $j (i32.add (local.get $j) (i32.const 1)))
      (br $jl)))
    (call $stack_truncate (global.get $STK_MISC) (local.get $mark))
    (call $store_node (i32.add (local.get $slots) (i32.shl (local.get $ci) (i32.const 4))) (i32.const 7) (local.get $members) (i64.extend_i32_u (local.get $sn)))
    (i32.store8 (i32.add (local.get $attached) (local.get $ci)) (i32.const 1))
    (br $next)))
  ;; every marker must have been filled
  (local.set $i (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ncols)))
    (if (i32.eq (i32.load (i32.add (local.get $slots) (i32.shl (local.get $i) (i32.const 4)))) (i32.const 9))
      (then (call $fail (i32.const 25) (local.get $row_line)) (return)))  ;; missing_attachment
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l))))

;; Does the text start like an object member (so a row scan must stop)?
(func $looks_like_member (param $p i32) (param $n i32) (result i32)
  (local $i i32) (local $c i32)
  (if (call $starts_with (local.get $p) (local.get $n) (global.get $S_SUMMARY) (i32.const 2)) (then (return (i32.const 1))))
  (if (i32.and (i32.gt_u (local.get $n) (i32.const 0)) (i32.eq (i32.load8_u (local.get $p)) (i32.const 0x22)))
    (then
      (local.set $i (call $find_close (local.get $p) (local.get $n) (i32.const 0)))
      (if (i32.lt_s (local.get $i) (i32.const 0)) (then (return (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1))))
    (else
      (block $done (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (br_if $done (i32.eqz (call $is_key_char (call $at (local.get $p) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (if (i32.eqz (call $is_bare_key (local.get $p) (local.get $i))) (then (return (i32.const 0))))))
  (if (i32.ge_u (local.get $i) (local.get $n)) (then (return (i32.const 0))))
  (local.set $c (call $at (local.get $p) (local.get $i)))
  (i32.or (i32.eq (local.get $c) (i32.const 0x3D)) (i32.eq (local.get $c) (i32.const 0x5B))))

;; Tabular array (SPEC §7.4) or keyed map (SPEC §7.2a) body at indent `r`.
(func $tabular_body (param $fields i32) (param $nf i32) (param $hasc i32) (param $exp i64) (param $r i32) (param $cont i32) (param $line i32) (param $keyed i32) (result i32 i32 i64)
  (local $pl i32) (local $inl i32) (local $arr i32) (local $mark i32) (local $keys i32) (local $ids i32) (local $n i64) (local $lri i32)
  (local $l i32) (local $t i32) (local $tn i32) (local $no i32) (local $id i64) (local $slots i32) (local $markers i32) (local $xmark i32)
  (local $i i32) (local $s i32) (local $rt i32) (local $rp i32) (local $rc i32) (local $xn i32) (local $kc i32) (local $ikp i32) (local $ikn i32)
  (local $q i32) (local $all i32) (local $j i32) (local $x i32) (local $m i32) (local $stk i32)
  (if (i32.and (local.get $keyed) (i32.load offset=12 (local.get $fields)))
    (then (call $fail (i32.const 30) (local.get $line)) (return (call $nil))))
  (local.set $pl (call $plan (local.get $fields) (local.get $nf) (i32.const 0) (i32.const 0) (i32.const 0) (local.get $keyed) (local.get $line)))
  (if (global.get $err) (then (return (call $nil))))
  (local.set $inl (call $alloc (i32.shl (local.get $nf) (i32.const 3))))
  (local.set $arr (call $alloc (i32.shl (local.get $nf) (i32.const 3))))
  (if (global.get $err) (then (return (call $nil))))
  (memory.fill (local.get $inl) (i32.const 0) (i32.shl (local.get $nf) (i32.const 3)))
  (memory.fill (local.get $arr) (i32.const 0) (i32.shl (local.get $nf) (i32.const 3)))
  (local.set $stk (select (global.get $STK_MEMBERS) (global.get $STK_NODES) (local.get $keyed)))
  (local.set $mark (call $stack_len (local.get $stk)))
  (local.set $kc (i32.load offset=20 (local.get $pl)))
  (if (local.get $keyed) (then (local.set $keys (call $ks_new))))
  (if (i32.and (i32.ge_s (local.get $kc) (i32.const 0)) (i32.or (i32.eqz (local.get $keyed)) (i32.ne (local.get $kc) (i32.const 0))))
    (then (local.set $ids (call $ks_new))))
  (if (global.get $err) (then (return (call $nil))))
  (block $done (loop $next
    (local.set $l (call $peek))
    (br_if $done (i32.eqz (local.get $l)))
    (br_if $done (i32.and (local.get $hasc) (i64.eq (local.get $n) (local.get $exp))))
    (br_if $done (i32.lt_u (call $lind (local.get $l)) (local.get $r)))
    (local.set $no (call $lno (local.get $l)))
    (if (i32.gt_u (call $lind (local.get $l)) (local.get $r)) (then (call $fail (i32.const 21) (local.get $no)) (return (call $nil))))
    (br_if $done (call $lstarts (local.get $l) (global.get $S_SUMMARY) (i32.const 2)))
    (br_if $done (i32.and (i32.and (i32.eqz (local.get $hasc)) (i32.eq (local.get $cont) (i32.const 1)))
                          (call $looks_like_member (call $lt (local.get $l)) (call $ltn (local.get $l)))))
    (call $advance)
    (call $row_line (local.get $l) (local.get $pl) (i32.const 1))
    (local.set $markers) (local.set $slots) (local.set $id)
    (if (global.get $err) (then (return (call $nil))))
    (if (i64.ne (local.get $id) (i64.const -1))
      (then (if (i64.ne (local.get $id) (local.get $n)) (then (call $fail (i32.const 22) (local.get $no)) (return (call $nil)))))
      (else (if (local.get $markers) (then (call $fail_msg (i32.const 22) (local.get $no) (i32.const 69)) (return (call $nil))))))
    ;; does this row end with an inline-schema marker? (surplus diagnostics)
    (local.set $lri (i32.const 0))
    (local.set $i (i32.const 0))
    (block $id2 (loop $il
      (br_if $id2 (i32.ge_u (local.get $i) (local.get $nf)))
      (local.set $s (i32.add (local.get $slots) (i32.shl (local.get $i) (i32.const 4))))
      (if (i32.eq (i32.load (local.get $s)) (i32.const 9))
        (then (if (i32.or (i32.load offset=4 (local.get $s)) (i32.load (i32.add (local.get $inl) (i32.shl (local.get $i) (i32.const 3)))))
          (then (local.set $lri (i32.const 1))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $il)))
    (local.set $xmark (call $stack_len (global.get $STK_EXTRA)))
    (call $attachments (local.get $slots) (local.get $pl) (local.get $r) (local.get $inl) (local.get $arr) (local.get $xmark) (local.get $no) (local.get $n))
    (if (global.get $err) (then (return (call $nil))))
    (call $assemble_level (local.get $pl) (i32.load offset=24 (local.get $pl)) (local.get $slots) (i32.const 1))
    (local.set $rc) (local.set $rp) (drop)
    (if (global.get $err) (then (return (call $nil))))
    ;; append bare '>' attachments after the columns
    (local.set $xn (i32.div_u (i32.sub (call $stack_len (global.get $STK_EXTRA)) (local.get $xmark)) (i32.const 24)))
    (if (local.get $xn)
      (then
        (local.set $all (call $alloc (i32.mul (i32.add (local.get $rc) (local.get $xn)) (i32.const 24))))
        (if (global.get $err) (then (return (call $nil))))
        (memory.copy (local.get $all) (local.get $rp) (i32.mul (local.get $rc) (i32.const 24)))
        (local.set $j (i32.const 0))
        (block $xd (loop $xl
          (br_if $xd (i32.ge_u (local.get $j) (local.get $xn)))
          (local.set $x (i32.add (call $stack_base (global.get $STK_EXTRA)) (i32.add (local.get $xmark) (i32.mul (local.get $j) (i32.const 24)))))
          (local.set $m (i32.const 0))
          (block $md (loop $ml
            (br_if $md (i32.ge_u (local.get $m) (i32.add (local.get $rc) (local.get $j))))
            (local.set $q (i32.add (local.get $all) (i32.mul (local.get $m) (i32.const 24))))
            (if (call $str_eq (i32.load (local.get $q)) (i32.load offset=4 (local.get $q)) (i32.load (local.get $x)) (i32.load offset=4 (local.get $x)))
              (then (call $fail (i32.const 15) (local.get $no)) (return (call $nil))))
            (local.set $m (i32.add (local.get $m) (i32.const 1)))
            (br $ml)))
          (memory.copy (i32.add (local.get $all) (i32.mul (i32.add (local.get $rc) (local.get $j)) (i32.const 24))) (local.get $x) (i32.const 24))
          (local.set $j (i32.add (local.get $j) (i32.const 1)))
          (br $xl)))
        (call $stack_truncate (global.get $STK_EXTRA) (local.get $xmark))
        (local.set $rp (local.get $all))
        (local.set $rc (i32.add (local.get $rc) (local.get $xn)))))
    ;; identity column uniqueness
    (if (local.get $ids)
      (then
        (local.set $s (i32.add (local.get $slots) (i32.shl (local.get $kc) (i32.const 4))))
        (if (i32.eq (i32.load (local.get $s)) (i32.const 8)) (then (call $fail (i32.const 29) (local.get $no)) (return (call $nil))))
        (call $identity_key (i32.load (local.get $s)) (i32.load offset=4 (local.get $s)) (i64.load offset=8 (local.get $s)))
        (local.set $ikn) (local.set $ikp)
        (if (global.get $err) (then (return (call $nil))))
        (if (call $ks_insert (local.get $ids) (local.get $ikp) (local.get $ikn))
          (then (call $fail (i32.const 15) (local.get $no)) (return (call $nil))))))
    (if (local.get $keyed)
      (then
        (if (i32.ne (i32.load (local.get $slots)) (i32.const 5)) (then (call $fail (i32.const 28) (local.get $no)) (return (call $nil))))
        (if (call $ks_insert (local.get $keys) (i32.load offset=4 (local.get $slots)) (i32.load offset=8 (local.get $slots)))
          (then (call $fail_msg (i32.const 15) (local.get $no) (i32.const 64)) (return (call $nil))))
        (local.set $q (call $stack_push (global.get $STK_MEMBERS) (i32.const 24)))
        (if (global.get $err) (then (return (call $nil))))
        (call $store_member (local.get $q) (i32.load offset=4 (local.get $slots)) (i32.load offset=8 (local.get $slots))
                            (i32.const 7) (local.get $rp) (i64.extend_i32_u (local.get $rc))))
      (else
        (local.set $q (call $stack_push (global.get $STK_NODES) (i32.const 16)))
        (if (global.get $err) (then (return (call $nil))))
        (call $store_node (local.get $q) (i32.const 7) (local.get $rp) (i64.extend_i32_u (local.get $rc)))))
    (local.set $n (i64.add (local.get $n) (i64.const 1)))
    (br $next)))
  (if (local.get $hasc)
    (then
      (if (i64.ne (local.get $n) (local.get $exp)) (then (call $fail (i32.const 18) (local.get $line)) (return (call $nil))))
      (call $surplus_check (local.get $r) (local.get $cont) (local.get $lri) (local.get $exp))
      (if (global.get $err) (then (return (call $nil))))))
  (select (i32.const 7) (i32.const 6) (local.get $keyed))
  (call $stack_pop_to_arena (local.get $stk) (local.get $mark))
  (local.get $n))

;; After the declared rows, a further line at the row indentation that
;; cannot belong to the parent is a surplus row.
(func $surplus_check (param $r i32) (param $cont i32) (param $lri i32) (param $e i64)
  (local $l i32) (local $ind i32)
  (local.set $l (call $peek))
  (if (i32.eqz (local.get $l)) (then (return)))
  (local.set $ind (call $lind (local.get $l)))
  (if (i32.or (i32.lt_u (local.get $ind) (local.get $r)) (i32.gt_u (local.get $ind) (i32.add (local.get $r) (i32.const 1)))) (then (return)))
  (if (call $lstarts (local.get $l) (global.get $S_SUMMARY) (i32.const 2)) (then (return)))
  (if (i32.and (i32.and (i32.eq (local.get $cont) (i32.const 1)) (i32.eq (local.get $ind) (local.get $r)))
               (call $looks_like_member (call $lt (local.get $l)) (call $ltn (local.get $l))))
    (then (return)))
  (if (i32.eq (i32.load8_u (call $lt (local.get $l))) (i32.const 0x2E)) (then (call $fail (i32.const 23) (call $lno (local.get $l))) (return)))
  (if (local.get $lri) (then (call $fail (i32.const 24) (call $lno (local.get $l))) (return)))
  (call $fail (i32.const 18) (call $lno (local.get $l))))

;; Value-grouped keyed set (SPEC §7.4.8).
(func $grouped_body (param $fields i32) (param $nf i32) (param $gp i32) (param $gn i32) (param $exp i64) (param $r i32) (param $line i32) (result i32 i32 i64)
  (local $i i32) (local $f i32) (local $keys_n i32) (local $ok i32) (local $pl i32) (local $gcol i32) (local $kcol i32)
  (local $ids i32) (local $groups i32) (local $mark i32) (local $total i64) (local $l i32) (local $t i32) (local $tn i32) (local $no i32)
  (local $kp i32) (local $kn i32) (local $rp i32) (local $rn i32) (local $bp i32) (local $bn i32) (local $br i32) (local $cnt i64) (local $k i64)
  (local $gt i32) (local $ga i32) (local $gb i64) (local $ikp i32) (local $ikn i32) (local $rl i32) (local $id i64) (local $slots i32) (local $s i32)
  (local $rc i32) (local $rpp i32) (local $q i32)
  (block $done (loop $l2
    (br_if $done (i32.ge_u (local.get $i) (local.get $nf)))
    (local.set $f (i32.add (local.get $fields) (i32.shl (local.get $i) (i32.const 5))))
    (if (i32.load offset=8 (local.get $f)) (then (local.set $keys_n (i32.add (local.get $keys_n) (i32.const 1)))))
    (if (call $str_eq (i32.load (local.get $f)) (i32.load offset=4 (local.get $f)) (local.get $gp) (local.get $gn))
      (then
        (if (i32.or (i32.load offset=8 (local.get $f)) (i32.load offset=12 (local.get $f)))
          (then (call $fail (i32.const 32) (local.get $line)) (return (call $nil))))
        (local.set $ok (i32.const 1))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l2)))
  (if (i32.ne (local.get $keys_n) (i32.const 1)) (then (call $fail (i32.const 32) (local.get $line)) (return (call $nil))))
  (if (i32.eqz (local.get $ok)) (then (call $fail (i32.const 32) (local.get $line)) (return (call $nil))))
  (local.set $pl (call $plan (local.get $fields) (local.get $nf) (local.get $gp) (local.get $gn) (i32.const 1) (i32.const 0) (local.get $line)))
  (if (global.get $err) (then (return (call $nil))))
  (local.set $gcol (call $find_column (local.get $pl) (local.get $gp) (local.get $gn)))
  (local.set $kcol (i32.load offset=20 (local.get $pl)))
  (local.set $ids (call $ks_new))
  (local.set $groups (call $ks_new))
  (if (global.get $err) (then (return (call $nil))))
  (local.set $mark (call $stack_len (global.get $STK_NODES)))
  (block $done (loop $next
    (local.set $l (call $peek))
    (br_if $done (i32.eqz (local.get $l)))
    (br_if $done (i32.lt_u (call $lind (local.get $l)) (local.get $r)))
    (local.set $no (call $lno (local.get $l)))
    (if (i32.gt_u (call $lind (local.get $l)) (local.get $r)) (then (call $fail (i32.const 21) (local.get $no)) (return (call $nil))))
    (br_if $done (call $lstarts (local.get $l) (global.get $S_SUMMARY) (i32.const 2)))
    (br_if $done (i64.eq (local.get $total) (local.get $exp)))
    (call $advance)
    (local.set $t (call $lt (local.get $l))) (local.set $tn (call $ltn (local.get $l)))
    ;; subheader: <col>=<value> [<n>]
    (call $key (local.get $t) (local.get $tn) (local.get $no))
    (local.set $rn) (local.set $rp) (local.set $kn) (local.set $kp)
    (if (global.get $err) (then (return (call $nil))))
    (if (i32.eqz (call $str_eq (local.get $kp) (local.get $kn) (local.get $gp) (local.get $gn)))
      (then (call $fail (i32.const 32) (local.get $no)) (return (call $nil))))
    (if (i32.or (i32.eqz (local.get $rn)) (i32.ne (i32.load8_u (local.get $rp)) (i32.const 0x3D)))
      (then (call $fail (i32.const 32) (local.get $no)) (return (call $nil))))
    (local.set $bp (i32.add (local.get $rp) (i32.const 1)))
    (local.set $bn (i32.sub (local.get $rn) (i32.const 1)))
    ;; last " [" in the body
    (local.set $br (i32.const -1))
    (local.set $i (i32.sub (local.get $bn) (i32.const 2)))
    (block $bd (loop $bl
      (br_if $bd (i32.lt_s (local.get $i) (i32.const 0)))
      (if (i32.eq (i32.load16_u (i32.add (local.get $bp) (local.get $i))) (i32.const 0x5B20))
        (then (local.set $br (local.get $i)) (br $bd)))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br $bl)))
    (if (i32.lt_s (local.get $br) (i32.const 0)) (then (call $fail (i32.const 32) (local.get $no)) (return (call $nil))))
    (if (i32.ne (call $at (local.get $bp) (i32.sub (local.get $bn) (i32.const 1))) (i32.const 0x5D))
      (then (call $fail (i32.const 32) (local.get $no)) (return (call $nil))))
    (local.set $cnt (call $count (i32.add (local.get $bp) (i32.add (local.get $br) (i32.const 2)))
                                 (i32.sub (i32.sub (local.get $bn) (i32.const 1)) (i32.add (local.get $br) (i32.const 2))) (local.get $no)))
    (if (global.get $err) (then (return (call $nil))))
    (if (i64.eqz (local.get $cnt)) (then (call $fail (i32.const 19) (local.get $no)) (return (call $nil))))
    (call $scalar (local.get $bp) (local.get $br) (i32.const 1) (local.get $no))
    (local.set $gb) (local.set $ga) (local.set $gt)
    (if (global.get $err) (then (return (call $nil))))
    (call $identity_key (local.get $gt) (local.get $ga) (local.get $gb))
    (local.set $ikn) (local.set $ikp)
    (if (global.get $err) (then (return (call $nil))))
    (if (call $ks_insert (local.get $groups) (local.get $ikp) (local.get $ikn))
      (then (call $fail (i32.const 33) (local.get $no)) (return (call $nil))))  ;; duplicate_group
    (local.set $k (i64.const 0))
    (block $rd (loop $rlp
      (br_if $rd (i64.ge_u (local.get $k) (local.get $cnt)))
      (local.set $rl (call $peek))
      (if (i32.eqz (local.get $rl)) (then (call $fail (i32.const 18) (local.get $no)) (return (call $nil))))
      (if (i32.or (i32.ne (call $lind (local.get $rl)) (local.get $r)) (call $lstarts (local.get $rl) (global.get $S_SUMMARY) (i32.const 2)))
        (then (call $fail (i32.const 18) (local.get $no)) (return (call $nil))))
      (call $advance)
      (call $row_line (local.get $rl) (local.get $pl) (i32.const 0))
      (drop) (local.set $slots) (local.set $id)
      (if (global.get $err) (then (return (call $nil))))
      (if (i64.ne (local.get $id) (i64.const -1)) (then (call $fail (i32.const 29) (call $lno (local.get $rl))) (return (call $nil))))
      (call $store_node (i32.add (local.get $slots) (i32.shl (local.get $gcol) (i32.const 4))) (local.get $gt) (local.get $ga) (local.get $gb))
      (local.set $s (i32.add (local.get $slots) (i32.shl (local.get $kcol) (i32.const 4))))
      (if (i32.eq (i32.load (local.get $s)) (i32.const 8)) (then (call $fail (i32.const 29) (call $lno (local.get $rl))) (return (call $nil))))
      (call $identity_key (i32.load (local.get $s)) (i32.load offset=4 (local.get $s)) (i64.load offset=8 (local.get $s)))
      (local.set $ikn) (local.set $ikp)
      (if (global.get $err) (then (return (call $nil))))
      (if (call $ks_insert (local.get $ids) (local.get $ikp) (local.get $ikn))
        (then (call $fail (i32.const 15) (call $lno (local.get $rl))) (return (call $nil))))
      (call $assemble_level (local.get $pl) (i32.load offset=24 (local.get $pl)) (local.get $slots) (i32.const 1))
      (local.set $rc) (local.set $rpp) (drop)
      (if (global.get $err) (then (return (call $nil))))
      (local.set $q (call $stack_push (global.get $STK_NODES) (i32.const 16)))
      (if (global.get $err) (then (return (call $nil))))
      (call $store_node (local.get $q) (i32.const 7) (local.get $rpp) (i64.extend_i32_u (local.get $rc)))
      (local.set $k (i64.add (local.get $k) (i64.const 1)))
      (br $rlp)))
    (local.set $total (i64.add (local.get $total) (local.get $cnt)))
    (if (i64.gt_u (local.get $total) (local.get $exp)) (then (call $fail (i32.const 18) (local.get $no)) (return (call $nil))))
    (br $next)))
  (if (i64.ne (local.get $total) (local.get $exp)) (then (call $fail (i32.const 18) (local.get $line)) (return (call $nil))))
  (i32.const 6)
  (call $stack_pop_to_arena (global.get $STK_NODES) (local.get $mark))
  (local.get $total))

;; Whole document -> value tree.
(func $decode_doc (param $src i32) (param $len i32) (result i32 i32 i64)
  (local $d i32)
  (global.set $pos (i32.const 0))
  (global.set $depth (i32.const 0))
  (global.set $nlines (i32.const 0))
  (call $build_document (local.get $src) (local.get $len))
  (if (global.get $err) (then (return (call $nil))))
  (if (global.get $profile)
    (then
      (if (call $header_flag (global.get $S_DELTA) (i32.const 5)) (then (return (call $graph_delta))))
      (call $parse_graph)
      (if (global.get $err) (then (return (call $nil))))
      (return (call $graph_to_value))))
  (if (call $header_flag (global.get $S_DELTA) (i32.const 5))
    (then
      (local.set $d (call $parse_generic_delta))
      (if (global.get $err) (then (return (call $nil))))
      (return (call $generic_delta_value (local.get $d)))))
  (call $root))
