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

// Give a photo a depth map: w x h bytes, 0 near ... 255 far, upright. NULL / 0 takes it away.
void latent_set_depth(const LatentCore *core, uint64_t id, uint32_t w, uint32_t h, const uint8_t *data, size_t len);

// The depth map as the photo is framed: near white, far black.
LatentImage *latent_render_depth(const LatentCore *core, uint64_t id, uint32_t max_w, uint32_t max_h);

// A preview of a creative profile (built in or an imported LUT) on the photo, without editing it.
LatentImage *latent_profile_thumb(const LatentCore *core, uint64_t id, const char *profile, uint32_t long_edge);

// The app's inpainting model for AI remove spots: rgb (size*size*3, 0..1) and hole (size*size, 1 =
// rebuild) in, size*size*3 values (0..1) written to out; false on failure. NULL takes it away.
typedef bool (*LatentInpaintFn)(const float *rgb, const float *hole, uint32_t size, float *out);
void latent_set_inpainter(LatentInpaintFn model, uint32_t size);

// AI denoise with the app's model: one tile of 3*size*size planar values (0..1, gamma encoded) in, the cleaned tile
// written to out; false on failure. latent_denoise runs every tile of the photo (call it off the main thread) and
// makes the result the photo's denoised picture, which the Denoise amount mixes in.
typedef bool (*LatentDenoiseFn)(const float *input, uint32_t size, float *out);
typedef void (*LatentProgressFn)(uint32_t done, uint32_t total);
// Photo Merge: command is merge.hdr, merge.panorama or merge.hdrPanorama; params its options with "ids". Runs until
// done (call it off the main thread) with the library usable meanwhile; progress may return false to cancel. The
// result JSON (free with latent_string_free; "id" is the new photo), or NULL with *error saying why.
typedef bool (*LatentMergeProgressFn)(float fraction, const char *stage);
char *latent_merge(const LatentCore *core, const char *command, const char *params, LatentMergeProgressFn progress, char **error);
bool latent_denoise(const LatentCore *core, uint64_t id, LatentDenoiseFn model, uint32_t size, LatentProgressFn progress, char **error);
bool latent_save_denoised(const LatentCore *core, uint64_t id, const char *path);
bool latent_load_denoised(const LatentCore *core, uint64_t id, const char *path);
bool latent_has_denoised(const LatentCore *core, uint64_t id);
void latent_forget_denoised(const LatentCore *core, uint64_t id);

// An object mask from the app's own selection (side*side coverage bytes over the uncropped,
// oriented photo); added to `mask` with `op`, or a new mask when mask is 0. 0 on failure.
uint32_t latent_object_from_coverage(const LatentCore *core, uint32_t mask, const char *op, uint32_t side, const uint8_t *probs, double x, double y, char **error);

// A stored segmentation (an object mask's "seg") from side*side coverage bytes, as JSON; NULL on bad sizes.
char *latent_seg_from_coverage(uint32_t side, const uint8_t *probs);

void latent_image_free(LatentImage *img);
void latent_string_free(char *s);
