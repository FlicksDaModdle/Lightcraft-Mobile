//! Glow ([`lightcraft_develop::Glow`]): the brightest parts of the photo spread a soft light around them, as
//! through a diffusion filter. It runs on the linear, white-balanced picture (after Lens Blur), so what glows is
//! what is bright in the scene, and the light it adds mixes like light.
//!
//! What glows: the part of each pixel's brightness (after Exposure) above a threshold set by Range, eased in over a
//! soft knee so nothing switches on at an edge. That light is spread at a smaller scale by the style's blurs (each
//! three box passes: close to a Gaussian; a round halo, a sideways smear, or rays across and down), tinted by
//! Warmth (and the style's own colour), scaled up again and added back. Diffusion, Halation and Motion also take
//! some of it from where it came from, so they move light rather than only add it.

use lightcraft_develop::{DevelopSettings, GlowStyle};
use lightcraft_raster::Rgb32f;
use rayon::prelude::*;

/// Whether the glow renders.
pub fn active(s: &DevelopSettings) -> bool {
    let g = &s.glow;
    s.section_enabled("effects") && g.amount.is_finite() && g.amount > 0.0
}

/// What [`apply`] reads from `s`, for render cache keys (empty when it doesn't render).
pub fn key(s: &DevelopSettings) -> String {
    if active(s) { format!("glow {:?} {}", s.glow, s.light.exposure) } else { String::new() }
}

/// The spread of the wide haze, in output pixels.
fn radius_px(s: &DevelopSettings, px_per_long: f64) -> f32 {
    let spread = (s.glow.spread.clamp(0.0, 100.0) / 100.0) as f32;
    let frac = 0.004 + 0.07 * spread.powf(1.5);
    let r = frac * px_per_long.max(1.0) as f32;
    if r.is_finite() { r.max(1.0) } else { 1.0 }
}

/// How a style spreads its light: the blurs (horizontal and vertical standard deviations, as multiples of the
/// Spread radius, and their weights), how much of the light that glows is taken out where it came from (0: the
/// glow is added; 1: light is moved, not added), the threshold's scale, the gain, and a base colour.
struct Shape {
    blurs: &'static [(f32, f32, f32)],
    moved: f32,
    threshold: f32,
    gain: f32,
    colour: [f32; 3],
    /// Spread radii per cell of the smaller scale the light is spread at (more: finer cells, for thin shapes).
    cells: f32,
}

fn shape(style: GlowStyle) -> Shape {
    match style {
        GlowStyle::Bloom => {
            Shape { blurs: &[(0.3, 0.3, 0.35), (1.0, 1.0, 0.65)], moved: 0.0, threshold: 1.0, gain: 1.6, colour: [1.0; 3], cells: 10.0 }
        }
        GlowStyle::Diffusion => Shape { blurs: &[(0.8, 0.8, 1.0)], moved: 1.0, threshold: 0.3, gain: 1.4, colour: [1.0; 3], cells: 8.0 },
        GlowStyle::Halation => {
            Shape { blurs: &[(0.25, 0.25, 0.5), (0.5, 0.5, 0.5)], moved: 0.55, threshold: 1.0, gain: 2.2, colour: [1.0, 0.3, 0.08], cells: 20.0 }
        }
        GlowStyle::Motion => Shape { blurs: &[(2.5, 0.02, 1.0)], moved: 0.6, threshold: 0.8, gain: 1.6, colour: [1.0; 3], cells: 8.0 },
        GlowStyle::Streak => {
            Shape { blurs: &[(3.0, 0.02, 0.5), (0.02, 3.0, 0.5)], moved: 0.0, threshold: 1.2, gain: 2.4, colour: [1.0; 3], cells: 14.0 }
        }
    }
}

/// How far from a bright pixel the glow reaches, in output pixels (0 when it doesn't render): what a window render
/// must read around itself.
pub fn reach_px(s: &DevelopSettings, px_per_long: f64) -> usize {
    if !active(s) {
        return 0;
    }
    let widest = shape(s.glow.style).blurs.iter().map(|b| b.0.max(b.1)).fold(0f32, f32::max);
    (radius_px(s, px_per_long) * widest * 2.2).ceil() as usize + 2
}

/// [`crate::PixelWindow`] `win` grown by the glow's reach, within the `full_w × full_h` output.
pub fn window_for_reads(s: &DevelopSettings, full_w: usize, full_h: usize, px_per_long: f64, win: crate::PixelWindow) -> crate::PixelWindow {
    let m = reach_px(s, px_per_long);
    if m == 0 {
        return win;
    }
    let (x0, y0) = (win.x.saturating_sub(m), win.y.saturating_sub(m));
    let x1 = win.x.saturating_add(win.w).saturating_add(m).min(full_w.max(1));
    let y1 = win.y.saturating_add(win.h).saturating_add(m).min(full_h.max(1));
    crate::PixelWindow { x: x0, y: y0, w: x1.saturating_sub(x0).max(1), h: y1.saturating_sub(y0).max(1) }
}

const LUMA: [f32; 3] = [0.2126, 0.7152, 0.0722];

/// Add the glow of `s` to `img` (linear, `px_per_long` output pixels along the long edge).
pub fn apply(img: &mut Rgb32f, s: &DevelopSettings, px_per_long: f64) {
    if !active(s) || img.width == 0 || img.height == 0 {
        return;
    }
    let g = &s.glow;
    let sh_ = shape(g.style);
    let amount = (g.amount.clamp(0.0, 100.0) / 100.0) as f32;
    // the threshold, in brightness after Exposure: Range 0 lets only what is far past white glow, 100 the midtones
    let threshold = 2.0 * 0.125f32.powf((g.range.clamp(0.0, 100.0) / 100.0) as f32) * sh_.threshold;
    let exposure = 2f32.powf(s.light.exposure.clamp(-10.0, 10.0) as f32);
    let knee = threshold * 0.5;
    let warm = (g.warmth.clamp(-100.0, 100.0) / 100.0) as f32;
    let tint = [(1.0 + 0.4 * warm) * sh_.colour[0], (1.0 + 0.06 * warm) * sh_.colour[1], (1.0 - 0.45 * warm) * sh_.colour[2]];

    let radius = radius_px(s, px_per_long);
    // spread at a smaller scale, fine enough for the style's narrowest blur
    let f = ((radius / sh_.cells).floor() as usize).clamp(1, 64);
    let (w, h) = (img.width, img.height);
    let (sw, sh) = (w.div_ceil(f), h.div_ceil(f));

    // the light above the threshold, averaged into f × f cells
    let mut bright = vec![[0f32; 3]; sw * sh];
    bright.par_chunks_mut(sw).enumerate().for_each(|(cy, row)| {
        let y0 = cy * f;
        let y1 = (y0 + f).min(h);
        for (cx, cell) in row.iter_mut().enumerate() {
            let x0 = cx * f;
            let x1 = (x0 + f).min(w);
            let mut acc = [0f32; 3];
            for y in y0..y1 {
                for p in &img.data[y * w + x0..y * w + x1] {
                    let k = over(p, exposure, threshold, knee);
                    for c in 0..3 {
                        acc[c] += p[c].max(0.0) * k;
                    }
                }
            }
            let n = ((y1 - y0) * (x1 - x0)).max(1) as f32;
            *cell = acc.map(|v| v / n);
        }
    });

    let rc = radius / f as f32;
    let mut spread = vec![[0f32; 3]; sw * sh];
    for &(sx, sy, weight) in sh_.blurs {
        let b = blur(&bright, sw, sh, rc * sx, rc * sy);
        for (o, v) in spread.iter_mut().zip(&b) {
            for c in 0..3 {
                o[c] += weight * v[c];
            }
        }
    }
    let gain = amount * sh_.gain;
    let glow: Vec<[f32; 3]> = spread.iter().map(|v| std::array::from_fn(|c| v[c] * tint[c] * gain)).collect();
    let moved = sh_.moved * gain;

    // back to full size (bilinear between cell centres) and added; a style that moves light takes it away from
    // where it came from first
    img.data.par_chunks_mut(w).enumerate().for_each(|(y, row)| {
        let fy = ((y as f32 + 0.5) / f as f32 - 0.5).clamp(0.0, (sh - 1) as f32);
        let (y0, ty) = (fy.floor() as usize, fy - fy.floor());
        let y1 = (y0 + 1).min(sh - 1);
        for (x, p) in row.iter_mut().enumerate() {
            let fx = ((x as f32 + 0.5) / f as f32 - 0.5).clamp(0.0, (sw - 1) as f32);
            let (x0, tx) = (fx.floor() as usize, fx - fx.floor());
            let x1 = (x0 + 1).min(sw - 1);
            let (a, b, c, d) = (glow[y0 * sw + x0], glow[y0 * sw + x1], glow[y1 * sw + x0], glow[y1 * sw + x1]);
            let take = if moved > 0.0 { over(p, exposure, threshold, knee) * moved.min(1.0) } else { 0.0 };
            for ch in 0..3 {
                let top = a[ch] + (b[ch] - a[ch]) * tx;
                let bottom = c[ch] + (d[ch] - c[ch]) * tx;
                let v = top + (bottom - top) * ty;
                if v.is_finite() && p[ch].is_finite() {
                    p[ch] = p[ch] - p[ch].max(0.0) * take * tint[ch].min(1.0) + v;
                }
            }
        }
    });
}

/// The share of pixel `p`'s light above the threshold (0 to 1), eased in over a soft knee.
fn over(p: &[f32; 3], exposure: f32, threshold: f32, knee: f32) -> f32 {
    let l = (LUMA[0] * p[0] + LUMA[1] * p[1] + LUMA[2] * p[2]) * exposure;
    if !(l.is_finite() && l > 0.0) {
        return 0.0;
    }
    let x = (l - threshold + knee).clamp(0.0, 2.0 * knee);
    ((x * x / (4.0 * knee)).max(l - threshold).max(0.0) / l).min(1.0)
}

/// A Gaussian-like blur of standard deviations about `sx` and `sy` cells: three box passes each way, edges held.
fn blur(src: &[[f32; 3]], w: usize, h: usize, sx: f32, sy: f32) -> Vec<[f32; 3]> {
    // three boxes of width 2r+1 have variance 3·((2r+1)² − 1)/12 = r(r+1)
    let r_of = |sigma: f32| ((sigma * sigma + 0.25).sqrt() - 0.5).round().max(0.0) as usize;
    let (rx, ry) = (r_of(sx), r_of(sy));
    let mut a = src.to_vec();
    for _ in 0..3 {
        if rx > 0 {
            a.par_chunks_mut(w).for_each(|row| box_line(row, rx));
        }
        if ry > 0 {
            let mut t = transpose(&a, w, h);
            t.par_chunks_mut(h).for_each(|col| box_line(col, ry));
            a = transpose(&t, h, w);
        }
    }
    a
}

/// A box average of radius `r` along `line`, the end values held beyond its ends.
fn box_line(line: &mut [[f32; 3]], r: usize) {
    let n = line.len();
    if n == 0 {
        return;
    }
    let src = line.to_vec();
    let at = |i: isize| src[i.clamp(0, n as isize - 1) as usize];
    let mut sum = [0f32; 3];
    for i in -(r as isize)..=(r as isize) {
        let v = at(i);
        for c in 0..3 {
            sum[c] += v[c];
        }
    }
    let k = 1.0 / (2 * r + 1) as f32;
    for i in 0..n {
        line[i] = sum.map(|v| v * k);
        let (add, sub) = (at(i as isize + r as isize + 1), at(i as isize - r as isize));
        for c in 0..3 {
            sum[c] += add[c] - sub[c];
        }
    }
}

fn transpose(a: &[[f32; 3]], w: usize, h: usize) -> Vec<[f32; 3]> {
    let mut t = vec![[0f32; 3]; a.len()];
    for y in 0..h {
        for x in 0..w {
            t[x * h + y] = a[y * w + x];
        }
    }
    t
}

#[cfg(test)]
mod tests {
    use super::*;

    fn on(amount: f64) -> DevelopSettings {
        let mut s = DevelopSettings::default();
        s.glow.amount = amount;
        s
    }

    fn lamp(w: usize, h: usize) -> Rgb32f {
        let mut img = Rgb32f::filled(w, h, [0.05; 3]);
        for y in 45..55 {
            for x in 45..55 {
                img.set(x, y, [8.0; 3]);
            }
        }
        img
    }

    /// A bright light spreads into the dark around it, more the larger the Size, while dark areas far from any
    /// light, and a photo with nothing bright, are left alone.
    #[test]
    fn bright_light_spreads_and_dark_stays() {
        let (w, h) = (300, 300);
        let mut small = lamp(w, h);
        let mut s = on(80.0);
        s.glow.spread = 20.0;
        apply(&mut small, &s, w as f64);
        let mut large = lamp(w, h);
        s.glow.spread = 90.0;
        apply(&mut large, &s, w as f64);
        let near = |img: &Rgb32f| img.get(60, 50)[1];
        assert!(near(&small) > 0.06, "{}", near(&small));
        assert!(large.get(110, 50)[1] > small.get(110, 50)[1], "a larger glow reaches further");
        assert!((small.get(280, 280)[1] - 0.05).abs() < 0.01, "far away stays dark: {}", small.get(280, 280)[1]);

        let mut dim = Rgb32f::filled(w, h, [0.1; 3]);
        apply(&mut dim, &s, w as f64);
        assert!(dim.data.iter().all(|p| (p[1] - 0.1).abs() < 1e-3), "nothing bright, nothing glows");
    }

    /// Warmth tints the glow: warm adds more red than blue around a white light, cool the other way.
    #[test]
    fn warmth_tints_the_glow() {
        let (w, h) = (200, 200);
        let mut s = on(80.0);
        s.glow.warmth = 80.0;
        let mut warm = lamp(w, h);
        apply(&mut warm, &s, w as f64);
        let p = warm.get(65, 50);
        assert!(p[0] > p[2], "{p:?}");
        s.glow.warmth = -80.0;
        let mut cool = lamp(w, h);
        apply(&mut cool, &s, w as f64);
        let p = cool.get(65, 50);
        assert!(p[2] > p[0], "{p:?}");
    }

    /// Each style shapes the light its own way: Motion smears it sideways, Streak sends rays across and down but
    /// not along the diagonals, Halation glows red, and Diffusion moves light (it softens rather than brightens).
    #[test]
    fn styles_shape_the_light() {
        let (w, h) = (300, 300);
        let run = |style: GlowStyle| {
            let mut s = on(80.0);
            s.glow.style = style;
            let mut img = lamp(w, h);
            apply(&mut img, &s, w as f64);
            img
        };
        let motion = run(GlowStyle::Motion);
        assert!(motion.get(80, 50)[1] > 2.0 * motion.get(50, 80)[1], "sideways {} vs down {}", motion.get(80, 50)[1], motion.get(50, 80)[1]);
        let streak = run(GlowStyle::Streak);
        let (across, diagonal) = (streak.get(85, 50)[1], streak.get(75, 75)[1]);
        assert!(across > 2.0 * (diagonal - 0.05).max(1e-4) + 0.05, "across {across} vs diagonal {diagonal}");
        let halation = run(GlowStyle::Halation);
        let p = halation.get(60, 50);
        assert!(p[0] > 2.0 * p[2], "{p:?}");
        let total = |img: &Rgb32f| img.data.iter().map(|p| f64::from(p[1])).sum::<f64>();
        let (before, bloom, diffusion) = (total(&lamp(w, h)), total(&run(GlowStyle::Bloom)), total(&run(GlowStyle::Diffusion)));
        assert!(bloom > before * 1.05, "bloom adds light");
        assert!((diffusion - before).abs() < (bloom - before) * 0.5, "diffusion mostly moves it: {before} → {diffusion}");
    }

    /// Off (no amount, or the Effects section hidden), the picture is untouched; odd sizes and values don't panic.
    #[test]
    fn off_changes_nothing_and_odd_input_is_safe() {
        let before = lamp(100, 100);
        let mut img = before.clone();
        apply(&mut img, &on(0.0), 100.0);
        assert_eq!(img.data, before.data);
        let mut s = on(80.0);
        s.set_section_enabled("effects", false);
        apply(&mut img, &s, 100.0);
        assert_eq!(img.data, before.data);
        for (w, h) in [(1, 1), (1, 40), (37, 1), (3, 3)] {
            let mut tiny = Rgb32f::filled(w, h, [f32::NAN, f32::INFINITY, 4.0]);
            apply(&mut tiny, &on(100.0), 1e9);
            apply(&mut tiny, &on(100.0), f64::NAN);
        }
    }
}
