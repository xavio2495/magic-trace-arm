open! Core

(** OCaml bindings to the OpenCSD library for decoding ARM CoreSight ETM traces.

    Typical usage:
    {[
      let arch = Opencsd_decoder.Arch.of_platform_arch (Platform.detect_arch () |> ok_exn) in
      let dec  = Opencsd_decoder.create ~trace_id:0 ~arch in
      Opencsd_decoder.add_image dec ~filename:"/usr/bin/myapp"
        ~load_address:0x400000L ~offset:0L ~size:0x10000L
      |> ok_exn;
      Opencsd_decoder.decode dec ~data ~offset:0 ~len:(Bytes.length data)
        ~data_index:0L
      |> ok_exn
      |> ignore;
      Opencsd_decoder.flush dec |> ok_exn;
      let events = Opencsd_decoder.drain_events dec in
      ...
    ]}
*)

(** Decoded trace event types. *)
module Event : sig
  module Kind : sig
    type t =
      | Instruction_range
      | Call
      | Return
      | Trace_on
      | Trace_off
      | Exception
      | Exception_ret
    [@@deriving sexp_of, compare, equal]

    val of_int : int -> t
  end

  type t =
    { kind : Kind.t
    ; timestamp : Int64.t
    ; from_addr : Int64.t
    ; to_addr : Int64.t
    ; cpu : int
    ; exception_number : int
    }
  [@@deriving sexp_of]
end

(** ARM ETM protocol / architecture selection. *)
module Arch : sig
  type t =
    | Etmv3
    | Etmv4
    | Ete
  [@@deriving sexp_of, compare, equal]

  val to_int : t -> int
  val of_platform_arch : Platform.arch -> t
end

(** Opaque decoder handle. *)
type t

val create : trace_id:int -> arch:Arch.t -> t

val add_image
  :  t
  -> filename:string
  -> load_address:int64
  -> offset:int64
  -> size:int64
  -> unit Or_error.t

val decode
  :  t
  -> data:bytes
  -> offset:int
  -> len:int
  -> data_index:int64
  -> int Or_error.t

val flush : t -> unit Or_error.t
val next_event : t -> Event.t option
val drain_events : t -> Event.t list
val has_error : t -> bool
val error_msg : t -> string
