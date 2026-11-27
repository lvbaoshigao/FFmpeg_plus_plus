#ifndef FFMPEGPP_JSON_H
#define FFMPEGPP_JSON_H

/* Bounded JSON helpers for freestanding C/C++ plugins.  No allocation, libc,
 * WASI or platform headers are required.  All offsets are byte offsets into
 * the caller-owned UTF-8 document. */

#ifndef FPP_I32_DEFINED
#define FPP_I32_DEFINED 1
typedef __INT32_TYPE__ fpp_i32;
#endif
#ifndef FPP_I64_DEFINED
#define FPP_I64_DEFINED 1
typedef __INT64_TYPE__ fpp_i64;
#endif
#ifndef FPP_U32_DEFINED
#define FPP_U32_DEFINED 1
typedef __UINT32_TYPE__ fpp_u32;
#endif
#ifndef FPP_U64_DEFINED
#define FPP_U64_DEFINED 1
typedef __UINT64_TYPE__ fpp_u64;
#endif

#define FPP_JSON_OK 0
#define FPP_JSON_E_INVALID (-1)
#define FPP_JSON_E_TYPE (-2)
#define FPP_JSON_E_NOT_FOUND (-3)
#define FPP_JSON_E_OVERFLOW (-4)
#define FPP_JSON_E_LIMIT (-5)
#define FPP_JSON_E_STATE (-6)
#define FPP_JSON_E_ARGUMENT (-7)
#define FPP_JSON_E_HOST (-8)

#define FPP_JSON_MAX_DOCUMENT 262144
#define FPP_JSON_MAX_DEPTH 32
#define FPP_JSON_MAX_ARRAY_ITEMS 256
#define FPP_JSON_MAX_OBJECT_MEMBERS 256
#define FPP_JSON_MAX_STRING_BYTES 65536
#define FPP_JSON_WRITER_DEPTH 32

typedef enum fpp_json_type {
    FPP_JSON_INVALID = 0,
    FPP_JSON_NULL = 1,
    FPP_JSON_BOOL = 2,
    FPP_JSON_NUMBER = 3,
    FPP_JSON_STRING = 4,
    FPP_JSON_ARRAY = 5,
    FPP_JSON_OBJECT = 6
} fpp_json_type;

typedef struct fpp_json_doc {
    const char *data;
    fpp_i32 length;
    fpp_i32 root_begin;
    fpp_i32 root_end;
    fpp_i32 max_depth;
} fpp_json_doc;

typedef struct fpp_json_value {
    const fpp_json_doc *doc;
    fpp_i32 begin;
    fpp_i32 end;
    fpp_i32 type;
} fpp_json_value;

typedef struct fpp_json_writer {
    char *buffer;
    fpp_i32 capacity;
    fpp_i32 length;
    fpp_i32 error;
    fpp_i32 depth;
    fpp_i32 root_done;
    unsigned char kind[FPP_JSON_WRITER_DEPTH];
    unsigned char state[FPP_JSON_WRITER_DEPTH];
    fpp_i32 count[FPP_JSON_WRITER_DEPTH];
} fpp_json_writer;

static inline int fpp_json_is_ws(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

static inline int fpp_json_hex(char c) {
    if (c >= '0' && c <= '9') return (int)(c - '0');
    if (c >= 'a' && c <= 'f') return (int)(c - 'a') + 10;
    if (c >= 'A' && c <= 'F') return (int)(c - 'A') + 10;
    return -1;
}

/* Decode one JSON string code point. The input position must point inside the
 * string (not at its surrounding quotes). Embedded NUL and invalid UTF-8 are
 * rejected because they are unsafe for plugin identifiers and argv values. */
static inline int fpp_json_next_codepoint(const char *data, fpp_i32 end,
                                          fpp_i32 *position, fpp_u32 *codepoint) {
    fpp_i32 p;
    unsigned char c;
    fpp_u32 value;
    if (!data || !position || !codepoint || *position < 0 || *position >= end) return FPP_JSON_E_INVALID;
    p = *position;
    c = (unsigned char)data[p++];
    if (c == '\\') {
        if (p >= end) return FPP_JSON_E_INVALID;
        c = (unsigned char)data[p++];
        switch (c) {
        case '"': value = 0x22; break;
        case '\\': value = 0x5c; break;
        case '/': value = 0x2f; break;
        case 'b': value = 0x08; break;
        case 'f': value = 0x0c; break;
        case 'n': value = 0x0a; break;
        case 'r': value = 0x0d; break;
        case 't': value = 0x09; break;
        case 'u': {
            int h0, h1, h2, h3;
            fpp_u32 low;
            if (p + 4 > end) return FPP_JSON_E_INVALID;
            h0 = fpp_json_hex(data[p]); h1 = fpp_json_hex(data[p + 1]);
            h2 = fpp_json_hex(data[p + 2]); h3 = fpp_json_hex(data[p + 3]);
            if (h0 < 0 || h1 < 0 || h2 < 0 || h3 < 0) return FPP_JSON_E_INVALID;
            value = (fpp_u32)((h0 << 12) | (h1 << 8) | (h2 << 4) | h3);
            p += 4;
            if (value >= 0xd800u && value <= 0xdbffu) {
                int l0, l1, l2, l3;
                if (p + 6 > end || data[p] != '\\' || data[p + 1] != 'u') return FPP_JSON_E_INVALID;
                l0 = fpp_json_hex(data[p + 2]); l1 = fpp_json_hex(data[p + 3]);
                l2 = fpp_json_hex(data[p + 4]); l3 = fpp_json_hex(data[p + 5]);
                if (l0 < 0 || l1 < 0 || l2 < 0 || l3 < 0) return FPP_JSON_E_INVALID;
                low = (fpp_u32)((l0 << 12) | (l1 << 8) | (l2 << 4) | l3);
                if (low < 0xdc00u || low > 0xdfffu) return FPP_JSON_E_INVALID;
                value = 0x10000u + ((value - 0xd800u) << 10) + (low - 0xdc00u);
                p += 6;
            } else if (value >= 0xdc00u && value <= 0xdfffu) {
                return FPP_JSON_E_INVALID;
            }
            break;
        }
        default: return FPP_JSON_E_INVALID;
        }
        if (value == 0) return FPP_JSON_E_INVALID;
        *position = p;
        *codepoint = value;
        return FPP_JSON_OK;
    }
    if (c < 0x20u || c == 0) return FPP_JSON_E_INVALID;
    if (c < 0x80u) {
        value = c;
    } else if (c >= 0xc2u && c <= 0xdfu) {
        unsigned char c1;
        if (p >= end) return FPP_JSON_E_INVALID;
        c1 = (unsigned char)data[p++];
        if ((c1 & 0xc0u) != 0x80u) return FPP_JSON_E_INVALID;
        value = ((fpp_u32)(c & 0x1fu) << 6) | (fpp_u32)(c1 & 0x3fu);
    } else if (c >= 0xe0u && c <= 0xefu) {
        unsigned char c1, c2;
        if (p + 1 >= end) return FPP_JSON_E_INVALID;
        c1 = (unsigned char)data[p++]; c2 = (unsigned char)data[p++];
        if ((c1 & 0xc0u) != 0x80u || (c2 & 0xc0u) != 0x80u ||
            (c == 0xe0u && c1 < 0xa0u) || (c == 0xedu && c1 >= 0xa0u)) return FPP_JSON_E_INVALID;
        value = ((fpp_u32)(c & 0x0fu) << 12) | ((fpp_u32)(c1 & 0x3fu) << 6) | (fpp_u32)(c2 & 0x3fu);
    } else if (c >= 0xf0u && c <= 0xf4u) {
        unsigned char c1, c2, c3;
        if (p + 2 >= end) return FPP_JSON_E_INVALID;
        c1 = (unsigned char)data[p++]; c2 = (unsigned char)data[p++]; c3 = (unsigned char)data[p++];
        if ((c1 & 0xc0u) != 0x80u || (c2 & 0xc0u) != 0x80u || (c3 & 0xc0u) != 0x80u ||
            (c == 0xf0u && c1 < 0x90u) || (c == 0xf4u && c1 >= 0x90u)) return FPP_JSON_E_INVALID;
        value = ((fpp_u32)(c & 0x07u) << 18) | ((fpp_u32)(c1 & 0x3fu) << 12) |
                ((fpp_u32)(c2 & 0x3fu) << 6) | (fpp_u32)(c3 & 0x3fu);
    } else {
        return FPP_JSON_E_INVALID;
    }
    if (value == 0 || value > 0x10ffffu || (value >= 0xd800u && value <= 0xdfffu)) return FPP_JSON_E_INVALID;
    *position = p;
    *codepoint = value;
    return FPP_JSON_OK;
}

static inline int fpp_json_next_text_codepoint(const char *data, fpp_i32 length,
                                              fpp_i32 *position, fpp_u32 *codepoint) {
    fpp_i32 p;
    if (!data || !position || !codepoint || *position < 0 || *position >= length) return FPP_JSON_E_INVALID;
    p = *position;
    /* Plain C text has no JSON escapes. The writer escapes ASCII itself;
     * only non-ASCII bytes need the shared UTF-8 decoder. */
    if ((unsigned char)data[p] < 0x80u) {
        *codepoint = (unsigned char)data[p];
        *position = p + 1;
        return FPP_JSON_OK;
    }
    return fpp_json_next_codepoint(data, length, position, codepoint);
}

static inline fpp_i32 fpp_json_skip_ws(const char *data, fpp_i32 length, fpp_i32 p) {
    while (p < length && fpp_json_is_ws(data[p])) ++p;
    return p;
}

static inline int fpp_json_string_end(const char *data, fpp_i32 length, fpp_i32 begin, fpp_i32 *out_end) {
    fpp_i32 p;
    fpp_u32 ignored;
    if (!data || !out_end || begin < 0 || begin >= length || data[begin] != '"') return FPP_JSON_E_INVALID;
    p = begin + 1;
    while (p < length && data[p] != '"') {
        if (fpp_json_next_codepoint(data, length, &p, &ignored) != FPP_JSON_OK) return FPP_JSON_E_INVALID;
    }
    if (p >= length) return FPP_JSON_E_INVALID;
    if (p - begin - 1 > FPP_JSON_MAX_STRING_BYTES) return FPP_JSON_E_LIMIT;
    *out_end = p + 1;
    return FPP_JSON_OK;
}

static inline int fpp_json_number_end(const char *data, fpp_i32 length, fpp_i32 begin, fpp_i32 *out_end) {
    fpp_i32 p = begin;
    fpp_i32 digits = 0;
    if (!data || !out_end || p < 0 || p >= length) return FPP_JSON_E_INVALID;
    if (data[p] == '-') { if (++p >= length) return FPP_JSON_E_INVALID; }
    if (data[p] == '0') {
        ++p;
        if (p < length && data[p] >= '0' && data[p] <= '9') return FPP_JSON_E_INVALID;
    } else {
        if (data[p] < '1' || data[p] > '9') return FPP_JSON_E_INVALID;
        while (p < length && data[p] >= '0' && data[p] <= '9') { ++p; if (++digits > FPP_JSON_MAX_STRING_BYTES) return FPP_JSON_E_LIMIT; }
    }
    if (p < length && data[p] == '.') {
        ++p;
        if (p >= length || data[p] < '0' || data[p] > '9') return FPP_JSON_E_INVALID;
        while (p < length && data[p] >= '0' && data[p] <= '9') { ++p; if (++digits > FPP_JSON_MAX_STRING_BYTES) return FPP_JSON_E_LIMIT; }
    }
    if (p < length && (data[p] == 'e' || data[p] == 'E')) {
        ++p;
        if (p < length && (data[p] == '+' || data[p] == '-')) ++p;
        if (p >= length || data[p] < '0' || data[p] > '9') return FPP_JSON_E_INVALID;
        while (p < length && data[p] >= '0' && data[p] <= '9') { ++p; if (++digits > FPP_JSON_MAX_STRING_BYTES) return FPP_JSON_E_LIMIT; }
    }
    *out_end = p;
    return FPP_JSON_OK;
}

typedef struct fpp_json_parser {
    const char *data;
    fpp_i32 length;
    fpp_i32 max_depth;
} fpp_json_parser;

static inline int fpp_json_string_equal(const char *data, fpp_i32 a_begin, fpp_i32 a_end,
                                        fpp_i32 b_begin, fpp_i32 b_end) {
    fpp_i32 a = a_begin, b = b_begin;
    fpp_u32 ac, bc;
    while (a < a_end && b < b_end) {
        if (fpp_json_next_codepoint(data, a_end, &a, &ac) != FPP_JSON_OK ||
            fpp_json_next_codepoint(data, b_end, &b, &bc) != FPP_JSON_OK || ac != bc) return 0;
    }
    return a == a_end && b == b_end;
}

static inline int fpp_json_string_equal_literal(const char *data, fpp_i32 begin, fpp_i32 end,
                                                const char *literal) {
    fpp_i32 p = begin, q = 0, length = 0;
    fpp_u32 a, b;
    if (!literal) return 0;
    while (literal[length]) { if (++length > FPP_JSON_MAX_STRING_BYTES) return 0; }
    while (p < end && q < length) {
        if (fpp_json_next_codepoint(data, end, &p, &a) != FPP_JSON_OK ||
            fpp_json_next_text_codepoint(literal, length, &q, &b) != FPP_JSON_OK || a != b) return 0;
    }
    return p == end && q == length;
}

static inline int fpp_json_parse_value(const fpp_json_parser *parser, fpp_i32 begin,
                                       fpp_i32 depth, fpp_i32 *out_end);

static inline int fpp_json_parse_object(const fpp_json_parser *parser, fpp_i32 begin,
                                        fpp_i32 depth, fpp_i32 *out_end) {
    fpp_i32 p = begin + 1, key_end, value_end;
    fpp_i32 member_count = 0;
    /* One offset per key keeps depth 32 within the 64 KiB WASM stack,
     * without recursively reparsing earlier values to detect duplicates. */
    fpp_i32 key_begins[FPP_JSON_MAX_OBJECT_MEMBERS];
    if (depth >= parser->max_depth) return FPP_JSON_E_LIMIT;
    p = fpp_json_skip_ws(parser->data, parser->length, p);
    if (p < parser->length && parser->data[p] == '}') { *out_end = p + 1; return FPP_JSON_OK; }
    while (p < parser->length) {
        fpp_i32 key_begin, i;
        if (member_count >= FPP_JSON_MAX_OBJECT_MEMBERS || parser->data[p] != '"') return FPP_JSON_E_LIMIT;
        key_begin = p + 1;
        if (fpp_json_string_end(parser->data, parser->length, p, &key_end) != FPP_JSON_OK) return FPP_JSON_E_INVALID;
        for (i = 0; i < member_count; ++i) {
            fpp_i32 previous_key_end;
            if (fpp_json_string_end(parser->data, p, key_begins[i], &previous_key_end) != FPP_JSON_OK) return FPP_JSON_E_INVALID;
            if (fpp_json_string_equal(parser->data, key_begin, key_end - 1,
                                      key_begins[i] + 1, previous_key_end - 1)) return FPP_JSON_E_INVALID;
        }
        key_begins[member_count++] = p;
        p = fpp_json_skip_ws(parser->data, parser->length, key_end);
        if (p >= parser->length || parser->data[p++] != ':') return FPP_JSON_E_INVALID;
        p = fpp_json_skip_ws(parser->data, parser->length, p);
        if (p >= parser->length || fpp_json_parse_value(parser, p, depth + 1, &value_end) != FPP_JSON_OK) return FPP_JSON_E_INVALID;
        p = fpp_json_skip_ws(parser->data, parser->length, value_end);
        if (p >= parser->length) return FPP_JSON_E_INVALID;
        if (parser->data[p] == '}') { *out_end = p + 1; return FPP_JSON_OK; }
        if (parser->data[p++] != ',') return FPP_JSON_E_INVALID;
        p = fpp_json_skip_ws(parser->data, parser->length, p);
        if (p >= parser->length || parser->data[p] == '}') return FPP_JSON_E_INVALID;
    }
    return FPP_JSON_E_INVALID;
}

static inline int fpp_json_parse_array(const fpp_json_parser *parser, fpp_i32 begin,
                                       fpp_i32 depth, fpp_i32 *out_end) {
    fpp_i32 p = fpp_json_skip_ws(parser->data, parser->length, begin + 1);
    fpp_i32 value_end, count = 0;
    if (depth >= parser->max_depth) return FPP_JSON_E_LIMIT;
    if (p < parser->length && parser->data[p] == ']') { *out_end = p + 1; return FPP_JSON_OK; }
    while (p < parser->length) {
        if (count >= FPP_JSON_MAX_ARRAY_ITEMS) return FPP_JSON_E_LIMIT;
        if (fpp_json_parse_value(parser, p, depth + 1, &value_end) != FPP_JSON_OK) return FPP_JSON_E_INVALID;
        ++count;
        p = fpp_json_skip_ws(parser->data, parser->length, value_end);
        if (p >= parser->length) return FPP_JSON_E_INVALID;
        if (parser->data[p] == ']') { *out_end = p + 1; return FPP_JSON_OK; }
        if (parser->data[p++] != ',') return FPP_JSON_E_INVALID;
        p = fpp_json_skip_ws(parser->data, parser->length, p);
        if (p >= parser->length || parser->data[p] == ']') return FPP_JSON_E_INVALID;
    }
    return FPP_JSON_E_INVALID;
}

static inline int fpp_json_parse_value(const fpp_json_parser *parser, fpp_i32 begin,
                                       fpp_i32 depth, fpp_i32 *out_end) {
    char c;
    if (!parser || !out_end || begin < 0 || begin >= parser->length || depth > parser->max_depth) return FPP_JSON_E_LIMIT;
    c = parser->data[begin];
    if (c == '"') return fpp_json_string_end(parser->data, parser->length, begin, out_end);
    if (c == '{') return fpp_json_parse_object(parser, begin, depth, out_end);
    if (c == '[') return fpp_json_parse_array(parser, begin, depth, out_end);
    if (c == '-' || (c >= '0' && c <= '9')) return fpp_json_number_end(parser->data, parser->length, begin, out_end);
    if (c == 't' && begin + 4 <= parser->length && parser->data[begin + 1] == 'r' && parser->data[begin + 2] == 'u' && parser->data[begin + 3] == 'e') { *out_end = begin + 4; return FPP_JSON_OK; }
    if (c == 'f' && begin + 5 <= parser->length && parser->data[begin + 1] == 'a' && parser->data[begin + 2] == 'l' && parser->data[begin + 3] == 's' && parser->data[begin + 4] == 'e') { *out_end = begin + 5; return FPP_JSON_OK; }
    if (c == 'n' && begin + 4 <= parser->length && parser->data[begin + 1] == 'u' && parser->data[begin + 2] == 'l' && parser->data[begin + 3] == 'l') { *out_end = begin + 4; return FPP_JSON_OK; }
    return FPP_JSON_E_INVALID;
}

static inline fpp_i32 fpp_json_value_type_at(const fpp_json_doc *doc, fpp_i32 begin) {
    if (!doc || begin < 0 || begin >= doc->length) return FPP_JSON_INVALID;
    switch (doc->data[begin]) {
    case 'n': return FPP_JSON_NULL;
    case 't': case 'f': return FPP_JSON_BOOL;
    case '-': case '0': case '1': case '2': case '3': case '4': case '5': case '6': case '7': case '8': case '9': return FPP_JSON_NUMBER;
    case '"': return FPP_JSON_STRING;
    case '[': return FPP_JSON_ARRAY;
    case '{': return FPP_JSON_OBJECT;
    default: return FPP_JSON_INVALID;
    }
}

static inline int fpp_json_parse(fpp_json_doc *doc, const char *json, fpp_i32 length) {
    fpp_json_parser parser;
    fpp_i32 begin, root_end, document_end;
    if (!doc || !json || length < 1 || length > FPP_JSON_MAX_DOCUMENT) return FPP_JSON_E_ARGUMENT;
    parser.data = json; parser.length = length; parser.max_depth = FPP_JSON_MAX_DEPTH;
    begin = fpp_json_skip_ws(json, length, 0);
    if (begin >= length || fpp_json_parse_value(&parser, begin, 0, &root_end) != FPP_JSON_OK) return FPP_JSON_E_INVALID;
    document_end = fpp_json_skip_ws(json, length, root_end);
    if (document_end != length) return FPP_JSON_E_INVALID;
    doc->data = json; doc->length = length; doc->root_begin = begin; doc->root_end = root_end; doc->max_depth = FPP_JSON_MAX_DEPTH;
    return FPP_JSON_OK;
}

static inline int fpp_json_root(const fpp_json_doc *doc, fpp_json_value *out) {
    if (!doc || !out || !doc->data || doc->root_begin < 0 || doc->root_end <= doc->root_begin) return FPP_JSON_E_ARGUMENT;
    out->doc = doc; out->begin = doc->root_begin; out->end = doc->root_end; out->type = fpp_json_value_type_at(doc, doc->root_begin);
    return out->type == FPP_JSON_INVALID ? FPP_JSON_E_INVALID : FPP_JSON_OK;
}

static inline int fpp_json_object_get(const fpp_json_value *object, const char *key, fpp_json_value *out) {
    fpp_i32 p, key_end, value_end;
    fpp_json_parser parser;
    if (!object || !key || !out || object->type != FPP_JSON_OBJECT || !object->doc) return FPP_JSON_E_TYPE;
    parser.data = object->doc->data; parser.length = object->doc->length; parser.max_depth = object->doc->max_depth;
    p = fpp_json_skip_ws(parser.data, object->end, object->begin + 1);
    while (p < object->end && parser.data[p] != '}') {
        fpp_i32 key_begin;
        if (parser.data[p] != '"') return FPP_JSON_E_INVALID;
        key_begin = p + 1;
        if (fpp_json_string_end(parser.data, object->end, p, &key_end) != FPP_JSON_OK) return FPP_JSON_E_INVALID;
        p = fpp_json_skip_ws(parser.data, object->end, key_end);
        if (p >= object->end || parser.data[p++] != ':') return FPP_JSON_E_INVALID;
        p = fpp_json_skip_ws(parser.data, object->end, p);
        if (fpp_json_parse_value(&parser, p, 0, &value_end) != FPP_JSON_OK || value_end > object->end) return FPP_JSON_E_INVALID;
        if (fpp_json_string_equal_literal(parser.data, key_begin, key_end - 1, key)) {
            out->doc = object->doc; out->begin = p; out->end = value_end; out->type = fpp_json_value_type_at(object->doc, p); return FPP_JSON_OK;
        }
        p = fpp_json_skip_ws(parser.data, object->end, value_end);
        if (p < object->end && parser.data[p] == ',') p = fpp_json_skip_ws(parser.data, object->end, p + 1); else break;
    }
    return FPP_JSON_E_NOT_FOUND;
}

static inline int fpp_json_lookup(const fpp_json_value *root, const char *path, fpp_json_value *out) {
    fpp_json_value current;
    fpp_i32 p = 0, start;
    if (!root || !path || !out) return FPP_JSON_E_ARGUMENT;
    current = *root;
    if (!path[0]) { *out = current; return FPP_JSON_OK; }
    while (path[p]) {
        char key[128];
        fpp_i32 n = 0;
        start = p;
        while (path[p] && path[p] != '.') { if (n >= (fpp_i32)sizeof(key) - 1) return FPP_JSON_E_LIMIT; key[n++] = path[p++]; }
        if (p == start) return FPP_JSON_E_INVALID;
        key[n] = 0;
        if (fpp_json_object_get(&current, key, &current) != FPP_JSON_OK) return FPP_JSON_E_NOT_FOUND;
        if (path[p] == '.') ++p;
    }
    *out = current;
    return FPP_JSON_OK;
}

static inline int fpp_json_array_length(const fpp_json_value *array, fpp_i32 *out_length) {
    fpp_json_parser parser;
    fpp_i32 p, end, count = 0;
    if (!array || !out_length || array->type != FPP_JSON_ARRAY || !array->doc) return FPP_JSON_E_TYPE;
    parser.data = array->doc->data; parser.length = array->doc->length; parser.max_depth = array->doc->max_depth;
    p = fpp_json_skip_ws(parser.data, array->end, array->begin + 1);
    if (p < array->end && parser.data[p] == ']') { *out_length = 0; return FPP_JSON_OK; }
    while (p < array->end) {
        if (fpp_json_parse_value(&parser, p, 0, &end) != FPP_JSON_OK || end > array->end) return FPP_JSON_E_INVALID;
        ++count; if (count > FPP_JSON_MAX_ARRAY_ITEMS) return FPP_JSON_E_LIMIT;
        p = fpp_json_skip_ws(parser.data, array->end, end);
        if (p < array->end && parser.data[p] == ']') { *out_length = count; return FPP_JSON_OK; }
        if (p >= array->end || parser.data[p++] != ',') return FPP_JSON_E_INVALID;
        p = fpp_json_skip_ws(parser.data, array->end, p);
    }
    return FPP_JSON_E_INVALID;
}

static inline int fpp_json_array_at(const fpp_json_value *array, fpp_i32 index, fpp_json_value *out) {
    fpp_json_parser parser;
    fpp_i32 p, end, i = 0;
    if (!array || !out || index < 0 || array->type != FPP_JSON_ARRAY || !array->doc) return FPP_JSON_E_TYPE;
    parser.data = array->doc->data; parser.length = array->doc->length; parser.max_depth = array->doc->max_depth;
    p = fpp_json_skip_ws(parser.data, array->end, array->begin + 1);
    while (p < array->end && parser.data[p] != ']') {
        if (fpp_json_parse_value(&parser, p, 0, &end) != FPP_JSON_OK || end > array->end) return FPP_JSON_E_INVALID;
        if (i == index) { out->doc = array->doc; out->begin = p; out->end = end; out->type = fpp_json_value_type_at(array->doc, p); return FPP_JSON_OK; }
        ++i; p = fpp_json_skip_ws(parser.data, array->end, end);
        if (p >= array->end || parser.data[p++] != ',') break;
        p = fpp_json_skip_ws(parser.data, array->end, p);
    }
    return FPP_JSON_E_NOT_FOUND;
}

static inline int fpp_json_get_bool(const fpp_json_value *value, int *out) {
    if (!value || !out || value->type != FPP_JSON_BOOL) return FPP_JSON_E_TYPE;
    *out = value->doc->data[value->begin] == 't';
    return FPP_JSON_OK;
}

static inline int fpp_json_get_i64(const fpp_json_value *value, fpp_i64 *out) {
    fpp_i32 p, end, negative = 0;
    fpp_u64 magnitude = 0, limit;
    if (!value || !out || value->type != FPP_JSON_NUMBER || !value->doc) return FPP_JSON_E_TYPE;
    p = value->begin; end = value->end;
    if (value->doc->data[p] == '-') { negative = 1; ++p; }
    if (p >= end) return FPP_JSON_E_INVALID;
    if (p < end && value->doc->data[p] == '0') { ++p; if (p != end) return FPP_JSON_E_TYPE; *out = 0; return FPP_JSON_OK; }
    limit = negative ? (fpp_u64)9223372036854775808ull : (fpp_u64)9223372036854775807ull;
    while (p < end) {
        fpp_u32 digit;
        if (value->doc->data[p] < '0' || value->doc->data[p] > '9') return FPP_JSON_E_TYPE;
        digit = (fpp_u32)(value->doc->data[p++] - '0');
        if (magnitude > (limit - digit) / 10u) return FPP_JSON_E_OVERFLOW;
        magnitude = magnitude * 10u + digit;
    }
    if (negative) {
        if (magnitude == (fpp_u64)9223372036854775808ull) *out = (fpp_i64)(-9223372036854775807ll - 1ll);
        else *out = -(fpp_i64)magnitude;
    } else *out = (fpp_i64)magnitude;
    return FPP_JSON_OK;
}

static inline int fpp_json_get_i32(const fpp_json_value *value, fpp_i32 *out) {
    fpp_i64 number;
    if (!out) return FPP_JSON_E_ARGUMENT;
    if (fpp_json_get_i64(value, &number) != FPP_JSON_OK) return FPP_JSON_E_TYPE;
    if (number < (fpp_i64)-2147483648ll || number > (fpp_i64)2147483647ll) return FPP_JSON_E_OVERFLOW;
    *out = (fpp_i32)number;
    return FPP_JSON_OK;
}

static inline int fpp_json_get_number(const fpp_json_value *value, double *out) {
    fpp_i32 p, end, exponent = 0, exponent_negative = 0, negative = 0;
    double number = 0.0;
    if (!value || !out || value->type != FPP_JSON_NUMBER || !value->doc) return FPP_JSON_E_TYPE;
    p = value->begin; end = value->end;
    if (value->doc->data[p] == '-') { negative = 1; ++p; }
    while (p < end && value->doc->data[p] >= '0' && value->doc->data[p] <= '9') number = number * 10.0 + (double)(value->doc->data[p++] - '0');
    if (p < end && value->doc->data[p] == '.') {
        double scale = 0.1; ++p;
        while (p < end && value->doc->data[p] >= '0' && value->doc->data[p] <= '9') { number += (double)(value->doc->data[p++] - '0') * scale; scale *= 0.1; }
    }
    if (p < end && (value->doc->data[p] == 'e' || value->doc->data[p] == 'E')) {
        ++p; if (p < end && (value->doc->data[p] == '+' || value->doc->data[p] == '-')) { exponent_negative = value->doc->data[p] == '-'; ++p; }
        while (p < end && value->doc->data[p] >= '0' && value->doc->data[p] <= '9') { if (exponent < 10000) exponent = exponent * 10 + (value->doc->data[p] - '0'); ++p; }
    }
    if (p != end || exponent > 308) return FPP_JSON_E_OVERFLOW;
    while (exponent-- > 0) number = exponent_negative ? number * 0.1 : number * 10.0;
    if (negative) number = -number;
    if (!(number == number) || number > 1.7976931348623157e308 || number < -1.7976931348623157e308) return FPP_JSON_E_OVERFLOW;
    *out = number;
    return FPP_JSON_OK;
}

static inline int fpp_json_get_string(const fpp_json_value *value, char *out,
                                      fpp_i32 capacity, fpp_i32 *out_length) {
    fpp_i32 p, decoded = 0;
    fpp_u32 cp;
    if (!value || !out || !out_length || value->type != FPP_JSON_STRING || !value->doc || capacity < 1) return FPP_JSON_E_ARGUMENT;
    p = value->begin + 1;
    while (p < value->end - 1) {
        if (fpp_json_next_codepoint(value->doc->data, value->end - 1, &p, &cp) != FPP_JSON_OK) return FPP_JSON_E_INVALID;
        decoded += cp < 0x80u ? 1 : (cp < 0x800u ? 2 : (cp < 0x10000u ? 3 : 4));
        if (decoded >= capacity) { *out_length = decoded; return FPP_JSON_E_OVERFLOW; }
    }
    p = value->begin + 1; decoded = 0;
    while (p < value->end - 1) {
        if (fpp_json_next_codepoint(value->doc->data, value->end - 1, &p, &cp) != FPP_JSON_OK) return FPP_JSON_E_INVALID;
        if (cp < 0x80u) { out[decoded++] = (char)cp; }
        else if (cp < 0x800u) { out[decoded++] = (char)(0xc0u | (cp >> 6)); out[decoded++] = (char)(0x80u | (cp & 0x3fu)); }
        else if (cp < 0x10000u) { out[decoded++] = (char)(0xe0u | (cp >> 12)); out[decoded++] = (char)(0x80u | ((cp >> 6) & 0x3fu)); out[decoded++] = (char)(0x80u | (cp & 0x3fu)); }
        else { out[decoded++] = (char)(0xf0u | (cp >> 18)); out[decoded++] = (char)(0x80u | ((cp >> 12) & 0x3fu)); out[decoded++] = (char)(0x80u | ((cp >> 6) & 0x3fu)); out[decoded++] = (char)(0x80u | (cp & 0x3fu)); }
    }
    out[decoded] = 0; *out_length = decoded; return FPP_JSON_OK;
}

static inline int fpp_json_string_equals(const fpp_json_value *value, const char *literal) {
    if (!value || !literal || value->type != FPP_JSON_STRING || !value->doc) return 0;
    return fpp_json_string_equal_literal(value->doc->data, value->begin + 1, value->end - 1, literal);
}

typedef struct fpp_host_capabilities {
    fpp_i32 api_version;
    fpp_i32 ffmpeg_api_version;
    fpp_i32 max_arguments;
    fpp_i32 max_argument_bytes;
    fpp_i32 max_total_argument_bytes;
    fpp_i32 has_max_arguments;
    fpp_i32 has_max_argument_bytes;
    fpp_i32 has_max_total_argument_bytes;
    fpp_json_value host;
    fpp_json_value operations;
    fpp_json_value ffmpeg;
    fpp_json_value options;
    fpp_json_value filters;
    fpp_json_value limits;
} fpp_host_capabilities;

static inline int fpp_host_capabilities_init(const fpp_json_value *request, fpp_host_capabilities *out) {
    fpp_json_value version;
    if (!request || !out || request->type != FPP_JSON_OBJECT) return FPP_JSON_E_TYPE;
    out->api_version = 0; out->ffmpeg_api_version = 0;
    out->max_arguments = 0; out->max_argument_bytes = 0; out->max_total_argument_bytes = 0;
    out->has_max_arguments = 0; out->has_max_argument_bytes = 0; out->has_max_total_argument_bytes = 0;
    out->host = (fpp_json_value){0, 0, 0, FPP_JSON_INVALID};
    out->operations = out->host; out->ffmpeg = out->host; out->options = out->host; out->filters = out->host; out->limits = out->host;
    if (fpp_json_object_get(request, "host", &out->host) != FPP_JSON_OK || out->host.type != FPP_JSON_OBJECT) return FPP_JSON_E_NOT_FOUND;
    if (fpp_json_object_get(&out->host, "api_version", &version) != FPP_JSON_OK || fpp_json_get_i32(&version, &out->api_version) != FPP_JSON_OK || out->api_version != 1) return FPP_JSON_E_INVALID;
    if (fpp_json_object_get(&out->host, "operations", &out->operations) != FPP_JSON_OK || out->operations.type != FPP_JSON_ARRAY) return FPP_JSON_E_INVALID;
    if (fpp_json_object_get(&out->host, "ffmpeg", &out->ffmpeg) == FPP_JSON_OK) {
        if (out->ffmpeg.type != FPP_JSON_OBJECT ||
            fpp_json_object_get(&out->ffmpeg, "api_version", &version) != FPP_JSON_OK ||
            fpp_json_get_i32(&version, &out->ffmpeg_api_version) != FPP_JSON_OK || out->ffmpeg_api_version != 1) return FPP_JSON_E_TYPE;
        if (fpp_json_object_get(&out->ffmpeg, "options", &out->options) != FPP_JSON_OK || out->options.type != FPP_JSON_ARRAY ||
            fpp_json_object_get(&out->ffmpeg, "filters", &out->filters) != FPP_JSON_OK || out->filters.type != FPP_JSON_ARRAY) return FPP_JSON_E_TYPE;
        if (fpp_json_object_get(&out->ffmpeg, "max_arguments", &version) == FPP_JSON_OK) {
            out->has_max_arguments = 1;
            if (fpp_json_get_i32(&version, &out->max_arguments) != FPP_JSON_OK) return FPP_JSON_E_TYPE;
        }
        if (fpp_json_object_get(&out->ffmpeg, "max_argument_bytes", &version) == FPP_JSON_OK) {
            out->has_max_argument_bytes = 1;
            if (fpp_json_get_i32(&version, &out->max_argument_bytes) != FPP_JSON_OK) return FPP_JSON_E_TYPE;
        }
        if (fpp_json_object_get(&out->ffmpeg, "max_total_argument_bytes", &version) == FPP_JSON_OK) {
            out->has_max_total_argument_bytes = 1;
            if (fpp_json_get_i32(&version, &out->max_total_argument_bytes) != FPP_JSON_OK) return FPP_JSON_E_TYPE;
        }
        if ((out->max_arguments < 0) || (out->max_argument_bytes < 0) || (out->max_total_argument_bytes < 0)) return FPP_JSON_E_INVALID;
    }
    return FPP_JSON_OK;
}

static inline int fpp_host_array_contains(const fpp_json_value *array, const char *name) {
    fpp_i32 count, i;
    fpp_json_value value;
    if (!array || !name || array->type != FPP_JSON_ARRAY || fpp_json_array_length(array, &count) != FPP_JSON_OK) return 0;
    for (i = 0; i < count; ++i) if (fpp_json_array_at(array, i, &value) == FPP_JSON_OK && fpp_json_string_equals(&value, name)) return 1;
    return 0;
}

static inline int fpp_host_supports_operation(const fpp_host_capabilities *caps, const char *name) {
    return caps && fpp_host_array_contains(&caps->operations, name);
}
static inline int fpp_host_supports_ffmpeg_option(const fpp_host_capabilities *caps, const char *name) {
    return caps && fpp_host_array_contains(&caps->options, name);
}
static inline int fpp_host_supports_ffmpeg_filter(const fpp_host_capabilities *caps, const char *name) {
    return caps && fpp_host_array_contains(&caps->filters, name);
}

static inline int fpp_json_writer_fail(fpp_json_writer *writer, int error) {
    if (writer && writer->error == FPP_JSON_OK) writer->error = error;
    return error;
}

static inline void fpp_json_writer_init(fpp_json_writer *writer, char *buffer, fpp_i32 capacity) {
    fpp_i32 i;
    if (!writer) return;
    writer->buffer = buffer; writer->capacity = capacity; writer->length = 0; writer->error = FPP_JSON_OK; writer->depth = 0; writer->root_done = 0;
    for (i = 0; i < FPP_JSON_WRITER_DEPTH; ++i) { writer->kind[i] = 0; writer->state[i] = 0; writer->count[i] = 0; }
    if (!buffer || capacity < 1) writer->error = FPP_JSON_E_ARGUMENT;
}

static inline int fpp_json_writer_put(fpp_json_writer *writer, char c) {
    if (!writer || writer->error != FPP_JSON_OK) return writer ? writer->error : FPP_JSON_E_ARGUMENT;
    if (writer->length >= writer->capacity) return fpp_json_writer_fail(writer, FPP_JSON_E_OVERFLOW);
    writer->buffer[writer->length++] = c; return FPP_JSON_OK;
}

static inline int fpp_json_writer_prepare_value(fpp_json_writer *writer) {
    fpp_i32 top;
    if (!writer || writer->error != FPP_JSON_OK) return writer ? writer->error : FPP_JSON_E_ARGUMENT;
    if (writer->depth == 0) {
        if (writer->root_done) return fpp_json_writer_fail(writer, FPP_JSON_E_STATE);
        writer->root_done = 1; return FPP_JSON_OK;
    }
    top = writer->depth - 1;
    if (writer->kind[top] == 1) {
        if (writer->state[top] != 1) return fpp_json_writer_fail(writer, FPP_JSON_E_STATE);
        writer->state[top] = 0; ++writer->count[top];
    } else {
        if (writer->count[top] > 0 && fpp_json_writer_put(writer, ',') != FPP_JSON_OK) return writer->error;
        ++writer->count[top];
    }
    return FPP_JSON_OK;
}

static inline int fpp_json_writer_begin_object(fpp_json_writer *writer) {
    if (fpp_json_writer_prepare_value(writer) != FPP_JSON_OK) return writer ? writer->error : FPP_JSON_E_ARGUMENT;
    if (writer->depth >= FPP_JSON_WRITER_DEPTH) return fpp_json_writer_fail(writer, FPP_JSON_E_LIMIT);
    if (fpp_json_writer_put(writer, '{') != FPP_JSON_OK) return writer->error;
    writer->kind[writer->depth] = 1; writer->state[writer->depth] = 0; writer->count[writer->depth] = 0; ++writer->depth;
    return FPP_JSON_OK;
}

static inline int fpp_json_writer_begin_array(fpp_json_writer *writer) {
    if (fpp_json_writer_prepare_value(writer) != FPP_JSON_OK) return writer ? writer->error : FPP_JSON_E_ARGUMENT;
    if (writer->depth >= FPP_JSON_WRITER_DEPTH) return fpp_json_writer_fail(writer, FPP_JSON_E_LIMIT);
    if (fpp_json_writer_put(writer, '[') != FPP_JSON_OK) return writer->error;
    writer->kind[writer->depth] = 2; writer->state[writer->depth] = 0; writer->count[writer->depth] = 0; ++writer->depth;
    return FPP_JSON_OK;
}

static inline int fpp_json_writer_key(fpp_json_writer *writer, const char *key) {
    fpp_i32 n = 0, p;
    fpp_u32 cp;
    if (!writer || !key || writer->depth < 1 || writer->kind[writer->depth - 1] != 1 || writer->state[writer->depth - 1] != 0) return fpp_json_writer_fail(writer, FPP_JSON_E_STATE);
    while (key[n]) { if (++n > FPP_JSON_MAX_STRING_BYTES) return fpp_json_writer_fail(writer, FPP_JSON_E_LIMIT); }
    if (writer->count[writer->depth - 1] > 0 && fpp_json_writer_put(writer, ',') != FPP_JSON_OK) return writer->error;
    if (fpp_json_writer_put(writer, '"') != FPP_JSON_OK) return writer->error;
    p = 0;
    while (p < n) {
        fpp_i32 next = p;
        if (fpp_json_next_text_codepoint(key, n, &next, &cp) != FPP_JSON_OK) return fpp_json_writer_fail(writer, FPP_JSON_E_INVALID);
        if (cp == '"') { if (fpp_json_writer_put(writer, '\\') != FPP_JSON_OK || fpp_json_writer_put(writer, '"') != FPP_JSON_OK) return writer->error; }
        else if (cp == '\\') { if (fpp_json_writer_put(writer, '\\') != FPP_JSON_OK || fpp_json_writer_put(writer, '\\') != FPP_JSON_OK) return writer->error; }
        else if (cp == '\n' || cp == '\r' || cp == '\t' || cp == '\b' || cp == '\f') {
            char esc = cp == '\n' ? 'n' : (cp == '\r' ? 'r' : (cp == '\t' ? 't' : (cp == '\b' ? 'b' : 'f')));
            if (fpp_json_writer_put(writer, '\\') != FPP_JSON_OK || fpp_json_writer_put(writer, esc) != FPP_JSON_OK) return writer->error;
        } else if (cp < 0x20u) {
            static const char hex[] = "0123456789abcdef";
            if (fpp_json_writer_put(writer, '\\') != FPP_JSON_OK ||
                fpp_json_writer_put(writer, 'u') != FPP_JSON_OK ||
                fpp_json_writer_put(writer, '0') != FPP_JSON_OK ||
                fpp_json_writer_put(writer, '0') != FPP_JSON_OK ||
                fpp_json_writer_put(writer, hex[(cp >> 4) & 0x0fu]) != FPP_JSON_OK ||
                fpp_json_writer_put(writer, hex[cp & 0x0fu]) != FPP_JSON_OK) return writer->error;
        }
        else if (cp < 0x80u) { if (fpp_json_writer_put(writer, (char)cp) != FPP_JSON_OK) return writer->error; }
        else if (cp < 0x800u) { if (fpp_json_writer_put(writer, (char)(0xc0u | (cp >> 6))) != FPP_JSON_OK || fpp_json_writer_put(writer, (char)(0x80u | (cp & 0x3fu))) != FPP_JSON_OK) return writer->error; }
        else if (cp < 0x10000u) { if (fpp_json_writer_put(writer, (char)(0xe0u | (cp >> 12))) != FPP_JSON_OK || fpp_json_writer_put(writer, (char)(0x80u | ((cp >> 6) & 0x3fu))) != FPP_JSON_OK || fpp_json_writer_put(writer, (char)(0x80u | (cp & 0x3fu))) != FPP_JSON_OK) return writer->error; }
        else { if (fpp_json_writer_put(writer, (char)(0xf0u | (cp >> 18))) != FPP_JSON_OK || fpp_json_writer_put(writer, (char)(0x80u | ((cp >> 12) & 0x3fu))) != FPP_JSON_OK || fpp_json_writer_put(writer, (char)(0x80u | ((cp >> 6) & 0x3fu))) != FPP_JSON_OK || fpp_json_writer_put(writer, (char)(0x80u | (cp & 0x3fu))) != FPP_JSON_OK) return writer->error; }
        p = next;
    }
    if (fpp_json_writer_put(writer, '"') != FPP_JSON_OK || fpp_json_writer_put(writer, ':') != FPP_JSON_OK) return writer->error;
    writer->state[writer->depth - 1] = 1;
    return FPP_JSON_OK;
}

static inline int fpp_json_writer_string(fpp_json_writer *writer, const char *value) {
    fpp_i32 n = 0, p;
    fpp_u32 cp;
    if (!value) return fpp_json_writer_fail(writer, FPP_JSON_E_ARGUMENT);
    while (value[n]) { if (++n > FPP_JSON_MAX_STRING_BYTES) return fpp_json_writer_fail(writer, FPP_JSON_E_LIMIT); }
    if (fpp_json_writer_prepare_value(writer) != FPP_JSON_OK) return writer ? writer->error : FPP_JSON_E_ARGUMENT;
    if (fpp_json_writer_put(writer, '"') != FPP_JSON_OK) return writer->error;
    p = 0;
    while (p < n) {
        fpp_i32 next = p;
        if (fpp_json_next_text_codepoint(value, n, &next, &cp) != FPP_JSON_OK) return fpp_json_writer_fail(writer, FPP_JSON_E_INVALID);
        if (cp == '"') { if (fpp_json_writer_put(writer, '\\') != FPP_JSON_OK || fpp_json_writer_put(writer, '"') != FPP_JSON_OK) return writer->error; }
        else if (cp == '\\') { if (fpp_json_writer_put(writer, '\\') != FPP_JSON_OK || fpp_json_writer_put(writer, '\\') != FPP_JSON_OK) return writer->error; }
        else if (cp == '\n' || cp == '\r' || cp == '\t' || cp == '\b' || cp == '\f') {
            char esc = cp == '\n' ? 'n' : (cp == '\r' ? 'r' : (cp == '\t' ? 't' : (cp == '\b' ? 'b' : 'f')));
            if (fpp_json_writer_put(writer, '\\') != FPP_JSON_OK || fpp_json_writer_put(writer, esc) != FPP_JSON_OK) return writer->error;
        } else if (cp < 0x20u) {
            static const char hex[] = "0123456789abcdef";
            if (fpp_json_writer_put(writer, '\\') != FPP_JSON_OK ||
                fpp_json_writer_put(writer, 'u') != FPP_JSON_OK ||
                fpp_json_writer_put(writer, '0') != FPP_JSON_OK ||
                fpp_json_writer_put(writer, '0') != FPP_JSON_OK ||
                fpp_json_writer_put(writer, hex[(cp >> 4) & 0x0fu]) != FPP_JSON_OK ||
                fpp_json_writer_put(writer, hex[cp & 0x0fu]) != FPP_JSON_OK) return writer->error;
        }
        else if (cp < 0x80u) { if (fpp_json_writer_put(writer, (char)cp) != FPP_JSON_OK) return writer->error; }
        else if (cp < 0x800u) { if (fpp_json_writer_put(writer, (char)(0xc0u | (cp >> 6))) != FPP_JSON_OK || fpp_json_writer_put(writer, (char)(0x80u | (cp & 0x3fu))) != FPP_JSON_OK) return writer->error; }
        else if (cp < 0x10000u) { if (fpp_json_writer_put(writer, (char)(0xe0u | (cp >> 12))) != FPP_JSON_OK || fpp_json_writer_put(writer, (char)(0x80u | ((cp >> 6) & 0x3fu))) != FPP_JSON_OK || fpp_json_writer_put(writer, (char)(0x80u | (cp & 0x3fu))) != FPP_JSON_OK) return writer->error; }
        else { if (fpp_json_writer_put(writer, (char)(0xf0u | (cp >> 18))) != FPP_JSON_OK || fpp_json_writer_put(writer, (char)(0x80u | ((cp >> 12) & 0x3fu))) != FPP_JSON_OK || fpp_json_writer_put(writer, (char)(0x80u | ((cp >> 6) & 0x3fu))) != FPP_JSON_OK || fpp_json_writer_put(writer, (char)(0x80u | (cp & 0x3fu))) != FPP_JSON_OK) return writer->error; }
        p = next;
    }
    return fpp_json_writer_put(writer, '"');
}

static inline int fpp_json_writer_i64(fpp_json_writer *writer, fpp_i64 value) {
    char digits[32]; fpp_i32 n = 0, i; fpp_u64 magnitude;
    if (fpp_json_writer_prepare_value(writer) != FPP_JSON_OK) return writer ? writer->error : FPP_JSON_E_ARGUMENT;
    if (value < 0) { if (fpp_json_writer_put(writer, '-') != FPP_JSON_OK) return writer->error; magnitude = (fpp_u64)(-(value + 1)) + 1u; } else magnitude = (fpp_u64)value;
    do { digits[n++] = (char)('0' + (magnitude % 10u)); magnitude /= 10u; } while (magnitude && n < (fpp_i32)sizeof(digits));
    for (i = n - 1; i >= 0; --i) if (fpp_json_writer_put(writer, digits[i]) != FPP_JSON_OK) return writer->error;
    return FPP_JSON_OK;
}
static inline int fpp_json_writer_i32(fpp_json_writer *writer, fpp_i32 value) { return fpp_json_writer_i64(writer, (fpp_i64)value); }

static inline int fpp_json_writer_number_literal(fpp_json_writer *writer, const char *literal) {
    fpp_i32 n = 0, end, i;
    if (!literal) return fpp_json_writer_fail(writer, FPP_JSON_E_ARGUMENT);
    while (literal[n]) { if (++n > FPP_JSON_MAX_STRING_BYTES) return fpp_json_writer_fail(writer, FPP_JSON_E_LIMIT); }
    if (fpp_json_number_end(literal, n, 0, &end) != FPP_JSON_OK || end != n) return fpp_json_writer_fail(writer, FPP_JSON_E_INVALID);
    if (fpp_json_writer_prepare_value(writer) != FPP_JSON_OK) return writer ? writer->error : FPP_JSON_E_ARGUMENT;
    for (i = 0; i < n; ++i) if (fpp_json_writer_put(writer, literal[i]) != FPP_JSON_OK) return writer->error;
    return FPP_JSON_OK;
}

static inline int fpp_json_writer_bool(fpp_json_writer *writer, int value) {
    const char *text = value ? "true" : "false"; fpp_i32 i;
    if (fpp_json_writer_prepare_value(writer) != FPP_JSON_OK) return writer ? writer->error : FPP_JSON_E_ARGUMENT;
    for (i = 0; text[i]; ++i) if (fpp_json_writer_put(writer, text[i]) != FPP_JSON_OK) return writer->error;
    return FPP_JSON_OK;
}
static inline int fpp_json_writer_null(fpp_json_writer *writer) {
    const char *text = "null"; fpp_i32 i;
    if (fpp_json_writer_prepare_value(writer) != FPP_JSON_OK) return writer ? writer->error : FPP_JSON_E_ARGUMENT;
    for (i = 0; text[i]; ++i) if (fpp_json_writer_put(writer, text[i]) != FPP_JSON_OK) return writer->error;
    return FPP_JSON_OK;
}

static inline int fpp_json_writer_end(fpp_json_writer *writer) {
    fpp_i32 top;
    if (!writer || writer->error != FPP_JSON_OK) return writer ? writer->error : FPP_JSON_E_ARGUMENT;
    if (writer->depth < 1) return fpp_json_writer_fail(writer, FPP_JSON_E_STATE);
    top = writer->depth - 1;
    if (writer->kind[top] == 1 && writer->state[top] != 0) return fpp_json_writer_fail(writer, FPP_JSON_E_STATE);
    if (fpp_json_writer_put(writer, writer->kind[top] == 1 ? '}' : ']') != FPP_JSON_OK) return writer->error;
    --writer->depth;
    return FPP_JSON_OK;
}
static inline int fpp_json_writer_finish(fpp_json_writer *writer, fpp_i32 *out_length) {
    if (!writer || !out_length) return FPP_JSON_E_ARGUMENT;
    if (writer->error != FPP_JSON_OK) return writer->error;
    if (writer->depth != 0 || !writer->root_done) return fpp_json_writer_fail(writer, FPP_JSON_E_STATE);
    *out_length = writer->length; return FPP_JSON_OK;
}

#endif
