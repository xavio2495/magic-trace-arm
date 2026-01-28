open! Core

(** Which address space to trace in.  Kept self-contained so this library
    does not depend on [magic_trace_lib] (which would create a cycle). *)
module Trace_scope = struct
  type t =
    | Userspace
    | Kernel
    | Userspace_and_kernel
  [@@deriving sexp_of, compare, equal]
end

(** Perf trace scope selector for ARM cs_etm events. *)
let selector_of_trace_scope : Trace_scope.t -> string = function
  | Userspace -> "u"
  | Kernel -> "k"
  | Userspace_and_kernel -> "uk"
;;

(** Build the perf event string for CoreSight ETM tracing.

    Format: [cs_etm/@<sink_name>/<selector>]

    Examples:
    {v
      cs_etm/@tmc_etr0/u      (* user-space only, ETR sink *)
      cs_etm/@tmc_etf0/uk     (* user+kernel, ETF sink *)
    v} *)
let perf_event_string ~sink_name ~trace_scope =
  let sel = selector_of_trace_scope trace_scope in
  [%string "cs_etm/@%{sink_name}/%{sel}"]
;;

(** Address range filter for ARM cs_etm.  Passed to perf as:
    [--filter 'filter <start>/<size>'] *)
module Address_filter = struct
  type t =
    { start_addr : int64
    ; size : int64
    }
  [@@deriving sexp_of]

  let to_perf_filter_arg { start_addr; size } =
    [%string "filter 0x%{Int64.to_string start_addr}/0x%{Int64.to_string size}"]
  ;;
end

(** Full configuration for a single ARM cs_etm recording session. *)
module Config = struct
  type t =
    { sink_name : string (** Name of the CoreSight sink device, e.g. [tmc_etr0]. *)
    ; trace_scope : Trace_scope.t
    ; address_filters : Address_filter.t list
      (** Optional address-range filters. Empty = trace everything. *)
    ; per_cpu : bool (** If [true], use [--per-cpu] instead of per-thread recording. *)
    }
  [@@deriving sexp_of]

  let create ~sink_name ~trace_scope ?(address_filters = []) ?(per_cpu = false) () =
    { sink_name; trace_scope; address_filters; per_cpu }
  ;;

  (** Return the list of [perf record] arguments that implement this configuration.

      Produces:
      {v
        --event cs_etm/@tmc_etr0/u  [--per-cpu | --per-thread]  [--filter ...]
      v} *)
  let to_perf_record_args { sink_name; trace_scope; address_filters; per_cpu } =
    let event_str = perf_event_string ~sink_name ~trace_scope in
    let event_args = [ "--event"; event_str ] in
    let thread_args = if per_cpu then [ "--per-cpu" ] else [ "--per-thread" ] in
    let filter_args =
      match address_filters with
      | [] -> []
      | filters ->
        let filter_str =
          List.map filters ~f:Address_filter.to_perf_filter_arg |> String.concat ~sep:" "
        in
        [ "--filter"; filter_str ]
    in
    List.concat [ event_args; thread_args; filter_args ]
  ;;

  (** Arguments for [perf script] to decode a cs_etm trace. *)
  let to_perf_script_decode_args _t =
    (* --itrace=d requests raw trace decode; b=taken branches, e=errors *)
    [ "--itrace=be" ]
  ;;
end

(** Build a [Config.t] automatically by running CoreSight detection and then
    selecting the best available sink.  Accepts an optional [~preferred_sink]
    name to override the automatic selection. *)
let auto_config ~trace_scope ?preferred_sink ?(address_filters = []) ?(per_cpu = false) ()
  : Config.t Or_error.t
  =
  let open Or_error.Let_syntax in
  let%bind topology = Coresight_detect.detect () in
  let%bind sink = Coresight_detect.select_sink ?preferred:preferred_sink topology in
  Ok (Config.create ~sink_name:sink.name ~trace_scope ~address_filters ~per_cpu ())
;;
