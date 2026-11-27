#include "ffmpegpp_plugin.h"
#include "ffmpegpp_json.h"
#include "ffmpegpp_ffmpeg.h"
#include "manifest.generated.h"
#include "filters.h"

/* Only these bounded buffers and the two ABI imports are needed. C++ dispatch
 * and typed request validation are separate from the C filter business. */
static char request_buffer[16384];
static char response_buffer[2048];
static char filter_buffer[256];

static bool same(const char *left, const char *right) {
    int i = 0;
    while (left[i] && right[i] && left[i] == right[i]) ++i;
    return left[i] == right[i];
}

static bool member_string(const fpp_json_value &object, const char *key,
                          char *output, fpp_i32 capacity) {
    fpp_json_value value;
    fpp_i32 length;
    if (fpp_json_object_get(&object, key, &value) != 0 ||
        fpp_json_get_string(&value, output, capacity, &length) != 0 ||
        length < 0 || length >= capacity) return false;
    /* A decoded embedded NUL must not turn an invalid ID or enum into a
     * matching prefix when passed to the plugin's C string comparisons. */
    for (fpp_i32 i = 0; i < length; ++i) if (!output[i]) return false;
    return output[length] == 0;
}

static bool member_number(const fpp_json_value &object, const char *key,
                          double *output) {
    fpp_json_value value;
    return fpp_json_object_get(&object, key, &value) == 0 &&
           fpp_json_get_number(&value, output) == 0;
}

static bool member_integer(const fpp_json_value &object, const char *key,
                           fpp_i32 *output) {
    fpp_json_value value;
    return fpp_json_object_get(&object, key, &value) == 0 &&
           fpp_json_get_i32(&value, output) == 0;
}

static bool member_boolean(const fpp_json_value &object, const char *key,
                           int *output) {
    fpp_json_value value;
    return fpp_json_object_get(&object, key, &value) == 0 &&
           fpp_json_get_bool(&value, output) == 0;
}

static bool media_matches(const fpp_json_value &root, const char *input,
                          const char *output) {
    char name[16];
    fpp_json_value value;
    if (!member_string(root, "media_type", name, sizeof(name)) || !same(name, input)) return false;
    /* Old hosts only sent media_type. A missing new field uses this node's
     * declared contract; a present field must be typed and match exactly. */
    if (fpp_json_object_get(&root, "input_media_type", &value) == 0 &&
        (!member_string(root, "input_media_type", name, sizeof(name)) || !same(name, input))) return false;
    if (fpp_json_object_get(&root, "output_media_type", &value) == 0 &&
        (!member_string(root, "output_media_type", name, sizeof(name)) || !same(name, output))) return false;
    return true;
}

static bool supports_plan(const fpp_json_value &root,
                          const fpp_host_capabilities &host,
                          const char *filter, const char *option,
                          bool grayscale, bool waveform) {
    fpp_json_value ffmpeg;
    if (fpp_json_lookup(&root, "host.ffmpeg", &ffmpeg) != 0) return true;
    fpp_i32 version;
    if (!member_integer(ffmpeg, "api_version", &version) || version != 1 ||
        !fpp_host_supports_ffmpeg_filter(&host, filter) ||
        !fpp_host_supports_ffmpeg_option(&host, option)) return false;
    if (grayscale && !fpp_host_supports_ffmpeg_filter(&host, "hue")) return false;
    if (waveform && (!fpp_host_supports_ffmpeg_option(&host, "-map") ||
                     !fpp_host_supports_ffmpeg_option(&host, "-frames:v") ||
                     !fpp_host_supports_ffmpeg_option(&host, "-c:v"))) return false;
    return true;
}

static void invalid_request() {
    FPP_RESPOND_LITERAL("{\"error\":\"Invalid request: expected API v1 and plugin identity\"}");
}

static void invalid_video() {
    FPP_RESPOND_LITERAL("{\"error\":\"video_tone: brightness [-1,1], contrast [0,2], saturation [0,3] and boolean grayscale are required\"}");
}

static void invalid_normalize() {
    FPP_RESPOND_LITERAL("{\"error\":\"audio_normalize: profile must be podcast, broadcast or streaming\"}");
}

static void invalid_waveform() {
    FPP_RESPOND_LITERAL("{\"error\":\"audio_waveform: integer width [64,4096], height [64,2160] and color cyan, white or orange are required\"}");
}

FPP_EXPORT(Basic_info) void Basic_info(void) { FPP_RESPOND_LITERAL(FPP_BASIC_JSON); }
FPP_EXPORT(Node_info) void Node_info(void) { FPP_RESPOND_LITERAL(FPP_NODES_JSON); }
/* Each manifest node already owns its fields. No first-node editor macro. */

FPP_EXPORT(Node_execute) void Node_execute(void) {
    const fpp_i32 length = fpp_read_json(request_buffer, sizeof(request_buffer));
    fpp_json_doc document;
    fpp_json_value root;
    fpp_i32 version;
    char plugin_id[80];
    char node_id[64];
    if (length < 0 || fpp_json_parse(&document, request_buffer, length) != 0 ||
        fpp_json_root(&document, &root) != 0 ||
        !member_integer(root, "api_version", &version) || version != 1 ||
        !member_string(root, "plugin_id", plugin_id, sizeof(plugin_id)) ||
        !same(plugin_id, "org.ffmpegpp.examples.media-toolkit") ||
        !member_string(root, "node_id", node_id, sizeof(node_id))) {
        invalid_request(); return;
    }

    enum class Node { tone, normalize, waveform } node;
    const char *input;
    const char *output;
    if (same(node_id, "video_tone")) {
        node = Node::tone; input = "video"; output = "video";
    } else if (same(node_id, "audio_normalize")) {
        node = Node::normalize; input = "audio"; output = "audio";
    } else if (same(node_id, "audio_waveform")) {
        node = Node::waveform; input = "audio"; output = "image";
    } else {
        FPP_RESPOND_LITERAL("{\"error\":\"Unknown node_id\"}"); return;
    }
    if (!media_matches(root, input, output)) {
        FPP_RESPOND_LITERAL("{\"error\":\"Request media types do not match the node\"}"); return;
    }

    fpp_host_capabilities host;
    if (fpp_host_capabilities_init(&root, &host) != 0 || host.api_version != 1 ||
        !fpp_host_supports_operation(&host, "ffmpeg.execute")) {
        FPP_RESPOND_LITERAL("{\"error\":\"Host does not support ffmpeg.execute\"}"); return;
    }

    fpp_json_value params;
    const bool has_params = fpp_json_object_get(&root, "params", &params) == 0;
    const char *required_filter;
    const char *option;
    int grayscale = 0;
    int filter_length = -1;
    if (node == Node::tone) {
        double brightness, contrast, saturation;
        if (!has_params || !member_number(params, "brightness", &brightness) ||
            !member_number(params, "contrast", &contrast) ||
            !member_number(params, "saturation", &saturation) ||
            !member_boolean(params, "grayscale", &grayscale) ||
            (filter_length = mt_video_filter(filter_buffer, sizeof(filter_buffer),
                                            brightness, contrast, saturation, grayscale)) < 0) {
            invalid_video(); return;
        }
        required_filter = "eq"; option = "-vf";
    } else if (node == Node::normalize) {
        char profile[24];
        if (!has_params || !member_string(params, "profile", profile, sizeof(profile))) {
            invalid_normalize(); return;
        }
        const int choice = same(profile, "podcast") ? 0 :
                           (same(profile, "broadcast") ? 1 : (same(profile, "streaming") ? 2 : -1));
        filter_length = mt_normalize_filter(filter_buffer, sizeof(filter_buffer), choice);
        if (filter_length < 0) { invalid_normalize(); return; }
        required_filter = "loudnorm"; option = "-af";
    } else {
        fpp_i32 width, height;
        char color[24];
        if (!has_params || !member_integer(params, "width", &width) ||
            !member_integer(params, "height", &height) ||
            !member_string(params, "color", color, sizeof(color))) {
            invalid_waveform(); return;
        }
        const int choice = same(color, "cyan") ? 0 :
                           (same(color, "white") ? 1 : (same(color, "orange") ? 2 : -1));
        filter_length = mt_waveform_filter(filter_buffer, sizeof(filter_buffer), width, height, choice);
        if (filter_length < 0) { invalid_waveform(); return; }
        required_filter = "showwavespic"; option = "-filter_complex";
    }

    if (!supports_plan(root, host, required_filter, option, grayscale != 0, node == Node::waveform)) {
        FPP_RESPOND_LITERAL("{\"error\":\"Host does not support required FFmpeg filters or options\"}"); return;
    }
    fpp_ffmpeg_plan plan;
    fpp_json_value ffmpeg;
    fpp_i32 response_length;
    const bool has_ffmpeg_capabilities = fpp_json_lookup(&root, "host.ffmpeg", &ffmpeg) == 0;
    if (fpp_ffmpeg_plan_init(&plan, response_buffer, sizeof(response_buffer)) < 0 ||
        (has_ffmpeg_capabilities && fpp_ffmpeg_plan_set_capabilities(&plan, &host) < 0) ||
        fpp_ffmpeg_plan_add_option(&plan, option, filter_buffer) < 0 ||
        (node == Node::waveform &&
         (fpp_ffmpeg_plan_add_option(&plan, "-map", "[v]") < 0 ||
          fpp_ffmpeg_plan_add_option(&plan, "-frames:v", "1") < 0 ||
          fpp_ffmpeg_plan_add_option(&plan, "-c:v", "png") < 0)) ||
        fpp_ffmpeg_plan_write(&plan, &response_length) < 0) {
        FPP_RESPOND_LITERAL("{\"error\":\"FFmpeg plan exceeds the response buffer or host limits\"}"); return;
    }
    fpp_response_write(response_buffer, response_length);
}
