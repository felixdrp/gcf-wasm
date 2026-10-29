;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 felixdrp
;;
;; 05_text.wat — shared text machinery of the decoder: static strings,
;; quoted strings, scalars, keys, field declarations, counts, a hash key set
;; and type-tagged identity keys.
;;
;; Value nodes travel as three stack values (tag i32, a i32, b i64) — wasm
;; multi-value returns — and are stored in memory as 16 bytes:
;;   +0 tag   +4 a   +8 b
;; tags: 0 null, 1 false, 2 true, 3 integer (b = i64), 4 double (b = f64 bits),
;;       5 string (a = ptr, b = len), 6 array (a = 16-byte nodes, b = count),
;;       7 object (a = 24-byte members, b = count),
;;       8 absent '~' and 9 attachment marker (row slots only; for a marker,
;;       a = inline-schema fields or 0, b = field count | matched << 32).
;; Object member (24 bytes): +0 key ptr, +4 key len, +8 value node.

;; ---------------------------------------------------------------------------
;; Static strings (offsets into the data segment below)
;; ---------------------------------------------------------------------------
(data (i32.const 0x7B00) "GCF## [##! summary group=countsprofilegenericgraphdeltabtruebfalsenullzo## {} [")
(global $S_GCF i32 (i32.const 0x7B00))      ;; "GCF"            3
(global $S_HDRARR i32 (i32.const 0x7B03))   ;; "## ["           4
(global $S_SUMMARY i32 (i32.const 0x7B07))  ;; "##! summary"   11 ("##!" = 3, "##" = 2)
(global $S_GROUP i32 (i32.const 0x7B12))    ;; " group="        7
(global $S_COUNTS i32 (i32.const 0x7B19))   ;; "counts"         6
(global $S_PROFILE i32 (i32.const 0x7B1F))  ;; "profile"        7
(global $S_GENERIC i32 (i32.const 0x7B26))  ;; "generic"        7
(global $S_GRAPH i32 (i32.const 0x7B2D))    ;; "graph"          5
(global $S_DELTA i32 (i32.const 0x7B32))    ;; "delta"          5
(global $S_BTRUE i32 (i32.const 0x7B37))    ;; "btrue"          5
(global $S_TRUE i32 (i32.const 0x7B38))     ;; "true"           4
(global $S_BFALSE i32 (i32.const 0x7B3C))   ;; "bfalse"         6
(global $S_FALSE i32 (i32.const 0x7B3D))    ;; "false"          5
(global $S_NULL i32 (i32.const 0x7B42))     ;; "null"           4
(global $S_Z i32 (i32.const 0x7B46))        ;; "z"              1
(global $S_O i32 (i32.const 0x7B47))        ;; "o"              1
(global $S_SECTION i32 (i32.const 0x7B48))  ;; "## "            3
(global $S_BRACES i32 (i32.const 0x7B4B))   ;; "{}"             2
(global $S_SPBR i32 (i32.const 0x7B4D))     ;; " ["             2

;; ---------------------------------------------------------------------------
;; Small helpers
;; ---------------------------------------------------------------------------

;; Zero results, returned on the error path (`(return (call $nil))`).
(func $nil (result i32 i32 i64) (i32.const 0) (i32.const 0) (i64.const 0))
(func $nil4 (result i32 i32 i32 i32) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0))
(func $nil5 (result i32 i32 i32 i32 i64) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i64.const 0))

(func $at (param $p i32) (param $i i32) (result i32) (i32.load8_u (i32.add (local.get $p) (local.get $i))))

;; Replace the current error category (and its default message).
(func $retag (param $code i32)
  (global.set $err (local.get $code))
  (global.set $err_msg (local.get $code)))

(func $store_node (param $q i32) (param $t i32) (param $a i32) (param $b i64)
  (i32.store (local.get $q) (local.get $t))
  (i32.store offset=4 (local.get $q) (local.get $a))
  (i64.store offset=8 (local.get $q) (local.get $b)))

(func $store_member (param $q i32) (param $kp i32) (param $kn i32) (param $t i32) (param $a i32) (param $b i64)
  (i32.store (local.get $q) (local.get $kp))
  (i32.store offset=4 (local.get $q) (local.get $kn))
  (i32.store offset=8 (local.get $q) (local.get $t))
  (i32.store offset=12 (local.get $q) (local.get $a))
  (i64.store offset=16 (local.get $q) (local.get $b)))

;; Trim spaces and tabs on both ends.
(func $trim (param $p i32) (param $n i32) (result i32 i32)
  (local $c i32)
  (block $done (loop $l
    (br_if $done (i32.eqz (local.get $n)))
    (local.set $c (i32.load8_u (local.get $p)))
    (br_if $done (i32.and (i32.ne (local.get $c) (i32.const 0x20)) (i32.ne (local.get $c) (i32.const 0x09))))
    (local.set $p (i32.add (local.get $p) (i32.const 1)))
    (local.set $n (i32.sub (local.get $n) (i32.const 1)))
    (br $l)))
  (block $done (loop $l
    (br_if $done (i32.eqz (local.get $n)))
    (local.set $c (call $at (local.get $p) (i32.sub (local.get $n) (i32.const 1))))
    (br_if $done (i32.and (i32.ne (local.get $c) (i32.const 0x20)) (i32.ne (local.get $c) (i32.const 0x09))))
    (local.set $n (i32.sub (local.get $n) (i32.const 1)))
    (br $l)))
  (local.get $p) (local.get $n))

;; ALPHA / DIGIT / "_". (c | 0x20) folds A-Z onto a-z; no other byte lands there.
(func $is_key_char (param $c i32) (result i32)
  (i32.or (i32.or (i32.lt_u (i32.sub (i32.or (local.get $c) (i32.const 0x20)) (i32.const 0x61)) (i32.const 26))
                  (i32.lt_u (i32.sub (local.get $c) (i32.const 0x30)) (i32.const 10)))
          (i32.eq (local.get $c) (i32.const 0x5F))))

;; bare-key = ( ALPHA / "_" ) *( ALPHA / DIGIT / "_" )   (SPEC §2a.1)
(func $is_bare_key (param $p i32) (param $n i32) (result i32)
  (local $i i32) (local $c i32)
  (if (i32.eqz (local.get $n)) (then (return (i32.const 0))))
  (local.set $c (i32.load8_u (local.get $p)))
  (if (i32.eqz (i32.or (i32.lt_u (i32.sub (i32.or (local.get $c) (i32.const 0x20)) (i32.const 0x61)) (i32.const 26))
                       (i32.eq (local.get $c) (i32.const 0x5F))))
    (then (return (i32.const 0))))
  (local.set $i (i32.const 1))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (if (i32.eqz (call $is_key_char (call $at (local.get $p) (local.get $i)))) (then (return (i32.const 0))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (i32.const 1))

;; ---------------------------------------------------------------------------
;; Quoted strings (JSON grammar)
;; ---------------------------------------------------------------------------

;; Index of the quote closing p[open], or -1 (no error recorded).
;; Jumps between '"' and '\' candidates with the SIMD scanner.
(func $find_close (param $p i32) (param $n i32) (param $open i32) (result i32)
  (local $i i32) (local $hit i32)
  (local.set $i (i32.add (local.get $open) (i32.const 1)))
  (loop $l
    (local.set $hit (call $find_any2 (local.get $p) (local.get $n) (local.get $i) (i32.const 0x22) (i32.const 0x5C)))
    (if (i32.lt_s (local.get $hit) (i32.const 0)) (then (return (i32.const -1))))
    (if (i32.eq (call $at (local.get $p) (local.get $hit)) (i32.const 0x5C))
      (then
        (local.set $i (i32.add (local.get $hit) (i32.const 2)))
        (if (i32.gt_u (local.get $i) (local.get $n)) (then (return (i32.const -1))))
        (br $l))))
  (local.get $hit))

(func $skip_quoted (param $p i32) (param $n i32) (param $open i32) (param $line i32) (result i32)
  (local $c i32)
  (local.set $c (call $find_close (local.get $p) (local.get $n) (local.get $open)))
  (if (i32.lt_s (local.get $c) (i32.const 0)) (then (call $fail (i32.const 6) (local.get $line))))  ;; unterminated_quote
  (local.get $c))

(func $hex4 (param $p i32) (param $n i32) (param $i i32) (param $line i32) (result i32)
  (local $v i32) (local $k i32) (local $c i32) (local $h i32)
  (if (i32.gt_u (i32.add (local.get $i) (i32.const 4)) (local.get $n))
    (then (call $fail (i32.const 7) (local.get $line)) (return (i32.const 0))))
  (block $done (loop $l
    (br_if $done (i32.eq (local.get $k) (i32.const 4)))
    (local.set $c (call $at (local.get $p) (i32.add (local.get $i) (local.get $k))))
    (local.set $h
      (if (result i32) (i32.lt_u (i32.sub (local.get $c) (i32.const 0x30)) (i32.const 10))
        (then (i32.sub (local.get $c) (i32.const 0x30)))
        (else (if (result i32) (i32.lt_u (i32.sub (i32.or (local.get $c) (i32.const 0x20)) (i32.const 0x61)) (i32.const 6))
          (then (i32.sub (i32.or (local.get $c) (i32.const 0x20)) (i32.const 0x57)))
          (else (i32.const -1))))))
    (if (i32.lt_s (local.get $h) (i32.const 0)) (then (call $fail (i32.const 7) (local.get $line)) (return (i32.const 0))))
    (local.set $v (i32.or (i32.shl (local.get $v) (i32.const 4)) (local.get $h)))
    (local.set $k (i32.add (local.get $k) (i32.const 1)))
    (br $l)))
  (local.get $v))

;; Byte for a one-character escape, or -1.
(func $simple_escape (param $e i32) (result i32)
  (if (i32.or (i32.or (i32.eq (local.get $e) (i32.const 0x22)) (i32.eq (local.get $e) (i32.const 0x5C)))
              (i32.eq (local.get $e) (i32.const 0x2F)))
    (then (return (local.get $e))))
  (if (i32.eq (local.get $e) (i32.const 0x62)) (then (return (i32.const 0x08))))
  (if (i32.eq (local.get $e) (i32.const 0x66)) (then (return (i32.const 0x0C))))
  (if (i32.eq (local.get $e) (i32.const 0x6E)) (then (return (i32.const 0x0A))))
  (if (i32.eq (local.get $e) (i32.const 0x72)) (then (return (i32.const 0x0D))))
  (if (i32.eq (local.get $e) (i32.const 0x74)) (then (return (i32.const 0x09))))
  (i32.const -1))

;; UTF-8 encode a code point at o; returns the new end.
(func $utf8_put (param $o i32) (param $cp i32) (result i32)
  (if (i32.lt_u (local.get $cp) (i32.const 0x80))
    (then (i32.store8 (local.get $o) (local.get $cp)) (return (i32.add (local.get $o) (i32.const 1)))))
  (if (i32.lt_u (local.get $cp) (i32.const 0x800))
    (then
      (i32.store8 (local.get $o) (i32.or (i32.const 0xC0) (i32.shr_u (local.get $cp) (i32.const 6))))
      (i32.store8 offset=1 (local.get $o) (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
      (return (i32.add (local.get $o) (i32.const 2)))))
  (if (i32.lt_u (local.get $cp) (i32.const 0x10000))
    (then
      (i32.store8 (local.get $o) (i32.or (i32.const 0xE0) (i32.shr_u (local.get $cp) (i32.const 12))))
      (i32.store8 offset=1 (local.get $o) (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 0x3F))))
      (i32.store8 offset=2 (local.get $o) (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
      (return (i32.add (local.get $o) (i32.const 3)))))
  (i32.store8 (local.get $o) (i32.or (i32.const 0xF0) (i32.shr_u (local.get $cp) (i32.const 18))))
  (i32.store8 offset=1 (local.get $o) (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 0x3F))))
  (i32.store8 offset=2 (local.get $o) (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 0x3F))))
  (i32.store8 offset=3 (local.get $o) (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
  (i32.add (local.get $o) (i32.const 4)))

;; Decode the body of a quoted string (without quotes). Zero-copy when there
;; is no escape and no control byte (one SIMD pass); the decoded form is
;; never longer than the source, so one arena block of `n` bytes suffices.
(func $string_body (param $p i32) (param $n i32) (param $line i32) (result i32 i32)
  (local $out i32) (local $o i32) (local $i i32) (local $c i32) (local $e i32) (local $hi i32) (local $lo i32) (local $cp i32)
  (if (i32.eqz (call $has_backslash_or_control (local.get $p) (local.get $n)))
    (then (return (local.get $p) (local.get $n))))
  (local.set $out (call $alloc (local.get $n)))
  (if (global.get $err) (then (return (i32.const 0) (i32.const 0))))
  (local.set $o (local.get $out))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $c (call $at (local.get $p) (local.get $i)))
    (if (i32.lt_u (local.get $c) (i32.const 0x20))
      (then (call $fail (i32.const 13) (local.get $line)) (return (i32.const 0) (i32.const 0))))  ;; invalid_control_character
    (if (i32.ne (local.get $c) (i32.const 0x5C))
      (then
        (i32.store8 (local.get $o) (local.get $c))
        (local.set $o (i32.add (local.get $o) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (if (i32.ge_u (i32.add (local.get $i) (i32.const 1)) (local.get $n))
      (then (call $fail (i32.const 7) (local.get $line)) (return (i32.const 0) (i32.const 0))))  ;; dangling backslash
    (local.set $e (call $at (local.get $p) (i32.add (local.get $i) (i32.const 1))))
    (local.set $i (i32.add (local.get $i) (i32.const 2)))
    (if (i32.eq (local.get $e) (i32.const 0x75))  ;; \uXXXX
      (then
        (local.set $hi (call $hex4 (local.get $p) (local.get $n) (local.get $i) (local.get $line)))
        (if (global.get $err) (then (return (i32.const 0) (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 4)))
        (local.set $cp (local.get $hi))
        (if (i32.eq (i32.and (local.get $hi) (i32.const 0xFC00)) (i32.const 0xD800))
          (then
            ;; high surrogate: must be followed by "\u" + low surrogate
            (if (i32.or (i32.gt_u (i32.add (local.get $i) (i32.const 6)) (local.get $n))
                        (i32.ne (i32.load16_u (i32.add (local.get $p) (local.get $i))) (i32.const 0x755C)))
              (then (call $fail (i32.const 11) (local.get $line)) (return (i32.const 0) (i32.const 0))))
            (local.set $lo (call $hex4 (local.get $p) (local.get $n) (i32.add (local.get $i) (i32.const 2)) (local.get $line)))
            (if (global.get $err) (then (return (i32.const 0) (i32.const 0))))
            (if (i32.ne (i32.and (local.get $lo) (i32.const 0xFC00)) (i32.const 0xDC00))
              (then (call $fail (i32.const 11) (local.get $line)) (return (i32.const 0) (i32.const 0))))
            (local.set $i (i32.add (local.get $i) (i32.const 6)))
            (local.set $cp (i32.add (i32.const 0x10000)
              (i32.or (i32.shl (i32.sub (local.get $hi) (i32.const 0xD800)) (i32.const 10))
                      (i32.sub (local.get $lo) (i32.const 0xDC00))))))
          (else
            (if (i32.eq (i32.and (local.get $hi) (i32.const 0xFC00)) (i32.const 0xDC00))
              (then (call $fail (i32.const 11) (local.get $line)) (return (i32.const 0) (i32.const 0))))))
        (local.set $o (call $utf8_put (local.get $o) (local.get $cp)))
        (br $l)))
    (local.set $c (call $simple_escape (local.get $e)))
    (if (i32.lt_s (local.get $c) (i32.const 0))
      (then (call $fail (i32.const 7) (local.get $line)) (return (i32.const 0) (i32.const 0))))
    (i32.store8 (local.get $o) (local.get $c))
    (local.set $o (i32.add (local.get $o) (i32.const 1)))
    (br $l)))
  (local.get $out) (i32.sub (local.get $o) (local.get $out)))

;; A complete quoted token: the closing quote must end the token.
(func $parse_quoted (param $p i32) (param $n i32) (param $line i32) (result i32 i32)
  (local $close i32)
  (local.set $close (call $skip_quoted (local.get $p) (local.get $n) (i32.const 0) (local.get $line)))
  (if (global.get $err) (then (return (i32.const 0) (i32.const 0))))
  (if (i32.ne (local.get $close) (i32.sub (local.get $n) (i32.const 1)))
    (then (call $fail (i32.const 8) (local.get $line)) (return (i32.const 0) (i32.const 0))))  ;; trailing_characters
  (call $string_body (i32.add (local.get $p) (i32.const 1)) (i32.sub (local.get $close) (i32.const 1)) (local.get $line)))

;; ---------------------------------------------------------------------------
;; Scalars
;; ---------------------------------------------------------------------------

;; Parse a scalar token. ctx: 0 = tabular cell, 1 = value, 2 = constant column
;; value; it decides which markers are legal (SPEC §2.1).
(func $scalar (param $p i32) (param $n i32) (param $ctx i32) (param $line i32) (result i32 i32 i64)
  (local $c i32) (local $k i32) (local $fp i32) (local $fn i32) (local $rp i32) (local $rn i32)
  (call $trim (local.get $p) (local.get $n)) (local.set $n) (local.set $p)
  (if (i32.eqz (local.get $n)) (then (return (i32.const 5) (local.get $p) (i64.const 0))))
  (local.set $c (i32.load8_u (local.get $p)))
  (if (i32.eq (local.get $c) (i32.const 0x22))
    (then
      (call $parse_quoted (local.get $p) (local.get $n) (local.get $line)) (local.set $n) (local.set $p)
      (return (i32.const 5) (local.get $p) (i64.extend_i32_u (local.get $n)))))
  (if (i32.eq (local.get $n) (i32.const 1))
    (then
      (if (i32.eq (local.get $c) (i32.const 0x2D)) (then (return (call $nil))))  ;; '-' null
      (if (i32.eq (local.get $c) (i32.const 0x7E))                              ;; '~' absent
        (then
          (if (i32.eqz (local.get $ctx)) (then (return (i32.const 8) (i32.const 0) (i64.const 0))))
          (call $fail (select (i32.const 30) (i32.const 9) (i32.eq (local.get $ctx) (i32.const 2))) (local.get $line))
          (return (call $nil))))
      (if (i32.eq (local.get $c) (i32.const 0x5E))                              ;; '^' marker
        (then
          (if (i32.eqz (local.get $ctx)) (then (return (i32.const 9) (i32.const 0) (i64.const 0))))
          (call $fail (select (i32.const 30) (i32.const 10) (i32.eq (local.get $ctx) (i32.const 2))) (local.get $line))
          (return (call $nil))))))
  ;; ^{fields}: inline-schema marker
  (if (i32.and (i32.and (i32.ge_u (local.get $n) (i32.const 3)) (i32.eq (local.get $c) (i32.const 0x5E)))
               (i32.and (i32.eq (call $at (local.get $p) (i32.const 1)) (i32.const 0x7B))
                        (i32.eq (call $at (local.get $p) (i32.sub (local.get $n) (i32.const 1))) (i32.const 0x7D))))
    (then
      (if (local.get $ctx)
        (then
          (call $fail (select (i32.const 30) (i32.const 10) (i32.eq (local.get $ctx) (i32.const 2))) (local.get $line))
          (return (call $nil))))
      (call $field_decl (i32.add (local.get $p) (i32.const 1)) (i32.sub (local.get $n) (i32.const 1)) (local.get $line) (i32.const 1))
      (local.set $rn) (local.set $rp) (local.set $fn) (local.set $fp)
      (if (global.get $err)
        (then
          (if (i32.eq (global.get $err) (i32.const 4)) (then (call $retag (i32.const 10))))
          (return (call $nil))))
      (if (local.get $rn) (then (call $fail (i32.const 10) (local.get $line)) (return (call $nil))))
      (return (i32.const 9) (local.get $fp) (i64.extend_i32_u (local.get $fn)))))
  ;; true / false: one 32-bit compare ("true" = 0x65757274 little-endian)
  (if (i32.eq (local.get $n) (i32.const 4))
    (then (if (i32.eq (i32.load (local.get $p)) (i32.const 0x65757274)) (then (return (i32.const 2) (i32.const 0) (i64.const 0))))))
  (if (i32.eq (local.get $n) (i32.const 5))
    (then (if (i32.and (i32.eq (i32.load (local.get $p)) (i32.const 0x736C6166)) (i32.eq (call $at (local.get $p) (i32.const 4)) (i32.const 0x65)))
      (then (return (i32.const 1) (i32.const 0) (i64.const 0))))))
  (local.set $k (call $number_kind (local.get $p) (local.get $n)))
  (if (i32.eq (local.get $k) (i32.const 1))
    (then (return (i32.const 3) (i32.const 0) (call $parse_int64 (local.get $p) (local.get $n) (local.get $line)))))
  (if (i32.eq (local.get $k) (i32.const 2))
    (then (return (i32.const 4) (i32.const 0) (i64.reinterpret_f64 (call $parse_f64 (local.get $p) (local.get $n) (local.get $line))))))
  (i32.const 5) (local.get $p) (i64.extend_i32_u (local.get $n)))

;; ---------------------------------------------------------------------------
;; Keys, counts, field declarations
;; ---------------------------------------------------------------------------

;; Key at the start of the text: quoted, or a run of bare-key bytes.
;; Returns (key ptr, key len, rest ptr, rest len).
(func $key (param $p i32) (param $n i32) (param $line i32) (result i32 i32 i32 i32)
  (local $close i32) (local $kp i32) (local $kn i32) (local $i i32)
  (if (i32.and (i32.gt_u (local.get $n) (i32.const 0)) (i32.eq (i32.load8_u (local.get $p)) (i32.const 0x22)))
    (then
      (local.set $close (call $skip_quoted (local.get $p) (local.get $n) (i32.const 0) (local.get $line)))
      (if (global.get $err) (then (return (call $nil4))))
      (call $string_body (i32.add (local.get $p) (i32.const 1)) (i32.sub (local.get $close) (i32.const 1)) (local.get $line))
      (local.set $kn) (local.set $kp)
      (if (global.get $err) (then (return (call $nil4))))
      (local.set $close (i32.add (local.get $close) (i32.const 1)))
      (return (local.get $kp) (local.get $kn) (i32.add (local.get $p) (local.get $close)) (i32.sub (local.get $n) (local.get $close)))))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (br_if $done (i32.eqz (call $is_key_char (call $at (local.get $p) (local.get $i)))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (if (i32.eqz (call $is_bare_key (local.get $p) (local.get $i)))
    (then (call $fail (i32.const 28) (local.get $line)) (return (call $nil4))))  ;; invalid_key
  (local.get $p) (local.get $i) (i32.add (local.get $p) (local.get $i)) (i32.sub (local.get $n) (local.get $i)))

;; count = "0" / ( DIGIT1-9 *DIGIT ), as u64 (overflow is invalid_count).
(func $count (param $p i32) (param $n i32) (param $line i32) (result i64)
  (local $v i64) (local $i i32) (local $d i32)
  (if (i32.eqz (local.get $n)) (then (call $fail (i32.const 19) (local.get $line)) (return (i64.const 0))))
  (if (i32.and (i32.gt_u (local.get $n) (i32.const 1)) (i32.eq (i32.load8_u (local.get $p)) (i32.const 0x30)))
    (then (call $fail (i32.const 19) (local.get $line)) (return (i64.const 0))))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $d (i32.sub (call $at (local.get $p) (local.get $i)) (i32.const 0x30)))
    (if (i32.gt_u (local.get $d) (i32.const 9)) (then (call $fail (i32.const 19) (local.get $line)) (return (i64.const 0))))
    ;; v * 10 + d must stay below 2^64
    (if (i32.or (i64.gt_u (local.get $v) (i64.const 0x1999999999999999))
                (i32.and (i64.eq (local.get $v) (i64.const 0x1999999999999999)) (i32.gt_u (local.get $d) (i32.const 5))))
      (then (call $fail (i32.const 19) (local.get $line)) (return (i64.const 0))))
    (local.set $v (i64.add (i64.mul (local.get $v) (i64.const 10)) (i64.extend_i32_u (local.get $d))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.get $v))

;; Field declaration `{a,"b c",@id,region=us-east}` at p[0] == '{'.
;; mode 0 = table header, 1 = inline schema (no '@', no constants).
;; Field entry (32 bytes): +0 name ptr, +4 name len, +8 is_key,
;;   +12 has_constant, +16 constant value node.
;; Returns (fields ptr, field count, rest ptr, rest len).
(func $field_decl (param $p i32) (param $n i32) (param $line i32) (param $mode i32) (result i32 i32 i32 i32)
  (local $i i32) (local $mark i32) (local $e i32) (local $q i32) (local $is_key i32) (local $has i32)
  (local $np i32) (local $nn i32) (local $close i32) (local $stop i32) (local $tp i32) (local $tn i32)
  (local $vt i32) (local $va i32) (local $vb i64) (local $c i32) (local $cnt i32) (local $fp i32)
  (local.set $i (i32.const 1))
  (if (i32.and (i32.gt_u (local.get $n) (i32.const 1)) (i32.eq (call $at (local.get $p) (i32.const 1)) (i32.const 0x7D)))
    (then (call $fail (i32.const 4) (local.get $line)) (return (call $nil4))))  ;; empty declaration
  (local.set $mark (call $stack_len (global.get $STK_FIELDS)))
  (block $end (loop $next
    (if (i32.ge_u (local.get $i) (local.get $n)) (then (call $fail (i32.const 4) (local.get $line)) (return (call $nil4))))
    (local.set $is_key (i32.const 0))
    (local.set $has (i32.const 0))
    (local.set $vt (i32.const 0)) (local.set $va (i32.const 0)) (local.set $vb (i64.const 0))
    (if (i32.eq (call $at (local.get $p) (local.get $i)) (i32.const 0x40))  ;; '@'
      (then
        (if (local.get $mode) (then (call $fail (i32.const 10) (local.get $line)) (return (call $nil4))))
        (local.set $is_key (i32.const 1))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))))
    ;; name
    (if (i32.and (i32.lt_u (local.get $i) (local.get $n)) (i32.eq (call $at (local.get $p) (local.get $i)) (i32.const 0x22)))
      (then
        (local.set $close (call $skip_quoted (local.get $p) (local.get $n) (local.get $i) (local.get $line)))
        (if (global.get $err) (then (return (call $nil4))))
        (call $string_body (i32.add (local.get $p) (i32.add (local.get $i) (i32.const 1)))
                           (i32.sub (local.get $close) (i32.add (local.get $i) (i32.const 1))) (local.get $line))
        (local.set $nn) (local.set $np)
        (if (global.get $err) (then (return (call $nil4))))
        (local.set $i (i32.add (local.get $close) (i32.const 1))))
      (else
        (local.set $stop (call $find_any3 (local.get $p) (local.get $n) (local.get $i) (i32.const 0x2C) (i32.const 0x7D) (i32.const 0x3D)))
        (if (i32.lt_s (local.get $stop) (i32.const 0)) (then (local.set $stop (local.get $n))))
        (call $trim (i32.add (local.get $p) (local.get $i)) (i32.sub (local.get $stop) (local.get $i)))
        (local.set $nn) (local.set $np)
        ;; empty, or not a bare key (it must be quoted)
        (if (i32.eqz (call $is_bare_key (local.get $np) (local.get $nn)))
          (then (call $fail (i32.const 4) (local.get $line)) (return (call $nil4))))
        (local.set $i (local.get $stop))))
    ;; `=value`: constant column
    (if (i32.and (i32.lt_u (local.get $i) (local.get $n)) (i32.eq (call $at (local.get $p) (local.get $i)) (i32.const 0x3D)))
      (then
        (if (local.get $mode) (then (call $fail (i32.const 10) (local.get $line)) (return (call $nil4))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (if (i32.and (i32.lt_u (local.get $i) (local.get $n)) (i32.eq (call $at (local.get $p) (local.get $i)) (i32.const 0x22)))
          (then
            (local.set $close (call $skip_quoted (local.get $p) (local.get $n) (local.get $i) (local.get $line)))
            (if (global.get $err) (then (return (call $nil4))))
            (local.set $tp (i32.add (local.get $p) (local.get $i)))
            (local.set $tn (i32.sub (i32.add (local.get $close) (i32.const 1)) (local.get $i)))
            (local.set $i (i32.add (local.get $close) (i32.const 1))))
          (else
            (local.set $stop (call $find_any2 (local.get $p) (local.get $n) (local.get $i) (i32.const 0x2C) (i32.const 0x7D)))
            (if (i32.lt_s (local.get $stop) (i32.const 0)) (then (local.set $stop (local.get $n))))
            (local.set $tp (i32.add (local.get $p) (local.get $i)))
            (local.set $tn (i32.sub (local.get $stop) (local.get $i)))
            (local.set $i (local.get $stop))))
        (call $trim (local.get $tp) (local.get $tn)) (local.set $c) (drop)
        (if (i32.eqz (local.get $c)) (then (call $fail (i32.const 30) (local.get $line)) (return (call $nil4))))
        (call $scalar (local.get $tp) (local.get $tn) (i32.const 2) (local.get $line))
        (local.set $vb) (local.set $va) (local.set $vt)
        (if (global.get $err) (then (return (call $nil4))))
        (local.set $has (i32.const 1))))
    ;; duplicate names (declarations are short: linear scan)
    (local.set $q (i32.add (call $stack_base (global.get $STK_FIELDS)) (local.get $mark)))
    (local.set $e (i32.add (call $stack_base (global.get $STK_FIELDS)) (call $stack_len (global.get $STK_FIELDS))))
    (block $dd (loop $dl
      (br_if $dd (i32.ge_u (local.get $q) (local.get $e)))
      (if (call $str_eq (i32.load (local.get $q)) (i32.load offset=4 (local.get $q)) (local.get $np) (local.get $nn))
        (then (call $fail (i32.const 16) (local.get $line)) (return (call $nil4))))  ;; duplicate_field_name
      (local.set $q (i32.add (local.get $q) (i32.const 32)))
      (br $dl)))
    (local.set $e (call $stack_push (global.get $STK_FIELDS) (i32.const 32)))
    (if (global.get $err) (then (return (call $nil4))))
    (i32.store (local.get $e) (local.get $np))
    (i32.store offset=4 (local.get $e) (local.get $nn))
    (i32.store offset=8 (local.get $e) (local.get $is_key))
    (i32.store offset=12 (local.get $e) (local.get $has))
    (call $store_node (i32.add (local.get $e) (i32.const 16)) (local.get $vt) (local.get $va) (local.get $vb))
    (if (i32.ge_u (local.get $i) (local.get $n)) (then (call $fail (i32.const 4) (local.get $line)) (return (call $nil4))))
    (local.set $c (call $at (local.get $p) (local.get $i)))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br_if $next (i32.eq (local.get $c) (i32.const 0x2C)))
    (br_if $end (i32.eq (local.get $c) (i32.const 0x7D)))
    (call $fail (i32.const 4) (local.get $line))
    (return (call $nil4))))
  (local.set $cnt (i32.shr_u (i32.sub (call $stack_len (global.get $STK_FIELDS)) (local.get $mark)) (i32.const 5)))
  (local.set $fp (call $stack_pop_to_arena (global.get $STK_FIELDS) (local.get $mark)))
  ;; a declaration can become a column's inline or shared schema for the
  ;; rows that follow
  (global.set $pin (global.get $arena_top))
  (local.get $fp) (local.get $cnt) (i32.add (local.get $p) (local.get $i)) (i32.sub (local.get $n) (local.get $i)))

;; ---------------------------------------------------------------------------
;; Key set: open addressing over 12-byte entries (hash | 1, ptr, len), with a
;; power-of-two capacity kept at most half full. Murmur3_32 hashing uses only
;; 32-bit multiplies (cheap in wasm).
;; Set header (12 bytes): +0 count, +4 capacity, +8 table.
;; ---------------------------------------------------------------------------

(func $hash (param $p i32) (param $n i32) (result i32)
  (local $h i32) (local $k i32) (local $i i32) (local $end i32)
  (local.set $h (i32.const 0x9747B28C))
  (local.set $end (i32.and (local.get $n) (i32.const -4)))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $end)))
    (local.set $k (i32.mul (i32.load (i32.add (local.get $p) (local.get $i))) (i32.const 0xCC9E2D51)))
    (local.set $k (i32.mul (i32.rotl (local.get $k) (i32.const 15)) (i32.const 0x1B873593)))
    (local.set $h (i32.xor (local.get $h) (local.get $k)))
    (local.set $h (i32.add (i32.mul (i32.rotl (local.get $h) (i32.const 13)) (i32.const 5)) (i32.const 0xE6546B64)))
    (local.set $i (i32.add (local.get $i) (i32.const 4)))
    (br $l)))
  (local.set $k (i32.const 0))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
    (local.set $k (i32.or (local.get $k)
      (i32.shl (call $at (local.get $p) (local.get $i)) (i32.shl (i32.sub (local.get $i) (local.get $end)) (i32.const 3)))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (local.set $k (i32.mul (i32.rotl (i32.mul (local.get $k) (i32.const 0xCC9E2D51)) (i32.const 15)) (i32.const 0x1B873593)))
  (local.set $h (i32.xor (i32.xor (local.get $h) (local.get $k)) (local.get $n)))
  ;; fmix32
  (local.set $h (i32.mul (i32.xor (local.get $h) (i32.shr_u (local.get $h) (i32.const 16))) (i32.const 0x85EBCA6B)))
  (local.set $h (i32.mul (i32.xor (local.get $h) (i32.shr_u (local.get $h) (i32.const 13))) (i32.const 0xC2B2AE35)))
  (i32.xor (local.get $h) (i32.shr_u (local.get $h) (i32.const 16))))

(func $ks_new (result i32)
  (local $s i32)
  (local.set $s (call $alloc (i32.const 12)))
  (if (local.get $s) (then (memory.fill (local.get $s) (i32.const 0) (i32.const 12))))
  (local.get $s))

;; Place an entry with a known hash (no duplicate check).
(func $ks_place (param $t i32) (param $mask i32) (param $h i32) (param $p i32) (param $n i32)
  (local $i i32) (local $e i32)
  (local.set $i (i32.and (local.get $h) (local.get $mask)))
  (loop $probe
    (local.set $e (i32.add (local.get $t) (i32.mul (local.get $i) (i32.const 12))))
    (if (i32.load (local.get $e))
      (then
        (local.set $i (i32.and (i32.add (local.get $i) (i32.const 1)) (local.get $mask)))
        (br $probe))))
  (i32.store (local.get $e) (local.get $h))
  (i32.store offset=4 (local.get $e) (local.get $p))
  (i32.store offset=8 (local.get $e) (local.get $n)))

(func $ks_grow (param $s i32)
  (local $old i32) (local $ocap i32) (local $cap i32) (local $t i32) (local $i i32) (local $e i32)
  (local.set $old (i32.load offset=8 (local.get $s)))
  (local.set $ocap (i32.load offset=4 (local.get $s)))
  (local.set $cap (select (i32.shl (local.get $ocap) (i32.const 1)) (i32.const 16) (local.get $ocap)))
  (local.set $t (call $alloc (i32.mul (local.get $cap) (i32.const 12))))
  (if (global.get $err) (then (return)))
  (global.set $pin (global.get $arena_top))
  (memory.fill (local.get $t) (i32.const 0) (i32.mul (local.get $cap) (i32.const 12)))
  (block $done (loop $l
    (br_if $done (i32.ge_u (local.get $i) (local.get $ocap)))
    (local.set $e (i32.add (local.get $old) (i32.mul (local.get $i) (i32.const 12))))
    (if (i32.load (local.get $e))
      (then (call $ks_place (local.get $t) (i32.sub (local.get $cap) (i32.const 1)) (i32.load (local.get $e))
                            (i32.load offset=4 (local.get $e)) (i32.load offset=8 (local.get $e)))))
    (local.set $i (i32.add (local.get $i) (i32.const 1)))
    (br $l)))
  (i32.store offset=4 (local.get $s) (local.get $cap))
  (i32.store offset=8 (local.get $s) (local.get $t)))

;; Insert a key; returns 1 when it was already present.
(func $ks_insert (param $s i32) (param $p i32) (param $n i32) (result i32)
  (local $h i32) (local $mask i32) (local $t i32) (local $i i32) (local $e i32)
  (if (i32.ge_u (i32.shl (i32.add (i32.load (local.get $s)) (i32.const 1)) (i32.const 1)) (i32.load offset=4 (local.get $s)))
    (then (call $ks_grow (local.get $s)) (if (global.get $err) (then (return (i32.const 0))))))
  (local.set $h (i32.or (call $hash (local.get $p) (local.get $n)) (i32.const 1)))
  (local.set $mask (i32.sub (i32.load offset=4 (local.get $s)) (i32.const 1)))
  (local.set $t (i32.load offset=8 (local.get $s)))
  (local.set $i (i32.and (local.get $h) (local.get $mask)))
  (loop $probe
    (local.set $e (i32.add (local.get $t) (i32.mul (local.get $i) (i32.const 12))))
    (if (i32.eqz (i32.load (local.get $e)))
      (then
        (i32.store (local.get $e) (local.get $h))
        (i32.store offset=4 (local.get $e) (local.get $p))
        (i32.store offset=8 (local.get $e) (local.get $n))
        (i32.store (local.get $s) (i32.add (i32.load (local.get $s)) (i32.const 1)))
        (return (i32.const 0))))
    (if (i32.eq (i32.load (local.get $e)) (local.get $h))
      (then
        (if (call $str_eq (i32.load offset=4 (local.get $e)) (i32.load offset=8 (local.get $e)) (local.get $p) (local.get $n))
          (then (return (i32.const 1))))))
    (local.set $i (i32.and (i32.add (local.get $i) (i32.const 1)) (local.get $mask)))
    (br $probe))
  (unreachable))

;; Type-tagged byte key for identity / group uniqueness: string "1" and
;; number 1 differ ('s' / 'n' prefix); numbers use their canonical form.
(func $identity_key (param $t i32) (param $a i32) (param $b i64) (result i32 i32)
  (local $q i32) (local $mark i32) (local $n i32)
  (if (i32.eq (local.get $t) (i32.const 5))
    (then
      (local.set $n (i32.wrap_i64 (local.get $b)))
      (local.set $q (call $alloc (i32.add (local.get $n) (i32.const 1))))
      (if (global.get $err) (then (return (i32.const 0) (i32.const 0))))
      (global.set $pin (global.get $arena_top))  ;; identity keys outlive the row
      (i32.store8 (local.get $q) (i32.const 0x73))
      (memory.copy (i32.add (local.get $q) (i32.const 1)) (local.get $a) (local.get $n))
      (return (local.get $q) (i32.add (local.get $n) (i32.const 1)))))
  (if (i32.or (i32.eq (local.get $t) (i32.const 3)) (i32.eq (local.get $t) (i32.const 4)))
    (then
      ;; format through the output buffer, copy out, rewind (publishing a
      ;; streaming decoder's open cursor first)
      (if (global.get $jlive) (then (call $w_sync)))
      (local.set $mark (call $stack_len (global.get $STK_OUT)))
      (call $out_byte (i32.const 0x6E))
      (if (i32.eq (local.get $t) (i32.const 3))
        (then
          (if (i64.lt_s (local.get $b) (i64.const 0)) (then (call $out_byte (i32.const 0x2D))))
          (call $out_u64 (select (i64.sub (i64.const 0) (local.get $b)) (local.get $b) (i64.lt_s (local.get $b) (i64.const 0)))))
        (else (call $out_f64 (f64.reinterpret_i64 (local.get $b)))))
      (if (global.get $err) (then (return (i32.const 0) (i32.const 0))))
      (local.set $n (i32.sub (call $stack_len (global.get $STK_OUT)) (local.get $mark)))
      (local.set $q (call $dup (i32.add (call $stack_base (global.get $STK_OUT)) (local.get $mark)) (local.get $n)))
      (global.set $pin (global.get $arena_top))
      (call $stack_truncate (global.get $STK_OUT) (local.get $mark))
      (if (global.get $jlive) (then (call $w_begin (i32.const 0))))
      (return (local.get $q) (local.get $n))))
  (if (i32.eq (local.get $t) (i32.const 2)) (then (return (global.get $S_BTRUE) (i32.const 5))))
  (if (i32.eq (local.get $t) (i32.const 1)) (then (return (global.get $S_BFALSE) (i32.const 6))))
  (if (i32.eqz (local.get $t)) (then (return (global.get $S_Z) (i32.const 1))))
  (global.get $S_O) (i32.const 1))
