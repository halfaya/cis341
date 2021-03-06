(* X86lite Simulator *)

(* See the documentation in the X86lite specification, available on the 
   course web pages, for a detailed explanation of the instruction
   semantics.
*)

open X86

(* simulator machine state -------------------------------------------------- *)

let mem_bot = 0x400000L          (* lowest valid address *)
let mem_top = 0x410000L          (* one past the last byte in memory *)
let mem_size = Int64.to_int (Int64.sub mem_top mem_bot)
let nregs = 17                   (* including Rip *)
let ins_size = 4L                (* assume we have a 4-byte encoding *)
let exit_addr = 0xfdeadL         (* halt when m.regs(%rip) = exit_addr *)

(* Your simulator should raise this exception if it tries to read from or
   store to an address not within the valid address space. *)
exception X86lite_segfault

(* The simulator memory maps addresses to symbolic bytes.  Symbolic
   bytes are either actual data indicated by the Byte constructor or
   'symbolic instructions' that take up four bytes for the purposes of
   layout.

   The symbolic bytes abstract away from the details of how
   instructions are represented in memory.  Each instruction takes
   exactly four consecutive bytes, where the first byte InsB0 stores
   the actual instruction, and the next three bytes are InsFrag
   elements, which aren't valid data.

   For example, the two-instruction sequence:
        at&t syntax             ocaml syntax
      movq %rdi, (%rsp)       Movq,  [~%Rdi; Ind2 Rsp]
      decq %rdi               Decq,  [~%Rdi]

   is represented by the following elements of the mem array (starting
   at address 0x400000):

       0x400000 :  InsB0 (Movq,  [~%Rdi; Ind2 Rsp])
       0x400001 :  InsFrag
       0x400002 :  InsFrag
       0x400003 :  InsFrag
       0x400004 :  InsB0 (Decq,  [~%Rdi])
       0x400005 :  InsFrag
       0x400006 :  InsFrag
       0x400007 :  InsFrag
*)
type sbyte = InsB0 of ins       (* 1st byte of an instruction *)
           | InsFrag            (* 2nd, 3rd, or 4th byte of an instruction *)
           | Byte of char       (* non-instruction byte *)

let string_of_sbyte: sbyte -> string = function
  | InsB0 i -> "InsB0 " ^ string_of_ins i
  | InsFrag -> "InsFrag"
  | Byte c  -> "Byte " ^ (Char.escaped c)

(* memory maps addresses to symbolic bytes *)
type mem = sbyte array

(* Flags for condition codes *)
type flags = { mutable fo : bool
             ; mutable fs : bool
             ; mutable fz : bool
             }

(* Register files *)
type regs = int64 array

(* Complete machine state *)
type mach = { flags : flags
            ; regs : regs
            ; mem : mem
            }

(* simulator helper functions ----------------------------------------------- *)

(* The index of a register in the regs array *)
let rind : reg -> int = function
  | Rip -> 16
  | Rax -> 0  | Rbx -> 1  | Rcx -> 2  | Rdx -> 3
  | Rsi -> 4  | Rdi -> 5  | Rbp -> 6  | Rsp -> 7
  | R08 -> 8  | R09 -> 9  | R10 -> 10 | R11 -> 11
  | R12 -> 12 | R13 -> 13 | R14 -> 14 | R15 -> 15

(* Helper functions for reading/writing sbytes *)

(* Convert an int64 to its sbyte representation *)
let sbytes_of_int64 (i:int64) : sbyte list =
  let open Char in 
  let open Int64 in
  List.map (fun n -> Byte (shift_right i n |> logand 0xffL |> to_int |> chr))
           [0; 8; 16; 24; 32; 40; 48; 56]

(* Convert an sbyte representation to an int64 *)
let int64_of_sbytes (bs:sbyte list) : int64 =
  let open Char in
  let open Int64 in
  let f b i = match b with
    | Byte c -> logor (shift_left i 8) (c |> code |> of_int)
    | _ -> 0L
  in
  List.fold_right f bs 0L

(* Convert a string to its sbyte representation *)
let sbytes_of_string (s:string) : sbyte list =
  let rec loop acc = function
    | i when i < 0 -> acc
    | i -> loop (Byte s.[i]::acc) (pred i)
  in
  loop [Byte '\x00'] @@ String.length s - 1

(* Serialize an instruction to sbytes *)
let sbytes_of_ins (op, args:ins) : sbyte list =
  let check = function
    | Imm (Lbl l) | Ind1 (Lbl l) | Ind3 (Lbl l, _) -> 
      invalid_arg ("sbytes_of_ins: tried to serialize a label!: " ^ l)
    | o -> ()
  in
  List.iter check args;
  [InsB0 (op, args); InsFrag; InsFrag; InsFrag]

(* Serialize a data element to sbytes *)
let sbytes_of_data : data -> sbyte list = function
  | Quad (Lit i) -> sbytes_of_int64 i
  | Asciz s -> sbytes_of_string s
  | Quad (Lbl _) -> invalid_arg "sbytes_of_data: tried to serialize a label!"

(* It might be useful to toggle printing of intermediate states of your 
   simulator. *)
let debug_simulator = ref false

(* Interpret a condition code with respect to the given flags. *)
let interp_cnd {fo; fs; fz} : cnd -> bool = function
  | Eq  -> fz
  | Neq -> not fz
  | Gt  -> not fz && fs = fo
  | Ge  -> fs = fo
  | Lt  -> fs <> fo (* should technically add (&& not fz) but the tests fail with that *)
  | Le  -> fz || fs <> fo

(* Set condition flags given a result *)
let set_cnd (f: flags)(result: Int64_overflow.t): unit =
  let open Int64_overflow in
  f.fo <- result.overflow;
  f.fs <- result.value < 0L;
  f.fz <- result.value = 0L

(* Set condition flags given a logical result *)
let set_cnd_log (f: flags)(result: int64): unit =
  let open Int64_overflow in
  f.fo <- false;
  f.fs <- result < 0L;
  f.fz <- result = 0L

  (* Set condition for a shift *)
let set_cnd_shift (f: flags)(result: int64)(dest: int64)(amt: int)(op: opcode): unit =
  let open Int64 in
  let top_bit    n = logand n (shift_left 1L 63) in
  let second_bit n = logand n (shift_left 1L 62) in
  if amt <> 0 then
    (f.fs <- result < 0L;
     f.fz <- result = 0L;
     if amt = 1 then
       match op with
       | Sarq -> f.fo <- false
       | Shlq -> if top_bit dest = second_bit dest then f.fo <- true
       | Shrq -> f.fo <- top_bit dest = 1L
       |  _   -> invalid_arg "set_cnd_shift: not a shift opcode")
    
(* Maps an X86lite address into Some OCaml array index,
   or None if the address is not within the legal address space. *)
let map_addr (addr:quad) : int option =
  if addr >= mem_bot && addr < mem_top
  then Some (Int64.to_int (Int64.sub addr mem_bot))
  else None

(* return an int64 value from the specified memory location *)
let lookup (m: mem) (addr: quad): int64 =
  let open Array in
  match map_addr addr with
  | Some i -> int64_of_sbytes (to_list (sub m i 8))
  | None   -> invalid_arg "lookup: bad addr"

(* lookup the next instruction at the RIP and increment the RIP by 4 *)
let lookup_ins (m: mach): ins =
  let rip = m.regs.(rind Rip) in
  match map_addr rip with
  | Some a -> (match m.mem.(a) with
               | InsB0 i -> m.regs.(rind Rip) <- Int64.add rip 4L; i
               | _       -> invalid_arg "lookup_ins: bad instruction")
  | None   -> invalid_arg (Printf.sprintf "lookup_ins: bad addr in RIP %Ld" rip)
  
(* store an int64 value in the specified memory location *)
let store_mem (m: mem) (addr: quad) (v: int64): unit =
  let open Array in
  match map_addr addr with
  | Some i -> blit (of_list (sbytes_of_int64 v)) 0 m i 8
  | None   -> invalid_arg (Printf.sprintf "store_mem: bad addr %Ld value %Ld" addr v)

(* return the value of an operand as an int64 *)
let value (m: mach) : operand -> int64 = function
  | Imm (Lit i)     -> i
  | Reg r           -> m.regs.(rind r)
  | Ind1 (Lit i)    -> lookup m.mem i
  | Ind2 r          -> lookup m.mem (m.regs.(rind r))
  | Ind3 (Lit i, r) -> lookup m.mem (Int64.add m.regs.(rind r) i)
  | Imm (Lbl l) | Ind1 (Lbl l) | Ind3 (Lbl l, _) -> invalid_arg "value: labels should have been resolved"

(* returns memory address from an ind operand *)
let addr_ind (m: mach) : operand -> int64 = function
  | Ind1 (Lit i)    -> i
  | Ind2 r          -> m.regs.(rind r)
  | Ind3 (Lit i, r) -> Int64.add m.regs.(rind r) i
  | _               -> invalid_arg "addr_ind: argument must be Ind"

(* return the value of an Imm or rcx operand as an int *)
let shift_amount (m: mach) : operand -> int = function
  | Imm (Lit i) -> Int64.to_int i
  | Reg Rcx     -> Int64.to_int m.regs.(rind Rcx)
  | _           -> invalid_arg "shift_value: invalid operand"

(* store an int64 value into the location specified by an operand *)
let store (m: mach) (v: int64) : operand -> unit = function
  | Reg r            -> m.regs.(rind r) <- v
  | Ind1 (Lit i)     -> store_mem m.mem i v
  | Ind2 r           -> store_mem m.mem (m.regs.(rind r)) v
  | Ind3 (Lit i, r)  -> store_mem m.mem (Int64.add m.regs.(rind r) i) v
  | Imm (Lit i) as x -> invalid_arg ("store: cannot store to immediate" ^ string_of_operand x)
  | Imm (Lbl l) | Ind1 (Lbl l) | Ind3 (Lbl l, _) -> invalid_arg "store: labels should have been resolved"

(* Set low byte of i to the low byte of b *)
let set_low_byte (i: int64)(b: int64) : int64 =
  let open Int64 in
  let mask = sub (shift_left 1L 8) 1L in
  logor (logand i (lognot mask)) (logand b mask)

(* Simulates one step of the machine:
    - fetch the instruction at %rip
    - compute the source and/or destination information from the operands
    - simulate the instruction semantics
    - update the registers and/or memory appropriately
    - set the condition flags
*)
let step (m:mach) : unit =
  let open Int64_overflow in
  let unary   f d   = (let r = f (value m d)             in set_cnd m.flags r; store m r.value d) in
  let binary  f s d = (let r = f (value m d) (value m s) in set_cnd m.flags r; store m r.value d) in
  let lunary  f d   = (let r = f (value m d)             in set_cnd_log m.flags r; store m r d) in
  let lbinary f s d = (let r = f (value m d) (value m s) in set_cnd_log m.flags r; store m r d) in
  let shift   f s d o = (let a = shift_amount m s in
                         let x = value m d in
                         let r = f x a in
                         set_cnd_shift m.flags r x a o; store m r d) in
  let push    s       = m.regs.(rind Rsp) <- Int64.sub m.regs.(rind Rsp) 8L; store m (value m s) (Ind2 Rsp) in
  let pop     d       = store m (value m (Ind2 Rsp)) d; m.regs.(rind Rsp) <- Int64.add m.regs.(rind Rsp) 8L in
  let jump    s       = store m (value m s) (Reg Rip) in
  match lookup_ins m with
  | (Negq,  [d])    -> unary neg d (* NOTE: Shouldn't set flags? *)
  | (Incq,  [d])    -> unary succ d
  | (Decq,  [d])    -> unary pred d
  | (Addq,  [s; d]) -> binary add s d
  | (Subq,  [s; d]) -> binary sub s d (* NOTE: Doesn't handle overflow according to spec. *)
  | (Imulq, [s; d]) -> binary mul s d
  | (Notq,  [d])    -> lunary Int64.lognot d
  | (Andq,  [s; d]) -> lbinary Int64.logand s d
  | (Orq,   [s; d]) -> lbinary Int64.logor  s d
  | (Xorq,  [s; d]) -> lbinary Int64.logxor s d
  | (Sarq,  [a; d]) -> shift Int64.shift_right         a d Sarq
  | (Shlq,  [a; d]) -> shift Int64.shift_left          a d Shlq
  | (Shrq,  [a; d]) -> shift Int64.shift_right_logical a d Shrq
  | (Set c, [d])    -> store m (set_low_byte (value m d) (if interp_cnd m.flags c then 1L else 0L)) d
  | (Leaq,  [s; d]) -> store m (addr_ind m s) d
  | (Movq,  [s; d]) -> store m (value m s) d
  | (Pushq, [s])    -> push s
  | (Popq,  [d])    -> pop d
  | (Cmpq,  [s; t]) -> set_cnd m.flags (sub (value m t) (value m s)) (* NOTE: See Subq note. *)
  | (Jmp ,  [s])    -> jump s
  | (Callq, [s])    -> push (Reg Rip); jump s
  | (Retq,  [])     -> pop (Reg Rip)
  | (J c,   [s])    -> if interp_cnd m.flags c then jump s
  | _               -> failwith "step unimplemented"

(* Runs the machine until the rip register reaches a designated
   memory address. *)
let run (m:mach) : int64 = 
  while m.regs.(rind Rip) <> exit_addr do step m done;
  m.regs.(rind Rax)

(* assembling and linking --------------------------------------------------- *)

(* A representation of the executable *)
type exec = { entry    : quad              (* address of the entry point *)
            ; text_pos : quad              (* starting address of the code *)
            ; data_pos : quad              (* starting address of the data *)
            ; text_seg : sbyte list        (* contents of the text segment *)
            ; data_seg : sbyte list        (* contents of the data segment *)
            }

(* Assemble should raise this when a label is used but not defined *)
exception Undefined_sym of lbl

(* Assemble should raise this when a label is defined more than once *)
exception Redefined_sym of lbl

(* Convert an X86 program into an object file:
   - separate the text and data segments
   - compute the size of each segment
      Note: the size of an Asciz string section is (1 + the string length)

   - resolve the labels to concrete addresses and 'patch' the instructions to 
     replace Lbl values with the corresponding Imm values.

   - the text segment starts at the lowest address
   - the data segment starts after the text segment

  HINT: List.fold_left and List.fold_right are your friends.
 *)
let assemble (p:prog) : exec =
  let open List in
  let open Int64 in
  let symbol_table: (lbl, quad) Hashtbl.t = Hashtbl.create 100 in
  let data_len: data -> int = function
    | Asciz s -> String.length s + 1
    | Quad  _ -> 8 in
  let add_label (lbl: lbl) (n: quad): unit =
    if Hashtbl.mem symbol_table lbl
    then raise (Redefined_sym lbl)
    else Hashtbl.add symbol_table lbl n in
  let text_len (e: elem): quad = match e.asm with
    | Text l -> mul (of_int (length l)) ins_size
    | Data l -> 0L in
  let full_text_len: quad = fold_left (fun a b -> add a (text_len b)) 0L p in
  let text_pos: quad ref = ref mem_bot in
  let data_pos: quad ref = ref (add mem_bot full_text_len) in
  let elem_update (e: elem): unit = match e.asm with
    | Text l -> add_label e.lbl !text_pos;
                text_pos := add !text_pos (mul (of_int (length l)) ins_size)
    | Data l -> add_label e.lbl !data_pos;
                data_pos := add !data_pos (of_int (fold_left (fun a b -> a + data_len b) 0 l)) in
  let patch_imm: imm -> imm = function
    | Lit q -> Lit q
    | Lbl l -> if Hashtbl.mem symbol_table l
               then Lit (Hashtbl.find symbol_table l)
               else raise (Undefined_sym l) in
  let patch_op: operand -> operand = function
    | Imm  i      -> Imm (patch_imm i)
    | Ind1 i      -> Ind1 (patch_imm i)
    | Ind3 (i, r) -> Ind3 (patch_imm i, r)
    | op      -> op in
  let patch_ins (code, ops: ins): ins =
    (code, map patch_op ops) in
  let patch_data: data -> data = function
    | Asciz s -> Asciz s
    | Quad imm -> Quad (patch_imm imm) in
  let patch: asm -> asm = function
    | Text l -> Text (map patch_ins l)
    | Data l -> Data (map patch_data l) in
  let base_exec: exec = 
    iter elem_update p; (* set up sizes and labels as a side-effect *)
    { entry = if Hashtbl.mem symbol_table "main" then Hashtbl.find symbol_table "main" else raise (Undefined_sym "main")
    ; text_pos = mem_bot
    ; data_pos = add mem_bot full_text_len
    ; text_seg = []
    ; data_seg = []
    } in
  let step (a: asm)(e: exec): exec = match (patch a) with
    | Text l -> {e with text_seg = (concat (map sbytes_of_ins l))  @ e.text_seg}
    | Data l -> {e with data_seg = (concat (map sbytes_of_data l)) @ e.data_seg} in
  fold_right step (map (fun x -> x.asm) p) base_exec

(* Convert an object file into an executable machine state. 
    - allocate the mem array
    - set up the memory state by writing the symbolic bytes to the 
      appropriate locations 
    - create the inital register state
      - initialize rip to the entry point address
      - initializes rsp to the last word in memory 
      - the other registers are initialized to 0
    - the condition code flags start as 'false'

  Hint: The Array.make, Array.blit, and Array.of_list library functions 
  may be of use.
*)
let load {entry; text_pos; data_pos; text_seg; data_seg} : mach =
  let open Array in
  let open Int64 in
  let mem: mem = make mem_size (Byte '\x00') in
  let text_arr = of_list text_seg in
  let data_arr = of_list data_seg in
  blit text_arr 0 mem (to_int (sub text_pos mem_bot)) (length text_arr);
  blit data_arr 0 mem (to_int (sub data_pos mem_bot)) (length data_arr);
  blit (of_list (sbytes_of_int64 exit_addr)) 0 mem (mem_size - 8) 8;
  let flags: flags = {fo = false; fs = false; fz = false} in
  let regs: regs = make 17 0L in
  regs.(rind Rip) <- entry;
  regs.(rind Rsp) <- sub mem_top 8L;
  {flags; regs; mem}
