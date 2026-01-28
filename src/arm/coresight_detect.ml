open! Core

(** Base sysfs path for CoreSight devices. *)
let coresight_sysfs = "/sys/bus/coresight/devices"

(** The type of a CoreSight component as reported in sysfs. *)
module Device_type = struct
  type t =
    | Etm (** Embedded Trace Macrocell — trace source *)
    | Tmc_etr (** Trace Memory Controller (ETR mode) — DRAM sink *)
    | Tmc_etf (** Trace Memory Controller (ETF mode) — on-chip FIFO sink *)
    | Tmc_etb (** Trace Memory Controller (ETB mode) — on-chip buffer sink *)
    | Funnel (** Coresight funnel — fan-in component *)
    | Replicator (** Coresight replicator — fan-out component *)
    | Other of string
  [@@deriving sexp_of, compare, equal]

  (** Classify a device by its sysfs directory name. *)
  let of_device_name name =
    (* CoreSight sysfs names are like etm0, etm1, tmc_etr0, funnel0, … *)
    if String.is_prefix name ~prefix:"etm"
    then Etm
    else if String.is_prefix name ~prefix:"tmc_etr"
    then Tmc_etr
    else if String.is_prefix name ~prefix:"tmc_etf"
    then Tmc_etf
    else if String.is_prefix name ~prefix:"tmc_etb"
    then Tmc_etb
    else if String.is_prefix name ~prefix:"funnel"
    then Funnel
    else if String.is_prefix name ~prefix:"replicator"
    then Replicator
    else Other name
  ;;
end

(** Describes a single discovered CoreSight device. *)
module Device = struct
  type t =
    { name : string
    ; device_type : Device_type.t
    ; sysfs_path : string
    ; cpu : int option (** Present for ETM devices — which CPU this ETM belongs to. *)
    }
  [@@deriving sexp_of]

  (** Read the CPU number associated with an ETM device, e.g. from
      /sys/bus/coresight/devices/etm0/cpu. *)
  let read_cpu sysfs_path =
    let cpu_path = sysfs_path ^/ "cpu" in
    match Core_unix.access cpu_path [ `Exists ] with
    | Error _ -> None
    | Ok () ->
      (try
         let s = In_channel.read_all cpu_path |> String.strip in
         Some (Int.of_string s)
       with
       | _ -> None)
  ;;

  let of_sysfs_entry name =
    let sysfs_path = coresight_sysfs ^/ name in
    let device_type = Device_type.of_device_name name in
    let cpu =
      match device_type with
      | Etm -> read_cpu sysfs_path
      | _ -> None
    in
    { name; device_type; sysfs_path; cpu }
  ;;
end

(** Describes a sink device suitable for receiving trace. *)
module Sink = struct
  type t =
    { device : Device.t
    ; priority : int (** Lower = higher preference. ETR=0, ETF=1, ETB=2. *)
    }
  [@@deriving sexp_of]

  let of_device (d : Device.t) : t option =
    match d.device_type with
    | Tmc_etr -> Some { device = d; priority = 0 }
    | Tmc_etf -> Some { device = d; priority = 1 }
    | Tmc_etb -> Some { device = d; priority = 2 }
    | _ -> None
  ;;

  let compare a b = Int.compare a.priority b.priority
end

(** The complete topology discovered on this platform. *)
type t =
  { devices : Device.t list
  ; etms : Device.t list (** All ETM sources, sorted by CPU number. *)
  ; sinks : Sink.t list (** All sinks, sorted by preference (ETR first). *)
  }
[@@deriving sexp_of]

(** Returns [Error] if CoreSight sysfs path does not exist, indicating that
    either the kernel has no CoreSight support or none is exposed to the OS. *)
let detect () : t Or_error.t =
  match Core_unix.access coresight_sysfs [ `Exists ] with
  | Error _ ->
    Or_error.errorf
      "CoreSight sysfs path %s not found. This system may not have CoreSight hardware, \
       or the kernel may have been built without CONFIG_CORESIGHT=y. Run: ls %s"
      coresight_sysfs
      coresight_sysfs
  | Ok () ->
    let entries =
      try Sys.readdir coresight_sysfs |> Array.to_list with
      | Sys_error e ->
        raise (Invalid_argument (sprintf "Cannot read CoreSight sysfs: %s" e))
    in
    let devices = List.map entries ~f:Device.of_sysfs_entry in
    let etms =
      List.filter devices ~f:(fun d -> Device_type.equal d.device_type Device_type.Etm)
      |> List.sort ~compare:(fun a b -> Option.compare Int.compare a.cpu b.cpu)
    in
    let sinks =
      List.filter_map devices ~f:Sink.of_device |> List.sort ~compare:Sink.compare
    in
    Ok { devices; etms; sinks }
;;

(** Checks if the `perf` tool supports the `cs_etm` event. *)
let perf_supports_coresight () =
  (* perf list output contains "cs_etm//" when CoreSight perf support is compiled in *)
  match
    Core_unix.open_process_in "perf list 2>/dev/null | grep -c cs_etm"
    |> In_channel.input_line
  with
  | Some s ->
    (try Int.of_string (String.strip s) > 0 with
     | _ -> false)
  | None -> false
;;

(** Select the best available sink device. Preference order: ETR > ETF > ETB.
    Returns [Error] if no sinks are available. *)
let select_sink ?(preferred : string option) (topology : t) : Device.t Or_error.t =
  match preferred with
  | Some name ->
    (match List.find topology.devices ~f:(fun d -> String.equal d.name name) with
     | Some d -> Ok d
     | None ->
       Or_error.errorf
         "Requested ARM sink device %S not found in CoreSight sysfs. Available devices: \
          %s"
         name
         (List.map topology.devices ~f:(fun d -> d.name) |> String.concat ~sep:", "))
  | None ->
    (match topology.sinks with
     | [] ->
       Or_error.error_string
         "No CoreSight sink devices found (looked for tmc_etr, tmc_etf, tmc_etb). Check: \
          ls /sys/bus/coresight/devices/"
     | best :: _ -> Ok best.device)
;;
