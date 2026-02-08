open! Core

module Event = struct
  module Name = struct
    type t =
      | Branch_misses
      | Cache_misses
    [@@deriving compare, hash, sexp, bin_io]

    let to_string = function
      | Branch_misses -> "branch-misses"
      | Cache_misses -> "cache-misses"
    ;;
  end

  module When_to_sample = struct
    type t =
      | Frequency of int
      | Period of int
    [@@deriving of_sexp]
  end

  module Precision = struct
    type t =
      | Arbitrary_skid
      | Constant_skid
      | Request_zero_skid
      | Zero_skid
      | Maximum_possible
    [@@deriving of_sexp]
  end

  type t =
    { when_to_sample : When_to_sample.t
    ; name : Name.t
    ; precision : Precision.t
    }
  [@@deriving of_sexp]

  let of_string = function
    | "branch-misses" ->
      { when_to_sample = Period 50; name = Branch_misses; precision = Maximum_possible }
    | "cache-misses" ->
      { when_to_sample = Period 1; name = Cache_misses; precision = Maximum_possible }
    | str -> t_of_sexp (Sexp.of_string str)
  ;;

  let arg_type = Command.Arg_type.create of_string
end

type t =
  | Intel_processor_trace of { extra_events : Event.t list }
  | Stacktrace_sampling of { extra_events : Event.t list }
  | Arm_coresight of { preferred_sink : string option }

let extra_events = function
  | Intel_processor_trace { extra_events } | Stacktrace_sampling { extra_events } ->
    extra_events
  | Arm_coresight _ -> []
;;

let select_collection_mode ~extra_events ~use_sampling ~use_arm =
  match use_arm, use_sampling with
  | true, _ ->
    (* ARM CoreSight requested explicitly; sink will be auto-detected later. *)
    Arm_coresight { preferred_sink = None }
  | false, true -> Stacktrace_sampling { extra_events }
  | false, false ->
    (* Check for Intel PT first, then ARM CoreSight, then fall back to sampling. *)
    (match Core_unix.access "/sys/bus/event_source/devices/intel_pt" [ `Exists ] with
     | Ok () -> Intel_processor_trace { extra_events }
     | Error _ ->
       (match Core_unix.access "/sys/bus/coresight/devices" [ `Exists ] with
        | Ok () ->
          Core.eprintf
            "Intel PT not found; ARM CoreSight detected. magic-trace will use ARM \
             CoreSight tracing.\n";
          Arm_coresight { preferred_sink = None }
        | Error _ ->
          Core.eprintf
            "Intel PT support not found. magic-trace will continue and use sampling \
             instead.\n";
          Stacktrace_sampling { extra_events }))
;;

let param =
  let%map_open.Command extra_events =
    flag
      "-events"
      (optional_with_default
         []
         (Command.Arg_type.comma_separated ~unique_values:true Event.arg_type))
      ~doc:
        "EVENTS Select additional events which can be sampled as a comma separated list. \
         Valid options are [cache-misses] or [branch-misses]. For more info: \
         https://magic-trace.org/w/e"
    |> Util.experimental_flag ~default:[]
  and use_sampling =
    flag
      "-sampling"
      no_arg
      ~doc:
        "Use stacktrace sampling instead of Intel PT. If Intel PT is not available, \
         magic-trace will default to this. For more info: https://magic-trace.org/w/b"
  and use_arm =
    flag
      "-arm"
      no_arg
      ~doc:
        "Use ARM CoreSight ETM tracing (cs_etm) instead of Intel PT. Requires an ARM CPU \
         with CoreSight support and a perf built with CORESIGHT=1. If CoreSight is \
         detected automatically, this flag is not required."
  in
  select_collection_mode ~extra_events ~use_sampling ~use_arm
;;
