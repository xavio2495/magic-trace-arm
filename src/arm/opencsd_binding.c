/*
 * opencsd_binding.c
 *
 * C wrapper around the OpenCSD library's C API for decoding ARM CoreSight ETM
 * traces.  This layer is called by opencsd_stubs.c which bridges it into OCaml.
 *
 * Requires: libopencsd (>= 1.3)
 *   Headers: <opencsd/c_api/opencsd_c_api.h>
 *   Link:    -lopencsd_c_api
 */

#include "opencsd_binding.h"

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>

/* OpenCSD C API */
#include <opencsd/c_api/opencsd_c_api.h>

/* -------------------------------------------------------------------------
 * Internal state for one decode session.
 * ---------------------------------------------------------------------- */

struct mtrace_opencsd_decoder
{
    dcd_tree_handle_t dcd_tree; /* opaque OpenCSD decode tree handle */

    /* Ring buffer of decoded events (written by callback, read by OCaml) */
    mtrace_cs_event_t *event_buf;
    size_t event_buf_cap;
    size_t event_buf_head; /* next slot to write */
    size_t event_buf_tail; /* next slot to read  */

    int error_flag; /* set on decode error */
    char error_msg[256];
};

/* -------------------------------------------------------------------------
 * Event ring-buffer helpers
 * ---------------------------------------------------------------------- */

static int event_buf_push(mtrace_opencsd_decoder_t *dec, const mtrace_cs_event_t *ev)
{
    size_t next_head = (dec->event_buf_head + 1) % dec->event_buf_cap;
    if (next_head == dec->event_buf_tail)
    {
        /* Buffer full — grow it x2 */
        size_t new_cap = dec->event_buf_cap * 2;
        mtrace_cs_event_t *new_buf =
            realloc(dec->event_buf, new_cap * sizeof(mtrace_cs_event_t));
        if (!new_buf)
            return -1;
        /* Linearise the ring: move tail..end to the new end */
        if (dec->event_buf_head < dec->event_buf_tail)
        {
            size_t old_tail_len = dec->event_buf_cap - dec->event_buf_tail;
            memmove(new_buf + new_cap - old_tail_len,
                    new_buf + dec->event_buf_tail,
                    old_tail_len * sizeof(mtrace_cs_event_t));
            dec->event_buf_tail = new_cap - old_tail_len;
        }
        dec->event_buf = new_buf;
        dec->event_buf_cap = new_cap;
        next_head = (dec->event_buf_head + 1) % dec->event_buf_cap;
    }
    dec->event_buf[dec->event_buf_head] = *ev;
    dec->event_buf_head = next_head;
    return 0;
}

static int event_buf_pop(mtrace_opencsd_decoder_t *dec, mtrace_cs_event_t *out)
{
    if (dec->event_buf_head == dec->event_buf_tail)
        return 0; /* empty */
    *out = dec->event_buf[dec->event_buf_tail];
    dec->event_buf_tail = (dec->event_buf_tail + 1) % dec->event_buf_cap;
    return 1;
}

/* -------------------------------------------------------------------------
 * OpenCSD generic element callback
 *
 * OpenCSD calls this for every decoded trace element.  We convert it to our
 * flat mtrace_cs_event_t representation and push it onto the ring buffer.
 * ---------------------------------------------------------------------- */

static ocsd_datapath_resp_t
gen_elem_callback(const void *p_context,
                  const ocsd_trc_index_t index_sop,
                  const uint8_t trc_chan_id,
                  const ocsd_generic_trace_elem *elem)
{
    mtrace_opencsd_decoder_t *dec = (mtrace_opencsd_decoder_t *)p_context;
    (void)index_sop;
    (void)trc_chan_id;

    mtrace_cs_event_t ev;
    memset(&ev, 0, sizeof(ev));
    ev.timestamp = elem->timestamp;

    switch (elem->elem_type)
    {
    case OCSD_GEN_TRC_ELEM_INSTR_RANGE:
        /* A range of instructions was executed.  Report the start (call site)
           and the end (return/branch target). */
        if (elem->last_instr_type == OCSD_INSTR_BR_INDIRECT)
        {
            ev.kind = MTRACE_CS_EVENT_RETURN;
        }
        else if (elem->last_instr_type == OCSD_INSTR_BR)
        {
            ev.kind = MTRACE_CS_EVENT_CALL;
        }
        else
        {
            ev.kind = MTRACE_CS_EVENT_INSTRUCTION_RANGE;
        }
        ev.from_addr = elem->st_addr;
        ev.to_addr = elem->en_addr;
        ev.cpu = (int)elem->context.ctxt_id;
        break;

    case OCSD_GEN_TRC_ELEM_TRACE_ON:
        ev.kind = MTRACE_CS_EVENT_TRACE_ON;
        ev.from_addr = elem->st_addr;
        break;

    case OCSD_GEN_TRC_ELEM_TRACE_OFF:
        ev.kind = MTRACE_CS_EVENT_TRACE_OFF;
        ev.from_addr = elem->st_addr;
        break;

    case OCSD_GEN_TRC_ELEM_EXCEPTION:
        ev.kind = MTRACE_CS_EVENT_EXCEPTION;
        ev.from_addr = elem->st_addr;
        ev.exception_number = (uint32_t)elem->exception_number;
        break;

    case OCSD_GEN_TRC_ELEM_EXCEPTION_RET:
        ev.kind = MTRACE_CS_EVENT_EXCEPTION_RET;
        ev.from_addr = elem->st_addr;
        break;

    default:
        /* Ignore all other element types (PE context, timestamp-only, etc.) */
        return OCSD_RESP_CONT;
    }

    if (event_buf_push(dec, &ev) != 0)
    {
        snprintf(dec->error_msg, sizeof(dec->error_msg),
                 "opencsd: event buffer allocation failed");
        dec->error_flag = 1;
        return OCSD_RESP_FATAL_SYS_ERR;
    }
    return OCSD_RESP_CONT;
}

/* -------------------------------------------------------------------------
 * Public API
 * ---------------------------------------------------------------------- */

mtrace_opencsd_decoder_t *
mtrace_opencsd_create(int protocol, uint8_t trace_id, int arch_version)
{
    mtrace_opencsd_decoder_t *dec = calloc(1, sizeof(*dec));
    if (!dec)
        return NULL;

    /* Allocate initial event ring buffer (256 slots) */
    dec->event_buf_cap = 256;
    dec->event_buf = malloc(dec->event_buf_cap * sizeof(mtrace_cs_event_t));
    if (!dec->event_buf)
    {
        free(dec);
        return NULL;
    }
    dec->event_buf_head = dec->event_buf_tail = 0;

    /* Create an OpenCSD decode tree in "formatted" frame mode (as produced
       by perf when using the CoreSight sink).  Use
       OCSD_TRC_SRC_FRAME_FORMATTED for normal ETR/ETF output, or
       OCSD_TRC_SRC_SINGLE if decoding a raw single-trace-ID stream. */
    ocsd_dcd_tree_src_t src_type = OCSD_TRC_SRC_FRAME_FORMATTED;
    dec->dcd_tree = ocsd_create_dcd_tree(src_type, OCSD_DFRMTR_FRAME_MEM_ALIGN);
    if (dec->dcd_tree == C_API_INVALID_TREE_HANDLE)
    {
        free(dec->event_buf);
        free(dec);
        return NULL;
    }

    /* Install the generic element output callback */
    ocsd_dt_set_gen_elem_outfn(dec->dcd_tree, gen_elem_callback, dec);

    /* Create the ETM/ETE decoder for this trace-ID */
    ocsd_etmv4_cfg etm4cfg;
    memset(&etm4cfg, 0, sizeof(etm4cfg));

    /* Minimal config: protocol selects ETMv3/ETMv4/ETE.
       arch_version: 3 = ETMv3, 4 = ETMv4, 5 = ETE (ARMv9) */
    const char *decoder_name;
    void *decoder_cfg;
    ocsd_etmv3_cfg etm3cfg;

    switch (arch_version)
    {
    case 3:
        memset(&etm3cfg, 0, sizeof(etm3cfg));
        etm3cfg.reg_idr = 0;
        etm3cfg.arch_ver = CS_ARCH_V7;
        etm3cfg.core_prof = profile_CortexA;
        decoder_name = OCSD_BUILTIN_DCD_ETMV3;
        decoder_cfg = &etm3cfg;
        break;
    case 5:
        /* ETE (ETMv5) shares config struct with ETMv4 */
        /* fall through */
    default:                           /* 4 = ETMv4, also default */
        etm4cfg.reg_idr0 = 0x28000ea1; /* ETMv4.0 minimal */
        etm4cfg.reg_idr1 = 0x4100f403;
        etm4cfg.reg_idr2 = 0x00000488;
        etm4cfg.reg_idr8 = 0;
        etm4cfg.reg_configr = 0x000000c1;
        etm4cfg.arch_ver = (arch_version == 5) ? CS_ARCH_V8 : CS_ARCH_V8;
        etm4cfg.core_prof = profile_CortexA;
        decoder_name = (arch_version == 5) ? OCSD_BUILTIN_DCD_ETE
                                           : OCSD_BUILTIN_DCD_ETMV4I;
        decoder_cfg = &etm4cfg;
        break;
    }

    ocsd_decoder_handle_t decoder_handle;
    ocsd_err_t err = ocsd_dt_create_decoder(dec->dcd_tree,
                                            decoder_name,
                                            OCSD_CREATE_FLG_FULL_DECODER,
                                            decoder_cfg,
                                            &decoder_handle);
    if (err != OCSD_OK)
    {
        snprintf(dec->error_msg, sizeof(dec->error_msg),
                 "opencsd: ocsd_dt_create_decoder failed: %s",
                 ocsd_err_str(err));
        dec->error_flag = 1;
        /* Still return dec; caller can check error state. */
    }

    (void)protocol;
    (void)trace_id;
    return dec;
}

int mtrace_opencsd_add_image(mtrace_opencsd_decoder_t *dec,
                             const char *filename,
                             uint64_t load_address,
                             uint64_t offset,
                             uint64_t size)
{
    ocsd_err_t err =
        ocsd_dt_add_named_mem_acc(dec->dcd_tree,
                                  load_address,
                                  load_address + size - 1,
                                  OCSD_MEM_SPACE_ANY,
                                  filename,
                                  offset);
    if (err != OCSD_OK)
    {
        snprintf(dec->error_msg, sizeof(dec->error_msg),
                 "opencsd: add_named_mem_acc failed for %s: %s",
                 filename, ocsd_err_str(err));
        return -1;
    }
    return 0;
}

int mtrace_opencsd_decode(mtrace_opencsd_decoder_t *dec,
                          const uint8_t *data,
                          size_t data_len,
                          uint64_t data_index)
{
    if (dec->error_flag)
        return -1;

    uint32_t bytes_used = 0;
    ocsd_err_t err =
        ocsd_dt_process_data(dec->dcd_tree,
                             OCSD_OP_DATA,
                             (ocsd_trc_index_t)data_index,
                             (uint32_t)data_len,
                             data,
                             &bytes_used);
    if (err != OCSD_OK && err != OCSD_ERR_UNSUPP_DECODE_PKT)
    {
        snprintf(dec->error_msg, sizeof(dec->error_msg),
                 "opencsd: decode error at index %llu: %s",
                 (unsigned long long)data_index, ocsd_err_str(err));
        dec->error_flag = 1;
        return -1;
    }
    return (int)bytes_used;
}

int mtrace_opencsd_flush(mtrace_opencsd_decoder_t *dec)
{
    if (dec->error_flag)
        return -1;
    ocsd_err_t err =
        ocsd_dt_process_data(dec->dcd_tree,
                             OCSD_OP_FLUSH,
                             0, 0, NULL, NULL);
    return (err == OCSD_OK || err == OCSD_ERR_FLUSH_COMPLETE) ? 0 : -1;
}

int mtrace_opencsd_next_event(mtrace_opencsd_decoder_t *dec, mtrace_cs_event_t *out)
{
    return event_buf_pop(dec, out);
}

int mtrace_opencsd_has_error(const mtrace_opencsd_decoder_t *dec)
{
    return dec->error_flag;
}

const char *
mtrace_opencsd_error_msg(const mtrace_opencsd_decoder_t *dec)
{
    return dec->error_msg;
}

void mtrace_opencsd_destroy(mtrace_opencsd_decoder_t *dec)
{
    if (!dec)
        return;
    if (dec->dcd_tree != C_API_INVALID_TREE_HANDLE)
        ocsd_destroy_dcd_tree(dec->dcd_tree);
    free(dec->event_buf);
    free(dec);
}
