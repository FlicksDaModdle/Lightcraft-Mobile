//! The iPhone Photos picker (PHPicker), driven through the Objective-C runtime directly so only
//! objc2, block2 and Foundation are needed. It copies the chosen photos into a folder and reports
//! their paths.
//!
//! This crate is allowed `unsafe` (the Objective-C calls, in `ios`), like `crates/sysmem`. Its API is
//! safe, and off iOS [`pick_photos`] says it cannot show a picker.
#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

use std::path::PathBuf;

/// Called with the copied files' paths (empty when the user cancelled), on any thread.
pub type Done = Box<dyn FnOnce(Vec<String>) + Send>;

/// Show the Photos picker over the app. `dest` receives copies of the chosen photos and `done` gets
/// their paths. Call it on the main thread; false means it could not be shown.
pub fn pick_photos(dest: PathBuf, done: Done) -> bool {
    #[cfg(target_os = "ios")]
    {
        ios::pick_photos(dest, done)
    }
    #[cfg(not(target_os = "ios"))]
    {
        let _ = (dest, done);
        false
    }
}

#[cfg(target_os = "ios")]
#[allow(unsafe_code)]
mod ios {

    use std::cell::RefCell;
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};

    use block2::RcBlock;
    use objc2::rc::Retained;
    use objc2::runtime::{AnyClass, AnyObject, NSObject};
    use objc2::{DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send};
    use objc2_foundation::{NSArray, NSError, NSObjectProtocol, NSString, NSURL};

    #[cfg(target_vendor = "apple")]
    #[link(name = "PhotosUI", kind = "framework")]
    unsafe extern "C" {}

    use super::Done;

    struct Ivars {
        dest: PathBuf,
        done: RefCell<Option<Done>>,
    }

    define_class!(
        #[unsafe(super(NSObject))]
        #[thread_kind = MainThreadOnly]
        #[name = "LightCraftPickerDelegate"]
        #[ivars = Ivars]
        struct Delegate;

        unsafe impl NSObjectProtocol for Delegate {}

        impl Delegate {
            // PHPickerViewControllerDelegate; the protocol is informal here, the picker only checks
            // that the delegate responds to the selector
            #[unsafe(method(picker:didFinishPicking:))]
            fn picker_did_finish(&self, picker: &AnyObject, results: &NSArray<AnyObject>) {
                let _: () = unsafe { msg_send![picker, dismissViewControllerAnimated: true, completion: std::ptr::null::<AnyObject>()] };
                let done = self.ivars().done.borrow_mut().take();
                let dest = self.ivars().dest.clone();
                if let Some(done) = done {
                    copy_results(results, dest, done);
                }
                // the picker held us weakly; we can go
                LIVE.with(|l| l.borrow_mut().retain(|d| !std::ptr::eq(&**d, self)));
            }
        }
    );

    thread_local! {
        static LIVE: RefCell<Vec<Retained<Delegate>>> = const { RefCell::new(Vec::new()) };
    }

    struct Collect {
        left: usize,
        paths: Vec<String>,
        done: Option<Done>,
    }

    fn finish_one(state: &Arc<Mutex<Collect>>, path: Option<String>) {
        let Ok(mut s) = state.lock() else { return };
        s.paths.extend(path);
        s.left = s.left.saturating_sub(1);
        if s.left == 0
            && let Some(done) = s.done.take()
        {
            let mut paths = std::mem::take(&mut s.paths);
            paths.sort();
            done(paths);
        }
    }

    /// Load each result's image file (the system deletes its copy once the handler returns, so copy it
    /// inside the handler) into `dest`.
    fn copy_results(results: &NSArray<AnyObject>, dest: PathBuf, done: Done) {
        let n = results.count();
        if n == 0 {
            done(Vec::new());
            return;
        }
        let state = Arc::new(Mutex::new(Collect { left: n, paths: Vec::new(), done: Some(done) }));
        let _ = std::fs::create_dir_all(&dest);
        let type_id = NSString::from_str("public.image");
        for i in 0..n {
            let result = results.objectAtIndex(i);
            let provider: Retained<AnyObject> = unsafe { msg_send![&*result, itemProvider] };
            let (state, dest) = (state.clone(), dest.clone());
            let handler = RcBlock::new(move |url: *mut NSURL, _err: *mut NSError| {
                let copied = unsafe { url.as_ref() }.and_then(|url| {
                    let src = url.path()?.to_string();
                    let name = std::path::Path::new(&src).file_name()?.to_string_lossy().into_owned();
                    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis());
                    let to = dest.join(format!("{stamp}-{i}-{name}"));
                    std::fs::copy(&src, &to).ok()?;
                    Some(to.to_string_lossy().into_owned())
                });
                finish_one(&state, copied);
            });
            let _progress: Option<Retained<AnyObject>> =
                unsafe { msg_send![&*provider, loadFileRepresentationForTypeIdentifier: &*type_id, completionHandler: &*handler] };
        }
    }

    /// Show the Photos picker over the app. `dest` receives copies of the chosen photos and `done` gets
    /// their paths. Call it on the main thread; false means it could not be shown.
    pub(super) fn pick_photos(dest: PathBuf, done: Done) -> bool {
        let Some(mtm) = MainThreadMarker::new() else { return false };
        let (Some(config_class), Some(picker_class)) = (AnyClass::get(c"PHPickerConfiguration"), AnyClass::get(c"PHPickerViewController")) else {
            return false;
        };
        let Some(root) = top_view_controller() else { return false };
        unsafe {
            let config: Retained<AnyObject> = msg_send![config_class, new];
            // 0 = as many as the user likes
            let _: () = msg_send![&*config, setSelectionLimit: 0isize];
            let picker: Option<Retained<AnyObject>> = msg_send![msg_send![picker_class, alloc], initWithConfiguration: &*config];
            let Some(picker) = picker else { return false };
            let delegate = mtm.alloc::<Delegate>().set_ivars(Ivars { dest, done: RefCell::new(Some(done)) });
            let delegate: Retained<Delegate> = msg_send![super(delegate), init];
            let _: () = msg_send![&*picker, setDelegate: &*delegate];
            LIVE.with(|l| l.borrow_mut().push(delegate));
            let _: () = msg_send![&*root, presentViewController: &*picker, animated: true, completion: std::ptr::null::<AnyObject>()];
        }
        true
    }

    /// The view controller on top of the app's key window.
    fn top_view_controller() -> Option<Retained<AnyObject>> {
        unsafe {
            let app: Retained<AnyObject> = msg_send![AnyClass::get(c"UIApplication")?, sharedApplication];
            let window: Option<Retained<AnyObject>> = msg_send![&*app, keyWindow];
            let mut vc: Retained<AnyObject> = msg_send![&*window?, rootViewController];
            loop {
                let next: Option<Retained<AnyObject>> = msg_send![&*vc, presentedViewController];
                match next {
                    Some(n) => vc = n,
                    None => return Some(vc),
                }
            }
        }
    }
}
