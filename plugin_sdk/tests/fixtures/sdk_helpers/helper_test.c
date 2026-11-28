#include "ffmpegpp_plugin.h"
#include "ffmpegpp_json.h"
#include "ffmpegpp_ffmpeg.h"

static int failures;
static void expect(int condition, int code) { if (!condition && failures == 0) failures = code; }
static int equals(const char *left, const char *right) {
    int i = 0;
    while (left[i] && right[i] && left[i] == right[i]) ++i;
    return left[i] == right[i];
}
static int parse_document(const char *text, fpp_json_doc *doc) {
    int length = 0;
    while (text[length]) ++length;
    return fpp_json_parse(doc, text, length);
}
static int check_depth(int levels, int expected_ok, int siblings) {
    char text[512];
    int i, n = 0;
    fpp_json_doc doc;
    for (i = 0; i < levels; ++i) {
        text[n++] = '{'; text[n++] = '"'; text[n++] = 'a'; text[n++] = '"'; text[n++] = ':';
    }
    text[n++] = '0';
    for (i = 0; i < levels; ++i) {
        if (siblings) {
            text[n++] = ','; text[n++] = '"'; text[n++] = 'b'; text[n++] = '"'; text[n++] = ':'; text[n++] = '0';
        }
        text[n++] = '}';
    }
    return (fpp_json_parse(&doc, text, n) == FPP_JSON_OK) == expected_ok;
}

static void report_failure(void) {
    char report[32];
    fpp_i32 length;
    fpp_json_writer writer;
    fpp_json_writer_init(&writer, report, sizeof(report));
    (void)fpp_json_writer_begin_object(&writer);
    (void)fpp_json_writer_key(&writer, "failure");
    (void)fpp_json_writer_i32(&writer, failures);
    (void)fpp_json_writer_end(&writer);
    if (fpp_json_writer_finish(&writer, &length) == FPP_JSON_OK) (void)fpp_response_write(report, length);
}

FPP_EXPORT(run_sdk_helpers) void run_sdk_helpers(void) {
    static const char request[] = "{\"outer\":{\"values\":[-0.125,1.25,true,\"quote\\n\\uD83D\\uDE00\"]},\"host\":{\"api_version\":1,\"operations\":[\"ffmpeg.execute\"],\"ffmpeg\":{\"api_version\":1,\"max_arguments\":2,\"max_argument_bytes\":64,\"max_total_argument_bytes\":128,\"options\":[\"-t\",\"-frames:v\"],\"filters\":[\"scale\"]}}}";
    static const char zero_limit_request[] = "{\"host\":{\"api_version\":1,\"operations\":[\"ffmpeg.execute\"],\"ffmpeg\":{\"api_version\":1,\"max_arguments\":0,\"options\":[\"-t\"],\"filters\":[]}}}";
    static const char total_limit_request[] = "{\"host\":{\"api_version\":1,\"operations\":[\"ffmpeg.execute\"],\"ffmpeg\":{\"api_version\":1,\"max_arguments\":4,\"max_argument_bytes\":64,\"max_total_argument_bytes\":10,\"options\":[\"-t\"],\"filters\":[]}}}";
    static char cap_argument[66];
    static const char duplicate[] = "{\"a\":1,\"\\u0061\":2}";
    static const char nul_string[] = "\"bad\\u0000value\"";
    static const char lone_surrogate[] = "\"\\uD800\"";
    static const char lone_low_surrogate[] = "\"\\uDC00\"";
    static const char raw_bad_utf8[] = {'"', (char)0xc0, (char)0x80, '"', 0};
    static const char raw_utf8[] = {'"', (char)0xf0, (char)0x9f, (char)0x98, (char)0x80, '"', 0};
    static const char writer_input[] = {'A', '"', '\\', '\n', 1, 0};
    static char long_argument[FPP_FFMPEG_MAX_ARGUMENT_LENGTH + 2];
    fpp_json_doc doc;
    fpp_json_value root, values, value;
    fpp_host_capabilities caps;
    fpp_ffmpeg_plan plan;
    fpp_json_writer json_writer;
    fpp_i32 count, int_value, out_length = 0, string_length;
    fpp_i64 wide;
    double number;
    int boolean, i;
    char decoded[32], response[256], escaped_json[64];
    static char large_output[FPP_FFMPEG_MAX_ARGUMENT_LENGTH * 2 + 512];
    const char *json;

    expect(parse_document(request, &doc) == FPP_JSON_OK, 1);
    expect(fpp_json_root(&doc, &root) == FPP_JSON_OK && root.type == FPP_JSON_OBJECT, 2);
    expect(fpp_json_lookup(&root, "outer.values", &values) == FPP_JSON_OK, 3);
    expect(fpp_json_array_length(&values, &count) == FPP_JSON_OK && count == 4, 4);
    expect(fpp_json_array_at(&values, 0, &value) == FPP_JSON_OK && fpp_json_get_number(&value, &number) == FPP_JSON_OK && number > -0.126 && number < -0.124, 5);
    expect(fpp_json_array_at(&values, 1, &value) == FPP_JSON_OK && fpp_json_get_number(&value, &number) == FPP_JSON_OK && number > 1.249 && number < 1.251, 6);
    expect(fpp_json_array_at(&values, 2, &value) == FPP_JSON_OK && fpp_json_get_bool(&value, &boolean) == FPP_JSON_OK && boolean == 1, 7);
    expect(fpp_json_array_at(&values, 3, &value) == FPP_JSON_OK && fpp_json_get_string(&value, decoded, sizeof(decoded), &string_length) == FPP_JSON_OK && string_length == 10, 8);
    expect(decoded[0] == 'q' && decoded[5] == '\n' && (unsigned char)decoded[6] == 0xf0u && (unsigned char)decoded[9] == 0x80u && decoded[10] == 0, 9);
    expect(fpp_json_get_i32(&value, &int_value) == FPP_JSON_E_TYPE, 10);
    fpp_json_writer_init(&json_writer, escaped_json, sizeof(escaped_json));
    expect(fpp_json_writer_string(&json_writer, writer_input) == FPP_JSON_OK, 59);
    expect(fpp_json_writer_finish(&json_writer, &out_length) == FPP_JSON_OK, 62);
    expect(fpp_json_parse(&doc, escaped_json, out_length) == FPP_JSON_OK && fpp_json_root(&doc, &value) == FPP_JSON_OK && fpp_json_get_string(&value, decoded, sizeof(decoded), &string_length) == FPP_JSON_OK && string_length == 5 && decoded[0] == 'A' && decoded[1] == '"' && decoded[2] == '\\' && decoded[3] == '\n' && decoded[4] == 1 && decoded[5] == 0, 60);
    expect(fpp_json_lookup(&root, "outer..values", &value) != FPP_JSON_OK, 11);
    expect(fpp_json_parse(&doc, duplicate, (fpp_i32)(sizeof(duplicate) - 1)) != FPP_JSON_OK, 12);
    expect(fpp_json_parse(&doc, nul_string, (fpp_i32)(sizeof(nul_string) - 1)) != FPP_JSON_OK, 13);
    expect(fpp_json_parse(&doc, lone_surrogate, (fpp_i32)(sizeof(lone_surrogate) - 1)) != FPP_JSON_OK, 14);
    expect(fpp_json_parse(&doc, lone_low_surrogate, (fpp_i32)(sizeof(lone_low_surrogate) - 1)) != FPP_JSON_OK, 37);
    expect(fpp_json_parse(&doc, raw_bad_utf8, 4) != FPP_JSON_OK, 15);
    expect(fpp_json_parse(&doc, raw_utf8, 6) == FPP_JSON_OK && fpp_json_root(&doc, &value) == FPP_JSON_OK && fpp_json_get_string(&value, decoded, sizeof(decoded), &string_length) == FPP_JSON_OK && string_length == 4 && (unsigned char)decoded[0] == 0xf0u && (unsigned char)decoded[3] == 0x80u, 38);
    expect(check_depth(FPP_JSON_MAX_DEPTH, 1, 0), 16);
    expect(check_depth(FPP_JSON_MAX_DEPTH + 1, 0, 0), 17);
    expect(check_depth(FPP_JSON_MAX_DEPTH, 1, 1), 63);
    expect(parse_document("{\"\\u4e2d\":\"\\u4e2d\"}", &doc) == FPP_JSON_OK && fpp_json_root(&doc, &root) == FPP_JSON_OK && fpp_json_object_get(&root, "\xe4\xb8\xad", &value) == FPP_JSON_OK && fpp_json_string_equals(&value, "\xe4\xb8\xad"), 64);
    expect(fpp_json_parse(&doc, "2147483648", 10) == FPP_JSON_OK && fpp_json_root(&doc, &value) == FPP_JSON_OK && fpp_json_get_i32(&value, &int_value) == FPP_JSON_E_OVERFLOW, 18);
    expect(fpp_json_parse(&doc, "1e309", 5) == FPP_JSON_OK && fpp_json_root(&doc, &value) == FPP_JSON_OK && fpp_json_get_number(&value, &number) == FPP_JSON_E_OVERFLOW, 19);
    expect(fpp_json_parse(&doc, "0.005", 5) == FPP_JSON_OK && fpp_json_root(&doc, &value) == FPP_JSON_OK && fpp_json_get_number(&value, &number) == FPP_JSON_OK && number > 0.0049 && number < 0.0051, 39);
    expect(fpp_json_parse(&doc, "1.25e1", 6) == FPP_JSON_OK && fpp_json_root(&doc, &value) == FPP_JSON_OK && fpp_json_get_number(&value, &number) == FPP_JSON_OK && number > 12.49 && number < 12.51, 40);
    expect(fpp_json_parse(&doc, "-9223372036854775808", 20) == FPP_JSON_OK && fpp_json_root(&doc, &value) == FPP_JSON_OK && fpp_json_get_i64(&value, &wide) == FPP_JSON_OK && wide == (fpp_i64)(-9223372036854775807ll - 1ll), 41);
    expect(fpp_json_parse(&doc, "9223372036854775807", 19) == FPP_JSON_OK && fpp_json_root(&doc, &value) == FPP_JSON_OK && fpp_json_get_i64(&value, &wide) == FPP_JSON_OK && wide == (fpp_i64)9223372036854775807ll, 42);
    expect(fpp_json_parse(&doc, "9223372036854775808", 19) == FPP_JSON_OK && fpp_json_root(&doc, &value) == FPP_JSON_OK && fpp_json_get_i64(&value, &wide) == FPP_JSON_E_OVERFLOW, 43);
    expect(parse_document("\"root text\" \t\n", &doc) == FPP_JSON_OK && fpp_json_root(&doc, &value) == FPP_JSON_OK && fpp_json_get_string(&value, decoded, sizeof(decoded), &string_length) == FPP_JSON_OK && string_length == 9 && equals(decoded, "root text"), 55);
    expect(parse_document("1 \t\n", &doc) == FPP_JSON_OK && fpp_json_root(&doc, &value) == FPP_JSON_OK && fpp_json_get_i64(&value, &wide) == FPP_JSON_OK && wide == 1, 56);
    expect(parse_document("1.25 \t\n", &doc) == FPP_JSON_OK && fpp_json_root(&doc, &value) == FPP_JSON_OK && fpp_json_get_number(&value, &number) == FPP_JSON_OK && number > 1.249 && number < 1.251, 57);
    expect(fpp_json_parse(&doc, "0", FPP_JSON_MAX_DOCUMENT + 1) != FPP_JSON_OK, 20);

    expect(parse_document(request, &doc) == FPP_JSON_OK && fpp_json_root(&doc, &root) == FPP_JSON_OK, 21);
    expect(fpp_host_capabilities_init(&root, &caps) == FPP_JSON_OK && caps.api_version == 1 && caps.ffmpeg_api_version == 1, 22);
    expect(fpp_host_supports_operation(&caps, "ffmpeg.execute"), 23);
    expect(fpp_host_supports_ffmpeg_option(&caps, "-t"), 24);
    expect(fpp_host_supports_ffmpeg_filter(&caps, "scale"), 25);
    expect(fpp_ffmpeg_plan_init(&plan, response, sizeof(response)) == FPP_JSON_OK && fpp_ffmpeg_plan_add_argument(&plan, "-metadata") == FPP_JSON_OK && fpp_ffmpeg_plan_set_capabilities(&plan, &caps) == FPP_JSON_E_STATE && fpp_ffmpeg_plan_write(&plan, &out_length) == FPP_JSON_E_ARGUMENT, 61);
    expect(fpp_ffmpeg_plan_init(&plan, response, sizeof(response)) == FPP_JSON_OK, 26);
    expect(fpp_ffmpeg_plan_set_capabilities(&plan, &caps) == FPP_JSON_OK, 27);
    expect(fpp_ffmpeg_plan_add_option(&plan, "-t", "-1.5") == FPP_JSON_OK, 28);
    expect(fpp_ffmpeg_plan_add_option(&plan, "-frames:v", "1") == FPP_JSON_E_LIMIT, 29);
    expect(fpp_ffmpeg_plan_write(&plan, &out_length) == FPP_JSON_OK, 30);
    response[out_length] = 0;
    json = "{\"operation\":\"ffmpeg.execute\",\"arguments\":[\"-t\",\"-1.5\"]}";
    expect(equals(response, json), 31);
    expect(fpp_ffmpeg_plan_init(&plan, response, sizeof(response)) == FPP_JSON_OK, 32);
    expect(fpp_ffmpeg_plan_add_option(&plan, "-frames:v", "1") == FPP_JSON_OK, 33);
    expect(fpp_ffmpeg_plan_add_argument(&plan, "1") == FPP_JSON_OK, 34);
    expect(fpp_ffmpeg_plan_add_argument(&plan, "-i") == FPP_JSON_E_HOST, 35);
    expect(fpp_ffmpeg_has_protocol("1") == 0, 36);
    expect(fpp_ffmpeg_plan_init(&plan, response, sizeof(response)) == FPP_JSON_OK && fpp_ffmpeg_plan_add_option(&plan, "-t", "") == FPP_JSON_E_INVALID, 44);
    expect(parse_document(request, &doc) == FPP_JSON_OK && fpp_json_root(&doc, &root) == FPP_JSON_OK && fpp_host_capabilities_init(&root, &caps) == FPP_JSON_OK, 45);
    expect(fpp_ffmpeg_plan_init(&plan, response, sizeof(response)) == FPP_JSON_OK && fpp_ffmpeg_plan_set_capabilities(&plan, &caps) == FPP_JSON_OK && fpp_ffmpeg_plan_add_option(&plan, "-vf", "scale=1") == FPP_JSON_E_HOST, 46);
    expect(fpp_ffmpeg_plan_init(&plan, response, sizeof(response)) == FPP_JSON_OK && fpp_ffmpeg_plan_set_capabilities(&plan, &caps) == FPP_JSON_OK && fpp_ffmpeg_plan_add_filter(&plan, "scale=10,hflip") == FPP_JSON_E_HOST, 58);
    expect(parse_document(zero_limit_request, &doc) == FPP_JSON_OK && fpp_json_root(&doc, &root) == FPP_JSON_OK && fpp_host_capabilities_init(&root, &caps) == FPP_JSON_OK && caps.has_max_arguments && caps.max_arguments == 0, 50);
    expect(fpp_ffmpeg_plan_init(&plan, response, sizeof(response)) == FPP_JSON_OK && fpp_ffmpeg_plan_set_capabilities(&plan, &caps) == FPP_JSON_OK && fpp_ffmpeg_plan_add_argument(&plan, "-t") == FPP_JSON_E_LIMIT, 51);
    for (i = 0; i < 65; ++i) cap_argument[i] = 'x'; cap_argument[65] = 0;
    expect(parse_document(request, &doc) == FPP_JSON_OK && fpp_json_root(&doc, &root) == FPP_JSON_OK && fpp_host_capabilities_init(&root, &caps) == FPP_JSON_OK && fpp_ffmpeg_plan_init(&plan, large_output, sizeof(large_output)) == FPP_JSON_OK && fpp_ffmpeg_plan_set_capabilities(&plan, &caps) == FPP_JSON_OK && fpp_ffmpeg_plan_add_argument(&plan, cap_argument) == FPP_JSON_E_LIMIT, 52);
    expect(parse_document(total_limit_request, &doc) == FPP_JSON_OK && fpp_json_root(&doc, &root) == FPP_JSON_OK && fpp_host_capabilities_init(&root, &caps) == FPP_JSON_OK && fpp_ffmpeg_plan_init(&plan, response, sizeof(response)) == FPP_JSON_OK && fpp_ffmpeg_plan_set_capabilities(&plan, &caps) == FPP_JSON_OK && fpp_ffmpeg_plan_add_option(&plan, "-t", "12345678") == FPP_JSON_OK, 53);
    expect(fpp_ffmpeg_plan_add_argument(&plan, "x") == FPP_JSON_E_LIMIT, 54);
    for (i = 0; i <= 8193; ++i) long_argument[i] = 'x';
    long_argument[8192] = 0;
    expect(fpp_ffmpeg_plan_init(&plan, large_output, sizeof(large_output)) == FPP_JSON_OK && fpp_ffmpeg_plan_add_argument(&plan, long_argument) == FPP_JSON_OK, 47);
    long_argument[8192] = 'x'; long_argument[8193] = 0;
    expect(fpp_ffmpeg_plan_init(&plan, large_output, sizeof(large_output)) == FPP_JSON_OK && fpp_ffmpeg_plan_add_argument(&plan, long_argument) == FPP_JSON_E_LIMIT, 48);
    for (i = 0; i <= FPP_FFMPEG_MAX_ARGUMENT_LENGTH; ++i) long_argument[i] = 'x';
    long_argument[FPP_FFMPEG_MAX_ARGUMENT_LENGTH + 1] = 0;
    expect(fpp_ffmpeg_plan_init(&plan, large_output, sizeof(large_output)) == FPP_JSON_OK && fpp_ffmpeg_plan_add_argument(&plan, long_argument) == FPP_JSON_E_ARGUMENT, 49);
    report_failure();
}

/* Let the JavaScript host check escaping independently of the C parser. */
FPP_EXPORT(test_sdk_writer_text) fpp_i32 test_sdk_writer_text(void) {
    char text[135], response[1024];
    fpp_i32 i, length;
    fpp_json_writer writer;
    for (i = 1; i < 128; ++i) text[i - 1] = (char)i;
    text[127] = (char)0xe4; text[128] = (char)0xb8; text[129] = (char)0xad;
    text[130] = (char)0xf0; text[131] = (char)0x9f; text[132] = (char)0x98; text[133] = (char)0x80;
    text[134] = 0;
    fpp_json_writer_init(&writer, response, sizeof(response));
    if (fpp_json_writer_begin_object(&writer) != FPP_JSON_OK ||
        fpp_json_writer_key(&writer, "quote\"\n\\") != FPP_JSON_OK ||
        fpp_json_writer_string(&writer, text) != FPP_JSON_OK ||
        fpp_json_writer_end(&writer) != FPP_JSON_OK ||
        fpp_json_writer_finish(&writer, &length) != FPP_JSON_OK) return writer.error;
    return fpp_response_write(response, length);
}

FPP_EXPORT(test_sdk_helper_response_failure) fpp_i32 test_sdk_helper_response_failure(void) {
    char response[128];
    fpp_ffmpeg_plan plan;
    if (fpp_ffmpeg_plan_init(&plan, response, sizeof(response)) != FPP_JSON_OK ||
        fpp_ffmpeg_plan_add_option(&plan, "-t", "1") != FPP_JSON_OK) return -1;
    return fpp_ffmpeg_plan_respond(&plan);
}
