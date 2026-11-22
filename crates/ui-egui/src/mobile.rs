//! The phone layout: a photo grid, a full-screen photo with a bottom tool strip, and large touch
//! sliders. It replaces the desktop window's docked panels (top bar, tool strip, panels) when the
//! host sets [`LightcraftApp::mobile`]; everything it changes goes through the same engine commands
//! as the desktop panels (`develop.set`, `library.select`, `edit.undo`, ...), and the photo itself is
//! drawn by the desktop loupe ([`crate::panels::detail::show`]).
//!
//! Screens: the library (thumbnails, tap to open) and the photo (canvas, tools). The tools open a
//! sheet of sliders above the strip, one sheet per group of the engine's control specs
//! (`lightcraft_develop::controls`), so every slider the engine has for the group is there.

use egui::{Align2, Color32, Rect, Sense, Stroke, UiBuilder, pos2, vec2};
use lightcraft_develop::{ControlSpec, Section, controls};
use serde_json::json;

use crate::LightcraftApp;
use crate::state::RightPanel;
use crate::theme::Tokens;
use crate::widgets::SliderOut;

/// Header bar of both screens (below the status bar).
const HEADER_H: f32 = 52.0;
/// The tool strip along the bottom of the photo screen.
const STRIP_H: f32 = 64.0;
/// The rating row above the tool strip.
const RATE_H: f32 = 48.0;
/// The histogram above the photo.
const HIST_H: f32 = 104.0;
/// The slider rows' height: a finger-sized track under its label.
const ROW_H: f32 = 70.0;
/// Gap between thumbnails.
const GAP: f32 = 1.5;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Screen {
    Library,
    Photo,
}

/// A group of sliders in the bottom sheet.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Tool {
    /// The wand's row of one-tap actions (no sheet).
    Assist,
    Presets,
    Crop,
    Light,
    Color,
    Mixer,
    Curve,
    Grading,
    Effects,
    Detail,
    Optics,
    Geometry,
}

impl Tool {
    const ALL: [Tool; 11] = [
        Tool::Presets,
        Tool::Crop,
        Tool::Light,
        Tool::Color,
        Tool::Mixer,
        Tool::Curve,
        Tool::Grading,
        Tool::Effects,
        Tool::Detail,
        Tool::Optics,
        Tool::Geometry,
    ];

    fn label(self) -> &'static str {
        match self {
            Tool::Assist => "Assist",
            Tool::Presets => "Presets",
            Tool::Crop => "Crop",
            Tool::Light => "Light",
            Tool::Color => "Color",
            Tool::Mixer => "Mixer",
            Tool::Curve => "Curve",
            Tool::Grading => "Grading",
            Tool::Effects => "Effects",
            Tool::Detail => "Detail",
            Tool::Optics => "Optics",
            Tool::Geometry => "Geometry",
        }
    }

    /// The tabs across the top of the tool's panel: a name and the control ids (by prefix) it shows.
    fn subtabs(self) -> &'static [(&'static str, &'static [&'static str])] {
        match self {
            Tool::Effects => &[("Effects", &["effects."]), ("Vignette", &["vignette."]), ("Grain", &["grain."])],
            Tool::Detail => &[
                ("Sharpening", &["detail.sharpen"]),
                ("Noise", &["detail.nrLuminance", "detail.nrDetail", "detail.nrContrast"]),
                ("Color noise", &["detail.nrColor"]),
            ],
            _ => &[],
        }
    }

    /// The engine's control groups the tool shows, with the heading each gets when there are several.
    fn sections(self) -> &'static [(Section, &'static str)] {
        match self {
            Tool::Assist | Tool::Presets | Tool::Crop => &[],
            Tool::Light => &[(Section::Light, "")],
            Tool::Color => &[(Section::Color, "")],
            Tool::Mixer => &[(Section::Mixer, "")],
            Tool::Curve => &[],
            Tool::Grading => &[(Section::Grading, "")],
            Tool::Effects => &[(Section::Effects, ""), (Section::Vignette, ""), (Section::Grain, "")],
            Tool::Detail => &[(Section::Detail, "")],
            Tool::Optics => &[(Section::Optics, "")],
            Tool::Geometry => &[(Section::Geometry, "")],
        }
    }
}

/// The phone layout's state. A host that wants the phone layout puts one in [`LightcraftApp::mobile`].
#[derive(Debug)]
pub struct Shell {
    screen: Screen,
    tool: Option<Tool>,
    /// Show the status line (touch and modal state) and log state changes: for finding out why a
    /// device does not respond.
    pub debug: bool,
    stats: Stats,
    /// The lens-profile download offer (folder, mirrors), shown as a sheet of the phone's own.
    lens_offer: Option<(String, Vec<String>)>,
    /// Simulated safe-area insets (top, right, bottom, left) for a run on a desktop; `None` uses what
    /// the device reports.
    insets: Option<[f32; 4]>,
    /// Where photos wait to be added (the Files app can fill it); the + button imports from it.
    pub import_dir: Option<std::path::PathBuf>,
    /// Where exported JPEGs are written (visible in the Files app).
    pub export_dir: Option<std::path::PathBuf>,
    /// The pointer press on the photo: where, and when (seconds), for swipe and hold.
    press: Option<(egui::Pos2, f64)>,
    /// Name of the last preset group opened.
    preset_group: Option<String>,
    /// The "more" card (rating, flags, reset) is open.
    menu: bool,
    /// Crop mode: how many undo steps there were on entering (Cancel goes back to it).
    crop_mark: usize,
    /// Curve mode: 0 all channels together, then red, green, blue.
    curve_ch: usize,
    /// The tab open in a tool with tabs (Effects, Detail), and the tool it belongs to.
    subtab: (Option<Tool>, usize),
    /// A tap on the photo hid the bars and panels, so the photo fills the screen.
    hidden: bool,
    /// When a short tap on the photo ended; it hides the bars unless a second tap (a zoom) follows.
    tap_at: Option<f64>,
    /// Color grading: 0 shadows, 1 midtones, 2 highlights, 3 global.
    grade_region: usize,
    /// The white balance list under the Color sheet is open.
    wb_open: bool,
    /// Crop mode: 0 Aspect, 1 Geometry.
    crop_tab: u8,
    /// Crop mode: the open list of ratios, social sizes or more actions.
    crop_popup: Option<CropPopup>,
    /// Crop mode: the name of the last aspect chosen.
    crop_label: String,
    /// The colour band the Mixer sheet shows.
    mixer_band: usize,
    /// The phone's Photos picker, when the host has one.
    pub photo_picker: Option<PhotoPicker>,
    /// Photos the picker has copied in, waiting to be added to the library.
    picked: std::sync::Arc<std::sync::Mutex<Vec<String>>>,
}

/// Shows the Photos picker; its argument is told the copied files' paths when the user is done.
/// Returns false when it could not be shown.
pub struct PhotoPicker(pub Box<dyn FnMut(Box<dyn FnOnce(Vec<String>) + Send>) -> bool>);

impl std::fmt::Debug for PhotoPicker {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PhotoPicker")
    }
}

/// A list open in crop mode.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum CropPopup {
    Ratios,
    Social,
    More,
}

/// What input the shell has seen, for the status line.
#[derive(Debug, Default)]
struct Stats {
    frames: u64,
    touches: u64,
    presses: u64,
    taps: u64,
    last: Option<(egui::Pos2, &'static str)>,
    logged: String,
}

impl Default for Shell {
    fn default() -> Self {
        Shell {
            screen: Screen::Library,
            tool: None,
            debug: true,
            stats: Stats::default(),
            lens_offer: None,
            insets: None,
            import_dir: None,
            export_dir: None,
            press: None,
            preset_group: None,
            menu: false,
            crop_mark: 0,
            curve_ch: 0,
            grade_region: 0,
            hidden: false,
            subtab: (None, 0),
            tap_at: None,
            wb_open: false,
            crop_tab: 0,
            crop_popup: None,
            crop_label: String::new(),
            mixer_band: 0,
            photo_picker: None,
            picked: Default::default(),
        }
    }
}

impl Shell {
    /// For a desktop window or a headless screenshot: an iPhone's status bar and home indicator.
    pub fn preview() -> Self {
        Shell { insets: Some([47.0, 0.0, 34.0, 0.0]), debug: false, ..Shell::default() }
    }

    /// Open the photo screen on the active photo (a script or a test).
    pub fn open_photo(&mut self, tool: Option<&str>) {
        self.screen = Screen::Photo;
        self.tool = tool.and_then(|name| Tool::ALL.into_iter().chain([Tool::Assist]).find(|t| t.label().eq_ignore_ascii_case(name)));
    }
}

fn insets(ctx: &egui::Context, shell: &Shell) -> [f32; 4] {
    if let Some(i) = shell.insets {
        return i;
    }
    // the system gives them in its own points; a zoomed UI has more points across the same screen
    let m = ctx.input(|i| i.safe_area_insets()).0;
    let z = ctx.zoom_factor().max(0.1);
    [m.top / z, m.right / z, m.bottom / z, m.left / z]
}

/// Draw the phone layout over the whole window.
pub(crate) fn show(app: &mut LightcraftApp, ui: &mut egui::Ui) {
    let Some(mut shell) = app.mobile.take() else { return };
    let ctx = ui.ctx().clone();
    let t = Tokens::get(&ctx);
    let full = ui.max_rect();
    ui.painter().rect_filled(full, 0.0, bar(&t));
    // a notice or prompt would block all input behind a dialog sized for a desktop: say it in a toast
    // photos the picker has copied in since the last frame
    let picked = shell.picked.lock().map(|mut q| std::mem::take(&mut *q)).unwrap_or_default();
    if !picked.is_empty() {
        match crate::import::start_paths(app, picked) {
            Ok(_) => app.toast(&ctx, crate::i18n::tr("Adding photos")),
            Err(e) => app.toast(&ctx, e),
        }
    }
    for notice in std::mem::take(&mut app.notices) {
        log::warn!("notice: {notice}");
        app.toast(&ctx, notice);
    }
    // The desktop dialogs are laid out for a window several times wider than a phone: the lens offer
    // gets a sheet of its own here, any other one is closed with a word, never left to trap input.
    match app.ui.dialog.take() {
        Some(crate::state::Dialog::LensDatabase { dir, mirrors }) => shell.lens_offer = Some((dir, mirrors)),
        Some(other) => {
            log::warn!("dialog not shown on the phone: {other:?}");
            app.toast(&ctx, crate::i18n::tr("That isn't available on the phone yet"));
        }
        None => {}
    }
    let [top, right, bottom, left] = insets(&ctx, &shell);
    let safe = Rect::from_min_max(full.min + vec2(left, top), full.max - vec2(right, bottom));
    if shell.screen == Screen::Photo && app.session.active().is_none() {
        shell.screen = Screen::Library;
    }
    match shell.screen {
        Screen::Library => library(app, ui, &t, safe, &mut shell),
        Screen::Photo => photo(app, ui, &t, safe, &mut shell),
    }
    if let Some(offer) = shell.lens_offer.take() {
        shell.lens_offer = lens_sheet(app, &ctx, &t, full, bottom, offer);
    }
    if shell.debug {
        status_line(app, &ctx, &t, full, &mut shell);
    }
    app.mobile = Some(shell);
}

/// The lens-profile offer as a bottom sheet over a dimmed screen. Returns the offer while it stays up.
fn lens_sheet(
    app: &mut LightcraftApp,
    ctx: &egui::Context,
    t: &Tokens,
    full: Rect,
    bottom_inset: f32,
    offer: (String, Vec<String>),
) -> Option<(String, Vec<String>)> {
    let mut keep = Some(offer);
    egui::Area::new(egui::Id::unique("mobile-lens-offer")).order(egui::Order::Foreground).fixed_pos(full.min).show(ctx, |ui| {
        // the dim takes every touch outside the card
        ui.interact(full, ui.scope_id().with("dim"), Sense::click());
        ui.painter().rect_filled(full, 0.0, Color32::from_black_alpha(150));
        let card_h = 230.0 + bottom_inset;
        let card = Rect::from_min_max(pos2(full.left(), full.bottom() - card_h), full.max);
        ui.painter().rect_filled(card, egui::CornerRadius { nw: 16, ne: 16, sw: 0, se: 0 }, panel(t));
        let x = card.left() + 20.0;
        ui.painter().text(pos2(x, card.top() + 30.0), Align2::LEFT_CENTER, crate::i18n::tr("Lens corrections"), t.semibold(18.0), t.text);
        let body = crate::i18n::tr("Download the lens profile database to correct distortion and vignetting for your lenses?");
        let galley = ui.painter().layout(body.to_string(), t.font(15.0), t.text_dim, card.width() - 40.0);
        ui.painter().galley(pos2(x, card.top() + 54.0), galley, t.text_dim);
        let btn_w = (card.width() - 52.0) / 2.0;
        let y = card.top() + 150.0;
        let not_now = Rect::from_min_size(pos2(x, y), vec2(btn_w, 50.0));
        let download = Rect::from_min_size(pos2(not_now.right() + 12.0, y), vec2(btn_w, 50.0));
        ui.painter().rect_filled(not_now, 12.0, t.text_dim.gamma_multiply(0.25));
        ui.painter().text(not_now.center(), Align2::CENTER_CENTER, crate::i18n::tr("Not Now"), t.semibold(16.0), t.text);
        ui.painter().rect_filled(download, 12.0, t.accent);
        ui.painter().text(download.center(), Align2::CENTER_CENTER, crate::i18n::tr("Download"), t.semibold(16.0), Color32::WHITE);
        if tap(ui, "lens-not-now", not_now).clicked() {
            keep = None;
        }
        if tap(ui, "lens-download", download).clicked()
            && let Some((dir, mirrors)) = keep.take()
        {
            match crate::lens_db::download(app, std::path::Path::new(&dir), mirrors) {
                Ok(()) => app.toast(ctx, crate::i18n::tr("Downloading lens profiles")),
                Err(e) => app.toast(ctx, e),
            }
        }
    });
    keep
}

/// A line at the very top: frames drawn, touch events and presses seen, taps that hit a button, and
/// what could be blocking input. It also logs when that state changes.
fn status_line(app: &LightcraftApp, ctx: &egui::Context, t: &Tokens, full: Rect, shell: &mut Shell) {
    let st = &mut shell.stats;
    st.frames += 1;
    ctx.input(|i| {
        for e in &i.events {
            match e {
                egui::Event::Touch { phase, pos, .. } => {
                    st.touches += 1;
                    st.last = Some((
                        *pos,
                        match phase {
                            egui::TouchPhase::Start => "start",
                            egui::TouchPhase::Move => "move",
                            egui::TouchPhase::End => "end",
                            egui::TouchPhase::Cancel => "cancel",
                        },
                    ));
                }
                egui::Event::PointerButton { pressed: true, .. } => st.presses += 1,
                _ => {}
            }
        }
    });
    let modal = (app.ui.dialog.is_some(), app.library_problem.is_some(), crate::panels::notices::blocks_input(app));
    let last = st.last.map_or("-".to_string(), |(p, ph)| format!("{ph} {:.0},{:.0}", p.x, p.y));
    let line = format!(
        "f{} touch{} press{} tap{} last {} | dialog:{} libprob:{} blocked:{} | {}x{} ppp{:.1}",
        st.frames,
        st.touches,
        st.presses,
        st.taps,
        last,
        modal.0,
        modal.1,
        modal.2,
        full.width() as i32,
        full.height() as i32,
        ctx.pixels_per_point()
    );
    let state = format!("dialog:{} libprob:{} blocked:{} first-touch:{}", modal.0, modal.1, modal.2, st.touches > 0);
    if state != st.logged {
        log::info!("ui state: {state}");
        st.logged = state;
    }
    ctx.layer_painter(egui::LayerId::debug()).text(
        full.left_top() + vec2(6.0, 3.0),
        Align2::LEFT_TOP,
        line,
        egui::FontId::monospace(9.0),
        t.text_dim,
    );
}

/// A tappable rectangle that is not a widget of its own.
fn tap(ui: &mut egui::Ui, name: &str, rect: Rect) -> egui::Response {
    let id = ui.scope_id().with(name);
    let resp = ui.interact(rect, id, Sense::click());
    if resp.clicked() {
        log::info!("tap: {name}");
    }
    resp
}

// ---------------------------------------------------------------- library

fn library(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, safe: Rect, shell: &mut Shell) {
    let header = Rect::from_min_size(safe.min, vec2(safe.width(), HEADER_H));
    let (_, ids) = app.session.visible_shared();
    let p = ui.painter();
    p.text(pos2(header.left() + 16.0, header.center().y), Align2::LEFT_CENTER, crate::i18n::tr("All photos"), t.semibold(22.0), t.text);
    let count = if ids.len() == 1 { crate::i18n::tr("1 photo").to_string() } else { crate::i18n::tr_format!("{n} photos", n = ids.len()) };
    // the Add button: a circle with a plus
    let add = Rect::from_center_size(pos2(header.right() - 16.0 - 20.0, header.center().y), vec2(40.0, 40.0));
    p.circle_filled(add.center(), 18.0, t.accent);
    let plus = Stroke::new(2.5, Color32::WHITE);
    p.line_segment([add.center() - vec2(8.0, 0.0), add.center() + vec2(8.0, 0.0)], plus);
    p.line_segment([add.center() - vec2(0.0, 8.0), add.center() + vec2(0.0, 8.0)], plus);
    p.text(pos2(add.left() - 12.0, header.center().y), Align2::RIGHT_CENTER, count, t.font(14.0), t.text_dim);
    if tap(ui, "add", add.expand(6.0)).clicked() {
        add_photos(app, ui.ctx(), shell);
    }
    let body = Rect::from_min_max(pos2(safe.left(), header.bottom()), safe.max);
    ui.scope_builder(UiBuilder::new().max_rect(body), |ui| {
        ui.set_clip_rect(body.intersect(ui.clip_rect()));
        grid(app, ui, t, &ids, shell);
    });
}

/// Add photos: from the phone's picker when the host has one, otherwise from the Import folder
/// (shown in the Files app), which is how photos get in until the Photos picker exists
/// (docs/ios/PLAN.md, phase 1).
fn add_photos(app: &mut LightcraftApp, ctx: &egui::Context, shell: &mut Shell) {
    if let Some(picker) = shell.photo_picker.as_mut() {
        let (inbox, ctx2) = (shell.picked.clone(), ctx.clone());
        let shown = (picker.0)(Box::new(move |paths| {
            if let Ok(mut q) = inbox.lock() {
                q.extend(paths);
            }
            ctx2.request_repaint();
        }));
        if !shown {
            app.toast(ctx, crate::i18n::tr("The photo picker could not be opened"));
        }
        return;
    }
    let mut picked = app.services.pick_files.as_mut().map(|pick| pick()).unwrap_or_default();
    if picked.is_empty()
        && let Some(dir) = &shell.import_dir
    {
        picked = std::fs::read_dir(dir)
            .map(|rd| {
                rd.filter_map(Result::ok)
                    .filter(|e| e.file_type().is_ok_and(|t| t.is_file()) && !e.file_name().to_string_lossy().starts_with('.'))
                    .map(|e| e.path().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        if picked.is_empty() {
            app.toast(ctx, crate::i18n::tr("Put photos in the Import folder (Files > LightCraft > Import), then tap +"));
            return;
        }
        picked.sort();
    }
    if picked.is_empty() {
        app.toast(ctx, crate::i18n::tr("Adding photos from your phone is not available yet"));
        return;
    }
    if let Err(e) = crate::import::start_paths(app, picked) {
        app.toast(ctx, e);
    }
}

fn grid(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, ids: &[lightcraft_catalog::PhotoId], shell: &mut Shell) {
    let width = ui.available_width();
    let cols = ((width / 100.0).floor() as usize).clamp(4, 10);
    let cell = (width - GAP * (cols as f32 - 1.0)) / cols as f32;
    let rows = ids.len().div_ceil(cols);
    let ppp = ui.ctx().pixels_per_point();
    let active = app.session.active();
    ui.spacing_mut().item_spacing = vec2(GAP, GAP);
    egui::ScrollArea::vertical().auto_shrink([false, false]).show_rows(ui, cell, rows, |ui, range| {
        for row in range {
            ui.horizontal(|ui| {
                for &id in ids.iter().skip(row * cols).take(cols) {
                    let (r, resp) = ui.allocate_exact_size(vec2(cell, cell), Sense::click());
                    if ui.is_rect_visible(r) {
                        crate::panels::grid::request_thumb(app, id, (cell * ppp).ceil() as usize, 10);
                    }
                    paint_tile(app, ui, t, id, r, active == Some(id));
                    if resp.clicked() {
                        let _ = app.run("library.select", json!({"ids": [id.0], "mode": "replace"}));
                        let _ = app.run("view.detail", json!({}));
                        shell.screen = Screen::Photo;
                    }
                }
            });
        }
    });
}

/// A square thumbnail, cropped to fill.
fn paint_tile(app: &LightcraftApp, ui: &egui::Ui, t: &Tokens, id: lightcraft_catalog::PhotoId, r: Rect, active: bool) {
    let p = ui.painter();
    match app.renderer.thumb(id) {
        Some(tex) if tex.size[0] > 0 && tex.size[1] > 0 => {
            let aspect = tex.size[0] as f32 / tex.size[1] as f32;
            let (u, v) = if aspect > 1.0 { ((1.0 - 1.0 / aspect) / 2.0, 0.0) } else { (0.0, (1.0 - aspect) / 2.0) };
            p.image(tex.id(), r, Rect::from_min_max(pos2(u, v), pos2(1.0 - u, 1.0 - v)), Color32::WHITE);
        }
        _ => {
            p.rect_filled(r, 0.0, t.skeleton);
        }
    }
    if active {
        p.rect_stroke(r.shrink(1.0), 0.0, Stroke::new(2.0, t.accent), egui::StrokeKind::Inside);
    }
}

// ---------------------------------------------------------------- photo

fn photo(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, safe: Rect, shell: &mut Shell) {
    // turned sideways the phone is for looking: the photo alone, whatever was open
    if shell.hidden || safe.width() > safe.height() {
        // only the photo, edge to edge; a tap brings the bars back
        let full = ui.max_rect();
        app.ui.filmstrip = false;
        app.ui.fullscreen = false;
        app.ui.right = RightPanel::None;
        ui.painter().rect_filled(full, 0.0, Color32::BLACK);
        ui.scope_builder(UiBuilder::new().max_rect(full), |ui| {
            ui.set_clip_rect(full.intersect(ui.clip_rect()));
            crate::panels::detail::show(app, ui);
        });
        gestures(app, ui.ctx(), full, shell);
        return;
    }
    if shell.tool == Some(Tool::Crop) {
        return crop_mode(app, ui, t, safe, shell);
    }
    if shell.tool == Some(Tool::Curve) {
        return curve_mode(app, ui, t, safe, shell);
    }
    if shell.tool == Some(Tool::Grading) {
        return grading_mode(app, ui, t, safe, shell);
    }
    let header = Rect::from_min_size(safe.min, vec2(safe.width(), HEADER_H));
    let main = Rect::from_min_max(pos2(safe.left(), safe.bottom() - STRIP_H), safe.max);
    // the second row (Auto and the edit groups) belongs to Edit; Presets and Crop replace it
    let editing = !matches!(shell.tool, Some(Tool::Presets | Tool::Crop));
    let sub = Rect::from_min_max(pos2(safe.left(), main.top() - if editing { STRIP_H } else { 0.0 }), pos2(safe.right(), main.top()));
    let sheet_h = if shell.tool.is_some_and(|t| t != Tool::Assist) { (safe.height() * 0.4).min(360.0) } else { 0.0 };
    let sheet = Rect::from_min_max(pos2(safe.left(), sub.top() - sheet_h), pos2(safe.right(), sub.top()));
    // the histogram shows while no sheet covers the photo
    let hist_h = if safe.height() > 640.0 || sheet_h == 0.0 { HIST_H } else { 0.0 };
    let hist = Rect::from_min_size(pos2(safe.left(), header.bottom()), vec2(safe.width(), hist_h));
    let canvas = Rect::from_min_max(pos2(safe.left(), hist.bottom()), pos2(safe.right(), sheet.top()));

    // the loupe draws the photo; the desktop's own side panels, filmstrip and full screen stay off
    app.ui.filmstrip = false;
    app.ui.fullscreen = false;
    app.ui.right = RightPanel::None;
    ui.painter().rect_filled(Rect::from_min_max(hist.min, canvas.max), 0.0, Color32::BLACK);
    if hist_h > 0.0 {
        histogram(app, ui, t, hist);
    }
    ui.scope_builder(UiBuilder::new().max_rect(canvas), |ui| {
        ui.set_clip_rect(canvas.intersect(ui.clip_rect()));
        crate::panels::detail::show(app, ui);
    });

    gestures(app, ui.ctx(), canvas, shell);
    header_bar(app, ui, t, header, shell);
    if let Some(tool) = shell.tool.filter(|t| *t != Tool::Assist) {
        ui.painter().rect_filled(sheet, 0.0, panel(t));
        ui.scope_builder(UiBuilder::new().max_rect(sheet), |ui| {
            ui.set_clip_rect(sheet.intersect(ui.clip_rect()));
            sheet_of(app, ui, t, tool, shell);
        });
    }
    if editing {
        ui.painter().rect_filled(sub, 0.0, bar(t));
        ui.painter().line_segment([sub.left_top(), sub.right_top()], Stroke::new(1.0, t.text_dim.gamma_multiply(0.2)));
        ui.scope_builder(UiBuilder::new().max_rect(sub), |ui| edit_row(app, ui, t, sub, shell));
    }
    ui.painter().rect_filled(main, 0.0, bar(t));
    ui.painter().line_segment([main.left_top(), main.right_top()], Stroke::new(1.0, t.text_dim.gamma_multiply(0.2)));
    main_row(app, ui, t, main, shell);
    if shell.menu {
        menu_card(app, ui, t, header, shell);
    }
}

/// The histogram of the photo as it is drawn: a grey area for brightness and a line per channel.
fn histogram(app: &LightcraftApp, ui: &egui::Ui, t: &Tokens, r: Rect) {
    let Some(id) = app.session.active() else { return };
    let tex = |slot| app.renderer.textures.get(&slot);
    let Some(h) = tex(crate::render::Slot::Main)
        .filter(|x| x.photo == id)
        .and_then(|x| x.histogram.as_ref())
        .or_else(|| tex(crate::render::Slot::Thumb(id)).and_then(|x| x.histogram.as_ref()))
    else {
        return;
    };
    let n = h.r.len().min(h.g.len()).min(h.b.len()).min(h.luma.len());
    if n < 3 {
        return;
    }
    let plot = r.shrink2(vec2(20.0, 10.0));
    // scale by the tallest bin that is not an end: clipped pixels pile up there and would flatten the rest
    let peak = |c: &[u32]| c[1..n - 1].iter().copied().max().unwrap_or(1).max(1) as f32;
    let points = |c: &[u32], peak: f32| -> Vec<egui::Pos2> {
        (0..n)
            .map(|i| {
                pos2(plot.left() + plot.width() * i as f32 / (n - 1) as f32, plot.bottom() - plot.height() * (c[i] as f32 / peak).min(1.0).sqrt())
            })
            .collect()
    };
    let luma = points(&h.luma, peak(&h.luma));
    let fill = t.text_dim.gamma_multiply(0.35);
    let mut mesh = egui::Mesh::default();
    for (i, top) in luma.iter().enumerate() {
        mesh.colored_vertex(*top, fill);
        mesh.colored_vertex(pos2(top.x, plot.bottom()), fill);
        if i > 0 {
            let k = i as u32 * 2;
            mesh.add_triangle(k - 2, k - 1, k);
            mesh.add_triangle(k - 1, k + 1, k);
        }
    }
    ui.painter().add(mesh);
    let all = peak(&h.r).max(peak(&h.g)).max(peak(&h.b));
    for (c, color) in [(&h.r, Color32::from_rgb(235, 70, 70)), (&h.g, Color32::from_rgb(80, 200, 90)), (&h.b, Color32::from_rgb(80, 120, 240))] {
        ui.painter().add(egui::Shape::line(points(c, all), Stroke::new(1.4, color)));
    }
    ui.painter()
        .line_segment([pos2(plot.left(), plot.bottom()), pos2(plot.right(), plot.bottom())], Stroke::new(1.0, t.text_dim.gamma_multiply(0.5)));
}

/// The rectangle of the "more" button in the header.
fn more_rect(header: Rect) -> Rect {
    Rect::from_min_size(pos2(header.right() - 52.0, header.top()), vec2(52.0, HEADER_H))
}

fn header_bar(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, header: Rect, shell: &mut Shell) {
    ui.painter().rect_filled(header, 0.0, bar(t));
    let back = Rect::from_min_size(header.min, vec2(52.0, HEADER_H));
    let c = back.center();
    let chevron = Stroke::new(2.5, t.text);
    ui.painter().line_segment([c + vec2(4.0, -9.0), c + vec2(-5.0, 0.0)], chevron);
    ui.painter().line_segment([c + vec2(-5.0, 0.0), c + vec2(4.0, 9.0)], chevron);
    if tap(ui, "back", back).clicked() {
        shell.screen = Screen::Library;
        shell.tool = None;
        shell.menu = false;
        app.ui.view = crate::state::ViewMode::PhotoGrid;
    }
    // right to left: more, export, redo, undo
    let cell = |n: f32| Rect::from_min_size(pos2(header.right() - 52.0 * (n + 1.0), header.top()), vec2(52.0, HEADER_H));
    let more = more_rect(header);
    ui.painter().circle_stroke(more.center(), 11.0, Stroke::new(2.0, t.text));
    for dx in [-5.0, 0.0, 5.0] {
        ui.painter().circle_filled(more.center() + vec2(dx, 0.0), 1.5, t.text);
    }
    if tap(ui, "more", more).clicked() {
        shell.menu = !shell.menu;
    }
    let export = cell(1.0);
    paint_icon(ui.painter(), "Export", export.center(), t.text);
    if tap(ui, "export", export).clicked() {
        export_jpeg(app, ui.ctx(), shell);
    }
    for (name, rect, cmd, flip) in [("redo", cell(2.0), "edit.redo", true), ("undo", cell(3.0), "edit.undo", false)] {
        paint_arrow(ui.painter(), rect.center(), t.text, flip);
        if tap(ui, name, rect).clicked() {
            let _ = app.run(cmd, json!({}));
        }
    }
}

/// The "more" card: rating, flags and Reset.
fn menu_card(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, header: Rect, shell: &mut Shell) {
    let card = Rect::from_min_size(pos2(header.right() - 8.0 - 330.0, header.bottom() + 4.0), vec2(330.0, RATE_H * 2.0 + 8.0));
    ui.painter().rect_filled(card.translate(vec2(0.0, 3.0)), 14.0, Color32::from_black_alpha(80));
    ui.painter().rect_filled(card, 14.0, panel(t));
    ui.painter().rect_stroke(card, 14.0, Stroke::new(1.0, t.text_dim.gamma_multiply(0.3)), egui::StrokeKind::Inside);
    rating_row(app, ui, t, Rect::from_min_size(card.min + vec2(0.0, 4.0), vec2(card.width(), RATE_H)));
    let reset = Rect::from_min_size(card.min + vec2(0.0, 4.0 + RATE_H), vec2(card.width(), RATE_H));
    ui.painter()
        .line_segment([reset.left_top() + vec2(16.0, 0.0), reset.right_top() - vec2(16.0, 0.0)], Stroke::new(1.0, t.text_dim.gamma_multiply(0.25)));
    ui.painter().text(pos2(reset.left() + 20.0, reset.center().y), Align2::LEFT_CENTER, crate::i18n::tr("Reset all edits"), t.font(16.0), t.text);
    if tap(ui, "reset-all", reset).clicked() {
        let _ = app.run("develop.reset", json!({}));
        shell.menu = false;
    }
    // a tap anywhere else closes the card
    let outside = ui.input(|i| i.pointer.any_click().then(|| i.pointer.interact_pos()).flatten());
    if let Some(p) = outside
        && !card.contains(p)
        && !more_rect(header).contains(p)
    {
        shell.menu = false;
    }
}

/// The bottom row of main tools, icons only: Auto-enhance, Presets, Crop, Edit, Masks, Heal.
fn main_row(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, row: Rect, shell: &mut Shell) {
    let items = ["Assist", "Presets", "Crop", "Edit", "Masks", "Heal"];
    let w = row.width() / items.len() as f32;
    let editing = !matches!(shell.tool, Some(Tool::Presets | Tool::Crop));
    for (i, name) in items.into_iter().enumerate() {
        let cell = Rect::from_min_size(pos2(row.left() + i as f32 * w, row.top()), vec2(w, row.height()));
        let on = match name {
            "Assist" => shell.tool == Some(Tool::Assist),
            "Presets" => shell.tool == Some(Tool::Presets),
            "Crop" => shell.tool == Some(Tool::Crop),
            "Edit" => editing && shell.tool != Some(Tool::Assist),
            _ => false,
        };
        let c = cell.center() - vec2(0.0, 4.0);
        if on {
            ui.painter().rect_filled(Rect::from_center_size(c, vec2(54.0, 44.0)), 9.0, t.accent);
        }
        paint_icon(ui.painter(), name, c, if on { Color32::WHITE } else { t.text });
        if tap(ui, &format!("main-{name}"), cell).clicked() {
            match name {
                "Assist" => shell.tool = if on { None } else { Some(Tool::Assist) },
                "Presets" => shell.tool = if on { None } else { Some(Tool::Presets) },
                "Crop" => {
                    shell.tool = Some(Tool::Crop);
                    shell.crop_mark = app.session.undo.len();
                    shell.crop_tab = 0;
                    shell.crop_popup = None;
                    shell.crop_label.clear();
                }
                "Edit" => shell.tool = None,
                _ => app.toast(ui.ctx(), crate::i18n::tr("That isn't available on the phone yet")),
            }
        }
    }
}

/// One of the wand's actions. Those the phone cannot do yet say so rather than appear to work.
fn assist(app: &mut LightcraftApp, ctx: &egui::Context, name: &str) {
    let said = match name {
        "Auto" => match app.run("develop.auto", json!({})) {
            Ok(_) => crate::i18n::tr("Auto settings applied").to_string(),
            Err(e) => e.to_string(),
        },
        "Enhance" => match app.run("denoise.toggle", json!({"enabled": true})) {
            Ok(_) => crate::i18n::tr("Denoise turned on").to_string(),
            Err(e) => e.to_string(),
        },
        "Fix angle" => match app.run("crop.autoStraighten", json!({})) {
            Ok(v) if v["changed"] == false => crate::i18n::tr("No clear horizon or vertical lines found").to_string(),
            Ok(_) => crate::i18n::tr("Straightened").to_string(),
            Err(e) => e.to_string(),
        },
        // selections need masks on the phone (docs/ios/PLAN.md, phase 4)
        _ => crate::i18n::tr("That isn't available on the phone yet").to_string(),
    };
    app.toast(ctx, said);
}

/// The edit row: Auto, then one tab per group of sliders.
fn edit_row(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, strip: Rect, shell: &mut Shell) {
    let edited: Vec<Tool> = match app.session.active().and_then(|id| app.session.develop_of(id)) {
        Some(d) => Tool::ALL.into_iter().filter(|tool| tool_edited(*tool, &d)).collect(),
        None => Vec::new(),
    };
    ui.set_clip_rect(strip.intersect(ui.clip_rect()));
    egui::ScrollArea::horizontal().scroll_bar_visibility(egui::scroll_area::ScrollBarVisibility::AlwaysHidden).auto_shrink([false, false]).show(
        ui,
        |ui| {
            ui.spacing_mut().item_spacing = vec2(0.0, 0.0);
            ui.horizontal(|ui| {
                let item = |ui: &mut egui::Ui, label: &str, on: bool, dot: bool| -> bool {
                    let text = crate::i18n::tr(label);
                    let color = if on { t.text } else { t.text_dim };
                    let galley = ui.painter().layout_no_wrap(text.to_string(), t.font(11.5), color);
                    let (r, resp) = ui.allocate_exact_size(vec2((galley.size().x + 24.0).max(66.0), STRIP_H), Sense::click());
                    if on {
                        ui.painter().rect_filled(r.shrink2(vec2(3.0, 4.0)), 10.0, Color32::from_white_alpha(22));
                    }
                    paint_icon(ui.painter(), label, r.center_top() + vec2(0.0, 22.0), color);
                    if dot {
                        // this tool has changed the photo
                        ui.painter().circle_filled(pos2(r.center().x, r.bottom() - 2.0), 2.2, t.text_dim);
                    }
                    ui.painter().galley(pos2(r.center().x - galley.size().x / 2.0, r.bottom() - galley.size().y - 8.0), galley, color);
                    resp.clicked()
                };
                let divider = |ui: &mut egui::Ui| {
                    let (r, _) = ui.allocate_exact_size(vec2(1.0, STRIP_H), Sense::hover());
                    ui.painter().line_segment(
                        [r.center_top() + vec2(0.0, 14.0), r.center_bottom() - vec2(0.0, 14.0)],
                        Stroke::new(1.0, t.text_dim.gamma_multiply(0.4)),
                    );
                };
                if shell.tool == Some(Tool::Assist) {
                    // one-tap actions, in groups: whole photo, selections, geometry
                    for (i, group) in [&["Auto", "Enhance"][..], &["Subject", "Background", "Sky"], &["Fix angle"]].into_iter().enumerate() {
                        if i > 0 {
                            divider(ui);
                        }
                        for name in group {
                            if item(ui, name, false, false) {
                                assist(app, ui.ctx(), name);
                            }
                        }
                    }
                    return;
                }
                if item(ui, "Auto", false, false) {
                    assist(app, ui.ctx(), "Auto");
                }
                divider(ui);
                for tool in Tool::ALL.into_iter().filter(|t| !matches!(t, Tool::Presets | Tool::Crop | Tool::Curve | Tool::Mixer | Tool::Grading)) {
                    let on = shell.tool == Some(tool) || (tool == Tool::Color && matches!(shell.tool, Some(Tool::Mixer | Tool::Grading)));
                    if item(ui, tool.label(), on, edited.contains(&tool)) {
                        shell.tool = if shell.tool == Some(tool) { None } else { Some(tool) };
                    }
                }
            });
        },
    );
}

/// Whether any control the tool shows (for Color, its Grading and Color mix steps too) is off its default.
fn tool_edited(tool: Tool, d: &lightcraft_develop::DevelopSettings) -> bool {
    let extra: &[Section] = match tool {
        Tool::Color => &[Section::Mixer, Section::Grading],
        Tool::Light => &[Section::Curve],
        _ => &[],
    };
    tool.sections()
        .iter()
        .map(|(s, _)| *s)
        .chain(extra.iter().copied())
        .flat_map(controls::in_section)
        .any(|spec| controls::get(d, spec.id).is_some_and(|v| (v - spec.default).abs() > 1e-9))
}

/// The bars (header, rating row, tool strip): darker than the desktop chrome, so the photo leads.
fn bar(t: &Tokens) -> Color32 {
    t.chrome.lerp_to_gamma(Color32::BLACK, 0.42)
}

/// The sheet that slides over the photo: a step lighter than the bars.
fn panel(t: &Tokens) -> Color32 {
    bar(t)
}

// ---------------------------------------------------------------- sliders

/// The Mixer's colour bands: the engine's control-id name and a swatch.
const BANDS: [(&str, Color32); 8] = [
    ("red", Color32::from_rgb(230, 70, 70)),
    ("orange", Color32::from_rgb(240, 150, 50)),
    ("yellow", Color32::from_rgb(235, 215, 60)),
    ("green", Color32::from_rgb(80, 200, 90)),
    ("aqua", Color32::from_rgb(70, 205, 205)),
    ("blue", Color32::from_rgb(70, 120, 235)),
    ("purple", Color32::from_rgb(150, 90, 220)),
    ("magenta", Color32::from_rgb(225, 80, 180)),
];

/// The sliders of one tool, in a scrolling sheet.
fn sheet_of(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, tool: Tool, shell: &mut Shell) {
    match tool {
        Tool::Presets => return presets_sheet(app, ui, t, shell),
        Tool::Crop => return,
        _ => {}
    }
    let Some(id) = app.session.active() else { return };
    let d = app.session.develop_of(id).unwrap_or_default();
    let specs: Vec<(&'static str, &'static ControlSpec)> = tool
        .sections()
        .iter()
        .flat_map(|(section, heading)| controls::in_section(*section).filter(|s| controls::get(&d, s.id).is_some()).map(move |s| (*heading, s)))
        .filter(|(_, s)| tool != Tool::Mixer || s.id.starts_with(&format!("mixer.{}.", BANDS[shell.mixer_band].0)))
        .collect();
    let tabs = tool.subtabs();
    if shell.subtab.0 != Some(tool) {
        shell.subtab = (Some(tool), 0);
    }
    let tab = shell.subtab.1.min(tabs.len().saturating_sub(1));
    let specs: Vec<(&'static str, &'static ControlSpec)> = match tabs.get(tab) {
        Some((_, prefixes)) => specs.into_iter().filter(|(_, s)| prefixes.iter().any(|p| s.id.starts_with(p))).collect(),
        None => specs,
    };
    let title = Rect::from_min_size(ui.max_rect().min, vec2(ui.max_rect().width(), 48.0));
    if tool == Tool::Mixer {
        // the Color mix is a step inside Color: back goes there
        let c = pos2(title.left() + 22.0, title.center().y);
        let chevron = Stroke::new(2.2, t.text);
        ui.painter().line_segment([c + vec2(4.0, -7.0), c + vec2(-3.0, 0.0)], chevron);
        ui.painter().line_segment([c + vec2(-3.0, 0.0), c + vec2(4.0, 7.0)], chevron);
        ui.painter().text(pos2(title.left() + 38.0, title.center().y), Align2::LEFT_CENTER, crate::i18n::tr("Color mix"), t.semibold(16.0), t.text);
        if tap(ui, "mixer-back", Rect::from_min_size(title.min, vec2(170.0, title.height()))).clicked() {
            shell.tool = Some(Tool::Color);
        }
    }
    if tool == Tool::Light {
        // the point curve has a screen of its own
        let pill = Rect::from_min_size(pos2(title.right() - 16.0 - 116.0, title.top() + 8.0), vec2(116.0, 36.0));
        ui.painter().rect_filled(pill, 8.0, Color32::from_white_alpha(10));
        ui.painter().rect_stroke(pill, 8.0, Stroke::new(1.0, Color32::from_white_alpha(46)), egui::StrokeKind::Inside);
        paint_icon(ui.painter(), "Curve", pill.left_center() + vec2(18.0, 0.0), t.text);
        ui.painter().text(pill.center() + vec2(12.0, 0.0), Align2::CENTER_CENTER, crate::i18n::tr("Curve"), t.font(15.0), t.text);
        if tap(ui, "open-curve", pill).clicked() {
            shell.tool = Some(Tool::Curve);
        }
    }
    // double-tap a slider to reset it; the whole edit resets from the menu
    let mut top = if matches!(tool, Tool::Light | Tool::Mixer) || !tabs.is_empty() { title.bottom() } else { title.top() + 4.0 };
    if !tabs.is_empty() {
        // the tool's own tabs: names across, the open one bright and underlined
        let row = Rect::from_min_size(pos2(title.left(), title.top() + 4.0), vec2(title.width(), 44.0));
        let galleys: Vec<_> =
            tabs.iter().map(|(name, _)| ui.painter().layout_no_wrap(crate::i18n::tr(name).to_string(), t.font(15.0), t.text)).collect();
        let gap = 28.0;
        let total: f32 = galleys.iter().map(|g| g.size().x).sum::<f32>() + gap * (galleys.len() as f32 - 1.0);
        let mut x = row.center().x - total / 2.0;
        for (i, g) in galleys.into_iter().enumerate() {
            let w = g.size().x;
            let on = i == tab;
            let color = if on { t.text } else { t.text_dim };
            let cell = Rect::from_min_size(pos2(x, row.top()), vec2(w, row.height()));
            ui.painter().galley(pos2(x, row.center().y - g.size().y / 2.0 - 2.0), g, color);
            if on {
                ui.painter().line_segment([pos2(x, row.bottom() - 4.0), pos2(x + w, row.bottom() - 4.0)], Stroke::new(2.0, t.text));
            }
            if tap(ui, &format!("subtab-{i}"), cell.expand2(vec2(gap / 2.0, 0.0))).clicked() {
                shell.subtab.1 = i;
            }
            x += w + gap;
        }
        top = row.bottom();
    }
    if tool == Tool::Mixer {
        let row = Rect::from_min_size(pos2(title.left(), top), vec2(title.width(), 48.0));
        let w = row.width() / BANDS.len() as f32;
        for (i, (name, color)) in BANDS.iter().enumerate() {
            let cell = Rect::from_min_size(pos2(row.left() + i as f32 * w, row.top()), vec2(w, 48.0));
            let on = shell.mixer_band == i;
            ui.painter().circle_filled(cell.center(), 11.0, *color);
            if on {
                ui.painter().circle_stroke(cell.center(), 15.0, Stroke::new(2.5, t.text));
            }
            if tap(ui, &format!("band-{name}"), cell).clicked() {
                shell.mixer_band = i;
            }
        }
        top = row.bottom();
    }
    let body = Rect::from_min_max(pos2(title.left(), top), ui.max_rect().max);
    ui.scope_builder(UiBuilder::new().max_rect(body), |ui| {
        ui.set_clip_rect(body.intersect(ui.clip_rect()));
        egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
            ui.spacing_mut().item_spacing = vec2(0.0, 0.0);
            if tool == Tool::Color {
                let bw = d.treatment == lightcraft_develop::settings::Treatment::Bw;
                let mode = serde_json::to_value(d.wb.mode).ok().and_then(|v| v.as_str().map(str::to_owned)).unwrap_or_default();
                color_header(app, ui, t, bw, &mode, shell);
            }
            let mut last = "";
            for (heading, spec) in specs {
                if heading != last && !heading.is_empty() {
                    let (r, _) = ui.allocate_exact_size(vec2(ui.available_width(), 34.0), Sense::hover());
                    ui.painter().text(
                        pos2(r.left() + 16.0, r.center().y + 4.0),
                        Align2::LEFT_CENTER,
                        crate::i18n::tr(heading),
                        t.semibold(13.0),
                        t.text_dim,
                    );
                }
                last = heading;
                // inside a tab the tab names the group, so the slider can say less
                let label = match spec.id {
                    "detail.nrLuminance" => "Luminance",
                    _ => spec.label,
                };
                let spec = &ControlSpec { label, ..*spec };
                let v = controls::get(&d, spec.id).unwrap_or(spec.default);
                let out = touch_slider(ui, t, spec, v);
                crate::panels::edit::apply_slider_out(app, spec, out, |app, v| app.run("develop.set", json!({"control": spec.id, "value": v})));
            }
            ui.add_space(24.0);
        });
    });
}

/// A slider made for a finger: the name and value on a line, a track below. Dragging along the track
/// moves the value from where it is (a touch never makes it jump), a double tap resets it. The
/// name and value are not draggable, so the sheet scrolls under a finger that starts there.
fn touch_slider(ui: &mut egui::Ui, t: &Tokens, spec: &ControlSpec, value: f64) -> SliderOut {
    let (row, _) = ui.allocate_exact_size(vec2(ui.available_width(), ROW_H), Sense::hover());
    let pad = 18.0;
    let track = Rect::from_min_max(pos2(row.left() + pad, row.bottom() - 30.0), pos2(row.right() - pad, row.bottom() - 6.0));
    let id = ui.scope_id().with(("touch-slider", spec.id));
    let label_zone = Rect::from_min_max(row.left_top(), pos2(row.right(), track.top()));
    let mut out = SliderOut::default();

    let resp = ui.interact(track, id, Sense::click_and_drag());
    let reset = ui.interact(label_zone, id.with("label"), Sense::click());
    let pos_key = id.with("pos");
    if resp.drag_started() {
        out.drag_started = true;
        ui.data_mut(|d| d.insert_temp(pos_key, spec.position(value)));
    }
    if resp.dragged() {
        let from: f64 = ui.data(|d| d.get_temp(pos_key)).unwrap_or_else(|| spec.position(value));
        let pos = (from + f64::from(resp.drag_delta().x) / f64::from(track.width().max(1.0))).clamp(0.0, 1.0);
        ui.data_mut(|d| d.insert_temp(pos_key, pos));
        let step = spec.step.max(1e-9);
        let snapped = spec.clamp((spec.value_at(pos) / step).round() * step);
        if (snapped - value).abs() > 1e-12 {
            out.value = Some(snapped);
        }
    }
    if resp.drag_stopped() {
        out.drag_stopped = true;
    }
    if resp.double_clicked() || reset.double_clicked() {
        out.reset = true;
        out.value = Some(spec.default);
    }

    let shown = out.value.unwrap_or(value);
    let changed = (shown - spec.default).abs() > 1e-9;
    let p = ui.painter();
    p.text(pos2(row.left() + pad, row.top() + 20.0), Align2::LEFT_CENTER, crate::i18n::tr(spec.label), t.font(16.0), t.text.gamma_multiply(0.92));
    p.text(
        pos2(row.right() - pad, row.top() + 20.0),
        Align2::RIGHT_CENTER,
        spec.format(shown),
        t.font(16.0),
        if changed { t.text } else { t.text_dim },
    );
    let y = track.center().y;
    let x_of = |v: f64| track.left() + spec.position(v) as f32 * track.width();
    let thumb = pos2(x_of(shown), y);
    let r = if resp.dragged() { 13.0 } else { 11.5 };
    match track_stops(spec) {
        Some(stops) => paint_gradient(p, pos2(track.left(), y), pos2(track.right(), y), 2.0, &stops),
        None => {
            p.line_segment([pos2(track.left(), y), pos2(track.right(), y)], Stroke::new(2.0, Color32::from_gray(78)));
            // the stretch the value has moved from its default, so a changed slider reads at a glance
            p.line_segment([pos2(x_of(spec.default), y), thumb], Stroke::new(2.0, Color32::from_gray(200)));
        }
    }
    // a ring, open in the middle like the track runs under it
    p.circle_filled(thumb, r + 4.0, panel(t));
    p.circle_stroke(thumb, r, Stroke::new(2.0, Color32::from_gray(if resp.dragged() { 250 } else { 215 })));
    out
}

/// The colours along a slider's track, for the controls that have one (white balance, saturation,
/// the mixer bands, hue); `None` for a plain grey track.
fn track_stops(spec: &ControlSpec) -> Option<Vec<Color32>> {
    use lightcraft_develop::controls::Track;
    let hex = |h: &str| Color32::from_hex(h).unwrap_or(Color32::GRAY);
    let band = |b: u8| BANDS.get(usize::from(b)).map_or(Color32::GRAY, |(_, c)| *c);
    let rainbow = || (0..=12).map(|i| egui::ecolor::Hsva::new(i as f32 / 12.0, 0.85, 0.95, 1.0).into()).collect();
    Some(match spec.track {
        Track::Plain | Track::Centered => return None,
        Track::Temp => vec![Color32::from_rgb(70, 92, 210), Color32::from_gray(140), Color32::from_rgb(214, 196, 70)],
        Track::Tint => vec![Color32::from_rgb(76, 170, 80), Color32::from_gray(140), Color32::from_rgb(196, 76, 196)],
        Track::Gradient { from, to } => vec![hex(from), hex(to)],
        Track::Sat { band: b } => vec![Color32::from_gray(120), band(b)],
        Track::Lum { band: b } => vec![band(b).lerp_to_gamma(Color32::BLACK, 0.65), band(b), band(b).lerp_to_gamma(Color32::WHITE, 0.6)],
        Track::Hue { band: b } => {
            let i = usize::from(b);
            let prev = band(((i + BANDS.len() - 1) % BANDS.len()) as u8);
            let next = band(((i + 1) % BANDS.len()) as u8);
            vec![prev, band(b), next]
        }
        Track::Rainbow => rainbow(),
    })
}

/// A line with colour stops spread evenly along it.
fn paint_gradient(p: &egui::Painter, a: egui::Pos2, b: egui::Pos2, width: f32, stops: &[Color32]) {
    if stops.len() < 2 {
        return;
    }
    let mut mesh = egui::Mesh::default();
    let n = (stops.len() - 1) as f32;
    let h = width / 2.0;
    for (i, c) in stops.iter().enumerate() {
        let x = a.x + (b.x - a.x) * i as f32 / n;
        mesh.colored_vertex(pos2(x, a.y - h), *c);
        mesh.colored_vertex(pos2(x, a.y + h), *c);
        if i > 0 {
            let k = i as u32 * 2;
            mesh.add_triangle(k - 2, k - 1, k);
            mesh.add_triangle(k - 1, k + 1, k);
        }
    }
    p.add(mesh);
    p.circle_filled(a, h, stops[0]);
    p.circle_filled(b, h, stops[stops.len() - 1]);
}

// ---------------------------------------------------------------- photo gestures, rating, export

/// A swipe along the photo moves to the next or previous photo; holding a finger still on it shows
/// the original. Two fingers (a pinch) are the loupe's own.
fn gestures(app: &mut LightcraftApp, ctx: &egui::Context, canvas: Rect, shell: &mut Shell) {
    use crate::state::BeforeAfter;
    let (pressed, released, pos, now, pinching) =
        ctx.input(|i| (i.pointer.any_pressed(), i.pointer.any_released(), i.pointer.interact_pos(), i.time, i.multi_touch().is_some()));
    if pressed
        && let Some(p) = pos
        && canvas.contains(p)
        && shell.lens_offer.is_none()
    {
        // a second tap soon after the first is a double tap (the photo's zoom), not a hide
        if shell.tap_at.is_some_and(|at| now - at < TAP_WAIT) {
            shell.tap_at = None;
            shell.press = None;
            return;
        }
        shell.press = Some((p, now));
    }
    if let Some(at) = shell.tap_at {
        if now - at >= TAP_WAIT {
            shell.tap_at = None;
            shell.hidden = !shell.hidden;
            shell.menu = false;
        } else {
            ctx.request_repaint_after(std::time::Duration::from_secs_f64(TAP_WAIT - (now - at)));
        }
    }
    if pinching {
        shell.press = None;
    }
    if let (Some((from, at)), Some(p)) = (shell.press, pos) {
        let moved = (p - from).length();
        if !released && now - at > HOLD_SECS && moved < 12.0 {
            app.ui.before_after = BeforeAfter::Original;
            ctx.request_repaint();
        }
        if released {
            if app.ui.before_after == BeforeAfter::Original {
                app.ui.before_after = BeforeAfter::Off;
            } else if let Some(cmd) = swipe(p - from, now - at) {
                let _ = app.run(cmd, json!({}));
            } else if moved < 10.0 && now - at < TAP_SECS {
                shell.tap_at = Some(now);
                ctx.request_repaint_after(std::time::Duration::from_secs_f64(TAP_WAIT));
            }
            shell.press = None;
        }
    }
    if released && app.ui.before_after == BeforeAfter::Original && shell.press.is_none() {
        app.ui.before_after = BeforeAfter::Off;
    }
}

/// A press shorter than this, that barely moved, is a tap.
const TAP_SECS: f64 = 0.3;
/// How long a tap waits for a second one before it hides or shows the bars.
const TAP_WAIT: f64 = 0.28;

/// How long a still finger holds before the original shows.
const HOLD_SECS: f64 = 0.45;

/// The command a drag of `d` points over `secs` makes: a quick, mostly sideways flick.
fn swipe(d: egui::Vec2, secs: f64) -> Option<&'static str> {
    (secs < 0.7 && d.x.abs() > 90.0 && d.y.abs() < d.x.abs() * 0.5).then_some(if d.x < 0.0 { "library.next" } else { "library.previous" })
}

/// Stars, pick and reject on the left; Export on the right.
fn rating_row(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, row: Rect) {
    let Some(id) = app.session.active() else { return };
    let Some((rating, flag)) = app.session.catalog.photo(id).map(|p| (p.rating, p.flag)) else { return };
    for n in 1..=5u8 {
        let r = Rect::from_center_size(pos2(row.left() + 24.0 + f32::from(n - 1) * 38.0, row.center().y), vec2(38.0, RATE_H));
        let on = n <= rating;
        paint_star(ui.painter(), r.center(), 10.0, if on { t.accent } else { t.text_dim.gamma_multiply(0.6) }, on);
        if tap(ui, &format!("star{n}"), r).clicked() {
            // tapping the star that is already the rating clears it
            let _ = app.run("photo.rate", json!({"rating": if n == rating { 0 } else { n }}));
        }
    }
    let flags =
        [("pick", crate::i18n::tr("Pick"), lightcraft_catalog::Flag::Pick), ("reject", crate::i18n::tr("Reject"), lightcraft_catalog::Flag::Reject)];
    let mut x = row.left() + 5.0 * 38.0 + 8.0;
    for (name, label, which) in flags {
        let w = 56.0;
        let r = Rect::from_min_size(pos2(x, row.top()), vec2(w, RATE_H));
        let on = flag == which;
        let color = if on { t.accent } else { t.text_dim };
        ui.painter().text(r.center(), Align2::CENTER_CENTER, label, t.font(14.0), color);
        if tap(ui, name, r).clicked() {
            let _ = app.run("photo.flag", json!({"flag": if on { "none" } else { name }}));
        }
        x += w;
    }
}

fn paint_star(p: &egui::Painter, c: egui::Pos2, r: f32, color: Color32, filled: bool) {
    let pts: Vec<egui::Pos2> = (0..10)
        .map(|i| {
            let a = -std::f32::consts::FRAC_PI_2 + i as f32 * std::f32::consts::PI / 5.0;
            let rad = if i % 2 == 0 { r } else { r * 0.42 };
            c + vec2(a.cos(), a.sin()) * rad
        })
        .collect();
    let stroke = Stroke::new(1.5, color);
    p.add(egui::Shape::convex_polygon(pts, if filled { color } else { Color32::TRANSPARENT }, stroke));
}

/// Write the photo as a JPEG into the Exports folder (visible in the Files app), and say where.
fn export_jpeg(app: &mut LightcraftApp, ctx: &egui::Context, shell: &Shell) {
    let (Some(dir), Some(id)) = (&shell.export_dir, app.session.active()) else {
        app.toast(ctx, crate::i18n::tr("Exporting is not available here"));
        return;
    };
    let Some(name) = app.session.catalog.photo(id).map(|p| p.file_name.clone()) else { return };
    let stem = std::path::Path::new(&name).file_stem().map_or_else(|| "photo".to_string(), |s| s.to_string_lossy().into_owned());
    if let Err(e) = std::fs::create_dir_all(dir) {
        app.toast(ctx, e.to_string());
        return;
    }
    let path = dir.join(format!("{stem}-edit.jpg"));
    match app.run("app.export", json!({"path": path.to_string_lossy(), "format": "jpg"})) {
        Ok(_) => app.toast(ctx, crate::i18n::tr_format!("Saved {name} to the Exports folder", name = format!("{stem}-edit.jpg"))),
        Err(e) => app.toast(ctx, e.to_string()),
    }
}

// ---------------------------------------------------------------- presets and crop

/// The presets as rows, a group at a time; tapping one applies it to the photo.
fn presets_sheet(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, shell: &mut Shell) {
    let mut groups: Vec<String> = Vec::new();
    for p in app.session.presets.iter() {
        if !groups.contains(&p.group) {
            groups.push(p.group.clone());
        }
    }
    let current = shell.preset_group.clone().filter(|g| groups.contains(g)).or_else(|| groups.first().cloned());
    let title = Rect::from_min_size(ui.max_rect().min, vec2(ui.max_rect().width(), 44.0));
    ui.scope_builder(UiBuilder::new().max_rect(title), |ui| {
        egui::ScrollArea::horizontal().scroll_bar_visibility(egui::scroll_area::ScrollBarVisibility::AlwaysHidden).show(ui, |ui| {
            ui.horizontal(|ui| {
                for g in &groups {
                    let on = current.as_deref() == Some(g.as_str());
                    let galley = ui.painter().layout_no_wrap(g.clone(), t.font(15.0), if on { t.accent } else { t.text });
                    let (r, resp) = ui.allocate_exact_size(vec2(galley.size().x + 28.0, 44.0), Sense::click());
                    ui.painter().galley(r.center() - galley.size() / 2.0, galley, t.text);
                    if on {
                        ui.painter()
                            .line_segment([r.left_bottom() + vec2(10.0, -3.0), r.right_bottom() + vec2(-10.0, -3.0)], Stroke::new(3.0, t.accent));
                    }
                    if resp.clicked() {
                        shell.preset_group = Some(g.clone());
                    }
                }
            });
        });
    });
    let body = Rect::from_min_max(pos2(ui.max_rect().left(), title.bottom()), ui.max_rect().max);
    let rows: Vec<(String, String)> =
        app.session.presets.iter().filter(|p| Some(&p.group) == current.as_ref()).map(|p| (p.id.clone(), p.name.clone())).collect();
    let mut apply = None;
    ui.scope_builder(UiBuilder::new().max_rect(body), |ui| {
        ui.set_clip_rect(body.intersect(ui.clip_rect()));
        egui::ScrollArea::vertical().auto_shrink([false, false]).show_rows(ui, 48.0, rows.len(), |ui, range| {
            for i in range {
                let (r, resp) = ui.allocate_exact_size(vec2(ui.available_width(), 48.0), Sense::click());
                ui.painter().text(pos2(r.left() + 18.0, r.center().y), Align2::LEFT_CENTER, &rows[i].1, t.font(16.0), t.text);
                ui.painter().line_segment([r.left_bottom() + vec2(18.0, 0.0), r.right_bottom()], Stroke::new(1.0, t.text_dim.gamma_multiply(0.2)));
                if resp.clicked() {
                    apply = Some(rows[i].clone());
                }
            }
        });
    });
    if let Some((id, name)) = apply {
        match app.run("preset.apply", json!({"id": id})) {
            Ok(_) => app.toast(ui.ctx(), crate::i18n::tr_format!("Applied {name}", name = name)),
            Err(e) => app.toast(ui.ctx(), e.to_string()),
        }
    }
}

/// A small line icon for a tool, about 22 pt across, drawn from shapes so it follows the theme.
fn paint_icon(p: &egui::Painter, name: &str, c: egui::Pos2, color: Color32) {
    let st = Stroke::new(1.8, color);
    let line = |a: egui::Vec2, b: egui::Vec2| p.line_segment([c + a, c + b], st);
    match name {
        "Auto" => {
            // a four-point sparkle
            for (a, b) in [
                (vec2(0.0, -11.0), vec2(0.0, 11.0)),
                (vec2(-11.0, 0.0), vec2(11.0, 0.0)),
                (vec2(-5.0, -5.0), vec2(5.0, 5.0)),
                (vec2(-5.0, 5.0), vec2(5.0, -5.0)),
            ] {
                line(a, b);
            }
        }
        "Edit" => {
            for (y, knob) in [(-7.0, -4.0), (0.0, 5.0), (7.0, -1.0)] {
                line(vec2(-11.0, y), vec2(11.0, y));
                p.circle_filled(c + vec2(knob, y), 3.0, color);
            }
        }
        "Presets" => {
            p.circle_stroke(c + vec2(-4.0, 0.0), 8.0, st);
            p.circle_stroke(c + vec2(5.0, 0.0), 8.0, st);
        }
        "Assist" => {
            // a wand with a spark
            line(vec2(-10.0, 10.0), vec2(3.0, -3.0));
            for (a, b) in [(vec2(6.0, -12.0), vec2(6.0, -4.0)), (vec2(2.0, -8.0), vec2(10.0, -8.0))] {
                line(a, b);
            }
            p.circle_filled(c + vec2(-11.0, -3.0), 1.5, color);
        }
        "Masks" => {
            for i in 0..14 {
                let a = i as f32 * std::f32::consts::TAU / 14.0;
                p.circle_filled(c + vec2(a.cos(), a.sin()) * 10.0, 1.5, color);
            }
            p.circle_filled(c, 3.0, color);
        }
        "Heal" => {
            // a bandage
            let a = vec2(-9.0, 9.0);
            let b = vec2(9.0, -9.0);
            p.line_segment([c + a, c + b], Stroke::new(9.0, color.gamma_multiply(0.35)));
            p.line_segment([c + a, c + b], Stroke::new(1.8, color));
            p.circle_filled(c, 1.8, color);
        }
        "Enhance" => {
            for (a, b) in [(vec2(-3.0, -11.0), vec2(-3.0, 1.0)), (vec2(-9.0, -5.0), vec2(3.0, -5.0))] {
                line(a, b);
            }
            line(vec2(-11.0, 10.0), vec2(11.0, 10.0));
            p.add(egui::Shape::line(vec![c + vec2(-9.0, 10.0), c + vec2(-2.0, 4.0), c + vec2(3.0, 8.0), c + vec2(10.0, 2.0)], st));
        }
        "Subject" => {
            p.circle_stroke(c + vec2(0.0, -4.0), 5.0, st);
            p.add(egui::Shape::line(vec![c + vec2(-10.0, 10.0), c + vec2(-8.0, 4.0), c + vec2(8.0, 4.0), c + vec2(10.0, 10.0)], st));
        }
        "Background" => {
            for i in 0..4 {
                let (a, b) = (-11.0 + i as f32 * 6.0, -11.0 + i as f32 * 6.0 + 3.0);
                line(vec2(a, -10.0), vec2(b, -10.0));
                line(vec2(a, 10.0), vec2(b, 10.0));
                line(vec2(-11.0, a), vec2(-11.0, b));
                line(vec2(11.0, a), vec2(11.0, b));
            }
            p.circle_filled(c, 4.0, color);
        }
        "Sky" => {
            p.circle_stroke(c + vec2(-3.0, 1.0), 6.0, st);
            line(vec2(-12.0, 9.0), vec2(12.0, 9.0));
            line(vec2(7.0, -8.0), vec2(10.0, -11.0));
        }
        "Fix angle" => {
            line(vec2(-11.0, 4.0), vec2(11.0, -4.0));
            line(vec2(-11.0, 10.0), vec2(11.0, 10.0));
        }
        "Lock" | "Unlock" => {
            p.rect_filled(Rect::from_center_size(c + vec2(0.0, 4.0), vec2(16.0, 12.0)), 2.0, color);
            let top = c + vec2(0.0, -3.0);
            p.add(egui::Shape::line(
                vec![
                    top + vec2(-5.0, 4.0),
                    top + vec2(-5.0, -2.0),
                    top + vec2(0.0, -6.0),
                    top + vec2(5.0, -2.0),
                    top + vec2(5.0, if name == "Lock" { 4.0 } else { -1.0 }),
                ],
                st,
            ));
        }
        "Rotate" => {
            let pts: Vec<egui::Pos2> = (0..=14)
                .map(|i| {
                    let a = -std::f32::consts::FRAC_PI_2 + i as f32 * std::f32::consts::PI * 1.5 / 14.0;
                    c + vec2(a.cos(), a.sin()) * 9.0
                })
                .collect();
            p.add(egui::Shape::line(pts, st));
            line(vec2(0.0, -9.0), vec2(5.0, -13.0));
            line(vec2(0.0, -9.0), vec2(5.0, -5.0));
        }
        "More" => {
            for dx in [-7.0, 0.0, 7.0] {
                p.circle_filled(c + vec2(dx, 0.0), 2.2, color);
            }
        }
        "Original" => {
            p.rect_stroke(Rect::from_center_size(c, vec2(24.0, 18.0)), 2.0, st, egui::StrokeKind::Middle);
            p.add(egui::Shape::line(
                vec![c + vec2(-10.0, 6.0), c + vec2(-3.0, -1.0), c + vec2(2.0, 4.0), c + vec2(6.0, 0.0), c + vec2(10.0, 5.0)],
                st,
            ));
        }
        "Free" => {
            for i in 0..4 {
                let a = -11.0 + i as f32 * 6.0;
                line(vec2(a, -8.0), vec2(a + 3.0, -8.0));
                line(vec2(a, 8.0), vec2(a + 3.0, 8.0));
            }
            line(vec2(-11.0, -5.0), vec2(-11.0, 5.0));
            line(vec2(11.0, -5.0), vec2(11.0, 5.0));
        }
        "Ratios" => {
            p.rect_stroke(Rect::from_min_size(c + vec2(-11.0, -8.0), vec2(16.0, 12.0)), 2.0, st, egui::StrokeKind::Middle);
            p.rect_stroke(Rect::from_min_size(c + vec2(-5.0, -2.0), vec2(16.0, 12.0)), 2.0, st, egui::StrokeKind::Middle);
        }
        "Social" => {
            // a tall frame and a wide one, the sizes a photo is shared in
            p.rect_stroke(Rect::from_center_size(c + vec2(-5.0, 0.0), vec2(12.0, 20.0)), 3.0, st, egui::StrokeKind::Middle);
            p.rect_stroke(Rect::from_center_size(c + vec2(6.0, 4.0), vec2(14.0, 10.0)), 2.0, st, egui::StrokeKind::Middle);
        }
        "Export" => {
            line(vec2(0.0, -11.0), vec2(0.0, 5.0));
            line(vec2(-5.0, 0.0), vec2(0.0, 5.0));
            line(vec2(5.0, 0.0), vec2(0.0, 5.0));
            line(vec2(-10.0, 10.0), vec2(10.0, 10.0));
        }
        "Crop" => {
            line(vec2(-6.0, -11.0), vec2(-6.0, 6.0));
            line(vec2(-11.0, -6.0), vec2(6.0, -6.0));
            line(vec2(6.0, -6.0), vec2(6.0, 11.0));
            line(vec2(-6.0, 6.0), vec2(11.0, 6.0));
        }
        "Light" => {
            p.circle_stroke(c, 5.0, st);
            for i in 0..8 {
                let a = i as f32 * std::f32::consts::FRAC_PI_4;
                let d = vec2(a.cos(), a.sin());
                p.line_segment([c + d * 8.0, c + d * 11.0], st);
            }
        }
        "Color" => {
            p.circle_stroke(c + vec2(0.0, 1.0), 9.0, st);
            p.circle_filled(c + vec2(0.0, 1.0), 4.5, color);
        }
        "Mixer" => {
            for (i, x) in [-8.0, 0.0, 8.0].into_iter().enumerate() {
                p.circle_stroke(c + vec2(x, if i == 1 { 4.0 } else { -3.0 }), 4.5, st);
            }
        }
        "Curve" => {
            let pts: Vec<egui::Pos2> = (0..=16)
                .map(|i| {
                    let x = i as f32 / 16.0;
                    c + vec2(-11.0 + 22.0 * x, 11.0 - 22.0 * (x * x * (3.0 - 2.0 * x)))
                })
                .collect();
            p.add(egui::Shape::line(pts, st));
        }
        "Grading" => {
            for (x, y) in [(-4.0, 4.0), (4.0, 4.0), (0.0, -4.0)] {
                p.circle_stroke(c + vec2(x, y), 6.5, st);
            }
        }
        "Effects" => {
            // a frame with a vignette inside
            p.rect_stroke(Rect::from_center_size(c, vec2(22.0, 22.0)), 2.0, st, egui::StrokeKind::Middle);
            p.circle_stroke(c, 7.0, st);
        }
        "Detail" => {
            p.add(egui::Shape::convex_polygon(vec![c + vec2(0.0, -10.0), c + vec2(11.0, 9.0), c + vec2(-11.0, 9.0)], Color32::TRANSPARENT, st));
        }
        "Optics" => {
            p.circle_stroke(c, 10.0, st);
            p.circle_stroke(c, 4.0, st);
        }
        "Geometry" => {
            p.rect_stroke(Rect::from_center_size(c, vec2(20.0, 20.0)), 2.0, st, egui::StrokeKind::Middle);
            line(vec2(-10.0, 10.0), vec2(10.0, -10.0));
        }
        _ => {}
    }
}

/// A curved arrow, pointing back (undo) or forward (redo).
fn paint_arrow(p: &egui::Painter, c: egui::Pos2, color: Color32, flip: bool) {
    let sx = if flip { -1.0 } else { 1.0 };
    let st = Stroke::new(2.0, color);
    let pts: Vec<egui::Pos2> = (0..=12)
        .map(|i| {
            let a = -std::f32::consts::FRAC_PI_2 + i as f32 * std::f32::consts::PI * 0.9 / 12.0;
            c + vec2(sx * (a.cos() * 8.0 - 1.0), a.sin() * 6.0 + 1.0)
        })
        .collect();
    p.add(egui::Shape::line(pts, st));
    let tip = c + vec2(sx * -9.0, -5.0);
    p.line_segment([tip, tip + vec2(sx * 6.0, -1.0)], st);
    p.line_segment([tip, tip + vec2(sx * 1.0, 6.0)], st);
}

// ---------------------------------------------------------------- crop mode

/// Ratios in the Ratios list: label, the engine's name for it, and the shape drawn beside it.
const RATIOS: [(&str, &str, f32, f32); 9] = [
    ("1 × 1", "1x1", 1.0, 1.0),
    ("2 × 1", "2x1", 2.0, 1.0),
    ("3 × 2", "3x2", 3.0, 2.0),
    ("4 × 3", "4x3", 4.0, 3.0),
    ("5 × 4", "5x4", 5.0, 4.0),
    ("7 × 5", "7x5", 7.0, 5.0),
    ("11 × 8.5", "11x8.5", 11.0, 8.5),
    ("16 × 9", "16x9", 16.0, 9.0),
    ("16 × 10", "16x10", 16.0, 10.0),
];

/// Sizes for sharing a photo: label and width, height as given (a taller size is portrait).
const SOCIAL: [(&str, f32, f32); 4] = [("Square", 1.0, 1.0), ("Story", 9.0, 16.0), ("Portrait", 4.0, 5.0), ("Landscape", 1.91, 1.0)];

/// The crop editor: the photo with the desktop's crop box, a straighten dial, aspect choices and a
/// Cancel / Done bar. Done keeps the edit (it is already in the photo's history); Cancel undoes back
/// to where crop mode began.
fn crop_mode(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, safe: Rect, shell: &mut Shell) {
    let aspect = app.session.active().and_then(|id| app.session.develop_of(id)).and_then(|d| d.crop.aspect);
    if shell.crop_label.is_empty() {
        shell.crop_label = if aspect.is_some() { "Custom" } else { "Free" }.to_string();
    }
    let top = Rect::from_min_size(safe.min, vec2(safe.width(), HEADER_H));
    let bottom = Rect::from_min_max(pos2(safe.left(), safe.bottom() - 56.0), safe.max);
    let panel_h = if shell.crop_tab == 0 { 48.0 + 84.0 } else { 48.0 + 190.0 };
    let panel = Rect::from_min_max(pos2(safe.left(), bottom.top() - panel_h), pos2(safe.right(), bottom.top()));
    let buttons = Rect::from_min_max(pos2(safe.left(), panel.top() - 72.0), pos2(safe.right(), panel.top()));
    let dial = Rect::from_min_max(pos2(safe.left(), buttons.top() - 60.0), pos2(safe.right(), buttons.top()));
    let canvas = Rect::from_min_max(pos2(safe.left(), top.bottom()), pos2(safe.right(), dial.top()));

    app.ui.filmstrip = false;
    app.ui.fullscreen = false;
    app.ui.right = RightPanel::Crop;
    ui.painter().rect_filled(safe, 0.0, Color32::BLACK);
    ui.scope_builder(UiBuilder::new().max_rect(canvas), |ui| {
        ui.set_clip_rect(canvas.intersect(ui.clip_rect()));
        crate::panels::detail::show(app, ui);
    });

    // top: the aspect's name, and Undo
    ui.painter().text(top.center(), Align2::CENTER_CENTER, crate::i18n::tr(&shell.crop_label), t.font(17.0), t.text);
    let undo = Rect::from_min_size(pos2(top.right() - 60.0, top.top()), vec2(60.0, HEADER_H));
    paint_arrow(ui.painter(), undo.center(), t.text, false);
    if tap(ui, "crop-undo", undo).clicked() {
        let _ = app.run("edit.undo", json!({}));
    }

    angle_dial(app, ui, t, dial);
    crop_buttons(app, ui, t, buttons, aspect.is_some(), shell);

    // tabs and what they hold
    ui.painter().rect_filled(Rect::from_min_max(panel.min, bottom.max), 0.0, bar(t));
    for (i, (label, x)) in [("Aspect", 0.38), ("Geometry", 0.64)].into_iter().enumerate() {
        let c = pos2(panel.left() + panel.width() * x, panel.top() + 24.0);
        let on = shell.crop_tab == i as u8;
        let color = if on { t.text } else { t.text_dim };
        let rect = ui.painter().text(c, Align2::CENTER_CENTER, crate::i18n::tr(label), t.font(17.0), color);
        if on {
            ui.painter().line_segment([rect.left_bottom() + vec2(0.0, 6.0), rect.right_bottom() + vec2(0.0, 6.0)], Stroke::new(2.0, t.text));
        }
        if tap(ui, &format!("crop-tab-{label}"), Rect::from_center_size(c, vec2(120.0, 48.0))).clicked() {
            shell.crop_tab = i as u8;
            shell.crop_popup = None;
        }
    }
    let body = Rect::from_min_max(pos2(panel.left(), panel.top() + 48.0), panel.max);
    if shell.crop_tab == 0 {
        aspect_row(app, ui, t, body, aspect, shell);
    } else {
        ui.scope_builder(UiBuilder::new().max_rect(body), |ui| {
            ui.set_clip_rect(body.intersect(ui.clip_rect()));
            sheet_of(app, ui, t, Tool::Geometry, shell);
        });
    }

    // the bottom bar: Cancel, the mode's name, Done
    ui.painter().line_segment([bottom.left_top(), bottom.right_top()], Stroke::new(1.0, t.text_dim.gamma_multiply(0.2)));
    let (cancel, done) =
        (Rect::from_min_size(bottom.min, vec2(64.0, 56.0)), Rect::from_min_size(pos2(bottom.right() - 64.0, bottom.top()), vec2(64.0, 56.0)));
    ui.painter().text(bottom.center() - vec2(0.0, 0.0), Align2::CENTER_CENTER, crate::i18n::tr("Crop"), t.font(19.0), t.text);
    let x = Stroke::new(2.2, t.text);
    let c = cancel.center();
    ui.painter().line_segment([c + vec2(-8.0, -8.0), c + vec2(8.0, 8.0)], x);
    ui.painter().line_segment([c + vec2(-8.0, 8.0), c + vec2(8.0, -8.0)], x);
    let c = done.center();
    ui.painter().line_segment([c + vec2(-9.0, 0.0), c + vec2(-3.0, 7.0)], x);
    ui.painter().line_segment([c + vec2(-3.0, 7.0), c + vec2(9.0, -8.0)], x);
    if tap(ui, "crop-cancel", cancel).clicked() {
        // back to the history as it was on entering
        for _ in 0..500 {
            if app.session.undo.len() <= shell.crop_mark {
                break;
            }
            if app.run("edit.undo", json!({})).is_err() {
                break;
            }
        }
        shell.tool = None;
        shell.crop_popup = None;
    }
    if tap(ui, "crop-done", done).clicked() {
        shell.tool = None;
        shell.crop_popup = None;
    }

    if let Some(popup) = shell.crop_popup {
        crop_popup(app, ui, t, popup, panel.top() + 48.0, safe, shell);
    }
}

/// A ruler under the photo that turns it: drag sideways to straighten, a degree every few points.
fn angle_dial(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, r: Rect) {
    let (Some(id), Some(spec)) = (app.session.active(), controls::find("crop.angle")) else { return };
    let v = app.session.develop_of(id).and_then(|d| controls::get(&d, spec.id)).unwrap_or(0.0);
    const PX_PER_DEG: f64 = 9.0;
    let resp = ui.interact(r, ui.scope_id().with("angle-dial"), Sense::click_and_drag());
    let mut out = SliderOut::default();
    if resp.drag_started() {
        out.drag_started = true;
    }
    if resp.dragged() {
        let to = (v - f64::from(resp.drag_delta().x) / PX_PER_DEG).clamp(spec.min, spec.max);
        let snapped = spec.clamp((to * 10.0).round() / 10.0);
        if (snapped - v).abs() > 1e-9 {
            out.value = Some(snapped);
        }
    }
    if resp.drag_stopped() {
        out.drag_stopped = true;
    }
    if resp.double_clicked() {
        out.reset = true;
        out.value = Some(spec.default);
    }
    let shown = out.value.unwrap_or(v);
    let cx = r.center().x;
    let p = ui.painter();
    let base = r.top() + 40.0;
    for k in (shown.floor() as i32 - 25)..=(shown.ceil() as i32 + 25) {
        let x = cx + ((f64::from(k) - shown) * PX_PER_DEG) as f32;
        if x < r.left() + 8.0 || x > r.right() - 8.0 {
            continue;
        }
        let fade = (1.0 - ((x - cx).abs() / (r.width() / 2.0)).powi(2)).clamp(0.0, 1.0);
        let major = k % 5 == 0;
        let h = if major { 11.0 } else { 3.0 };
        let color = t.text.gamma_multiply(0.25 + 0.75 * fade);
        if major {
            p.line_segment([pos2(x, base - h), pos2(x, base)], Stroke::new(1.8, color));
        } else {
            p.circle_filled(pos2(x, base - 1.5), 1.2, color);
        }
    }
    p.line_segment([pos2(cx, base - 14.0), pos2(cx, base + 2.0)], Stroke::new(2.0, t.text));
    p.text(pos2(cx, r.top() + 12.0), Align2::CENTER_CENTER, format!("{shown:.1}°"), t.font(14.0), t.text);
    crate::panels::edit::apply_slider_out(app, spec, out, |app, v| app.run("develop.set", json!({"control": spec.id, "value": v})));
}

/// The four round buttons: straighten and lock at the left, rotate and more at the right.
fn crop_buttons(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, row: Rect, locked: bool, shell: &mut Shell) {
    let centers = [
        ("Fix angle", pos2(row.left() + 52.0, row.center().y)),
        (if locked { "Lock" } else { "Unlock" }, pos2(row.left() + 52.0 + 60.0, row.center().y)),
        ("Rotate", pos2(row.right() - 52.0 - 60.0, row.center().y)),
        ("More", pos2(row.right() - 52.0, row.center().y)),
    ];
    for (name, c) in centers {
        ui.painter().circle_filled(c, 24.0, Color32::from_gray(34));
        ui.painter().circle_stroke(c, 24.0, Stroke::new(1.0, t.text_dim.gamma_multiply(0.35)));
        paint_icon(ui.painter(), name, c, t.text);
        if tap(ui, &format!("crop-btn-{name}"), Rect::from_center_size(c, vec2(60.0, 60.0))).clicked() {
            match name {
                "Fix angle" => assist(app, ui.ctx(), "Fix angle"),
                "Lock" | "Unlock" => {
                    let _ = app.run("crop.aspect", json!({"aspect": "toggle"}));
                    shell.crop_label = if locked { "Free" } else { "Custom" }.to_string();
                }
                "Rotate" => {
                    let _ = app.run("photo.rotateRight", json!({}));
                }
                _ => shell.crop_popup = if shell.crop_popup == Some(CropPopup::More) { None } else { Some(CropPopup::More) },
            }
        }
    }
}

/// The Aspect tab: Original and Free, then the two lists.
fn aspect_row(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, row: Rect, aspect: Option<(u32, u32)>, shell: &mut Shell) {
    let items = [("Original", false), ("Free", false), ("Ratios", true), ("Social", true)];
    let w = (row.width() / items.len() as f32).min(96.0);
    let x0 = row.center().x - w * items.len() as f32 / 2.0;
    for (i, (name, list)) in items.into_iter().enumerate() {
        let cell = Rect::from_min_size(pos2(x0 + i as f32 * w, row.top() + 4.0), vec2(w, row.height() - 8.0));
        let on = match name {
            "Free" => aspect.is_none(),
            "Ratios" => shell.crop_popup == Some(CropPopup::Ratios),
            "Social" => shell.crop_popup == Some(CropPopup::Social),
            _ => false,
        };
        if on {
            ui.painter().rect_filled(cell.shrink2(vec2(4.0, 0.0)), 10.0, Color32::from_gray(42));
        }
        paint_icon(ui.painter(), name, cell.center_top() + vec2(0.0, 24.0), t.text);
        ui.painter().text(cell.center_bottom() - vec2(0.0, 14.0), Align2::CENTER_CENTER, crate::i18n::tr(name), t.font(12.0), t.text);
        if tap(ui, &format!("aspect-{name}"), cell).clicked() {
            if list {
                let which = if name == "Ratios" { CropPopup::Ratios } else { CropPopup::Social };
                shell.crop_popup = if shell.crop_popup == Some(which) { None } else { Some(which) };
            } else {
                shell.crop_popup = None;
                let _ = app.run("crop.aspect", json!({"aspect": if name == "Free" { "free" } else { "original" }}));
                shell.crop_label = name.to_string();
            }
        }
    }
}

/// A list floating over the photo: Ratios, Social sizes, or the more actions.
fn crop_popup(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, popup: CropPopup, above: f32, safe: Rect, shell: &mut Shell) {
    const ROW: f32 = 48.0;
    let n = match popup {
        CropPopup::Ratios => RATIOS.len(),
        CropPopup::Social => SOCIAL.len(),
        CropPopup::More => 3,
    };
    let size = vec2(if popup == CropPopup::Ratios { 250.0 } else { 270.0 }, ROW * n as f32 + 12.0);
    let x = if popup == CropPopup::Social { safe.left() + 12.0 } else { safe.right() - 12.0 - size.x };
    let card = Rect::from_min_size(pos2(x, above - 8.0 - size.y), size);
    ui.painter().rect_filled(card.translate(vec2(0.0, 4.0)), 16.0, Color32::from_black_alpha(90));
    ui.painter().rect_filled(card, 16.0, Color32::from_gray(36));
    ui.painter().rect_stroke(card, 16.0, Stroke::new(1.0, t.text_dim.gamma_multiply(0.3)), egui::StrokeKind::Inside);
    let mut chosen: Option<(String, serde_json::Value)> = None;
    for i in 0..n {
        let r = Rect::from_min_size(card.min + vec2(0.0, 6.0 + i as f32 * ROW), vec2(card.width(), ROW));
        let (label, shape): (String, Option<(f32, f32)>) = match popup {
            CropPopup::Ratios => (RATIOS[i].0.to_string(), Some((RATIOS[i].2, RATIOS[i].3))),
            CropPopup::Social => (SOCIAL[i].0.to_string(), Some((SOCIAL[i].1, SOCIAL[i].2))),
            CropPopup::More => (["Flip horizontal", "Flip vertical", "Rotate left"][i].to_string(), None),
        };
        if let Some((w, h)) = shape {
            // the shape of the ratio, fitted in a 30 × 24 box
            let k = (30.0 / w).min(24.0 / h);
            ui.painter().rect_stroke(
                Rect::from_center_size(pos2(r.left() + 36.0, r.center().y), vec2(w * k, h * k)),
                3.0,
                Stroke::new(1.6, t.text),
                egui::StrokeKind::Middle,
            );
        }
        ui.painter().text(
            pos2(r.left() + if shape.is_some() { 66.0 } else { 22.0 }, r.center().y),
            Align2::LEFT_CENTER,
            crate::i18n::tr(&label),
            t.font(18.0),
            t.text,
        );
        if tap(ui, &format!("popup-{label}"), r).clicked() {
            chosen = Some(match popup {
                CropPopup::Ratios => (label, json!({"aspect": RATIOS[i].1})),
                CropPopup::Social => (label, json!({"aspect": [SOCIAL[i].1, SOCIAL[i].2]})),
                CropPopup::More => (label, json!(i)),
            });
        }
    }
    let outside = ui.input(|i| i.pointer.any_click().then(|| i.pointer.interact_pos()).flatten());
    if let Some((label, arg)) = chosen {
        match popup {
            CropPopup::More => {
                let cmd = ["photo.flipHorizontal", "photo.flipVertical", "photo.rotateLeft"][arg.as_u64().unwrap_or(0) as usize];
                let _ = app.run(cmd, json!({}));
            }
            _ => {
                let _ = app.run("crop.aspect", arg);
                shell.crop_label = label;
            }
        }
        shell.crop_popup = None;
    } else if let Some(p) = outside
        && !card.contains(p)
        && p.y < above
    {
        shell.crop_popup = None;
    }
}

// ---------------------------------------------------------------- curve mode

/// The point-curve editor: the photo, a graph to drag points on, and a bar with the channels.
/// Every change is a `develop.curve`; a drag is one undo step.
fn curve_mode(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, safe: Rect, shell: &mut Shell) {
    let top = Rect::from_min_size(safe.min, vec2(safe.width(), HEADER_H));
    let panel = Rect::from_min_max(pos2(safe.left(), safe.bottom() - 136.0), safe.max);
    let room = panel.top() - top.bottom();
    let side = (safe.width() - 56.0).min(room * 0.52).max(120.0);
    let graph_area = Rect::from_min_max(pos2(safe.left(), panel.top() - side - 28.0), pos2(safe.right(), panel.top()));
    let graph = Rect::from_center_size(graph_area.center(), vec2(side, side));
    let hist = Rect::from_min_size(pos2(safe.left(), top.bottom()), vec2(safe.width(), 0.0));
    let canvas = Rect::from_min_max(pos2(safe.left(), top.bottom()), pos2(safe.right(), graph_area.top()));

    app.ui.filmstrip = false;
    app.ui.fullscreen = false;
    app.ui.right = RightPanel::None;
    ui.painter().rect_filled(safe, 0.0, Color32::BLACK);
    let _ = hist;
    ui.scope_builder(UiBuilder::new().max_rect(canvas), |ui| {
        ui.set_clip_rect(canvas.intersect(ui.clip_rect()));
        crate::panels::detail::show(app, ui);
    });
    ui.painter().rect_filled(graph_area, 0.0, self::panel(t));

    // top: back to the Light sheet, Undo
    let back = Rect::from_min_size(top.min, vec2(52.0, HEADER_H));
    let c = back.center();
    let chevron = Stroke::new(2.5, t.text);
    ui.painter().line_segment([c + vec2(4.0, -9.0), c + vec2(-5.0, 0.0)], chevron);
    ui.painter().line_segment([c + vec2(-5.0, 0.0), c + vec2(4.0, 9.0)], chevron);
    if tap(ui, "curve-back", back).clicked() {
        shell.tool = Some(Tool::Light);
    }
    let undo = Rect::from_min_size(pos2(top.right() - 60.0, top.top()), vec2(60.0, HEADER_H));
    paint_arrow(ui.painter(), undo.center(), t.text, false);
    if tap(ui, "curve-undo", undo).clicked() {
        let _ = app.run("edit.undo", json!({}));
    }

    curve_graph(app, ui, t, graph, shell.curve_ch);

    // the bar: name and Done, then the channels and Reset
    ui.painter().rect_filled(panel, 0.0, self::panel(t));
    ui.painter().line_segment([panel.left_top(), panel.right_top()], Stroke::new(1.0, Color32::from_white_alpha(14)));
    ui.painter().text(pos2(panel.left() + 20.0, panel.top() + 34.0), Align2::LEFT_CENTER, crate::i18n::tr("Curve"), t.semibold(17.0), t.text);
    let done = Rect::from_min_size(pos2(panel.right() - 20.0 - 92.0, panel.top() + 14.0), vec2(92.0, 40.0));
    ui.painter().rect_stroke(done, 20.0, Stroke::new(1.5, Color32::from_gray(200)), egui::StrokeKind::Inside);
    ui.painter().text(done.center(), Align2::CENTER_CENTER, crate::i18n::tr("Done"), t.semibold(15.0), t.text);
    if tap(ui, "curve-done", done).clicked() {
        shell.tool = Some(Tool::Light);
    }
    let colors = [Color32::from_gray(235), Color32::from_rgb(221, 51, 51), Color32::from_rgb(51, 170, 51), Color32::from_rgb(51, 119, 238)];
    let y = panel.top() + 94.0;
    let step = 58.0;
    let first = panel.center().x - step * 1.5;
    for (i, color) in colors.into_iter().enumerate() {
        let c = pos2(first + i as f32 * step, y);
        if shell.curve_ch == i {
            ui.painter().circle_filled(c, 15.0, color);
            ui.painter().circle_stroke(c, 19.0, Stroke::new(2.0, Color32::from_gray(230)));
        } else {
            ui.painter().circle_stroke(c, 14.0, Stroke::new(2.5, color));
        }
        if tap(ui, &format!("curve-ch-{i}"), Rect::from_center_size(c, vec2(step, 52.0))).clicked() {
            shell.curve_ch = i;
        }
    }
    let reset = Rect::from_center_size(pos2(panel.right() - 20.0 - 22.0, y), vec2(52.0, 52.0));
    ui.painter().text(reset.center(), Align2::CENTER_CENTER, crate::i18n::tr("Reset"), t.font(13.0), t.text_dim);
    if tap(ui, "curve-reset", reset).clicked() {
        let _ = app.run("curve.reset", json!({"channel": "point"}));
    }
}

/// The graph: the curve for one channel and its points. Drag a point; tap empty space to add one;
/// double-tap a point to remove it (the two ends stay).
fn curve_graph(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, r: Rect, ch: usize) {
    use lightcraft_geom::Point;
    let Some(id) = app.session.active() else { return };
    let Some(d) = app.session.develop_of(id) else { return };
    let (name, color) = [
        ("master", Color32::from_gray(235)),
        ("red", Color32::from_rgb(221, 51, 51)),
        ("green", Color32::from_rgb(51, 170, 51)),
        ("blue", Color32::from_rgb(51, 119, 238)),
    ][ch.min(3)];
    let mut pts: Vec<Point> = match name {
        "red" => &d.curve.red,
        "green" => &d.curve.green,
        "blue" => &d.curve.blue,
        _ => &d.curve.master,
    }
    .iter()
    .copied()
    .filter(|q| q.x.is_finite() && q.y.is_finite())
    .collect();
    pts.sort_by(|a, b| a.x.total_cmp(&b.x));
    if pts.len() < 2 {
        pts = vec![Point::new(0.0, 0.0), Point::new(1.0, 1.0)];
    }
    let to_screen = |x: f64, y: f64| pos2(r.left() + x as f32 * r.width(), r.bottom() - y as f32 * r.height());
    let from_screen =
        |q: egui::Pos2| (f64::from(((q.x - r.left()) / r.width()).clamp(0.0, 1.0)), f64::from(((r.bottom() - q.y) / r.height()).clamp(0.0, 1.0)));

    let resp = ui.interact(r, ui.scope_id().with(("curve-graph", name)), Sense::click_and_drag());
    let drag_id = ui.scope_id().with("curve-dragging");
    let mut dragging: Option<usize> = ui.data(|dd| dd.get_temp::<Option<usize>>(drag_id)).flatten();
    // a finger is wide: take the nearest point within this reach
    let nearest = |q: egui::Pos2| {
        pts.iter().enumerate().map(|(i, p)| (i, to_screen(p.x, p.y).distance(q))).min_by(|a, b| a.1.total_cmp(&b.1)).filter(|(_, dist)| *dist < 26.0)
    };

    let mut new_pts: Option<Vec<Point>> = None;
    if resp.double_clicked()
        && let Some(q) = resp.interact_pointer_pos()
        && let Some((i, _)) = nearest(q)
        && i != 0
        && i != pts.len() - 1
    {
        let mut v = pts.clone();
        v.remove(i);
        new_pts = Some(v);
    } else if resp.drag_started()
        && let Some(q) = ui.input(|i| i.pointer.press_origin()).or(resp.interact_pointer_pos())
    {
        let _ = app.run("develop.beginInteraction", json!({"label": "Tone Curve"}));
        match nearest(q) {
            Some((i, _)) => dragging = Some(i),
            None => {
                let (x, y) = from_screen(q);
                let mut v = pts.clone();
                let i = v.iter().position(|p| p.x > x).unwrap_or(v.len());
                v.insert(i, Point::new(x, y));
                dragging = Some(i);
                new_pts = Some(v);
            }
        }
    } else if resp.dragged()
        && let (Some(i), Some(q)) = (dragging, resp.interact_pointer_pos())
        && i < pts.len()
    {
        let (mut x, y) = from_screen(q);
        let lo = if i == 0 { 0.0 } else { pts[i - 1].x + 0.01 };
        let hi = if i + 1 >= pts.len() { 1.0 } else { pts[i + 1].x - 0.01 };
        x = if i == 0 {
            x.min(hi)
        } else if i + 1 == pts.len() {
            x.max(lo)
        } else if lo <= hi {
            x.clamp(lo, hi)
        } else {
            (pts[i - 1].x + pts[i + 1].x) / 2.0
        };
        let mut v = pts.clone();
        v[i] = Point::new(x, y);
        new_pts = Some(v);
    } else if resp.clicked()
        && let Some(q) = resp.interact_pointer_pos()
        && nearest(q).is_none()
    {
        let (x, y) = from_screen(q);
        let mut v = pts.clone();
        let i = v.iter().position(|p| p.x > x).unwrap_or(v.len());
        v.insert(i, Point::new(x, y));
        new_pts = Some(v);
    }
    if let Some(v) = &new_pts {
        let arr: Vec<[f64; 2]> = v.iter().map(|p| [p.x, p.y]).collect();
        let _ = app.run("develop.curve", json!({"channel": name, "points": arr}));
        pts = v.clone();
    }
    if dragging.is_some() && (resp.drag_stopped() || !ui.input(|i| i.pointer.primary_down())) {
        let _ = app.run("develop.endInteraction", json!({}));
        dragging = None;
    }
    ui.data_mut(|dd| dd.insert_temp(drag_id, dragging));

    let p = ui.painter();
    p.rect_filled(r, 4.0, Color32::from_black_alpha(90));
    for i in 1..4 {
        let f = i as f32 / 4.0;
        let grid = Stroke::new(1.0, Color32::from_white_alpha(45));
        p.line_segment([pos2(r.left() + r.width() * f, r.top()), pos2(r.left() + r.width() * f, r.bottom())], grid);
        p.line_segment([pos2(r.left(), r.top() + r.height() * f), pos2(r.right(), r.top() + r.height() * f)], grid);
    }
    p.rect_stroke(r, 0.0, Stroke::new(1.0, Color32::from_white_alpha(70)), egui::StrokeKind::Inside);
    p.line_segment([r.left_bottom(), r.right_top()], Stroke::new(1.0, Color32::from_white_alpha(60)));
    let curve = lightcraft_color::spline::MonotoneCurve::new(&pts.iter().map(|q| (q.x, q.y)).collect::<Vec<_>>());
    let line: Vec<egui::Pos2> = (0..=96).map(|i| to_screen(f64::from(i) / 96.0, curve.eval(f64::from(i) / 96.0).clamp(0.0, 1.0))).collect();
    p.add(egui::Shape::line(line, Stroke::new(2.5, color)));
    for (i, q) in pts.iter().enumerate() {
        let c = to_screen(q.x, q.y);
        let rr = if dragging == Some(i) { 10.0 } else { 7.0 };
        p.circle_filled(c, rr, Color32::from_gray(30));
        p.circle_stroke(c, rr, Stroke::new(2.0, Color32::from_gray(235)));
    }
    let _ = t;
}

// ---------------------------------------------------------------- color

/// White balance choices: the engine's mode name and what the list says.
const WB_MODES: [(&str, &str); 8] = [
    ("asShot", "As shot"),
    ("auto", "Auto"),
    ("daylight", "Daylight"),
    ("cloudy", "Cloudy"),
    ("shade", "Shade"),
    ("tungsten", "Tungsten"),
    ("fluorescent", "Fluorescent"),
    ("flash", "Flash"),
];

/// The top of the Color sheet: black and white, the two steps (Grading, Color mix) and white balance.
fn color_header(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, bw: bool, mode: &str, shell: &mut Shell) {
    let w = ui.available_width();
    let (row, _) = ui.allocate_exact_size(vec2(w, 64.0), Sense::hover());
    let sw = Rect::from_center_size(pos2(row.left() + 18.0 + 24.0, row.center().y), vec2(48.0, 28.0));
    ui.painter().rect_filled(sw, 15.0, if bw { t.accent } else { Color32::from_gray(70) });
    ui.painter().circle_filled(pos2(if bw { sw.right() - 14.0 } else { sw.left() + 14.0 }, sw.center().y), 11.0, Color32::from_gray(235));
    ui.painter().text(pos2(sw.right() + 10.0, row.center().y), Align2::LEFT_CENTER, crate::i18n::tr("B&W"), t.font(16.0), t.text);
    if tap(ui, "bw", Rect::from_min_max(row.left_top(), pos2(sw.right() + 70.0, row.bottom()))).clicked() {
        let _ = app.run("develop.treatment", json!({"bw": !bw}));
    }
    let x0 = row.left() + 132.0;
    let bw_w = ((row.right() - 16.0 - x0) - 8.0) / 2.0;
    for (i, (label, icon, to)) in [("Grading", "Grading", Tool::Grading), ("Color mix", "Mixer", Tool::Mixer)].into_iter().enumerate() {
        let b = Rect::from_min_size(pos2(x0 + i as f32 * (bw_w + 8.0), row.top() + 12.0), vec2(bw_w, 40.0));
        ui.painter().rect_filled(b, 8.0, Color32::from_white_alpha(10));
        ui.painter().rect_stroke(b, 8.0, Stroke::new(1.0, Color32::from_white_alpha(46)), egui::StrokeKind::Inside);
        let text = ui.painter().layout_no_wrap(crate::i18n::tr(label).to_string(), t.font(13.5), t.text);
        let total = 20.0 + 6.0 + text.size().x;
        let start = b.center().x - total / 2.0;
        paint_icon(ui.painter(), icon, pos2(start + 10.0, b.center().y), t.text);
        ui.painter().galley(pos2(start + 26.0, b.center().y - text.size().y / 2.0), text, t.text);
        if tap(ui, label, b).clicked() {
            shell.tool = Some(to);
        }
    }
    let (wb, _) = ui.allocate_exact_size(vec2(w, 48.0), Sense::hover());
    let name = WB_MODES.iter().find(|(m, _)| *m == mode).map_or("Custom", |(_, n)| n);
    ui.painter().text(pos2(wb.left() + 18.0, wb.center().y), Align2::LEFT_CENTER, crate::i18n::tr("White balance"), t.font(15.0), t.text_dim);
    let shown = ui.painter().text(pos2(wb.left() + 140.0, wb.center().y), Align2::LEFT_CENTER, crate::i18n::tr(name), t.font(16.0), t.text);
    let c = pos2(shown.right() + 16.0, wb.center().y);
    let dy = if shell.wb_open { -4.0 } else { 4.0 };
    let chevron = Stroke::new(2.0, t.text);
    ui.painter().line_segment([c + vec2(-6.0, -dy / 2.0), c + vec2(0.0, dy / 2.0 + dy / 4.0)], chevron);
    ui.painter().line_segment([c + vec2(0.0, dy / 2.0 + dy / 4.0), c + vec2(6.0, -dy / 2.0)], chevron);
    if tap(ui, "wb-open", wb).clicked() {
        shell.wb_open = !shell.wb_open;
    }
    if shell.wb_open {
        for (key, label) in WB_MODES {
            let (r, _) = ui.allocate_exact_size(vec2(w, 44.0), Sense::hover());
            let on = key == mode;
            ui.painter().text(
                pos2(r.left() + 32.0, r.center().y),
                Align2::LEFT_CENTER,
                crate::i18n::tr(label),
                t.font(16.0),
                if on { t.accent } else { t.text },
            );
            if tap(ui, &format!("wb-{key}"), r).clicked() {
                let _ = app.run("develop.wb", json!({"mode": key}));
                shell.wb_open = false;
            }
        }
    }
}

/// Colour grading: the photo on top, below it a wheel for each tonal range (and one for the whole
/// picture). Dragging the wheel sets hue by angle and saturation by distance from the middle.
fn grading_mode(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, safe: Rect, shell: &mut Shell) {
    let top = Rect::from_min_size(safe.min, vec2(safe.width(), HEADER_H));
    let canvas = Rect::from_min_max(pos2(safe.left(), top.bottom() + 8.0), pos2(safe.right(), safe.top() + safe.height() * 0.44));
    let panel = Rect::from_min_max(pos2(safe.left(), canvas.bottom()), safe.max);
    app.ui.filmstrip = false;
    app.ui.fullscreen = false;
    app.ui.right = RightPanel::None;
    ui.painter().rect_filled(safe, 0.0, Color32::BLACK);
    ui.scope_builder(UiBuilder::new().max_rect(canvas), |ui| {
        ui.set_clip_rect(canvas.intersect(ui.clip_rect()));
        crate::panels::detail::show(app, ui);
    });
    let back = Rect::from_min_size(top.min, vec2(52.0, HEADER_H));
    let c = back.center();
    let chevron = Stroke::new(2.5, t.text);
    ui.painter().line_segment([c + vec2(4.0, -9.0), c + vec2(-5.0, 0.0)], chevron);
    ui.painter().line_segment([c + vec2(-5.0, 0.0), c + vec2(4.0, 9.0)], chevron);
    if tap(ui, "grading-back", back).clicked() {
        shell.tool = Some(Tool::Color);
    }
    let undo = Rect::from_min_size(pos2(top.right() - 60.0, top.top()), vec2(60.0, HEADER_H));
    paint_arrow(ui.painter(), undo.center(), t.text, false);
    if tap(ui, "grading-undo", undo).clicked() {
        let _ = app.run("edit.undo", json!({}));
    }

    ui.painter().rect_filled(panel, 0.0, bar(t));
    let Some(id) = app.session.active() else { return };
    let d = app.session.develop_of(id).unwrap_or_default();
    let names = ["shadows", "midtones", "highlights", "global"];
    let titles = ["Shadows", "Midtones", "Highlights", "Global"];
    let region = shell.grade_region.min(3);
    let name = names[region];
    ui.scope_builder(UiBuilder::new().max_rect(panel), |ui| {
        ui.set_clip_rect(panel.intersect(ui.clip_rect()));
        egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
            ui.spacing_mut().item_spacing = vec2(0.0, 0.0);
            let w = ui.available_width();
            // name and Done
            let (head, _) = ui.allocate_exact_size(vec2(w, 64.0), Sense::hover());
            ui.painter().text(
                pos2(head.left() + 20.0, head.center().y),
                Align2::LEFT_CENTER,
                crate::i18n::tr("Color grading"),
                t.semibold(18.0),
                t.text_dim,
            );
            let done = Rect::from_center_size(pos2(head.right() - 20.0 - 52.0, head.center().y), vec2(104.0, 44.0));
            ui.painter().rect_stroke(done, 22.0, Stroke::new(2.0, t.text_dim), egui::StrokeKind::Inside);
            ui.painter().text(done.center(), Align2::CENTER_CENTER, crate::i18n::tr("Done"), t.semibold(17.0), t.text_dim);
            if tap(ui, "grading-done", done).clicked() {
                shell.tool = Some(Tool::Color);
            }
            // the four ranges
            let (dots, _) = ui.allocate_exact_size(vec2(w, 56.0), Sense::hover());
            let fills = [Color32::from_gray(25), Color32::from_gray(100), Color32::from_gray(225), Color32::from_gray(150)];
            for i in 0..4 {
                let x = dots.center().x + (i as f32 - 1.5) * 64.0 + if i == 3 { 14.0 } else { 0.0 };
                let c = pos2(x, dots.center().y);
                if i == 3 {
                    ui.painter().line_segment([pos2(x - 32.0, c.y - 10.0), pos2(x - 32.0, c.y + 10.0)], Stroke::new(1.5, t.text_dim));
                }
                if region == i {
                    ui.painter().circle_filled(c, 15.0, Color32::WHITE);
                    ui.painter().circle_filled(c, 9.0, fills[i]);
                } else {
                    ui.painter().circle_filled(c, 14.0, fills[i]);
                    ui.painter().circle_stroke(c, 14.0, Stroke::new(2.0, Color32::from_gray(200)));
                }
                if tap(ui, &format!("range-{i}"), Rect::from_center_size(c, vec2(56.0, 52.0))).clicked() {
                    shell.grade_region = i;
                }
            }
            // the wheel
            let size = (w - 100.0).clamp(160.0, 270.0);
            let (area, _) = ui.allocate_exact_size(vec2(w, size + 24.0), Sense::hover());
            let wheel = Rect::from_center_size(area.center(), vec2(size, size));
            grading_wheel(app, ui, t, wheel, name, &d);
            // the range's name
            let (lab, _) = ui.allocate_exact_size(vec2(w, 48.0), Sense::hover());
            ui.painter().text(pos2(lab.left() + 20.0, lab.center().y), Align2::LEFT_CENTER, crate::i18n::tr(titles[region]), t.font(17.0), t.text);
            // sliders for this range
            let ids: Vec<(String, &'static str)> = {
                let mut v = vec![
                    (format!("grading.{name}.hue"), "Hue"),
                    (format!("grading.{name}.sat"), "Saturation"),
                    (format!("grading.{name}.lum"), "Luminance"),
                ];
                if region < 3 {
                    v.push(("grading.blending".to_string(), "Blending"));
                    v.push(("grading.balance".to_string(), "Balance"));
                }
                v
            };
            for (cid, label) in ids {
                let Some(spec) = controls::find(&cid) else { continue };
                let spec = ControlSpec { label, ..*spec };
                let v = controls::get(&d, spec.id).unwrap_or(spec.default);
                let out = touch_slider(ui, t, &spec, v);
                crate::panels::edit::apply_slider_out(app, &spec, out, |app, v| app.run("develop.set", json!({"control": spec.id, "value": v})));
            }
            ui.add_space(32.0);
        });
    });
}

/// One grading wheel: hue runs round the circle (red on the right), saturation out from the middle.
fn grading_wheel(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, r: Rect, name: &str, d: &lightcraft_develop::DevelopSettings) {
    let hue_id = format!("grading.{name}.hue");
    let sat_id = format!("grading.{name}.sat");
    let hue = controls::get(d, &hue_id).unwrap_or(0.0);
    let sat = controls::get(d, &sat_id).unwrap_or(0.0);
    let center = r.center();
    let radius = r.width() / 2.0;
    let (rings, spokes) = (14usize, 120usize);
    let mut mesh = egui::Mesh::default();
    for ring in 0..=rings {
        for a in 0..spokes {
            let ang = a as f32 / spokes as f32 * std::f32::consts::TAU;
            let f = ring as f32 / rings as f32;
            let color = egui::ecolor::Hsva::new(a as f32 / spokes as f32, f.powf(0.8), 1.0, 1.0);
            mesh.colored_vertex(center + vec2(ang.cos(), -ang.sin()) * radius * f, color.into());
        }
    }
    for ring in 0..rings {
        for a in 0..spokes {
            let (a2, i0, i1) = (a, ring * spokes, (ring + 1) * spokes);
            let b = (a2 + 1) % spokes;
            mesh.add_triangle((i0 + a2) as u32, (i1 + a2) as u32, (i1 + b) as u32);
            mesh.add_triangle((i0 + a2) as u32, (i1 + b) as u32, (i0 + b) as u32);
        }
    }
    ui.painter().add(egui::Shape::mesh(mesh));
    let ang = (hue as f32).to_radians();
    let knob = center + vec2(ang.cos(), -ang.sin()) * radius * (sat as f32 / 100.0).clamp(0.0, 1.0);
    ui.painter().circle_stroke(knob, 14.0, Stroke::new(2.5, Color32::from_gray(80)));
    ui.painter().circle_stroke(knob, 14.0, Stroke::new(1.0, Color32::WHITE));
    ui.painter().circle_filled(knob, 2.5, Color32::from_gray(80));
    let _ = t;

    let resp = ui.interact(r.expand(14.0), ui.scope_id().with(("wheel", name)), Sense::click_and_drag());
    if resp.drag_started() {
        let _ = app.run("develop.beginInteraction", json!({"label": "Color Grading"}));
    }
    if (resp.dragged() || resp.drag_started())
        && let Some(q) = resp.interact_pointer_pos()
    {
        let v = q - center;
        let mut deg = f64::from((-v.y).atan2(v.x).to_degrees());
        if deg < 0.0 {
            deg += 360.0;
        }
        let s = (f64::from(v.length() / radius) * 100.0).clamp(0.0, 100.0);
        let _ = app.run("develop.set", json!({"control": hue_id, "value": deg.round()}));
        let _ = app.run("develop.set", json!({"control": sat_id, "value": s.round()}));
    }
    if resp.drag_stopped() {
        let _ = app.run("develop.endInteraction", json!({}));
    }
    if resp.double_clicked() {
        let _ = app.run("develop.beginInteraction", json!({"label": "Color Grading"}));
        let _ = app.run("develop.set", json!({"control": hue_id, "value": 0.0}));
        let _ = app.run("develop.set", json!({"control": sat_id, "value": 0.0}));
        let _ = app.run("develop.endInteraction", json!({}));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A retune of the engine's control groups must not leave a tool with an empty sheet.
    #[test]
    fn every_tool_has_sliders() {
        for tool in Tool::ALL.into_iter().filter(|t| !matches!(t, Tool::Presets | Tool::Crop | Tool::Curve | Tool::Mixer | Tool::Grading)) {
            let n: usize = tool.sections().iter().map(|(section, _)| controls::in_section(*section).count()).sum();
            assert!(n > 0, "{} has no controls", tool.label());
        }
    }

    fn phone() -> crate::headless::Headless {
        let mut app = LightcraftApp::new(lightcraft_engine::Session::with_demo(), crate::Services::default());
        app.mobile = Some(Shell::preview());
        app.ui.seen_version = Some(env!("CARGO_PKG_VERSION").to_string());
        crate::headless::Headless::new(app, [393.0, 852.0], 1.0)
    }

    /// The desktop's lens offer would trap touches on a phone: the phone shows its own sheet, and
    /// Not Now on it takes it away and gives the screen back.
    #[test]
    fn the_lens_offer_is_a_sheet_that_can_be_dismissed() {
        let mut h = phone();
        h.step();
        h.app.ui.dialog = Some(crate::state::Dialog::LensDatabase { dir: "/nonexistent".into(), mirrors: vec![] });
        h.step();
        h.step();
        assert!(h.app.ui.dialog.is_none(), "the desktop dialog must not stay open behind the sheet");
        let text = h.painted_text();
        assert!(text.iter().any(|t| t.contains("Not Now")), "{text:?}");
        // Not Now: left of the two buttons, 150 pt below the card's top (the card is 230 pt plus the inset)
        let y = 852.0 - (230.0 + 34.0) + 150.0 + 25.0;
        let r = h.request("ui.click", serde_json::json!({"x": 100.0, "y": y}), std::time::Duration::from_secs(5));
        assert_eq!(r["ok"], true, "{r}");
        h.step();
        h.step();
        assert!(!h.painted_text().iter().any(|t| t.contains("Not Now")), "the sheet stays up after Not Now");
    }

    /// Any other desktop dialog is closed on the phone instead of trapping input.
    #[test]
    fn other_desktop_dialogs_do_not_stay_open() {
        let mut h = phone();
        h.step();
        h.app.ui.dialog = Some(crate::state::Dialog::WhatsNew);
        h.step();
        assert!(h.app.ui.dialog.is_none());
    }

    #[test]
    fn a_quick_sideways_flick_changes_photo_and_nothing_else_does() {
        assert_eq!(swipe(vec2(-150.0, 10.0), 0.2), Some("library.next"));
        assert_eq!(swipe(vec2(150.0, -10.0), 0.2), Some("library.previous"));
        assert_eq!(swipe(vec2(-150.0, 140.0), 0.2), None, "diagonal drags are not swipes");
        assert_eq!(swipe(vec2(-150.0, 0.0), 1.5), None, "a slow drag is not a swipe");
        assert_eq!(swipe(vec2(-20.0, 0.0), 0.1), None, "a tap with a wobble is not a swipe");
    }

    fn open_tool(name: &str) -> crate::headless::Headless {
        let mut h = phone();
        h.step();
        let (_, ids) = h.app.session.visible_shared();
        let id = *ids.first().expect("demo photos");
        h.app.run("library.select", serde_json::json!({"ids": [id.0], "mode": "replace"})).expect("select");
        h.app.run("view.detail", serde_json::json!({})).expect("detail");
        h.app.mobile.as_mut().expect("phone").open_photo(Some(name));
        h.step();
        h.step();
        h
    }

    #[test]
    fn crop_mode_has_its_own_screen_and_cancel_undoes_what_it_changed() {
        let mut h = open_tool("Crop");
        h.app.mobile.as_mut().expect("phone").crop_mark = h.app.session.undo.len();
        let text = h.painted_text();
        assert!(text.iter().any(|t| t == "Ratios") && text.iter().any(|t| t == "Original") && text.iter().any(|t| t == "Geometry"), "{text:?}");
        assert!(!text.iter().any(|t| t == "Exposure"));
        let id = h.app.session.active().expect("active");
        let before = h.app.session.develop_of(id);
        h.app.run("crop.aspect", serde_json::json!({"aspect": "1x1"})).expect("aspect");
        assert!(h.app.session.develop_of(id).is_some_and(|d| d.crop.aspect.is_some()));
        // Cancel: bottom left of the screen, above the home indicator
        let r = h.request("ui.click", serde_json::json!({"x": 32.0, "y": 790.0}), std::time::Duration::from_secs(5));
        assert_eq!(r["ok"], true, "{r}");
        h.step();
        h.step();
        assert_eq!(h.app.session.develop_of(id), before, "Cancel leaves the crop as it was");
        assert!(h.app.mobile.as_ref().is_some_and(|m| m.tool.is_none()), "and leaves crop mode");
    }

    #[test]
    fn the_presets_sheet_lists_presets_and_applying_one_changes_the_edit() {
        let mut h = open_tool("Presets");
        let first = h.app.session.presets.first().expect("built-in presets").clone();
        let text = h.painted_text();
        assert!(text.contains(&first.group), "the group tabs show {:?}: {text:?}", first.group);
        let id = h.app.session.active().expect("active");
        let before = h.app.session.develop_of(id);
        h.app.run("preset.apply", serde_json::json!({"id": first.id})).expect("apply");
        assert_ne!(h.app.session.develop_of(id), before, "{} did nothing", first.name);
    }

    #[test]
    fn rating_and_flagging_from_the_row_go_through_the_commands() {
        let mut h = open_tool("Light");
        let shell = h.app.mobile.as_mut().expect("phone");
        shell.tool = None;
        shell.menu = true;
        h.step();
        h.step();
        let text = h.painted_text();
        assert!(text.iter().any(|t| t == "Pick") && text.iter().any(|t| t == "Reject") && text.iter().any(|t| t == "Reset all edits"), "{text:?}");
    }

    /// Tapping + adds what is in the Import folder to the library.
    #[test]
    fn plus_imports_the_import_folder() {
        let dir = std::env::temp_dir().join(format!("lc-mobile-import-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("dir");
        let data: Vec<[u8; 4]> = (0..24 * 16).map(|i| [(i % 24 * 9) as u8, (i / 24 * 13) as u8, 7, 255]).collect();
        let img = lightcraft_raster::Rgba8 { width: 24, height: 16, data };
        let bytes =
            lightcraft_codecs::encode_png(&lightcraft_codecs::EncodeImage::rgba8(&img), &lightcraft_codecs::EncodeMeta::default()).expect("png");
        std::fs::write(dir.join("a.png"), bytes).expect("write");
        let mut app = LightcraftApp::new(lightcraft_engine::Session::new().with_fs(), crate::Services::default());
        let mut shell = Shell::preview();
        shell.import_dir = Some(dir.clone());
        app.mobile = Some(shell);
        app.ui.seen_version = Some(env!("CARGO_PKG_VERSION").to_string());
        let mut h = crate::headless::Headless::new(app, [393.0, 852.0], 1.0);
        h.step();
        let r = h.request("ui.click", serde_json::json!({"x": 357.0, "y": 73.0}), std::time::Duration::from_secs(5));
        assert_eq!(r["ok"], true, "{r}");
        for _ in 0..200 {
            h.step();
            std::thread::sleep(std::time::Duration::from_millis(20));
            if !h.app.session.visible_shared().1.is_empty() {
                break;
            }
        }
        let n = h.app.session.visible_shared().1.len();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(n, 1, "the photo in the Import folder is in the library; toasts: {:?}", h.painted_text());
    }

    #[test]
    fn the_mixer_sheet_shows_one_band_at_a_time() {
        let mut h = open_tool("Mixer");
        let text = h.painted_text();
        assert!(text.iter().any(|t| t.contains("Red Hue")) && !text.iter().any(|t| t.contains("Blue Hue")), "{text:?}");
        h.app.mobile.as_mut().expect("phone").mixer_band = 5;
        h.step();
        h.step();
        let text = h.painted_text();
        assert!(text.iter().any(|t| t.contains("Blue Hue")) && !text.iter().any(|t| t.contains("Red Hue")), "{text:?}");
    }

    #[test]
    fn the_wand_shows_one_tap_actions_and_no_slider_sheet() {
        let h = open_tool("Assist");
        let text = h.painted_text();
        assert!(text.iter().any(|t| t == "Enhance") && text.iter().any(|t| t == "Fix angle") && text.iter().any(|t| t == "Subject"), "{text:?}");
        assert!(!text.iter().any(|t| t == "Exposure"), "no sheet over the photo: {text:?}");
    }

    #[test]
    fn the_curve_has_a_screen_of_its_own_with_done() {
        let h = open_tool("Curve");
        let text = h.painted_text();
        assert!(text.iter().any(|t| t == "Curve") && text.iter().any(|t| t == "Done"), "{text:?}");
        assert!(!text.iter().any(|t| t == "Exposure"), "{text:?}");
    }

    #[test]
    fn light_offers_the_curve_screen() {
        let h = open_tool("Light");
        let text = h.painted_text();
        assert!(text.iter().any(|t| t == "Curve") && text.iter().any(|t| t == "Exposure"), "{text:?}");
    }

    #[test]
    fn color_has_bw_grading_and_color_mix_above_the_sliders() {
        let h = open_tool("Color");
        let text = h.painted_text();
        for want in ["B&W", "Grading", "Color mix", "White balance", "Temp", "Vibrance"] {
            assert!(text.iter().any(|t| t == want), "{want}: {text:?}");
        }
    }

    #[test]
    fn grading_has_a_screen_with_a_wheel_per_range() {
        let mut h = open_tool("Grading");
        let text = h.painted_text();
        assert!(text.iter().any(|t| t == "Color grading") && text.iter().any(|t| t == "Shadows") && text.iter().any(|t| t == "Done"), "{text:?}");
        h.app.mobile.as_mut().expect("phone").grade_region = 3;
        h.step();
        let text = h.painted_text();
        assert!(text.iter().any(|t| t == "Global") && !text.iter().any(|t| t == "Balance"), "{text:?}");
    }

    #[test]
    fn color_mix_is_still_reachable_with_a_way_back() {
        let h = open_tool("Mixer");
        let text = h.painted_text();
        assert!(text.iter().any(|t| t == "Color mix"), "{text:?}");
    }

    #[test]
    fn a_tap_on_the_photo_hides_the_bars_and_another_brings_them_back() {
        let mut h = open_tool("Light");
        h.app.mobile.as_mut().expect("phone").tool = None;
        h.step();
        assert!(h.painted_text().iter().any(|t| t == "Light"));
        h.app.mobile.as_mut().expect("phone").hidden = true;
        h.step();
        let text = h.painted_text();
        assert!(!text.iter().any(|t| t == "Light" || t == "Auto"), "{text:?}");
        h.app.mobile.as_mut().expect("phone").hidden = false;
        h.step();
        assert!(h.painted_text().iter().any(|t| t == "Light"));
    }

    #[test]
    fn effects_and_detail_open_on_their_first_tab_and_tabs_switch_the_sliders() {
        let mut h = open_tool("Effects");
        let text = h.painted_text();
        assert!(["Effects", "Vignette", "Grain", "Texture"].iter().all(|w| text.iter().any(|t| t == w)), "{text:?}");
        assert!(!text.iter().any(|t| t == "Roughness"), "{text:?}");
        h.app.mobile.as_mut().expect("phone").subtab.1 = 2;
        h.step();
        let text = h.painted_text();
        assert!(text.iter().any(|t| t == "Roughness") && !text.iter().any(|t| t == "Texture"), "{text:?}");
        h.app.mobile.as_mut().expect("phone").open_photo(Some("Detail"));
        h.step();
        h.step();
        let text = h.painted_text();
        assert!(
            text.iter().any(|t| t == "Sharpening") && text.iter().any(|t| t == "Color noise") && !text.iter().any(|t| t == "Smoothness"),
            "{text:?}"
        );
    }

    #[test]
    fn sideways_the_phone_shows_the_photo_alone() {
        let mut app = LightcraftApp::new(lightcraft_engine::Session::with_demo(), crate::Services::default());
        app.mobile = Some(Shell::preview());
        app.ui.seen_version = Some(env!("CARGO_PKG_VERSION").to_string());
        let mut h = crate::headless::Headless::new(app, [852.0, 393.0], 1.0);
        h.step();
        let (_, ids) = h.app.session.visible_shared();
        let id = *ids.first().expect("demo photos");
        h.app.run("library.select", serde_json::json!({"ids": [id.0], "mode": "replace"})).expect("select");
        h.app.mobile.as_mut().expect("phone").open_photo(Some("Light"));
        h.step();
        h.step();
        let text = h.painted_text();
        assert!(!text.iter().any(|t| t == "Light" || t == "Exposure"), "{text:?}");
    }
}
