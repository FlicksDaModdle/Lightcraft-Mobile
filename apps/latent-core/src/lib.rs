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
        (Core { session: Mutex::new(session) }, problem)
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

    /// A small square-ish thumbnail with the photo's edits.
    pub fn thumb(&self, id: u64, long_edge: usize) -> Result<Image, String> {
        let job = self.lock().thumb_job(PhotoId(id), long_edge.max(16)).ok_or("no thumbnail for this photo")?;
        self.finish(job.run())
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
    fn resampling_keeps_the_total() {
        let src: Vec<u32> = (0..1000).collect();
        let out = resample(&src, 256);
        assert_eq!(out.iter().map(|&v| u64::from(v)).sum::<u64>(), src.iter().map(|&v| u64::from(v)).sum::<u64>());
    }
}
