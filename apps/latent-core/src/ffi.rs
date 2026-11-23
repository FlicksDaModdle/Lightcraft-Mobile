//! The C interface (declared in `include/latent.h`). Strings are UTF-8 and NUL-terminated; every
//! string or image this returns is the caller's, to give back with [`latent_string_free`] or
//! [`latent_image_free`]. A null argument where one is needed gives a null or an error answer, never
//! a crash.
#![allow(unsafe_code)]

use std::ffi::{CStr, CString, c_char};
use std::path::Path;

use crate::{Core, HIST_BINS, HdrImage, Image};

/// A rendered photo as C sees it.
#[repr(C)]
pub struct LatentImage {
    pub width: u32,
    pub height: u32,
    /// `width * height * 4` bytes, RGBA, rows top to bottom.
    pub rgba: *mut u8,
    pub rgba_len: usize,
    /// Red, green and blue histograms, `LATENT_HIST_BINS` (256) each.
    pub hist: *mut u32,
    pub hist_len: usize,
}

/// # Safety
/// `p` is null or a NUL-terminated string that stays valid for the call.
unsafe fn text<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    // SAFETY: non-null, and the caller promises a NUL-terminated string valid for the call
    unsafe { CStr::from_ptr(p) }.to_str().ok()
}

fn give_string(s: String) -> *mut c_char {
    // a NUL inside JSON can only come from a string value: escape it rather than fail
    CString::new(s.replace('\0', "\\u0000")).map_or(std::ptr::null_mut(), CString::into_raw)
}

fn give_image(r: Result<Image, String>) -> *mut LatentImage {
    let Ok(img) = r else { return std::ptr::null_mut() };
    let mut rgba = img.rgba.into_boxed_slice();
    let mut hist = img.hist.into_boxed_slice();
    debug_assert_eq!(hist.len(), HIST_BINS * 3);
    let out = LatentImage {
        width: u32::try_from(img.width).unwrap_or(0),
        height: u32::try_from(img.height).unwrap_or(0),
        rgba: rgba.as_mut_ptr(),
        rgba_len: rgba.len(),
        hist: hist.as_mut_ptr(),
        hist_len: hist.len(),
    };
    std::mem::forget(rgba);
    std::mem::forget(hist);
    Box::into_raw(Box::new(out))
}

/// # Safety
/// `core` is null or came from [`latent_open`] or [`latent_open_demo`] and was not closed.
unsafe fn core<'a>(core: *const Core) -> Option<&'a Core> {
    // SAFETY: the caller promises a live pointer from latent_open
    unsafe { core.as_ref() }
}

/// Open the library in `dir` (null: the default library folder). `problem`, if not null, receives
/// null or a message saying why the library couldn't be opened (an empty library is used instead).
///
/// # Safety
/// `dir` is null or a NUL-terminated string; `problem` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_open(dir: *const c_char, problem: *mut *mut c_char) -> *mut Core {
    // SAFETY: as documented above
    let dir = unsafe { text(dir) }.map(Path::new);
    let (c, p) = Core::open(dir);
    if !problem.is_null() {
        // SAFETY: the caller promises `problem` is writable
        unsafe { *problem = p.map_or(std::ptr::null_mut(), give_string) };
    }
    Box::into_raw(Box::new(c))
}

/// An in-memory library with demo photos.
#[unsafe(no_mangle)]
pub extern "C" fn latent_open_demo() -> *mut Core {
    Box::into_raw(Box::new(Core::demo()))
}

/// Close a library opened by [`latent_open`].
///
/// # Safety
/// `core` is null or from [`latent_open`]; it is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_close(core: *mut Core) {
    if !core.is_null() {
        // SAFETY: from Box::into_raw in latent_open, and not used again
        drop(unsafe { Box::from_raw(core) });
    }
}

/// Run an engine command; `params` is a JSON object or null. Returns `{"ok": …}` or `{"error": …}`.
///
/// # Safety
/// `core` from [`latent_open`]; `cmd` and `params` null or NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_execute(core: *const Core, cmd: *const c_char, params: *const c_char) -> *mut c_char {
    // SAFETY: as documented above
    let (c, cmd, params) = unsafe { (self::core(core), text(cmd), text(params)) };
    match (c, cmd) {
        (Some(c), Some(cmd)) => give_string(c.execute(cmd, params.unwrap_or(""))),
        _ => give_string(r#"{"error":"no library or no command"}"#.to_string()),
    }
}

/// Render photo `id` with its edits (`original`: as it was before them) to fit the size. Null on failure.
///
/// # Safety
/// `core` from [`latent_open`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_render(core: *const Core, id: u64, max_w: u32, max_h: u32, original: bool) -> *mut LatentImage {
    // SAFETY: as documented above
    let Some(c) = (unsafe { self::core(core) }) else { return std::ptr::null_mut() };
    let (w, h) = (max_w as usize, max_h as usize);
    give_image(if original { c.render_original(id, w, h) } else { c.render(id, w, h) })
}

/// Photo `id` with mask `mask` tinted red over it. Null on failure.
///
/// # Safety
/// `core` from [`latent_open`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_render_mask(core: *const Core, id: u64, max_w: u32, max_h: u32, mask: u32) -> *mut LatentImage {
    // SAFETY: as documented above
    let Some(c) = (unsafe { self::core(core) }) else { return std::ptr::null_mut() };
    give_image(c.render_mask(id, max_w as usize, max_h as usize, mask))
}

/// Photo `id` with mask `mask` drawn as `view` ("color", "colorOnBw", "imageOnBlack",
/// "imageOnWhite", "whiteOnBlack") in `rgb` (0xRRGGBB) at `opacity` (0..100). Null on failure.
///
/// # Safety
/// `core` from [`latent_open`]; `view` NUL-terminated or null (the colour view).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_render_mask_as(
    core: *const Core,
    id: u64,
    max_w: u32,
    max_h: u32,
    mask: u32,
    view: *const c_char,
    rgb: u32,
    opacity: u8,
) -> *mut LatentImage {
    // SAFETY: as documented above
    let (Some(c), v) = (unsafe { self::core(core) }, unsafe { text(view) }) else { return std::ptr::null_mut() };
    let [_, r, g, b] = rgb.to_be_bytes();
    let look = crate::MaskLook { view: v.unwrap_or("color"), color: [r, g, b], opacity };
    give_image(c.render_mask_as(id, max_w as usize, max_h as usize, mask, look))
}

/// Photo `id` uncropped and unstraightened (what the crop box is drawn over). Null on failure.
///
/// # Safety
/// `core` from [`latent_open`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_render_uncropped(core: *const Core, id: u64, max_w: u32, max_h: u32) -> *mut LatentImage {
    // SAFETY: as documented above
    let Some(c) = (unsafe { self::core(core) }) else { return std::ptr::null_mut() };
    give_image(c.render_uncropped(id, max_w as usize, max_h as usize))
}

/// A preview of preset `preset` (its id) on photo `id`, without editing the photo. Null on failure.
///
/// # Safety
/// `core` from [`latent_open`]; `preset` a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_preset_thumb(core: *const Core, id: u64, preset: *const c_char, long_edge: u32) -> *mut LatentImage {
    // SAFETY: as documented above
    let (Some(c), Some(preset)) = (unsafe { self::core(core) }, unsafe { text(preset) }) else { return std::ptr::null_mut() };
    give_image(c.preset_thumb(id, preset, long_edge as usize))
}

/// A thumbnail of photo `id`, its long edge about `long_edge`. Null on failure.
///
/// # Safety
/// `core` from [`latent_open`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_thumb(core: *const Core, id: u64, long_edge: u32) -> *mut LatentImage {
    // SAFETY: as documented above
    let Some(c) = (unsafe { self::core(core) }) else { return std::ptr::null_mut() };
    give_image(c.thumb(id, long_edge as usize))
}

/// Give back an image from [`latent_render`] or [`latent_thumb`].
///
/// # Safety
/// `img` is null or from those functions, and not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_image_free(img: *mut LatentImage) {
    if img.is_null() {
        return;
    }
    // SAFETY: from Box::into_raw in give_image; the slices were boxed with exactly these lengths
    unsafe {
        let img = Box::from_raw(img);
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(img.rgba, img.rgba_len)));
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(img.hist, img.hist_len)));
    }
}

/// Give back a string from this library.
///
/// # Safety
/// `s` is null or from this library, and not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_string_free(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: from CString::into_raw in give_string
        drop(unsafe { CString::from_raw(s) });
    }
}

/// An HDR render as C sees it: half-float RGBA in linear light, SDR white at 1.0.
#[repr(C)]
pub struct LatentHdrImage {
    pub width: u32,
    pub height: u32,
    /// `width * height * 4` half floats (IEEE bits), linear RGB plus alpha.
    pub rgba16f: *mut u16,
    pub rgba16f_len: usize,
    /// Red, green, blue histograms over SDR then HDR, `LATENT_HIST_BINS` each.
    pub hist: *mut u32,
    pub hist_len: usize,
    /// The brightest value the render may reach.
    pub peak: f32,
}

/// Render photo `id` in HDR to fit the size. Null when HDR is off for it or there is no HDR render.
///
/// # Safety
/// `core` from [`latent_open`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_render_hdr(core: *const Core, id: u64, max_w: u32, max_h: u32) -> *mut LatentHdrImage {
    // SAFETY: as documented above
    let Some(c) = (unsafe { self::core(core) }) else { return std::ptr::null_mut() };
    let Ok(HdrImage { width, height, rgba16f, hist, peak }) = c.render_hdr(id, max_w as usize, max_h as usize) else {
        return std::ptr::null_mut();
    };
    let mut px = rgba16f.into_boxed_slice();
    let mut hist = hist.into_boxed_slice();
    let out = LatentHdrImage {
        width: u32::try_from(width).unwrap_or(0),
        height: u32::try_from(height).unwrap_or(0),
        rgba16f: px.as_mut_ptr(),
        rgba16f_len: px.len(),
        hist: hist.as_mut_ptr(),
        hist_len: hist.len(),
        peak,
    };
    std::mem::forget(px);
    std::mem::forget(hist);
    Box::into_raw(Box::new(out))
}

/// Give back an image from [`latent_render_hdr`].
///
/// # Safety
/// `img` is null or from [`latent_render_hdr`], and not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_hdr_image_free(img: *mut LatentHdrImage) {
    if img.is_null() {
        return;
    }
    // SAFETY: from Box::into_raw in latent_render_hdr; the slices were boxed with exactly these lengths
    unsafe {
        let img = Box::from_raw(img);
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(img.rgba16f, img.rgba16f_len)));
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(img.hist, img.hist_len)));
    }
}

/// Look for the SAM 3 model (AI masks) in `dir`.
///
/// # Safety
/// `core` from [`latent_open`]; `dir` a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_set_ai_model_dir(core: *const Core, dir: *const c_char) {
    // SAFETY: as documented above
    if let (Some(c), Some(d)) = (unsafe { self::core(core) }, unsafe { text(dir) }) {
        c.set_ai_model_dir(Path::new(d));
    }
}

/// Take in finished background work; returns `{"changed", "messages", "busy"}` (give it back
/// with [`latent_string_free`]).
///
/// # Safety
/// `core` from [`latent_open`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_poll(core: *const Core) -> *mut c_char {
    // SAFETY: as documented above
    match unsafe { self::core(core) } {
        Some(c) => give_string(c.poll()),
        None => give_string(r#"{"changed":false,"messages":[],"busy":false}"#.to_string()),
    }
}

/// An exported file: its name and bytes (give it back with [`latent_export_free`]).
#[repr(C)]
pub struct LatentExport {
    pub name: *mut c_char,
    pub bytes: *mut u8,
    pub len: usize,
}

/// Export photo `id` with `options` (the engine's export options as JSON; see `Core::export`).
/// Null on failure, and `error` (if not null) receives why.
///
/// # Safety
/// `core` from [`latent_open`]; `options` NUL-terminated or null; `error` null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_export(core: *const Core, id: u64, options: *const c_char, error: *mut *mut c_char) -> *mut LatentExport {
    // SAFETY: as documented above
    let (c, o) = unsafe { (self::core(core), text(options)) };
    let result = match c {
        Some(c) => c.export(id, o.unwrap_or("")),
        None => Err("no library".to_string()),
    };
    match result {
        Ok((name, bytes)) => {
            let mut b = bytes.into_boxed_slice();
            let out = LatentExport { name: give_string(name), bytes: b.as_mut_ptr(), len: b.len() };
            std::mem::forget(b);
            Box::into_raw(Box::new(out))
        }
        Err(e) => {
            if !error.is_null() {
                // SAFETY: the caller promises `error` is writable
                unsafe { *error = give_string(e) };
            }
            std::ptr::null_mut()
        }
    }
}

/// Give back an export from [`latent_export`].
///
/// # Safety
/// `e` is null or from [`latent_export`], and not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_export_free(e: *mut LatentExport) {
    if e.is_null() {
        return;
    }
    // SAFETY: from Box::into_raw in latent_export; the name and bytes were made there
    unsafe {
        let e = Box::from_raw(e);
        latent_string_free(e.name);
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(e.bytes, e.len)));
    }
}

/// Give photo `id` a depth map of `w × h` bytes (0 near … 255 far, upright); a null or short
/// buffer takes it away.
///
/// # Safety
/// `core` from [`latent_open`]; `data` null or `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_set_depth(core: *const Core, id: u64, w: u32, h: u32, data: *const u8, len: usize) {
    // SAFETY: as documented above
    let Some(c) = (unsafe { self::core(core) }) else { return };
    let bytes: &[u8] = if data.is_null() || len == 0 {
        &[]
    } else {
        // SAFETY: the caller promises `len` readable bytes at `data`
        unsafe { std::slice::from_raw_parts(data, len) }
    };
    c.set_depth(id, w as usize, h as usize, bytes);
}

/// The photo's depth map as the photo is framed, near white, far black. Null on failure.
///
/// # Safety
/// `core` from [`latent_open`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn latent_render_depth(core: *const Core, id: u64, max_w: u32, max_h: u32) -> *mut LatentImage {
    // SAFETY: as documented above
    let Some(c) = (unsafe { self::core(core) }) else { return std::ptr::null_mut() };
    give_image(c.render_depth(id, max_w as usize, max_h as usize))
}
