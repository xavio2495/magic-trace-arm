open! Core

(** Decoded event kinds produced by the OpenCSD decode pipeline.
    These map 1-to-1 with [mtrace_cs_event_kind_t] in opencsd_binding.h. *)
module Event = struct
  module Kind = struct
    type t =
      | Instruction_range (** A run of sequential instructions with no branch. *)
      | Call (** Direct or indirect branch (call-like). *)
      | Return (** Indirect branch treated as function return. *)
      | Trace_on (** Trace was enabled / resumed on this CPU. *)
      | Trace_off (** Trace was disabled / lost on this CPU. *)
      | Exception (** CPU took an exception (interrupt, fault, etc.). *)
      | Exception_ret (** ERET — return from exception. *)
    [@@deriving sexp_of, compare, equal]

    let of_int = function
      | 0 -> Instruction_range
      | 1 -> Call
      | 2 -> Return
      | 3 -> Trace_on
      | 4 -> Trace_off
      | 5 -> Exception
      | 6 -> Exception_ret
      | n -> failwithf "Opencsd_decoder.Event.Kind.of_int: unknown kind %d" n ()
    ;;
  end

  type t =
    { kind : Kind.t
    ; timestamp : Int64.t
      (** Nanosecond timestamp from the ETM timestamp counter.
              0 if the ETM was not configured to emit timestamps. *)
    ; from_addr : Int64.t (** Start address of the instruction range / branch source. *)
    ; to_addr : Int64.t
      (** End address (exclusive) for [Instruction_range]; branch
              target for [Call]/[Return].  0 for other kinds. *)
    ; cpu : int (** CPU index that generated this trace element, or [-1] if unknown. *)
    ; exception_number : int (** Exception number for [Exception] events; 0 otherwise. *)
    }
  [@@deriving sexp_of]
end

(** ARM ETM architecture versions.  Determines which OpenCSD decoder is used. *)
module Arch = struct
  type t =
    | Etmv3 (** ARMv7 ETMv3 / PTM *)
    | Etmv4 (** ARMv8 ETMv4     *)
    | Ete (** ARMv9 ETE       *)
  [@@deriving sexp_of, compare, equal]

  let to_int = function
    | Etmv3 -> 3
    | Etmv4 -> 4
    | Ete -> 5
  ;;

  (** Select the appropriate ETM architecture based on the detected
      platform architecture. *)
  let of_platform_arch (a : Platform.arch) =
    match a with
    | Armv7 -> Etmv3
    | Armv8 -> Etmv4
    | Armv9 -> Ete
  ;;
end

(** Opaque handle to a single-source OpenCSD decoder session. *)
type t

(* -------------------------------------------------------------------------
 * Stubs (implemented in opencsd_stubs.c)
 * ---------------------------------------------------------------------- *)
external _create
  :  protocol:int
  -> trace_id:int
  -> arch_version:int
  -> t
  = "caml_mtrace_opencsd_create"

external _add_image
  :  t
  -> filename:string
  -> load_address:int64
  -> offset:int64
  -> size:int64
  -> (unit, string) result
  = "caml_mtrace_opencsd_add_image"

external _decode
  :  t
  -> data:bytes
  -> offset:int
  -> len:int
  -> data_index:int64
  -> (int, string) result
  = "caml_mtrace_opencsd_decode"

external _flush : t -> (unit, string) result = "caml_mtrace_opencsd_flush"
external _next_event : t -> Event.t option = "caml_mtrace_opencsd_next_event"
external _has_error : t -> bool = "caml_mtrace_opencsd_has_error"
external _error_msg : t -> string = "caml_mtrace_opencsd_error_msg"

(* -------------------------------------------------------------------------
 * Public API
 * ---------------------------------------------------------------------- *)

(** Create a new decoder.
    @param trace_id   CoreSight trace-ID for this ETM source (0–127).
    @param arch       ETM architecture variant.
*)
let create ~trace_id ~arch =
  _create ~protocol:0 ~trace_id ~arch_version:(Arch.to_int arch)
;;

(** Register a binary image section.  Must be called (possibly multiple times,
    once per load segment) before decoding begins so that OpenCSD can read
    instruction bytes when resolving indirect branches.

    @param filename      Path to the ELF binary / shared object on disk.
    @param load_address  Virtual address at which the segment is mapped.
    @param offset        File offset of the segment in [filename].
    @param size          Size of the segment in bytes.
*)
let add_image t ~filename ~load_address ~offset ~size =
  _add_image t ~filename ~load_address ~offset ~size |> Or_error.of_result
;;

(** Feed a chunk of raw CoreSight-framed trace data to the decoder.

    @param data        Buffer containing the raw trace bytes.
    @param offset      Start offset within [data].
    @param len         Number of bytes to process starting at [offset].
    @param data_index  Byte offset of this chunk within the overall trace
                       stream (used for error messages).
    @return            Number of bytes consumed on success.
*)
let decode t ~data ~offset ~len ~data_index =
  _decode t ~data ~offset ~len ~data_index |> Or_error.of_result
;;

(** Flush remaining buffered decode state.  Call after the last [decode]. *)
let flush t = _flush t |> Or_error.of_result

(** Return the next decoded event, if one is available. *)
let next_event t = _next_event t

(** Drain all currently buffered decoded events into a list. *)
let drain_events t =
  let rec loop acc =
    match next_event t with
    | None -> List.rev acc
    | Some ev -> loop (ev :: acc)
  in
  loop []
;;

(** [true] if a fatal decode error has occurred. *)
let has_error t = _has_error t

(** Human-readable description of the last decode error. *)
let error_msg t = _error_msg t
