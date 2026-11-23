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
// The photo with mask `mask` tinted red over it (drawing masks).
LatentImage *latent_render_mask(const LatentCore *core, uint64_t id, uint32_t max_w, uint32_t max_h, uint32_t mask);
// The mask drawn as `view` ("color", "colorOnBw", "imageOnBlack", "imageOnWhite", "whiteOnBlack")
// in `rgb` (0xRRGGBB) at `opacity` (0..100).
LatentImage *latent_render_mask_as(const LatentCore *core, uint64_t id, uint32_t max_w, uint32_t max_h, uint32_t mask, const char *view, uint32_t rgb, uint8_t opacity);
// The photo uncropped and unstraightened (the crop box is drawn over it).
LatentImage *latent_render_uncropped(const LatentCore *core, uint64_t id, uint32_t max_w, uint32_t max_h);
// A preview of a preset (by id) on the photo, without editing it.
LatentImage *latent_preset_thumb(const LatentCore *core, uint64_t id, const char *preset, uint32_t long_edge);
LatentImage *latent_thumb(const LatentCore *core, uint64_t id, uint32_t long_edge);

// An HDR render: half-float RGBA, linear light, SDR white = 1.0, highlights up to `peak`.
// The histogram covers SDR (first half) then one band per stop above white.
typedef struct LatentHdrImage {
    uint32_t width;
    uint32_t height;
    uint16_t *rgba16f;  // width * height * 4 half floats (IEEE bits)
    size_t rgba16f_len;
    uint32_t *hist;     // red, green, blue, LATENT_HIST_BINS each
    size_t hist_len;
    float peak;
} LatentHdrImage;

// NULL when HDR is off for the photo or the engine gave no HDR render.
LatentHdrImage *latent_render_hdr(const LatentCore *core, uint64_t id, uint32_t max_w, uint32_t max_h);
void latent_hdr_image_free(LatentHdrImage *img);

// AI masks: where the SAM 3 model files are (model.safetensors, vocab.json, merges.txt).
void latent_set_ai_model_dir(const LatentCore *core, const char *dir);
// Take in finished background work: {"changed": bool, "messages": [...], "busy": bool}.
char *latent_poll(const LatentCore *core);

// An exported file.
typedef struct LatentExport {
    char *name;
    uint8_t *bytes;
    size_t len;
} LatentExport;

// Export a photo with the engine's export options as JSON (format, quality, resize, hdr, metadata,
// removeLocation, watermark…). NULL on failure; `error` (may be NULL) receives why.
LatentExport *latent_export(const LatentCore *core, uint64_t id, const char *options, char **error);
void latent_export_free(LatentExport *e);

void latent_image_free(LatentImage *img);
void latent_string_free(char *s);
