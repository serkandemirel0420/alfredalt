mod app;
mod db;
mod hotkey;
mod models;

use app::LauncherApp;

fn main() -> eframe::Result<()> {
    let native_options = eframe::NativeOptions {
        viewport: eframe::egui::ViewportBuilder::default()
            .with_inner_size([1100.0, 220.0])
            .with_min_inner_size([620.0, 200.0])
            .with_resizable(true)
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
