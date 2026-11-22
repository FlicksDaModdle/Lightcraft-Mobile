//! The app's settings and UI state, kept as `<config>/ui.json`.
//!
//! iOS can end a backgrounded app without letting it quit, so there is no "save on exit" to rely
//! on: the state is written whenever it changes, at most every few seconds ([`PrefsWriter::tick`]).
//! The library itself is a journal that survives a kill (a torn last record is repaired on open).

use lightcraft_ui_egui::panels::library_problem::LibraryProblem;
use lightcraft_ui_egui::{LightcraftApp, UiState};

/// `<config>/ui.json`; `None` when nothing is read or written (`LIGHTCRAFT_NO_PREFS`, no home).
pub(crate) fn prefs_path() -> Option<std::path::PathBuf> {
    if std::env::var_os("LIGHTCRAFT_NO_PREFS").is_some() {
        return None;
    }
    lightcraft_engine::config::config_dir().map(|d| d.join("ui.json"))
}

/// What loading the saved state gave.
#[derive(Default)]
pub(crate) struct Loaded {
    pub(crate) ui: Option<UiState>,
    /// For the user: the file exists but could not be used.
    pub(crate) warning: Option<String>,
    /// The file could not be read: never write over it this session.
    pub(crate) keep_file: bool,
}

pub(crate) fn load(path: Option<&std::path::Path>) -> Loaded {
    let Some(path) = path else { return Loaded::default() };
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Loaded::default(),
        Err(e) => {
            let warning = format!("The app settings ({}) couldn't be read: {e}. Defaults are used, and the file isn't overwritten.", path.display());
            return Loaded { ui: None, warning: Some(warning), keep_file: true };
        }
    };
    match decode(&bytes) {
        Ok(ui) => Loaded { ui: Some(ui.sanitized()), ..Loaded::default() },
        Err(e) => {
            // keep the damaged file aside, so the next save can't lose what is in it
            let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
            let aside = path.with_file_name(format!("ui.json.corrupt-{secs}"));
            let kept = std::fs::rename(path, &aside);
            let what = match &kept {
                Ok(()) => format!("it was kept as {}", aside.display()),
                Err(r) => format!("it couldn't be set aside ({r})"),
            };
            Loaded { ui: None, warning: Some(format!("The app settings are damaged ({e}); {what}. Defaults are used.")), keep_file: kept.is_err() }
        }
    }
}

/// The same migration the desktop app applies to a saved state (an older panel layout or a file from
/// before the start-up dialog existed).
fn decode(bytes: &[u8]) -> Result<UiState, String> {
    let mut saved: serde_json::Value = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
    let fields = saved.as_object_mut().ok_or("settings must be an object")?;
    lightcraft_ui_egui::docking::drop_outdated(fields);
    let unusable =
        fields.get("docking").is_some_and(|value| match serde_json::from_value::<Option<lightcraft_ui_egui::docking::Workspace>>(value.clone()) {
            Ok(Some(workspace)) => lightcraft_ui_egui::docking::validate(&workspace).is_err(),
            Ok(None) => false,
            Err(_) => true,
        });
    if unusable {
        fields.remove("docking");
    }
    lightcraft_ui_egui::startup::migrate_legacy_seen_version(fields);
    serde_json::from_value(saved).map_err(|e| e.to_string())
}

/// Write `bytes` to `path` atomically: a temp file, synced, renamed over it. A kill or a full disk
/// leaves the old file or the new one, never a truncated one.
pub(crate) fn write_atomic(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let tmp = path.with_extension("json.tmp");
    let written = (|| {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()
    })();
    if let Err(e) = written {
        let _ = std::fs::remove_file(&tmp);
        return Err(e);
    }
    std::fs::rename(&tmp, path)
}

/// Saves `ui.json` when the state changed: at once when the library to open changed, otherwise at
/// most every three seconds.
#[derive(Default)]
pub(crate) struct PrefsWriter {
    pub(crate) path: Option<std::path::PathBuf>,
    pub(crate) written: Vec<u8>,
    pub(crate) library: String,
    pub(crate) checked: f64,
    pub(crate) failing: bool,
    pub(crate) keep_file: bool,
}

impl PrefsWriter {
    pub(crate) fn save(&mut self, app: &LightcraftApp) -> Result<(), String> {
        let temporary = app.library_problem.as_ref().is_some_and(LibraryProblem::saves_nothing);
        if self.keep_file || temporary {
            return Ok(());
        }
        let Some(path) = self.path.clone() else { return Ok(()) };
        if let Some(workspace) = &app.ui.docking {
            lightcraft_ui_egui::docking::validate(workspace)?;
        }
        let bytes = serde_json::to_vec_pretty(&app.ui).map_err(|e| e.to_string())?;
        if bytes == self.written {
            return Ok(());
        }
        path.parent()
            .map_or(Ok(()), std::fs::create_dir_all)
            .and_then(|()| write_atomic(&path, &bytes))
            .map_err(|e| format!("saving the app settings failed: {e}"))?;
        self.written = bytes;
        self.library = app.ui.settings.library_path.clone();
        Ok(())
    }

    /// Called every frame: saves when due, and reports a failed save once.
    pub(crate) fn tick(&mut self, app: &mut LightcraftApp) {
        let now = app.tick_now();
        let moved = app.ui.settings.library_path != self.library;
        if !moved && now - self.checked < 3.0 {
            return;
        }
        self.checked = now;
        match self.save(app) {
            Ok(()) => self.failing = false,
            Err(e) => {
                if !self.failing {
                    log::warn!("{e}");
                    app.notices.push(format!("{e}. LightCraft keeps trying."));
                }
                self.failing = true;
                self.library = app.ui.settings.library_path.clone();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("lightcraft-ios-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::create_dir_all(&dir);
        dir.join("ui.json")
    }

    #[test]
    fn a_missing_file_is_not_a_problem() {
        let loaded = load(Some(&temp("missing")));
        assert!(loaded.ui.is_none() && loaded.warning.is_none() && !loaded.keep_file);
    }

    #[test]
    fn a_damaged_file_is_set_aside_with_a_warning() {
        let path = temp("damaged");
        assert!(std::fs::write(&path, b"{ not json").is_ok());
        let loaded = load(Some(&path));
        assert!(loaded.ui.is_none() && loaded.warning.is_some());
        assert!(!path.exists(), "the damaged file must not stay where the next save would overwrite it");
    }

    #[test]
    fn a_saved_state_loads_again() {
        let path = temp("roundtrip");
        let bytes = serde_json::to_vec(&UiState::default()).unwrap_or_default();
        assert!(write_atomic(&path, &bytes).is_ok());
        assert!(load(Some(&path)).ui.is_some());
    }
}
