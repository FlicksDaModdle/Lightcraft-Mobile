//! A minimal logger: records go to standard error (Xcode and Console.app show it for an app on a
//! device) and, on iOS, to `Documents/lightcraft.log`, which the Files app shows under "On My
//! iPhone" so it can be read or sent without a Mac.

use std::io::Write;
use std::sync::{Mutex, OnceLock};

static FILE: OnceLock<Mutex<std::fs::File>> = OnceLock::new();

/// Where the log file goes: the app's Documents folder on iOS; nowhere on a desktop run.
pub(crate) fn file_path(name: &str) -> Option<std::path::PathBuf> {
    if !cfg!(target_os = "ios") {
        return None;
    }
    std::env::var_os("HOME").filter(|h| !h.is_empty()).map(|h| std::path::PathBuf::from(h).join("Documents").join(name))
}

struct Logger;

impl log::Log for Logger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::Level::Info
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let line = format!("{secs} [{} {}] {}", record.level(), record.target(), record.args());
        eprintln!("{line}");
        if let Some(Ok(mut f)) = FILE.get().map(Mutex::lock) {
            let _ = writeln!(f, "{line}");
        }
    }

    fn flush(&self) {
        if let Some(Ok(mut f)) = FILE.get().map(Mutex::lock) {
            let _ = f.flush();
        }
    }
}

pub(crate) fn install() {
    if let Some(path) = file_path("lightcraft.log") {
        // start a fresh file when the old one has grown large
        if std::fs::metadata(&path).is_ok_and(|m| m.len() > (1 << 20)) {
            let _ = std::fs::remove_file(&path);
        }
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
            let _ = FILE.set(Mutex::new(f));
        }
    }
    if log::set_logger(&Logger).is_ok() {
        log::set_max_level(log::LevelFilter::Info);
    }
}
