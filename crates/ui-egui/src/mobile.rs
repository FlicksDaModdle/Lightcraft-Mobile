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
const STRIP_H: f32 = 60.0;
/// The rating row above the tool strip.
const RATE_H: f32 = 48.0;
/// The slider rows' height: a finger-sized track under its label.
const ROW_H: f32 = 64.0;
/// Gap between thumbnails.
const GAP: f32 = 2.0;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Screen {
    Library,
    Photo,
}

/// A group of sliders in the bottom sheet.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Tool {
    Presets,
    Crop,
    Light,
    Color,
    Effects,
    Detail,
    Optics,
    Geometry,
}

impl Tool {
    const ALL: [Tool; 8] = [Tool::Presets, Tool::Crop, Tool::Light, Tool::Color, Tool::Effects, Tool::Detail, Tool::Optics, Tool::Geometry];

    fn label(self) -> &'static str {
        match self {
            Tool::Presets => "Presets",
            Tool::Crop => "Crop",
            Tool::Light => "Light",
            Tool::Color => "Color",
            Tool::Effects => "Effects",
            Tool::Detail => "Detail",
            Tool::Optics => "Optics",
            Tool::Geometry => "Geometry",
        }
    }

    /// The engine's control groups the tool shows, with the heading each gets when there are several.
    fn sections(self) -> &'static [(Section, &'static str)] {
        match self {
            Tool::Presets | Tool::Crop => &[],
            Tool::Light => &[(Section::Light, "")],
            Tool::Color => &[(Section::Color, "")],
            Tool::Effects => &[(Section::Effects, ""), (Section::Vignette, "Vignette"), (Section::Grain, "Grain")],
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
        self.tool = tool.and_then(|name| Tool::ALL.into_iter().find(|t| t.label().eq_ignore_ascii_case(name)));
    }
}

fn insets(ctx: &egui::Context, shell: &Shell) -> [f32; 4] {
    if let Some(i) = shell.insets {
        return i;
    }
    let m = ctx.input(|i| i.safe_area_insets()).0;
    [m.top, m.right, m.bottom, m.left]
}

/// Draw the phone layout over the whole window.
pub(crate) fn show(app: &mut LightcraftApp, ui: &mut egui::Ui) {
    let Some(mut shell) = app.mobile.take() else { return };
    let ctx = ui.ctx().clone();
    let t = Tokens::get(&ctx);
    let full = ui.max_rect();
    ui.painter().rect_filled(full, 0.0, t.chrome);
    // a notice or prompt would block all input behind a dialog sized for a desktop: say it in a toast
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
        ui.painter().rect_filled(card, egui::CornerRadius { nw: 16, ne: 16, sw: 0, se: 0 }, t.chrome);
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
    p.text(pos2(header.left() + 16.0, header.center().y), Align2::LEFT_CENTER, crate::i18n::tr("Library"), t.semibold(24.0), t.text);
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
fn add_photos(app: &mut LightcraftApp, ctx: &egui::Context, shell: &Shell) {
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
    let cols = ((width / 118.0).floor() as usize).clamp(3, 8);
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
    let header = Rect::from_min_size(safe.min, vec2(safe.width(), HEADER_H));
    let strip = Rect::from_min_max(pos2(safe.left(), safe.bottom() - STRIP_H), safe.max);
    let sheet_h = if shell.tool.is_some() { (safe.height() * 0.4).min(360.0) } else { 0.0 };
    let sheet = Rect::from_min_max(pos2(safe.left(), strip.top() - sheet_h), pos2(safe.right(), strip.top()));
    // the rating row sits above the strip while no sheet is open
    let rate_h = if shell.tool.is_none() { RATE_H } else { 0.0 };
    let rate = Rect::from_min_max(pos2(safe.left(), sheet.top() - rate_h), pos2(safe.right(), sheet.top()));
    let canvas = Rect::from_min_max(pos2(safe.left(), header.bottom()), pos2(safe.right(), rate.top()));

    // the loupe draws the photo; the desktop's own side panels, filmstrip and full screen stay off
    app.ui.filmstrip = false;
    app.ui.fullscreen = false;
    app.ui.right = RightPanel::None;
    ui.painter().rect_filled(canvas, 0.0, Color32::BLACK);
    ui.scope_builder(UiBuilder::new().max_rect(canvas), |ui| {
        ui.set_clip_rect(canvas.intersect(ui.clip_rect()));
        crate::panels::detail::show(app, ui);
    });

    gestures(app, ui.ctx(), canvas, shell);
    header_bar(app, ui, t, header, shell);
    if rate_h > 0.0 {
        ui.painter().rect_filled(rate, 0.0, t.chrome);
        rating_row(app, ui, t, rate, shell);
    }
    if let Some(tool) = shell.tool {
        ui.painter().rect_filled(sheet, 0.0, t.chrome);
        ui.painter().line_segment([sheet.left_top(), sheet.right_top()], Stroke::new(1.0, t.text_dim.gamma_multiply(0.35)));
        ui.scope_builder(UiBuilder::new().max_rect(sheet), |ui| {
            ui.set_clip_rect(sheet.intersect(ui.clip_rect()));
            sheet_of(app, ui, t, tool, shell);
        });
    }
    ui.painter().rect_filled(strip, 0.0, t.chrome);
    ui.scope_builder(UiBuilder::new().max_rect(strip), |ui| tool_strip(app, ui, t, strip, shell));
}

fn header_bar(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, header: Rect, shell: &mut Shell) {
    ui.painter().rect_filled(header, 0.0, t.chrome);
    let back = Rect::from_min_size(header.min, vec2(52.0, HEADER_H));
    let c = back.center();
    let chevron = Stroke::new(2.5, t.text);
    ui.painter().line_segment([c + vec2(4.0, -9.0), c + vec2(-5.0, 0.0)], chevron);
    ui.painter().line_segment([c + vec2(-5.0, 0.0), c + vec2(4.0, 9.0)], chevron);
    if tap(ui, "back", back).clicked() {
        shell.screen = Screen::Library;
        shell.tool = None;
        app.ui.view = crate::state::ViewMode::PhotoGrid;
    }
    // undo / redo at the right, the file name between
    let (undo, redo) = (
        Rect::from_min_size(pos2(header.right() - 124.0, header.top()), vec2(62.0, HEADER_H)),
        Rect::from_min_size(pos2(header.right() - 62.0, header.top()), vec2(62.0, HEADER_H)),
    );
    for (name, label, rect, cmd) in [("undo", "Undo", undo, "edit.undo"), ("redo", "Redo", redo, "edit.redo")] {
        ui.painter().text(rect.center(), Align2::CENTER_CENTER, crate::i18n::tr(label), t.font(15.0), t.accent);
        if tap(ui, name, rect).clicked() {
            let _ = app.run(cmd, json!({}));
        }
    }
    if let Some(photo) = app.session.active().and_then(|id| app.session.catalog.photo(id)) {
        let name_rect = Rect::from_min_max(pos2(back.right(), header.top()), pos2(undo.left() - 4.0, header.bottom()));
        ui.painter_at(name_rect).text(name_rect.center(), Align2::CENTER_CENTER, &photo.file_name, t.semibold(15.0), t.text);
    }
}

/// The bottom row of tools: Auto, then a sheet of sliders per group.
fn tool_strip(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, strip: Rect, shell: &mut Shell) {
    ui.set_clip_rect(strip.intersect(ui.clip_rect()));
    egui::ScrollArea::horizontal().scroll_bar_visibility(egui::scroll_area::ScrollBarVisibility::AlwaysHidden).auto_shrink([false, false]).show(
        ui,
        |ui| {
            ui.spacing_mut().item_spacing = vec2(0.0, 0.0);
            ui.horizontal(|ui| {
                let item = |ui: &mut egui::Ui, label: &str, on: bool| -> bool {
                    let text = crate::i18n::tr(label);
                    let color = if on { t.accent } else { t.text };
                    let galley = ui.painter().layout_no_wrap(text.to_string(), t.font(15.0), color);
                    let (r, resp) = ui.allocate_exact_size(vec2((galley.size().x + 32.0).max(72.0), STRIP_H), Sense::click());
                    let galley_w = galley.size().x;
                    ui.painter().galley(r.center() - galley.size() / 2.0 - vec2(0.0, 3.0), galley, color);
                    if on {
                        ui.painter().line_segment(
                            [r.center() + vec2(-galley_w / 2.0, 16.0), r.center() + vec2(galley_w / 2.0, 16.0)],
                            Stroke::new(3.0, t.accent),
                        );
                    }
                    resp.clicked()
                };
                if item(ui, "Auto", false) {
                    let _ = app.run("develop.auto", json!({}));
                    app.toast(ui.ctx(), crate::i18n::tr("Auto settings applied"));
                }
                for tool in Tool::ALL {
                    if item(ui, tool.label(), shell.tool == Some(tool)) {
                        shell.tool = if shell.tool == Some(tool) { None } else { Some(tool) };
                    }
                }
            });
        },
    );
}

// ---------------------------------------------------------------- sliders

/// The sliders of one tool, in a scrolling sheet.
fn sheet_of(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, tool: Tool, shell: &mut Shell) {
    match tool {
        Tool::Presets => return presets_sheet(app, ui, t, shell),
        Tool::Crop => return crop_sheet(app, ui, t),
        _ => {}
    }
    let Some(id) = app.session.active() else { return };
    let d = app.session.develop_of(id).unwrap_or_default();
    let specs: Vec<(&'static str, &'static ControlSpec)> = tool
        .sections()
        .iter()
        .flat_map(|(section, heading)| controls::in_section(*section).filter(|s| controls::get(&d, s.id).is_some()).map(move |s| (*heading, s)))
        .collect();
    let title = Rect::from_min_size(ui.max_rect().min, vec2(ui.max_rect().width(), 40.0));
    ui.painter().text(pos2(title.left() + 16.0, title.center().y), Align2::LEFT_CENTER, crate::i18n::tr(tool.label()), t.semibold(16.0), t.text);
    let changed = specs.iter().any(|(_, s)| controls::get(&d, s.id).is_some_and(|v| (v - s.default).abs() > 1e-9));
    let reset = Rect::from_min_size(pos2(title.right() - 80.0, title.top()), vec2(80.0, 40.0));
    ui.painter().text(reset.center(), Align2::CENTER_CENTER, crate::i18n::tr("Reset"), t.font(15.0), if changed { t.accent } else { t.text_dim });
    if changed && tap(ui, "reset-tool", reset).clicked() {
        let _ = app.run("develop.beginInteraction", json!({"label": tool.label()}));
        for (_, spec) in &specs {
            let _ = app.run("develop.set", json!({"control": spec.id, "value": spec.default}));
        }
        let _ = app.run("develop.endInteraction", json!({}));
    }
    let body = Rect::from_min_max(pos2(title.left(), title.bottom()), ui.max_rect().max);
    ui.scope_builder(UiBuilder::new().max_rect(body), |ui| {
        ui.set_clip_rect(body.intersect(ui.clip_rect()));
        egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
            ui.spacing_mut().item_spacing = vec2(0.0, 0.0);
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
    p.text(pos2(row.left() + pad, row.top() + 20.0), Align2::LEFT_CENTER, crate::i18n::tr(spec.label), t.font(15.0), t.text);
    p.text(
        pos2(row.right() - pad, row.top() + 20.0),
        Align2::RIGHT_CENTER,
        spec.format(shown),
        t.font(15.0),
        if changed { t.accent } else { t.text_dim },
    );
    let y = track.center().y;
    let x_of = |v: f64| track.left() + spec.position(v) as f32 * track.width();
    p.line_segment([pos2(track.left(), y), pos2(track.right(), y)], Stroke::new(3.0, t.text_dim.gamma_multiply(0.45)));
    p.line_segment([pos2(x_of(spec.default), y), pos2(x_of(shown), y)], Stroke::new(3.0, t.accent));
    p.circle_filled(pos2(x_of(shown), y), if resp.dragged() { 13.0 } else { 11.0 }, if changed { t.accent } else { Color32::from_gray(230) });
    out
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
        shell.press = Some((p, now));
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
            }
            shell.press = None;
        }
    }
    if released && app.ui.before_after == BeforeAfter::Original && shell.press.is_none() {
        app.ui.before_after = BeforeAfter::Off;
    }
}

/// How long a still finger holds before the original shows.
const HOLD_SECS: f64 = 0.45;

/// The command a drag of `d` points over `secs` makes: a quick, mostly sideways flick.
fn swipe(d: egui::Vec2, secs: f64) -> Option<&'static str> {
    (secs < 0.7 && d.x.abs() > 90.0 && d.y.abs() < d.x.abs() * 0.5).then_some(if d.x < 0.0 { "library.next" } else { "library.previous" })
}

/// Stars, pick and reject on the left; Export on the right.
fn rating_row(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, row: Rect, shell: &Shell) {
    let Some(id) = app.session.active() else { return };
    let Some((rating, flag)) = app.session.catalog.photo(id).map(|p| (p.rating, p.flag)) else { return };
    for n in 1..=5u8 {
        let r = Rect::from_center_size(pos2(row.left() + 28.0 + f32::from(n - 1) * 42.0, row.center().y), vec2(42.0, RATE_H));
        let on = n <= rating;
        paint_star(ui.painter(), r.center(), 10.0, if on { t.accent } else { t.text_dim.gamma_multiply(0.6) }, on);
        if tap(ui, &format!("star{n}"), r).clicked() {
            // tapping the star that is already the rating clears it
            let _ = app.run("photo.rate", json!({"rating": if n == rating { 0 } else { n }}));
        }
    }
    let flags =
        [("pick", crate::i18n::tr("Pick"), lightcraft_catalog::Flag::Pick), ("reject", crate::i18n::tr("Reject"), lightcraft_catalog::Flag::Reject)];
    let mut x = row.left() + 28.0 + 5.0 * 42.0 + 8.0;
    for (name, label, which) in flags {
        let w = 64.0;
        let r = Rect::from_min_size(pos2(x, row.top()), vec2(w, RATE_H));
        let on = flag == which;
        let color = if on { t.accent } else { t.text_dim };
        ui.painter().text(r.center(), Align2::CENTER_CENTER, label, t.font(14.0), color);
        if tap(ui, name, r).clicked() {
            let _ = app.run("photo.flag", json!({"flag": if on { "none" } else { name }}));
        }
        x += w;
    }
    let ex = Rect::from_min_max(pos2(row.right() - 72.0, row.top()), row.right_bottom());
    ui.painter().text(ex.center(), Align2::CENTER_CENTER, crate::i18n::tr("Export"), t.semibold(15.0), t.accent);
    if tap(ui, "export", ex).clicked() {
        export_jpeg(app, ui.ctx(), shell);
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

/// Aspect-ratio buttons, a rotate and the straighten angle. Dragging the crop box itself is the
/// loupe's (the crop overlay), so the sheet only sets what the box is locked to.
fn crop_sheet(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens) {
    let area = ui.max_rect();
    let ratios: [(&str, &str); 8] = [
        ("Original", "original"),
        ("Free", "free"),
        ("1:1", "1x1"),
        ("4:5", "4x5"),
        ("2:3", "2x3"),
        ("4:3", "4x3"),
        ("16:9", "16x9"),
        ("Rotate", "rotate"),
    ];
    let cell = vec2(area.width() / 4.0, 52.0);
    for (i, (label, arg)) in ratios.iter().enumerate() {
        let r = Rect::from_min_size(area.min + vec2((i % 4) as f32 * cell.x, 8.0 + (i / 4) as f32 * cell.y), cell);
        ui.painter().text(r.center(), Align2::CENTER_CENTER, crate::i18n::tr(label), t.font(16.0), t.text);
        if tap(ui, &format!("crop-{arg}"), r).clicked() {
            let _ = if *arg == "rotate" { app.run("crop.rotateAspect", json!({})) } else { app.run("crop.aspect", json!({"aspect": arg})) };
        }
    }
    let angle_area = Rect::from_min_max(pos2(area.left(), area.top() + 8.0 + 2.0 * cell.y), area.max);
    ui.scope_builder(UiBuilder::new().max_rect(angle_area), |ui| {
        let Some(id) = app.session.active() else { return };
        let d = app.session.develop_of(id).unwrap_or_default();
        if let Some(spec) = controls::find("crop.angle").filter(|s| controls::get(&d, s.id).is_some())
            && let Some(v) = controls::get(&d, spec.id)
        {
            let out = touch_slider(ui, t, spec, v);
            crate::panels::edit::apply_slider_out(app, spec, out, |app, v| app.run("develop.set", json!({"control": spec.id, "value": v})));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A retune of the engine's control groups must not leave a tool with an empty sheet.
    #[test]
    fn every_tool_has_sliders() {
        for tool in Tool::ALL.into_iter().filter(|t| !matches!(t, Tool::Presets | Tool::Crop)) {
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
    fn the_crop_sheet_offers_ratios_and_a_locked_ratio_sticks() {
        let mut h = open_tool("Crop");
        let text = h.painted_text();
        assert!(text.iter().any(|t| t == "16:9") && text.iter().any(|t| t == "Original"), "{text:?}");
        h.app.run("crop.aspect", serde_json::json!({"aspect": "1x1"})).expect("aspect");
        let id = h.app.session.active().expect("active");
        assert!(h.app.session.develop_of(id).is_some_and(|d| d.crop.aspect.is_some()));
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
        h.app.mobile.as_mut().expect("phone").tool = None;
        h.step();
        h.step();
        let text = h.painted_text();
        assert!(text.iter().any(|t| t == "Pick") && text.iter().any(|t| t == "Export"), "{text:?}");
    }
}
