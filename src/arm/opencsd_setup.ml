open! Core

(** High-level setup for a complete ARM CoreSight decode session.

    This module ties together [Platform], [Coresight_detect], [Arm_endpoint],
    and [Opencsd_decoder] to give a single entry-point for creating a
    ready-to-use decoder from the current machine configuration.
*)

(** Parameters required to decode a trace produced by one ETM source. *)
module Source = struct
  type t =
    { trace_id : int
      (** CoreSight trace-ID in the range 0–127, assigned by the kernel's
              CoreSight infrastructure and embedded in the formatted frame. *)
    ; cpu : int (** CPU index this ETM belongs to. *)
    ; arch : Opencsd_decoder.Arch.t
    }
  [@@deriving sexp_of]
end

(** A fully-initialised decode session for one or more ETM sources. *)
module Session = struct
  type entry =
    { source : Source.t
    ; decoder : Opencsd_decoder.t
    }

  type t =
    { entries : entry list
    ; platform_arch : Platform.arch
    ; topology : Coresight_detect.t
    ; endpoint_config : Arm_endpoint.Config.t
    }

  (** Look up the decoder for a specific trace-ID. *)
  let decoder_for_trace_id t tid =
    List.find_map t.entries ~f:(fun e ->
      if e.source.trace_id = tid then Some e.decoder else None)
  ;;

  (** Feed a chunk of raw CoreSight-framed trace data to all decoders that
      correspond to the given trace-ID. Returns [Error] on decode failure. *)
  let decode_chunk t ~trace_id ~data ~offset ~len ~data_index =
    match decoder_for_trace_id t trace_id with
    | None ->
      (* Silently skip unknown trace IDs — the kernel may include trace
         from components we didn't configure. *)
      Ok 0
    | Some dec -> Opencsd_decoder.decode dec ~data ~offset ~len ~data_index
  ;;

  (** Flush all decoders. Call after all raw trace data has been fed in. *)
  let flush t =
    List.fold_result t.entries ~init:() ~f:(fun () e -> Opencsd_decoder.flush e.decoder)
  ;;

  (** Drain all buffered decoded events from all sources.  Events are returned
      in source order (not globally sorted by timestamp — the caller should
      sort after merging if required). *)
  let drain_all_events t =
    List.concat_map t.entries ~f:(fun e -> Opencsd_decoder.drain_events e.decoder)
  ;;
end

(** Determine the trace-ID assigned to each ETM from the CoreSight sysfs.
    The kernel assigns trace-IDs that appear in
    [/sys/bus/coresight/devices/etm0/trctraceidr] etc. *)
let read_trace_id (etm_device : Coresight_detect.Device.t) : int Or_error.t =
  let path = etm_device.sysfs_path ^/ "trctraceidr" in
  match Core_unix.access path [ `Exists ] with
  | Error _ ->
    (* Not all kernels expose this; fall back to a synthetic ID based on CPU
       number (the kernel's CoreSight framework uses cpu+1 as default). *)
    let fallback_id = Option.value etm_device.cpu ~default:0 + 1 in
    Ok fallback_id
  | Ok () ->
    (try
       let s = In_channel.read_all path |> String.strip in
       (* File may contain hex e.g. "0x03" or decimal "3" *)
       let v =
         if String.is_prefix s ~prefix:"0x" then Int.of_string s else Int.of_string s
       in
       Ok v
     with
     | _ -> Or_error.errorf "Could not parse trace-ID from %s" path)
;;

(** Create a decode [Session.t] for all ETM sources present on the system.

    @param trace_scope  Which address space was traced.
    @param ?preferred_sink  Override the automatic sink selection.
    @param ?image_sections  List of [(filename, load_addr, offset, size)]
                            for all binary segments that should be registered
                            with each decoder.  Required for correct decode
                            of indirect branches; may be empty for basic decode.
*)
let create_session ~trace_scope ?preferred_sink ?(image_sections = []) ()
  : Session.t Or_error.t
  =
  let open Or_error.Let_syntax in
  (* 1. Detect ARM architecture *)
  let%bind platform_arch = Platform.detect_arch () in
  let decoder_arch = Opencsd_decoder.Arch.of_platform_arch platform_arch in
  (* 2. Discover CoreSight topology *)
  let%bind topology = Coresight_detect.detect () in
  if List.is_empty topology.etms
  then
    Or_error.error_string
      "No ETM trace source devices found in CoreSight sysfs. Check: ls \
       /sys/bus/coresight/devices/etm*"
  else (
    (* 3. Build arm_endpoint config *)
    let%bind endpoint_config = Arm_endpoint.auto_config ~trace_scope ?preferred_sink () in
    (* 4. Create one decoder per ETM source *)
    let%bind entries =
      List.fold_result topology.etms ~init:[] ~f:(fun acc etm_dev ->
        let%bind trace_id = read_trace_id etm_dev in
        let cpu = Option.value etm_dev.cpu ~default:(-1) in
        let decoder = Opencsd_decoder.create ~trace_id ~arch:decoder_arch in
        (* Register all provided image sections with this decoder *)
        let%bind () =
          List.fold_result
            image_sections
            ~init:()
            ~f:(fun () (filename, load_address, offset, size) ->
              Opencsd_decoder.add_image decoder ~filename ~load_address ~offset ~size)
        in
        let source = Session.{ trace_id; cpu; arch = decoder_arch } in
        Ok (Session.{ source; decoder } :: acc))
    in
    Ok Session.{ entries = List.rev entries; platform_arch; topology; endpoint_config })
;;

(** Verify that the current environment has all the prerequisites for ARM
    CoreSight tracing and return a human-readable status report. *)
let check_environment () =
  let results = Buffer.create 256 in
  let ok msg = Buffer.add_string results (sprintf "  [OK]   %s\n" msg) in
  let err msg = Buffer.add_string results (sprintf "  [FAIL] %s\n" msg) in
  let warn msg = Buffer.add_string results (sprintf "  [WARN] %s\n" msg) in
  Buffer.add_string results "ARM CoreSight environment check:\n";
  (* 1. Architecture *)
  (match Platform.detect_arch () with
   | Ok arch -> ok (sprintf "CPU architecture: %s" (Platform.arch_to_string arch))
   | Error e ->
     err (sprintf "CPU architecture detection failed: %s" (Error.to_string_hum e)));
  (* 2. CoreSight sysfs *)
  (match Coresight_detect.detect () with
   | Ok topo ->
     ok
       (sprintf
          "CoreSight sysfs present (%d ETMs, %d sinks)"
          (List.length topo.etms)
          (List.length topo.sinks));
     if List.is_empty topo.sinks
     then warn "No sink devices found (tmc_etr/tmc_etf/tmc_etb)"
   | Error e -> err (sprintf "CoreSight sysfs: %s" (Error.to_string_hum e)));
  (* 3. perf cs_etm support *)
  if Coresight_detect.perf_supports_coresight ()
  then ok "perf supports cs_etm events"
  else err "perf does not list cs_etm — rebuild perf with CORESIGHT=1";
  Buffer.contents results
;;
