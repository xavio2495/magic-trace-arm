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


The current *heavily detailed plan* for the implementation of ARM support also involves the library [OpenCSD](https://github.com/Linaro/OpenCSD). 


## Feature Upgrade Checklist

### Functional Requirements
- [ ] Collect trace from ARM processes via magic-trace
- [ ] Decode ETM trace data accurately
- [ ] Support both user and kernel space tracing
- [ ] Handle multi-core trace collection
- [ ] Generate timeline output in Perfetto format
- [ ] Work on at least 3 different ARM platforms

### Documentation Requirements
- [ ] Complete user installation guide
- [ ] Troubleshooting guide with common issues
- [ ] Developer documentation for extensions
- [ ] API reference for OpenCSD bindings

### Verification Steps
Verify your environment before starting:

```bash
# Check for CoreSight devices in sysfs
ls /sys/bus/coresight/devices/

# Expected output: etm0, etm1, ..., tmc_etr0, funnel0, etc.

# Check perf support for CoreSight
perf list | grep cs_etm

# Expected output: cs_etm// event

# Verify OpenCSD installation
pkg-config --modversion opencsd
ldconfig -p | grep opencsd
```

---

## Phase 1: Environment Setup & Validation (Week 1-2)

### Goals
- Set up ARM development environment
- Build and install OpenCSD library
- Validate perf CoreSight functionality
- Document baseline configuration
