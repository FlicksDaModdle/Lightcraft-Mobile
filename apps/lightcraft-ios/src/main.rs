//! LightCraft for iPhone and iPad.
//!
//! The same engine as the desktop app (decode, develop pipeline, GPU rendering, catalog, commands)
//! with its own host: this crate starts the window, keeps the library and settings, and gives the UI
//! what the device provides. On iOS the window is the whole screen; on a desktop the app opens in a
//! phone-sized window so it can be developed and tested without a device (`--memory` keeps the
//! session in memory, writing nothing).
//!
//! Status and plan: docs/ios/PLAN.md.
#![forbid(unsafe_code)]
#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

mod host;
mod logging;
mod memory;
mod store;

use lightcraft_ui_egui::LightcraftApp;

/// Logical size of the window on a desktop (an iPhone 15 Pro); iOS ignores it.
const PHONE_SIZE: [f32; 2] = [393.0, 852.0];

/// How long closing waits for renders that are running. A GPU render takes well under a second.
const EXIT_WAIT: std::time::Duration = std::time::Duration::from_secs(2);

struct App {
    app: LightcraftApp,
    prefs: store::PrefsWriter,
}

impl eframe::App for App {
    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        egui::Color32::from_rgb(12, 12, 12).to_normalized_gamma_f32()
    }

    fn logic(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.app.logic(ctx);
        self.prefs.tick(&mut self.app);
    }

    /// Keeps modal and prompt input barriers, and queued synthetic input, ahead of the panels.
    fn raw_input_hook(&mut self, ctx: &egui::Context, raw: &mut egui::RawInput) {
        self.app.raw_input_hook(ctx, raw);
    }

    fn ui(&mut self, ui: &mut egui::Ui, frame: &mut eframe::Frame) {
        self.app.perf.host_frame_ms = frame.info().cpu_usage.map(|s| f64::from(s) * 1000.0);
        self.app.ui(ui);
    }
}

impl Drop for App {
    /// Reached when the app is closed normally (a desktop run, or iOS letting the process end). A
    /// kill gets no such chance, which is why the state is also saved while the app runs.
    fn drop(&mut self) {
        if let Err(e) = self.prefs.save(&self.app) {
            log::error!("{e}");
        }
        if let Err(e) = self.app.session.close_library() {
            log::error!("saving the library failed: {e}");
        }
        if !self.app.shutdown(EXIT_WAIT) {
            log::warn!("quit: background work was still running after {EXIT_WAIT:?}");
        }
    }
}

fn main() -> eframe::Result {
    logging::install();
    lightcraft_engine::guard::install_hook(std::env::temp_dir().join("lightcraft-panics.log"));
    memory::configure();

    let in_memory = std::env::args().skip(1).any(|a| a == "--memory");
    let path = if in_memory { None } else { store::prefs_path() };
    let loaded = store::load(path.as_deref());
    if let Some(ui) = &loaded.ui {
        lightcraft_ui_egui::i18n::set_language(ui.language);
    }
    lightcraft_engine::gpu::set_enabled(loaded.ui.as_ref().is_none_or(|u| u.settings.gpu));

    let options = eframe::NativeOptions {
        renderer: eframe::Renderer::Wgpu,
        viewport: egui::ViewportBuilder::default().with_title("LightCraft").with_inner_size(PHONE_SIZE),
        ..Default::default()
    };
    eframe::run_native(
        "LightCraft",
        options,
        Box::new(move |_cc| {
            let (session, problem) = host::open_session(in_memory);
            let mut app = LightcraftApp::new(session, host::services());
            if let Some(ui) = loaded.ui {
                app.ui = ui;
            }
            lightcraft_ui_egui::i18n::set_language(app.ui.language);
            app.notices.extend(loaded.warning);
            app.library_problem = problem;
            let prefs = store::PrefsWriter {
                path,
                written: serde_json::to_vec_pretty(&app.ui).unwrap_or_default(),
                library: app.ui.settings.library_path.clone(),
                keep_file: loaded.keep_file,
                ..Default::default()
            };
            Ok(Box::new(App { app, prefs }))
        }),
    )
}
