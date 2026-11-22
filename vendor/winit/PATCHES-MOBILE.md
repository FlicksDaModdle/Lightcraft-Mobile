# winit, vendored for LightCraft Mobile

A copy of https://github.com/storytold/winit at `a517b3846ee8457d84ee4975110bfda6797c44dc`
(Apache-2.0, see LICENSE), used through `[patch.crates-io]` in the workspace `Cargo.toml`.
The manifest's workspace fields are written out; tests and examples are left out.

## Change

`src/platform_impl/ios/window.rs`: `inner_size` and `inner_position` report the whole window
instead of the safe area. egui-winit lays out and maps touches at the full screen (`outer_size`)
while eframe and egui-wgpu size the Metal surface from `inner_size`; the mismatch made iOS stretch
a smaller surface over the screen, so touches landed below what was drawn (worse towards the
bottom). The app reads the safe-area insets separately and pads its layout.

Drop this copy once the fix is in storytold/winit (or winit 0.31's `Window::safe_area` is used).
