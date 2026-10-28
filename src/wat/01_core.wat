;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 felixdrp
;;
;; 01_core.wat — memory, arena, scratch stacks, errors, basic ABI exports.
;;
;; Hand-written WebAssembly GCF codec (phase 1: generic profile). It exposes
;; the same ABI as the Zig build (docs/WASM_ABI.md), so src/host.ts and the
;; test suite run against either module unchanged.
;;
;; Conventions used in every fragment:
;;   * Folded S-expressions: (i32.add (local.get $a) (i32.const 1)).
;;   * Strings are (ptr, len) pairs of i32.
;;   * Errors work like Zig's `try`: $fail sets the global $err (first error
;;     wins); every caller checks (global.get $err) after a call that can fail
;;     and returns immediately.
;;   * Memory map: page 0 holds static tables (see _tables.gen.wat) and the
;;     scratch-stack headers; the bump arena starts at 0x10000 and is reset in
;;     O(1) by gcf_input_alloc.

(memory (export "memory") 2)

(global $HEAP i32 (i32.const 0x10000))
(global $arena_top (mut i32) (i32.const 0x10000))
(global $arena_limit (mut i32) (i32.const 0x20000))  ;; = memory.size * 64 KiB
(global $high_water (mut i32) (i32.const 0))

(global $in_ptr (mut i32) (i32.const 0))
(global $out_ptr (mut i32) (i32.const 0))
(global $out_len (mut i32) (i32.const 0))

(global $err (mut i32) (i32.const 0))        ;; ErrorCode (0 = none)
(global $err_line (mut i32) (i32.const 0))
(global $err_msg (mut i32) (i32.const 0))    ;; message id (table at 0x0500)
(global $unsafe_ints (mut i32) (i32.const 0))

;; ---------------------------------------------------------------------------
;; Errors
;; ---------------------------------------------------------------------------

;; Record an error with the default message of `code`. First error wins.
(func $fail (param $code i32) (param $line i32)
  (if (i32.eqz (global.get $err))
    (then
      (global.set $err (local.get $code))
      (global.set $err_line (local.get $line))
      (global.set $err_msg (local.get $code)))))

;; Record an error with a specific message id (>= 64, see the generator).
(func $fail_msg (param $code i32) (param $line i32) (param $msg i32)
  (if (i32.eqz (global.get $err))
    (then
      (global.set $err (local.get $code))
      (global.set $err_line (local.get $line))
      (global.set $err_msg (local.get $msg)))))

;; ---------------------------------------------------------------------------
;; Arena: 8-byte aligned bump allocation; grows memory on demand.
;; ---------------------------------------------------------------------------

;; Returns a pointer to `n` bytes, or 0 (with out_of_memory) on failure.
(func $alloc (param $n i32) (result i32)
  (local $p i32) (local $end i32) (local $pages i32)
  (local.set $p (i32.and (i32.add (global.get $arena_top) (i32.const 7)) (i32.const -8)))
  (local.set $end (i32.add (local.get $p) (local.get $n)))
  ;; keep 16 readable bytes after every block: guards written as eager
  ;; (i32.and (in-range?) (load ...)) may read just past a buffer, and the
  ;; vector short-copy reads up to 15 bytes past its source
  (if (i32.gt_u (i32.add (local.get $end) (i32.const 16)) (global.get $arena_limit))
    (then
      ;; pages = ceil((end - limit) / 64 KiB)
      (local.set $pages
        (i32.shr_u (i32.add (i32.sub (i32.add (local.get $end) (i32.const 16)) (global.get $arena_limit)) (i32.const 0xFFFF)) (i32.const 16)))
      (if (i32.eq (memory.grow (local.get $pages)) (i32.const -1))
        (then (call $fail (i32.const 46) (i32.const 0)) (return (i32.const 0))))  ;; out_of_memory
      (global.set $arena_limit (i32.shl (memory.size) (i32.const 16)))))
  (global.set $arena_top (local.get $end))
  (if (i32.gt_u (i32.sub (local.get $end) (global.get $HEAP)) (global.get $high_water))
    (then (global.set $high_water (i32.sub (local.get $end) (global.get $HEAP)))))
  (local.get $p))

;; Copy `len` bytes to a fresh arena block; returns the new pointer.
(func $dup (param $src i32) (param $len i32) (result i32)
  (local $p i32)
  (local.set $p (call $alloc (local.get $len)))
  (if (local.get $p) (then (memory.copy (local.get $p) (local.get $src) (local.get $len))))
  (local.get $p))

;; ---------------------------------------------------------------------------
;; Scratch stacks
;;
;; Growable LIFO byte stacks used while building containers of unknown size:
;; children are pushed, then copied once (exact size) into the arena when the
;; container closes, and the stack is rewound. A header is 3 x i32 in page 0:
;;   +0 base pointer, +4 used bytes, +8 capacity
;; Growing allocates a block twice as large and copies (amortised O(1)).
;; ---------------------------------------------------------------------------

(global $STK_NODES i32 (i32.const 0x7900))    ;; 16-byte value nodes
(global $STK_MEMBERS i32 (i32.const 0x7910))  ;; 24-byte object members
(global $STK_SLOTS i32 (i32.const 0x7920))    ;; tabular row slots
(global $STK_MISC i32 (i32.const 0x7930))     ;; (ptr, len) pairs: cells, keys...
(global $STK_OUT i32 (i32.const 0x7940))      ;; output byte buffer
(global $STK_ROW i32 (i32.const 0x7950))      ;; encoder per-row scratch bytes
(global $STK_FIELDS i32 (i32.const 0x7960))   ;; 32-byte field entries of a declaration
(global $STK_DEFER i32 (i32.const 0x7970))    ;; deferred [?] sections: (i64 actual, i32 line)
(global $STK_EXTRA i32 (i32.const 0x7980))    ;; per-row bare '>' attachments (members)

;; Forget every scratch stack (their blocks live in the arena being reset).
(func $reset_stacks
  (memory.fill (i32.const 0x7900) (i32.const 0) (i32.const 0x100))
  ;; the output write cursor pointed into a stack block
  (global.set $wp (i32.const 0))
  (global.set $wend (i32.const 0)))

(func $stack_reset (param $h i32)
  (i32.store (local.get $h) (i32.const 0))
  (i32.store offset=4 (local.get $h) (i32.const 0))
  (i32.store offset=8 (local.get $h) (i32.const 0)))

;; Reserve `n` bytes on stack `h`; returns their address (0 on OOM).
(func $stack_push (param $h i32) (param $n i32) (result i32)
  (local $len i32) (local $cap i32) (local $new i32) (local $ncap i32)
  (local.set $len (i32.load offset=4 (local.get $h)))
  (local.set $cap (i32.load offset=8 (local.get $h)))
  (if (i32.gt_u (i32.add (local.get $len) (local.get $n)) (local.get $cap))
    (then
      (local.set $ncap (i32.shl (local.get $cap) (i32.const 1)))
      (if (i32.lt_u (local.get $ncap) (i32.add (local.get $len) (local.get $n)))
        (then (local.set $ncap (i32.add (local.get $len) (local.get $n)))))
      (if (i32.lt_u (local.get $ncap) (i32.const 4096)) (then (local.set $ncap (i32.const 4096))))
      (local.set $new (call $alloc (local.get $ncap)))
      (if (i32.eqz (local.get $new)) (then (return (i32.const 0))))
      (memory.copy (local.get $new) (i32.load (local.get $h)) (local.get $len))
      (i32.store (local.get $h) (local.get $new))
      (i32.store offset=8 (local.get $h) (local.get $ncap))))
  (i32.store offset=4 (local.get $h) (i32.add (local.get $len) (local.get $n)))
  (i32.add (i32.load (local.get $h)) (local.get $len)))

(func $stack_len (param $h i32) (result i32) (i32.load offset=4 (local.get $h)))
(func $stack_base (param $h i32) (result i32) (i32.load (local.get $h)))
(func $stack_truncate (param $h i32) (param $len i32) (i32.store offset=4 (local.get $h) (local.get $len)))

;; Push an (i32, i32) pair.
(func $push_pair (param $h i32) (param $a i32) (param $b i32)
  (local $q i32)
  (local.set $q (call $stack_push (local.get $h) (i32.const 8)))
  (if (local.get $q) (then (i32.store (local.get $q) (local.get $a)) (i32.store offset=4 (local.get $q) (local.get $b)))))

;; Copy stack bytes [from, len) into the arena and rewind to `from`.
(func $stack_pop_to_arena (param $h i32) (param $from i32) (result i32)
  (local $n i32) (local $p i32)
  (local.set $n (i32.sub (i32.load offset=4 (local.get $h)) (local.get $from)))
  (local.set $p (call $alloc (local.get $n)))
  (if (local.get $p)
    (then (memory.copy (local.get $p) (i32.add (i32.load (local.get $h)) (local.get $from)) (local.get $n))))
  (i32.store offset=4 (local.get $h) (local.get $from))
  (local.get $p))

;; ---------------------------------------------------------------------------
;; Output buffer (bytes appended to the STK_OUT stack)
;; ---------------------------------------------------------------------------

(func $out_byte (param $b i32)
  (local $p i32)
  (local.set $p (call $stack_push (global.get $STK_OUT) (i32.const 1)))
  (if (local.get $p) (then (i32.store8 (local.get $p) (local.get $b)))))

(func $out_bytes (param $src i32) (param $len i32)
  (local $p i32)
  (if (i32.eqz (local.get $len)) (then (return)))
  (local.set $p (call $stack_push (global.get $STK_OUT) (local.get $len)))
  (if (local.get $p) (then (memory.copy (local.get $p) (local.get $src) (local.get $len)))))

;; Publish the output buffer as the result of the call.
(func $out_finish
  (global.set $out_ptr (call $stack_base (global.get $STK_OUT)))
  (global.set $out_len (call $stack_len (global.get $STK_OUT))))

;; ---------------------------------------------------------------------------
;; Per-call reset and basic ABI exports
;; ---------------------------------------------------------------------------

(func (export "gcf_abi_version") (result i32) (i32.const 1))

(func (export "gcf_input_alloc") (param $len i32) (result i32)
  (local $p i32)
  (global.set $arena_top (global.get $HEAP))
  (global.set $err (i32.const 0))
  (global.set $err_line (i32.const 0))
  (global.set $err_msg (i32.const 0))
  (global.set $out_ptr (i32.const 0))
  (global.set $out_len (i32.const 0))
  (global.set $unsafe_ints (i32.const 0))
  (call $reset_stacks)
  (local.set $p (call $alloc (select (local.get $len) (i32.const 1) (local.get $len))))
  (global.set $in_ptr (local.get $p))
  (local.get $p))

(func (export "gcf_output_ptr") (result i32) (global.get $out_ptr))
(func (export "gcf_output_len") (result i32) (global.get $out_len))
(func (export "gcf_output_unsafe_ints") (result i32) (global.get $unsafe_ints))
(func (export "gcf_error_line") (result i32) (global.get $err_line))
(func (export "gcf_error_name_ptr") (result i32)
  (i32.load (i32.add (i32.const 0x0300) (i32.shl (global.get $err) (i32.const 3)))))
(func (export "gcf_error_name_len") (result i32)
  (i32.load offset=4 (i32.add (i32.const 0x0300) (i32.shl (global.get $err) (i32.const 3)))))
(func (export "gcf_error_message_ptr") (result i32)
  (i32.load (i32.add (i32.const 0x0500) (i32.shl (global.get $err_msg) (i32.const 3)))))
(func (export "gcf_error_message_len") (result i32)
  (i32.load offset=4 (i32.add (i32.const 0x0500) (i32.shl (global.get $err_msg) (i32.const 3)))))
(func (export "gcf_arena_high_water") (result i32) (global.get $high_water))
(func (export "gcf_memory_pages") (result i32) (memory.size))
