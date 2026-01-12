/*
 * opencsd_binding.h
 *
 * Public C interface for the magic-trace OpenCSD wrapper layer.
 * This header is included by both opencsd_binding.c and opencsd_stubs.c.
 */
#ifndef MTRACE_OPENCSD_BINDING_H
#define MTRACE_OPENCSD_BINDING_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C"
{
#endif

    /* -------------------------------------------------------------------------
     * Decoded event kinds (mirrors Opencsd_decoder.Event.Kind.t in OCaml)
     * ---------------------------------------------------------------------- */
    typedef enum
    {
        MTRACE_CS_EVENT_INSTRUCTION_RANGE = 0,
        MTRACE_CS_EVENT_CALL = 1,
        MTRACE_CS_EVENT_RETURN = 2,
        MTRACE_CS_EVENT_TRACE_ON = 3,
        MTRACE_CS_EVENT_TRACE_OFF = 4,
        MTRACE_CS_EVENT_EXCEPTION = 5,
        MTRACE_CS_EVENT_EXCEPTION_RET = 6,
    } mtrace_cs_event_kind_t;

    /* A single decoded CoreSight trace element. */
    typedef struct
    {
        mtrace_cs_event_kind_t kind;
        uint64_t timestamp;        /* nanosecond timestamp, 0 if unavailable */
        uint64_t from_addr;        /* start address of the instruction range */
        uint64_t to_addr;          /* end address (exclusive) for ranges */
        int cpu;                   /* source CPU, -1 if unknown */
        uint32_t exception_number; /* valid for EXCEPTION events only */
    } mtrace_cs_event_t;

    /* Opaque decoder handle. */
    typedef struct mtrace_opencsd_decoder mtrace_opencsd_decoder_t;

    /* -------------------------------------------------------------------------
     * Lifecycle
     * ---------------------------------------------------------------------- */

    /**
     * Create a new decoder for a single-source ETM trace stream.
     *
     * @param protocol     Reserved for future use; pass 0.
     * @param trace_id     The CoreSight trace-ID for this ETM source (0-127).
     * @param arch_version ETM architecture: 3 = ETMv3, 4 = ETMv4, 5 = ETE.
     * @return             New decoder handle, or NULL on allocation failure.
     */
    mtrace_opencsd_decoder_t *
    mtrace_opencsd_create(int protocol, uint8_t trace_id, int arch_version);

    /** Free all resources associated with a decoder. */
    void mtrace_opencsd_destroy(mtrace_opencsd_decoder_t *dec);

    /* -------------------------------------------------------------------------
     * Binary image sections
     * ---------------------------------------------------------------------- */

    /**
     * Register a binary image section so OpenCSD can read instruction bytes
     * during decode (needed to resolve indirect branches).
     *
     * @param filename      Path to the ELF binary or shared library.
     * @param load_address  Virtual address at which this section is loaded.
     * @param offset        File offset of the section within [filename].
     * @param size          Size in bytes of the section.
     * @return              0 on success, -1 on error.
     */
    int mtrace_opencsd_add_image(mtrace_opencsd_decoder_t *dec,
                                 const char *filename,
                                 uint64_t load_address,
                                 uint64_t offset,
                                 uint64_t size);

    /* -------------------------------------------------------------------------
     * Decoding
     * ---------------------------------------------------------------------- */

    /**
     * Feed raw trace data bytes to the decoder.
     *
     * @param data        Pointer to raw ETM trace bytes (CoreSight formatted frame).
     * @param data_len    Number of bytes to decode.
     * @param data_index  Byte offset of [data] within the overall trace stream
     *                    (used for error reporting; pass 0 if unknown).
     * @return            Number of bytes consumed (>= 0), or -1 on fatal error.
     */
    int mtrace_opencsd_decode(mtrace_opencsd_decoder_t *dec,
                              const uint8_t *data,
                              size_t data_len,
                              uint64_t data_index);

    /**
     * Flush any buffered decode state and emit final events.
     * Call this after feeding all available trace bytes.
     * @return 0 on success, -1 on error.
     */
    int mtrace_opencsd_flush(mtrace_opencsd_decoder_t *dec);

    /* -------------------------------------------------------------------------
     * Event retrieval
     * ---------------------------------------------------------------------- */

    /**
     * Pop the next decoded event from the output queue.
     *
     * @param out  Written with the next event if one is available.
     * @return     1 if an event was returned, 0 if the queue is empty.
     */
    int mtrace_opencsd_next_event(mtrace_opencsd_decoder_t *dec, mtrace_cs_event_t *out);

    /* -------------------------------------------------------------------------
     * Error reporting
     * ---------------------------------------------------------------------- */

    /** Returns non-zero if a fatal decode error occurred. */
    int mtrace_opencsd_has_error(const mtrace_opencsd_decoder_t *dec);

    /** Returns a human-readable error message (valid until next API call). */
    const char *mtrace_opencsd_error_msg(const mtrace_opencsd_decoder_t *dec);

#ifdef __cplusplus
}
#endif

#endif /* MTRACE_OPENCSD_BINDING_H */
