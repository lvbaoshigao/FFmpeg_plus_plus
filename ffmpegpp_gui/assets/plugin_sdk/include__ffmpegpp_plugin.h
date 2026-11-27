#ifndef FFMPEGPP_PLUGIN_H
#define FFMPEGPP_PLUGIN_H

/* FFmpeg++ Plugin ABI v1. No libc, WASI, Flutter or platform headers required. */
#if !defined(__wasm32__)
#error "Build with clang --target=wasm32 -nostdlib"
#endif

#define FPP_API_VERSION 1
#define FPP_EXPORT(name) __attribute__((export_name(#name), used))
#define FPP_IMPORT(name) __attribute__((import_module("ffmpegpp"), import_name(name)))
typedef __INT32_TYPE__ fpp_i32;

#ifdef __cplusplus
extern "C" {
#endif

/* Copies UTF-8 JSON into guest linear memory. Returns bytes copied or < 0.
 * capacity is bytes, no trailing NUL is supplied. Never assume success. */
FPP_IMPORT("request_read")
fpp_i32 fpp_request_read(char *destination, fpp_i32 capacity);

/* Copies a complete UTF-8 JSON response to the host. Returns length or < 0.
 * The host validates the pointer, byte count and JSON independently. */
FPP_IMPORT("response_write")
fpp_i32 fpp_response_write(const char *json, fpp_i32 length);

/* All business exports have exact signature void(void).
 * Basic_info is mandatory; Node_info is mandatory when nodes are declared.
 * Node_editor_add and Node_execute are optional for data-only plugins.
 * Export with FPP_EXPORT(Basic_info) void Basic_info(void) { ... }.
 * Only memory and those four business functions should be exported. */

#ifdef __cplusplus
}
#endif

/* Reserves one byte for a convenience NUL. Returns <0 without using partial JSON. */
static inline fpp_i32 fpp_read_json(char *buffer, fpp_i32 capacity) {
    if (capacity < 1) return -1;
    fpp_i32 length = fpp_request_read(buffer, capacity - 1);
    if (length < 0 || length >= capacity) return -1;
    buffer[length] = 0;
    return length;
}
#define FPP_RESPOND_LITERAL(json) fpp_response_write((json), (fpp_i32)(sizeof(json) - 1))

#endif
