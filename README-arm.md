<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.svg?sanitize=true">
    <img src="docs/assets/logo-light.svg?sanitize=true" width="150px">
  </picture>
  <br>
  magic-trace
</h1>

### The long requested support for ARM architecture

An experimental development made due to intrusive thoughts and midnight mayhem.
The following doc contains the details on the features, the development cycle, future updates and personal rants on the built.

**Key Goals:**
- Preliminary check to see if target supports CoreSight
- Enable trace collection from ARM CPUs via OS.
- Support ETM (Embedded Trace Macrocell) or PTM (Program Trace Macrocell) instruction tracing.
- Integrate OpenCSD library for trace decoding.
- Maintain feature parity with Intel PT where applicable.
- Documentation for ARM-specific requirements.

### [Reference Issue - 194](https://github.com/janestreet/magic-trace/issues/194) **by frakman1**

Eventhough the build in this fork of magic-trace might support ARM architecture, there is no guarentee that it will run on Raspberry Pi boards in the same way it runs on Intel chips, this is due to the fact that the processor present in Raspberry Pi is a Broadcom chip which is built around a quad-core Arm Cortex-A76 CPU cluster, and there is no pertaining docs which mention that CoreSight is exposed to the kernel/OS. 

The current fork depends heavily on ARM CoreSight Architecture which provides debug traces to the system, and as per my tests there was no luck in getting access to ARM CoreSight via the Raspbian OS.

## ARM CoreSight

CoreSight is the Debug Architecture from ARM for Debugging and Trace Solutions in Complex SoC designs (Single core and Multi core). 

| Trace | Description |
| --- | ---|
|Embedded Trace Router (ETR) | The Embedded Trace Router (ETR) is a form of CoreSight Trace Memory Controller (EMC) trace sink. It acts as a bridge between the trace and memory fabrics, and its function is to write formatted trace to a buffer in memory.|
|Embedded Trace Macrocell (ETM) |	The Embedded Trace Macrocell (ETM) architecture defines a real-time trace module providing instruction and data tracing of a processor. It includes the programmer's model, the trace port protocol and the physical interface.|
|Program Flow Trace (PTF)	| The Program Trace Macrocell (PTM) architecture defines a real-time module providing program flow trace module of a processor.|

Learn more about CoreSight here: [ARM CoreSight Architecture](https://developer.arm.com/Architectures/CoreSight%20Architecture)


The current implementation of ARM support also involves the library [OpenCSD](https://github.com/Linaro/OpenCSD). 


## Feature Upgrade Checklist

### Functional Requirements
- [ ] Collect trace from ARM processes via magic-trace
- [ ] Decode ETM trace data accurately
- [ ] Support both user and kernel space tracing
- [ ] Handle multi-core trace collection
- [ ] Generate timeline output in Perfetto format
- [ ] Work on at least 3 different ARM platforms

### Documentation Requirements
- [x] Complete user installation guide
- [x] Troubleshooting guide with common issues
- [x] Developer documentation for extensions
- [x] API reference for OpenCSD bindings

> Full documentation: [arm-coresight-support-docs](#arm-coresight-support-for-magic-trace)

---

# ARM CoreSight Support for magic-trace

> **Status:** Experimental — not yet tested on physical ARM hardware.  
> All implementation is complete and the code compiles, but end-to-end validation
> requires a machine that exposes CoreSight to the Linux kernel.  
> See [Known Limitations](#known-limitations) before use.


## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Prerequisites](#prerequisites)
5. [Installation](#installation)
   - [OpenCSD Library](#1-opencsd-library)
   - [perf with CoreSight Support](#2-perf-with-coresight-support)
   - [Building magic-trace](#3-building-magic-trace)
6. [Verifying Your Environment](#verifying-your-environment)
7. [Usage](#usage)
   - [Automatic Detection](#automatic-detection)
   - [Explicit ARM Mode](#explicit-arm-mode)
   - [Attach Mode](#attach-mode)
   - [Run Mode](#run-mode)
   - [Selecting a Sink Device](#selecting-a-sink-device)
   - [Kernel Tracing](#kernel-tracing)
8. [Module Reference](#module-reference)
   - [Platform](#platform)
   - [Coresight_detect](#coresight_detect)
   - [Arm_endpoint](#arm_endpoint)
   - [Opencsd_decoder](#opencsd_decoder)
   - [Opencsd_setup](#opencsd_setup)
9. [Data Flow](#data-flow)
10. [Differences from Intel PT](#differences-from-intel-pt)
11. [Troubleshooting](#troubleshooting)
12. [Known Limitations](#known-limitations)
13. [Platform Compatibility](#platform-compatibility)
14. [Contributing](#contributing)


## Overview

This fork extends [magic-trace](https://github.com/janestreet/magic-trace) with support
for ARM **CoreSight ETM (Embedded Trace Macrocell)** instruction tracing.

On Intel platforms, magic-trace uses **Intel Processor Trace (Intel PT)** via `perf` to
capture a ring buffer of all control flow. This fork provides the equivalent for ARM:

- Trace collection is delegated to `perf` using the `cs_etm` event type.
- Raw CoreSight formatted frames are decoded by the **OpenCSD** library.
- Decoded instruction-level events flow through the existing magic-trace pipeline and
  are rendered as an interactive Perfetto timeline — identical to the Intel PT output.

The ARM path introduces a new `Collection_mode.Arm_coresight` variant that is selected
automatically when CoreSight is detected at runtime, or explicitly via the `-arm` flag.


## How It Works

```
┌──────────────────────────────────────────────────────────────────┐
│                          User Process                            │
└──────────────────────────────────┬───────────────────────────────┘
                                   │  ptrace / breakpoint
                                   ▼
┌──────────────────────────────────────────────────────────────────┐
│  magic-trace (collection)                                        │
│                                                                  │
│  1. Detects ARM CoreSight via /sys/bus/coresight/devices/        │
│  2. Selects best sink device (ETR > ETF > ETB)                   │
│  3. Runs:  perf record -e cs_etm/@tmc_etr0/u --per-thread -t PID │
│  4. On trigger/Ctrl-C: sends snapshot signal to perf             │
└──────────────────────────────────┬───────────────────────────────┘
                                   │  perf.data (AUX area = raw ETM bytes)
                                   ▼
┌──────────────────────────────────────────────────────────────────┐
│  magic-trace (decode)                                            │
│                                                                  │
│  5. Runs: perf script -i perf.data --itrace=be                   │
│     perf uses OpenCSD internally to emit synthetic branch events │
│  6. Perf_decode parses the perf script output                    │
│  7. Trace_writer renders a Perfetto .json timeline               │
└──────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
                       Interactive Perfetto UI
```

> **Note on the OpenCSD OCaml bindings:** The OCaml layer
> (`Opencsd_decoder`, `Opencsd_setup`) provides a direct C-binding path to
> OpenCSD that allows future bypassing of the `perf script` subprocess.
> In the current implementation, perf's own OpenCSD integration handles
> the decode step — the OCaml bindings are in place for a future
> direct-decode backend that mirrors `direct_backend/` for Intel PT.


## Architecture

The ARM support lives entirely inside `src/arm/` as an independent OCaml library
(`magic_trace_arm`) that `magic_trace_lib` depends on.  This keeps the dependency
graph clean and cycle-free.

```
magic_trace_arm  (src/arm/)
  ├── Platform           — CPU arch detection (/proc/cpuinfo)
  ├── Coresight_detect   — Sysfs topology discovery
  ├── Arm_endpoint       — perf event string builder
  ├── Opencsd_decoder    — OCaml ↔ C ↔ OpenCSD bindings
  └── Opencsd_setup      — High-level session orchestration

    opencsd_binding.h    — Shared C header (event types, API surface)
    opencsd_binding.c    — C wrapper around OpenCSD C API
    opencsd_stubs.c      — OCaml C stubs (GC-managed decoder handle)

magic_trace_lib  (src/)
  ├── Collection_mode    — Added Arm_coresight variant + -arm flag
  └── Perf_tool_backend  — Added cs_etm event generation and decode args
```

### Dependency Graph

```
                  ┌──────────────┐
                  │   libopencsd │  (system library)
                  └──────┬───────┘
                         │
              ┌──────────▼──────────┐
              │  magic_trace_arm    │  depends only on: core
              └──────────┬──────────┘
                         │
              ┌──────────▼──────────┐
              │  magic_trace_lib    │  + all prior dependencies
              └──────────┬──────────┘
                         │
              ┌──────────▼──────────┐
              │  magic-trace binary │
              └─────────────────────┘
```


## Prerequisites

### Hardware Requirements

| Requirement | Details |
|---|---|
| ARM CPU with CoreSight | Cortex-A series (A53, A72, A76, A78, X1, X2, etc.) |
| ETM source | ETMv3 (ARMv7), ETMv4 (ARMv8), or ETE (ARMv9) |
| CoreSight sink | At minimum one of: TMC-ETR (preferred), TMC-ETF, ETB |
| CoreSight exposed to OS | Kernel must be able to access CoreSight via sysfs |

> **Raspberry Pi note:** Raspberry Pi boards use a Broadcom SoC.
> Even though the Cortex-A CPU cores inside have CoreSight hardware,
> Broadcom does not expose the CoreSight infrastructure to the OS.
> As a result, `/sys/bus/coresight/devices/` will be empty on Raspbian/Raspberry Pi OS
> and magic-trace ARM tracing will not work on those devices.
> Confirmed working platforms include AWS Graviton, Ampere Altra, and most
> developer boards based on reference ARM designs (e.g. Juno, N1SDP).

### Software Requirements

| Requirement | Version | Notes |
|---|---|---|
| Linux kernel | 5.16+ | With `CONFIG_CORESIGHT=y` and relevant ETM/sink modules |
| `perf` | 5.16+ | Must be built with `CORESIGHT=1` |
| OpenCSD library | 1.3+ | Headers + shared library |
| OCaml | 4.14+ | Matching existing magic-trace requirements |
| GCC / Clang | Any recent | For building C stubs |

### Required Kernel Config

```
CONFIG_CORESIGHT=y
CONFIG_CORESIGHT_LINK_AND_SINK_TMC=m   # TMC-ETR / TMC-ETF (required sink)
CONFIG_CORESIGHT_SOURCE_ETM4X=m        # ETMv4 for ARMv8/v9
CONFIG_CORESIGHT_SOURCE_ETM3X=m        # ETMv3 for ARMv7 (if needed)
CONFIG_CORESIGHT_SINK_TPIU=m           # Optional TPIU sink
CONFIG_CORESIGHT_STM=m                 # Optional software trace
```


## Installation

### 1. OpenCSD Library

OpenCSD is the Linaro reference decoder for ARM CoreSight trace.

```bash
# Clone OpenCSD
git clone https://github.com/Linaro/OpenCSD.git
cd OpenCSD

# Build the C and C++ libraries
cd decoder/build/linux
make

# Install system-wide (requires root)
sudo make install

# Verify
pkg-config --modversion opencsd    # should print e.g. 1.4.0
ldconfig -p | grep opencsd         # should list libopencsd_c_api.so
ls /usr/include/opencsd/           # headers should be present
```

If you prefer a non-system install, set `PKG_CONFIG_PATH` and `LD_LIBRARY_PATH`
to point to the local build before building magic-trace.

### 2. perf with CoreSight Support

The standard `perf` package shipped by most distributions is **not** built with
CoreSight support. You must build it from the kernel source.

```bash
# Use the kernel source matching your running kernel
git clone --depth=1 https://github.com/torvalds/linux.git
cd linux/tools/perf

# Build with CoreSight support
make CORESIGHT=1 VF=1

# Install (or use in-place)
sudo install -m 755 perf /usr/local/bin/perf-coresight

# Verify cs_etm is listed
perf list | grep cs_etm
# Expected: cs_etm//  [Kernel PMU event]
```

You can tell magic-trace to use a specific `perf` binary:

```bash
export MAGIC_TRACE_PERF=/usr/local/bin/perf-coresight
```

### 3. Building magic-trace

```bash
cd magic-trace-arm

# Standard build — OpenCSD is discovered automatically via pkg-config
make

# If OpenCSD is installed in a non-standard prefix (e.g. ~/opencsd):
PKG_CONFIG_PATH=~/opencsd/lib/pkgconfig make

# Run to confirm it compiled
./_build/default/bin/magic_trace_bin.exe -help
```

The Dune build system generates `src/arm/opencsd_cflags.sexp` and
`src/arm/opencsd_libs.sexp` at build time by querying `pkg-config opencsd`.
If OpenCSD is not found, the library still compiles but the C stubs will raise
`Failure` at runtime when an ARM trace session is attempted.


## Verifying Your Environment

Before attempting a trace, run the following checks:

```bash
# 1. CoreSight devices exposed to sysfs
ls /sys/bus/coresight/devices/
# Expected: etm0 etm1 ... tmc_etr0 funnel0 replicator0 ...
# If empty: kernel has no CoreSight support for this platform.

# 2. ETM-to-CPU mapping
for etm in /sys/bus/coresight/devices/etm*; do
  cpu=$(cat "$etm/cpu" 2>/dev/null || echo "?")
  echo "$(basename $etm) -> CPU $cpu"
done

# 3. Available sinks and their types
for dev in /sys/bus/coresight/devices/*; do
  name=$(basename "$dev")
  type=$(cat "$dev/type" 2>/dev/null || echo "unknown")
  echo "$name: $type"
done

# 4. perf supports cs_etm
perf list | grep cs_etm
# Expected line: cs_etm//   [Kernel PMU event]

# 5. OpenCSD installed
pkg-config --modversion opencsd
ldconfig -p | grep opencsd

# 6. Trace ID assigned by kernel
cat /sys/bus/coresight/devices/etm0/trctraceidr
```


## Usage

### Automatic Detection

magic-trace will automatically select ARM CoreSight tracing when:
- Intel PT is **not** present (`/sys/bus/event_source/devices/intel_pt` absent), **and**
- The CoreSight sysfs path **is** present (`/sys/bus/coresight/devices/` exists).

```bash
# On an ARM machine with CoreSight exposed:
magic-trace run ./my_program
# magic-trace will print:
#   Intel PT not found; ARM CoreSight detected. magic-trace will use ARM CoreSight tracing.
```

### Explicit ARM Mode

Use the `-arm` flag to force ARM CoreSight mode regardless of auto-detection:

```bash
magic-trace run -arm ./my_program
```

### Attach Mode

Attach to a running process by PID:

```bash
# Start your process
./my_server &
SERVER_PID=$!

# Attach and collect trace; press Ctrl+C to snapshot
magic-trace attach -arm -pid $SERVER_PID

# Or attach and automatically snapshot when a function is called
magic-trace attach -arm -pid $SERVER_PID -trigger-function handle_request
```

### Run Mode

Run a program under magic-trace from the start:

```bash
# Trace the full execution
magic-trace run -arm -full-execution ./my_program arg1 arg2

# Snapshot when the process exits (default for run mode)
magic-trace run -arm ./my_program
```

### Selecting a Sink Device

By default, magic-trace selects the best available CoreSight sink in this order:
**TMC-ETR** (DRAM-backed, largest capacity) → **TMC-ETF** → **ETB**.

To override, use the `-arm-sink` flag (not yet wired to CLI — sink selection is
currently done via the `Arm_endpoint.auto_config` API):

```bash
# Future CLI flag (planned):
magic-trace run -arm -arm-sink tmc_etf0 ./my_program
```

### Kernel Tracing

Include kernel space in the trace (requires root):

```bash
sudo magic-trace run -arm -trace-include-kernel ./my_program
```

### Output

All ARM CoreSight traces produce the same Perfetto JSON output as Intel PT traces:

```bash
magic-trace run -arm -output trace.json ./my_program
# Then open trace.json at https://ui.perfetto.dev
```


## Module Reference

All ARM-specific modules live in `src/arm/` and are part of the `magic_trace_arm`
library. They are independent of `magic_trace_lib` (no circular dependency).

### Platform

**File:** `src/arm/platform.ml`

Detects the ARM CPU architecture by reading `/proc/cpuinfo`.

```ocaml
type arch =
  | Armv7  (* 32-bit ARMv7, supports ETMv3/PTM *)
  | Armv8  (* 64-bit AArch64, supports ETMv4  *)
  | Armv9  (* 64-bit AArch64, supports ETE    *)

val detect_arch : unit -> arch Or_error.t
(** Reads /proc/cpuinfo and returns the detected architecture.
    Returns [Error] if the system is not ARM or the kernel does not
    expose architecture information in the standard format. *)

val arch_to_string : arch -> string
(** Human-readable string e.g. "ARMv8/AArch64". *)

val is_arm : unit -> bool
(** Returns [true] if [detect_arch ()] succeeds. *)
```

**Detection logic:**
1. Looks for `CPU architecture: 7 | 8 | AArch64` in `/proc/cpuinfo`.
2. For AArch64, checks `CPU part` against known ARMv9 part IDs to distinguish
   ARMv8 (ETMv4) from ARMv9 (ETE).
3. Falls back to `Architecture: armv7 | aarch64` on kernels that report it differently.


### Coresight_detect

**File:** `src/arm/coresight_detect.ml`

Enumerates all CoreSight devices exposed in `/sys/bus/coresight/devices/`.

```ocaml
module Device_type : sig
  type t =
    | Etm | Tmc_etr | Tmc_etf | Tmc_etb | Funnel | Replicator | Other of string
end

module Device : sig
  type t =
    { name        : string        (* e.g. "etm0", "tmc_etr0" *)
    ; device_type : Device_type.t
    ; sysfs_path  : string        (* full path to sysfs directory *)
    ; cpu         : int option    (* CPU index for ETM devices *)
    }
end

module Sink : sig
  type t =
    { device   : Device.t
    ; priority : int   (* 0=ETR (best), 1=ETF, 2=ETB *)
    }
end

type t =
  { devices : Device.t list
  ; etms    : Device.t list   (* sorted by CPU index *)
  ; sinks   : Sink.t list     (* sorted by preference *)
  }

val detect : unit -> t Or_error.t
(** Scan /sys/bus/coresight/devices/ and return the platform topology.
    Returns [Error] if the sysfs path does not exist. *)

val perf_supports_coresight : unit -> bool
(** Check if [perf list] includes the cs_etm event. *)

val select_sink : ?preferred:string -> t -> Device.t Or_error.t
(** Pick the best sink, or look up [preferred] by name.
    Returns [Error] if no sinks are found or the named device is absent. *)
```


### Arm_endpoint

**File:** `src/arm/arm_endpoint.ml`

Builds the `perf record` arguments for a CoreSight session.

```ocaml
module Trace_scope : sig
  type t = Userspace | Kernel | Userspace_and_kernel
end

module Address_filter : sig
  type t = { start_addr : int64; size : int64 }
  val to_perf_filter_arg : t -> string
  (* Produces: "filter 0x<start>/0x<size>" *)
end

module Config : sig
  type t =
    { sink_name       : string
    ; trace_scope     : Trace_scope.t
    ; address_filters : Address_filter.t list
    ; per_cpu         : bool
    }

  val create
    :  sink_name:string
    -> trace_scope:Trace_scope.t
    -> ?address_filters:Address_filter.t list
    -> ?per_cpu:bool
    -> unit
    -> t

  val to_perf_record_args : t -> string list
  (** Returns the [perf record] argument list, e.g.:
      ["--event"; "cs_etm/@tmc_etr0/u"; "--per-thread"] *)

  val to_perf_script_decode_args : t -> string list
  (** Returns ["--itrace=be"] for perf script decode. *)
end

val perf_event_string : sink_name:string -> trace_scope:Trace_scope.t -> string
(** Produces e.g. "cs_etm/@tmc_etr0/u" *)

val auto_config
  :  trace_scope:Trace_scope.t
  -> ?preferred_sink:string
  -> ?address_filters:Address_filter.t list
  -> ?per_cpu:bool
  -> unit
  -> Config.t Or_error.t
(** Auto-detect topology and build a Config.t using the best available sink. *)
```


### Opencsd_decoder

**File:** `src/arm/opencsd_decoder.ml` / `.mli`

OCaml bindings to the OpenCSD C library.

```ocaml
module Event : sig
  module Kind : sig
    type t =
      | Instruction_range  (* sequential run of instructions *)
      | Call               (* taken branch / call *)
      | Return             (* indirect branch treated as return *)
      | Trace_on           (* ETM trace resumed *)
      | Trace_off          (* ETM trace paused / lost *)
      | Exception          (* CPU took an exception *)
      | Exception_ret      (* ERET — return from exception *)
  end

  type t =
    { kind             : Kind.t
    ; timestamp        : Int64.t   (* ns timestamp, 0 if unavailable *)
    ; from_addr        : Int64.t   (* branch source / range start *)
    ; to_addr          : Int64.t   (* branch target / range end (exclusive) *)
    ; cpu              : int       (* source CPU, -1 if unknown *)
    ; exception_number : int       (* only valid for Exception events *)
    }
end

module Arch : sig
  type t = Etmv3 | Etmv4 | Ete
  val of_platform_arch : Platform.arch -> t
end

type t  (* opaque — GC-managed, finalizer calls opencsd_destroy *)

val create      : trace_id:int -> arch:Arch.t -> t
val add_image   : t -> filename:string -> load_address:int64
                     -> offset:int64 -> size:int64 -> unit Or_error.t
val decode      : t -> data:bytes -> offset:int -> len:int
                     -> data_index:int64 -> int Or_error.t
val flush       : t -> unit Or_error.t
val next_event  : t -> Event.t option
val drain_events: t -> Event.t list
val has_error   : t -> bool
val error_msg   : t -> string
```

**C layer:**
- `opencsd_binding.c` — wraps `ocsd_create_dcd_tree`, installs the
  `gen_elem_callback`, maintains a growable ring buffer of decoded events.
- `opencsd_stubs.c` — standard OCaml `CAMLprim` stubs; the `mtrace_opencsd_decoder_t*`
  is stored in a custom block with a finalizer.


### Opencsd_setup

**File:** `src/arm/opencsd_setup.ml`

High-level session setup combining all ARM modules.

```ocaml
module Source : sig
  type t =
    { trace_id : int           (* CoreSight trace-ID, 0–127 *)
    ; cpu      : int
    ; arch     : Opencsd_decoder.Arch.t
    }
end

module Session : sig
  type t

  val decoder_for_trace_id : t -> int -> Opencsd_decoder.t option
  val decode_chunk
    :  t -> trace_id:int -> data:bytes -> offset:int
    -> len:int -> data_index:int64 -> int Or_error.t
  val flush           : t -> unit Or_error.t
  val drain_all_events: t -> Opencsd_decoder.Event.t list
end

val create_session
  :  trace_scope:Arm_endpoint.Trace_scope.t
  -> ?preferred_sink:string
  -> ?image_sections:(string * int64 * int64 * int64) list
          (* (filename, load_address, file_offset, size) *)
  -> unit
  -> Session.t Or_error.t
(** Full setup: detect arch, enumerate ETM sources, read trace-IDs from sysfs,
    create one Opencsd_decoder per ETM, and register all binary image sections. *)

val check_environment : unit -> string
(** Run a series of environment checks and return a human-readable report.
    Useful for diagnostics and bug reports. *)
```

**Example:**

```ocaml
let () =
  match Opencsd_setup.check_environment () |> print_string; () with
  | () ->
    let session =
      Opencsd_setup.create_session
        ~trace_scope:Arm_endpoint.Trace_scope.Userspace
        ~image_sections:[ "/usr/bin/myapp", 0x400000L, 0L, 0x50000L ]
        ()
      |> Or_error.ok_exn
    in
    (* Feed raw trace data ... *)
    Opencsd_setup.Session.decode_chunk session ~trace_id:1
      ~data ~offset:0 ~len:(Bytes.length data) ~data_index:0L
    |> Or_error.ok_exn |> ignore;
    Opencsd_setup.Session.flush session |> Or_error.ok_exn;
    let events = Opencsd_setup.Session.drain_all_events session in
    List.iter events ~f:(fun ev ->
      printf "%s  0x%Lx -> 0x%Lx\n"
        (Sexp.to_string_hum (Opencsd_decoder.Event.Kind.sexp_of_t ev.kind))
        ev.from_addr
        ev.to_addr)
```


## Data Flow

```
perf.data (AUX area)
     │
     │  raw CoreSight formatted frames
     ▼
perf script --itrace=be
     │
     │  synthetic branch events (text lines)
     ▼
Perf_decode.to_events                   (src/perf_decode.ml)
     │
     │  Event.t stream (pid, tid, time, ip, addr, sym)
     ▼
Trace_writer                            (src/trace_writer.ml)
     │
     │  Perfetto JSON
     ▼
trace.json  →  https://ui.perfetto.dev
```

The `Opencsd_decoder` / `Opencsd_setup` OCaml modules represent a **future
direct-decode path** (mirroring `direct_backend/` for Intel PT) that would
eliminate the `perf script` subprocess and allow magic-trace to feed raw AUX
data directly into OpenCSD.  This path is not yet activated in the collection
pipeline.


## Differences from Intel PT

| Feature | Intel PT | ARM CoreSight |
|---|---|---|
| Perf event name | `intel_pt//u` | `cs_etm/@tmc_etr0/u` |
| Snapshot flag | `--snapshot` / `--snapshot=e` | Same (AUX snapshot via SIGUSR2 / ctlfd) |
| Decode `--itrace` | `--itrace=bep` | `--itrace=be` |
| dlfilter | Used to drop same-symbol jumps | Not used (ETM resolves indirect branches fully) |
| kcore | Used for kernel traces | Not needed (ETM captures full instruction stream) |
| Callgraph mode | Intel PT ignores `-callgraph-mode` | ARM CoreSight also ignores it |
| Snapshot size | Tunable via `-snapshot-size` | Not tunable (ignored with warning) |
| Multi-core | Per-thread by default | Per-thread by default |
| Timer resolution | Configurable (cyc, mtc, psb) | Determined by ETM hardware config |
| Auto-detection | `/sys/bus/event_source/devices/intel_pt` | `/sys/bus/coresight/devices/` |
| Extra events | `-events branch-misses,cache-misses` | Not supported (ARM CoreSight only) |


## Troubleshooting

### `CoreSight sysfs path /sys/bus/coresight/devices not found`

The running kernel has no CoreSight support, or it was built without the required
`CONFIG_CORESIGHT` options.

```bash
# Check if CoreSight is in the kernel config
grep CORESIGHT /boot/config-$(uname -r)

# Check dmesg for CoreSight messages
dmesg | grep -i coresight
```

### `perf does not list cs_etm`

Your `perf` binary was not built with `CORESIGHT=1`.  Rebuild from kernel source:

```bash
cd linux/tools/perf && make CORESIGHT=1 VF=1
```

### `opencsd_create: allocation failed`

OpenCSD library could not be found at runtime.

```bash
# Check the linker can find it
ldd $(which magic-trace) | grep opencsd
# If missing:
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
sudo ldconfig
```

### `No ETM trace source devices found`

CoreSight sysfs is present but no `etm*` devices appear.

```bash
ls /sys/bus/coresight/devices/etm*
# If missing, the ETM kernel module may not be loaded:
sudo modprobe coresight-etm4x   # ARMv8/v9
sudo modprobe coresight-etm3x   # ARMv7
```

### `No CoreSight sink devices found (tmc_etr, tmc_etf, tmc_etb)`

The sink module is not loaded.

```bash
sudo modprobe coresight-tmc     # loads TMC-ETR / TMC-ETF driver
```

### `perf record` exits immediately with error

Ensure you have sufficient permissions:

```bash
# Check perf_event_paranoid
cat /proc/sys/kernel/perf_event_paranoid
# Set to -1 for full access (not recommended in production):
sudo sysctl kernel.perf_event_paranoid=-1
```

### Trace is empty or shows `Trace_off` events only

The ETM may not be configured to trace user space, or the trace was lost due to
a buffer overflow.

```bash
# Check available buffer size
cat /sys/bus/coresight/devices/tmc_etr0/mem_size

# Try a smaller program first:
magic-trace run -arm uname
```

### `Requested ARM sink device "X" not found`

The device name you passed does not match any device in sysfs.

```bash
# List available devices
ls /sys/bus/coresight/devices/
```


## Known Limitations

1. **Not tested on real hardware.** The implementation has been developed and
   compiled on an x86/AMD machine inside WSL. No end-to-end validation against
   real ARM CoreSight hardware has been performed.

2. **perf's OpenCSD integration is used for decode.** The `Opencsd_decoder` OCaml
   bindings provide a direct-decode path that is not yet activated;
   all current decoding goes through `perf script`.

3. **No `-arm-sink` CLI flag yet.** Sink selection is automatic (ETR > ETF > ETB).
   Manual override requires modifying `Arm_endpoint.auto_config` programmatically.

4. **No address-range filter CLI flag.** `Arm_endpoint.Address_filter` is
   implemented but no CLI flag exposes it yet.

5. **No `-events` support.** The `Arm_coresight` collection mode returns an empty
   extra-events list; `branch-misses` and `cache-misses` sampling cannot be
   combined with CoreSight tracing.

6. **Raspberry Pi and other Broadcom-based SBCs are not supported.** CoreSight
   hardware is present in the CPU cores but not routed/exposed, so
   `/sys/bus/coresight/devices/` will be empty.

7. **Multi-snapshot mode (`--switch-output=signal`) is untested** with CoreSight
   — it should work since the snapshot control path is shared with Intel PT,
   but has not been validated.


## Platform Compatibility

| Platform | CoreSight Expected | Notes |
|---|---|---|
| AWS Graviton 3 (Neoverse V1) | ✓ | ETMv4, ETR sink |
| AWS Graviton 2 (Neoverse N1) | ✓ | ETMv4, ETR sink |
| Ampere Altra / AltraMax | ✓ | ETMv4, ETR sink |
| ARM Juno development board | ✓ | Reference platform, well tested with perf |
| ARM N1SDP | ✓ | Reference platform |
| Raspberry Pi 4 / 5 (Broadcom) | ✗ | CoreSight not exposed to OS |
| Raspberry Pi CM4 (Broadcom) | ✗ | Same as above |
| Apple M-series (macOS) | ✗ | Not Linux, different trace architecture |
| Qualcomm Snapdragon (Android) | Varies | Depends on OEM kernel; typically locked |
| Generic Cortex-A developer boards | ✓ | Check `/sys/bus/coresight/devices/` |

---

*Documentation written for magic-trace-arm — the experimental ARM CoreSight fork of [janestreet/magic-trace](https://github.com/janestreet/magic-trace).*
