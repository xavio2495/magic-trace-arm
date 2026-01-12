/*
 * opencsd_stubs.c
 *
 * OCaml C stubs that expose the mtrace_opencsd_* C API to OCaml.
 *
 * Each CAMLprim function corresponds to an external declaration in
 * opencsd_decoder.ml.
 *
 * Memory management:
 *   The mtrace_opencsd_decoder_t pointer is wrapped in a custom OCaml block
 *   so that the GC will automatically call [mtrace_opencsd_destroy] when the
 *   OCaml value is collected.
 */

#include "opencsd_binding.h"

#include <string.h>
#include <caml/mlvalues.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/alloc.h>

/* -------------------------------------------------------------------------
 * Custom block for the decoder pointer
 * ---------------------------------------------------------------------- */

static void decoder_finalize(value v)
{
    mtrace_opencsd_decoder_t *dec =
        *((mtrace_opencsd_decoder_t **)Data_custom_val(v));
    if (dec)
        mtrace_opencsd_destroy(dec);
}

static struct custom_operations decoder_ops = {
    "mtrace_opencsd_decoder",
    decoder_finalize,
    custom_compare_default,
    custom_hash_default,
    custom_serialize_default,
    custom_deserialize_default,
    custom_compare_ext_default,
    custom_fixed_length_default};

static value alloc_decoder(mtrace_opencsd_decoder_t *dec)
{
    value v = caml_alloc_custom(&decoder_ops,
                                sizeof(mtrace_opencsd_decoder_t *), 0, 1);
    *((mtrace_opencsd_decoder_t **)Data_custom_val(v)) = dec;
    return v;
}

static mtrace_opencsd_decoder_t *get_decoder(value v)
{
    return *((mtrace_opencsd_decoder_t **)Data_custom_val(v));
}

/* -------------------------------------------------------------------------
 * Stubs
 * ---------------------------------------------------------------------- */

/* external create : protocol:int -> trace_id:int -> arch_version:int -> t
   Raises Failure if allocation fails. */
CAMLprim value
caml_mtrace_opencsd_create(value v_protocol, value v_trace_id, value v_arch)
{
    CAMLparam3(v_protocol, v_trace_id, v_arch);
    int protocol = Int_val(v_protocol);
    uint8_t trace_id = (uint8_t)Int_val(v_trace_id);
    int arch = Int_val(v_arch);

    mtrace_opencsd_decoder_t *dec =
        mtrace_opencsd_create(protocol, trace_id, arch);
    if (!dec)
        caml_failwith("opencsd_create: allocation failed");

    CAMLreturn(alloc_decoder(dec));
}

/* external add_image :
     t -> filename:string -> load_address:int64 -> offset:int64 -> size:int64
     -> (unit, string) result */
CAMLprim value
caml_mtrace_opencsd_add_image(value v_dec, value v_filename,
                              value v_load, value v_off, value v_size)
{
    CAMLparam5(v_dec, v_filename, v_load, v_off, v_size);
    CAMLlocal1(result);

    mtrace_opencsd_decoder_t *dec = get_decoder(v_dec);
    const char *filename = String_val(v_filename);
    uint64_t load_addr = Int64_val(v_load);
    uint64_t offset = Int64_val(v_off);
    uint64_t size = Int64_val(v_size);

    int rc = mtrace_opencsd_add_image(dec, filename, load_addr, offset, size);
    if (rc != 0)
    {
        /* Return Error msg */
        result = caml_alloc(1, 1); /* Error tag = 1 */
        Store_field(result, 0,
                    caml_copy_string(mtrace_opencsd_error_msg(dec)));
    }
    else
    {
        /* Return Ok () */
        result = caml_alloc(1, 0); /* Ok tag = 0 */
        Store_field(result, 0, Val_unit);
    }
    CAMLreturn(result);
}

/* external decode :
     t -> data:bytes -> offset:int -> len:int -> data_index:int64
     -> (int, string) result  */
CAMLprim value
caml_mtrace_opencsd_decode(value v_dec, value v_data,
                           value v_off, value v_len, value v_index)
{
    CAMLparam5(v_dec, v_data, v_off, v_len, v_index);
    CAMLlocal1(result);

    mtrace_opencsd_decoder_t *dec = get_decoder(v_dec);
    const uint8_t *data = (const uint8_t *)Bytes_val(v_data) + Int_val(v_off);
    size_t len = (size_t)Int_val(v_len);
    uint64_t index = Int64_val(v_index);

    int consumed = mtrace_opencsd_decode(dec, data, len, index);
    if (consumed < 0)
    {
        result = caml_alloc(1, 1);
        Store_field(result, 0,
                    caml_copy_string(mtrace_opencsd_error_msg(dec)));
    }
    else
    {
        result = caml_alloc(1, 0);
        Store_field(result, 0, Val_int(consumed));
    }
    CAMLreturn(result);
}

/* external flush : t -> (unit, string) result */
CAMLprim value
caml_mtrace_opencsd_flush(value v_dec)
{
    CAMLparam1(v_dec);
    CAMLlocal1(result);

    mtrace_opencsd_decoder_t *dec = get_decoder(v_dec);
    int rc = mtrace_opencsd_flush(dec);
    if (rc != 0)
    {
        result = caml_alloc(1, 1);
        Store_field(result, 0,
                    caml_copy_string(mtrace_opencsd_error_msg(dec)));
    }
    else
    {
        result = caml_alloc(1, 0);
        Store_field(result, 0, Val_unit);
    }
    CAMLreturn(result);
}

/* Layout of the OCaml Event.t record (must match opencsd_decoder.ml):
     [| kind: int; timestamp: int64; from_addr: int64; to_addr: int64;
        cpu: int; exception_number: int |]
   We use a plain record (non-float), so tag 0 with int-sized fields. */
#define EVENT_FIELD_KIND 0
#define EVENT_FIELD_TIMESTAMP 1
#define EVENT_FIELD_FROM_ADDR 2
#define EVENT_FIELD_TO_ADDR 3
#define EVENT_FIELD_CPU 4
#define EVENT_FIELD_EXNO 5
#define EVENT_NFIELDS 6

/* external next_event : t -> Event.t option */
CAMLprim value
caml_mtrace_opencsd_next_event(value v_dec)
{
    CAMLparam1(v_dec);
    CAMLlocal2(option, record);

    mtrace_opencsd_decoder_t *dec = get_decoder(v_dec);
    mtrace_cs_event_t ev;
    int got = mtrace_opencsd_next_event(dec, &ev);
    if (!got)
    {
        CAMLreturn(Val_int(0)); /* None */
    }

    record = caml_alloc(EVENT_NFIELDS, 0);
    Store_field(record, EVENT_FIELD_KIND, Val_int((int)ev.kind));
    Store_field(record, EVENT_FIELD_TIMESTAMP, caml_copy_int64(ev.timestamp));
    Store_field(record, EVENT_FIELD_FROM_ADDR, caml_copy_int64(ev.from_addr));
    Store_field(record, EVENT_FIELD_TO_ADDR, caml_copy_int64(ev.to_addr));
    Store_field(record, EVENT_FIELD_CPU, Val_int(ev.cpu));
    Store_field(record, EVENT_FIELD_EXNO, Val_int((int)ev.exception_number));

    option = caml_alloc(1, 0); /* Some _ */
    Store_field(option, 0, record);
    CAMLreturn(option);
}

/* external has_error : t -> bool */
CAMLprim value
caml_mtrace_opencsd_has_error(value v_dec)
{
    CAMLparam1(v_dec);
    mtrace_opencsd_decoder_t *dec = get_decoder(v_dec);
    CAMLreturn(Val_bool(mtrace_opencsd_has_error(dec) != 0));
}

/* external error_msg : t -> string */
CAMLprim value
caml_mtrace_opencsd_error_msg(value v_dec)
{
    CAMLparam1(v_dec);
    mtrace_opencsd_decoder_t *dec = get_decoder(v_dec);
    CAMLreturn(caml_copy_string(mtrace_opencsd_error_msg(dec)));
}
