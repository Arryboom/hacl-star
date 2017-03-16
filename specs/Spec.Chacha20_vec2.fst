module Spec.Chacha20_vec2

open FStar.Mul
open FStar.Seq
open FStar.UInt32
open FStar.Endianness
open Spec.Lib

module U32 = FStar.UInt32
(* This should go elsewhere! *)

#set-options "--initial_fuel 0 --max_fuel 0 --initial_ifuel 0 --max_ifuel 0 --z3rlimit 100"

let keylen = 32 (* in bytes *)
let blocklen = 64  (* in bytes *)
let noncelen = 12 (* in bytes *)

type key = lbytes keylen
type block = lbytes blocklen
type nonce = lbytes noncelen
type counter = UInt.uint_t 32

// What we need to know about vectors:
type vec   = v:seq U32.t {length v = 8}
let to_vec (x:U32.t) : vec = create 8 x
type state = m:seq vec      {length m = 16}
type idx = n:nat{n < 16}
type shuffle = state -> Tot state 


// Vector size changes the blocksize and the counter step:
type vec_block = lbytes (8*blocklen)
unfold let counter_step:vec  = to_vec 8ul
unfold let initial_counter (c:counter) : vec = 
       let ctr = U32.uint_to_t c in
       let l = U32.([ctr; ctr +^ 1ul; ctr +^ 2ul; ctr +^ 3ul; ctr +^ 4ul; ctr +^ 5ul; ctr +^ 6ul; ctr +^ 7ul]) in
       assert_norm(List.Tot.length l = 8); 
       let s = createL l in
       s       
//Transposed state matrix
type stateT = m:seq (r:seq U32.t{length r = 16}){length m = 8}

//Chacha20 code begins

(* unfold *) let op_Plus_Percent_Hat (x:vec) (y:vec) : Tot vec = 
       C.Loops.seq_map2 U32.op_Plus_Percent_Hat x y

(* unfold  *)let op_Hat_Hat (x:vec) (y:vec) : Tot vec = 
       C.Loops.seq_map2 U32.op_Hat_Hat x y

(* unfold *) let op_Less_Less_Less (x:vec) (n:UInt32.t{v n < 32}) : Tot vec = 
       C.Loops.seq_map (fun x -> x <<< n) x 

val line: idx -> idx -> idx -> s:UInt32.t {v s < 32} -> shuffle
let line a b d s m = 
  let m = upd m a (index m a +%^ index m b) in
  let m = upd m d ((index m d ^^  index m a) <<< s) in
  m

let column_round : shuffle =
  line 0 4 12 16ul @
  line 1 5 13 16ul @
  line 2 6 14 16ul @
  line 3 7 15 16ul @

  line 8 12 4 12ul @
  line 9 13 5 12ul @
  line 10 14 6 12ul @
  line 11 15 7 12ul @

  line 0 4 12 8ul @
  line 1 5 13 8ul @
  line 2 6 14 8ul @
  line 3 7 15 8ul @

  line 8 12 4 7ul @
  line 9 13 5 7ul @
  line 10 14 6 7ul @
  line 11 15 7 7ul 

let diagonal_round : shuffle =
  line 0 5 15 16ul @
  line 1 6 12 16ul @
  line 2 7 13 16ul @
  line 3 4 14 16ul @

  line 10 15 5 12ul @
  line 11 12 6 12ul @
  line 8 13 7 12ul @
  line 9 14 4 12ul @

  line 0 5 15 8ul @
  line 1 6 12 8ul @
  line 2 7 13 8ul @
  line 3 4 14 8ul @

  line 10 15 5 7ul @
  line 11 12 6 7ul @
  line 8 13 7 7ul @
  line 9 14 4 7ul 

let double_round : shuffle =
  column_round @ diagonal_round

let rounds : shuffle = 
    iter 10 double_round (* 20 rounds *)

let chacha20_core (s:state) : Tot state = 
    let s' = rounds s in
    C.Loops.seq_map2 op_Plus_Percent_Hat s' s

(* state initialization *) 

unfold let constants : (s:seq U32.t{length s = 4}) = 
       let l = [0x61707865ul; 0x3320646eul; 0x79622d32ul; 0x6b206574ul] in
         assert_norm(List.Tot.length l = 4);
	 createL l	 

let setup (k:key) (n:nonce) (c:counter): Tot state =
  let constants:seq vec = C.Loops.seq_map to_vec constants in
  let key = C.Loops.seq_map to_vec (uint32s_from_le 8 k) in
  let nonce = C.Loops.seq_map to_vec (uint32s_from_le 3 n) in
  let ctr = create 1 (initial_counter c) in
  constants @| key @| ctr @| nonce

let column (s:state) (c:nat): (m:seq U32.t{length m = 16}) = 
  C.Loops.seq_map (fun r -> index r c) s
  
let transpose (s:state): Tot stateT =
    let cols = createL [0;1;2;3;4;5;6;7] in
    C.Loops.seq_map (column s) cols

let state_to_key (s:state): Tot vec_block =
    let k = transpose s in
    uint32s_to_le 16 (index k 0) @|
    uint32s_to_le 16 (index k 1) @|
    uint32s_to_le 16 (index k 2) @|
    uint32s_to_le 16 (index k 3) @|
    uint32s_to_le 16 (index k 4) @|
    uint32s_to_le 16 (index k 5) @|
    uint32s_to_le 16 (index k 6) @|
    uint32s_to_le 16 (index k 7) 


let chacha20_block (k:key) (n:nonce) (c:counter): Tot vec_block =
    let st = setup k n c in
    let st' = chacha20_core st in
    state_to_key st'    

let chacha20_ctx: Spec.CTR.block_cipher_ctx = 
    let open Spec.CTR in
    {
    keylen = keylen;
    blocklen = 8 * blocklen;
    noncelen = noncelen;
    counterbits = 32;
    incr = 8
    }

let chacha20_cipher: Spec.CTR.block_cipher chacha20_ctx = chacha20_block

let chacha20_encrypt_bytes key nonce counter m = 
    Spec.CTR.counter_mode chacha20_ctx chacha20_cipher key nonce counter m


unfold let test_plaintext = [
    0x4cuy; 0x61uy; 0x64uy; 0x69uy; 0x65uy; 0x73uy; 0x20uy; 0x61uy;
    0x6euy; 0x64uy; 0x20uy; 0x47uy; 0x65uy; 0x6euy; 0x74uy; 0x6cuy;
    0x65uy; 0x6duy; 0x65uy; 0x6euy; 0x20uy; 0x6fuy; 0x66uy; 0x20uy;
    0x74uy; 0x68uy; 0x65uy; 0x20uy; 0x63uy; 0x6cuy; 0x61uy; 0x73uy;
    0x73uy; 0x20uy; 0x6fuy; 0x66uy; 0x20uy; 0x27uy; 0x39uy; 0x39uy;
    0x3auy; 0x20uy; 0x49uy; 0x66uy; 0x20uy; 0x49uy; 0x20uy; 0x63uy;
    0x6fuy; 0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x6fuy; 0x66uy; 0x66uy;
    0x65uy; 0x72uy; 0x20uy; 0x79uy; 0x6fuy; 0x75uy; 0x20uy; 0x6fuy;
    0x6euy; 0x6cuy; 0x79uy; 0x20uy; 0x6fuy; 0x6euy; 0x65uy; 0x20uy;
    0x74uy; 0x69uy; 0x70uy; 0x20uy; 0x66uy; 0x6fuy; 0x72uy; 0x20uy;
    0x74uy; 0x68uy; 0x65uy; 0x20uy; 0x66uy; 0x75uy; 0x74uy; 0x75uy;
    0x72uy; 0x65uy; 0x2cuy; 0x20uy; 0x73uy; 0x75uy; 0x6euy; 0x73uy;
    0x63uy; 0x72uy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
    0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
    0x74uy; 0x2euy
]

unfold let test_plaintext2 = [ 
      0x4cuy; 0x61uy; 0x64uy; 0x69uy; 0x65uy; 0x73uy; 0x20uy; 0x61uy;
      0x6euy; 0x64uy; 0x20uy; 0x47uy; 0x65uy; 0x6euy; 0x74uy; 0x6cuy;
      0x65uy; 0x6duy; 0x65uy; 0x6euy; 0x20uy; 0x6fuy; 0x66uy; 0x20uy;
      0x74uy; 0x68uy; 0x65uy; 0x20uy; 0x63uy; 0x6cuy; 0x61uy; 0x73uy;
      0x73uy; 0x20uy; 0x6fuy; 0x66uy; 0x20uy; 0x27uy; 0x39uy; 0x39uy;
      0x3auy; 0x20uy; 0x49uy; 0x66uy; 0x20uy; 0x49uy; 0x20uy; 0x63uy;
      0x6fuy; 0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x6fuy; 0x66uy; 0x66uy;
      0x65uy; 0x72uy; 0x20uy; 0x79uy; 0x6fuy; 0x75uy; 0x20uy; 0x6fuy;
      0x6euy; 0x6cuy; 0x79uy; 0x20uy; 0x6fuy; 0x6euy; 0x65uy; 0x20uy;
      0x74uy; 0x69uy; 0x70uy; 0x20uy; 0x66uy; 0x6fuy; 0x72uy; 0x20uy;
      0x74uy; 0x68uy; 0x65uy; 0x20uy; 0x66uy; 0x75uy; 0x74uy; 0x75uy;
      0x72uy; 0x65uy; 0x2cuy; 0x20uy; 0x73uy; 0x75uy; 0x6euy; 0x73uy;
      0x63uy; 0x72uy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy; 0x65uy; 0x65uy; 0x6euy; 0x20uy; 0x77uy; 0x6fuy;
      0x75uy; 0x6cuy; 0x64uy; 0x20uy; 0x62uy; 0x65uy; 0x20uy; 0x69uy;
      0x74uy; 0x2euy ]

unfold let test_ciphertext = [
    0x6euy; 0x2euy; 0x35uy; 0x9auy; 0x25uy; 0x68uy; 0xf9uy; 0x80uy;
    0x41uy; 0xbauy; 0x07uy; 0x28uy; 0xdduy; 0x0duy; 0x69uy; 0x81uy;
    0xe9uy; 0x7euy; 0x7auy; 0xecuy; 0x1duy; 0x43uy; 0x60uy; 0xc2uy;
    0x0auy; 0x27uy; 0xafuy; 0xccuy; 0xfduy; 0x9fuy; 0xaeuy; 0x0buy;
    0xf9uy; 0x1buy; 0x65uy; 0xc5uy; 0x52uy; 0x47uy; 0x33uy; 0xabuy;
    0x8fuy; 0x59uy; 0x3duy; 0xabuy; 0xcduy; 0x62uy; 0xb3uy; 0x57uy;
    0x16uy; 0x39uy; 0xd6uy; 0x24uy; 0xe6uy; 0x51uy; 0x52uy; 0xabuy;
    0x8fuy; 0x53uy; 0x0cuy; 0x35uy; 0x9fuy; 0x08uy; 0x61uy; 0xd8uy;
    0x07uy; 0xcauy; 0x0duy; 0xbfuy; 0x50uy; 0x0duy; 0x6auy; 0x61uy;
    0x56uy; 0xa3uy; 0x8euy; 0x08uy; 0x8auy; 0x22uy; 0xb6uy; 0x5euy;
    0x52uy; 0xbcuy; 0x51uy; 0x4duy; 0x16uy; 0xccuy; 0xf8uy; 0x06uy;
    0x81uy; 0x8cuy; 0xe9uy; 0x1auy; 0xb7uy; 0x79uy; 0x37uy; 0x36uy;
    0x5auy; 0xf9uy; 0x0buy; 0xbfuy; 0x74uy; 0xa3uy; 0x5buy; 0xe6uy;
    0xb4uy; 0x0buy; 0x8euy; 0xeduy; 0xf2uy; 0x78uy; 0x5euy; 0x42uy;
    0x87uy; 0x4duy
]

unfold let test_ciphertext2 = [
	 0x6euy; 0x2euy; 0x35uy; 0x9auy; 0x25uy; 0x68uy; 0xf9uy;
	 0x80uy; 0x41uy; 0xbauy; 0x07uy; 0x28uy; 0xdduy; 0x0duy;
	 0x69uy; 0x81uy; 0xe9uy; 0x7euy; 0x7auy; 0xecuy; 0x1duy;
	 0x43uy; 0x60uy; 0xc2uy; 0x0auy; 0x27uy; 0xafuy; 0xccuy;
	 0xfduy; 0x9fuy; 0xaeuy; 0x0buy; 0xf9uy; 0x1buy; 0x65uy;
	 0xc5uy; 0x52uy; 0x47uy; 0x33uy; 0xabuy; 0x8fuy; 0x59uy;
	 0x3duy; 0xabuy; 0xcduy; 0x62uy; 0xb3uy; 0x57uy; 0x16uy;
	 0x39uy; 0xd6uy; 0x24uy; 0xe6uy; 0x51uy; 0x52uy; 0xabuy;
	 0x8fuy; 0x53uy; 0x0cuy; 0x35uy; 0x9fuy; 0x08uy; 0x61uy;
	 0xd8uy; 0x07uy; 0xcauy; 0x0duy; 0xbfuy; 0x50uy; 0x0duy;
	 0x6auy; 0x61uy; 0x56uy; 0xa3uy; 0x8euy; 0x08uy; 0x8auy;
	 0x22uy; 0xb6uy; 0x5euy; 0x52uy; 0xbcuy; 0x51uy; 0x4duy;
	 0x16uy; 0xccuy; 0xf8uy; 0x06uy; 0x81uy; 0x8cuy; 0xe9uy;
	 0x1auy; 0xb7uy; 0x79uy; 0x37uy; 0x36uy; 0x5auy; 0xf9uy;
	 0x0buy; 0xbfuy; 0x74uy; 0xa3uy; 0x5buy; 0xe6uy; 0xb4uy;
	 0x0buy; 0x8euy; 0xeduy; 0xf2uy; 0x78uy; 0x5euy; 0x42uy;
	 0x87uy; 0x4duy; 0x11uy; 0x66uy; 0x1duy; 0x00uy; 0x6duy;
	 0xceuy; 0xfduy; 0x97uy; 0xd8uy; 0xc8uy; 0x5buy; 0xf4uy;
	 0xe4uy; 0x84uy; 0xbcuy; 0xc3uy; 0x63uy; 0x29uy; 0x00uy;
	 0xb3uy; 0xeauy; 0x2fuy; 0x44uy; 0x19uy; 0x8auy; 0xc1uy;
	 0x25uy; 0x35uy; 0xd3uy; 0x8cuy; 0xdduy; 0x80uy; 0xeeuy;
	 0x23uy; 0xafuy; 0x6duy; 0xdauy; 0x25uy; 0xe3uy; 0x44uy;
	 0xaeuy; 0x8fuy; 0x64uy; 0x2fuy; 0x01uy; 0xb9uy; 0x7euy;
	 0x5cuy; 0x36uy; 0xc8uy; 0x96uy; 0xefuy; 0xf9uy; 0xdfuy;
	 0xeduy; 0x00uy; 0x5auy; 0x48uy; 0x10uy; 0xa3uy; 0xfeuy;
	 0x0cuy; 0x39uy; 0xaeuy; 0x13uy; 0xaeuy; 0xf4uy; 0x81uy;
	 0xebuy; 0x78uy; 0x34uy; 0x51uy; 0xe2uy; 0x9cuy; 0x6cuy;
	 0xb0uy; 0x4buy; 0x7auy; 0xdauy; 0xfduy; 0x90uy; 0x82uy;
	 0x94uy; 0xaduy; 0x7euy; 0x33uy; 0x45uy; 0x09uy; 0x23uy;
	 0x08uy; 0x57uy; 0x01uy; 0xecuy; 0xfauy; 0x15uy; 0xd1uy;
	 0x46uy; 0x20uy; 0x43uy; 0x97uy; 0xb1uy; 0x19uy; 0x10uy;
	 0x19uy; 0xe1uy; 0x80uy; 0x87uy; 0x14uy; 0x5buy; 0x68uy;
	 0xbduy; 0xa3uy; 0x58uy; 0x2buy; 0xeduy; 0xe7uy; 0xd1uy;
	 0xb4uy; 0xd9uy; 0x99uy; 0x40uy; 0xc0uy; 0xa6uy; 0xf7uy;
	 0x61uy; 0xc6uy; 0xf3uy; 0x25uy; 0x76uy; 0x16uy; 0x7buy;
	 0x85uy; 0x52uy; 0x16uy; 0x95uy; 0xbduy; 0x21uy; 0x5duy;
	 0x1buy; 0xc4uy; 0xeduy; 0x4fuy; 0xbfuy; 0x7fuy; 0xd0uy;
	 0xc7uy; 0x73uy; 0x9duy; 0x4fuy; 0x67uy; 0x99uy; 0x1buy;
	 0x35uy; 0xcbuy; 0xfbuy; 0x55uy; 0xf3uy; 0x31uy; 0x2buy;
	 0xefuy; 0x5fuy; 0xa2uy; 0xd9uy; 0x60uy; 0xc4uy; 0x62uy;
	 0x7duy; 0x6auy; 0x3euy; 0x2cuy; 0xb0uy; 0x24uy; 0x01uy;
	 0xc4uy; 0x45uy; 0x51uy; 0xd2uy; 0x27uy; 0xceuy; 0xc1uy;
	 0x2euy; 0x12uy; 0xe8uy; 0xa5uy; 0x71uy; 0x4fuy; 0x62uy;
	 0x8duy; 0x75uy; 0xccuy; 0xbduy; 0xfauy; 0xbduy; 0xd9uy;
	 0xaduy; 0x94uy; 0x57uy; 0x58uy; 0x57uy; 0x47uy; 0xdfuy;
	 0x8cuy; 0xafuy; 0xf7uy; 0x59uy; 0x54uy; 0xfduy; 0xd3uy;
	 0xb2uy; 0x55uy; 0x05uy; 0xa8uy; 0xb7uy; 0x02uy; 0x0euy;
	 0x87uy; 0x70uy; 0x24uy; 0x62uy; 0xf9uy; 0x70uy; 0xd2uy;
	 0x13uy; 0xcauy; 0x5cuy; 0xe9uy; 0x5auy; 0xb4uy; 0x05uy;
	 0x43uy; 0x92uy; 0x02uy; 0x14uy; 0xefuy; 0xfauy; 0x4euy;
	 0x25uy; 0x0auy; 0x4euy; 0x32uy; 0x73uy; 0xefuy; 0x88uy;
	 0x75uy; 0x55uy; 0x4cuy; 0xdcuy; 0xc9uy; 0x83uy; 0x99uy;
	 0x72uy; 0x73uy; 0xbfuy; 0xbauy; 0x6fuy; 0x4euy; 0x3duy;
	 0x7duy; 0x2duy; 0xc5uy; 0x9duy; 0xe0uy; 0xccuy; 0xcauy;
	 0x5buy; 0x1fuy; 0x0euy; 0x48uy; 0x34uy; 0x76uy; 0x6euy;
	 0xb5uy; 0xc7uy; 0xb1uy; 0xd5uy; 0x4euy; 0x03uy; 0xe1uy;
	 0x09uy; 0x4cuy; 0xeauy; 0x6duy; 0x0auy; 0x44uy; 0x02uy;
	 0xfduy; 0xfauy; 0x11uy; 0x08uy; 0x30uy; 0x56uy; 0x88uy;
	 0x90uy; 0xaauy; 0x38uy; 0xbbuy; 0x7fuy; 0x60uy; 0x2cuy;
	 0x90uy; 0x67uy; 0x89uy; 0xc3uy; 0xf5uy; 0x80uy; 0xc1uy;
	 0x79uy; 0x29uy; 0x61uy; 0xe7uy; 0x6duy; 0xc5uy; 0x29uy;
	 0x26uy; 0x7auy; 0x17uy; 0xa0uy; 0x54uy; 0x7auy; 0x24uy;
	 0xe5uy; 0x57uy; 0xa9uy; 0x30uy; 0xaauy; 0xa9uy; 0x44uy;
	 0x96uy; 0xf1uy; 0x69uy; 0xbduy; 0xc8uy; 0x61uy; 0x5fuy;
	 0xccuy; 0xa2uy; 0xffuy; 0xf1uy; 0x4fuy; 0xc3uy; 0xd0uy;
	 0xd3uy; 0x94uy; 0x07uy; 0x1buy; 0xacuy; 0x19uy; 0x6fuy;
	 0x0duy; 0x15uy; 0x55uy; 0x54uy; 0x7cuy; 0xe7uy; 0x19uy;
	 0xf2uy; 0x69uy; 0xf1uy; 0x81uy; 0xfauy; 0x06uy; 0xe4uy;
	 0x72uy; 0x1fuy; 0xffuy; 0xb1uy; 0x67uy; 0xacuy; 0xb2uy;
	 0xd6uy; 0x70uy; 0xbfuy; 0x00uy; 0x3cuy; 0x1duy; 0x9cuy;
	 0x5fuy; 0x36uy; 0xccuy; 0x5fuy; 0xbduy; 0xeauy; 0x31uy;
	 0xd3uy; 0xdduy; 0x36uy; 0xf8uy; 0x92uy; 0xcbuy; 0xbeuy;
	 0xc3uy; 0x60uy; 0x60uy; 0xfeuy; 0x48uy; 0x46uy; 0x56uy;
	 0xc9uy; 0x95uy; 0x10uy; 0x59uy; 0xfauy; 0x88uy; 0x2buy;
	 0xc6uy; 0x7euy; 0x3fuy; 0x67uy; 0x79uy; 0x47uy; 0x2auy;
	 0x75uy; 0x7fuy; 0x6euy; 0x84uy; 0x84uy; 0x2auy; 0x80uy;
	 0x19uy; 0x81uy; 0x99uy; 0x90uy; 0x07uy; 0xb7uy; 0x29uy;
	 0x44uy; 0xd4uy; 0xf3uy; 0xffuy; 0x01uy; 0xc8uy; 0xbcuy;
	 0x93uy; 0xe7uy; 0x26uy; 0xd7uy; 0xc3uy; 0x5euy; 0x48uy;
	 0x0cuy; 0xdauy; 0x95uy; 0x08uy; 0x54uy; 0xd6uy; 0x99uy;
	 0xf3uy; 0x88uy; 0xd7uy; 0x96uy; 0x0cuy; 0xabuy; 0x45uy;
	 0xd1uy; 0x2fuy; 0xffuy; 0xc0uy; 0x3fuy; 0x69uy; 0x94uy;
	 0x25uy; 0x90uy; 0xf7uy; 0xbcuy; 0xc1uy; 0xbfuy; 0x39uy;
	 0xf6uy; 0x17uy; 0xfbuy; 0x44uy; 0x28uy; 0x08uy; 0x3buy;
	 0xfauy; 0x38uy; 0x10uy; 0xa0uy; 0x55uy; 0xfauy; 0xa9uy;
	 0xffuy; 0x7buy; 0x83uy; 0x57uy; 0xc8uy; 0x33uy; 0xcauy;
	 0x7auy; 0x0auy; 0xa7uy; 0x0auy; 0xeduy; 0x18uy; 0xf4uy;
	 0x59uy; 0xc1uy; 0x73uy; 0x13uy; 0x12uy; 0x38uy; 0x7buy;
	 0x5euy; 0x48uy; 0x43uy; 0xe2uy; 0x8duy; 0x6euy; 0xfeuy;
	 0x98uy; 0x1auy; 0xb8uy; 0xe8uy; 0x70uy; 0xbeuy; 0xd1uy;
	 0x7fuy; 0x4buy; 0xa7uy; 0x37uy; 0xc9uy; 0x76uy; 0xb8uy;
	 0x39uy; 0xb0uy; 0xbduy; 0xceuy; 0x52uy; 0x3buy; 0xbbuy;
	 0x97uy; 0xa1uy; 0xd5uy; 0x05uy; 0x58uy; 0xb0uy; 0x65uy;
	 0x33uy; 0xe0uy; 0x10uy; 0x2buy; 0x64uy; 0x92uy; 0x03uy;
	 0xf2uy; 0x29uy; 0x75uy; 0xc7uy; 0x2fuy; 0x27uy; 0x2cuy;
	 0xe2uy; 0x78uy; 0x8duy; 0x26uy; 0xa2uy; 0x6euy; 0xa3uy;
	 0x8euy; 0xe2uy; 0xa1uy; 0xbeuy; 0xccuy; 0xacuy; 0x28uy;
	 0xbeuy; 0xd1uy; 0x14uy; 0x4auy; 0x6fuy; 0x73uy; 0x50uy;
	 0x5buy; 0xb8uy; 0x2fuy; 0x4fuy; 0xd0uy; 0xdduy; 0x70uy;
	 0xe5uy; 0xa3uy; 0x88uy; 0x9auy; 0xdauy; 0xffuy; 0xeeuy;
	 0xdfuy; 0x94uy; 0xeeuy; 0xa5uy; 0xc3uy; 0x83uy; 0x4auy;
	 0xfcuy; 0x01uy; 0x0buy; 0x44uy; 0x7buy; 0xa9uy; 0x3buy;
	 0xe9uy; 0xa3uy; 0x5auy; 0xe3uy; 0x98uy; 0xeauy; 0x34uy;
	 0xccuy; 0xc4uy; 0xa4uy; 0xe9uy; 0xc6uy; 0xeauy; 0xb1uy;
	 0xdfuy; 0xa2uy; 0x60uy; 0x8cuy; 0x17uy; 0x59uy; 0x47uy;
	 0x45uy; 0x32uy; 0x05uy; 0x41uy; 0xf4uy; 0x8buy; 0x34uy;
	 0x86uy; 0xaduy; 0x9buy; 0x3duy; 0xb2uy; 0x57uy; 0xe2uy;
	 0xbeuy; 0x55uy; 0xbfuy; 0xe5uy; 0x82uy ]

unfold let test_key = [ 
       0uy; 1uy; 2uy; 3uy; 4uy; 5uy; 6uy; 7uy; 8uy; 9uy; 10uy; 11uy;
       12uy; 13uy; 14uy; 15uy; 16uy; 17uy; 18uy; 19uy; 20uy; 21uy;
       22uy; 23uy; 24uy; 25uy; 26uy; 27uy; 28uy; 29uy; 30uy; 31uy ]
       
unfold let test_nonce = [ 
       0uy; 0uy; 0uy; 0uy; 0uy; 0uy; 0uy; 0x4auy; 0uy; 0uy; 0uy; 0uy ]

unfold let test_counter = 1

let test() =
  assert_norm(List.Tot.length test_plaintext = 114);
  assert_norm(List.Tot.length test_ciphertext = 114);
  assert_norm(List.Tot.length test_plaintext2 = 754);
  assert_norm(List.Tot.length test_ciphertext2 = 654);
  assert_norm(List.Tot.length test_key = 32);
  assert_norm(List.Tot.length test_nonce = 12);
  let test_plaintext = createL test_plaintext in
  let test_ciphertext = createL test_ciphertext in
  let test_plaintext2 = createL test_plaintext2 in
  let test_ciphertext2 = createL test_ciphertext2 in
  let test_key = createL test_key in
  let test_nonce = createL test_nonce in
  chacha20_encrypt_bytes test_key test_nonce test_counter test_plaintext
  = test_ciphertext &&
  chacha20_encrypt_bytes test_key test_nonce test_counter test_plaintext2
  = test_ciphertext2

