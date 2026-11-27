#include "ffmpegpp_plugin.h"
#include "manifest.generated.h"

static char request[16384];
static char response[128];

static int ws(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
static int after_ws(int p, int end) { while (p < end && ws(request[p])) ++p; return p; }

static int same(int begin, int end, const char *value) {
    int n = 0;
    while (value[n]) ++n;
    if (end - begin != n) return 0;
    for (int i = 0; i < n; ++i) {
        if (request[begin + i] != value[i]) return 0;
    }
    return 1;
}

static int string_end(int p, int end) {
    if (p >= end || request[p++] != '"') return -1;
    while (p < end) {
        if (request[p] == '"') return p + 1;
        if (request[p] == '\\') p += 2; else ++p;
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
            if (c == '"') {
                p = string_end(p, end);
                if (p < 0) return -1;
                continue;
            }
            if (c == '{' || c == '[') ++depth;
            if (c == '}' || c == ']') {
                if (--depth == 0) return p + 1;
            }
            ++p;
        }
        return -1;
    }
    while (p < end && request[p] != ',' && request[p] != '}' &&
           request[p] != ']' && !ws(request[p])) ++p;
    return p;
}

/* Return a direct object's member range, skipping nested values. */
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
        int value = value_end(p, end);
        if (value < 0) return -1;
        if (matched) {
            *out_end = value;
            return p;
        }
        p = after_ws(value, end);
        if (p < end && request[p] == ',') ++p; else break;
    }
    return -1;
}

static void error(void) {
    FPP_RESPOND_LITERAL("{\"error\":\"Invalid video_flip request or axis\"}");
}

FPP_EXPORT(Basic_info) void Basic_info(void) { FPP_RESPOND_LITERAL(FPP_BASIC_JSON); }
FPP_EXPORT(Node_info) void Node_info(void) { FPP_RESPOND_LITERAL(FPP_NODES_JSON); }
FPP_EXPORT(Node_editor_add) void Node_editor_add(void) { FPP_RESPOND_LITERAL(FPP_EDITOR_JSON); }

FPP_EXPORT(Node_execute) void Node_execute(void) {
    int length = fpp_read_json(request, (int)sizeof(request));
    if (length < 0) { error(); return; }

    int end = 0;
    int node = member(0, length, "node_id", &end);
    if (node < 0 || !same(node, end, "\"video_flip\"")) { error(); return; }
    int media = member(0, length, "media_type", &end);
    if (media < 0 || !same(media, end, "\"video\"")) { error(); return; }
    int params = member(0, length, "params", &end), params_end = end;
    if (params < 0) { error(); return; }
    int axis = member(params, params_end, "axis", &end);
    if (axis < 0 ||
        (!same(axis, end, "\"horizontal\"") &&
         !same(axis, end, "\"vertical\""))) {
        error();
        return;
    }

    const char *prefix = "{\"operation\":\"video.flip\",\"axis\":";
    int n = 0;
    while (prefix[n]) { response[n] = prefix[n]; ++n; }
    for (int i = axis; i < end; ++i) response[n++] = request[i];
    response[n++] = '}';
    fpp_response_write(response, n);
}
