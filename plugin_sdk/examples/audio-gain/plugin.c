#include "ffmpegpp_plugin.h"
#include "manifest.generated.h"

/* This example parses only its small protocol, without libc or a JSON dependency.
 * The host validates field types and bounds too. Never return arbitrary ffmpeg args. */
static char request[16384];
static char response[128];

static int ws(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
static int after_ws(int p, int end) { while (p < end && ws(request[p])) ++p; return p; }
static int same(int begin, int end, const char *value) {
    int n = 0; while (value[n]) ++n;
    if (end - begin != n) return 0;
    for (int i = 0; i < n; ++i) if (request[begin + i] != value[i]) return 0;
    return 1;
}
static int string_end(int p, int end) {
    if (p >= end || request[p++] != '"') return -1;
    while (p < end) {
        if (request[p] == '"') return p + 1;
        if (request[p] == '\\') { p += 2; } else { ++p; }
    }
    return -1;
}
static int value_end(int p, int end) {
    p = after_ws(p, end);
    if (p >= end) return -1;
    if (request[p] == '"') return string_end(p, end);
    if (request[p] == '{' || request[p] == '[') {
        int depth = 0;
        while (p < end) {
            char c = request[p];
            if (c == '"') { p = string_end(p, end); if (p < 0) return -1; continue; }
            if (c == '{' || c == '[') ++depth;
            if (c == '}' || c == ']') { if (--depth == 0) return p + 1; }
            ++p;
        }
        return -1;
    }
    while (p < end && request[p] != ',' && request[p] != '}' && request[p] != ']' && !ws(request[p])) ++p;
    return p;
}
/* Return the direct member's value range; skip nested objects and escaped text. */
static int member(int begin, int end, const char *key, int *out_end) {
    int p = after_ws(begin, end);
    if (p >= end || request[p++] != '{') return -1;
    while ((p = after_ws(p, end)) < end && request[p] != '}') {
        int key_end = string_end(p, end);
        if (key_end < 0) return -1;
        int matched = same(p + 1, key_end - 1, key);
        p = after_ws(key_end, end);
        if (p >= end || request[p++] != ':') return -1;
        p = after_ws(p, end);
        int v_end = value_end(p, end);
        if (v_end < 0) return -1;
        if (matched) { *out_end = v_end; return p; }
        p = after_ws(v_end, end);
        if (p < end && request[p] == ',') ++p; else break;
    }
    return -1;
}
static int valid_gain(int begin, int end) {
    int p = begin, sign = 1, digits = 0;
    double value = 0.0, scale = 0.1;
    if (p < end && request[p] == '-') { sign = -1; ++p; }
    if (p >= end || request[p] < '0' || request[p] > '9') return 0;
    if (request[p] == '0' && p + 1 < end && request[p + 1] >= '0' && request[p + 1] <= '9') return 0;
    while (p < end && request[p] >= '0' && request[p] <= '9') {
        value = value * 10 + request[p++] - '0';
        if (++digits > 12) return 0;
    }
    if (p < end && request[p] == '.') {
        ++p; int fraction = 0;
        while (p < end && request[p] >= '0' && request[p] <= '9') {
            value += (request[p++] - '0') * scale; scale *= 0.1; ++fraction;
        }
        if (!fraction) return 0;
    }
    if (p < end && (request[p] == 'e' || request[p] == 'E')) {
        ++p; int negative = 0, exponent = 0, count = 0;
        if (p < end && (request[p] == '+' || request[p] == '-')) { negative = request[p] == '-'; ++p; }
        while (p < end && request[p] >= '0' && request[p] <= '9') {
            exponent = exponent * 10 + request[p++] - '0'; if (++count > 2 || exponent > 20) return 0;
        }
        if (!count) return 0;
        while (exponent-- > 0) { if (negative) value *= 0.1; else value *= 10; }
    }
    value *= sign;
    return p == end && value >= -60.0 && value <= 12.0;
}
static void error(void) { FPP_RESPOND_LITERAL("{\"error\":\"Invalid audio_gain request or gain outside [-60,12]\"}"); }

FPP_EXPORT(Basic_info) void Basic_info(void) { FPP_RESPOND_LITERAL(FPP_BASIC_JSON); }
FPP_EXPORT(Node_info) void Node_info(void) { FPP_RESPOND_LITERAL(FPP_NODES_JSON); }
FPP_EXPORT(Node_editor_add) void Node_editor_add(void) { FPP_RESPOND_LITERAL(FPP_EDITOR_JSON); }
FPP_EXPORT(Node_execute) void Node_execute(void) {
    int length = fpp_read_json(request, (int)sizeof(request));
    if (length < 0) { error(); return; }
    int end = 0;
    int node = member(0, length, "node_id", &end);
    if (node < 0 || !same(node, end, "\"audio_gain\"")) { error(); return; }
    int media = member(0, length, "media_type", &end);
    if (media < 0 || !same(media, end, "\"audio\"")) { error(); return; }
    int params = member(0, length, "params", &end), params_end = end;
    if (params < 0) { error(); return; }
    int gain = member(params, params_end, "decibels", &end);
    if (gain < 0 || end - gain > 32 || !valid_gain(gain, end)) { error(); return; }
    const char *prefix = "{\"operation\":\"audio.volume\",\"decibels\":";
    int n = 0;
    while (prefix[n]) { response[n] = prefix[n]; ++n; }
    for (int i = gain; i < end; ++i) response[n++] = request[i];
    response[n++] = '}';
    fpp_response_write(response, n);
}
