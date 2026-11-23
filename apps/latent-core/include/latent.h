// Latent's bridge to the LightCraft engine (apps/latent-core/src/ffi.rs).
// Strings are UTF-8 and NUL-terminated. Strings and images returned are the caller's: give them back
// with latent_string_free / latent_image_free.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define LATENT_HIST_BINS 256

typedef struct LatentCore LatentCore;

typedef struct LatentImage {
    uint32_t width;
    uint32_t height;
    uint8_t *rgba;      // width * height * 4 bytes, RGBA, rows top to bottom
    size_t rgba_len;
    uint32_t *hist;     // red, green, blue histograms, LATENT_HIST_BINS each
    size_t hist_len;
} LatentImage;

// Open the library in `dir` (NULL: the default folder). `problem` (may be NULL) receives NULL or why
// the library couldn't be opened.
LatentCore *latent_open(const char *dir, char **problem);
LatentCore *latent_open_demo(void);
void latent_close(LatentCore *core);

// Run an engine command (`params`: a JSON object or NULL). Returns {"ok": ...} or {"error": "..."}.
char *latent_execute(const LatentCore *core, const char *cmd, const char *params);

LatentImage *latent_render(const LatentCore *core, uint64_t id, uint32_t max_w, uint32_t max_h, bool original);
LatentImage *latent_thumb(const LatentCore *core, uint64_t id, uint32_t long_edge);

void latent_image_free(LatentImage *img);
void latent_string_free(char *s);
