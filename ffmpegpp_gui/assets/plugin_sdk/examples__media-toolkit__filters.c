#include "filters.h"

/* This formatter is intentionally part of the example, not the SDK: choosing
 * filters, loudness profiles, palettes and precision is plugin business. */
typedef struct {
    char *data;
    int capacity;
    int length;
    int ok;
} mt_text;

static void character(mt_text *text, char value) {
    if (!text->ok) return;
    if (text->length + 1 >= text->capacity) { text->ok = 0; return; }
    text->data[text->length++] = value;
}

static void literal(mt_text *text, const char *value) {
    for (int i = 0; value[i]; ++i) character(text, value[i]);
}

static void unsigned_decimal(mt_text *text, unsigned int value) {
    char digits[10];
    int count = 0;
    do { digits[count++] = (char)('0' + value % 10); value /= 10; } while (value);
    while (count) character(text, digits[--count]);
}

static void fixed_decimal(mt_text *text, double value) {
    const int negative = value < 0;
    if (negative) value = -value;
    /* Callers validated the small range, so this conversion cannot overflow. */
    const unsigned int scaled = (unsigned int)(value * 1000.0 + 0.5);
    if (negative && scaled) character(text, '-');
    unsigned_decimal(text, scaled / 1000);
    unsigned int fraction = scaled % 1000;
    if (fraction) {
        character(text, '.');
        unsigned int divisor = 100;
        do {
            character(text, (char)('0' + fraction / divisor));
            fraction %= divisor;
            divisor /= 10;
        } while (fraction && divisor);
    }
}

static int finish(mt_text *text) {
    if (!text->ok || text->capacity < 1) {
        if (text->capacity > 0) text->data[0] = 0;
        return -1;
    }
    text->data[text->length] = 0;
    return text->length;
}

int mt_video_filter(char *output, int capacity, double brightness,
                    double contrast, double saturation, int grayscale) {
    if (!output || capacity < 1 || !(brightness >= -1 && brightness <= 1) ||
        !(contrast >= 0 && contrast <= 2) ||
        !(saturation >= 0 && saturation <= 3) ||
        (grayscale != 0 && grayscale != 1)) return -1;
    mt_text text = {output, capacity, 0, 1};
    literal(&text, "eq=brightness="); fixed_decimal(&text, brightness);
    literal(&text, ":contrast="); fixed_decimal(&text, contrast);
    literal(&text, ":saturation="); fixed_decimal(&text, saturation);
    if (grayscale) literal(&text, ",hue=s=0");
    return finish(&text);
}

int mt_normalize_filter(char *output, int capacity, int profile) {
    if (!output || capacity < 1 || profile < 0 || profile > 2) return -1;
    mt_text text = {output, capacity, 0, 1};
    literal(&text, "loudnorm=I=-");
    unsigned_decimal(&text, profile == 0 ? 16 : (profile == 1 ? 23 : 14));
    literal(&text, ":TP=-1.5:LRA=11");
    return finish(&text);
}

int mt_waveform_filter(char *output, int capacity, int width, int height,
                       int color) {
    if (!output || capacity < 1 || width < 64 || width > 4096 ||
        height < 64 || height > 2160 || color < 0 || color > 2) return -1;
    mt_text text = {output, capacity, 0, 1};
    literal(&text, "[0:a]showwavespic=s=");
    unsigned_decimal(&text, (unsigned int)width); character(&text, 'x');
    unsigned_decimal(&text, (unsigned int)height); literal(&text, ":colors=");
    literal(&text, color == 0 ? "0x00ccff" : (color == 1 ? "white" : "0xff9900"));
    literal(&text, "[v]");
    return finish(&text);
}
