use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use eframe::{App, egui};
use egui::{Color32, Key, TextEdit, text::LayoutJob, text::TextFormat};

use crate::db::{
    fetch_item, insert_item, load_hotkey_setting, save_hotkey_setting, search, update_item,
};
use crate::hotkey::{HotKeyRegistration, DEFAULT_HOTKEY, setup_hotkey_listener_with};
use crate::models::{AppMessage, EditableItem, SearchResult};

pub struct LauncherApp {
    query: String,
    results: Vec<SearchResult>,
    selected: usize,
    last_error: Option<String>,
    needs_focus: bool,
    visible: bool,
    editor_open: bool,
    editor_item: Option<EditableItem>,
    editor_texture: Option<egui::TextureHandle>,
    editor_needs_focus: bool,
    hotkey_rx: std::sync::mpsc::Receiver<AppMessage>,
    hotkey_enabled: bool,
    _hotkey: Option<HotKeyRegistration>,
    settings_open: bool,
    hotkey_input: String,
    hotkey_status: Option<String>,
    hotkey_error: Option<String>,
}

impl LauncherApp {
    pub fn new(ctx: &egui::Context) -> Self {
        let hotkey_setting =
            load_hotkey_setting().unwrap_or_else(|_| DEFAULT_HOTKEY.to_string());
        let (hotkey_rx, hotkey) = setup_hotkey_listener_with(ctx, &hotkey_setting);
        let hotkey_enabled = hotkey.is_some();
        let start_visible = !hotkey_enabled;
        let mut app = Self {
            query: String::new(),
            results: Vec::new(),
            selected: 0,
            last_error: None,
            needs_focus: start_visible,
            visible: start_visible,
            editor_open: false,
            editor_item: None,
            editor_texture: None,
            editor_needs_focus: false,
            hotkey_rx,
            hotkey_enabled,
            _hotkey: hotkey,
            settings_open: false,
            hotkey_input: hotkey_setting,
            hotkey_status: None,
            hotkey_error: None,
        };
        app.refresh_results();
        if !start_visible {
            ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
        }
        app
    }

    fn process_app_messages(&mut self, ctx: &egui::Context) {
        while let Ok(msg) = self.hotkey_rx.try_recv() {
            match msg {
                AppMessage::ToggleLauncher => {
                    if self.visible {
                        self.visible = false;
                        ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(true));
                    } else {
                        self.visible = true;
                        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
                        ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(false));
                        self.needs_focus = true;
                        ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
                    }
                }
            }
        }
    }

    fn refresh_results(&mut self) {
        if self.query.trim().is_empty() {
            self.results.clear();
            self.selected = 0;
            self.last_error = None;
            return;
        }

        match search(&self.query, 8) {
            Ok(list) => {
                self.results = list;
                self.selected = 0;
                self.last_error = None;
            }
            Err(err) => {
                self.last_error = Some(err.to_string());
            }
        }
    }

    fn apply_hotkey_setting(&mut self, ctx: &egui::Context) {
        let hotkey_str = self.hotkey_input.trim();
        if hotkey_str.is_empty() {
            self.hotkey_error = Some("Hotkey cannot be empty.".to_string());
            self.hotkey_status = None;
            return;
        }

        let (hotkey_rx, hotkey) = setup_hotkey_listener_with(ctx, hotkey_str);
        if let Some(hk) = hotkey {
            self.hotkey_rx = hotkey_rx;
            self._hotkey = Some(hk);
            self.hotkey_enabled = true;
            self.hotkey_error = None;
            self.hotkey_status = Some("Hotkey saved.".to_string());
            if let Err(err) = save_hotkey_setting(hotkey_str) {
                self.hotkey_error = Some(format!("Saved hotkey but failed to persist: {err}"));
            }
        } else {
            self.hotkey_error = Some("Failed to register hotkey. It might be in use.".to_string());
            self.hotkey_status = None;
        }
    }

    fn activate_current_or_create_new(&mut self, ctx: &egui::Context) {
        if let Some(item) = self.results.get(self.selected) {
            self.open_editor(item.id, ctx);
            return;
        }

        let title = self.query.trim().to_string();
        if title.is_empty() {
            return;
        }

        match insert_item(&title) {
            Ok(id) => {
                self.last_error = None;
                self.refresh_results();
                self.open_editor(id, ctx);
            }
            Err(err) => {
                self.last_error = Some(format!("Failed to add item: {err}"));
            }
        }
    }

    fn open_editor(&mut self, item_id: i64, ctx: &egui::Context) {
        match fetch_item(item_id) {
            Ok(item) => {
                self.editor_item = Some(item);
                self.editor_open = true;
                self.editor_needs_focus = true;
                self.reload_editor_texture(ctx);
            }
            Err(err) => {
                self.last_error = Some(format!("Failed to open item: {err}"));
            }
        }
    }

    fn save_editor(&mut self) {
        if let Some(item) = self.editor_item.as_ref() {
            if let Err(err) = update_item(item.id, &item.note, item.screenshot.as_deref()) {
                self.last_error = Some(format!("Failed to save item: {err}"));
            }
        }
    }

    fn reload_editor_texture(&mut self, ctx: &egui::Context) {
        let Some(item) = self.editor_item.as_ref() else {
            self.editor_texture = None;
            return;
        };

        let Some(bytes) = item.screenshot.as_ref() else {
            self.editor_texture = None;
            return;
        };

        match image::load_from_memory(bytes) {
            Ok(img) => {
                let rgba = img.to_rgba8();
                let size = [rgba.width() as usize, rgba.height() as usize];
                let color_image = egui::ColorImage::from_rgba_unmultiplied(size, rgba.as_raw());
                self.editor_texture = Some(ctx.load_texture(
                    format!("note-shot-{}", item.id),
                    color_image,
                    egui::TextureOptions::LINEAR,
                ));
            }
            Err(err) => {
                self.editor_texture = None;
                self.last_error = Some(format!("Failed to decode screenshot: {err}"));
            }
        }
    }

    fn capture_screenshot(&mut self, ctx: &egui::Context) {
        let path = std::env::temp_dir().join(format!("alfred-alt-shot-{}.png", unix_time_secs()));
        match Command::new("screencapture").arg("-i").arg(&path).status() {
            Ok(status) if status.success() && path.exists() => match std::fs::read(&path) {
                Ok(bytes) => {
                    if let Some(item) = self.editor_item.as_mut() {
                        item.screenshot = Some(bytes);
                    }
                    let _ = std::fs::remove_file(&path);
                    self.reload_editor_texture(ctx);
                    self.save_editor();
                }
                Err(err) => {
                    self.last_error = Some(format!("Could not read screenshot: {err}"));
                }
            },
            Ok(_) => {
                // User canceled capture.
            }
            Err(err) => {
                self.last_error = Some(format!("screencapture failed: {err}"));
            }
        }
    }

    fn close_editor(&mut self) {
        self.save_editor();
        self.editor_open = false;
        self.editor_item = None;
        self.editor_texture = None;
        self.editor_needs_focus = false;
    }

    fn render_editor_modal(&mut self, ctx: &egui::Context) {
        if !self.editor_open {
            return;
        }

        let mut open_flag = self.editor_open;
        let mut save_now = false;
        let mut close_now = false;
        let mut capture_now = false;
        let mut remove_shot = false;

        egui::Window::new("Text Editor")
            .open(&mut open_flag)
            .default_size([840.0, 560.0])
            .resizable(true)
            .collapsible(false)
            .show(ctx, |ui| {
                if let Some(item) = self.editor_item.as_mut() {
                    ui.label(egui::RichText::new(&item.title).size(22.0).strong());
                    ui.add_space(8.0);

                    let editor_id = ui.make_persistent_id("note_editor_modal_text");
                    let response = ui.add_sized(
                        [780.0, 300.0],
                        TextEdit::multiline(&mut item.note)
                            .id_source(editor_id)
                            .desired_rows(14),
                    );

                    if self.editor_needs_focus {
                        response.request_focus();
                        self.editor_needs_focus = false;
                    }

                    if response.changed() {
                        save_now = true;
                    }

                    ui.add_space(10.0);
                    ui.horizontal(|ui| {
                        if ui.button("Save").clicked() {
                            save_now = true;
                        }
                        if ui.button("Capture Screenshot").clicked() {
                            capture_now = true;
                        }
                        if item.screenshot.is_some() && ui.button("Remove Screenshot").clicked() {
                            item.screenshot = None;
                            remove_shot = true;
                        }
                        if ui.button("Close").clicked() {
                            close_now = true;
                        }
                    });

                    if let Some(texture) = self.editor_texture.as_ref() {
                        ui.add_space(10.0);
                        let size = texture.size_vec2();
                        let scale = (760.0 / size.x).min(210.0 / size.y).min(1.0);
                        ui.image((texture.id(), size * scale));
                    }
                }
            });

        self.editor_open = open_flag;

        if remove_shot {
            self.editor_texture = None;
            save_now = true;
        }
        if save_now {
            self.save_editor();
            self.refresh_results();
        }
        if capture_now {
            self.capture_screenshot(ctx);
        }
        if close_now || !self.editor_open {
            self.close_editor();
        }
    }
}

impl App for LauncherApp {
    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        egui::Rgba::TRANSPARENT.to_array()
    }

    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.process_app_messages(ctx);

        let mut visuals = egui::Visuals::light();
        visuals.panel_fill = egui::Color32::TRANSPARENT;
        visuals.window_fill = egui::Color32::TRANSPARENT;
        visuals.override_text_color = Some(egui::Color32::from_rgb(25, 25, 25));
        ctx.set_visuals(visuals);

        let mut style = (*ctx.style()).clone();
        style
            .text_styles
            .insert(egui::TextStyle::Heading, egui::FontId::proportional(36.0));
        style
            .text_styles
            .insert(egui::TextStyle::Body, egui::FontId::proportional(22.0));
        style
            .text_styles
            .insert(egui::TextStyle::Small, egui::FontId::proportional(16.0));
        ctx.set_style(style);

        let mut should_refresh = false;
        let mut activate = false;
        let mut selection_moved = false;

        egui::CentralPanel::default()
            .frame(egui::Frame::none().fill(egui::Color32::TRANSPARENT))
            .show(ctx, |ui| {
                ui.vertical_centered(|ui| {
                    ui.add_space(14.0);
                    let shell_width = (ui.available_width() - 56.0).clamp(700.0, 1180.0);

                    egui::Frame::none()
                        .fill(egui::Color32::from_rgba_unmultiplied(250, 250, 250, 252))
                        .rounding(egui::Rounding::same(30.0))
                        .stroke(egui::Stroke::new(
                            1.0,
                            egui::Color32::from_rgba_unmultiplied(0, 0, 0, 35),
                        ))
                        .shadow(egui::epaint::Shadow {
                            offset: egui::vec2(0.0, 8.0),
                            blur: 34.0,
                            spread: 0.0,
                            color: egui::Color32::from_rgba_unmultiplied(0, 0, 0, 52),
                        })
                        .inner_margin(egui::Margin::same(18.0))
                        .show(ui, |ui| {
                            ui.set_width(shell_width);

                            ui.with_layout(
                                egui::Layout::right_to_left(egui::Align::Center),
                                |ui| {
                                    let button_label =
                                        if self.settings_open { "Close Settings" } else { "Settings" };
                                    if ui.button(button_label).clicked() {
                                        self.settings_open = !self.settings_open;
                                        self.hotkey_status = None;
                                        self.hotkey_error = None;
                                    }
                                    if self.hotkey_enabled {
                                        ui.label(
                                            egui::RichText::new(format!(
                                                "Hotkey: {}",
                                                self.hotkey_input
                                            ))
                                            .size(14.0)
                                            .color(egui::Color32::from_gray(90)),
                                        );
                                    } else {
                                        ui.label(
                                            egui::RichText::new("Hotkey inactive")
                                                .size(14.0)
                                                .color(egui::Color32::from_rgb(220, 90, 90)),
                                        );
                                    }
                                },
                            );

                            ui.horizontal(|ui| {
                                let field_id = ui.make_persistent_id("alfred_search_input");
                                let search_w = (shell_width - 28.0).max(500.0);
                                let response = egui::Frame::none()
                                    .fill(egui::Color32::from_rgb(238, 238, 238))
                                    .rounding(egui::Rounding::same(16.0))
                                    .inner_margin(egui::Margin::symmetric(16.0, 12.0))
                                    .show(ui, |ui| {
                                        ui.with_layout(
                                            egui::Layout::left_to_right(egui::Align::Center),
                                            |ui| {
                                                ui.add(
                                                    TextEdit::singleline(&mut self.query)
                                                        .id_source(field_id)
                                                        .hint_text("Type to search...")
                                                        .frame(false)
                                                        .font(egui::TextStyle::Heading)
                                                        .desired_width(search_w),
                                                )
                                            },
                                        )
                                        .inner
                                    })
                                    .inner;

                                if self.needs_focus {
                                    response.request_focus();
                                    self.needs_focus = false;
                                }

                                if response.changed() {
                                    should_refresh = true;
                                }

                                if response.lost_focus() && ui.input(|i| i.key_pressed(Key::Enter)) {
                                    activate = true;
                                }
                            });

                            if let Some(err) = &self.last_error {
                                ui.add_space(6.0);
                                ui.colored_label(egui::Color32::RED, format!("Error: {err}"));
                            }

                            if self.settings_open {
                                ui.add_space(10.0);
                                egui::Frame::none()
                                    .fill(egui::Color32::from_rgba_unmultiplied(240, 242, 247, 255))
                                    .rounding(egui::Rounding::same(12.0))
                                    .stroke(egui::Stroke::new(
                                        1.0,
                                        egui::Color32::from_rgba_unmultiplied(0, 0, 0, 20),
                                    ))
                                    .inner_margin(egui::Margin::symmetric(14.0, 12.0))
                                    .show(ui, |ui| {
                                        ui.horizontal(|ui| {
                                            ui.label(
                                                egui::RichText::new("Global hotkey")
                                                    .size(18.0)
                                                    .strong(),
                                            );
                                            ui.label(
                                                egui::RichText::new("Format: shift+alt+KeyK or super+Space")
                                                    .size(13.0)
                                                    .color(egui::Color32::from_gray(90)),
                                            );
                                        });

                                        ui.add_space(6.0);
                                        let resp = ui.add(
                                            TextEdit::singleline(&mut self.hotkey_input)
                                                .desired_width(280.0),
                                        );
                                        if resp.lost_focus() && ui.input(|i| i.key_pressed(Key::Enter)) {
                                            self.apply_hotkey_setting(ctx);
                                        }

                                        ui.add_space(8.0);
                                        ui.horizontal(|ui| {
                                            if ui.button("Save hotkey").clicked() {
                                                self.apply_hotkey_setting(ctx);
                                            }
                                            if ui.button("Reset to default").clicked() {
                                                self.hotkey_input = DEFAULT_HOTKEY.to_string();
                                                self.apply_hotkey_setting(ctx);
                                            }
                                        });

                                        if let Some(msg) = &self.hotkey_status {
                                            ui.add_space(6.0);
                                            ui.colored_label(
                                                egui::Color32::from_rgb(40, 140, 80),
                                                msg,
                                            );
                                        }
                                        if let Some(err) = &self.hotkey_error {
                                            ui.add_space(6.0);
                                            ui.colored_label(egui::Color32::from_rgb(200, 60, 60), err);
                                        }
                                    });
                            }

                            if self.query.trim().is_empty() {
                                ui.add_space(16.0);
                                ui.vertical_centered(|ui| {
                                    ui.label(
                                        egui::RichText::new("Alfred Update Available")
                                            .size(22.0)
                                            .strong()
                                            .color(egui::Color32::from_gray(20)),
                                    );
                                });
                                ui.add_space(4.0);
                            } else {
                                ui.add_space(10.0);
                                let row_height = 74.0;
                                let viewport_height = row_height * 5.0;
                                egui::ScrollArea::vertical()
                                    .max_height(viewport_height)
                                    .show(ui, |ui| {
                                        for (idx, item) in self.results.iter().enumerate() {
                                            let is_sel = idx == self.selected;
                                            let row_fill = if is_sel {
                                                egui::Color32::from_rgba_unmultiplied(45, 45, 45, 28)
                                            } else {
                                                egui::Color32::TRANSPARENT
                                            };

                                            egui::Frame::none()
                                                .fill(row_fill)
                                                .rounding(egui::Rounding::same(9.0))
                                                .inner_margin(egui::Margin::symmetric(12.0, 9.0))
                                                .show(ui, |ui| {
                                                    let resp = ui.selectable_label(
                                                        is_sel,
                                                        egui::RichText::new(&item.title)
                                                            .size(24.0)
                                                            .strong(),
                                                    );
                                                    if !item.subtitle.is_empty() {
                                                        ui.label(
                                                            egui::RichText::new(&item.subtitle)
                                                                .size(17.0)
                                                                .color(egui::Color32::from_gray(85)),
                                                        );
                                                    }

                                                    if let Some(snippet) = &item.snippet {
                                                        ui.horizontal_wrapped(|ui| {
                                                            if let Some(src) = &item.snippet_source {
                                                                ui.label(
                                                                    egui::RichText::new(format!("{src}:"))
                                                                        .size(14.0)
                                                                        .color(egui::Color32::from_gray(95)),
                                                                );
                                                            }
                                                            render_marked_snippet(ui, snippet, 14.0);
                                                        });
                                                    }

                                                    if resp.hovered() && ui.input(|i| i.pointer.is_moving()) {
                                                        self.selected = idx;
                                                    }
                                                    if selection_moved && is_sel {
                                                        ui.scroll_to_rect(resp.rect, Some(egui::Align::Center));
                                                    }
                                                    if resp.clicked() {
                                                        self.selected = idx;
                                                        activate = true;
                                                    }
                                                });
                                        }

                                        if self.results.is_empty() {
                                            ui.label(
                                                egui::RichText::new(
                                                    "No matching results. Press Enter to add this as a new entry.",
                                                )
                                                .italics()
                                                .color(egui::Color32::from_gray(95)),
                                            );
                                        }
                                    });
                            }
                        });

                    ui.add_space(20.0);
                });
            });

        self.render_editor_modal(ctx);

        ctx.input(|input| {
            if input.key_pressed(Key::Escape) {
                if self.editor_open {
                    self.close_editor();
                } else if self.hotkey_enabled {
                    self.visible = false;
                    ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(true));
                } else {
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                }
            }

            if !self.editor_open && input.key_pressed(Key::ArrowUp) && self.selected > 0 {
                self.selected -= 1;
                selection_moved = true;
            }
            if !self.editor_open
                && input.key_pressed(Key::ArrowDown)
                && self.selected + 1 < self.results.len()
            {
                self.selected += 1;
                selection_moved = true;
            }
            if !self.editor_open && input.key_pressed(Key::Enter) {
                activate = true;
            }
        });

        if should_refresh {
            self.refresh_results();
        }
        if activate {
            self.activate_current_or_create_new(ctx);
        }
    }
}

fn render_marked_snippet(ui: &mut egui::Ui, snippet: &str, size: f32) {
    let mut job = LayoutJob::default();
    let mut rest = snippet;

    while let Some(start) = rest.find("**") {
        let before = &rest[..start];
        append_job(&mut job, before, size, Color32::from_gray(70), false);

        let highlighted = &rest[start + 2..];
        if let Some(end) = highlighted.find("**") {
            append_job(
                &mut job,
                &highlighted[..end],
                size,
                Color32::from_rgb(25, 25, 25),
                true,
            );
            rest = &highlighted[end + 2..];
        } else {
            append_job(
                &mut job,
                &rest[start..],
                size,
                Color32::from_gray(70),
                false,
            );
            rest = "";
            break;
        }
    }

    if !rest.is_empty() {
        append_job(&mut job, rest, size, Color32::from_gray(70), false);
    }

    ui.label(job);
}

fn append_job(job: &mut LayoutJob, text: &str, size: f32, color: Color32, highlight: bool) {
    let mut format = TextFormat {
        font_id: egui::FontId::proportional(size),
        color,
        ..Default::default()
    };
    if highlight {
        format.background = Color32::from_rgb(255, 238, 170);
    }
    job.append(text, 0.0, format);
}

fn unix_time_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
