//! Latent's bridge to the LightCraft engine. The SwiftUI app (apps/latent-ios) calls the C
//! functions in [`ffi`] (declared in `include/latent.h`); they wrap [`Core`], which is safe Rust.
//!
//! Every edit goes through the engine's commands ([`Core::execute`]), the same ones the desktop app,
//! the CLI and the automation interface use, so the phone can do nothing they can't.
#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

pub mod ffi;

use std::path::Path;
use std::sync::{Mutex, MutexGuard};

use lightcraft_engine::Session;
use lightcraft_engine::catalog::PhotoId;
use serde_json::{Value, json};

/// The number of histogram bins per channel [`Image`] carries.
pub const HIST_BINS: usize = 256;

/// A rendered photo: 8-bit RGBA, rows top to bottom, and its red, green and blue histograms.
pub struct Image {
    pub width: usize,
    pub height: usize,
    pub rgba: Vec<u8>,
    /// Red, then green, then blue, [`HIST_BINS`] each.
    pub hist: Vec<u32>,
}

/// An HDR render: linear RGB with SDR white at 1.0 and highlights up to `peak`, as half floats
/// (RGBA, alpha 1), and a histogram over SDR and then HDR (see [`HDR_SDR_SHARE`]).
pub struct HdrImage {
    pub width: usize,
    pub height: usize,
    /// IEEE half-float bits, 4 per pixel.
    pub rgba16f: Vec<u16>,
    pub hist: Vec<u32>,
    /// The brightest value the render may reach (2^headroom).
    pub peak: f32,
}

/// How much of the HDR histogram's width the SDR range takes; the rest is one band per stop above
/// SDR white, up to the headroom.
pub const HDR_SDR_SHARE: f32 = 0.5;

/// How a mask overlay is drawn: the engine's view name, colour and opacity (0..100).
#[derive(Clone, Copy, Debug)]
pub struct MaskLook<'a> {
    pub view: &'a str,
    pub color: [u8; 3],
    pub opacity: u8,
}

impl Default for MaskLook<'_> {
    fn default() -> Self {
        Self { view: "color", color: [235, 64, 64], opacity: 50 }
    }
}

/// One library session, shared by the app's threads.
pub struct Core {
    session: Mutex<Session>,
}

impl Core {
    /// The library in `dir`, or (with `None`) the default library folder: on iOS, the app's
    /// Documents folder, the same one the earlier LightCraft phone app used. If it can't be opened the
    /// session is empty and in memory, and [`Core::problem`] says why.
    pub fn open(dir: Option<&Path>) -> (Core, Option<String>) {
        let bare = || Session::new().with_fs().with_default_denoise_models().with_system_clock();
        let dir = dir.map(Path::to_path_buf).or_else(lightcraft_engine::library::default_dir);
        let (session, problem) = match dir {
            None => (bare(), Some("There is no folder to keep the library in.".to_string())),
            Some(dir) => {
                let first_run = !dir.exists();
                let mut s = bare();
                match s.open_library(&dir, first_run) {
                    Ok(report) => {
                        log::info!("library {}: {} log records replayed", dir.display(), report.replayed);
                        (s.with_default_lens_database().with_lens_auto_download(), None)
                    }
                    Err(e) => (bare(), Some(format!("The library in {} could not be opened: {e}", dir.display()))),
                }
            }
        };
        let mut session = session;
        // AI mask work runs on the engine's own thread; `poll` takes the results in
        session.segmenter.background = true;
        (Core { session: Mutex::new(session) }, problem)
    }

    /// Export photo `id` with its edits. `options` is the engine's export options as JSON
    /// (camelCase: format, quality, resize {mode, value}, hdr, metadata, removeLocation,
    /// watermark {text, size, opacity, anchor}, colorSpace…; anything left out keeps its default).
    /// Returns the file name and its bytes.
    pub fn export(&self, id: u64, options: &str) -> Result<(String, Vec<u8>), String> {
        use lightcraft_engine::export::ExportOptions;
        let o: ExportOptions = if options.trim().is_empty() {
            ExportOptions::default()
        } else {
            serde_json::from_str(options).map_err(|e| format!("export options: {e}"))?
        };
        let prepared = lightcraft_engine::export::prepare_export(&mut self.lock(), PhotoId(id), &o, 1)?;
        let out = prepared.run()?;
        Ok((out.file_name, out.bytes))
    }

    /// Where the SAM 3 model (AI masks) is looked for: a folder holding `model.safetensors`,
    /// `vocab.json` and `merges.txt`.
    pub fn set_ai_model_dir(&self, dir: &Path) {
        self.lock().segmenter.dir = Some(dir.to_path_buf());
    }

    /// Take in finished background work (AI mask selections) and say what happened:
    /// `{"changed": bool, "messages": [...], "busy": bool}`. Cheap when nothing is pending.
    pub fn poll(&self) -> String {
        let mut s = self.lock();
        let polled = s.segment_poll();
        let busy = s.segmenter.busy() || s.segmenter.pending_clicks().is_some();
        json!({"changed": polled.changed, "messages": polled.messages, "busy": busy}).to_string()
    }

    /// An in-memory session with the demo photos (tests, previews).
    pub fn demo() -> Core {
        Core { session: Mutex::new(Session::with_demo().with_system_clock()) }
    }

    fn lock(&self) -> MutexGuard<'_, Session> {
        // a panic elsewhere while holding the lock leaves the session as it was: keep using it
        self.session.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Run an engine command. `params` is a JSON object (empty means `{}`). The answer is JSON:
    /// `{"ok": result}` or `{"error": message}`.
    pub fn execute(&self, cmd: &str, params: &str) -> String {
        let params: Value = if params.trim().is_empty() {
            json!({})
        } else {
            match serde_json::from_str(params) {
                Ok(v) => v,
                Err(e) => return json!({"error": format!("{cmd}: the parameters are not JSON: {e}")}).to_string(),
            }
        };
        let r = self.lock().execute(cmd, &params);
        match r {
            Ok(v) => json!({"ok": v}).to_string(),
            Err(e) => json!({"error": e.to_string()}).to_string(),
        }
    }

    /// Render a photo with its edits, to fit `max_w` × `max_h`. The work runs outside the session
    /// lock, so commands are not held up by it.
    pub fn render(&self, id: u64, max_w: usize, max_h: usize) -> Result<Image, String> {
        let job = self.lock().render_job(PhotoId(id), max_w.max(1), max_h.max(1), false, true).ok_or("no such photo")?;
        self.finish(job.run())
    }

    /// The photo as it was before any edit, to fit `max_w` × `max_h` (for comparing).
    pub fn render_original(&self, id: u64, max_w: usize, max_h: usize) -> Result<Image, String> {
        let job = self.lock().render_job(PhotoId(id), max_w.max(1), max_h.max(1), true, true).ok_or("no such photo")?;
        self.finish(job.run())
    }

    /// The photo with mask `mask` shown as a red tint over it (where the mask applies), for
    /// drawing masks.
    pub fn render_mask(&self, id: u64, max_w: usize, max_h: usize, mask: u32) -> Result<Image, String> {
        self.render_mask_as(id, max_w, max_h, mask, MaskLook::default())
    }

    /// Photo `id` with mask `mask` drawn the way `look` says (the engine's mask views: "color",
    /// "colorOnBw", "imageOnBlack", "imageOnWhite", "whiteOnBlack"; an unknown view is "color").
    pub fn render_mask_as(&self, id: u64, max_w: usize, max_h: usize, mask: u32, look: MaskLook) -> Result<Image, String> {
        use lightcraft_pipeline::MaskView;
        let mut job = self.lock().render_job(PhotoId(id), max_w.max(1), max_h.max(1), false, true).ok_or("no such photo")?;
        let mask = u16::try_from(mask).map_err(|_| "no such mask")?;
        let view = MaskView::ALL.into_iter().find(|v| v.name() == look.view).unwrap_or(MaskView::Color);
        let opacity = look.opacity.min(100);
        job.request.overlay = lightcraft_pipeline::Overlay::Mask { id: mask, view, color: look.color, opacity };
        let salt = (view as u64) << 40
            | u64::from(look.color[0]) << 32
            | u64::from(look.color[1]) << 24
            | u64::from(look.color[2]) << 16
            | u64::from(opacity) << 8;
        job.key ^= 0x4d41_534b_0000_0000 ^ u64::from(mask).rotate_left(23) ^ salt.rotate_left(3);
        job.cache = None;
        self.finish(job.run())
    }

    /// The whole photo, not cropped or straightened (flips and the rest of the edit applied), to
    /// fit `max_w` × `max_h`: what the crop box is drawn over.
    pub fn render_uncropped(&self, id: u64, max_w: usize, max_h: usize) -> Result<Image, String> {
        let job = self.lock().render_job(PhotoId(id), max_w.max(1), max_h.max(1), false, false).ok_or("no such photo")?;
        self.finish(job.run())
    }

    /// A preview of preset `preset` on the photo, long edge about `long_edge`: the photo's edit with
    /// the preset applied at full strength, rendered without changing the photo.
    pub fn preset_thumb(&self, id: u64, preset: &str, long_edge: usize) -> Result<Image, String> {
        let job = {
            let mut s = self.lock();
            let p = s.presets.iter().find(|x| x.id == preset).cloned().ok_or("unknown preset")?;
            let d = s.develop_of(PhotoId(id)).ok_or("no such photo")?;
            let next = p.apply_on(&d, &d, 1.0);
            let edge = long_edge.max(16);
            let mut job = s.render_job(PhotoId(id), edge, edge, false, true).ok_or("no such photo")?;
            let salt = preset.bytes().fold(0xcbf2_9ce4_8422_2325u64, |h, b| (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3));
            job.settings = std::sync::Arc::new(next);
            job.key ^= salt.rotate_left(7);
            job.cache = None;
            job
        };
        self.finish(job.run())
    }

    /// A small square-ish thumbnail with the photo's edits.
    pub fn thumb(&self, id: u64, long_edge: usize) -> Result<Image, String> {
        let job = self.lock().thumb_job(PhotoId(id), long_edge.max(16)).ok_or("no thumbnail for this photo")?;
        self.finish(job.run())
    }

    /// The photo's HDR render (its edit with HDR on). An error when the photo isn't in HDR or the
    /// engine gave no HDR pixels for it; the caller then shows the ordinary render.
    pub fn render_hdr(&self, id: u64, max_w: usize, max_h: usize) -> Result<HdrImage, String> {
        let mut job = self.lock().render_job(PhotoId(id), max_w.max(1), max_h.max(1), false, true).ok_or("no such photo")?;
        if !job.settings.hdr.enabled {
            return Err("HDR is off for this photo".into());
        }
        let peak = job.settings.hdr.peak();
        let headroom = job.settings.hdr.max_ev.clamp(0.0, 5.0) as f32;
        job.request.depth = lightcraft_pipeline::OutputDepth::F32Hdr;
        // its own result: not the 8-bit preview's cache entry
        job.key ^= 0x4844_5250_5245_5649;
        job.cache = None;
        let r = job.run();
        self.lock().accept(&r);
        let deep = r.rendered?.deep.ok_or("the engine gave no HDR pixels")?;
        let lightcraft_pipeline::DeepSamples::F32(rgb) = deep.samples else { return Err("the HDR render is not floating point".into()) };
        let n = deep.width * deep.height;
        if rgb.len() < n * 3 {
            return Err("the HDR render is short".into());
        }
        let mut out = Vec::with_capacity(n * 4);
        let mut hist = vec![0u32; HIST_BINS * 3];
        let (pixels, _) = rgb.as_chunks::<3>();
        for px in pixels.iter().take(n) {
            for (c, &v) in px.iter().enumerate() {
                let v = if v.is_finite() { v.clamp(0.0, peak) } else { 0.0 };
                out.push(f16_bits(v));
                let bin = (hdr_position(v, headroom) * (HIST_BINS - 1) as f32).round() as usize;
                if let Some(b) = hist.get_mut(c * HIST_BINS + bin.min(HIST_BINS - 1)) {
                    *b = b.saturating_add(1);
                }
            }
            out.push(0x3c00); // alpha 1.0
        }
        Ok(HdrImage { width: deep.width, height: deep.height, rgba16f: out, hist, peak })
    }

    fn finish(&self, r: lightcraft_engine::media::RenderResult) -> Result<Image, String> {
        self.lock().accept(&r);
        let rendered = r.rendered?;
        let img = rendered.image;
        let rgba = img.data.iter().flatten().copied().collect();
        let h = &rendered.histogram;
        let mut hist = Vec::with_capacity(HIST_BINS * 3);
        for ch in [&h.r, &h.g, &h.b] {
            hist.extend(resample(ch, HIST_BINS));
        }
        Ok(Image { width: img.width, height: img.height, rgba, hist })
    }
}

/// Where a linear value sits on the HDR histogram (0…1): SDR (display-encoded) in the first
/// [`HDR_SDR_SHARE`], then one equal band per stop above white.
pub fn hdr_position(v: f32, headroom: f32) -> f32 {
    if v <= 1.0 {
        let e = if v <= 0.003_130_8 { 12.92 * v } else { 1.055 * v.max(0.0).powf(1.0 / 2.4) - 0.055 };
        e.clamp(0.0, 1.0) * HDR_SDR_SHARE
    } else if headroom <= 0.0 {
        HDR_SDR_SHARE
    } else {
        (HDR_SDR_SHARE + (1.0 - HDR_SDR_SHARE) * v.log2() / headroom).min(1.0)
    }
}

/// IEEE 754 half-float bits of `v` (rounded to nearest; too large becomes the largest half, tiny
/// becomes zero, which is all an image needs).
pub fn f16_bits(v: f32) -> u16 {
    let bits = v.to_bits();
    let sign = ((bits >> 16) & 0x8000) as u16;
    let exp = ((bits >> 23) & 0xff) as i32 - 127 + 15;
    let mant = bits & 0x7f_ffff;
    if v.is_nan() {
        return sign | 0x7e00;
    }
    if exp >= 31 {
        return sign | 0x7bff;
    }
    if exp <= 0 {
        return sign;
    }
    let mut h = (exp as u32) << 10 | (mant >> 13);
    if mant & 0x1000 != 0 {
        h += 1; // round half up; a carry into the exponent is the right next value
    }
    sign | h.min(0x7bff) as u16
}

/// `bins` sums of `src` (any length) spread evenly over the output.
fn resample(src: &[u32], bins: usize) -> Vec<u32> {
    let mut out = vec![0u32; bins];
    if src.is_empty() {
        return out;
    }
    for (i, v) in src.iter().enumerate() {
        let j = i * bins / src.len();
        if let Some(o) = out.get_mut(j) {
            *o = o.saturating_add(*v);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(answer: &str) -> Value {
        let v: Value = serde_json::from_str(answer).unwrap_or_default();
        assert!(v.get("error").is_none(), "{answer}");
        v["ok"].clone()
    }

    #[test]
    fn a_command_answers_with_ok_or_error() {
        let core = Core::demo();
        let photos = ok(&core.execute("catalog.query", ""));
        assert!(photos["total"].as_u64().unwrap_or(0) > 0, "{photos}");
        let bad: Value = serde_json::from_str(&core.execute("no.such.command", "{}")).unwrap_or_default();
        assert!(bad["error"].is_string(), "{bad}");
        let bad: Value = serde_json::from_str(&core.execute("catalog.query", "{not json")).unwrap_or_default();
        assert!(bad["error"].is_string(), "{bad}");
    }

    #[test]
    fn an_edit_changes_the_render() {
        let core = Core::demo();
        let photos = ok(&core.execute("catalog.query", ""));
        let id = photos["photos"][0]["id"].as_u64().unwrap_or(0);
        ok(&core.execute("library.select", &json!({"ids": [id], "active": id}).to_string()));
        let before = core.render(id, 160, 160).map_err(|e| e.to_string());
        let before = before.as_ref().map(|i| i.rgba.iter().map(|&b| u64::from(b)).sum::<u64>());
        ok(&core.execute("develop.set", &json!({"control": "light.exposure", "value": 2.0}).to_string()));
        let after = core.render(id, 160, 160);
        let img = after.as_ref().map_err(|e| e.to_string());
        let after_sum = img.as_ref().map(|i| i.rgba.iter().map(|&b| u64::from(b)).sum::<u64>());
        assert!(matches!((&before, &after_sum), (Ok(b), Ok(a)) if a > b), "{before:?} {after_sum:?}");
        let img = after.unwrap_or(Image { width: 0, height: 0, rgba: vec![], hist: vec![] });
        assert!(img.width <= 160 && img.height <= 160 && img.width > 0);
        assert_eq!(img.rgba.len(), img.width * img.height * 4);
        assert_eq!(img.hist.len(), HIST_BINS * 3);
    }

    #[test]
    fn an_hdr_render_keeps_highlights_above_white() {
        let core = Core::demo();
        let photos = ok(&core.execute("catalog.query", ""));
        let id = photos["photos"][0]["id"].as_u64().unwrap_or(0);
        ok(&core.execute("library.select", &json!({"ids": [id], "active": id}).to_string()));
        assert!(core.render_hdr(id, 120, 120).is_err(), "HDR is off");
        ok(&core.execute("develop.hdr", &json!({"enabled": true}).to_string()));
        ok(&core.execute("develop.set", &json!({"control": "light.exposure", "value": 2.0}).to_string()));
        let img = core.render_hdr(id, 120, 120);
        let Ok(img) = img else { panic!("{:?}", img.err()) };
        assert_eq!(img.rgba16f.len(), img.width * img.height * 4);
        let one = f16_bits(1.0);
        assert!(img.rgba16f.as_chunks::<4>().0.iter().any(|p| p[..3].iter().any(|&h| h > one)), "nothing above SDR white");
        assert!(img.peak > 1.0);
    }

    #[test]
    fn half_floats_keep_their_order() {
        let vals = [0.0f32, 0.001, 0.25, 0.5, 1.0, 1.5, 4.0, 32.0];
        let bits: Vec<u16> = vals.iter().map(|&v| f16_bits(v)).collect();
        assert!(bits.windows(2).all(|w| w[0] < w[1]), "{bits:?}");
        assert_eq!(f16_bits(1.0), 0x3c00);
        assert!(hdr_position(1.0, 3.0) <= hdr_position(2.0, 3.0) && hdr_position(8.0, 3.0) <= 1.0);
    }

    #[test]
    fn a_preset_preview_leaves_the_photo_alone() {
        let core = Core::demo();
        let photos = ok(&core.execute("catalog.query", ""));
        let id = photos["photos"][0]["id"].as_u64().unwrap_or(0);
        ok(&core.execute("library.select", &json!({"ids": [id], "active": id}).to_string()));
        let presets = ok(&core.execute("presets.list", ""));
        let pid = presets[0]["id"].as_str().unwrap_or("").to_string();
        let before = ok(&core.execute("develop.get", ""));
        let thumb = core.preset_thumb(id, &pid, 96);
        assert!(thumb.as_ref().is_ok_and(|t| t.width > 0 && t.width <= 96), "{:?}", thumb.err());
        assert_eq!(ok(&core.execute("develop.get", "")), before, "a preview must not edit the photo");
        let plain = core.render(id, 96, 96).map(|i| i.rgba).unwrap_or_default();
        assert_ne!(thumb.map(|i| i.rgba).unwrap_or_default(), plain, "the preview should show the preset");
        assert!(core.render_uncropped(id, 96, 96).is_ok());
        let m = ok(&core.execute("mask.add", r#"{"kind":"radial"}"#));
        let mid = m["activeMask"].as_u64().unwrap_or(0) as u32;
        let tinted = core.render_mask(id, 96, 96, mid).map(|i| i.rgba).unwrap_or_default();
        assert!(!tinted.is_empty() && tinted != plain, "the mask overlay should tint the photo");
        let look = |view, color| MaskLook { view, color, opacity: 60 };
        let mask_only = core.render_mask_as(id, 96, 96, mid, look("whiteOnBlack", [255, 255, 255])).map(|i| i.rgba).unwrap_or_default();
        assert!(!mask_only.is_empty() && mask_only != tinted, "the white-on-black view draws the mask, not a tint");
        let green = core.render_mask_as(id, 96, 96, mid, look("color", [40, 220, 90])).map(|i| i.rgba).unwrap_or_default();
        assert_ne!(green, tinted, "the overlay colour is used");
    }

    #[test]
    fn ai_masks_say_the_model_is_missing_until_it_is_installed() {
        // Sky, Subject and Background need no model; picking an object or describing one does
        let core = Core::demo();
        let dir = std::env::temp_dir().join(format!("latent-no-sam3-{}", std::process::id()));
        core.set_ai_model_dir(&dir);
        let status = ok(&core.execute("segment.model.status", ""));
        assert_eq!(status["available"], json!(true), "this build has AI masks: {status}");
        assert_eq!(status["installed"], json!(false), "{status}");
        let photos = ok(&core.execute("catalog.query", ""));
        let id = photos["photos"][0]["id"].as_u64().unwrap_or(0);
        ok(&core.execute("library.select", &json!({"ids": [id], "active": id}).to_string()));
        ok(&core.execute("mask.add", r#"{"kind":"sky"}"#));
        let object: Value = serde_json::from_str(&core.execute("mask.add", r#"{"kind":"object"}"#)).unwrap_or_default();
        assert!(object["error"].is_string(), "an object mask needs the model: {object}");
        let polled: Value = serde_json::from_str(&core.poll()).unwrap_or_default();
        assert_eq!(polled["busy"], json!(false), "{polled}");
    }

    #[test]
    fn an_export_is_an_image_file() {
        let core = Core::demo();
        let photos = ok(&core.execute("catalog.query", ""));
        let id = photos["photos"][0]["id"].as_u64().unwrap_or(0);
        let small = r#"{"format":"jpeg","quality":80,"resize":{"mode":"longEdge","value":400}}"#;
        let jpeg = core.export(id, small);
        let Ok((name, bytes)) = jpeg else { panic!("{:?}", jpeg.err()) };
        assert!(name.to_lowercase().ends_with(".jpg"), "{name}");
        assert_eq!(&bytes[..2], &[0xff, 0xd8], "a JPEG starts with SOI");
        let png = core.export(id, &small.replace("jpeg", "png")).map(|(_, b)| b).unwrap_or_default();
        assert_eq!(png.get(..4), Some(&b"\x89PNG"[..]));
        let marked = small.replace("}}", r#"},"watermark":{"text":"LATENT","size":0.2,"opacity":1}}"#);
        let marked = core.export(id, &marked).map(|(_, b)| b);
        assert!(marked.is_ok_and(|b| b != bytes), "a watermark changes the file");
        assert!(core.export(id, "{nonsense").is_err());
        for f in ["tiff", "avif", "jxl", "webp"] {
            let r = core.export(id, &small.replace("jpeg", f));
            assert!(r.is_ok_and(|(_, b)| !b.is_empty()), "{f} exports");
        }
    }

    #[test]
    fn resampling_keeps_the_total() {
        let src: Vec<u32> = (0..1000).collect();
        let out = resample(&src, 256);
        assert_eq!(out.iter().map(|&v| u64::from(v)).sum::<u64>(), src.iter().map(|&v| u64::from(v)).sum::<u64>());
    }
}
