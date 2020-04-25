#lang rosette

(require
  (prefix-in core: "../lib/core.rkt")
  (only-in racket/base hash-has-key? hash-ref)
  "base.rkt")

(provide (all-defined-out) (all-from-out "base.rkt"))

(struct program (base instructions) #:transparent)

(define (cpu-next! cpu size)
  (set-cpu-pc! cpu (bvadd (bv size (XLEN)) (cpu-pc cpu))))

; memory

(struct ptr (block path) #:transparent)

(define (memop->size op)
  (case op
    [(lb lbu sb) 1]
    [(lh lhu sh) 2]
    [(lw lwu sw) 4]
    [(ld ldu sd) 8]
    [else (core:bug #:dbg current-pc-debug #:msg (format "memop->size: no such memop ~e\n" op))]))

(define (load-signed? op)
  (case op
    [(lb lh lw ld) #t]
    [(lbu lhu lwu ldu) #f]
    [else (core:bug #:dbg current-pc-debug #:msg (format "load-signed?: no such load ~e\n" op))]))

(define (resolve-mem-path cpu instr)
  (define-values (type off reg)
    (cond
      [(rv_s_insn? instr) (values (rv_s_insn-op instr) (rv_s_insn-imm12 instr) (rv_s_insn-rs1 instr))]
      [(rv_i_insn? instr) (values (rv_i_insn-op instr) (rv_i_insn-imm12 instr) (rv_i_insn-rs1 instr))]
      [else (core:bug #:msg (format "resolve-mem-path: bad insn type ~v" instr) #:dbg current-pc-debug)]))

  (define mr (core:guess-mregion-from-addr #:dbg current-pc-debug (cpu-mregions cpu) (gpr-ref cpu reg) off))
  (define start (core:mregion-start mr))
  (define end (core:mregion-end mr))
  (define name (core:mregion-name mr))
  (define block (core:mregion-block mr))

  (define addr (bvadd (sign-extend off (bitvector (XLEN))) (gpr-ref cpu reg)))
  (define size (core:bvpointer (memop->size type)))
  (define offset (bvsub addr (bv start (XLEN))))

  (core:bug-on (! (core:mregion-inbounds? mr addr size))
                #:dbg current-pc-debug
                #:msg (format "resolve-mem-path: address out of range:\n addr: ~e\n block: ~e" addr name))
  (define path (core:mblock-path block offset size #:dbg current-pc-debug))
  (ptr block path))

; conditionals

(define (evaluate-binary-conditional type val1 val2)
  (case type
    [(bge) (bvsge val1 val2)]
    [(blt) (bvslt val1 val2)]
    [(bgeu) (bvuge val1 val2)]
    [(bltu) (bvult val1 val2)]
    [(bne) (! (bveq val1 val2))]
    [(beq) (bveq val1 val2)]
    [else (core:bug #:dbg current-pc-debug
                    #:msg (format "evaluate-binary-conditional: no such binary conditional ~e\n" type))]))

(define (evaluate-binary-op type v1 v2)
  (case type
    [(addi addw add) (bvadd v1 v2)]
    [(subi subw sub) (bvsub v1 v2)]
    [(ori or) (bvor v1 v2)]
    [(andi and) (bvand v1 v2)]
    [(xori xor) (bvxor v1 v2)]
    [(slliw slli sllw sll) (bvshl v1 (bvand (bv (sub1 (core:bv-size v1)) (core:bv-size v1)) v2))]
    [(srliw srli srlw srl) (bvlshr v1 (bvand (bv (sub1 (core:bv-size v1)) (core:bv-size v1)) v2))]
    [(sraiw srai sraw sra) (bvashr v1 (bvand (bv (sub1 (core:bv-size v1)) (core:bv-size v1)) v2))]
    [(mulw mul) ((core:bvmul-proc) v1 v2)]
    [(mulh) ((core:bvmulh-proc) v1 v2)]
    [(mulhu) ((core:bvmulhu-proc) v1 v2)]
    [(mulhsu) ((core:bvmulhsu-proc) v1 v2)]
    ; our code doesn't really use divisions - just add for completeness
    ; smtlib seems to have a different div-by-zero semantics for bvsdiv
    ; (bvsdiv -1 0) returns 1, while riscv returns -1
    [(divw div) (if (core:bvzero? v2) (bv -1 (core:bv-size v1)) ((core:bvsdiv-proc) v1 v2))]
    [(remw rem) (if (core:bvzero? v2) v1 ((core:bvsrem-proc) v1 v2))]
    [(divuw divu) ((core:bvudiv-proc) v1 v2)]
    [(remuw remu) ((core:bvurem-proc) v1 v2)]
    [else (core:bug #:dbg current-pc-debug
                    #:msg (format "evaluate-binary-op: no such binary op ~e\n" type))]))

(define (jump-and-link cpu reg addr #:size size)

  (define target
    (bvadd
      (cpu-pc cpu)
      (bvshl
        (sign-extend addr (bitvector (XLEN)))
        (bv 1 (XLEN)))))

  ; Set register to address of following instruction
  (gpr-set! cpu reg (bvadd (bv size (XLEN)) (cpu-pc cpu)))
  (set-cpu-pc! cpu target))

(define (do-csr-op cpu op dst csr value)
  (when (! (core:bvzero? (gpr->idx dst)))
    (gpr-set! cpu dst (zero-extend (csr-ref cpu csr) (bitvector (XLEN)))))
  (case op
    [(csrrw csrrwi)
      (csr-set! cpu csr value)]
    [(csrrs csrrsi)
      (csr-set! cpu csr (bvor (csr-ref cpu csr) value))]
    [(csrrc csrrci)
      (csr-set! cpu csr (bvand (csr-ref cpu csr) (bvnot value)))]
    [else (core:bug #:msg (format "do-csr-op: Unknown csr op ~v" op) #:dbg current-pc-debug)]))

(define (check-imm-size size imm)
  (core:bug-on (! (= size (for/all ([imm imm #:exhaustive]) (core:bv-size imm))))
               #:msg (format "Bad immediate size: Expected ~e got ~e" (bitvector size) imm)
               #:dbg current-pc-debug))

(define (interpret-rv_i_insn cpu insn)
  (define op (rv_i_insn-op insn))
  (define rd (rv_i_insn-rd insn))
  (define rs1 (rv_i_insn-rs1 insn))
  (define imm12 (rv_i_insn-imm12 insn))
  (define size (insn-size insn))

  (case op

    ; Encoded as I-type instruction
    [(fence.i fence)
      (cpu-next! cpu size)]

    ; CSR reg
    [(csrrw csrrs csrrc)
      ; imm12 is really a csr name
      (do-csr-op cpu op rd imm12 (gpr-ref cpu rs1))
      (cpu-next! cpu size)]

    ; CSR imm
    [(csrrwi csrrsi csrrci)
      ; This is the most irregular encoding. Here rs1 is actually a 5-bit immediate
      ; and not an actual register name.
      ; In addition, imm12 is actually a CSR name and not an immediate.
      (check-imm-size 5 rs1)
      (do-csr-op cpu op rd imm12 (zero-extend rs1 (bitvector (XLEN))))
      (cpu-next! cpu size)]

    ; ALU immediate instructions
    [(addi subi ori andi xori srli srai slli)
      (check-imm-size 12 imm12)
      (gpr-set! cpu rd (evaluate-binary-op op (gpr-ref cpu rs1) (sign-extend imm12 (bitvector (XLEN)))))
      (cpu-next! cpu size)]

    ; Set if less than immediate (signed)
    [(slti)
      (check-imm-size 12 imm12)
      (gpr-set! cpu rd
        (if (bvslt (gpr-ref cpu rs1) (sign-extend imm12 (bitvector (XLEN))))
          (bv 1 (XLEN))
          (bv 0 (XLEN))))
      (cpu-next! cpu size)]

    ; Set if less than immediate unsigned
    [(sltiu)
      (check-imm-size 12 imm12)
      (gpr-set! cpu rd
        (if (bvult (gpr-ref cpu rs1) (sign-extend imm12 (bitvector (XLEN))))
          (bv 1 (XLEN))
          (bv 0 (XLEN))))
      (cpu-next! cpu size)]

    ; ADDIW is an RV64I-only instruction that adds the sign-extended 12-bit
    ; immediate to register rs1 and produces the proper sign-extension of a 32-bit
    ; result in rd. Overflows are ignored and the result is the low 32 bits of the
    ; result sign-extended to 64 bits. Note, ADDIW rd, rs1, 0 writes the
    ; sign-extension of the lower 32 bits of register rs1 into register rd
    [(addiw)
      (check-imm-size 12 imm12)
      (core:bug-on (! (= (XLEN) 64)) #:msg "addiw: (XLEN) != 64" #:dbg current-pc-debug)
      (gpr-set! cpu rd
        (sign-extend
          (bvadd (extract 31 0 (gpr-ref cpu rs1))
                 (sign-extend imm12 (bitvector 32)))
        (bitvector 64)))
      (cpu-next! cpu size)]

    [(slliw srliw sraiw)
      (check-imm-size 12 imm12)
      (core:bug-on (! (= (XLEN) 64)) #:msg "slliw/srliw/sraiw: (XLEN) != 64" #:dbg current-pc-debug)
      (gpr-set! cpu rd
        (sign-extend
          (evaluate-binary-op op
            (extract 31 0 (gpr-ref cpu rs1))
            (bvand (sign-extend imm12 (bitvector 32)) (bv #b11111 32)))
          (bitvector 64)))
      (cpu-next! cpu size)]

    [(ld ldu lw lwu lh lhu lb lbu)
      (check-imm-size 12 imm12)
      (define ptr (resolve-mem-path cpu insn))
      (define block (ptr-block ptr))
      (define path (ptr-path ptr))
      (define extend (if (load-signed? op) sign-extend zero-extend))
      (gpr-set! cpu rd (extend (core:mblock-iload block path) (bitvector (XLEN))))
      (cpu-next! cpu size)]

    ; The indirect jump instruction JALR (jump and link register) uses the I-type encoding.
    ; The target address is obtained by adding the sign-extended 12-bit I-immediate to the register
    ; rs1, then setting the least-significant bit of the result to zero. The address of the
    ; instruction following the jump (pc+4) is written to register rd.
    [(jalr)
      (check-imm-size 12 imm12)
      (gpr-set! cpu rd (bvadd (bv size (XLEN)) (cpu-pc cpu)))
      (define target
        (for/all ([src (gpr-ref cpu rs1) #:exhaustive])
          (bvand
            (bvnot (bv 1 (XLEN)))
            (bvadd src (sign-extend imm12 (bitvector (XLEN)))))))
      (set-cpu-pc! cpu target)]

    [else (core:bug #:msg (format "No such rv_i_insn: ~v" insn) #:dbg current-pc-debug)]))

(define (interpret-rv_r_insn cpu insn)
  (define op (rv_r_insn-op insn))
  (define rd (rv_r_insn-rd insn))
  (define rs1 (rv_r_insn-rs1 insn))
  (define rs2 (rv_r_insn-rs2 insn))
  (define size (insn-size insn))

  (case op

    ; wfi and sfence.vma are encoded as R-type instructions
    [(wfi sfence.vma)
      (cpu-next! cpu size)]

    ; Set if less than (signed)
    [(slt)
      (gpr-set! cpu rd
        (if (bvslt (gpr-ref cpu rs1) (gpr-ref cpu rs2))
          (bv 1 (XLEN))
          (bv 0 (XLEN))))
      (cpu-next! cpu size)]

    ; Set if less than unsigned
    [(sltu)
      (gpr-set! cpu rd
        (if (bvult (gpr-ref cpu rs1) (gpr-ref cpu rs2))
          (bv 1 (XLEN))
          (bv 0 (XLEN))))
      (cpu-next! cpu size)]

    ; Binary operation two registers
    [(add sub or and xor srl sra sll mul mulh mulhu mulhsu div rem divu remu)
      (gpr-set! cpu rd (evaluate-binary-op op (gpr-ref cpu rs1) (gpr-ref cpu rs2)))
      (cpu-next! cpu size)]

    ; Binary operation two registers (32-bit ops on 64-bit only)
    [(addw subw sllw srlw sraw mulw divw remw divuw remuw)
      (core:bug-on (! (= (XLEN) 64)) #:msg "*w: (XLEN) != 64" #:dbg current-pc-debug)
      (gpr-set! cpu rd (sign-extend (evaluate-binary-op op (extract 31 0 (gpr-ref cpu rs1)) (extract 31 0 (gpr-ref cpu rs2))) (bitvector 64)))
      (cpu-next! cpu size)]

    [else (core:bug #:msg (format "No such rv_r_insn: ~v" insn) #:dbg current-pc-debug)]

  ))

(define (interpret-rv_s_insn cpu insn)
  (define op (rv_s_insn-op insn))
  (define rs1 (rv_s_insn-rs1 insn))
  (define rs2 (rv_s_insn-rs2 insn))
  (define imm12 (rv_s_insn-imm12 insn))
  (define size (insn-size insn))

  (case op
    [(sd sw sh sb)
      (check-imm-size 12 imm12)
      (define ptr (resolve-mem-path cpu insn))
      (define block (ptr-block ptr))
      (define path (ptr-path ptr))
      (define value (extract (- (* 8 (memop->size op)) 1) 0 (gpr-ref cpu rs2)))
      (core:mblock-istore! block value path)
      (cpu-next! cpu size)]

    ; Binary conditional branch
    [(bge blt bgeu bltu bne beq)
      (check-imm-size 12 imm12)

      (define (simplify-condition expr)
        (match expr
          [(expression (== !)
              (expression (== bveq)
                (expression (== bvadd) C1 x)
                (expression (== bvadd) C2 y)))
          #:when (&& (! (term? C1))
                      (! (term? C2))
                      (! (bveq C1 C2)))
          (define newexpr (|| (bveq x y) (! (bveq (bvadd C1 x) (bvadd C2 y)))))
          (core:bug-on (! (equal? newexpr expr)))
          newexpr]
          [_ expr]))

      (if (simplify-condition (evaluate-binary-conditional op (gpr-ref cpu rs1) (gpr-ref cpu rs2)))
        (jump-and-link cpu 'x0 imm12 #:size size)
        (cpu-next! cpu size))]

    [else (core:bug #:msg (format "No such rv_s_insn: ~v" insn) #:dbg current-pc-debug)]
  ))

(define (interpret-rv_u_insn cpu insn)
  (define op (rv_u_insn-op insn))
  (define rd (rv_u_insn-rd insn))
  (define imm20 (rv_u_insn-imm20 insn))
  (define size (insn-size insn))

  (case op
    ; AUIPC appends 12 low-order zero bits to the 20-bit U-immediate, sign-extends
    ; the result to 64 bits, then adds it to the pc and places the result in register rd.
    [(auipc)
      (check-imm-size 20 imm20)
      (gpr-set! cpu rd (bvadd
                         (sign-extend (concat imm20 (bv 0 12)) (bitvector (XLEN)))
                         (cpu-pc cpu)))
      (cpu-next! cpu size)]

    ; LUI places the 20-bit U-immediate into bits 31–12 of register rd and places
    ; zero in the lowest 12 bits. The 32-bit result is sign-extended to 64 bits.
    [(lui)
      (check-imm-size 20 imm20)
      (gpr-set! cpu rd (sign-extend (concat imm20 (bv 0 12)) (bitvector (XLEN))))
      (cpu-next! cpu size)]

    ; The jump and link (JAL) instruction uses the J-type format, where the J-immediate encodes a
    ; signed offset in multiples of 2 bytes. The offset is sign-extended and added to the address of
    ; the jump instruction to form the jump target address.
    [(jal)
      (check-imm-size 20 imm20)
      (jump-and-link cpu rd imm20 #:size size)]

    [else (core:bug #:msg (format "No such rv_u_insn: ~v" insn) #:dbg current-pc-debug)]

  ))

; interpret one instr
(define (interpret-insn cpu insn)
  (cond
    [(rv_i_insn? insn) (interpret-rv_i_insn cpu insn)]
    [(rv_r_insn? insn) (interpret-rv_r_insn cpu insn)]
    [(rv_s_insn? insn) (interpret-rv_s_insn cpu insn)]
    [(rv_u_insn? insn) (interpret-rv_u_insn cpu insn)]
    [else (core:bug #:msg (format "interpret-insn: Unknown instruction type: ~v" insn)
                    #:dbg current-pc-debug)]))

(define (interpret-program cpu program)
  (define instructions (program-instructions program))
  (core:split-pc (cpu pc) cpu
    (define pc (cpu-pc cpu))
    (set-current-pc-debug! pc)
    (cond
      [(hash-has-key? (cpu-shims cpu) pc)
        ((hash-ref (cpu-shims cpu) pc) cpu)
        (interpret-program cpu program)]

      [(hash-has-key? instructions pc)
        (define insn (hash-ref instructions pc))
        (unless (and (rv_r_insn? insn) (or (equal? (rv_r_insn-op insn) 'mret) (equal? (rv_r_insn-op insn) 'sret)))
          (interpret-insn cpu (hash-ref instructions pc))
          (interpret-program cpu program))])))
