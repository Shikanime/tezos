(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

let decimals = 3

type fp_tag

type integral_tag

module S = Saturation_repr

(*

   When a saturated integer is sufficiently small (i.e. strictly less
   than 2147483648), we can assign it the type [mul_safe S.t] to use
   it within fast multiplications, named [S.scale_fast] and
   [S.mul_fast].

   The following function allows such type assignment but may raise an
   exception if the assumption is wrong.  Therefore, [assert_mul_safe]
   should only be used to define toplevel values, so that these
   exceptions can only occur during startup.

*)
let assert_mul_safe_exn x =
  match S.mul_safe x with None -> assert false | Some x -> x

(*

   Similarly as [assert_mul_safe_exn], [safe_const_exn] must only be applied
   to integer literals that are small enough for fast multiplications.

*)
let safe_const_exn x =
  match S.of_int_opt x with
  | None ->
      (* Since [safe_const_exn] is only applied to small integers: *)
      assert false
  | Some x ->
      assert_mul_safe_exn x

let scaling_factor = safe_const_exn 1000

module Arith = struct
  type 'a t = S.may_saturate S.t

  type fp = fp_tag t

  type integral = integral_tag t

  let scaling_factor = scaling_factor

  let sub = S.sub

  let add = S.add

  let zero = S.(may_saturate zero)

  let min = S.min

  let max = S.max

  let compare = S.compare

  let ( < ) = S.( < )

  let ( <> ) = S.( <> )

  let ( > ) = S.( > )

  let ( <= ) = S.( <= )

  let ( >= ) = S.( >= )

  let ( = ) = S.( = )

  let equal = S.equal

  let of_int_opt = S.of_int_opt

  let fatally_saturated_int i =
    failwith (string_of_int i ^ " should not be saturated.")

  let fatally_saturated_z z =
    failwith (Z.to_string z ^ " should not be saturated.")

  let integral_of_int_exn i =
    S.(
      match of_int_opt i with
      | None ->
          fatally_saturated_int i
      | Some i' ->
          let r = scale_fast scaling_factor i' in
          if r = saturated then fatally_saturated_int i else r)

  let integral_exn z =
    match Z.to_int z with
    | i ->
        integral_of_int_exn i
    | exception Z.Overflow ->
        fatally_saturated_z z

  let integral_to_z (i : integral) : Z.t = S.(to_z (ediv i scaling_factor))

  let ceil x =
    let r = S.erem x scaling_factor in
    if r = zero then x else add x (sub scaling_factor r)

  let floor x = sub x (S.erem x scaling_factor)

  let fp x = x

  let pp fmtr fp =
    let q = S.(ediv fp scaling_factor |> to_int) in
    let r = S.(erem fp scaling_factor |> to_int) in
    if Compare.Int.(r = 0) then Format.fprintf fmtr "%d" q
    else Format.fprintf fmtr "%d.%0*d" q decimals r

  let pp_integral = pp

  let n_fp_encoding : fp Data_encoding.t = S.n_encoding

  let z_fp_encoding : fp Data_encoding.t = S.z_encoding

  let n_integral_encoding : integral Data_encoding.t =
    Data_encoding.conv integral_to_z integral_exn Data_encoding.n

  let z_integral_encoding : integral Data_encoding.t =
    Data_encoding.conv integral_to_z integral_exn Data_encoding.z

  let unsafe_fp x =
    match of_int_opt (Z.to_int x) with
    | Some int ->
        int
    | None ->
        fatally_saturated_z x

  let sub_opt = S.sub_opt
end

type t = Unaccounted | Limited of {remaining : Arith.fp}

type cost = S.may_saturate S.t

let encoding =
  let open Data_encoding in
  union
    [ case
        (Tag 0)
        ~title:"Limited"
        Arith.z_fp_encoding
        (function Limited {remaining} -> Some remaining | _ -> None)
        (fun remaining -> Limited {remaining});
      case
        (Tag 1)
        ~title:"Unaccounted"
        (constant "unaccounted")
        (function Unaccounted -> Some () | _ -> None)
        (fun () -> Unaccounted) ]

let pp ppf = function
  | Unaccounted ->
      Format.fprintf ppf "unaccounted"
  | Limited {remaining} ->
      Format.fprintf ppf "%a units remaining" Arith.pp remaining

let cost_encoding = S.z_encoding

let pp_cost fmt z = S.pp fmt z

let allocation_weight =
  S.(mul_fast scaling_factor (safe_const_exn 2)) |> assert_mul_safe_exn

let step_weight = scaling_factor

let read_base_weight =
  S.(mul_fast scaling_factor (safe_const_exn 100)) |> assert_mul_safe_exn

let write_base_weight =
  S.(mul_fast scaling_factor (safe_const_exn 160)) |> assert_mul_safe_exn

let byte_read_weight =
  S.(mul_fast scaling_factor (safe_const_exn 10)) |> assert_mul_safe_exn

let byte_written_weight =
  S.(mul_fast scaling_factor (safe_const_exn 15)) |> assert_mul_safe_exn

let cost_to_milligas (cost : cost) : Arith.fp = cost

let raw_consume gas_counter cost =
  let gas = cost_to_milligas cost in
  Arith.sub_opt gas_counter gas

let alloc_cost n = S.scale_fast allocation_weight S.(add n (safe_const_exn 1))

let alloc_bytes_cost n = alloc_cost (S.safe_int ((n + 7) / 8))

let atomic_step_cost : 'a S.t -> cost = S.may_saturate

let step_cost n = S.scale_fast step_weight n

let free = S.zero

let read_bytes_cost n =
  S.add read_base_weight (S.scale_fast byte_read_weight (S.safe_int n))

let write_bytes_cost n =
  S.add write_base_weight (S.scale_fast byte_written_weight (S.safe_int n))

let ( +@ ) x y = S.add x y

let ( *@ ) x y = S.mul x y

let alloc_mbytes_cost n = alloc_cost (safe_const_exn 12) +@ alloc_bytes_cost n
