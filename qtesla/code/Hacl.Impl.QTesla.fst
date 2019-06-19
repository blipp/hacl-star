module Hacl.Impl.QTesla

open FStar.HyperStack
open FStar.HyperStack.ST
open FStar.Mul

module I = FStar.Int
module I8 = FStar.Int8
module I16 = FStar.Int16
module I32 = FStar.Int32
module I64 = FStar.Int64
module UI8 = FStar.UInt8
module UI16 = FStar.UInt16
module UI32 = FStar.UInt32
module UI64 = FStar.UInt64
open FStar.Int.Cast

//open LowStar.BufferOps
open LowStar.Buffer

open Lib.IntTypes
open Lib.Buffer
open Lib.ByteBuffer

open C.Loops
module LL = Lib.Loops

open Hacl.Impl.QTesla.Params
open Hacl.Impl.QTesla.Platform
open Hacl.Impl.QTesla.Constants
open Hacl.Impl.QTesla.Globals
open Hacl.Impl.QTesla.Pack
open Hacl.Impl.QTesla.Poly
open Hacl.Impl.QTesla.Gauss
open Hacl.Impl.QTesla.Lemmas

module B  = LowStar.Buffer
module ST = FStar.HyperStack.ST
module HS = FStar.HyperStack

module Seq = FStar.Seq
module LibSeq = Lib.Sequence

module SHA3 = Hacl.SHA3
//module S    = Spec.QTesla

module R    = Hacl.QTesla.Random

#reset-options "--z3rlimit 100 --max_fuel 1 --max_ifuel 1"

private let _RADIX32 = size params_radix32

(*private let lemma_abs_by_mask (mask:I32.t{mask == 0l \/ mask == (-1l)}) (value:I32.t) : Lemma
    (requires FStar.Int.fits (I32.v (I32.(mask ^^ value)) - I32.v mask) I32.n /\
              ((mask == 0l) <==> (I32.v value >= 0)) /\
              ((mask == (-1l)) <==> (I32.v value < 0)))
    (ensures I32.v I32.((mask ^^ value) -^ mask) == FStar.Math.Lib.abs (I32.v value)) = 
    [@inline_let] let op_Plus_Hat = I32.op_Plus_Hat in
    [@inline_let] let op_Subtraction_Hat = I32.op_Subtraction_Hat in
    [@inline_let] let op_Greater_Greater_Hat = I32.op_Greater_Greater_Hat in
    [@inline_let] let op_Amp_Hat = I32.op_Amp_Hat in
    [@inline_let] let op_Bar_Hat = I32.op_Bar_Hat in
    [@inline_let] let op_Star_Hat = I32.op_Star_Hat in
    [@inline_let] let lognot = I32.lognot in  
    lemma_int32_logxor_identities value;
    Int.logxor_commutative (I32.v mask) (I32.v value);
    assert((mask == 0l) ==> ( (mask ^^ value) == value ));
    assert((mask == 0l) ==> ( value -^ mask == value ));
    assert((mask == (-1l)) ==> ( (mask ^^ value) == (-1l) *^ value -^ 1l ));
    assert((mask == (-1l)) ==> ( ((-1l) *^ value -^ 1l) -^ mask == (-1l) *^ value ))*)

    //assume(mask == 0l \/ mask == (-1l));
    //assume(FStar.Int.fits (elem_v (mask ^^ value) - elem_v mask) I32.n);
    // Proof sketch:
    // If value >= 0: |value| == value
    // 1. mask == 0
    // 2. mask ^ value == value
    // 3. (mask ^ value) - mask == value - mask == value - 0 == value
    // 4. value == |value|
    // If value < 0: |value| == -value
    // 1. mask == -1
    // 2. mask ^ value == |value| - 1 (definition of signed bitwise XOR)
    // 3. (mask ^ value) - mask == |value| - 1 - mask == |value| - 1 - (-1) == |value|
    // 4. |value|

// Reference implementation returns the unsigned version of the element type. Not sure yet whether or not
// it's important to do this. In one case the return value is compared against a quantity that isn't even close
// to exceeding the maximum value of a signed int32, much less an int64, and in all other cases ends up getting
// immediately cast back into a signed type.
val abs_: value: I32.t{Int.min_int I32.n < I32.v value} -> Tot (x:I32.t{I32.v x == FStar.Math.Lib.abs (I32.v value)})
let abs_ value = I32.ct_abs value
(*    assert_norm(v (_RADIX32 -. size 1) < I32.n);
    let mask = I32.(value >>^ (_RADIX32 -. size 1)) in
    lemma_int32_sar_n_minus_1 value;
    assert_norm(I32.n - 1 == v (_RADIX32 -. size 1));
    //assert((I32.v value >= 0) ==> (I32.v mask == 0));
    assert((I32.v value >= 0) ==> (mask == 0l));
    assert((I32.v value < 0) ==> (mask == (-1l)));
    lemma_abs_by_mask mask value;
    I32.((mask ^^ value) -^ mask)*)

private unfold let check_ES_list_bound (h:HS.mem) (list: lbuffer I32.t params_n) (i:nat{i < v params_n}) =
    let e = I32.v (bget h list i) in e >= 0 /\ e <= pow2 (v params_s_bits - 1) 

// {:pattern check_ES_list_bound h list i}
private unfold let check_ES_list_bound_buffer (h:HS.mem) (list: lbuffer I32.t params_n) =
    forall i. check_ES_list_bound h list i

// Shamelessly copied from FStar.Int32.ct_abs
private let lemma_mask (a:I32.t) (mask:I32.t) : Lemma
    (requires mask == I32.(a >>>^ UInt32.uint_to_t (n - 1)))
    (ensures ((0 <= I32.v a) ==> (mask == 0l)) /\
             ((0 > I32.v a) ==> (mask == (-1l)))) =
      let v = I32.v in
      if 0 <= v a then
        begin
        Int.sign_bit_positive (v a);
        Int.nth_lemma (v mask) (Int.zero _);
        Int.logxor_lemma_1 (v a)
        end
      else
        begin
        Int.sign_bit_negative (v a);
        Int.nth_lemma (v mask) (Int.ones _);
        Int.logxor_lemma_2 (v a);
        Int.lognot_negative (v a);
        UInt.lemma_lognot_value #I32.n (Int.to_uint (v a))
        end
    

private inline_for_extraction noextract
let check_ES_ordered_exchange_ct (list: lbuffer I32.t params_n) (i: size_t{v i + 1 < v params_n}) : Stack unit
    (requires fun h -> live h list /\ check_ES_list_bound_buffer h list)
    (ensures fun h0 _ h1 -> modifies1 list h0 h1 /\ check_ES_list_bound_buffer h1 list /\
                         I32.v (bget h1 list (v i)) <= I32.v (bget h1 list (v i + 1))) =

    [@inline_let] let op_Plus_Hat = I32.op_Plus_Hat in
    [@inline_let] let op_Subtraction_Hat = I32.op_Subtraction_Hat in
    [@inline_let] let op_Greater_Greater_Hat = I32.op_Greater_Greater_Hat in
    [@inline_let] let op_Greater_Greater_Greater_Hat = I32.op_Greater_Greater_Greater_Hat in
    [@inline_let] let op_Amp_Hat = I32.op_Amp_Hat in
    [@inline_let] let op_Bar_Hat = I32.op_Bar_Hat in
    [@inline_let] let lognot = I32.lognot in
    let h3 = ST.get () in
    assert_norm(v (_RADIX32 -. size 1) < I32.n);
    assert(check_ES_list_bound h3 list (v i));
    assert(check_ES_list_bound h3 list (v i + 1));
    // If list[i+1] < list[i] then exchange contents
    // Proof sketch:
    // If list[i+1] < list[i]:
    // 1. list[i+1]-list[i] is negative
    // 2. mask <- list[i+1]-list[i] >> 31 == -1 (0xFFFFFFFF)
    // 3. ~mask == 0
    // 4a. list[i+1] & mask == list[i+1]
    // 4b. list[i] & ~mask = 0
    // 4c. temp <- list[i+1] & mask | list[i] & ~mask == list[i+1] | 0 == list[i+1]
    // 5a. list[i] & mask == list[i]
    // 5b. list[i+1] & ~mask == 0
    // 5c. list[i+1] <- list[i] & mask | list[i+1] & ~mask == list[i] | 0 == list[i]
    // 6. list[i] <- temp == list[i+1] (previous value)
    // 
    // Similarly for list[i+1] >= list[i], mask is 0, and so the quantities ANDed with ~mask instead survive
    // and each element is reassigned its own value and nothing changes.
    let a = ((list.(i +. size 1)) -^ (list.(i))) in
    let mask = a >>>^ (_RADIX32 -. size 1) in
    lemma_mask a mask;  
    let temp = ((list.(i +. size 1)) &^ mask) |^
                          ((list.(i)) &^ (lognot mask)) in
    list.(i +. size 1) <- (list.(i)) &^ mask |^
                         (list.(i +. (size 1))) &^ (lognot mask);
    list.(i) <- temp;
    let h3end = ST.get () in
    assert(mask == 0l \/ mask == (-1l));
    assert(I32.v mask == Int.zero I32.n \/ I32.v mask == Int.ones I32.n);
    FStar.Int.logand_lemma_1 (I32.v (bget h3 list (v i)));
    FStar.Int.logand_lemma_1 (I32.v (bget h3 list (v i + 1)));
    FStar.Int.logand_lemma_2 (I32.v (bget h3 list (v i)));
    FStar.Int.logand_lemma_2 (I32.v (bget h3 list (v i + 1)));
    lemma_int32_logor_zero (bget h3 list (v i));
    lemma_int32_logor_zero (bget h3 list (v i + 1));
    assert(I32.v (bget h3 list (v i)) <= I32.v (bget h3 list (v i + 1)) ==> (mask == 0l));
    assert(I32.v (bget h3 list (v i)) > I32.v (bget h3 list (v i + 1)) ==> (mask == (-1l)));
    lemma_int32_lognot_zero mask;
    assert((mask == 0l) ==> (lognot mask == (-1l)));
    assert((mask == (-1l)) ==> (lognot mask == 0l));
    assert((mask == (-1l)) ==> ( (temp == (bget h3 list (v i + 1))) /\ 
                                 ((bget h3end list (v i + 1)) == (bget h3 list (v i))) /\
                                 ((bget h3end list (v i)) == (bget h3 list (v i + 1))) ));

    assert((mask == 0l) ==> ( ((bget h3 list (v i)) &^ (lognot mask)) == (bget h3 list (v i)) ));
    assert((mask == 0l) ==> ( ((bget h3 list (v i + 1)) &^ mask) == 0l));
    assert((mask == 0l) ==> ( ( ((bget h3 list (v i)) &^ (lognot mask)) |^
                                ((bget h3 list (v i + 1)) &^ mask) ) == (bget h3 list (v i)) ));
    assert(((bget h3 list (v i)) |^ 0l) == (bget h3 list (v i)));
    assert(temp == ( ((bget h3 list (v i + 1)) &^ mask) |^
                     ((bget h3 list (v i)) &^ (lognot mask)) ));
    assert((mask == 0l) ==> ( ((bget h3 list (v i + 1)) &^ mask) == 0l));
    assert((mask == 0l) ==> ( ((bget h3 list (v i)) &^ (lognot mask)) == (bget h3 list (v i)) ));
    assert( (0l |^ (bget h3 list (v i))) == (bget h3 list (v i)) );
    //assert((mask == 0l) ==> ( ( ((bget h3 list (v i + 1)) &^ mask)  |^
    //                             ((bget h3 list (v i)) &^ (lognot mask))) == (bget h3 list (v i)) ));
    assert((mask == 0l) ==> ( (temp == (bget h3 list (v i))) /\ 
                              ((bget h3end list (v i + 1)) == (bget h3 list (v i + 1))) /\
                              ((bget h3end list (v i)) == (bget h3 list (v i))) ));
    //assert((mask == 0l) ==> (bget h3end list (v i + 1)) == (bget h3 list (v i + 1)));
    //assert(I32.v (bget h3 list (v i)) < I32.v (bget h3 list (v i + 1)) ==> (temp == (bget h3 list (v i))));
           //(I32.v temp == I32.v (bget h3 list (v i))));// /\
            //I32.v (bget h3end list (v i)) == I32.v (bget h3 list (v i)) /\
            //I32.v (bget h3end list (v i + 1)) == I32.v (bget h3 list (v i + 1))));
    //assert(I32.v (bget h3 list (v i)) >= I32.v (bget h3 list (v i + 1)) ==> I32.v temp == I32.v (bget h3end list (v i + 1)));
    // Need to add in reasoning for all the bitwise operations. But either they end up exchanging
    // list[i] and list[i+1] or leaving them as-is. Assume as much.
    assert((bget h3 list (v i) == bget h3end list (v i + 1) /\
           bget h3 list (v i + 1) == bget h3end list (v i)) \/
           (bget h3 list (v i) == bget h3end list (v i) /\
           bget h3 list (v i + 1) == bget h3end list (v i + 1)));
    assert(I32.v (bget h3end list (v i)) <= I32.v (bget h3end list (v i + 1)));
    assert(check_ES_list_bound h3end list (v i));
    assert(check_ES_list_bound h3end list (v i + 1))


val check_ES:
    p: poly
  -> bound: UI32.t
  -> Stack bool
    (requires fun h -> live h p /\ is_poly_sampler_output h p)
    (ensures fun h0 _ h1 -> modifies0 h0 h1)

let check_ES p bound =
  let hInit = ST.get () in assert(is_poly_sampler_output hInit p);
  push_frame();
  // TODO/HACK: This is a hack to bind the hat operators in this function to the appropriate type;
  // heuristic parameter sets use I32.t and provable parameter sets use I16.t. We load the one
  // set of names from the Params module and rebind the operators here. Look into using FStar.Integers
  // to make this less miserable.
  [@inline_let] let op_Plus_Hat = I32.op_Plus_Hat in
  [@inline_let] let op_Subtraction_Hat = I32.op_Subtraction_Hat in
  [@inline_let] let op_Greater_Greater_Hat = I32.op_Greater_Greater_Hat in
  [@inline_let] let op_Amp_Hat = I32.op_Amp_Hat in
  [@inline_let] let op_Bar_Hat = I32.op_Bar_Hat in
  [@inline_let] let lognot = I32.lognot in
  
  let h0 = ST.get () in
  // Nik says push_frame should give us (modifies B.loc_none hInit h0) but it doesn't.
  // Will talk to Tahina.
  let sum = create (size 1) 0ul in
  let limit = create (size 1) params_n in
  let (list:lbuffer I32.t params_n) = create params_n 0l in
  let h0 = ST.get () in
  assert(disjoint p list);
  assert(B.modifies B.loc_none hInit h0);
  assert(forall (i:nat{i < v params_n}). {:pattern bget h0 p i} bget hInit p i == bget h0 p i);
  assert(is_poly_sampler_output h0 p);
  for (size 0) params_n
      (fun h _ -> live h p /\ live h list /\ modifies1 list h0 h /\ 
               (forall (i:nat{i < v params_n}). {:pattern bget h0 p i} bget h0 p i == bget h p i) /\
               is_poly_sampler_output h p /\
               (forall i . check_ES_list_bound h list i))
      (fun j ->
        let hx = ST.get () in assert(is_poly_sampler_output hx p); assert(is_sampler_output (bget hx p (v j)));
        let pj = p.(j) in
        assert(is_sampler_output pj);
        let abspj = abs_ (elem_to_int32 pj) in
        assert(I32.v abspj >= 0 /\ I32.v abspj <= pow2 (v params_s_bits) - 1);
        list.(j) <- abspj;
        let h = ST.get() in 
        assert(check_ES_list_bound h list (v j)); 
        assert(forall (i:nat{i < v params_n}). {:pattern bget h p i} bget hx p i == bget h p i);
        assert(is_poly_sampler_output h p)
      );

  let h1 = ST.get () in
  for (size 0) params_h
      (fun h j -> live h sum /\ live h limit /\ live h list /\
               modifies3 list sum limit h1 h /\
               v (bget h limit 0) == v params_n - j /\
               (forall i . check_ES_list_bound h list i) /\
               UI32.v (bget h sum 0) <= j * pow2 (v params_s_bits - 1))
      (fun j ->
          let loopMax = (limit.(size 0)) -. size 1 in
          let h2 = ST.get () in
          assert(v loopMax < v params_n);
          for 0ul loopMax
          (fun h _ -> live h p /\ live h sum /\ live h list /\
                   modifies1 list h2 h /\ check_ES_list_bound_buffer h list)
          (fun i -> check_ES_ordered_exchange_ct list i);

          let listIndex = limit.(size 0) -. size 1 in
          let h4 = ST.get () in
          assert(check_ES_list_bound h4 list (v listIndex));
          let listAmt = list.(listIndex) in
          let h5 = ST.get () in
          sum.(size 0) <- UI32.(sum.(size 0) +^ int32_to_uint32 listAmt);
          limit.(size 0) <- limit.(size 0) -. size 1
      );

   let sumAmt:UI32.t = sum.(size 0) in
   let res = UI32.(sumAmt >^ bound) in
   pop_frame();
   res

(*
let test _ = assert_norm(elem_v params_q == 4205569)
let test2 _ = assert_norm(2 * elem_v params_q == 8411138)
let test4 _ = assert_norm(v params_q_log == 23); assert_norm(pow2 (v params_q_log) == 8388608)
let test6 _ = assert_norm(pow2 23 == 8388608)
let test5 _ = assert_norm(pow2 (v (size 23)) == 8388608)
let test3 _ = assert_norm(pow2 (v params_q_log) == 8388608)


private let lemma_q_log_fact _ : Lemma (ensures pow2 (v params_q_log) < 2 * elem_v params_q) =
    assert_norm(pow2 (v params_q_log) < 2 * elem_v params_q)
*)

private inline_for_extraction noextract
val poly_uniform_valFromBuffer:
    subbuff: lbuffer uint8 (size (numbytes U32))
  -> Stack (r:pub_uint32{is_montgomery (uint32_to_elem r)})
    (requires fun h -> live h subbuff)
    (ensures fun h0 _ h1 -> h0 == h1 /\ modifies0 h0 h1)

let poly_uniform_valFromBuffer subbuff =
    // Can't prove this for some reason, although it should be doable since everything is a constant.
    // But good sanity check to make sure params_q and params_q_log are compatible for this function.
    //assert_norm(pow2 (v params_q_log) < 2 * elem_v params_q);
    let mask:uint32 = (u32 1 <<. params_q_log) -. u32 1 in
    lemma_shift_left_one_eq_pow2 params_q_log;
    assert(v (u32 1 <<. params_q_log) == pow2 (v params_q_log));
    assert(v ((u32 1 <<. params_q_log) -. u32 1) == pow2 (v params_q_log) - 1);
    assert(v mask == v ((u32 1 <<. params_q_log) -. u32 1));
    assert(v mask == pow2 (v params_q_log) - 1);
    assert(v mask == v (uint_pow2_minus_one (v params_q_log)));
    uintv_extensionality mask (uint_pow2_minus_one (v params_q_log));
    assert(mask == uint_pow2_minus_one (v params_q_log));
    let bufPosAsUint:uint32 = uint_from_bytes_le subbuff in
    let val1:uint32 = bufPosAsUint &. mask in
    assert(v val1 == v (bufPosAsUint &. mask));
    assert(v val1 == v (bufPosAsUint &. (uint_pow2_minus_one (v params_q_log))));
    // mask is 2^{params_q_log} - 1, and so val1 will be < 2^{params_q_log}.
    // params_q_log is chosen such that 2^{params_q_log} < 2 * params_q.
    // TODO: prove this when we have theory about bitwise operations: x & (2^q - 1) < 2^q
    uint_logand_pow2_minus_one bufPosAsUint (v params_q_log);
    assert(v val1 <= pow2 (v params_q_log) - 1);
    // Normalizer still has problems dealing with HACL* integers, but this suggestion from
    // Chris seems to give Z3 the information it needs.
    assert_norm(pow2 23 < 2 * elem_v params_q);
    assert(pow2 (v params_q_log) < 2 * elem_v params_q);
    assert(v val1 < 2 * elem_v params_q);
    // It is safe to compare this value with the regular less-than operator, so we declassify it to do that.
    unsafe_declassify val1

private inline_for_extraction noextract
val poly_uniform_setA:
    a: poly_k
  -> iBuf: lbuffer size_t (size 1)
  -> value: pub_uint32
  -> Stack unit
    (requires fun h -> live h a /\ live h iBuf /\ disjoint a iBuf /\ v (bget h iBuf 0) <= v params_n * v params_k /\
                    is_poly_k_montgomery_i h a (v (bget h iBuf 0))) 
    (ensures fun h0 _ h1 -> modifies2 a iBuf h0 h1 /\ v (bget h1 iBuf 0) <= v params_n * v params_k /\
                         ((v value < elem_v params_q /\ v (bget h0 iBuf 0) < (v params_k * v params_n)) ==>
                          v (bget h1 iBuf 0) = v (bget h0 iBuf 0) + 1) /\ 
                          is_poly_k_montgomery_i h1 a (v (bget h1 iBuf 0)))

let poly_uniform_setA a iBuf value =
    let params_q = elem_to_uint32 params_q in
    let i = iBuf.(size 0) in
    let h = ST.get () in assert(is_poly_k_montgomery_i h a (v i)); assert(modifies0 h h);
    if (value <. params_q && i <. (params_k *. params_n))
    then ( let h0 = ST.get () in assert(is_poly_k_montgomery_i h0 a (v i)); 
           [@inline_let] let reduction = reduce I64.((uint32_to_int64 value) *^ params_r2_invn) in
           assert(is_montgomery reduction);
           a.(i) <- reduction; // reduce I64.((uint32_to_int64 value) *^ params_r2_invn);
           let h1 = ST.get () in 
           assert(is_montgomery (bget h1 a (v i)));
           assert(forall (j:nat{j < v i}). {:pattern bget h1 a j} bget h0 a j == bget h1 a j);
           assert(is_poly_k_montgomery_i h1 a (v i));
           assert(is_poly_k_montgomery_i h1 a (v i + 1));
           iBuf.(size 0) <- i +. size 1;
           let h2 = ST.get() in
           assert(v (bget h2 iBuf 0) == (v i + 1));
           assert(forall (j:nat{j < v params_n * v params_k}) . {:pattern bget h2 a j} bget h1 a j == bget h2 a j);
           assert(is_poly_k_montgomery_i h2 a (v i + 1));
           assert(is_poly_k_montgomery_i h2 a (v (bget h2 iBuf 0))) )
    else ()

private inline_for_extraction noextract
val poly_uniform_do_while:
    a: poly_k
  -> seed: lbuffer uint8 crypto_randombytes
  -> pos: lbuffer size_t (size 1)
  -> i: lbuffer size_t (size 1)
  -> nblocks: lbuffer size_t (size 1)
  -> buf: lbuffer uint8 (shake128_rate *. params_genA +. size 1)
  -> dmsp: lbuffer uint16 (size 1)
  -> Stack unit
    (requires fun h -> let bufs = [bb a; bb seed; bb pos; bb i; bb nblocks; bb buf; bb dmsp] in
                    FStar.BigOps.big_and (live_buf h) bufs /\ FStar.BigOps.pairwise_and disjoint_buf bufs /\
                    (v (bget h i 0) < v params_k * v params_n) /\
                    ((bget h nblocks 0) == size 1 \/ (bget h nblocks 0) == params_genA) /\
                    is_poly_k_montgomery_i h a (v (bget h i 0)))
    (ensures fun h0 _ h1 -> modifies (loc a |+| loc pos |+| loc i |+| loc nblocks |+| loc buf |+| loc dmsp) h0 h1 /\
                         ((bget h1 nblocks 0) == size 1 \/ (bget h1 nblocks 0) == params_genA) /\
                         v (bget h1 i 0) <= v params_k * v params_n /\
                         is_poly_k_montgomery_i h1 a (v (bget h1 i 0)))

#reset-options "--z3rlimit 300 --max_fuel 1 --max_ifuel 1"

let poly_uniform_do_while a seed pos i nblocks buf dmsp =
    let h0 = ST.get () in
    assert(is_poly_k_montgomery_i h0 a (v (bget h0 i 0)));
    assert(modifies0 h0 h0);
    let nbytes:size_t = (params_q_log +. 7ul) /. 8ul in
    if (pos.(size 0)) >. (shake128_rate *. (nblocks.(size 0))) -. ((size 4) *. nbytes)
    then ( nblocks.(size 0) <- size 1;
         let bufSize:size_t = shake128_rate *. nblocks.(size 0) in
         let subbuff = sub buf (size 0) bufSize in
         cshake128_qtesla crypto_randombytes seed dmsp.(size 0) bufSize subbuff;
         dmsp.(size 0) <- dmsp.(size 0) +. u16 1;
         pos.(size 0) <- size 0 )
    else ();

    let h1 = ST.get () in 
    assert(modifies4 nblocks buf dmsp pos h0 h1);

    let pos0 = pos.(size 0) in
    let val1 = poly_uniform_valFromBuffer (sub buf pos0 (size (numbytes U32))) in
    pos.(size 0) <- pos.(size 0) +. nbytes;
    let pos0 = pos.(size 0) in
    let val2 = poly_uniform_valFromBuffer (sub buf pos0 (size (numbytes U32))) in
    pos.(size 0) <- pos.(size 0) +. nbytes;
    let pos0 = pos.(size 0) in
    let val3 = poly_uniform_valFromBuffer (sub buf pos0 (size (numbytes U32))) in
    pos.(size 0) <- pos.(size 0) +. nbytes;
    let pos0 = pos.(size 0) in
    let val4 = poly_uniform_valFromBuffer (sub buf pos0 (size (numbytes U32))) in
    pos.(size 0) <- pos.(size 0) +. nbytes;

    let h2 = ST.get () in
    assert(modifies4 nblocks buf dmsp pos h0 h2);
    assert(forall (j:nat{j < v (bget h2 i 0)}) . {:pattern bget h2 a j} bget h0 a j == bget h2 a j);
    assert(is_poly_k_montgomery_i h2 a (v (bget h2 i 0)));

    let hi = ST.get () in assert(v (bget hi i 0) <= v params_n * v params_k);
    assert(is_poly_k_montgomery_i hi a (v (bget hi i 0)));
    poly_uniform_setA a i val1;
    let hi = ST.get () in assert(v (bget hi i 0) <= v params_n * v params_k);
    assert(is_poly_k_montgomery_i hi a (v (bget hi i 0)));
    poly_uniform_setA a i val2;
    let hi = ST.get () in assert(v (bget hi i 0) <= v params_n * v params_k);
    assert(is_poly_k_montgomery_i hi a (v (bget hi i 0)));
    poly_uniform_setA a i val3;
    let hi = ST.get () in assert(v (bget hi i 0) <= v params_n * v params_k);
    assert(is_poly_k_montgomery_i hi a (v (bget hi i 0)));
    poly_uniform_setA a i val4;
    let hi = ST.get () in assert(v (bget hi i 0) <= v params_n * v params_k);
    assert(is_poly_k_montgomery_i hi a (v (bget hi i 0)));

    let h3 = ST.get () in
    assert(modifies (loc nblocks |+| loc buf |+| loc dmsp |+| loc pos |+| loc a |+| loc i) h0 h3)
    
#reset-options "--z3rlimit 100 --max_fuel 1 --max_ifuel 1"

val poly_uniform:
    a: poly_k
  -> seed: lbuffer uint8 crypto_randombytes
  -> Stack unit
    (requires fun h -> live h a /\ live h seed /\ disjoint a seed)
    (ensures fun h0 _ h1 -> modifies1 a h0 h1 /\ is_poly_k_montgomery h1 a)
    
let poly_uniform a seed =
    push_frame();
    let pos = create (size 1) (size 0) in
    let i = create (size 1) (size 0) in
    let nbytes:size_t = (params_q_log +. 7ul) /. 8ul in
    let nblocks = create (size 1) params_genA in
    // BUG (kkane): If nbytes is 3 and 1 isn't added to the size of buf, then there is a one byte overrun read
    // when extracting val4 above. Since buf is a stack-allocated variable the read should be into something else
    // on the stack (so it won't crash), which then gets masked out (so it doesn't affect the result). 
    // This may be one of the few memory safety violations in the history of the world that doesn't cause a problem. 
    // But F* sees the violation and so we allocate an extra byte of space which we can safely read into.
    let buf = create (shake128_rate *. params_genA +. size 1) (u8 0) in
    let dmsp = create (size 1) (u16 0) in
    cshake128_qtesla crypto_randombytes seed (dmsp.(size 0)) (shake128_rate *. params_genA) (sub buf (size 0) (shake128_rate *. params_genA));
    dmsp.(size 0) <- dmsp.(size 0) +. (u16 1);

    let h0 = ST.get () in
    LL.while
        (fun h -> live h a /\ live h pos /\ live h i /\ live h nblocks /\ live h buf /\ live h dmsp /\ live h seed /\
               modifies (loc dmsp |+| loc pos |+| loc a |+| loc i |+| loc nblocks |+| loc buf) h0 h /\
               v (bget h i 0) <= v params_k * v params_n /\
               is_poly_k_montgomery_i h a (v (bget h i 0)) /\
               ((bget h nblocks 0) == size 1 \/ (bget h nblocks 0) == params_genA))
        (fun h -> v (bget h i 0) < v params_k * v params_n)
        (fun _ -> i.(size 0) <. (params_k *. params_n) )
        (fun _ -> poly_uniform_do_while a seed pos i nblocks buf dmsp);

    let h1 = ST.get () in
    assert(v (bget h1 i 0) == v params_k * v params_n); 
    assert(is_poly_k_montgomery_i h1 a (v params_k * v params_n)); 
    assert(is_poly_k_montgomery h1 a);
    pop_frame();
    let h2 = ST.get () in
    assert(forall (j:nat{j < v params_k * v params_n}) . {:pattern bget h2 a j} bget h1 a j == bget h2 a j);
    assert(is_poly_k_montgomery h2 a)

private inline_for_extraction noextract
let randomness_extended_size = (params_k +. size 3) *. crypto_seedbytes

private inline_for_extraction noextract
val qtesla_keygen_sample_gauss_poly:
    randomness_extended: lbuffer uint8 randomness_extended_size
  -> nonce: lbuffer uint32 (size 1)
  -> p: poly
  -> k: size_t{v k <= v params_k}
  -> Stack unit
    (requires fun h -> live h randomness_extended /\ live h nonce /\ live h p /\ 
                    disjoint randomness_extended nonce /\ disjoint randomness_extended p /\ disjoint nonce p)
    (ensures fun h0 _ h1 -> modifies2 nonce p h0 h1 /\ is_poly_sampler_output h1 p)

let qtesla_keygen_sample_gauss_poly randomness_extended nonce p k =
    let subbuffer = sub randomness_extended (k *. crypto_seedbytes) crypto_randombytes in
    let nonce0 = nonce.(size 0) in
    nonce.(size 0) <- nonce0 +. u32 1;
    let nonce1 = nonce.(size 0) in
    sample_gauss_poly p subbuffer nonce1

(*let test (e:poly_k) (k:size_t{v k < v params_k}) : Stack unit (requires fun h -> live h e) (ensures fun _ _ _ -> True) =
    //let ek = sub e (k *. params_n) params_n in
    let ek2 = index_poly e k in
    //assert(loc_includes (loc e) (loc ek));
    assert(loc_includes (loc e) (loc ek2))*)

private inline_for_extraction noextract
val qtesla_keygen_:
    randomness: lbuffer uint8 crypto_randombytes
  -> pk: lbuffer uint8 crypto_publickeybytes
  -> sk: lbuffer uint8 crypto_secretkeybytes
  -> Stack (r:I32.t{r == 0l})
    (requires fun h -> live h randomness /\ live h pk /\ live h sk /\ 
                    disjoint randomness pk /\ disjoint randomness sk /\ disjoint pk sk)
    (ensures fun h0 _ h1 -> modifies2 pk sk h0 h1)

#reset-options "--z3rlimit 300 --max_fuel 0 --max_ifuel 0 --z3cliopt 'smt.qi.eager_threshold=100'"

let qtesla_keygen_ randomness pk sk =
  push_frame();
  let randomness_extended = create randomness_extended_size (u8 0) in
  let e:poly_k = poly_k_create () in
  let s:poly = poly_create () in
  let s_ntt:poly = poly_create () in
  let a:poly_k = poly_k_create () in
  let t:poly_k = poly_k_create () in 
  let nonce = create (size 1) (u32 0) in
  params_SHAKE crypto_randombytes randomness randomness_extended_size randomness_extended;
  let h0 = ST.get () in
  assert(modifies0 h0 h0);
  for (size 0) params_k
      (fun h _ -> live h nonce /\ live h e /\ live h randomness_extended /\ modifies2 nonce e h0 h)
      (fun k ->
        do_while
          (fun h _ -> live h nonce /\ live h e /\ live h randomness_extended /\ modifies2 nonce e h0 h)
          (fun _ ->
            let ek = index_poly e k in
            qtesla_keygen_sample_gauss_poly randomness_extended nonce ek k;
            not (check_ES ek params_Le)
          )
      ); 
  let h1 = ST.get () in
  assert(modifies2 nonce e h0 h1);
  do_while
      (fun h stop -> live h s /\ live h randomness_extended /\ live h nonce /\ modifies2 nonce s h1 h)
      (fun _ ->
        qtesla_keygen_sample_gauss_poly randomness_extended nonce s params_k;
        not (check_ES s params_Ls)
      ); 
  let h2 = ST.get () in
  assert(modifies3 nonce e s h0 h2);
  let rndsubbuffer = sub randomness_extended ((params_k +. (size 1)) *. crypto_seedbytes) (size 2 *. crypto_seedbytes) in
  poly_uniform a (sub rndsubbuffer (size 0) crypto_randombytes);
  let h3 = ST.get () in
  assert(modifies4 nonce e s a h0 h3); 
  poly_ntt s_ntt s;
  let h4 = ST.get () in
  assert(modifies (loc nonce |+| loc e |+| loc s |+| loc a |+| loc s_ntt) h0 h4);
  C.Loops.for (size 0) params_k
      (fun h _ -> live h t /\ live h a /\ live h s_ntt /\ live h e /\ modifies1 t h4 h)
      (fun k ->
          let tk:poly = index_poly t k in
          let ak:poly = index_poly a k in
          let ek:poly = index_poly e k in
          poly_mul tk ak s_ntt;
          poly_add_correct tk tk ek
        );

  let h5 = ST.get () in
  assert(modifies (loc nonce |+| loc e |+| loc s |+| loc a |+| loc s_ntt |+| loc t) h0 h5);
  encode_or_pack_sk sk s e rndsubbuffer;
  let h6 = ST.get () in
  assert(modifies (loc nonce |+| loc e |+| loc s |+| loc a |+| loc s_ntt |+| loc t |+| loc sk) h0 h6);
  assume(is_poly_k_pk h6 t);
  encode_pk pk t (sub rndsubbuffer (size 0) crypto_seedbytes);
  let h7 = ST.get () in
  assert(modifies (loc nonce |+| loc e |+| loc s |+| loc a |+| loc s_ntt |+| loc t |+| loc sk |+| loc pk) h0 h7);
  pop_frame();
  0l

#reset-options "--z3rlimit 100 --max_fuel 1 --max_ifuel 1"

val qtesla_keygen:
    pk: lbuffer uint8 crypto_publickeybytes
  -> sk: lbuffer uint8 crypto_secretkeybytes
  -> Stack (r:I32.t{r == 0l})
    (requires fun h -> live h pk /\ live h sk /\ 
                    disjoint R.state pk /\ disjoint R.state sk /\ disjoint pk sk)
    (ensures fun h0 _ h1 -> modifies3 R.state pk sk h0 h1)

let qtesla_keygen pk sk =
    //recall R.state;
    push_frame();
    let randomness = create crypto_randombytes (u8 0) in
    R.randombytes_ crypto_randombytes randomness;
    let r = qtesla_keygen_ randomness pk sk in
    pop_frame();
    r

private let nblocks_shake = shake_rate /. (((params_b_bits +. (size 1)) +. (size 7)) /. (size 8))
private let bplus1bytes = ((params_b_bits +. size 1) +. (size 7)) /. (size 8)

private inline_for_extraction noextract
val sample_y_while_body:
    y : poly
  -> seed : lbuffer uint8 crypto_randombytes
  -> nblocks : lbuffer size_t (size 1)
  -> buf : lbuffer uint8 (params_n *. bplus1bytes)
  -> dmsp : lbuffer uint16 (size 1)
  -> pos : lbuffer size_t (size 1)
  -> i : lbuffer size_t (size 1)
  -> Stack unit
    (requires fun h -> let bufs = [bb y; bb seed; bb nblocks; bb buf; bb dmsp; bb pos; bb i] in
                    FStar.BigOps.big_and (live_buf h) bufs /\ FStar.BigOps.pairwise_and disjoint_buf bufs /\
                    (v (bget h nblocks 0) == v params_n \/ v (bget h nblocks 0) == v nblocks_shake) /\
                    v (bget h i 0) < v params_n /\
                    (v (bget h pos 0) + numbytes U32 <= v params_n * v bplus1bytes \/ v (bget h pos 0) >= v params_n * v bplus1bytes)) 
    (ensures fun h0 _ h1 -> modifies (loc y |+| loc nblocks |+| loc buf |+| loc dmsp |+| loc pos |+| loc i) h0 h1 /\
                         (v (bget h1 i 0) == v (bget h0 i 0) \/ v (bget h1 i 0) == v (bget h0 i 0) + 1) /\
                         (v (bget h1 nblocks 0) == v params_n \/ v (bget h1 nblocks 0) == v nblocks_shake) /\

                         (v (bget h1 pos 0) + numbytes U32 <= v params_n * v bplus1bytes \/ v (bget h1 pos 0) >= v params_n * v bplus1bytes) /\
    
                         is_poly_y_sampler_output_i h1 y (v (bget h1 i 0)))

let sample_y_while_body y seed nblocks buf dmsp pos i =
    let nbytes = bplus1bytes in
    let h = ST.get () in
    if pos.(size 0) >=. nblocks.(size 0) *. nbytes
    then (
        nblocks.(size 0) <- nblocks_shake;
        params_cSHAKE crypto_randombytes seed dmsp.(size 0) shake_rate (sub buf (size 0) shake_rate);
        dmsp.(size 0) <- dmsp.(size 0) +. u16 1;
        pos.(size 0) <- size 0
    ) else ();

    let h0 = ST.get () in
    assert(v (bget h0 pos 0) + numbytes U32 <= v params_n * v bplus1bytes);

    let pos0 = pos.(size 0) in
    //assume(v pos0 + numbytes U32 <= v (params_n *. bplus1bytes));
    let subbuff = sub buf pos0 (size (numbytes U32)) in
    let bufPosAsU32 = uint_from_bytes_le #U32 #_ subbuff in
    let bufPosAsElem = uint32_to_elem (Lib.RawIntTypes.u32_to_UInt32 bufPosAsU32) in
    let i0 = i.(size 0) in
    // Heuristic parameter sets do four at once. Perf. But optional.
    let h1 = ST.get () in
    assume(FStar.Int.fits (elem_v (to_elem 1 <<^ (params_b_bits +. size 1)) - 1) elem_n);
    assume(is_elem (bufPosAsElem &^ ((to_elem 1 <<^ (params_b_bits +. size 1)) -^ to_elem 1)));
    y.(i0) <- bufPosAsElem &^ ((to_elem 1 <<^ (params_b_bits +. size 1)) -^ to_elem 1);
    let h2 = ST.get () in
    assume(is_elem ((bget h2 y (v i0)) -^ params_B));
    y.(i0) <- y.(i0) -^ params_B;
    if y.(i0) <> (to_elem 1 <<^ params_b_bits)
    then ( i.(size 0) <- i0 +. size 1 )
    else ();
    pos.(size 0) <- pos.(size 0) +. nbytes;
    let hFinal = ST.get () in
    assume(v (bget hFinal pos 0) + numbytes U32 <= v params_n * v bplus1bytes \/ v (bget hFinal pos 0) >= v params_n * v bplus1bytes);
    assume(is_poly_y_sampler_output_i hFinal y (v (bget hFinal i 0)))

val sample_y:
    y : poly
  -> seed : lbuffer uint8 crypto_randombytes
  -> nonce: UI32.t
  -> Stack unit
    (requires fun h -> live h y /\ live h seed /\ disjoint y seed)
    (ensures fun h0 _ h1 -> modifies1 y h0 h1 /\ is_poly_y_sampler_output h1 y)

let sample_y y seed nonce = 
    push_frame();

    let i = create (size 1) (size 0) in
    let pos = create (size 1) (size 0) in
    let nblocks = create (size 1) params_n in
    let buf = create (params_n *. bplus1bytes) (u8 0) in
    let nbytes = bplus1bytes in
    [@inline_let] let dmspVal:uint16 = cast U16 SEC (Lib.RawIntTypes.u16_from_UInt16 (uint32_to_uint16 UI32.(nonce <<^ 8ul))) in
    let dmsp = create (size 1) dmspVal in

    params_cSHAKE crypto_randombytes seed dmsp.(size 0) (params_n *. nbytes) buf;
    let hInit = ST.get () in
    dmsp.(size 0) <- dmsp.(size 0) +. u16 1;

    let h0 = ST.get () in
    assert(v (bget h0 pos 0) < v params_n * v bplus1bytes);
    LL.while
    (fun h -> live h y /\ live h i /\ live h pos /\ live h nblocks /\ live h buf /\ live h dmsp /\
           modifies (loc y |+| loc i |+| loc pos |+| loc nblocks |+| loc buf |+| loc dmsp) h0 h /\
           (v (bget h nblocks 0) == v params_n \/ v (bget h nblocks 0) == v nblocks_shake) /\
           (v (bget h pos 0) + numbytes U32 <= v params_n * v bplus1bytes \/ v (bget h pos 0) >= v params_n * v bplus1bytes) /\
           v (bget h i 0) <= v params_n /\
           is_poly_y_sampler_output_i h y (v (bget h i 0)))
    (fun h -> v (bget h i 0) < v params_n)
    (fun _ -> i.(size 0) <. params_n)
    (fun _ ->
        sample_y_while_body y seed nblocks buf dmsp pos i
    );

    let hFinal = ST.get () in
    pop_frame();
    let hReturn = ST.get () in
    assert(is_poly_equal hFinal hReturn y)

private inline_for_extraction noextract
val hash_H_inner_for:
    v_ : poly_k
  -> t : lbuffer uint8 (params_k *. params_n +. crypto_hmbytes)
  -> index : size_t{v index < v params_n * v params_k}
  -> Stack unit
    (requires fun h -> live h v_ /\ live h t /\ disjoint v_ t /\ is_poly_k_montgomery h v_)
    (ensures fun h0 _ h1 -> modifies1 t h0 h1 /\ is_poly_k_montgomery h1 v_)

//#reset-options "--log_queries --print_z3_statistics --using_facts_from '* -FStar.BitVector'"

//let test _ = assert(FStar.Int.fits (I32.v (1l <<^ params_d_ui32) - 1) I32.n)

module S = QTesla.Params

let hash_H_inner_for v_ t index =
    let hInit = ST.get () in 
    assert(is_poly_k_montgomery hInit v_);
    assert(is_montgomery (bget hInit v_ (v index)));
    let vindex:elem = v_.(index) in
    assert(is_montgomery vindex);
    let temp:I32.t = elem_to_int32 vindex in
    assert_norm(v (_RADIX32 -. size 1) < I32.n);
    let mask = I32.((params_q /^ 2l -^ temp) >>>^ (_RADIX32 -. size 1)) in
    let temp = I32.(((temp -^ params_q) &^ mask) |^ (temp &^ (lognot mask))) in
    assert_norm(FStar.Int.fits (I32.v (1l <<^ params_d)) I32.n); 
    Int.shift_left_value_lemma (I32.v 1l) (v params_d);
    assert_norm(pow2 (v params_d) > 0);
    assert_norm(pow2 S.params_d < pow2 (I32.n - 1));
    assert_norm(pow2 (v params_d) < pow2 (I32.n - 1));
    assert(I32.v (1l <<^ params_d) == pow2 (v params_d));
    assert(FStar.Int.fits (I32.v (1l <<^ params_d) - 1) I32.n);
    let cL = I32.(temp &^ ((1l <<^ params_d) -^ 1l)) in
    assert_norm(v (params_d -. size 1) < I32.n);
    //Int.logand_pos_le (I32.v temp) (I32.v ((1l <<^ params_d) -^ 1l));
    Int.sign_bit_positive (I32.v cL);
    assert(I32.v cL >= 0);
    let mask = I32.(((1l <<^ (params_d -. (size 1))) -^ cL) >>>^ (_RADIX32 -. size 1)) in
    let cL = I32.(((cL -^ (1l <<^ params_d)) &^ mask) |^ (cL &^ (lognot mask))) in
    assume(FStar.Int.fits (I32.v temp - I32.v cL) I32.n);
    //assume(I32.v temp >= -(S.params_q / 2) /\ I32.v temp <= S.params_q / 2);
    //assume(I32.v cL >= 0 /\ I32.v cL <= pow2 S.params_d);
    t.(index) <- Lib.RawIntTypes.u8_from_UInt8 (int32_to_uint8 I32.((temp -^ cL) >>>^ params_d));
    let hFinal = ST.get () in 
    assert(is_poly_k_equal hInit hFinal v_)

private inline_for_extraction noextract
val hash_H_outer_for:
    v_ : poly_k
  -> t : lbuffer uint8 (params_k *. params_n +. crypto_hmbytes)
  -> k : size_t{v k < v params_k}
  -> Stack unit
    (requires fun h -> live h v_ /\ live h t /\ disjoint v_ t /\ is_poly_k_montgomery h v_)
    (ensures fun h0 _ h1 -> modifies1 t h0 h1 /\ is_poly_k_montgomery h1 v_)

let hash_H_outer_for v_ t k =
    let h1 = ST.get () in
    for 0ul params_n
    (fun h i -> live h v_ /\ live h t /\ modifies1 t h1 h /\ is_poly_k_montgomery h v_)
    (fun i ->
        hash_H_inner_for v_ t (k *. params_n +. i)
    )

val hash_H:
    c_bin : lbuffer uint8 crypto_c_bytes
  -> v_ : poly_k
  -> hm : lbuffer uint8 crypto_hmbytes
  -> Stack unit
    (requires fun h -> live h c_bin /\ live h v_ /\ live h hm /\ disjoint c_bin v_ /\ disjoint c_bin hm /\ disjoint v_ hm /\
                    is_poly_k_montgomery h v_)
    (ensures fun h0 _ h1 -> modifies1 c_bin h0 h1)

#reset-options "--z3rlimit 400 --max_fuel 1 --max_ifuel 1"

let hash_H c_bin v_ hm =
    let hInit = ST.get () in
    push_frame();
    let hFrame = ST.get () in 
    assert(is_poly_k_equal hInit hFrame v_);

    [@inline_let] let params_q = elem_to_int32 params_q in
    let t = create (params_k *. params_n +. crypto_hmbytes) (u8 0) in

    let h0 = ST.get () in
    //assert(Seq.equal (as_seq hInit v_) (as_seq hFrame v_));
    //assert(Seq.equal (as_seq hFrame v_) (as_seq h0 v_));
    //assert(Seq.equal (as_seq hInit v_) (as_seq h0 v_));
    assert(is_poly_k_equal hFrame h0 v_);
    for 0ul params_k
    (fun h _ -> live h v_ /\ live h t /\ modifies1 t h0 h /\ is_poly_k_montgomery h v_)
    (fun k ->
        hash_H_outer_for v_ t k
    );

    update_sub #MUT #_ #_ t (params_k *. params_n) crypto_hmbytes hm;
    params_SHAKE (params_k *. params_n +. crypto_hmbytes) t crypto_c_bytes c_bin;

    pop_frame()

private let encode_c_invariant (h:HS.mem) (pos_list : lbuffer UI32.t params_h) (sign_list : lbuffer I16.t params_h) (i : size_t) = 
    forall (j:nat{j < v i /\ j < v params_h}) . 
        v (bget h pos_list j) < v params_n /\
        (bget h sign_list j == (-1s) \/ bget h sign_list j == 0s \/ bget h sign_list j == 1s)

private inline_for_extraction noextract
val encode_c_while_body:
    pos_list : lbuffer UI32.t params_h
  -> sign_list : lbuffer I16.t params_h
  -> c_bin : lbuffer uint8 crypto_c_bytes
  -> c : lbuffer I16.t params_n
  -> r : lbuffer uint8 shake_rate
  -> dmsp : lbuffer uint16 (size 1)
  -> cnt : lbuffer size_t (size 1)
  -> i : lbuffer size_t (size 1)
  -> Stack unit
    (requires fun h -> let bufs = [bb pos_list; bb sign_list; bb c_bin; bb c; bb r; bb dmsp; bb cnt; bb i] in
                    FStar.BigOps.big_and (live_buf h) bufs /\ FStar.BigOps.pairwise_and disjoint_buf bufs /\
                    v (bget h i 0) < v params_h /\
                    encode_c_invariant h pos_list sign_list (bget h i 0))
    (ensures fun h0 _ h1 -> modifies (loc pos_list |+| loc sign_list |+| loc c |+| loc r |+| loc dmsp |+| loc cnt |+| loc i) h0 h1 /\
                         encode_c_invariant h1 pos_list sign_list (bget h1 i 0))

let encode_c_while_body pos_list sign_list c_bin c r dmsp cnt i =
    let h0 = ST.get () in
    assert(encode_c_invariant h0 pos_list sign_list (bget h0 i 0));
    
    let iVal:size_t = i.(size 0) in
    if cnt.(size 0) >. (shake128_rate -. (size 3))
    then ( cshake128_qtesla crypto_randombytes c_bin (dmsp.(size 0)) shake128_rate r;
           dmsp.(size 0) <- dmsp.(size 0) +. (u16 1);
           cnt.(size 0) <- size 0
         )
    else ();

    let cntVal:size_t = cnt.(size 0) in
    let rCntVal:uint8 = r.(cntVal) in
    [@inline_let] let rCntVal:size_t = unsafe_declassify (cast U32 SEC rCntVal) in
    let rCntVal1:uint8 = r.(cntVal +. size 1) in
    [@inline_let] let rCntVal1:size_t = unsafe_declassify (cast U32 SEC rCntVal1) in
    let pos:size_t = (rCntVal <<. size 8) |. rCntVal1 in
    //assert(v pos >= 0);
    //Int.logand_pos_le #(numbytes U32) (v pos) (v (params_n -. size 1));
    let pos:size_t = pos &. (params_n -. (size 1)) in

    assume(v pos < v params_n);

    let h1 = ST.get () in
    assert(forall (j:nat{j < v params_h}) . {:pattern bget h1 pos_list j} bget h0 pos_list j == bget h1 pos_list j);
    assert(forall (j:nat{j < v params_h}) . {:pattern bget h1 sign_list j} bget h0 sign_list j == bget h1 sign_list j);
    assert(bget h0 i 0 == bget h1 i 0);
    assert(encode_c_invariant h1 pos_list sign_list (bget h1 i 0)); 
    
    if (c.(pos)) = 0s
    then ( let rCntVal2:uint8 = r.(cntVal +. size 2) in
           [@inline_let] let rCntVal2:UI8.t = Lib.RawIntTypes.u8_to_UInt8 rCntVal2 in
           if UI8.((rCntVal2 &^ 1uy) = 1uy)
           then c.(pos) <- -1s
           else c.(pos) <- 1s;
           pos_list.(iVal) <- pos;
           sign_list.(iVal) <- c.(pos);
           i.(size 0) <- iVal +. (size 1)
         )
    else ();
    cnt.(size 0) <- cntVal +. (size 3);

    let h2 = ST.get () in
    assert(forall (j:nat{j < v params_h /\ j <> v iVal}) . {:pattern bget h2 pos_list j} bget h1 pos_list j == bget h2 pos_list j);
    assert(forall (j:nat{j < v params_h /\ j <> v iVal}) . {:pattern bget h2 sign_list j} bget h1 sign_list j == bget h2 sign_list j);
    assert(encode_c_invariant h2 pos_list sign_list (bget h2 i 0))

val encode_c:
    pos_list : lbuffer UI32.t params_h
  -> sign_list : lbuffer I16.t params_h
  -> c_bin : lbuffer uint8 crypto_c_bytes
  -> Stack unit
    (requires fun h -> live h pos_list /\ live h sign_list /\ live h c_bin /\ disjoint pos_list sign_list /\
                    disjoint pos_list c_bin /\ disjoint sign_list c_bin)
    (ensures fun h0 _ h1 -> modifies2 pos_list sign_list h0 h1 /\ encode_c_invariant h1 pos_list sign_list params_h)

#reset-options "--z3rlimit 300 --max_fuel 0 --max_ifuel 0"

// This function looks identical between the I and p-III sets.
let encode_c pos_list sign_list c_bin =
    push_frame();

    let c = create params_n 0s in
    let r = create shake128_rate (u8 0) in
    let dmsp = create (size 1) (u16 0) in
    let cnt = create (size 1) (size 0) in
    let i = create (size 1) (size 0) in

    cshake128_qtesla crypto_randombytes c_bin (dmsp.(size 0)) shake128_rate r;
    let dmspVal:uint16 = dmsp.(size 0) in
    dmsp.(size 0) <- dmspVal +. (u16 1);

    // c already initialized to zero above, no need to loop and do it again as is done in the reference code

    let h0 = ST.get () in
    LL.while
    (fun h -> live h pos_list /\ live h sign_list /\ live h c_bin /\ live h c /\ live h r /\ live h dmsp /\ live h cnt /\ live h i /\
           modifies (loc r |+| loc dmsp |+| loc cnt |+| loc c |+| loc pos_list |+| loc sign_list |+| loc i) h0 h /\
           encode_c_invariant h pos_list sign_list (bget h i 0))
    (fun h -> v (bget h i 0) < v params_h)
    (fun _ -> i.(size 0) <. params_h)
    (fun _ ->
        encode_c_while_body pos_list sign_list c_bin c r dmsp cnt i
    );

    let h1 = ST.get () in
    assert(encode_c_invariant h1 pos_list sign_list params_h);

    pop_frame()

#reset-options "--z3rlimit 100 --max_fuel 1 --max_ifuel 1"

let lemma_is_s_still_sk (h0 h1: HS.mem) (s: lbuffer sparse_elem params_n) : Lemma
    (requires is_s_sk h0 s /\ 
              (forall (i:nat{i < v params_n}) . {:pattern bget h1 s i} bget h0 s i == bget h1 s i))
    (ensures is_s_sk h1 s) = 
    //assert((is_s_sk h0 s) ==> (forall (i:nat{i < v params_n}) . is_sparse_elem_sk (bget h0 s i)));
    //assert(is_s_sk h0 s);
    //assert(forall (i:nat{i < v params_n}) . {:pattern is_sparse_elem_sk (bget h0 s i)} is_sparse_elem_sk (bget h0 s i));
    //assert(forall (i:nat{i < v params_n}) . {:pattern bget h1 s i} bget h0 s i == bget h1 s i);
    admit()

let lemma_is_e_still_sk (h0 h1: HS.mem) (e: lbuffer sparse_elem (params_n *. params_k)) : Lemma
    (requires is_e_sk h0 e /\ 
              (forall (i:nat{i < v params_n * v params_k}) . {:pattern bget h1 e i} bget h0 e i == bget h1 e i))
    (ensures is_e_sk h1 e) = 
    //assert(is_s_sk h0 s);
    //assert(forall (i:nat{i < v params_n}) . {:pattern is_sparse_elem_sk (bget h0 s i)} is_sparse_elem_sk (bget h0 s i));
    //assert(forall (i:nat{i < v params_n}) . {:pattern bget h1 s i} bget h0 s i == bget h1 s i);
    admit()

val sparse_mul:
    prod : poly
  -> s : lbuffer sparse_elem params_n
  -> pos_list : lbuffer UI32.t params_h
  -> sign_list : lbuffer I16.t params_h
  -> Stack unit
    (requires fun h -> live h prod /\ live h s /\ live h pos_list /\ live h sign_list /\ 
                    disjoint prod s /\ disjoint prod pos_list /\ disjoint prod sign_list /\
                    disjoint s pos_list /\ disjoint s sign_list /\ disjoint pos_list sign_list /\
                    encode_c_invariant h pos_list sign_list params_h /\
                    is_s_sk h s)
    (ensures fun h0 _ h1 -> modifies1 prod h0 h1 /\ is_poly_sparse_mul_output h1 prod)

// Patrick says each element of prod on output will be at most params_s_bits + log2(params_h) in length,
// which bounds each element's size. params_h determines how many times we may possibly add something to
// a single element. This should be within 2^16 for all parameter sets. That's a loose bound, but enough
// for later proving that poly_add(z, y, Sc) falls within the modulus q.
let sparse_mul prod s pos_list sign_list =
    let hInit = ST.get () in
    assert(is_s_sk hInit s);
    push_frame();

    let t = s in

    let h0 = ST.get () in
    assert(forall (i:nat{i < v params_n}) . bget hInit s i == bget h0 s i);
    lemma_is_s_still_sk hInit h0 s;
    assert(is_s_sk h0 s);
    for 0ul params_n
    (fun h i -> live h prod /\ modifies1 prod h0 h /\ i <= v params_n /\ (forall (j:nat{j < i}) . elem_v (bget h prod j) == 0))
    (fun i -> 
        let hStart = ST.get () in
        assert(forall (j:nat{j < v i}) . elem_v (bget hStart prod j) == 0);
        prod.(i) <- to_elem 0;
        let hZero = ST.get () in
        assert(forall (j:nat{j < v i}) . bget hStart prod j == bget hZero prod j);
        assert(elem_v (bget hZero prod (v i)) == 0);
        assert(forall (j:nat{j <= v i}) . elem_v (bget hZero prod j) == 0)
    );

    let h1 = ST.get () in
    assert(forall (i:nat{i < v params_n}) . {:pattern bget h1 prod i} bget h1 prod i == to_elem 0);
    assert(is_poly_sparse_mul_output h1 prod);
    lemma_is_s_still_sk h0 h1 s;
    for 0ul params_h
    (fun h _ -> live h prod /\ live h t /\ live h pos_list /\ live h sign_list /\ modifies1 prod h1 h /\
             encode_c_invariant h pos_list sign_list params_h /\ is_s_sk h s /\ is_poly_sparse_mul_output h prod)
    (fun i ->
        let h = ST.get () in assert(UI32.v (bget h pos_list (v i)) < v params_n);
        let pos = pos_list.(i) in
        assert(UI32.v pos < v params_n);
        let h2 = ST.get () in
	for 0ul pos
	(fun h _ -> live h prod /\ live h t /\ live h pos_list /\ live h sign_list /\ modifies1 prod h2 h /\ 
                 encode_c_invariant h pos_list sign_list params_h /\ is_s_sk h s /\ is_poly_sparse_mul_output h prod)
	(fun j -> 
	    let sign_list_i:I16.t = sign_list.(i) in
            //assume(v (j +. params_n -. pos) < v params_n);
            assert(v j < v pos);
            let h = ST.get() in 
            assert(is_sparse_elem_sk (bget h t (v j + v params_n - v pos)));
            assert(is_poly_sparse_mul_output h prod);
	    let tVal:sparse_elem = t.(j +. params_n -. pos) in
            assert(is_sparse_elem_sk tVal);
            //assume(v j < v params_n);
            //assume(FStar.Int.fits (I16.v sign_list_i * I16.v tVal) I16.n);
            let hx = ST.get () in
            //assume(FStar.Int.fits (elem_v (bget hx prod (v j)) - (I16.v sign_list_i * I16.v tVal)) elem_n);
            //assume(is_elem ((bget hx prod (v j)) -^ (int16_to_elem I16.(sign_list_i *^ (sparse_to_int16 tVal)))));
            assert(sign_list_i == (-1s) \/ sign_list_i == 0s \/ sign_list_i == 1s);
            //assume(I16.v tVal <> Int.min_int I16.n);
            assert(sparse_v tVal < pow2 (v params_s_bits));
            assert(sparse_v tVal >= -(pow2 (v params_s_bits)));
            assume(Int.min_int I16.n < -(pow2 (v params_s_bits)));
            assert(Int.fits (I16.v sign_list_i * sparse_v tVal) I16.n);
            assume(Int.fits (elem_v (bget h prod (v j)) - (I16.v sign_list_i * sparse_v tVal)) elem_n);
	    prod.(j) <- prod.(j) -^ (int16_to_elem I16.(sign_list_i *^ (sparse_to_int16 tVal)));
            let hLoopEnd = ST.get () in
            assert(forall (k:nat{k < v params_n /\ k <> v j}) . {:pattern bget hLoopEnd prod k} bget h prod k == bget hLoopEnd prod k);
            assume(is_sparse_mul_output (bget hLoopEnd prod (v j)));
            lemma_is_s_still_sk h hLoopEnd s           
	);

        let h3 = ST.get () in
        //assume(v pos < v params_n);
	for pos params_n
	(fun h _ -> live h prod /\ live h t /\ live h pos_list /\ live h sign_list /\ modifies1 prod h3 h /\ is_s_sk h s /\
                 is_poly_sparse_mul_output h prod)
	(fun j -> 
	    let sign_list_i:I16.t = sign_list.(i) in
            let h = ST.get() in 
            assert(is_sparse_elem_sk (bget h t (v j - v pos)));
	    let tVal:sparse_elem = t.(j -. pos) in
            let hx = ST.get () in
            //assume(FStar.Int.fits (I16.v sign_list_i * I16.v tVal) I16.n);
            //assume(FStar.Int.fits (elem_v (bget hx prod (v j)) + (I16.v sign_list_i * I16.v tVal)) elem_n);
            //assume(is_elem ((bget hx prod (v j)) +^ (int16_to_elem I16.(sign_list_i *^ (sparse_to_int16 tVal)))));
            assert(is_sparse_elem_sk tVal);            
            assert(sparse_v tVal < pow2 (v params_s_bits));
            assert(sparse_v tVal >= -(pow2 (v params_s_bits)));
            assume(Int.min_int I16.n < -(pow2 (v params_s_bits)));
            assert(Int.fits (I16.v sign_list_i * sparse_v tVal) I16.n);
            assume(Int.fits (elem_v (bget h prod (v j)) + (I16.v sign_list_i * sparse_v tVal)) elem_n);
  	    prod.(j) <- prod.(j) +^ (int16_to_elem I16.(sign_list_i *^ (sparse_to_int16 tVal)));
            let hLoopEnd = ST.get () in
            assert(forall (k:nat{k < v params_n /\ k <> v j}) . {:pattern bget hLoopEnd prod k} bget h prod k == bget hLoopEnd prod k);
            assume(is_sparse_mul_output (bget hLoopEnd prod (v j)));
            lemma_is_s_still_sk h hLoopEnd s
	)
    );

    let hFinal = ST.get () in
    pop_frame();
    let hReturn = ST.get () in
    assert(forall (i:nat{i < v params_n}) . {:pattern bget hReturn prod i} bget hFinal prod i == bget hReturn prod i)

val sparse_mul32:
    prod : poly
  -> pk : lbuffer I32.t params_n
  -> pos_list : lbuffer UI32.t params_h
  -> sign_list : lbuffer I16.t params_h
  -> Stack unit
    (requires fun h -> live h prod /\ live h pk /\ live h pos_list /\ live h sign_list /\
                    disjoint prod pk /\ disjoint prod pos_list /\ disjoint prod sign_list /\
                    disjoint pk pos_list /\ disjoint pk sign_list /\ disjoint pos_list sign_list /\
                    is_poly_pk h pk /\
                    encode_c_invariant h pos_list sign_list params_h)
    (ensures fun h0 _ h1 -> modifies1 prod h0 h1 /\ is_poly_sparse_mul32_output h1 prod)

let sparse_mul32 prod pk pos_list sign_list =
    let hInit = ST.get () in
    push_frame();

    let h0 = ST.get () in
    for 0ul params_n
    (fun h i -> live h prod /\ modifies1 prod h0 h /\ i <= v params_n /\ (forall (j:nat{j < i}) . elem_v (bget h prod j) == 0))
    (fun i -> 
        let hStart = ST.get () in
        assert(forall (j:nat{j < v i}) . elem_v (bget hStart prod j) == 0);
        prod.(i) <- to_elem 0;
        let hZero = ST.get () in
        assert(forall (j:nat{j < v i}) . bget hStart prod j == bget hZero prod j);
        assert(elem_v (bget hZero prod (v i)) == 0);
        assert(forall (j:nat{j <= v i}) . elem_v (bget hZero prod j) == 0)
    );

    let h1 = ST.get () in
    assert(forall (i:nat{i < v params_n}) . {:pattern bget h1 prod i} bget h1 prod i == to_elem 0);
    assert(is_poly_sparse_mul32_output h1 prod);
    assert(is_poly_equal hInit h1 pk);
    assert(is_poly_pk h1 pk);

    for 0ul params_h
    (fun h _ -> live h prod /\ live h pk /\ live h pos_list /\ live h sign_list /\ modifies1 prod h1 h /\
             encode_c_invariant h pos_list sign_list params_h /\ is_poly_pk h pk /\ is_poly_sparse_mul32_output h prod)
    (fun i ->
        let hPos = ST.get () in
        assert(is_poly_pk hPos pk);
        assert(v (bget hPos pos_list (v i)) < v params_n);
        let pos = pos_list.(i) in
	let sign_list_i = sign_list.(i) in
        let h2 = ST.get () in
	for 0ul pos
	(fun h _ -> live h prod /\ live h pk /\ modifies1 prod h2 h /\ is_poly_pk h pk /\ is_poly_sparse_mul32_output h prod)
	(fun j ->
            let h = ST.get () in
	    let pkItem = pk.(j +. params_n -. pos) in
            assume(FStar.Int.fits (I16.v sign_list_i * I32.v pkItem) I32.n);
            let hProd = ST.get () in
            assume(FStar.Int.fits (elem_v (bget hProd prod (v j)) - (I16.v sign_list_i * I32.v pkItem)) elem_n);
            assume(is_elem_int (elem_v (bget hProd prod (v j)) - (I16.v sign_list_i * I32.v pkItem)));
	    prod.(j) <- prod.(j) -^ int32_to_elem I32.( (int16_to_int32 sign_list_i) *^ pkItem );
            let hLoopEnd = ST.get () in
            assert(is_poly_equal h hLoopEnd pk);
            assert(forall (k:nat{k < v params_n /\ k <> v j}) . {:pattern bget hLoopEnd prod k} bget h prod k == bget hLoopEnd prod k);
            assume(is_sparse_mul32_output (bget hLoopEnd prod (v j)))
	);
        let h3 = ST.get () in
	for pos params_n
	(fun h _ -> live h prod /\ live h pk /\ modifies1 prod h3 h /\ is_poly_pk h pk /\ is_poly_sparse_mul32_output h prod)
	(fun j ->
            let h = ST.get () in
	    let pkItem = pk.(j -. pos) in
            assume(FStar.Int.fits (I16.v sign_list_i * I32.v pkItem) I32.n);
            let hProd = ST.get () in
            assume(FStar.Int.fits (elem_v (bget hProd prod (v j)) + (I16.v sign_list_i * I32.v pkItem)) elem_n);
            assume(is_elem_int (elem_v (bget hProd prod (v j)) + (I16.v sign_list_i * I32.v pkItem)));
	    prod.(j) <- prod.(j) +^ int32_to_elem I32.( (int16_to_int32 sign_list_i) *^ pkItem );
            let hLoopEnd = ST.get () in
            assert(is_poly_equal h hLoopEnd pk);
            assert(forall (k:nat{k < v params_n /\ k <> v j}) . {:pattern bget hLoopEnd prod k} bget h prod k == bget hLoopEnd prod k);
            assume(is_sparse_mul32_output (bget hLoopEnd prod (v j)))
	);
        let hOuterLoopEnd = ST.get () in
        assert(is_poly_equal hPos hOuterLoopEnd pk);
        assert(is_poly_pk hOuterLoopEnd pk)
    );

    let h4 = ST.get () in
    for 0ul params_n
    (fun h _ -> live h prod /\ modifies1 prod h4 h /\ is_poly_sparse_mul32_output h prod)
    (fun i -> 
        let hBefore = ST.get () in
        assert(is_poly_sparse_mul32_output hBefore prod);
        prod.(i) <- barr_reduce prod.(i);
        let hAfter = ST.get () in
        assert(forall (j:nat{j < v params_n /\ j <> v i}) . {:pattern bget hAfter prod j} bget hBefore prod j == bget hAfter prod j);
        assume(is_sparse_mul32_output (bget hAfter prod (v i)))
    );

    let hFinal = ST.get () in
    pop_frame();
    let hReturn = ST.get () in
    assert(is_poly_equal hFinal hReturn prod)

val test_rejection:
    z : poly
  -> Stack bool
    (requires fun h -> live h z /\ is_poly_pmq h z)
    (ensures fun h0 r h1 -> h0 == h1 /\ ((not r) ==> is_poly_z_accepted h1 z))

let test_rejection z =
    [@inline_let] let params_B = elem_to_int32 params_B in
    [@inline_let] let params_U = elem_to_int32 params_U in
    [@inline_let] let op_Subtraction_Hat = I32.op_Subtraction_Hat in
    [@inline_let] let op_Greater_Hat = I32.op_Greater_Hat in

    let h0 = ST.get () in
    let _, res =
    interruptible_for 0ul params_n
    (fun h i r -> live h z /\ h0 == h /\ modifies0 h0 h /\
               is_poly_pmq h z /\ i <= v params_n /\ ((not r) ==> is_poly_z_accepted_i h z i))
    (fun i ->
        let h = ST.get () in
        assert(is_pmq (bget h z (v i)));
        let zi:elem = z.(i) in
        let zVal:I32.t = elem_to_int32 zi in
	abs_ zVal >^ params_B -^ params_U
    ) in

    res

#reset-options "--z3rlimit 300 --max_fuel 0 --max_ifuel 0"

val test_correctness:
    v_ : poly
  -> Stack (r:I32.t{r == 0l \/ r == 1l})
    (requires fun h -> live h v_ /\ is_poly_montgomery h v_)
    (ensures fun h0 _ h1 -> modifies0 h0 h1)

let test_correctness v_ =
    let hInit = ST.get () in
    push_frame();
    let res = create (size 1) 0l in

    let h0 = ST.get () in
    assert(is_poly_equal hInit h0 v_);
    assert(is_poly_montgomery hInit v_);
    let _, _ = interruptible_for 0ul params_n
    (fun h _ _ -> live h v_ /\ modifies1 res h0 h /\ ((bget h res 0) == 0l \/ (bget h res 0) == 1l) /\
               is_poly_montgomery h v_)
    (fun i ->
        let h1 = ST.get () in
        assert(is_poly_montgomery h1 v_);
        assert(is_montgomery (bget h1 v_ (v i)));
        let mask0:elem = (params_q /^ (to_elem 2) -^ v_.(i)) in
        assert_norm(v (_RADIX32 -. size 1) < I32.n);
        let mask:I32.t = I32.((elem_to_int32 mask0) >>>^ (_RADIX32 -. size 1)) in
        let h2 = ST.get () in
        // TODO (kkane): A lot of this proof is repeated from check_ES_ordered_exchange_ct. I really should
        // extract these facts about masking into a lemma.
        lemma_mask mask0 mask;
        assert(mask == 0l \/ mask == (-1l));
        assert(I32.v mask == Int.zero I32.n \/ I32.v mask == Int.ones I32.n);
        let val_:elem = (((v_.(i) -^ params_q) &^ (int32_to_elem mask)) |^ (v_.(i) &^ (lognot (int32_to_elem mask)))) in
        Int.logand_lemma_1 (I32.v ((bget h2 v_ (v i)) -^ params_q));
        Int.logand_lemma_1 (I32.v (bget h2 v_ (v i)));
        Int.logand_lemma_2 (I32.v ((bget h2 v_ (v i)) -^ params_q));
        Int.logand_lemma_2 (I32.v (bget h2 v_ (v i)));
        lemma_int32_logor_zero (bget h2 v_ (v i));
        lemma_int32_logor_zero ((bget h2 v_ (v i)) -^ params_q);
        lemma_int32_lognot_zero mask;
        assert((mask == 0l) ==> (lognot mask == (-1l)));
        assert((mask == (-1l)) ==> (lognot mask == 0l));
        assert(val_ == (bget h1 v_ (v i)) -^ params_q \/ val_ == bget h1 v_ (v i));
        assert(elem_v val_ >= -(2 * elem_v params_q));
        assert(elem_v val_ <= 2 * elem_v params_q);
        let val_:I32.t = elem_to_int32 val_ in
        // From here on, we only use params_q and params_rejection in 32-bit operations, so "cast" them to int32_t.
        [@inline_let] let params_q = elem_to_int32 params_q in
        [@inline_let] let params_rejection = elem_to_int32 params_rejection in
        //assume(FStar.Int.fits (I32.v (abs_ val_) - I32.v (params_q /^ 2l -^ params_rejection)) I32.n);
        let t0:UI32.t = UI32.(int32_to_uint32 I32.(((lognot ((abs_ val_) -^ (params_q /^ 2l -^ params_rejection))))) >>^ (_RADIX32 -. size 1)) in
        let left:I32.t = val_ in
        assert_norm(v (params_d -. (size 1)) < I32.n);
        assume(FStar.Int.fits (I32.v val_ + I32.v (1l <<^ (params_d -. (size 1)))) I32.n);
        assume(FStar.Int.fits (I32.v val_ + I32.v (1l <<^ (params_d -. (size 1))) - 1) I32.n);
        let val_:I32.t = I32.((val_ +^ (1l <<^ (params_d -. (size 1))) -^ 1l) >>>^ params_d) in
        assume(I32.v val_ >= 0);
        assume(FStar.Int.fits (I32.v left - I32.v (val_ <<^ params_d)) I32.n);
        // val is always -1, 0, or 1 it looks like
        let val_:I32.t = I32.(left -^ (val_ <<^ params_d)) in
        assume(I32.v val_ > Int.min_int I32.n);
        assume(FStar.Int.fits (I32.v (1l <<^ (params_d -. (size 1))) - elem_v params_rejection) I32.n);
        assume(FStar.Int.fits (I32.v (abs_ val_) - (I32.v (1l <<^ (params_d -. (size 1))) - elem_v params_rejection)) I32.n);
        let t1:UI32.t = UI32.(int32_to_uint32 I32.(((lognot ((abs_ val_) -^ ((1l <<^ (params_d -. (size 1))) -^ params_rejection))))) >>^ (_RADIX32 -. size 1)) in
        let r = if UI32.((t0 |^ t1) = 1ul)
        then ( res.(size 0) <- 1l; true )
        else ( false ) in
        let hLoopEnd = ST.get() in
        assert(forall (i:nat{i < v params_n}) . {:pattern bget hLoopEnd v_ i} bget h1 v_ i == bget hLoopEnd v_ i);
        assert(is_poly_montgomery hLoopEnd v_);
        r
    ) in

    let resVal:I32.t = res.(size 0) in
    pop_frame();
    resVal

#reset-options "--z3rlimit 100 --max_fuel 0 --max_ifuel 0"

private inline_for_extraction noextract
val qtesla_sign_compute_v:
    v_: poly_k
  -> y: poly
  -> a: poly_k
  -> Stack unit
    (requires fun h -> let bufs = [bb v_; bb y; bb a] in 
                    BigOps.big_and (live_buf h) bufs /\ BigOps.pairwise_and disjoint_buf bufs /\
                    is_poly_k_montgomery h a /\ is_poly_y_sampler_output h y)
    (ensures fun h0 _ h1 -> modifies1 v_ h0 h1 /\ is_poly_k_montgomery h1 v_)

let qtesla_sign_compute_v v_ y a =
    push_frame();
    let y_ntt:poly = poly_create () in
    // ntt transformation only happens here in provable parameter sets because poly_mul assumes
    // both arguments are in ntt form. Heuristic parameter sets only assume the first parameter is in
    // ntt form. In this combined codebase poly_mul always assumes both arguments are in NTT form, so
    // we always convert y.
    poly_ntt y_ntt y;
    let h1 = ST.get () in
    for 0ul params_k
        (fun h _ -> live h v_ /\ live h a /\ live h y_ntt /\ modifies1 v_ h1 h)
        (fun k ->
            poly_mul (index_poly v_ k) (index_poly a k) y_ntt
        );
    pop_frame();
    let hReturn = ST.get () in
    assume(is_poly_k_montgomery hReturn v_)

private let lemma_poly_add_in_bounds (h: HS.mem) (y sc: poly) : Lemma
    (requires is_poly_y_sampler_output h y /\ is_poly_sparse_mul_output h sc)
    (ensures (forall (i:nat{i < v params_n}) . is_elem_int (elem_v (bget h y i) + elem_v (bget h sc i)))) = 
    assert(forall (i:nat{i < v params_n}) . is_y_sampler_output(bget h y i) /\ is_sparse_mul_output(bget h sc i))

private inline_for_extraction noextract
val qtesla_sign_compute_c_z:
    v_: poly_k
  -> randomness_input: lbuffer uint8 (crypto_randombytes +. crypto_seedbytes +. crypto_hmbytes)
  -> s: lbuffer sparse_elem params_n
  -> y: poly
  -> c: lbuffer uint8 crypto_c_bytes
  -> z: poly
  -> pos_list: lbuffer UI32.t params_h
  -> sign_list: lbuffer I16.t params_h
  -> Stack unit
    (requires fun h -> let bufs = [bb v_; bb randomness_input; bb s; bb y; bb c; bb z; bb pos_list; bb sign_list] in
                    BigOps.big_and (live_buf h) bufs /\ BigOps.pairwise_and disjoint_buf bufs /\
                    is_poly_y_sampler_output h y /\ is_poly_k_montgomery h v_ /\ is_s_sk h s)
    (ensures fun h0 _ h1 -> modifies4 c z pos_list sign_list h0 h1 /\ is_poly_pmq h1 z /\
                        encode_c_invariant h1 pos_list sign_list params_h)

let qtesla_sign_compute_c_z v_ randomness_input s y c z pos_list sign_list =
    let hInit = ST.get () in
    assert(is_poly_y_sampler_output hInit y);
    push_frame();
    let sc:poly = poly_create () in
    let h0 = ST.get () in
    assert(is_poly_k_equal hInit h0 v_);
    assert(is_poly_k_montgomery h0 v_);
    hash_H c v_ (sub randomness_input (crypto_randombytes +. crypto_seedbytes) crypto_hmbytes);
    encode_c pos_list sign_list c;
    let h1 = ST.get () in
    assert(forall (i:nat{i < v params_n}) . {:pattern bget h1 s i} bget hInit s i == bget h1 s i);
    lemma_is_s_still_sk hInit h1 s;
    assert(is_s_sk h1 s);
    sparse_mul sc s pos_list sign_list;
    let h2 = ST.get () in
    assert(is_poly_equal hInit h2 y);
    assert(is_poly_y_sampler_output h2 y);
    assert(is_poly_sparse_mul_output h2 sc);
    lemma_poly_add_in_bounds h2 y sc;
    poly_add z y sc;
    let hFinal = ST.get () in
    pop_frame();
    let hReturn = ST.get () in
    assert(is_poly_equal hFinal hReturn z)

private let lemma_sub_poly_is_sk 
    (h: HS.mem) 
    (e: lbuffer sparse_elem (params_n *. params_k)) 
    (s: lbuffer sparse_elem params_n)
    (k: size_t{v k < v params_k}) : Lemma
    (requires is_e_sk h e /\ s == gsub e (k *. params_n) params_n)
    (ensures is_s_sk h s) = 
    assume(forall (i:nat{i < v params_k * v params_n}) . is_sparse_elem_sk (bget h e i));
    assert(forall (i:nat{i < v params_n}) . bget h s i == bget h e (v k * v params_n + i));
    assert(forall (i:nat{i < v params_n}) . is_sparse_elem_sk (bget h s i))

private let lemma_sub_poly_is_montgomery
    (h: HS.mem) 
    (p: poly_k)
    (sp: poly)
    (k: size_t{v k < v params_k}) : Lemma
    (requires is_poly_k_montgomery h p /\ sp == gsub p (k *. params_n) params_n)
    (ensures is_poly_montgomery h sp) = 
    assert(forall (i:nat{i < v params_k * v params_n}) . is_montgomery (bget h p i));
    assert(forall (i:nat{i < v params_n}) . bget h sp i == bget h p (v k * v params_n + i));
    assert(forall (i:nat{i < v params_n}) . is_montgomery (bget h sp i))

private let lemma_disjoint 
    (ec: poly_k) 
    (e: lbuffer sparse_elem (params_n *. params_k))
    (ec_k: poly)
    (e_k: lbuffer sparse_elem params_n)
    (k: size_t{v k < v params_k}) : Lemma
    (requires disjoint ec e /\ ec_k == gsub ec (k *. params_n) params_n /\ e_k == gsub e (k *. params_n) params_n)
    (ensures disjoint ec_k e_k) = ()

private inline_for_extraction noextract
val qtesla_sign_update_v:
    v_: poly_k
  -> e: lbuffer sparse_elem (params_n *. params_k)
  -> pos_list: lbuffer UI32.t params_h
  -> sign_list: lbuffer I16.t params_h
  -> Stack (r:I32.t{r == 0l \/ r == 1l})
    (requires fun h -> let bufs = [bb v_; bb e; bb pos_list; bb sign_list] in
                    FStar.BigOps.big_and (live_buf h) bufs /\ FStar.BigOps.pairwise_and disjoint_buf bufs /\
                    encode_c_invariant h pos_list sign_list params_h /\ is_e_sk h e)
    (ensures fun h0 _ h1 -> modifies1 v_ h0 h1)

let qtesla_sign_update_v v_ e pos_list sign_list =
    let hInit = ST.get () in
    assert(is_e_sk hInit e);
    push_frame();
    let rsp = create (size 1) 0l in

    let h0 = ST.get () in
    assert(forall (i:nat{i < v params_n * v params_k}) . bget hInit e i == bget h0 e i);
    lemma_is_e_still_sk hInit h0 e;
    let _, _ =
    interruptible_for (size 0) params_k
         (fun h _ _ -> live h v_ /\ live h e /\ live h rsp /\ (bget h rsp 0 == 0l \/ bget h rsp 0 == 1l) /\
                    modifies2 v_ rsp h0 h /\ is_e_sk h e)
         (fun k ->
             let hStart = ST.get () in
             push_frame();
             let ec:poly_k = poly_k_create () in

             let ec_k = index_poly ec k in
             let e_k = sub e (k *. params_n) params_n in
             assert(e_k == gsub e (k *. params_n) params_n);
             let h = ST.get () in
             assert(forall (i:nat{i < v params_n * v params_k}) . bget hInit e i == bget h e i);
             lemma_is_e_still_sk hStart h e;
             assert(is_e_sk h e);
             lemma_sub_poly_is_sk h e e_k k;
             assert(is_s_sk h e_k);
             //NS: Not sure why this is not provable
             lemma_disjoint ec e ec_k e_k k;
             assert(disjoint ec_k e_k);
             assume(disjoint e_k pos_list);
             assume(disjoint e_k sign_list);
             sparse_mul ec_k e_k pos_list sign_list;
             poly_sub_correct (index_poly v_ k) (index_poly v_ k) (index_poly ec k);
             let hSub = ST.get () in
             assume(is_poly_k_montgomery hSub v_);
             lemma_sub_poly_is_montgomery hSub v_ (gsub v_ (k *. params_n) params_n) k;
             rsp.(size 0) <- test_correctness (index_poly v_ k);
             let rspVal = rsp.(size 0) in 
             pop_frame(); 
             let hLoopEnd = ST.get () in
             lemma_is_e_still_sk hStart hLoopEnd e;
             rspVal <> 0l
         ) in
   let rspVal = rsp.(size 0) in
   pop_frame();
   rspVal

#reset-options "--z3rlimit 500 --max_fuel 0 --max_ifuel 0"

private inline_for_extraction noextract
val qtesla_sign_do_while:
    randomness: lbuffer uint8 crypto_seedbytes
  -> randomness_input: lbuffer uint8 (crypto_randombytes +. crypto_seedbytes +. crypto_hmbytes)
  -> nonce: lbuffer UI32.t (size 1)
  -> a: poly_k
  -> s: lbuffer sparse_elem params_n
  -> e: lbuffer sparse_elem (params_n *. params_k)
  -> smlen : lbuffer size_t 1ul // smlen only valid on output; does _not_ indicate allocated size of sm on input
  -> mlen : size_t{v mlen > 0 /\ v crypto_bytes + v mlen < modulus U32}
  -> m : lbuffer uint8 mlen
  -> sm: lbuffer uint8 (crypto_bytes +. mlen)
  -> Stack bool
    (requires fun h -> 
      let bufs =
        [bb randomness; 
         bb randomness_input;
         bb nonce;
         bb a;
         bb s;
         bb e;
         bb smlen;
         bb m;
         bb sm]      
      in
      BigOps.big_and (live_buf h) bufs /\
      BigOps.pairwise_and disjoint_buf bufs /\
      UI32.v (bget h nonce 0) >= 0 /\
      is_poly_k_montgomery h a /\ is_s_sk h s /\ is_e_sk h e)
    (ensures fun h0 _ h1 -> modifies3 nonce smlen sm h0 h1)

// -LowStar.Monotonic.Buffer.unused_in_not_unused_in_disjoint_2
#reset-options "--z3rlimit 1000 --max_fuel 0 --max_ifuel 0 \
                --using_facts_from '*  -FStar.Monotonic.Heap.equal_dom -LowStar.Monotonic.Buffer.unused_in_not_unused_in_disjoint_2'"
//                --using_facts_from '*  -FStar.Monotonic.Heap.equal_dom'"
//                --using_facts_from '* -LowStar.Monotonic.Buffer.unused_in_not_unused_in_disjoint_2'"
// --log_queries --query_stats --print_z3_statistics 

let qtesla_sign_do_while randomness randomness_input nonce a s e smlen mlen m sm =
    let hInit = ST.get () in
    push_frame();
    let c = create crypto_c_bytes (u8 0) in
    let z:poly = poly_create () in
    let y:poly = poly_create () in
    let v_:poly_k = poly_k_create () in 
    let rsp = create (size 1) 0l in
    let pos_list = create params_h 0ul in
    let sign_list = create params_h 0s in

    //TODO NS: to prove the assume below, we need to use 
    // LowStar.Monotonic.Buffer.unused_in_not_unused_in_disjoint_2
    //but that's really expensive in this context
    //It's probably worth factoring out a proof of this fact below
    //until we can improve that lemma
    assume (FStar.BigOps.pairwise_and 
                  disjoint_buf 
                  [bb randomness;
                   bb randomness_input;
                   bb nonce;
                   bb a;
                   bb s;
                   bb e;
                   bb smlen;
                   bb m;
                   bb sm;
                   bb c;
                   bb z;
                   bb y;
                   bb v_;
                   bb rsp;
                   bb pos_list;
                   bb sign_list]);

    let h0 = ST.get () in
    assert(modifies0 h0 h0);
    
    nonce.(size 0) <- UI32.(nonce.(size 0) +%^ 1ul);
    sample_y y randomness nonce.(size 0);

    let h1 = ST.get () in
    assert(modifies2 y nonce h0 h1);
    assert(is_poly_k_equal hInit h1 a); // for is_poly_k_montgomery h1 a
    qtesla_sign_compute_v v_ y a;

    let h2 = ST.get () in
    assert(modifies3 v_ y nonce h0 h2);
    assert(is_poly_equal h1 h2 y); // for is_poly_y_sampler_output h2 y
    assert(forall (i:nat{i < v params_n}) . bget h2 s i == bget hInit s i); // for is_s_sk h2 s
    lemma_is_s_still_sk hInit h2 s;

//is_poly_k_corrected h v_ /\ is_s_sk h s
    qtesla_sign_compute_c_z v_ randomness_input s y c z pos_list sign_list;
    let h3 = ST.get () in
    assert(modifies (loc c |+| loc z |+| loc v_ |+| loc y |+| loc nonce |+| loc pos_list |+| loc sign_list) h0 h3);
    assert(forall (i:nat{i < v params_n * v params_k}) . bget h3 e i == bget hInit e i); // for is_e_sk h3 e
    lemma_is_e_still_sk hInit h3 e;

    let res = 
    if test_rejection z
    then (false)
    else (
         let rspVal = qtesla_sign_update_v v_ e pos_list sign_list in
         if (rspVal <> 0l)
         then (false)
         else (
              let h4 = ST.get () in
              for 0ul mlen
              (fun h _ -> live h sm /\ live h m /\ modifies1 sm h4 h)
              (fun i -> let ix = crypto_bytes +. i in
                     assert (length sm == v (crypto_bytes +. mlen));
                     assert (v i < v mlen);
                     sm.(ix) <- m.(i) );

              let h5 = ST.get () in
              assert(modifies (loc sm |+| loc c |+| loc z |+| loc v_ |+| loc y |+| loc nonce |+| loc pos_list |+| loc sign_list) h0 h5);

              smlen.(size 0) <- crypto_bytes +. mlen;
              let h6 = ST.get () in
              assert(modifies (loc smlen |+| loc sm |+| loc c |+| loc z |+| loc v_ |+| loc y |+| loc nonce |+| loc pos_list |+| loc sign_list) h0 h6);
              
              encode_sig (sub sm (size 0) crypto_bytes) c z;
              let h7 = ST.get () in
              assert(modifies (loc smlen |+| loc sm |+| loc c |+| loc z |+| loc v_ |+| loc y |+| loc nonce |+| loc pos_list |+| loc sign_list) h0 h7);

              true
              )
        ) in
    let h8 = ST.get () in
    assert(modifies (loc smlen |+| loc sm |+| loc c |+| loc z |+| loc v_ |+| loc y |+| loc nonce |+| loc pos_list |+| loc sign_list) h0 h8);
    pop_frame(); 
    let hn = ST.get() in
    // TODO: Asserting this requires FStar.Monotonic.Heap.equal_dom to be included, but this lemma really slows the
    // proof down.
    assume (modifies3 nonce smlen sm hInit hn);
    res

//#reset-options "--z3rlimit 100 --max_fuel 0 --max_ifuel 0"

val qtesla_sign:
    smlen : lbuffer size_t 1ul // smlen only valid on output; does _not_ indicate allocated size of sm on input
  -> mlen : size_t{v mlen > 0 /\ v crypto_bytes + v mlen < modulus U32}
  -> m : lbuffer uint8 mlen
  -> sm: lbuffer uint8 (crypto_bytes +. mlen)
  -> sk : lbuffer uint8 crypto_secretkeybytes
  -> Stack unit
    (requires fun h -> let bufs = [bb smlen; bb m; bb sm; bb sk] in
                    BigOps.big_and (live_buf h) bufs /\
                    BigOps.pairwise_and disjoint_buf bufs /\
                    disjoint R.state smlen /\ disjoint R.state m /\ disjoint R.state sm /\ disjoint R.state sk)
    (ensures fun h0 _ h1 -> modifies3 R.state sm smlen h0 h1)

// --log_queries --query_stats --print_z3_statistics 
#reset-options "--z3rlimit 300 --max_fuel 0 --max_ifuel 0  --admit_smt_queries true \
                --using_facts_from '* -LowStar.Monotonic.Buffer.unused_in_not_unused_in_disjoint_2'"

let qtesla_sign smlen mlen m sm sk =
    recall R.state;
    push_frame();

    let randomness = create crypto_seedbytes (u8 0) in
    let randomness_input = create (crypto_randombytes +. crypto_seedbytes +. crypto_hmbytes) (u8 0) in
    let a:poly_k = poly_k_create () in
    let seeds = create (size 2 *. crypto_seedbytes) (u8 0) in
    let (s:lbuffer sparse_elem params_n) = create params_n (to_sparse_elem 0) in
    let e = create (params_n *. params_k) (to_sparse_elem 0) in
    let nonce = create (size 1) 0ul in

    // TODO: requires expensive LowStar.Monotonic.Buffer.unused_in_not_unused_in_disjoint_2 lemma
    assume (FStar.BigOps.pairwise_and 
                  disjoint_buf 
                  [bb smlen;
                   bb m;
                   bb sm;
                   bb sk;
                   bb randomness;
                   bb randomness_input;
                   bb nonce;
                   bb a;
                   bb s;
                   bb e;
                   bb seeds]);

    let h0 = ST.get () in
    assert(modifies0 h0 h0);
    decode_sk seeds s e sk;

    let h1 = ST.get () in
    assert(modifies3 seeds s e h0 h1);
    
    R.randombytes_ crypto_randombytes (sub randomness_input crypto_randombytes crypto_randombytes);
    update_sub randomness_input (size 0) crypto_seedbytes (sub seeds crypto_seedbytes crypto_seedbytes);
    params_SHAKE mlen m crypto_hmbytes (sub randomness_input (crypto_randombytes +. crypto_seedbytes) crypto_hmbytes);
    params_SHAKE (crypto_randombytes +. crypto_seedbytes +. crypto_hmbytes) randomness_input crypto_seedbytes randomness;

    let h2 = ST.get () in
    assert(modifies (loc seeds |+| loc s |+| loc e |+| loc randomness |+| loc randomness_input |+| loc R.state) h0 h2);

    poly_uniform a (sub seeds (size 0) crypto_randombytes);

    let h3 = ST.get () in
    assert(modifies (loc seeds |+| loc s |+| loc e |+| loc randomness |+| loc randomness_input |+| loc R.state |+| loc a) h0 h3);
    lemma_is_s_still_sk h1 h3 s;
    lemma_is_e_still_sk h1 h3 e;
    
    do_while
        (fun h _ -> let bufs = [bb smlen; bb m; bb sm; bb s; bb e; bb randomness; bb randomness_input; bb a; bb nonce] in
                 FStar.BigOps.big_and (live_buf h) bufs /\ modifies3 nonce smlen sm h3 h /\ is_poly_k_montgomery h a /\
                 is_s_sk h s /\ is_e_sk h e)
        (fun _ -> 
            let h4 = ST.get () in
            //assume(FStar.Int.fits (I32.v (bget h4 nonce 0) + 1) I32.n);
            qtesla_sign_do_while randomness randomness_input nonce a s e smlen mlen m sm
        );

    let h5 = ST.get () in
    assert(modifies (loc seeds |+| loc s |+| loc e |+| loc randomness |+| loc randomness_input |+| loc R.state |+| loc a |+|
                     loc nonce |+| loc smlen |+| loc sm) h0 h5);
    
    pop_frame()

//#reset-options "--z3rlimit 100 --max_fuel 0 --max_ifuel 0"

val test_z:
    z : poly
  -> Stack (r:I32.t{r == 0l \/ r == 1l})
    (requires fun h -> live h z)
    (ensures fun h0 _ h1 -> h0 == h1)

let test_z z =
    let h0 = ST.get () in
    let _ , res = interruptible_for 0ul params_n
    (fun h _ _ -> live h z /\ h0 == h)
    (fun i ->
        let zi = z.(i) in
        zi <^ to_elem (-1) *^ (params_B -^ params_U) || zi >^ (params_B -^ params_U)
    ) in
    if res
    then 1l
    else 0l

private let lemma_subpoly_of_pk_is_pk (h: HS.mem) (pk: poly_k) (p: poly) (k: size_t{v k < v params_k}) : Lemma
    (requires is_poly_k_pk h pk /\ p == gsub pk (k *. params_n) params_n)
    (ensures is_poly_pk h p) = ()

private inline_for_extraction noextract
val qtesla_verify_decode_pk_compute_w:
    pk: lbuffer uint8 crypto_publickeybytes
  -> c: lbuffer uint8 crypto_c_bytes
  -> z: poly
  -> w: poly_k
  -> Stack unit
    (requires fun h -> let bufs = [bb pk; bb c; bb z; bb w] in
                    BigOps.big_and (live_buf h) bufs /\ BigOps.pairwise_and disjoint_buf bufs)
    (ensures fun h0 _ h1 -> modifies1 w h0 h1 /\ is_poly_k_montgomery h1 w)

//  --log_queries --query_stats --print_z3_statistics 
#reset-options "--z3rlimit 300 --max_fuel 0 --max_ifuel 1 \
                --using_facts_from '* -LowStar.Monotonic.Buffer.unused_in_not_unused_in_disjoint_2'"

let qtesla_verify_decode_pk_compute_w pk c z w =
    push_frame();
    let seed = create crypto_seedbytes (u8 0) in
    let pos_list = create params_h 0ul in
    let sign_list = create params_h 0s in
    let pk_t = create (params_n *. params_k) 0l in
    let z_ntt = poly_create () in
    let tc = poly_k_create () in
    let a = poly_k_create () in

    let h0 = ST.get () in
    assert(modifies0 h0 h0);

    // TODO: requires expensive LowStar.Monotonic.Buffer.unused_in_not_unused_in_disjoint_2 lemma
    assume (FStar.BigOps.pairwise_and 
                  disjoint_buf
                  [bb pk;
                   bb c;
                   bb z;
                   bb w;
                   bb seed;
                   bb pos_list;
                   bb sign_list;
                   bb pk_t;
                   bb z_ntt;
                   bb tc;
                   bb a]);

    decode_pk pk_t seed pk;
    let hAfterDecode = ST.get () in
    assert(is_poly_k_pk hAfterDecode pk_t);
    poly_uniform a seed;
    let hAfterPolyUniform = ST.get () in
    assert(is_poly_k_montgomery hAfterPolyUniform a);
    encode_c pos_list sign_list c;
    poly_ntt z_ntt z; 

    let h1 = ST.get () in
    // All buffers in this stack frame.
    assert(modifies (loc pk_t |+| loc seed |+| loc a |+| loc pos_list |+| loc sign_list |+| loc z_ntt) h0 h1);
    assert(forall (i:nat{i < v params_n * v params_k}) . bget hAfterDecode pk_t i == bget h1 pk_t i);
    assert(is_poly_k_pk h1 pk_t);
    assert(is_poly_k_equal hAfterPolyUniform h1 a);

    for 0ul params_k
    (fun h k -> live h w /\ live h a /\ live h z_ntt /\ live h tc /\ live h pk_t /\ live h pos_list /\ live h sign_list /\
             modifies2 w tc h1 h /\ is_poly_k_pk h pk_t /\ encode_c_invariant h pos_list sign_list params_h /\
             is_poly_k_montgomery h a /\ k <= v params_k /\ is_poly_k_montgomery_i h w (k * v params_n))
    (fun k ->
        let hBegin = ST.get () in
        poly_mul (index_poly w k) (index_poly a k) z_ntt;
        let hAfterMul = ST.get () in
        assume(is_poly_montgomery hAfterMul (get_poly w k));
        let tc_k = index_poly tc k in
        let pk_t_k = sub pk_t (k *. params_n) params_n in
        assert(disjoint tc pk_t);
        //loc_disjoint_includes (loc tc) (loc pk_t) (loc tc_k) (loc pk_t_k);
        let h = ST.get () in
        // TODO: No idea why the prover can't prove these subbuffers are disjoint.
        assume(let bufs = [bb tc_k; bb pk_t_k; bb pos_list; bb sign_list] in
               FStar.BigOps.pairwise_and disjoint_buf bufs);
        //sparse_mul32 (index_poly tc k) (sub pk_t (k *. params_n) params_n) pos_list sign_list;
        //assume(forall i . {:pattern v (bget h pos_list i)} v (bget h pos_list i) < v params_n);
        assert(forall (i:nat{i < v params_n * v params_k}) . bget hBegin pk_t i == bget h pk_t i);
        assert(is_poly_k_pk h pk_t);
        lemma_subpoly_of_pk_is_pk h pk_t pk_t_k k;
        sparse_mul32 tc_k pk_t_k pos_list sign_list;
        assert(is_poly_montgomery h (get_poly w k));
        //let wk = index_poly w k in
        let hIndex = ST.get () in
        assert(is_poly_equal h hIndex (get_poly w k));
        assert(is_poly_montgomery hIndex (get_poly w k));
        poly_sub_reduce (index_poly w k) (index_poly w k) tc_k;
        let hEnd = ST.get () in
        assert(is_poly_k_montgomery_i hEnd w (v k * v params_n));
        assert(is_poly_montgomery hEnd (get_poly w k));
        let pTest = get_poly w k in
        assert(is_montgomery (bget hEnd pTest 0));
        assert(forall (i:nat{i < v k * v params_n}) . is_montgomery (bget hEnd w i));
        assume(forall (i:nat{i >= v k * v params_n /\ i < v k * v params_n + v params_n}) . is_montgomery (bget hEnd w i));
        assert(is_poly_k_montgomery_i hEnd w (((v k) + 1) * v params_n));
        assert(is_poly_k_equal hBegin hEnd a);
        assert(is_poly_k_montgomery hEnd a);
        assert(forall (i:nat{i < v params_n * v params_k}) . bget hBegin pk_t i == bget hEnd pk_t i);
        assert(is_poly_k_pk hEnd pk_t)
    );

    let h2 = ST.get () in
    assert(is_poly_k_montgomery h2 w);
    assert(modifies (loc w |+| loc tc |+| loc pk_t |+| loc seed |+| loc a |+| loc pos_list |+| loc sign_list |+| loc z_ntt) h0 h2);

    pop_frame();
    let hReturn = ST.get () in
    assert(is_poly_k_equal h2 hReturn w)

// Bring those expensive disjointness lemmas back into scope because they're fine for the following.
#reset-options "--z3rlimit 100 --max_fuel 0 --max_ifuel 1" 
//  --log_queries --query_stats --print_z3_statistics"

private inline_for_extraction noextract
val qtesla_verify_valid_z:
    smlen : size_t{v smlen >= v crypto_bytes}
  -> sm : lbuffer uint8 smlen
  -> pk : lbuffer uint8 crypto_publickeybytes
  -> c : lbuffer uint8 crypto_c_bytes
  -> z : poly
  -> Stack bool
    (requires fun h -> let bufs = [bb sm; bb pk; bb c; bb z] in
                    FStar.BigOps.big_and (live_buf h) bufs /\ FStar.BigOps.pairwise_and disjoint_buf bufs)
    (ensures fun h0 _ h1 -> modifies0 h0 h1)

let qtesla_verify_valid_z smlen sm pk c z =
    push_frame();

    let hm = create crypto_hmbytes (u8 0) in
    let w = poly_k_create () in
    //let w = create (params_n *. params_k) (to_elem 0) in // poly_k_create () in
    let c_sig = create crypto_c_bytes (u8 0) in

    let h0 = ST.get () in
    assert(modifies0 h0 h0);
    
    qtesla_verify_decode_pk_compute_w pk c z w;
    let h1 = ST.get () in
    assert(modifies3 c z w h0 h1);
    assert(is_poly_k_montgomery h1 w);

    assert(v (smlen -. crypto_bytes) == v smlen - v crypto_bytes);
    params_SHAKE (smlen -. crypto_bytes) (sub sm crypto_bytes (smlen -. crypto_bytes)) crypto_hmbytes hm;
    let h2 = ST.get () in
    assert(modifies4 hm c z w h0 h2);
    assert(is_poly_k_equal h1 h2 w);
    assert(is_poly_k_montgomery h2 w);
    hash_H c_sig w hm;
    let h3 = ST.get () in
    assert(modifies (loc c_sig |+| loc hm |+| loc c |+| loc z |+| loc w) h0 h3);

    // TODO perf: lbytes_eq iterates over the entire buffer no matter what, which we don't need. memcmp would be fine since
    // this is all public data. Not yet determined if there's a construct which extracts as memcmp.
    // So we may do unnecessary work but it's still correct.
    let r = lbytes_eq c c_sig in
    pop_frame();
    r

val qtesla_verify:
    mlen : lbuffer size_t 1ul
  -> smlen : size_t{FStar.Int.fits (v crypto_bytes + v smlen) I32.n}
  -> m : lbuffer uint8 (smlen -. crypto_bytes)
  -> sm : lbuffer uint8 smlen
  -> pk : lbuffer uint8 crypto_publickeybytes
  -> Stack (r:I32.t{r == 0l \/ r == (-1l) \/ r == (-2l) \/ r == (-3l)})
    (requires fun h -> let bufs = [bb mlen; bb m; bb sm; bb pk] in
                    FStar.BigOps.big_and (live_buf h) bufs /\ FStar.BigOps.pairwise_and disjoint_buf bufs)
    (ensures fun h0 _ h1 -> modifies2 mlen m h0 h1)

let qtesla_verify mlen smlen m sm pk =

    // Can't return from the middle of a function in F*, so instead we use this if-then-else structure where
    // the else is the entire rest of the function after the return statement.
    if smlen <. crypto_bytes then ( -1l ) else (
    push_frame();
    let c = create crypto_c_bytes (u8 0) in
    let z = poly_create () in

    let h0 = ST.get () in
    assert(modifies0 h0 h0);
    
    decode_sig c z (sub sm (size 0) crypto_bytes); 
    let h1 = ST.get () in
    assert(modifies2 c z h0 h1);
    if test_z z <> 0l then ( pop_frame(); -2l ) else (
    if not (qtesla_verify_valid_z smlen sm pk c z) then ( pop_frame(); -3l ) else (
    [@inline_let] let mlenVal = smlen -. crypto_bytes in
    mlen.(size 0) <- mlenVal;
    let h5 = ST.get () in
    assert(modifies3 mlen c z h0 h5);
    for 0ul mlenVal
    (fun h _ -> live h m /\ live h sm /\ modifies1 m h5 h)
    (fun i -> 
        assert(v mlenVal <= v smlen);
        assert(FStar.Int.fits (v crypto_bytes + v i) I32.n);
        [@inline_let] let smIndex = crypto_bytes +. i in
        assert(v smIndex == v crypto_bytes + v i);
        assert(v mlenVal == v smlen - v crypto_bytes);
        assert(v smIndex < v smlen);
        m.(i) <- sm.(crypto_bytes +. i) );

    let h6 = ST.get () in
    assert(modifies4 m mlen c z h0 h6);
    
    pop_frame();
    0l
    )))

/// NIST required API wrappers

// API is identical here. Although defining "let crypto_sign_keypair = qtesla_keygen" causes KreMLin to extract
// crypto_sign_keypair as a function pointer pointing to qtesla_keygen; this way gives us an actual wrapper.
let crypto_sign_keypair pk sk = qtesla_keygen pk sk

val crypto_sign:
    sm : buffer uint8
  -> smlen : lbuffer UI64.t 1ul
  -> m : buffer uint8
  -> mlen : UI64.t{length m = v mlen /\ length sm = v crypto_bytes + UI64.v mlen /\ v mlen > 0 /\ v crypto_bytes + v mlen < modulus U32}
  -> sk : lbuffer uint8 crypto_secretkeybytes
  -> Stack (r:I32.t{r == 0l})
    (requires fun h -> live h sm /\ live h smlen /\ live h m /\ live h sk /\
                    disjoint R.state sm /\ disjoint R.state smlen /\ disjoint R.state m /\ disjoint R.state sk /\
                    disjoint sm smlen /\ disjoint sm m /\ disjoint sm sk /\
                    disjoint smlen m /\ disjoint smlen sk /\ 
                    disjoint m sk)
    (ensures fun h0 _ h1 -> modifies3 R.state sm smlen h0 h1)

let crypto_sign sm smlen m mlen sk =
    recall R.state;
    push_frame();
    let smlen_sizet = create (size 1) (size 0) in
    assert(disjoint R.state smlen_sizet);
    qtesla_sign smlen_sizet (uint64_to_uint32 mlen) m sm sk;
    let smlen_sizet = smlen_sizet.(size 0) in
    smlen.(size 0) <- uint32_to_uint64 smlen_sizet;
    pop_frame();
    0l

val crypto_sign_open:
    m : buffer uint8
  -> mlen : lbuffer UI64.t 1ul
  -> sm : buffer uint8
  -> smlen : UI64.t{length sm = v smlen /\ length m = UI64.v smlen - v crypto_bytes /\ 
                   FStar.Int.fits (v crypto_bytes + v smlen) Int32.n}
  -> pk : lbuffer uint8 crypto_publickeybytes
  -> Stack (r:I32.t{r == 0l \/ r == (-1l) \/ r == (-2l) \/ r == (-3l)})
    (requires fun h -> live h m /\ live h mlen /\ live h sm /\ live h pk /\
                    disjoint m mlen /\ disjoint m sm /\ disjoint m pk /\
                    disjoint mlen sm /\ disjoint mlen pk /\
                    disjoint sm pk)
    (ensures fun h0 _ h1 -> modifies2 m mlen h0 h1)

let crypto_sign_open m mlen sm smlen pk =
    push_frame();
    let smlen = Lib.RawIntTypes.size_from_UInt32 (uint64_to_uint32 smlen) in
    let mlen_sizet = create (size 1) (size 0) in
    let res = qtesla_verify mlen_sizet smlen m sm pk in
    let mlen_sizet = mlen_sizet.(size 0) in
    mlen.(size 0) <- uint32_to_uint64 mlen_sizet;
    pop_frame();
    res