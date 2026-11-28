#ifndef FFMPEGPP_FFMPEG_H
#define FFMPEGPP_FFMPEG_H

/* Bounded argv-plan helper for the host-owned ffmpeg.execute operation.
 * The plan contains only option/value strings; the host supplies the one
 * input and one output path and performs the final security validation. */
#include "ffmpegpp_json.h"
#include "ffmpegpp_plugin.h"

#define FPP_FFMPEG_MAX_ARGUMENTS 128
#define FPP_FFMPEG_MAX_ARGUMENT_LENGTH 16384

typedef struct fpp_ffmpeg_plan {
    fpp_json_writer json;
    const fpp_host_capabilities *caps;
    fpp_i32 arg_count;
    fpp_i32 argument_bytes;
    fpp_i32 max_arguments;
    fpp_i32 max_argument_bytes;
    fpp_i32 max_total_argument_bytes;
    fpp_i32 active;
    fpp_i32 closed;
} fpp_ffmpeg_plan;

static inline fpp_i32 fpp_ffmpeg_text_length(const char *text) {
    fpp_i32 length = 0;
    if (!text) return -1;
    while (text[length]) {
        if (++length > FPP_FFMPEG_MAX_ARGUMENT_LENGTH) return -1;
    }
    return length;
}

static inline int fpp_ffmpeg_forbidden_option(const char *option) {
    static const char *const forbidden[] = {
        "-i", "--input", "-o", "--output", "-filter_complex_script",
        "-filter_script", "-progress", "-report", "-dump_attachment",
        "-attach", "-fpre", "-preset_script"
    };
    fpp_i32 i, p, n;
    if (!option) return 1;
    n = fpp_ffmpeg_text_length(option);
    if (n < 1 || option[0] != '-') return 1;
    for (i = 0; i < (fpp_i32)(sizeof(forbidden) / sizeof(forbidden[0])); ++i) {
        for (p = 0; p < n && forbidden[i][p] && option[p] == forbidden[i][p]; ++p) {}
        if (p == n && forbidden[i][p] == 0) return 1;
    }
    return 0;
}

static inline int fpp_ffmpeg_has_protocol(const char *text) {
    fpp_i32 i;
    if (!text) return 0;
    for (i = 0; text[i] && text[i + 1] && text[i + 2]; ++i) {
        if (text[i] == ':' && text[i + 1] == '/' && text[i + 2] == '/') return 1;
    }
    return 0;
}

static inline int fpp_ffmpeg_value_safe(const char *value) {
    fpp_i32 n, i;
    if (!value) return 0;
    n = fpp_ffmpeg_text_length(value);
    if (n < 0 || fpp_ffmpeg_has_protocol(value)) return 0;
    if (n > 0 && (value[0] == '/' || value[0] == '\\' || value[0] == '~')) return 0;
    if (n >= 2 && ((value[0] >= 'A' && value[0] <= 'Z') || (value[0] >= 'a' && value[0] <= 'z')) && value[1] == ':') return 0;
    for (i = 0; i < n; ++i) if ((unsigned char)value[i] < 0x20u || value[i] == 0) return 0;
    return 1;
}

static inline int fpp_ffmpeg_plan_init(fpp_ffmpeg_plan *plan, char *buffer, fpp_i32 capacity) {
    if (!plan) return FPP_JSON_E_ARGUMENT;
    fpp_json_writer_init(&plan->json, buffer, capacity);
    plan->caps = (const fpp_host_capabilities *)0;
    plan->arg_count = 0; plan->argument_bytes = 0;
    plan->max_arguments = FPP_FFMPEG_MAX_ARGUMENTS;
    plan->max_argument_bytes = 8192;
    plan->max_total_argument_bytes = 32768;
    plan->active = 0; plan->closed = 0;
    if (plan->json.error != FPP_JSON_OK) return plan->json.error;
    if (fpp_json_writer_begin_object(&plan->json) != FPP_JSON_OK ||
        fpp_json_writer_key(&plan->json, "operation") != FPP_JSON_OK ||
        fpp_json_writer_string(&plan->json, "ffmpeg.execute") != FPP_JSON_OK ||
        fpp_json_writer_key(&plan->json, "arguments") != FPP_JSON_OK ||
        fpp_json_writer_begin_array(&plan->json) != FPP_JSON_OK) return plan->json.error;
    plan->active = 1;
    return FPP_JSON_OK;
}

static inline int fpp_ffmpeg_plan_begin(fpp_ffmpeg_plan *plan, char *buffer, fpp_i32 capacity) {
    return fpp_ffmpeg_plan_init(plan, buffer, capacity);
}

static inline int fpp_ffmpeg_plan_set_capabilities(fpp_ffmpeg_plan *plan,
                                                   const fpp_host_capabilities *caps) {
    if (!plan) return FPP_JSON_E_ARGUMENT;
    if (!plan->active || plan->closed) return FPP_JSON_E_STATE;
    if (!caps) { plan->active = 0; return FPP_JSON_E_ARGUMENT; }
    /* Already serialized arguments cannot be checked against new capabilities. */
    if (plan->arg_count != 0 || plan->argument_bytes != 0) { plan->active = 0; return FPP_JSON_E_STATE; }
    if (!fpp_host_supports_operation(caps, "ffmpeg.execute") ||
        caps->ffmpeg_api_version != 1 || caps->options.type != FPP_JSON_ARRAY ||
        caps->filters.type != FPP_JSON_ARRAY) { plan->active = 0; return FPP_JSON_E_HOST; }
    if (caps->has_max_arguments && caps->max_arguments < plan->max_arguments) plan->max_arguments = caps->max_arguments;
    if (caps->has_max_argument_bytes && caps->max_argument_bytes < plan->max_argument_bytes) plan->max_argument_bytes = caps->max_argument_bytes;
    if (caps->has_max_total_argument_bytes && caps->max_total_argument_bytes < plan->max_total_argument_bytes) plan->max_total_argument_bytes = caps->max_total_argument_bytes;
    plan->caps = caps;
    return FPP_JSON_OK;
}

static inline int fpp_ffmpeg_is_negative_number(const char *argument, fpp_i32 length) {
    fpp_i32 end;
    return argument && length > 1 && argument[0] == '-' &&
           fpp_json_number_end(argument, length, 0, &end) == FPP_JSON_OK && end == length;
}

static inline int fpp_ffmpeg_plan_append(fpp_ffmpeg_plan *plan, const char *argument, fpp_i32 length) {
    if (!plan || !plan->active || plan->closed || !argument) return FPP_JSON_E_STATE;
    if (length < 1 || length > plan->max_argument_bytes) return FPP_JSON_E_LIMIT;
    if (plan->arg_count >= plan->max_arguments ||
        plan->argument_bytes > plan->max_total_argument_bytes - length) return FPP_JSON_E_LIMIT;
    if (fpp_json_writer_string(&plan->json, argument) != FPP_JSON_OK) return plan->json.error;
    ++plan->arg_count;
    plan->argument_bytes += length;
    return FPP_JSON_OK;
}

static inline int fpp_ffmpeg_plan_add_argument(fpp_ffmpeg_plan *plan, const char *argument) {
    fpp_i32 n;
    if (!plan || !plan->active || plan->closed || !argument) return FPP_JSON_E_STATE;
    n = fpp_ffmpeg_text_length(argument);
    if (n < 1) return FPP_JSON_E_ARGUMENT;
    if (argument[0] == '-' && !fpp_ffmpeg_is_negative_number(argument, n)) {
        if (fpp_ffmpeg_forbidden_option(argument)) return FPP_JSON_E_HOST;
        if (plan->caps && !fpp_host_supports_ffmpeg_option(plan->caps, argument)) return FPP_JSON_E_HOST;
    }
    if (!fpp_ffmpeg_value_safe(argument)) return FPP_JSON_E_INVALID;
    return fpp_ffmpeg_plan_append(plan, argument, n);
}

static inline int fpp_ffmpeg_plan_add_arg(fpp_ffmpeg_plan *plan, const char *argument) {
    return fpp_ffmpeg_plan_add_argument(plan, argument);
}

static inline int fpp_ffmpeg_plan_add_option(fpp_ffmpeg_plan *plan, const char *option,
                                             const char *value) {
    fpp_i32 option_length, value_length;
    if (!plan || !option || !value || option[0] != '-' || fpp_ffmpeg_forbidden_option(option)) return FPP_JSON_E_HOST;
    option_length = fpp_ffmpeg_text_length(option);
    value_length = fpp_ffmpeg_text_length(value);
    if (option_length < 1 || value_length < 1 || !fpp_ffmpeg_value_safe(value)) return FPP_JSON_E_INVALID;
    if (option_length > plan->max_argument_bytes || value_length > plan->max_argument_bytes ||
        plan->arg_count > plan->max_arguments - 2 ||
        plan->argument_bytes > plan->max_total_argument_bytes - option_length - value_length) return FPP_JSON_E_LIMIT;
    if (fpp_ffmpeg_plan_add_argument(plan, option) != FPP_JSON_OK) return plan->json.error ? plan->json.error : FPP_JSON_E_HOST;
    return fpp_ffmpeg_plan_append(plan, value, value_length);
}

static inline int fpp_ffmpeg_filter_name(const char *graph, fpp_i32 begin, fpp_i32 end,
                                           char *name, fpp_i32 capacity) {
    fpp_i32 p = begin, n = 0;
    if (!graph || !name || capacity < 2 || begin < 0 || end < begin) return FPP_JSON_E_ARGUMENT;
    p = fpp_json_skip_ws(graph, end, p);
    while (p < end && graph[p] == '[') {
        while (p < end && graph[p] != ']') ++p;
        if (p >= end) return FPP_JSON_E_INVALID;
        p = fpp_json_skip_ws(graph, end, p + 1);
    }
    while (p < end && !fpp_json_is_ws(graph[p]) && graph[p] != '=' && graph[p] != ':' &&
           graph[p] != ',' && graph[p] != ';' && graph[p] != '[') {
        if (n + 1 >= capacity) return FPP_JSON_E_LIMIT;
        name[n++] = graph[p++];
    }
    if (n == 0) return FPP_JSON_E_INVALID;
    name[n] = 0;
    return FPP_JSON_OK;
}

static inline int fpp_ffmpeg_filtergraph_supported(const fpp_host_capabilities *caps,
                                                   const char *graph) {
    fpp_i32 length, begin = 0, i;
    char quote = 0;
    int escaped = 0;
    if (!caps || !graph) return FPP_JSON_E_ARGUMENT;
    length = fpp_ffmpeg_text_length(graph);
    if (length < 1) return FPP_JSON_E_INVALID;
    for (i = 0; i <= length; ++i) {
        const char c = graph[i];
        if (i == length && (quote || escaped)) return FPP_JSON_E_INVALID;
        if (i == length || (!quote && !escaped && (c == ',' || c == ';'))) {
            char name[128];
            if (fpp_ffmpeg_filter_name(graph, begin, i, name, sizeof(name)) != FPP_JSON_OK ||
                !fpp_host_supports_ffmpeg_filter(caps, name)) return FPP_JSON_E_HOST;
            begin = i + 1;
            escaped = 0;
            continue;
        }
        if (escaped) { escaped = 0; continue; }
        if (c == '\\') { escaped = 1; continue; }
        if (quote) { if (c == quote) quote = 0; continue; }
        if (c == '\'' || c == '"') quote = c;
    }
    if (quote || escaped) return FPP_JSON_E_INVALID;
    return FPP_JSON_OK;
}

static inline int fpp_ffmpeg_plan_add_filter(fpp_ffmpeg_plan *plan, const char *filtergraph) {
    if (!plan || !filtergraph || !fpp_ffmpeg_value_safe(filtergraph)) return FPP_JSON_E_INVALID;
    if (plan->caps && fpp_ffmpeg_filtergraph_supported(plan->caps, filtergraph) != FPP_JSON_OK) return FPP_JSON_E_HOST;
    return fpp_ffmpeg_plan_add_option(plan, "-vf", filtergraph);
}

static inline int fpp_ffmpeg_plan_write(fpp_ffmpeg_plan *plan, fpp_i32 *out_length) {
    if (!plan || !plan->active || !out_length) return FPP_JSON_E_ARGUMENT;
    if (!plan->closed) {
        if (fpp_json_writer_end(&plan->json) != FPP_JSON_OK ||
            fpp_json_writer_end(&plan->json) != FPP_JSON_OK) return plan->json.error;
        plan->closed = 1;
    }
    return fpp_json_writer_finish(&plan->json, out_length);
}

static inline int fpp_ffmpeg_plan_end(fpp_ffmpeg_plan *plan, fpp_i32 *out_length) {
    return fpp_ffmpeg_plan_write(plan, out_length);
}

static inline int fpp_ffmpeg_plan_respond(fpp_ffmpeg_plan *plan) {
    fpp_i32 length;
    int result = fpp_ffmpeg_plan_write(plan, &length);
    if (result != FPP_JSON_OK) return result;
    if (fpp_response_write(plan->json.buffer, length) < 0) return FPP_JSON_E_HOST;
    return FPP_JSON_OK;
}

#endif
