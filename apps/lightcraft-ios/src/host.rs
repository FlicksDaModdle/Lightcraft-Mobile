//! What the app gives the UI that depends on the device: file writing, PNG encoding, and the
//! library session. Pickers for photos and files come with the Photos integration (see
//! docs/ios/PLAN.md, phase 1); until then the UI works on the library's own photos.

use lightcraft_engine::Session;
use lightcraft_ui_egui::Services;
use lightcraft_ui_egui::panels::library_problem::LibraryProblem;

pub(crate) fn services() -> Services {
    Services {
        // atomic (temp file, sync, rename): a failed write never leaves a truncated file
        write_shared: Some(std::sync::Arc::new(lightcraft_engine::export::write_file)),
        write: Some(Box::new(lightcraft_engine::export::write_file)),
        write_new: Some(Box::new(lightcraft_engine::export::write_file_new)),
        png: Some(Box::new(|img: &lightcraft_raster::Rgba8| {
            lightcraft_codecs::encode_png(&lightcraft_codecs::EncodeImage::rgba8(img), &lightcraft_codecs::EncodeMeta::default()).unwrap_or_default()
        })),
        ..Services::default()
    }
}

fn bare_session() -> Session {
    Session::new().with_fs().with_default_denoise_models().with_system_clock()
}

/// The library session: the library in the app's Documents folder (shown in the Files app), made
/// with the demo photos the first time. When it can't be opened the session is empty and in memory,
/// and the problem is returned for the window to explain; nothing is replaced silently.
pub(crate) fn open_session(in_memory: bool) -> (Session, Option<LibraryProblem>) {
    let (mut session, problem) = if in_memory {
        (Session::with_demo().with_fs().with_default_denoise_models().with_system_clock(), None)
    } else {
        match lightcraft_engine::library::default_dir() {
            None => (bare_session(), Some(LibraryProblem::new("", "There is no folder to keep the library in."))),
            Some(dir) => {
                let first_run = !dir.exists();
                let mut session = bare_session();
                match session.open_library(&dir, first_run) {
                    Ok(report) => {
                        log::info!("library {}: {} log records replayed", dir.display(), report.replayed);
                        (session, None)
                    }
                    Err(e) => {
                        log::error!("can't open library {}: {e}", dir.display());
                        (bare_session(), Some(LibraryProblem::new(dir.to_string_lossy(), e.to_string())))
                    }
                }
            }
        }
    };
    if !in_memory {
        session = session.with_default_lens_database().with_lens_auto_download();
    }
    session.face_models_dir = lightcraft_engine::config::default_face_models_dir();
    session.slide_templates_dir = lightcraft_engine::config::config_dir().map(|d| d.join(lightcraft_engine::slide_template::DIR_NAME));
    (session, problem)
}
