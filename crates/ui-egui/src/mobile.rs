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
    Light,
    Color,
    Effects,
    Detail,
    Optics,
    Geometry,
}

impl Tool {
    const ALL: [Tool; 6] = [Tool::Light, Tool::Color, Tool::Effects, Tool::Detail, Tool::Optics, Tool::Geometry];

    fn label(self) -> &'static str {
        match self {
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
    /// Simulated safe-area insets (top, right, bottom, left) for a run on a desktop; `None` uses what
    /// the device reports.
    insets: Option<[f32; 4]>,
}

impl Default for Shell {
    fn default() -> Self {
        Shell { screen: Screen::Library, tool: None, insets: None }
    }
}

impl Shell {
    /// For a desktop window or a headless screenshot: an iPhone's status bar and home indicator.
    pub fn preview() -> Self {
        Shell { insets: Some([47.0, 0.0, 34.0, 0.0]), ..Shell::default() }
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
    let [top, right, bottom, left] = insets(&ctx, &shell);
    let safe = Rect::from_min_max(full.min + vec2(left, top), full.max - vec2(right, bottom));
    if shell.screen == Screen::Photo && app.session.active().is_none() {
        shell.screen = Screen::Library;
    }
    match shell.screen {
        Screen::Library => library(app, ui, &t, safe, &mut shell),
        Screen::Photo => photo(app, ui, &t, safe, &mut shell),
    }
    app.mobile = Some(shell);
}

/// A tappable rectangle that is not a widget of its own.
fn tap(ui: &mut egui::Ui, name: &str, rect: Rect) -> egui::Response {
    let id = ui.scope_id().with(name);
    ui.interact(rect, id, Sense::click())
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
        add_photos(app, ui.ctx());
    }
    let body = Rect::from_min_max(pos2(safe.left(), header.bottom()), safe.max);
    ui.scope_builder(UiBuilder::new().max_rect(body), |ui| {
        ui.set_clip_rect(body.intersect(ui.clip_rect()));
        grid(app, ui, t, &ids, shell);
    });
}

/// Add photos from the device. Until the Photos and Files pickers exist (docs/ios/PLAN.md, phase 1)
/// this says so instead of pretending to work.
fn add_photos(app: &mut LightcraftApp, ctx: &egui::Context) {
    let picked = app.services.pick_files.as_mut().map(|pick| pick()).unwrap_or_default();
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
    let canvas = Rect::from_min_max(pos2(safe.left(), header.bottom()), pos2(safe.right(), sheet.top()));

    // the loupe draws the photo; the desktop's own side panels, filmstrip and full screen stay off
    app.ui.filmstrip = false;
    app.ui.fullscreen = false;
    app.ui.right = RightPanel::None;
    ui.painter().rect_filled(canvas, 0.0, Color32::BLACK);
    ui.scope_builder(UiBuilder::new().max_rect(canvas), |ui| {
        ui.set_clip_rect(canvas.intersect(ui.clip_rect()));
        crate::panels::detail::show(app, ui);
    });

    header_bar(app, ui, t, header, shell);
    if let Some(tool) = shell.tool {
        ui.painter().rect_filled(sheet, 0.0, t.chrome);
        ui.painter().line_segment([sheet.left_top(), sheet.right_top()], Stroke::new(1.0, t.text_dim.gamma_multiply(0.35)));
        ui.scope_builder(UiBuilder::new().max_rect(sheet), |ui| {
            ui.set_clip_rect(sheet.intersect(ui.clip_rect()));
            sheet_of(app, ui, t, tool);
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
fn sheet_of(app: &mut LightcraftApp, ui: &mut egui::Ui, t: &Tokens, tool: Tool) {
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A retune of the engine's control groups must not leave a tool with an empty sheet.
    #[test]
    fn every_tool_has_sliders() {
        for tool in Tool::ALL {
            let n: usize = tool.sections().iter().map(|(section, _)| controls::in_section(*section).count()).sum();
            assert!(n > 0, "{} has no controls", tool.label());
        }
    }
}
