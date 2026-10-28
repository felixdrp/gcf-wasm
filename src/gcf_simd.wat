;; SPDX-License-Identifier: Apache-2.0
;; Copyright 2026 felixdrp
;;
;; ============================================================================
;; gcf_simd.wat — Module A: hand-written WebAssembly SIMD structural indexer
;;                for the Graph Compact Format (GCF v3.6.0).
;; ============================================================================
;;
;; WHAT THIS MODULE DOES
;; ---------------------
;; A GCF parser spends most of its time looking for structural delimiters.
;; This module finds every structural byte of the GCF alphabet
;;
;;     LF  "  #  ,  :  =  @  [  ]  ^  {  |  }  ~
;;     0A 22 23 2C 3A 3D 40 5B 5D 5E 7B 7C 7D 7E
;;
;; in 16-byte steps with 128-bit SIMD, never branching per byte.
;;
;; HOW: NIBBLE-TABLE CLASSIFICATION (2 lookups instead of 14 compares)
;; -------------------------------------------------------------------
;; Comparing every lane against 14 constants costs 14 `i8x16.eq` plus 13
;; `v128.or`. Instead, split each byte into a low nibble (bits 0-3) and a high
;; nibble (bits 4-7) and look each one up in a 16-entry table with
;; `i8x16.swizzle`, which is a parallel 16-way table lookup. Each table entry is
;; a small bit set. A byte is structural iff (LO[lo] AND HI[hi]) != 0.
;;
;; The high nibble picks one "row" bit. The high nibbles that occur in the
;; alphabet are 0,2,3,4,5,7:
;;
;;     HI[0]=0x01  HI[2]=0x02  HI[3]=0x04  HI[4]=0x08  HI[5]=0x10  HI[7]=0x20
;;     (every other HI entry is 0, including 8..F, so non-ASCII never matches)
;;
;; The low-nibble table lists which rows accept that low nibble:
;;
;;     lo  bytes in the alphabet with this low nibble    LO entry
;;     0   40 '@'                                        0x08 (row 4)
;;     2   22 '"'                                        0x02 (row 2)
;;     3   23 '#'                                        0x02 (row 2)
;;     A   0A LF, 3A ':'                                 0x05 (rows 0,3)
;;     B   5B '[', 7B '{'                                0x30 (rows 5,7)
;;     C   2C ',', 7C '|'                                0x22 (rows 2,7)
;;     D   3D '=', 5D ']', 7D '}'                        0x34 (rows 3,5,7)
;;     E   5E '^', 7E '~'                                0x30 (rows 5,7)
;;
;; Per 16-byte block that is: and, shr_u, 2x swizzle, and, ne, bitmask, about
;; 8 SIMD instructions for all 14 delimiters at once. The test harness checks
;; all 256 byte values against a scalar reference to prove the tables have no
;; false positives.
;;
;; FROM BITMASK TO POSITIONS (branchless offsets)
;; ----------------------------------------------
;; `i8x16.bitmask` packs the top bit of every lane into an i32 (bit k = lane
;; k). `i32.ctz` of that mask is the offset of the first structural byte in the
;; block. `mask & (mask - 1)` clears the lowest set bit, so a hit-draining loop
;; runs once per structural byte, not once per input byte.
;;
;; TAIL HANDLING
;; -------------
;; The last len % 16 bytes are classified one at a time with the same two
;; tables (stored once in a data segment), so the module never reads past
;; `ptr + len` and can't trap on the final memory page.
;;
;; MEMORY LAYOUT (one linear memory, exported as "memory")
;; -------------------------------------------------------
;;     [0x0000, 0x0010)  LO nibble table (16 bytes)
;;     [0x0010, 0x0020)  HI nibble table (16 bytes)
;;     [0x0400, ...   )  host-owned input buffer (`input_base`)
;; The host calls `ensure_capacity(n)` to grow memory before copying input.
;;
;; STACK NOTATION
;; --------------
;; Comments of the form  ;; [a b] -> [c]  show the operand stack before and
;; after an instruction (top of stack on the right).
;; ============================================================================

(module
  ;; One page (64 KiB) to start; the host grows it through ensure_capacity.
  (memory (export "memory") 1)

  ;; The two classification tables, laid out exactly as described above.
  ;; LO table at offset 0.
  (data (i32.const 0)
    "\08\00\02\02\00\00\00\00\00\00\05\30\22\34\30\00")
  ;; HI table at offset 16.
  (data (i32.const 16)
    "\01\00\02\04\08\10\00\20\00\00\00\00\00\00\00\00")

  ;; Where the host should place input bytes.
  (global $INPUT_BASE i32 (i32.const 1024))

  ;; --------------------------------------------------------------------------
  ;; input_base() -> i32
  ;; --------------------------------------------------------------------------
  (func (export "input_base") (result i32)
    global.get $INPUT_BASE          ;; [] -> [1024]
  )

  ;; --------------------------------------------------------------------------
  ;; ensure_capacity(bytes) -> i32
  ;; Grow memory so [INPUT_BASE, INPUT_BASE + bytes) is addressable.
  ;; Returns 1 on success, 0 if memory.grow fails.
  ;; --------------------------------------------------------------------------
  (func (export "ensure_capacity") (param $bytes i32) (result i32)
    (local $need_pages i32)
    ;; need_pages = ceil((INPUT_BASE + bytes) / 65536)
    global.get $INPUT_BASE          ;; [] -> [base]
    local.get $bytes                ;; [base] -> [base bytes]
    i32.add                         ;; [base bytes] -> [end]
    i32.const 65535                 ;; [end] -> [end 65535]
    i32.add                         ;; -> [end+65535]
    i32.const 16                    ;; -> [end+65535 16]
    i32.shr_u                       ;; -> [ceil(end/64Ki)]
    local.tee $need_pages           ;; keep a copy in the local, leave it on the stack
    memory.size                     ;; -> [need have]
    i32.le_u                        ;; -> [need <= have]
    if                              ;; already large enough
      i32.const 1
      return
    end
    local.get $need_pages           ;; -> [need]
    memory.size                     ;; -> [need have]
    i32.sub                         ;; -> [delta pages]
    memory.grow                     ;; -> [old size, or -1 on failure]
    i32.const -1                    ;; -> [old -1]
    i32.ne                          ;; -> [success?]
  )

  ;; --------------------------------------------------------------------------
  ;; $classify16(block: v128) -> i32 mask
  ;; The SIMD core: bit k of the result is 1 iff byte k of `block` is structural.
  ;; --------------------------------------------------------------------------
  (func $classify16 (param $block v128) (result i32)
    ;; ---- low-nibble lookup ------------------------------------------------
    i32.const 0                     ;; [] -> [&LO]
    v128.load                       ;; [&LO] -> [LO]  (16-entry table in one register)
    local.get $block                ;; [LO] -> [LO block]
    v128.const i8x16 15 15 15 15 15 15 15 15 15 15 15 15 15 15 15 15
                                    ;; -> [LO block 0x0F..]
    v128.and                        ;; -> [LO lo_nibbles]  each lane is 0..15
    i8x16.swizzle                   ;; -> [LO[lo]]  lane k = LO[lo_nibble_k]

    ;; ---- high-nibble lookup -----------------------------------------------
    i32.const 16                    ;; -> [LO[lo] &HI]
    v128.load                       ;; -> [LO[lo] HI]
    local.get $block                ;; -> [LO[lo] HI block]
    i32.const 4                     ;; -> [LO[lo] HI block 4]
    i8x16.shr_u                     ;; -> [LO[lo] HI hi_nibbles]  logical shift per lane
                                    ;;    (shr_u is required: shr_s would sign-extend
                                    ;;     bytes >= 0x80 and yield indices >= 16)
    i8x16.swizzle                   ;; -> [LO[lo] HI[hi]]

    ;; ---- intersect the two bit sets ---------------------------------------
    v128.and                        ;; -> [class]  non-zero lane == structural byte
    v128.const i64x2 0 0            ;; -> [class 0]
    i8x16.ne                        ;; -> [lanes]  0xFF where class != 0, else 0x00
    i8x16.bitmask                   ;; -> [mask]   top bit of each lane packed into i32
  )

  ;; --------------------------------------------------------------------------
  ;; $classify_byte(b: i32) -> i32 (0 or 1)
  ;; Scalar fallback for the < 16-byte tail; same tables, so same answer.
  ;; --------------------------------------------------------------------------
  (func $classify_byte (param $b i32) (result i32)
    local.get $b                    ;; [] -> [b]
    i32.const 15                    ;; -> [b 15]
    i32.and                         ;; -> [lo]
    i32.load8_u offset=0            ;; -> [LO[lo]]
    local.get $b                    ;; -> [LO[lo] b]
    i32.const 4                     ;; -> [LO[lo] b 4]
    i32.shr_u                       ;; -> [LO[lo] hi]  (b is a byte, so hi is 0..15)
    i32.load8_u offset=16           ;; -> [LO[lo] HI[hi]]
    i32.and                         ;; -> [class]
    i32.const 0                     ;; -> [class 0]
    i32.ne                          ;; -> [class != 0]
  )

  ;; --------------------------------------------------------------------------
  ;; classify_byte_export(b) -> i32 : exposes the scalar classifier so the host
  ;; can verify all 256 byte values against its own reference set.
  ;; --------------------------------------------------------------------------
  (func (export "classify_byte") (param $b i32) (result i32)
    local.get $b
    i32.const 255
    i32.and                         ;; clamp to one byte
    call $classify_byte
  )

  ;; --------------------------------------------------------------------------
  ;; count_structural(ptr, len) -> i32
  ;; Number of structural bytes in memory[ptr .. ptr+len).
  ;;
  ;; This is the throughput-tuned form of the $classify16 pipeline; the
  ;; harness holds it to <= 3 CPU cycles per 16-byte block:
  ;;   * The nibble tables and the 0x0F mask live in v128 locals, loaded once
  ;;     per call instead of once per block.
  ;;   * No per-block bitmask/popcnt/scalar add. i8x16.eq(class, 0) is 0xFF
  ;;     (= -1) in every NON-structural lane, and i8x16.sub(acc, that) adds +1
  ;;     to that lane, so 16 byte-wide counters accumulate in one register.
  ;;   * 4 blocks (64 bytes) per iteration amortise the loop branch.
  ;;   * A lane counter is 8 bits wide and gains at most 4 per iteration, so
  ;;     every 63 iterations (252 < 256) the accumulator is widened and summed:
  ;;     extadd_pairwise u8->u16, then u16->u32, then the four i32 lanes.
  ;; Result = SIMD bytes - non-structural bytes + hits in the < 64-byte tail.
  ;; --------------------------------------------------------------------------
  (func (export "count_structural") (param $ptr i32) (param $len i32) (result i32)
    (local $p i32)          ;; cursor
    (local $end i32)        ;; ptr + len
    (local $vec_end i32)    ;; end of the 64-byte-multiple prefix
    (local $chunk_end i32)  ;; end of the current <= 252-block chunk
    (local $non i32)        ;; non-structural bytes counted by the SIMD loop
    (local $count i32)      ;; result
    (local $lo_tab v128)
    (local $hi_tab v128)
    (local $nib v128)
    (local $acc v128)       ;; 16 lane counters (u8)
    (local $v v128)         ;; scratch block

    ;; Hoist the constants into registers.
    i32.const 0
    v128.load
    local.set $lo_tab
    i32.const 16
    v128.load
    local.set $hi_tab
    v128.const i8x16 15 15 15 15 15 15 15 15 15 15 15 15 15 15 15 15
    local.set $nib

    local.get $ptr
    local.set $p
    local.get $ptr
    local.get $len
    i32.add
    local.set $end
    ;; vec_end = ptr + (len & ~63)
    local.get $ptr
    local.get $len
    i32.const -64
    i32.and
    i32.add
    local.set $vec_end

    block $simd_done
      loop $chunk
        local.get $p
        local.get $vec_end
        i32.ge_u
        br_if $simd_done

        ;; chunk_end = min(p + 63 * 64, vec_end)
        local.get $p
        i32.const 4032
        i32.add
        local.tee $chunk_end
        local.get $vec_end
        i32.gt_u
        if
          local.get $vec_end
          local.set $chunk_end
        end

        v128.const i64x2 0 0
        local.set $acc          ;; fresh counters for this chunk

        loop $blocks
          ;; ---- one 16-byte block at p+0 ------------------------------
          local.get $lo_tab             ;; [LO]
          local.get $p
          v128.load offset=0          ;; [LO block]
          local.tee $v                  ;; keep the block for the high-nibble path
          local.get $nib
          v128.and                      ;; [LO lo]
          i8x16.swizzle ;; @relaxed     [LO[lo]]
          local.get $hi_tab             ;; [LO[lo] HI]
          local.get $v
          i32.const 4
          i16x8.shr_u                   ;; 16-bit shift (cheaper than i8x16.shr_u on x86)
          local.get $nib
          v128.and                      ;; [LO[lo] HI hi]  drop the neighbour's bits
          i8x16.swizzle ;; @relaxed     [LO[lo] HI[hi]]
          v128.and                      ;; [class]
          v128.const i64x2 0 0
          i8x16.eq                      ;; [0xFF where NOT structural]
          local.set $v
          local.get $acc
          local.get $v
          i8x16.sub                     ;; acc - (-1) = acc + 1 per non-structural lane
          local.set $acc
          ;; ---- one 16-byte block at p+16 ------------------------------
          local.get $lo_tab             ;; [LO]
          local.get $p
          v128.load offset=16          ;; [LO block]
          local.tee $v                  ;; keep the block for the high-nibble path
          local.get $nib
          v128.and                      ;; [LO lo]
          i8x16.swizzle ;; @relaxed     [LO[lo]]
          local.get $hi_tab             ;; [LO[lo] HI]
          local.get $v
          i32.const 4
          i16x8.shr_u                   ;; 16-bit shift (cheaper than i8x16.shr_u on x86)
          local.get $nib
          v128.and                      ;; [LO[lo] HI hi]  drop the neighbour's bits
          i8x16.swizzle ;; @relaxed     [LO[lo] HI[hi]]
          v128.and                      ;; [class]
          v128.const i64x2 0 0
          i8x16.eq                      ;; [0xFF where NOT structural]
          local.set $v
          local.get $acc
          local.get $v
          i8x16.sub                     ;; acc - (-1) = acc + 1 per non-structural lane
          local.set $acc
          ;; ---- one 16-byte block at p+32 ------------------------------
          local.get $lo_tab             ;; [LO]
          local.get $p
          v128.load offset=32          ;; [LO block]
          local.tee $v                  ;; keep the block for the high-nibble path
          local.get $nib
          v128.and                      ;; [LO lo]
          i8x16.swizzle ;; @relaxed     [LO[lo]]
          local.get $hi_tab             ;; [LO[lo] HI]
          local.get $v
          i32.const 4
          i16x8.shr_u                   ;; 16-bit shift (cheaper than i8x16.shr_u on x86)
          local.get $nib
          v128.and                      ;; [LO[lo] HI hi]  drop the neighbour's bits
          i8x16.swizzle ;; @relaxed     [LO[lo] HI[hi]]
          v128.and                      ;; [class]
          v128.const i64x2 0 0
          i8x16.eq                      ;; [0xFF where NOT structural]
          local.set $v
          local.get $acc
          local.get $v
          i8x16.sub                     ;; acc - (-1) = acc + 1 per non-structural lane
          local.set $acc
          ;; ---- one 16-byte block at p+48 ------------------------------
          local.get $lo_tab             ;; [LO]
          local.get $p
          v128.load offset=48          ;; [LO block]
          local.tee $v                  ;; keep the block for the high-nibble path
          local.get $nib
          v128.and                      ;; [LO lo]
          i8x16.swizzle ;; @relaxed     [LO[lo]]
          local.get $hi_tab             ;; [LO[lo] HI]
          local.get $v
          i32.const 4
          i16x8.shr_u                   ;; 16-bit shift (cheaper than i8x16.shr_u on x86)
          local.get $nib
          v128.and                      ;; [LO[lo] HI hi]  drop the neighbour's bits
          i8x16.swizzle ;; @relaxed     [LO[lo] HI[hi]]
          v128.and                      ;; [class]
          v128.const i64x2 0 0
          i8x16.eq                      ;; [0xFF where NOT structural]
          local.set $v
          local.get $acc
          local.get $v
          i8x16.sub                     ;; acc - (-1) = acc + 1 per non-structural lane
          local.set $acc
          local.get $p
          i32.const 64
          i32.add
          local.tee $p
          local.get $chunk_end
          i32.lt_u
          br_if $blocks         ;; next 64 bytes
        end

        ;; Flush: widen u8 -> u16 -> u32 lanes, then add the four i32 lanes.
        local.get $acc
        i16x8.extadd_pairwise_i8x16_u   ;; [8 x u16]
        i32x4.extadd_pairwise_i16x8_u   ;; [4 x u32]
        local.tee $v
        i32x4.extract_lane 0
        local.get $v
        i32x4.extract_lane 1
        i32.add
        local.get $v
        i32x4.extract_lane 2
        i32.add
        local.get $v
        i32x4.extract_lane 3
        i32.add
        local.get $non
        i32.add
        local.set $non
        br $chunk
      end
    end

    ;; structural bytes in the SIMD prefix = prefix length - non-structural
    local.get $vec_end
    local.get $ptr
    i32.sub
    local.get $non
    i32.sub
    local.set $count

    ;; ---- tail < 64 bytes: whole 16-byte blocks via $classify16 --------------
    block $blk_done
      loop $blk
        local.get $p
        i32.const 16
        i32.add
        local.get $end
        i32.gt_u
        br_if $blk_done
        local.get $count
        local.get $p
        v128.load
        call $classify16
        i32.popcnt
        i32.add
        local.set $count
        local.get $p
        i32.const 16
        i32.add
        local.set $p
        br $blk
      end
    end

    ;; ---- final < 16 bytes: scalar ------------------------------------------
    block $tail_done
      loop $tail
        local.get $p
        local.get $end
        i32.ge_u
        br_if $tail_done
        local.get $count
        local.get $p
        i32.load8_u
        call $classify_byte
        i32.add
        local.set $count
        local.get $p
        i32.const 1
        i32.add
        local.set $p
        br $tail
      end
    end

    local.get $count
  )

  ;; --------------------------------------------------------------------------
  ;; index_structural(ptr, len, out) -> i32
  ;; Writes the offset (relative to ptr) of every structural byte as an i32 to
  ;; memory[out ..] and returns how many were written.
  ;;
  ;; The caller must provide room for len + 8 entries. The extractor stores
  ;; positions in groups of four *unconditionally* and only then advances
  ;; the write cursor by popcnt(mask), so up to 7 slots past the last real
  ;; entry may be overwritten with junk. This is the simdjson "flatten bits"
  ;; idea: one predictable branch per 4 hits instead of one unpredictable
  ;; branch per hit. In GCF ~20% of bytes are structural (~3 per block), so
  ;; the hit count per block varies constantly and a per-hit loop exit would
  ;; mispredict often.
  ;; --------------------------------------------------------------------------
  (func (export "index_structural") (param $ptr i32) (param $len i32) (param $out i32) (result i32)
    (local $p i32)
    (local $vec_end i32)
    (local $end i32)
    (local $w i32)          ;; write cursor (byte address in out)
    (local $mask i32)
    (local $cnt i32)        ;; hits in the current block
    (local $off i32)        ;; block offset relative to ptr
    (local $lo_tab v128)
    (local $hi_tab v128)
    (local $nib v128)
    (local $v v128)

    i32.const 0
    v128.load
    local.set $lo_tab
    i32.const 16
    v128.load
    local.set $hi_tab
    v128.const i8x16 15 15 15 15 15 15 15 15 15 15 15 15 15 15 15 15
    local.set $nib

    local.get $ptr
    local.set $p
    local.get $ptr
    local.get $len
    i32.add
    local.set $end
    local.get $ptr
    local.get $len
    i32.const -16
    i32.and
    i32.add
    local.set $vec_end
    local.get $out
    local.set $w

    block $vec_done
      loop $vec
        local.get $p
        local.get $vec_end
        i32.ge_u
        br_if $vec_done

        ;; ---- classify (same tables as $classify16, constants in registers) --
        local.get $lo_tab
        local.get $p
        v128.load
        local.tee $v
        local.get $nib
        v128.and                      ;; low nibbles
        i8x16.swizzle ;; @relaxed     indices are 0..15, so relaxed == strict
        local.get $hi_tab
        local.get $v
        i32.const 4
        i16x8.shr_u                   ;; 16-bit shift: each byte's high nibble lands
        local.get $nib                ;; in its low half, plus 4 bits from the
        v128.and                      ;; neighbouring byte, which the mask removes
        i8x16.swizzle ;; @relaxed
        v128.and                      ;; [class]
        v128.const i64x2 0 0
        i8x16.ne
        i8x16.bitmask
        local.tee $mask               ;; [mask]

        if                            ;; block has at least one structural byte
          local.get $p
          local.get $ptr
          i32.sub
          local.set $off
          local.get $mask
          i32.popcnt
          local.set $cnt              ;; remember how many hits before draining

          ;; Hits 1-4: written unconditionally. Once the mask is empty, ctz
          ;; returns 32 and the store writes junk (off + 32) into a slot the
          ;; cursor never reaches, which is harmless.
            local.get $w
            local.get $off
            local.get $mask
            i32.ctz
            i32.add
            i32.store offset=0        ;; out[w+0] = off + ctz(mask)
            local.get $mask
            local.get $mask
            i32.const 1
            i32.sub
            i32.and
            local.set $mask                   ;; clear the lowest set bit
            local.get $w
            local.get $off
            local.get $mask
            i32.ctz
            i32.add
            i32.store offset=4        ;; out[w+1] = off + ctz(mask)
            local.get $mask
            local.get $mask
            i32.const 1
            i32.sub
            i32.and
            local.set $mask                   ;; clear the lowest set bit
            local.get $w
            local.get $off
            local.get $mask
            i32.ctz
            i32.add
            i32.store offset=8        ;; out[w+2] = off + ctz(mask)
            local.get $mask
            local.get $mask
            i32.const 1
            i32.sub
            i32.and
            local.set $mask                   ;; clear the lowest set bit
            local.get $w
            local.get $off
            local.get $mask
            i32.ctz
            i32.add
            i32.store offset=12        ;; out[w+3] = off + ctz(mask)
            local.get $mask
            local.get $mask
            i32.const 1
            i32.sub
            i32.and
            local.set $mask                   ;; clear the lowest set bit

          local.get $cnt
          i32.const 4
          i32.gt_u
          if                          ;; hits 5-8
            local.get $w
              local.get $off
              local.get $mask
              i32.ctz
              i32.add
              i32.store offset=16        ;; out[w+4] = off + ctz(mask)
              local.get $mask
              local.get $mask
              i32.const 1
              i32.sub
              i32.and
              local.set $mask                   ;; clear the lowest set bit
              local.get $w
              local.get $off
              local.get $mask
              i32.ctz
              i32.add
              i32.store offset=20        ;; out[w+5] = off + ctz(mask)
              local.get $mask
              local.get $mask
              i32.const 1
              i32.sub
              i32.and
              local.set $mask                   ;; clear the lowest set bit
              local.get $w
              local.get $off
              local.get $mask
              i32.ctz
              i32.add
              i32.store offset=24        ;; out[w+6] = off + ctz(mask)
              local.get $mask
              local.get $mask
              i32.const 1
              i32.sub
              i32.and
              local.set $mask                   ;; clear the lowest set bit
              local.get $w
              local.get $off
              local.get $mask
              i32.ctz
              i32.add
              i32.store offset=28        ;; out[w+7] = off + ctz(mask)
              local.get $mask
              local.get $mask
              i32.const 1
              i32.sub
              i32.and
              local.set $mask                   ;; clear the lowest set bit

            ;; Hits 9-16 (rare): drain the remainder one at a time.
            block $rest_done
              loop $rest
                local.get $mask
                i32.eqz
                br_if $rest_done
                local.get $w
                local.get $off
                local.get $mask
                i32.ctz
                i32.add
                i32.store offset=32
                local.get $w
                i32.const 4
                i32.add
                local.set $w          ;; shift the base so offset=32 points at the next slot
                local.get $mask
                local.get $mask
                i32.const 1
                i32.sub
                i32.and
                local.set $mask
                br $rest
              end
            end
          end

          ;; Advance the cursor by the real hit count. The rare-path loop
          ;; above already moved it by (cnt - 8) entries.
          local.get $cnt
          i32.const 8
          i32.gt_u
          if (result i32)
            i32.const 32              ;; 8 entries written by the two groups of four
          else
            local.get $cnt
            i32.const 2
            i32.shl                   ;; cnt * 4 bytes
          end
          local.get $w
          i32.add
          local.set $w
        end

        local.get $p
        i32.const 16
        i32.add
        local.set $p
        br $vec
      end
    end

    ;; Scalar tail (< 16 bytes).
    block $tail_done
      loop $tail
        local.get $p
        local.get $end
        i32.ge_u
        br_if $tail_done

        local.get $p
        i32.load8_u
        call $classify_byte
        if
          local.get $w
          local.get $p
          local.get $ptr
          i32.sub
          i32.store                   ;; out[w] = p - ptr
          local.get $w
          i32.const 4
          i32.add
          local.set $w
        end

        local.get $p
        i32.const 1
        i32.add
        local.set $p
        br $tail
      end
    end

    ;; Entries written = (w - out) / 4
    local.get $w
    local.get $out
    i32.sub
    i32.const 2
    i32.shr_u
  )

  ;; --------------------------------------------------------------------------
  ;; next_structural(ptr, len, from) -> i32
  ;; Offset (relative to ptr) of the first structural byte at or after `from`,
  ;; or -1. The first partial block is handled by masking off lanes before
  ;; `from`, so the result comes straight out of one `i32.ctz`.
  ;; --------------------------------------------------------------------------
  (func (export "next_structural") (param $ptr i32) (param $len i32) (param $from i32) (result i32)
    (local $p i32)
    (local $end i32)
    (local $mask i32)

    local.get $ptr
    local.get $len
    i32.add
    local.set $end
    local.get $ptr
    local.get $from
    i32.add
    local.set $p

    block $vec_done
      loop $vec
        ;; need a whole block: p + 16 <= end
        local.get $p
        i32.const 16
        i32.add
        local.get $end
        i32.gt_u
        br_if $vec_done

        local.get $p
        v128.load
        call $classify16
        local.tee $mask
        if
          local.get $p
          local.get $ptr
          i32.sub                   ;; [block_offset]
          local.get $mask
          i32.ctz                   ;; [block_offset lane]
          i32.add                   ;; [offset]
          return
        end

        local.get $p
        i32.const 16
        i32.add
        local.set $p
        br $vec
      end
    end

    block $tail_done
      loop $tail
        local.get $p
        local.get $end
        i32.ge_u
        br_if $tail_done

        local.get $p
        i32.load8_u
        call $classify_byte
        if
          local.get $p
          local.get $ptr
          i32.sub
          return
        end

        local.get $p
        i32.const 1
        i32.add
        local.set $p
        br $tail
      end
    end

    i32.const -1
  )
  ;; --------------------------------------------------------------------------
  ;; calibrate(n, k, m) -> i32
  ;; Clock estimator for cycles-per-block measurements (WebAssembly cannot read
  ;; the CPU cycle counter). Each iteration runs a chain of 16 *dependent*
  ;; scalar ops, x = (x + k) ^ m eight times. Every op needs the previous
  ;; result, and i32 add/xor have 1-cycle latency on current x86-64 and
  ;; ARM64 cores, so the chain advances one op per cycle: 16 * n ops take
  ;; ~16 * n cycles, and the host derives the effective frequency from the
  ;; elapsed time. k and m are runtime parameters, so the JIT cannot fold the
  ;; chain into a constant. The result is returned so the work is never dead.
  ;; --------------------------------------------------------------------------
  (func (export "calibrate") (param $n i32) (param $k i32) (param $m i32) (result i32)
    (local $x i32)
    local.get $k
    local.set $x
    loop $spin
      ;; 8 x (add, xor): 16 ops on one dependency chain
      local.get $x  local.get $k  i32.add  local.get $m  i32.xor
      local.get $k  i32.add  local.get $m  i32.xor
      local.get $k  i32.add  local.get $m  i32.xor
      local.get $k  i32.add  local.get $m  i32.xor
      local.get $k  i32.add  local.get $m  i32.xor
      local.get $k  i32.add  local.get $m  i32.xor
      local.get $k  i32.add  local.get $m  i32.xor
      local.get $k  i32.add  local.get $m  i32.xor
      local.set $x
      local.get $n
      i32.const 1
      i32.sub
      local.tee $n
      br_if $spin               ;; loop while n != 0
    end
    local.get $x
  )
)
