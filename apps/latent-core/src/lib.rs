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
                // no sample photos: the library starts empty and fills from the camera roll
                let mut s = bare();
                match s.open_library(&dir, false) {
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
        // sample photos earlier versions added go away for good
        let demos: Vec<u64> =
            session.catalog.photos().filter(|p| matches!(p.source, lightcraft_catalog::Source::Demo { .. })).map(|p| p.id.0).collect();
        if !demos.is_empty() {
            let ids = serde_json::json!({ "ids": demos });
            if let Err(e) = session.execute("photo.deletePermanently", &ids) {
                log::warn!("removing the sample photos: {e}");
            }
        }
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

    /// The photo's depth map as the photo is framed (cropped, straightened, flipped): near white,
    /// far black, to fit `max_w` × `max_h`. Black all over without a depth map.
    pub fn render_depth(&self, id: u64, max_w: usize, max_h: usize) -> Result<Image, String> {
        use lightcraft_develop::{Mask, MaskComponent, MaskOp, MaskShape};
        const VIEW_ID: u16 = 65_000;
        let mut job = self.lock().render_job(PhotoId(id), max_w.max(1), max_h.max(1), false, true).ok_or("no such photo")?;
        // a mask whose strength is the nearness, shown white on black, without changing the photo
        let mut d = (*job.settings).clone();
        d.masks.retain(|m| m.id != u32::from(VIEW_ID));
        d.masks.push(Mask {
            id: u32::from(VIEW_ID),
            components: vec![MaskComponent {
                name: None,
                op: MaskOp::Add,
                invert: false,
                shape: MaskShape::DepthRange { lo: 0.0, hi: 0.0, feather: 1.0 },
            }],
            ..Default::default()
        });
        job.settings = std::sync::Arc::new(d);
        job.request.overlay = lightcraft_pipeline::Overlay::Mask {
            id: VIEW_ID,
            view: lightcraft_pipeline::MaskView::WhiteOnBlack,
            color: [255, 255, 255],
            opacity: 100,
        };
        job.key ^= 0x4445_5054_4800_0000;
        job.cache = None;
        self.finish(job.run())
    }

    /// A stored segmentation (the `seg` of an object mask) from `side × side` coverage bytes over
    /// the uncropped, oriented photo stretched to a square, as JSON.
    pub fn seg_from_coverage(side: usize, probs: &[u8]) -> Result<String, String> {
        if side == 0 || side > lightcraft_develop::segmask::MAX_SIDE || probs.len() != side * side {
            return Err("the selection is the wrong size".into());
        }
        let logits: Vec<f32> = probs
            .iter()
            .map(|&b| {
                let p = (f32::from(b) / 255.0).clamp(1e-4, 1.0 - 1e-4);
                (p / (1.0 - p)).ln()
            })
            .collect();
        serde_json::to_string(&lightcraft_develop::SegMask::from_logits(side, &logits)).map_err(|e| e.to_string())
    }

    /// An object mask from a selection the app made (Apple's Vision, say): `probs` is `side × side`
    /// coverage (0 out … 255 in) over the uncropped, oriented photo stretched to a square, the
    /// way the engine's own segmentations are stored; `at` is where the user tapped (mask
    /// coordinates). With `mask` it becomes a part of that mask (`op` "add", "subtract" or
    /// "intersect"), else a new mask. Returns the mask's id.
    pub fn object_from_coverage(&self, mask: Option<u32>, op: &str, side: usize, probs: &[u8], at: (f64, f64)) -> Result<u32, String> {
        use lightcraft_develop::{MaskShape, SegMask};
        if side == 0 || side > lightcraft_develop::segmask::MAX_SIDE || probs.len() != side * side {
            return Err("the selection is the wrong size".into());
        }
        // coverage to logits: 0 and 255 are fully out and in
        let logits: Vec<f32> = probs
            .iter()
            .map(|&b| {
                let p = (f32::from(b) / 255.0).clamp(1e-4, 1.0 - 1e-4);
                (p / (1.0 - p)).ln()
            })
            .collect();
        let hint = if at.0.is_finite() && at.1.is_finite() { vec![lightcraft_geom::Point::new(at.0, at.1)] } else { Vec::new() };
        let shape = MaskShape::Object { hint, exclude: Vec::new(), seg: Some(SegMask::from_logits(side, &logits)), detail: Vec::new(), edge: 0.0 };
        let shape = serde_json::to_value(&shape).map_err(|e| e.to_string())?;
        let run = |cmd: &str, p: serde_json::Value| -> Result<serde_json::Value, String> {
            let r: serde_json::Value = serde_json::from_str(&self.execute(cmd, &p.to_string())).map_err(|e| e.to_string())?;
            match r.get("error").and_then(|e| e.as_str()) {
                Some(e) => Err(e.to_string()),
                None => Ok(r.get("ok").cloned().unwrap_or(r)),
            }
        };
        let (id, component) = match mask {
            Some(id) => {
                run("mask.addComponent", serde_json::json!({"id": id, "op": op, "kind": "brush"}))?;
                let d = run("develop.get", serde_json::json!({}))?;
                let parts = d["masks"]
                    .as_array()
                    .and_then(|ms| ms.iter().find(|m| m["id"].as_u64() == Some(u64::from(id))))
                    .and_then(|m| m["components"].as_array())
                    .map_or(1, Vec::len);
                (id, parts.saturating_sub(1))
            }
            None => {
                let r = run("mask.add", serde_json::json!({"kind": "brush"}))?;
                let id = r["activeMask"].as_u64().and_then(|v| u32::try_from(v).ok()).ok_or("no mask was made")?;
                (id, 0)
            }
        };
        run("mask.update", serde_json::json!({"id": id, "component": component, "shape": shape}))?;
        Ok(id)
    }

    /// Give photo `id` a depth map: `w × h` bytes, 0 nearest … 255 farthest, over the photo as
    /// the camera stood it (upright, before the user's rotation). An empty or ill-sized map takes
    /// the photo's depth map away. Lens Blur's Focus Range and Depth Range masks use it.
    pub fn set_depth(&self, id: u64, w: usize, h: usize, data: &[u8]) {
        let map = (w > 0 && h > 0 && data.len() == w.saturating_mul(h)).then(|| lightcraft_raster::Image::<u8> {
            width: w,
            height: h,
            data: data.to_vec(),
        });
        self.lock().set_depth_map(PhotoId(id), map);
    }

    /// Denoise photo `id` with the app's model: `run` takes one tile, `3 × size × size` planar values 0…1 (gamma
    /// encoded, about as a phone photo's are), and writes the cleaned tile to its second argument. The photo's source
    /// is read at full size, balanced and brightened to the range the model knows, cut into overlapping tiles, and
    /// only the model's change is taken back to the linear picture (so highlights beyond white keep their values).
    /// The result becomes the photo's denoised picture, which the Denoise amount mixes in. `progress(done, total)`
    /// is told after each tile; `run` returning false stops it with an error.
    pub fn denoise(
        &self,
        id: u64,
        size: usize,
        run: &mut dyn FnMut(&[f32], &mut [f32]) -> bool,
        progress: &mut dyn FnMut(usize, usize),
    ) -> Result<(), String> {
        if !(64..=2048).contains(&size) {
            return Err(format!("the model's tile size {size} is not usable"));
        }
        // read the source with the session unlocked: decoding a large raw takes seconds
        let job = self.lock().render_job(PhotoId(id), 1 << 20, 1 << 20, false, false).ok_or("no such photo")?;
        let src = job.source.load_source()?.image;
        let out = denoise_tiles(&src, size, run, progress)?;
        self.lock().set_app_denoised(PhotoId(id), Some(out));
        Ok(())
    }

    /// Save photo `id`'s denoised picture to `path` (half floats), to load it again next time. False without one.
    pub fn save_denoised(&self, id: u64, path: &Path) -> Result<bool, String> {
        let Some(t) = self.lock().app_denoised.get(&PhotoId(id)).cloned() else { return Ok(false) };
        let img = &t.image;
        let mut bytes = Vec::with_capacity(16 + img.data.len() * 6);
        bytes.extend_from_slice(DENOISED_MAGIC);
        bytes.extend_from_slice(&(img.width as u32).to_le_bytes());
        bytes.extend_from_slice(&(img.height as u32).to_le_bytes());
        for p in &img.data {
            for v in p {
                bytes.extend_from_slice(&half::f16::from_f32(*v).to_le_bytes());
            }
        }
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, &bytes).and_then(|()| std::fs::rename(&tmp, path)).map_err(|e| format!("saving the denoised picture: {e}"))?;
        Ok(true)
    }

    /// Load a denoised picture [`Self::save_denoised`] wrote for photo `id`. False when the file is not one.
    pub fn load_denoised(&self, id: u64, path: &Path) -> bool {
        let Ok(bytes) = std::fs::read(path) else { return false };
        match parse_denoised(&bytes) {
            Some(img) => {
                self.lock().set_app_denoised(PhotoId(id), Some(img));
                true
            }
            None => false,
        }
    }

    /// Whether photo `id` has a denoised picture.
    pub fn has_denoised(&self, id: u64) -> bool {
        self.lock().app_denoised.contains_key(&PhotoId(id))
    }

    /// Take photo `id`'s denoised picture away.
    pub fn forget_denoised(&self, id: u64) {
        self.lock().set_app_denoised(PhotoId(id), None);
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

    /// A preview of creative profile `profile` (built in, or an imported LUT) on the photo, long
    /// edge about `long_edge`, at the photo's profile Amount (100 when it has none): rendered
    /// without changing the photo.
    pub fn profile_thumb(&self, id: u64, profile: &str, long_edge: usize) -> Result<Image, String> {
        let job = {
            let mut s = self.lock();
            let known = lightcraft_engine::presets::PROFILES.iter().any(|p| p.id == profile) || s.lut_profiles.iter().any(|p| p.id == profile);
            if !known {
                return Err("unknown profile".into());
            }
            let mut d = (*s.develop_of(PhotoId(id)).ok_or("no such photo")?).clone();
            d.profile.id = profile.to_string();
            if d.profile.amount <= 0.0 {
                d.profile.amount = 100.0;
            }
            let edge = long_edge.max(16);
            let mut job = s.render_job(PhotoId(id), edge, edge, false, true).ok_or("no such photo")?;
            let salt = profile.bytes().fold(0x9e37_79b9_7f4a_7c15u64, |h, b| (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3));
            job.settings = std::sync::Arc::new(d);
            job.key ^= salt.rotate_left(11);
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

const DENOISED_MAGIC: &[u8; 8] = b"LTDN0001";

fn parse_denoised(bytes: &[u8]) -> Option<lightcraft_raster::Rgb32f> {
    let rest = bytes.strip_prefix(DENOISED_MAGIC.as_slice())?;
    let w = u32::from_le_bytes(rest.get(0..4)?.try_into().ok()?) as usize;
    let h = u32::from_le_bytes(rest.get(4..8)?.try_into().ok()?) as usize;
    let data = rest.get(8..)?;
    let n = w.checked_mul(h)?;
    if w == 0 || h == 0 || n > 200_000_000 || data.len() != n.checked_mul(6)? {
        return None;
    }
    let mut img = lightcraft_raster::Rgb32f::filled(w, h, [0.0; 3]);
    let (cells, _) = data.as_chunks::<6>();
    for (p, c) in img.data.iter_mut().zip(cells) {
        *p = std::array::from_fn(|i| {
            let v = half::f16::from_le_bytes([c[i * 2], c[i * 2 + 1]]).to_f32();
            if v.is_finite() { v } else { 0.0 }
        });
    }
    Some(img)
}

/// Context each tile reads around the part of it that is kept.
const DENOISE_OVERLAP: usize = 32;

/// [`Core::denoise`]'s work on picture `src`.
fn denoise_tiles(
    src: &lightcraft_raster::Rgb32f,
    size: usize,
    run: &mut dyn FnMut(&[f32], &mut [f32]) -> bool,
    progress: &mut dyn FnMut(usize, usize),
) -> Result<lightcraft_raster::Rgb32f, String> {
    let (w, h) = (src.width, src.height);
    if w == 0 || h == 0 {
        return Err("the photo has no picture".into());
    }
    // balance the channels (a raw's are not yet white balanced) and set the brightness so that the brightest
    // part (99.5 %) lands near white
    let step_px = (w * h / 200_000).max(1);
    let mut sums = [0f64; 3];
    let mut lum: Vec<f32> = Vec::with_capacity(w * h / step_px + 1);
    for p in src.data.iter().step_by(step_px) {
        for c in 0..3 {
            if p[c].is_finite() {
                sums[c] += f64::from(p[c].max(0.0));
            }
        }
        lum.push(p.iter().copied().filter(|v| v.is_finite()).fold(0f32, f32::max));
    }
    let gain: [f32; 3] = std::array::from_fn(|c| if sums[c] > 0.0 { ((sums[1] / sums[c]) as f32).clamp(0.25, 4.0) } else { 1.0 });
    lum.sort_by(f32::total_cmp);
    let top = lum.get(lum.len().saturating_sub(1) * 995 / 1000).copied().unwrap_or(1.0) * gain.iter().copied().fold(0f32, f32::max);
    let k = if top > 1e-6 { (0.92 / top).clamp(0.02, 64.0) } else { 1.0 };
    let scale: [f32; 3] = gain.map(|g| g * k);
    let enc = |v: f32, c: usize| if v.is_finite() { (v * scale[c]).clamp(0.0, 1.0).powf(1.0 / 2.2) } else { 0.0 };
    let dec = |e: f32, c: usize| e.clamp(0.0, 1.0).powf(2.2) / scale[c];

    let keep = size - 2 * DENOISE_OVERLAP;
    let (tx_n, ty_n) = (w.div_ceil(keep), h.div_ceil(keep));
    let total = tx_n * ty_n;
    let mut out = src.clone();
    let plane = size * size;
    let mut input = vec![0f32; plane * 3];
    let mut cleaned = vec![0f32; plane * 3];
    for ty in 0..ty_n {
        for tx in 0..tx_n {
            let (x0, y0) = (tx * keep, ty * keep);
            let at = |i: usize, origin: usize, n: usize| (origin + i).saturating_sub(DENOISE_OVERLAP).min(n - 1);
            for yy in 0..size {
                let sy = at(yy, y0, h);
                for xx in 0..size {
                    let p = src.data[sy * w + at(xx, x0, w)];
                    for c in 0..3 {
                        input[c * plane + yy * size + xx] = enc(p[c], c);
                    }
                }
            }
            if !run(&input, &mut cleaned) {
                return Err("the denoise model stopped".into());
            }
            for yy in DENOISE_OVERLAP..DENOISE_OVERLAP + keep {
                let y = y0 + yy - DENOISE_OVERLAP;
                if y >= h {
                    break;
                }
                for xx in DENOISE_OVERLAP..DENOISE_OVERLAP + keep {
                    let x = x0 + xx - DENOISE_OVERLAP;
                    if x >= w {
                        break;
                    }
                    let o = &mut out.data[y * w + x];
                    for c in 0..3 {
                        let (i, j) = (input[c * plane + yy * size + xx], cleaned[c * plane + yy * size + xx]);
                        let d = dec(j, c) - dec(i, c);
                        if d.is_finite() && o[c].is_finite() {
                            o[c] += d;
                        }
                    }
                }
            }
            progress(ty * tx_n + tx + 1, total);
        }
    }
    Ok(out)
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
    fn a_depth_map_moves_the_lens_blur_focus() {
        let core = Core::demo();
        let photos = ok(&core.execute("catalog.query", ""));
        let id = photos["photos"][0]["id"].as_u64().unwrap_or(0);
        ok(&core.execute("library.select", &json!({"ids": [id], "active": id}).to_string()));
        let blur = json!({"settings": {"lens_blur": {"enabled": true, "amount": 100.0, "focal_range": 20.0, "focal_distance": 10.0}}});
        ok(&core.execute("develop.merge", &blur.to_string()));
        let px = |c: &Core| c.render(id, 96, 96).map(|i| i.rgba).unwrap_or_default();
        let before = px(&core);
        let (w, h) = (32, 32);
        let map: Vec<u8> = (0..w * h).map(|i| if i % w < w / 2 { 0 } else { 255 }).collect();
        core.set_depth(id, w, h, &map);
        assert_ne!(px(&core), before, "the depth map decides what is sharp");
        let view = core.render_depth(id, 64, 64);
        let Ok(v) = view else { panic!("{:?}", view.err()) };
        let at = |x: usize| v.rgba.get(4 * ((v.height / 2) * v.width + x)).copied();
        let (near, far) = (at(2), at(v.width - 3));
        assert!(near > far, "the depth view shows near brighter than far: {near:?} {far:?}");
        core.set_depth(id, 0, 0, &[]);
        assert_eq!(px(&core), before, "taking it away restores the blur");
    }

    #[test]
    fn a_lut_imports_as_a_profile_and_previews_without_editing() {
        let core = Core::demo();
        let photos = ok(&core.execute("catalog.query", ""));
        let id = photos["photos"][0]["id"].as_u64().unwrap_or(0);
        ok(&core.execute("library.select", &json!({"ids": [id], "active": id}).to_string()));
        // a 2×2×2 LUT that swaps red and blue
        let mut cube = String::from("TITLE \"Swap\"\nLUT_3D_SIZE 2\n");
        for b in 0..2 {
            for g in 0..2 {
                for r in 0..2 {
                    cube.push_str(&format!("{b} {g} {r}\n"));
                }
            }
        }
        let dir = std::env::temp_dir().join(format!("latent-lut-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let file = dir.join("Swap.cube");
        let _ = std::fs::write(&file, cube);
        let r = ok(&core.execute("profile.import", &json!({"paths": [file.to_string_lossy()]}).to_string()));
        let pid = r["imported"][0]["id"].as_str().unwrap_or_default().to_string();
        assert!(pid.starts_with("lut:"), "{r}");
        let before = ok(&core.execute("develop.get", ""));
        let thumb = core.profile_thumb(id, &pid, 96).map(|i| i.rgba).unwrap_or_default();
        assert_eq!(ok(&core.execute("develop.get", "")), before, "a preview must not edit the photo");
        assert_ne!(thumb, core.thumb(id, 96).map(|i| i.rgba).unwrap_or_default(), "the preview shows the LUT");
        assert!(core.profile_thumb(id, "lut:nope", 96).is_err());
        ok(&core.execute("develop.profile", &json!({"id": pid, "amount": 100}).to_string()));
    }

    #[test]
    fn a_selection_from_the_app_becomes_an_object_mask() {
        let core = Core::demo();
        let photos = ok(&core.execute("catalog.query", ""));
        let id = photos["photos"][0]["id"].as_u64().unwrap_or(0);
        ok(&core.execute("library.select", &json!({"ids": [id], "active": id}).to_string()));
        let side = 32;
        // the left half selected
        let probs: Vec<u8> = (0..side * side).map(|i| if i % side < side / 2 { 255 } else { 0 }).collect();
        let m = core.object_from_coverage(None, "add", side, &probs, (0.25, 0.5));
        let Ok(m) = m else { panic!("{:?}", m.err()) };
        let d = ok(&core.execute("develop.get", ""));
        let mask = d["masks"].as_array().and_then(|ms| ms.iter().find(|x| x["id"].as_u64() == Some(u64::from(m)))).cloned().unwrap_or_default();
        assert_eq!(mask["components"][0]["shape"]["kind"], "object", "{mask}");
        let view = core.render_mask_as(id, 64, 64, m, MaskLook { view: "whiteOnBlack", color: [255, 255, 255], opacity: 100 });
        let Ok(v) = view else { panic!("{:?}", view.err()) };
        let at = |x: usize| v.rgba.get(4 * ((v.height / 2) * v.width + x)).copied().unwrap_or(0);
        assert!(at(4) > 200 && at(v.width - 5) < 50, "{} {}", at(4), at(v.width - 5));
        // the same grid as a stored segmentation, for a shape the app writes itself
        let seg = Core::seg_from_coverage(side, &probs).map(|j| serde_json::from_str::<serde_json::Value>(&j).unwrap_or_default());
        assert!(seg.as_ref().is_ok_and(|v| v["side"] == 32 && v["data"].as_str().is_some_and(|d| !d.is_empty())), "{seg:?}");
        assert!(Core::seg_from_coverage(0, &[]).is_err());
        // and as a part taken away from it
        assert!(core.object_from_coverage(Some(m), "subtract", side, &probs, (0.25, 0.5)).is_ok());
        assert!(core.object_from_coverage(None, "add", side, &probs[..10], (0.5, 0.5)).is_err());
    }

    #[test]
    fn a_new_library_starts_without_sample_photos() {
        let dir = std::env::temp_dir().join(format!("latent-empty-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let (core, problem) = Core::open(Some(&dir));
        assert!(problem.is_none(), "{problem:?}");
        let photos = ok(&core.execute("catalog.query", ""));
        assert_eq!(photos["photos"].as_array().map_or(0, Vec::len), 0, "{photos}");
        drop(core);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The app's model sees every part of the picture once per tile and only its change comes back: a model that
    /// changes nothing leaves the picture as it was, one that flattens each tile to grey makes the whole picture
    /// one colour, tiles cover pictures of odd sizes, and a model that fails stops it.
    #[test]
    fn denoise_tiles_take_back_only_the_models_change() {
        let mut src = lightcraft_raster::Rgb32f::filled(301, 157, [0.0; 3]);
        for (i, p) in src.data.iter_mut().enumerate() {
            *p = [(i % 7) as f32 * 0.05, 0.1 + (i % 3) as f32 * 0.02, 0.3];
        }
        let mut calls = 0;
        let mut last = (0, 0);
        let same = denoise_tiles(
            &src,
            96,
            &mut |i, o| {
                calls += 1;
                o.copy_from_slice(i);
                true
            },
            &mut |d, t| last = (d, t),
        )
        .unwrap();
        assert!(same.data.iter().zip(&src.data).all(|(a, b)| (0..3).all(|c| (a[c] - b[c]).abs() < 1e-4)));
        assert_eq!(last.0, last.1);
        assert_eq!(calls, last.1);
        let flat = denoise_tiles(
            &src,
            96,
            &mut |_, o| {
                o.fill(0.5);
                true
            },
            &mut |_, _| {},
        )
        .unwrap();
        let first = flat.data[0];
        assert!(flat.data.iter().all(|p| (0..3).all(|c| (p[c] - first[c]).abs() < 1e-4)), "one colour");
        assert!(denoise_tiles(&src, 96, &mut |_, _| false, &mut |_, _| {}).is_err());
    }

    /// A photo denoised with the app's model renders differently once Denoise is up, keeps that after saving
    /// and loading the picture again, and a damaged file is refused.
    #[test]
    fn a_denoised_photo_renders_and_saves() {
        let core = Core::demo();
        let photos = ok(&core.execute("catalog.query", ""));
        let id = photos["photos"][0]["id"].as_u64().unwrap();
        ok(&core.execute("library.select", &json!({"ids": [id], "active": id}).to_string()));
        let plain = core.render(id, 64, 64).unwrap().rgba;
        core.denoise(
            id,
            128,
            &mut |_, o| {
                o.fill(0.4);
                true
            },
            &mut |_, _| {},
        )
        .unwrap();
        assert!(core.has_denoised(id));
        assert_eq!(core.render(id, 64, 64).unwrap().rgba, plain, "Denoise at 0 changes nothing");
        ok(&core.execute("develop.set", r#"{"control":"enhance.denoise","value":100}"#));
        let cleaned = core.render(id, 64, 64).unwrap().rgba;
        assert_ne!(cleaned, plain);
        let dir = std::env::temp_dir().join(format!("latent-denoise-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("d.bin");
        assert!(core.save_denoised(id, &file).unwrap());
        core.forget_denoised(id);
        assert_eq!(core.render(id, 64, 64).unwrap().rgba, plain);
        assert!(core.load_denoised(id, &file));
        assert_ne!(core.render(id, 64, 64).unwrap().rgba, plain);
        let mut bytes = std::fs::read(&file).unwrap();
        bytes.truncate(bytes.len() - 3);
        std::fs::write(&file, &bytes).unwrap();
        assert!(!core.load_denoised(id, &file));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn resampling_keeps_the_total() {
        let src: Vec<u32> = (0..1000).collect();
        let out = resample(&src, 256);
        assert_eq!(out.iter().map(|&v| u64::from(v)).sum::<u64>(), src.iter().map(|&v| u64::from(v)).sum::<u64>());
    }
}
