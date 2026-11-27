#ifndef MEDIA_TOOLKIT_FILTERS_H
#define MEDIA_TOOLKIT_FILTERS_H

/* Plugin-owned business logic. No libc, WASI, C++ runtime or host paths. */
#ifdef __cplusplus
extern "C" {
#endif

/* Decimal tone values are rounded to three fractional digits. Returns the
 * complete NUL-terminated filter length, or -1; never use a partial result. */
int mt_video_filter(char *output, int capacity, double brightness,
                    double contrast, double saturation, int grayscale);
/* profile: 0 podcast (-16 LUFS), 1 broadcast (-23), 2 streaming (-14). */
int mt_normalize_filter(char *output, int capacity, int profile);
/* color: 0 cyan, 1 white, 2 orange. Includes [0:a] and [v] graph labels. */
int mt_waveform_filter(char *output, int capacity, int width, int height,
                       int color);

#ifdef __cplusplus
}
#endif
#endif
