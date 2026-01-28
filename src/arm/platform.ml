open! Core

(** ARM architecture variant detected from the CPU. *)
type arch =
  | Armv7 (** 32-bit ARMv7, Cortex-A, supports ETMv3/PTM *)
  | Armv8 (** 64-bit AArch64 (ARMv8), Cortex-A5x/A7x, supports ETMv4 *)
  | Armv9 (** 64-bit AArch64 (ARMv9), Cortex-X/A7x/A5x, supports ETE *)
[@@deriving sexp_of, compare, equal]

let arch_to_string = function
  | Armv7 -> "ARMv7"
  | Armv8 -> "ARMv8/AArch64"
  | Armv9 -> "ARMv9/AArch64"
;;

(** Read and return the contents of /proc/cpuinfo, or an empty string on error. *)
let read_cpuinfo () =
  try In_channel.read_all "/proc/cpuinfo" with
  | Sys_error _ -> ""
;;

(** Parse the CPU architecture from /proc/cpuinfo.
    Returns [Error] if the architecture cannot be determined or is not ARM. *)
let detect_arch () : arch Or_error.t =
  let cpuinfo = read_cpuinfo () in
  (* Look for "CPU architecture" field (present on ARM Linux kernels) *)
  let lines = String.split_lines cpuinfo in
  let find_field prefix =
    List.find_map lines ~f:(fun line ->
      match String.lsplit2 line ~on:':' with
      | Some (key, value) when String.is_prefix (String.strip key) ~prefix ->
        Some (String.strip value)
      | _ -> None)
  in
  (* ARM kernels expose "CPU architecture" in /proc/cpuinfo *)
  match find_field "CPU architecture" with
  | Some "7" -> Ok Armv7
  | Some "8" -> Ok Armv8
  | Some "AArch64" ->
    (* Check CPU part to distinguish ARMv9 (e.g. Cortex-X2, A710, A510) *)
    let cpu_part = find_field "CPU part" |> Option.value ~default:"" in
    (* Known ARMv9 Cortex-A CPU part IDs *)
    let armv9_parts = [ "0xd48"; "0xd47"; "0xd46"; "0xd4d"; "0xd4e" ] in
    if List.mem armv9_parts cpu_part ~equal:String.equal then Ok Armv9 else Ok Armv8
  | Some other ->
    Or_error.errorf
      "Unrecognised ARM CPU architecture field: %s. Expected 7, 8, or AArch64."
      other
  | None ->
    (* Fallback: look for "Architecture" as reported by newer kernels *)
    (match find_field "Architecture" with
     | Some s when String.is_prefix s ~prefix:"armv7" -> Ok Armv7
     | Some s when String.is_prefix s ~prefix:"aarch64" -> Ok Armv8
     | _ ->
       Or_error.error_string
         "Could not determine ARM CPU architecture from /proc/cpuinfo. This system may \
          not be ARM, or may be running an unusual kernel.")
;;

(** Returns [true] if the current platform is ARM (any variant). *)
let is_arm () =
  match detect_arch () with
  | Ok _ -> true
  | Error _ -> false
;;
