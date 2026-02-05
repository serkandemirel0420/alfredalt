mod app;
mod db;
mod hotkey;
mod models;

use app::LauncherApp;

fn main() -> eframe::Result<()> {
    let native_options = eframe::NativeOptions {
        viewport: eframe::egui::ViewportBuilder::default()
            .with_inner_size([1280.0, 285.0])
            .with_resizable(false)
            .with_transparent(true)
            .with_decorations(false)
            .with_always_on_top()
            .with_title("Alfred Alternative"),
        ..Default::default()
    };

    eframe::run_native(
        "Alfred Alternative",
        native_options,
        Box::new(|cc| Box::new(LauncherApp::new(&cc.egui_ctx))),
    )
}
