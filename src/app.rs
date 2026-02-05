use std::process::Command;
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use std::{
    collections::hash_map::DefaultHasher,
    hash::{Hash, Hasher},
};

use arboard::Clipboard;
use eframe::{App, egui};
use egui::{Color32, Key, TextEdit, text::LayoutJob, text::TextFormat};
use image::{
    ColorType, GenericImageView, ImageBuffer, ImageEncoder, ImageFormat, Rgba,
    codecs::png::{CompressionType, FilterType, PngEncoder},
    imageops::FilterType as ResizeFilterType,
};

use crate::db::{MAX_NOTE_IMAGE_COUNT, MAX_SCREENSHOT_BYTES, fetch_item, insert_item, search, update_item};
use crate::hotkey::{HotKeyRegistration, setup_hotkey_listener};
use crate::models::{AppMessage, EditableItem, NoteImage, SearchResult};

const SEARCH_LIMIT: i64 = 8;
const SEARCH_DEBOUNCE_MS: u64 = 160;
const EDITOR_IDLE_AUTOSAVE_MS: u64 = 1200;
const SCREENSHOT_MAX_DIMENSION_WIDTH: u32 = 1920;
const SCREENSHOT_MAX_DIMENSION_HEIGHT: u32 = 1080;
const SCREENSHOT_MAX_PIXELS: u64 = 8_294_400; // 3840x2160
const SCREENSHOT_MAX_INPUT_BYTES: usize = 20 * 1024 * 1024;
const NOTE_IMAGE_URL_PREFIX: &str = "alfred://image/";

#[derive(Clone, Copy)]
enum EscapeAction {
    CloseEditor,
    HideLauncher,
    CloseApp,
}

struct SearchRequest {
    seq: u64,
    query: String,
}

struct SearchResponse {
    seq: u64,
    query: String,
    result: anyhow::Result<Vec<SearchResult>>,
}

struct DecodedImage {
    size: [usize; 2],
    rgba: Vec<u8>,
}

#[derive(Default, Clone, Copy)]
struct EditorActions {
    paste_image: bool,
    capture_image: bool,
    remove_image: bool,
}

enum EditorTask {
    CaptureScreenshot {
        item_id: i64,
    },
    DecodeScreenshot {
        item_id: i64,
        request_id: u64,
        screenshot_version: u64,
        bytes: Vec<u8>,
    },
    SaveItem {
        item_id: i64,
        content_hash: u64,
        note: String,
        images: Vec<NoteImage>,
    },
}

enum EditorTaskResult {
    ScreenshotCaptured {
        item_id: i64,
        result: Result<Option<Vec<u8>>, String>,
    },
    ScreenshotDecoded {
        item_id: i64,
        request_id: u64,
        screenshot_version: u64,
        result: Result<DecodedImage, String>,
    },
    ItemSaved {
        item_id: i64,
        content_hash: u64,
        result: Result<(), String>,
    },
}

pub struct LauncherApp {
    query: String,
    results: Vec<SearchResult>,
    results_query: String,
    selected: usize,
    last_error: Option<String>,
    needs_focus: bool,
    visible: bool,
    launcher_hidden_for_editor: bool,
    editor_open: bool,
    editor_item: Option<EditableItem>,
    editor_texture: Option<egui::TextureHandle>,
    editor_texture_viewport: Option<egui::ViewportId>,
    editor_text_id: Option<egui::Id>,
    editor_needs_focus: bool,
    editor_dirty: bool,
    last_editor_edit: Option<Instant>,
    last_saved_editor_hash: Option<u64>,
    save_in_flight: Option<(i64, u64)>,
    selected_image_key: Option<String>,
    next_image_seq: u64,
    screenshot_version: u64,
    decoded_screenshot_version: Option<u64>,
    decoded_screenshot: Option<DecodedImage>,
    decode_request_seq: u64,
    decode_in_flight: Option<(i64, u64, u64)>,
    screenshot_capture_in_flight: bool,
    hotkey_rx: std::sync::mpsc::Receiver<AppMessage>,
    hotkey_enabled: bool,
    _hotkey: Option<HotKeyRegistration>,
    editor_task_tx: Sender<EditorTask>,
    editor_task_rx: Receiver<EditorTaskResult>,
    search_tx: Sender<SearchRequest>,
    search_rx: Receiver<SearchResponse>,
    pending_search_at: Option<Instant>,
    next_search_seq: u64,
    in_flight_search_seq: Option<u64>,
}

impl LauncherApp {
    pub fn new(ctx: &egui::Context) -> Self {
        let (hotkey_rx, hotkey) = setup_hotkey_listener(ctx);
        let hotkey_enabled = hotkey.is_some();
        let start_visible = !hotkey_enabled;
        let (search_tx, search_rx) = Self::spawn_search_worker(ctx.clone());
        let (editor_task_tx, editor_task_rx) = Self::spawn_editor_worker(ctx.clone());
        let mut app = Self {
            query: String::new(),
            results: Vec::new(),
            results_query: String::new(),
            selected: 0,
            last_error: None,
            needs_focus: start_visible,
            visible: start_visible,
            launcher_hidden_for_editor: false,
            editor_open: false,
            editor_item: None,
            editor_texture: None,
            editor_texture_viewport: None,
            editor_text_id: None,
            editor_needs_focus: false,
            editor_dirty: false,
            last_editor_edit: None,
            last_saved_editor_hash: None,
            save_in_flight: None,
            selected_image_key: None,
            next_image_seq: 0,
            screenshot_version: 0,
            decoded_screenshot_version: None,
            decoded_screenshot: None,
            decode_request_seq: 0,
            decode_in_flight: None,
            screenshot_capture_in_flight: false,
            hotkey_rx,
            hotkey_enabled,
            _hotkey: hotkey,
            editor_task_tx,
            editor_task_rx,
            search_tx,
            search_rx,
            pending_search_at: None,
            next_search_seq: 0,
            in_flight_search_seq: None,
        };
        app.schedule_search(true);
        if !start_visible {
            ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
        }
        app
    }

    fn spawn_editor_worker(ctx: egui::Context) -> (Sender<EditorTask>, Receiver<EditorTaskResult>) {
        let (task_tx, task_rx) = mpsc::channel::<EditorTask>();
        let (result_tx, result_rx) = mpsc::channel::<EditorTaskResult>();
        std::thread::spawn(move || {
            while let Ok(task) = task_rx.recv() {
                let message = match task {
                    EditorTask::CaptureScreenshot { item_id } => {
                        EditorTaskResult::ScreenshotCaptured {
                            item_id,
                            result: capture_screenshot_bytes(),
                        }
                    }
                    EditorTask::DecodeScreenshot {
                        item_id,
                        request_id,
                        screenshot_version,
                        bytes,
                    } => EditorTaskResult::ScreenshotDecoded {
                        item_id,
                        request_id,
                        screenshot_version,
                        result: decode_screenshot_bytes(&bytes),
                    },
                    EditorTask::SaveItem {
                        item_id,
                        content_hash,
                        note,
                        images,
                    } => {
                        let result = update_item(item_id, &note, &images)
                            .map_err(|err| format!("Failed to save item: {err}"));
                        EditorTaskResult::ItemSaved {
                            item_id,
                            content_hash,
                            result,
                        }
                    }
                };

                let _ = result_tx.send(message);
                ctx.request_repaint();
            }
        });

        (task_tx, result_rx)
    }

    fn spawn_search_worker(
        ctx: egui::Context,
    ) -> (Sender<SearchRequest>, Receiver<SearchResponse>) {
        let (request_tx, request_rx) = mpsc::channel::<SearchRequest>();
        let (response_tx, response_rx) = mpsc::channel::<SearchResponse>();
        std::thread::spawn(move || {
            while let Ok(mut request) = request_rx.recv() {
                while let Ok(newer) = request_rx.try_recv() {
                    request = newer;
                }

                let result = if request.query.trim().is_empty() {
                    Ok(Vec::new())
                } else {
                    search(&request.query, SEARCH_LIMIT)
                };

                let _ = response_tx.send(SearchResponse {
                    seq: request.seq,
                    query: request.query,
                    result,
                });
                ctx.request_repaint();
            }
        });

        (request_tx, response_rx)
    }

    fn process_app_messages(&mut self, ctx: &egui::Context) {
        while let Ok(msg) = self.hotkey_rx.try_recv() {
            match msg {
                AppMessage::ToggleLauncher => {
                    if self.visible {
                        self.hide_launcher(ctx);
                    } else {
                        self.show_launcher(ctx);
                    }
                }
            }
        }
    }

    fn show_launcher(&mut self, ctx: &egui::Context) {
        self.visible = true;
        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
        self.needs_focus = true;
        ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
    }

    fn hide_launcher(&mut self, ctx: &egui::Context) {
        self.visible = false;
        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
    }

    fn schedule_search(&mut self, immediate: bool) {
        if self.query.trim().is_empty() {
            self.results.clear();
            self.results_query.clear();
            self.selected = 0;
            self.last_error = None;
            self.pending_search_at = None;
            self.in_flight_search_seq = None;
            return;
        }

        let when = if immediate {
            Instant::now()
        } else {
            Instant::now() + Duration::from_millis(SEARCH_DEBOUNCE_MS)
        };
        self.pending_search_at = Some(when);
    }

    fn dispatch_due_search(&mut self, ctx: &egui::Context) {
        let Some(at) = self.pending_search_at else {
            return;
        };

        let now = Instant::now();
        if now < at {
            ctx.request_repaint_after(at - now);
            return;
        }

        self.pending_search_at = None;
        self.next_search_seq += 1;
        let seq = self.next_search_seq;
        self.in_flight_search_seq = Some(seq);

        if let Err(err) = self.search_tx.send(SearchRequest {
            seq,
            query: self.query.clone(),
        }) {
            self.last_error = Some(format!("Failed to queue search: {err}"));
            self.in_flight_search_seq = None;
        }
    }

    fn apply_search_responses(&mut self) {
        loop {
            match self.search_rx.try_recv() {
                Ok(msg) => {
                    if Some(msg.seq) != self.in_flight_search_seq {
                        continue;
                    }
                    if msg.query != self.query {
                        continue;
                    }

                    self.in_flight_search_seq = None;
                    match msg.result {
                        Ok(list) => {
                            self.results = list;
                            self.results_query = msg.query;
                            self.selected = 0;
                            self.last_error = None;
                        }
                        Err(err) => {
                            self.last_error = Some(err.to_string());
                        }
                    }
                }
                Err(TryRecvError::Empty) | Err(TryRecvError::Disconnected) => break,
            }
        }
    }

    fn activate_current_or_create_new(&mut self, ctx: &egui::Context) {
        if self.results_query != self.query || self.in_flight_search_seq.is_some() {
            self.schedule_search(true);
            return;
        }

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
                self.schedule_search(true);
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
                let initial_hash = Self::editor_content_hash(&item);
                let has_images = !item.images.is_empty();
                let selected_image_key = item.images.first().map(|img| img.image_key.clone());
                self.editor_item = Some(item);
                self.editor_open = true;
                self.launcher_hidden_for_editor = self.visible;
                if self.launcher_hidden_for_editor {
                    ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
                }
                self.editor_needs_focus = true;
                self.editor_dirty = false;
                self.last_editor_edit = None;
                self.last_saved_editor_hash = Some(initial_hash);
                self.save_in_flight = None;
                self.selected_image_key = selected_image_key;
                self.next_image_seq = 0;
                self.editor_texture = None;
                self.editor_texture_viewport = None;
                self.screenshot_version = if has_images { 1 } else { 0 };
                self.decoded_screenshot_version = None;
                self.decoded_screenshot = None;
                self.decode_in_flight = None;
                self.screenshot_capture_in_flight = false;
                self.editor_text_id = None;
                ctx.request_repaint();
            }
            Err(err) => {
                self.last_error = Some(format!("Failed to open item: {err}"));
            }
        }
    }

    fn queue_editor_save(&mut self) -> bool {
        let Some(item) = self.editor_item.as_ref() else {
            return false;
        };

        if self.save_in_flight.is_some() {
            return false;
        }

        let current_hash = Self::editor_content_hash(item);
        if self.last_saved_editor_hash == Some(current_hash) {
            self.editor_dirty = self.last_saved_editor_hash != Some(current_hash);
            return false;
        }

        let task = EditorTask::SaveItem {
            item_id: item.id,
            content_hash: current_hash,
            note: item.note.clone(),
            images: item.images.clone(),
        };
        if let Err(err) = self.editor_task_tx.send(task) {
            self.last_error = Some(format!("Failed to queue save: {err}"));
            return false;
        }

        self.save_in_flight = Some((item.id, current_hash));
        true
    }

    fn ensure_editor_texture_for(&mut self, ctx: &egui::Context) {
        let Some(item) = self.editor_item.as_ref() else {
            self.editor_texture = None;
            self.editor_texture_viewport = None;
            self.decoded_screenshot = None;
            self.decoded_screenshot_version = None;
            self.decode_in_flight = None;
            return;
        };

        let Some(bytes) = self.current_image_bytes(item) else {
            self.editor_texture = None;
            self.editor_texture_viewport = None;
            self.decoded_screenshot = None;
            self.decoded_screenshot_version = None;
            self.decode_in_flight = None;
            return;
        };

        if self.editor_texture.is_some() && self.editor_texture_viewport == Some(ctx.viewport_id())
        {
            return;
        }

        if self.decoded_screenshot_version == Some(self.screenshot_version) {
            if let Some(decoded) = self.decoded_screenshot.as_ref() {
                let color_image =
                    egui::ColorImage::from_rgba_unmultiplied(decoded.size, decoded.rgba.as_slice());
                self.editor_texture = Some(ctx.load_texture(
                    format!("note-shot-{}", item.id),
                    color_image,
                    egui::TextureOptions::LINEAR,
                ));
                self.editor_texture_viewport = Some(ctx.viewport_id());
            }
            return;
        }

        if self
            .decode_in_flight
            .map(|(in_flight_item, _, in_flight_version)| {
                in_flight_item == item.id && in_flight_version == self.screenshot_version
            })
            .unwrap_or(false)
        {
            return;
        }

        self.decode_request_seq = self.decode_request_seq.wrapping_add(1);
        let request_id = self.decode_request_seq;
        let screenshot_version = self.screenshot_version;
        self.decode_in_flight = Some((item.id, request_id, screenshot_version));
        let task = EditorTask::DecodeScreenshot {
            item_id: item.id,
            request_id,
            screenshot_version,
            bytes: bytes.clone(),
        };
        if let Err(err) = self.editor_task_tx.send(task) {
            self.decode_in_flight = None;
            self.last_error = Some(format!("Failed to queue screenshot decode: {err}"));
        }
    }

    fn capture_screenshot(&mut self) {
        let Some(item) = self.editor_item.as_ref() else {
            return;
        };
        if self.screenshot_capture_in_flight {
            return;
        }

        if let Err(err) = self
            .editor_task_tx
            .send(EditorTask::CaptureScreenshot { item_id: item.id })
        {
            self.last_error = Some(format!("Failed to queue screenshot capture: {err}"));
            return;
        }

        self.screenshot_capture_in_flight = true;
    }

    fn try_paste_clipboard_image(&mut self) {
        let mut clipboard = match Clipboard::new() {
            Ok(clipboard) => clipboard,
            Err(err) => {
                self.last_error = Some(format!("Clipboard unavailable: {err}"));
                return;
            }
        };

        let image = match clipboard.get_image() {
            Ok(image) => image,
            Err(arboard::Error::ContentNotAvailable) => return,
            Err(err) => {
                self.last_error = Some(format!("Could not read clipboard image: {err}"));
                return;
            }
        };

        let rgba = match Self::clipboard_image_to_rgba(image) {
            Ok(rgba) => rgba,
            Err(err) => {
                self.last_error = Some(format!("Clipboard image format not supported: {err}"));
                return;
            }
        };

        let dyn_image = image::DynamicImage::ImageRgba8(rgba);
        let mut png_bytes = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut png_bytes);
        if let Err(err) = dyn_image.write_to(&mut cursor, ImageFormat::Png) {
            self.last_error = Some(format!("Could not encode pasted image: {err}"));
            return;
        }

        match normalize_screenshot_for_storage(&png_bytes) {
            Ok(stored_bytes) => {
                self.add_image_to_editor(stored_bytes, "pasted");
                self.last_error = None;
            }
            Err(err) => {
                self.last_error = Some(format!("Could not use pasted image: {err}"));
            }
        }
    }

    fn close_editor(&mut self, ctx: &egui::Context) {
        self.queue_editor_save();
        self.editor_open = false;
        self.editor_item = None;
        self.editor_texture = None;
        self.editor_texture_viewport = None;
        self.editor_text_id = None;
        self.editor_needs_focus = false;
        self.editor_dirty = false;
        self.last_editor_edit = None;
        self.last_saved_editor_hash = None;
        self.save_in_flight = None;
        self.selected_image_key = None;
        self.next_image_seq = 0;
        self.screenshot_version = 0;
        self.decoded_screenshot_version = None;
        self.decoded_screenshot = None;
        self.decode_in_flight = None;
        self.screenshot_capture_in_flight = false;
        if self.launcher_hidden_for_editor {
            self.launcher_hidden_for_editor = false;
            if self.visible {
                ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
                self.needs_focus = true;
                ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
            }
        }
        ctx.send_viewport_cmd_to(Self::editor_viewport_id(), egui::ViewportCommand::Close);
    }

    fn mark_editor_dirty(&mut self) {
        self.editor_dirty = true;
        self.last_editor_edit = Some(Instant::now());
    }

    fn mark_screenshot_changed(&mut self) {
        self.screenshot_version = self.screenshot_version.wrapping_add(1);
        self.editor_texture = None;
        self.editor_texture_viewport = None;
        self.decoded_screenshot = None;
        self.decoded_screenshot_version = None;
        self.decode_in_flight = None;
        self.mark_editor_dirty();
    }

    fn remove_selected_image(&mut self) {
        let Some(selected) = self.selected_image_key.clone() else {
            return;
        };
        if let Some(item) = self.editor_item.as_mut() {
            let before = item.images.len();
            item.images.retain(|img| img.image_key != selected);
            if item.images.len() != before {
                Self::remove_markdown_image_ref(&mut item.note, &selected);
                self.selected_image_key = item.images.first().map(|img| img.image_key.clone());
                self.mark_screenshot_changed();
            }
        }
    }

    fn apply_editor_task_results(&mut self) {
        loop {
            match self.editor_task_rx.try_recv() {
                Ok(EditorTaskResult::ScreenshotCaptured { item_id, result }) => {
                    self.screenshot_capture_in_flight = false;
                    match result {
                        Ok(Some(bytes)) => {
                            if self.editor_item.as_ref().map(|item| item.id) == Some(item_id) {
                                self.add_image_to_editor(bytes, "shot");
                            }
                        }
                        Ok(None) => {}
                        Err(err) => {
                            self.last_error = Some(err);
                        }
                    }
                }
                Ok(EditorTaskResult::ScreenshotDecoded {
                    item_id,
                    request_id,
                    screenshot_version,
                    result,
                }) => {
                    if self.decode_in_flight == Some((item_id, request_id, screenshot_version)) {
                        self.decode_in_flight = None;
                    }

                    let active_item_matches = self
                        .editor_item
                        .as_ref()
                        .map(|item| item.id == item_id)
                        .unwrap_or(false);
                    if !active_item_matches || self.screenshot_version != screenshot_version {
                        continue;
                    }

                    match result {
                        Ok(decoded) => {
                            self.decoded_screenshot = Some(decoded);
                            self.decoded_screenshot_version = Some(screenshot_version);
                            self.editor_texture = None;
                            self.editor_texture_viewport = None;
                        }
                        Err(err) => {
                            self.last_error = Some(format!("Failed to decode screenshot: {err}"));
                            self.decoded_screenshot = None;
                            self.decoded_screenshot_version = None;
                        }
                    }
                }
                Ok(EditorTaskResult::ItemSaved {
                    item_id,
                    content_hash,
                    result,
                }) => {
                    if self.save_in_flight == Some((item_id, content_hash)) {
                        self.save_in_flight = None;
                    }

                    let active_item_matches = self
                        .editor_item
                        .as_ref()
                        .map(|item| item.id == item_id)
                        .unwrap_or(false);

                    match result {
                        Ok(()) => {
                            if active_item_matches {
                                self.last_saved_editor_hash = Some(content_hash);
                                if let Some(item) = self.editor_item.as_ref() {
                                    if Self::editor_content_hash(item) == content_hash {
                                        self.editor_dirty = false;
                                        self.last_editor_edit = None;
                                    }
                                }
                            }
                            self.schedule_search(true);
                        }
                        Err(err) => {
                            if active_item_matches {
                                self.last_error = Some(err);
                            }
                        }
                    }
                }
                Err(TryRecvError::Empty) | Err(TryRecvError::Disconnected) => break,
            }
        }
    }

    fn editor_content_hash(item: &EditableItem) -> u64 {
        let mut hasher = DefaultHasher::new();
        item.note.hash(&mut hasher);
        item.images.len().hash(&mut hasher);
        for image in &item.images {
            image.image_key.hash(&mut hasher);
            image.bytes.hash(&mut hasher);
        }
        hasher.finish()
    }

    fn current_image_bytes(&self, item: &EditableItem) -> Option<Vec<u8>> {
        if let Some(selected) = self.selected_image_key.as_deref() {
            if let Some(found) = item.images.iter().find(|img| img.image_key == selected) {
                return Some(found.bytes.clone());
            }
        }
        item.images.first().map(|img| img.bytes.clone())
    }

    fn add_image_to_editor(&mut self, bytes: Vec<u8>, label: &str) {
        if let Some(item) = self.editor_item.as_mut() {
            if item.images.len() >= MAX_NOTE_IMAGE_COUNT {
                self.last_error = Some(format!(
                    "Too many images in one note (max {MAX_NOTE_IMAGE_COUNT})"
                ));
                return;
            }

            let key = format!("{}-{}-{}", label, unix_time_secs(), self.next_image_seq);
            self.next_image_seq = self.next_image_seq.wrapping_add(1);
            item.images.push(NoteImage {
                image_key: key.clone(),
                bytes,
            });
            Self::ensure_markdown_image_ref(&mut item.note, &key);
            self.selected_image_key = Some(key);
            self.mark_screenshot_changed();
        }
    }

    fn editor_viewport_id() -> egui::ViewportId {
        egui::ViewportId::from_hash_of("alfred_editor_viewport")
    }

    fn apply_theme(&self, ctx: &egui::Context) {
        let mut visuals = egui::Visuals::light();
        visuals.panel_fill = egui::Color32::from_rgb(240, 240, 240);
        visuals.window_fill = egui::Color32::from_rgb(245, 245, 245);
        visuals.override_text_color = Some(egui::Color32::from_rgb(25, 25, 25));
        visuals.selection.bg_fill = egui::Color32::from_rgb(209, 238, 250);
        visuals.selection.stroke = egui::Stroke::new(1.0, egui::Color32::from_rgb(82, 164, 203));
        ctx.set_visuals(visuals);

        let mut style = (*ctx.style()).clone();
        style
            .text_styles
            .insert(egui::TextStyle::Heading, egui::FontId::proportional(30.0));
        style
            .text_styles
            .insert(egui::TextStyle::Body, egui::FontId::proportional(18.0));
        style
            .text_styles
            .insert(egui::TextStyle::Small, egui::FontId::proportional(13.0));
        style.spacing.item_spacing = egui::vec2(8.0, 6.0);
        style.spacing.button_padding = egui::vec2(10.0, 6.0);
        ctx.set_style(style);
    }

    fn apply_editor_theme(&self, ctx: &egui::Context) {
        let mut visuals = egui::Visuals::light();
        visuals.panel_fill = egui::Color32::from_rgb(246, 246, 246);
        visuals.window_fill = egui::Color32::from_rgb(250, 250, 250);
        visuals.override_text_color = Some(egui::Color32::from_rgb(28, 28, 28));
        visuals.selection.bg_fill = egui::Color32::from_rgb(209, 238, 250);
        visuals.selection.stroke = egui::Stroke::new(1.0, egui::Color32::from_rgb(82, 164, 203));
        ctx.set_visuals(visuals);

        let mut style = (*ctx.style()).clone();
        style
            .text_styles
            .insert(egui::TextStyle::Heading, egui::FontId::proportional(25.0));
        style
            .text_styles
            .insert(egui::TextStyle::Body, egui::FontId::proportional(15.0));
        style
            .text_styles
            .insert(egui::TextStyle::Button, egui::FontId::proportional(14.0));
        style
            .text_styles
            .insert(egui::TextStyle::Small, egui::FontId::proportional(12.0));
        style
            .text_styles
            .insert(egui::TextStyle::Monospace, egui::FontId::monospace(12.0));
        style.spacing.item_spacing = egui::vec2(8.0, 6.0);
        style.spacing.button_padding = egui::vec2(10.0, 6.0);
        ctx.set_style(style);
    }

    fn render_editor_contents(&mut self, ctx: &egui::Context, ui: &mut egui::Ui) -> EditorActions {
        self.ensure_editor_texture_for(ctx);
        let mut note_changed = false;
        let mut actions = EditorActions::default();
        let is_dirty = self.editor_dirty;

        if let Some(item) = self.editor_item.as_mut() {
            ui.horizontal_wrapped(|ui| {
                ui.heading(&item.title);
                if is_dirty {
                    ui.label(
                        egui::RichText::new("Unsaved changes")
                            .size(12.0)
                            .color(egui::Color32::from_rgb(160, 92, 0)),
                    );
                }
            });
            ui.add_space(4.0);

            ui.horizontal_wrapped(|ui| {
                if ui.button("Paste Image").clicked() {
                    actions.paste_image = true;
                }
                if ui.button("Capture Screenshot").clicked() {
                    actions.capture_image = true;
                }
                if item.screenshot.is_some() && ui.button("Remove Image").clicked() {
                    actions.remove_image = true;
                }
                ui.label(
                    egui::RichText::new(
                        "Markdown note: pasted images are stored as `alfred://image/main`.",
                    )
                    .size(11.0)
                    .color(egui::Color32::from_gray(90)),
                );
            });
            ui.add_space(6.0);

            let controls_height = 32.0;
            let editor_height = (ui.available_height() - controls_height).max(200.0);
            let has_screenshot = item.screenshot.is_some();
            let full_width = ui.available_width();
            let left_width = if has_screenshot {
                (full_width * 0.68).clamp(380.0, full_width - 200.0)
            } else {
                full_width
            };

            ui.horizontal_top(|ui| {
                let editor_id = ui.make_persistent_id("note_editor_modal_text");
                self.editor_text_id = Some(editor_id);

                ui.vertical(|ui| {
                    ui.set_width(left_width);
                    let response = ui.add_sized(
                        [left_width, editor_height],
                        TextEdit::multiline(&mut item.note)
                            .id_source(editor_id)
                            .desired_width(f32::INFINITY)
                            .font(egui::TextStyle::Body),
                    );

                    if self.editor_needs_focus {
                        response.request_focus();
                        self.editor_needs_focus = false;
                    }

                    if response.changed() {
                        note_changed = true;
                    }
                });

                if has_screenshot {
                    ui.add_space(8.0);
                    let right_width = (full_width - left_width - 8.0).max(180.0);
                    ui.vertical(|ui| {
                        ui.set_width(right_width);
                        ui.label(egui::RichText::new("Screenshot").strong().size(13.0));

                        egui::Frame::none()
                            .fill(egui::Color32::from_rgb(236, 236, 236))
                            .rounding(egui::Rounding::same(8.0))
                            .inner_margin(egui::Margin::same(6.0))
                            .show(ui, |ui| {
                                ui.set_min_height((editor_height - 34.0).max(120.0));
                                if let Some(texture) = self.editor_texture.as_ref() {
                                    let size = texture.size_vec2();
                                    let max = egui::vec2(
                                        ui.available_width().max(120.0),
                                        (editor_height - 56.0).max(110.0),
                                    );
                                    let scale = (max.x / size.x).min(max.y / size.y).min(1.0);
                                    ui.centered_and_justified(|ui| {
                                        ui.image((texture.id(), size * scale));
                                    });
                                } else {
                                    ui.centered_and_justified(|ui| {
                                        ui.label(
                                            egui::RichText::new("Loading preview...")
                                                .color(egui::Color32::from_gray(90)),
                                        );
                                    });
                                }
                            });
                    });
                }
            });

            if let Some(err) = &self.last_error {
                ui.add_space(4.0);
                ui.colored_label(egui::Color32::from_rgb(180, 40, 40), err);
            }
        }

        if note_changed {
            self.mark_editor_dirty();
        }

        actions
    }

    fn render_editor_modal(&mut self, ctx: &egui::Context) {
        if !self.editor_open {
            return;
        }

        let mut open_flag = self.editor_open;
        let mut save_now = false;
        let mut close_now = false;
        let mut capture_now = false;
        let mut paste_now = false;
        let mut remove_image_now = false;
        let viewport_id = Self::editor_viewport_id();
        let builder = egui::ViewportBuilder::default()
            .with_title("Markdown Editor")
            .with_inner_size([1120.0, 760.0])
            .with_min_inner_size([620.0, 380.0])
            .with_resizable(true)
            .with_decorations(true)
            .with_visible(true)
            .with_active(true);

        ctx.show_viewport_immediate(viewport_id, builder, |editor_ctx, class| {
            self.apply_editor_theme(editor_ctx);

            if editor_ctx.input(|i| i.viewport().close_requested()) {
                close_now = true;
                open_flag = false;
            }

            match class {
                egui::ViewportClass::Embedded => {
                    let screen_rect = editor_ctx.input(|i| i.screen_rect());
                    let modal_size = egui::vec2(
                        (screen_rect.width() - 72.0).clamp(640.0, 1120.0),
                        (screen_rect.height() - 72.0).clamp(400.0, 820.0),
                    );

                    egui::Window::new("Markdown Editor")
                        .open(&mut open_flag)
                        .default_size(modal_size)
                        .min_size([620.0, 380.0])
                        .max_size([screen_rect.width() - 24.0, screen_rect.height() - 24.0])
                        .resizable(true)
                        .collapsible(false)
                        .show(editor_ctx, |ui| {
                            let actions = self.render_editor_contents(editor_ctx, ui);
                            paste_now |= actions.paste_image;
                            capture_now |= actions.capture_image;
                            remove_image_now |= actions.remove_image;
                        });
                }
                egui::ViewportClass::Root
                | egui::ViewportClass::Deferred
                | egui::ViewportClass::Immediate => {
                    egui::CentralPanel::default().show(editor_ctx, |ui| {
                        let actions = self.render_editor_contents(editor_ctx, ui);
                        paste_now |= actions.paste_image;
                        capture_now |= actions.capture_image;
                        remove_image_now |= actions.remove_image;
                    });
                }
            }

            editor_ctx.input(|input| {
                if input.key_pressed(Key::Escape) {
                    close_now = true;
                    open_flag = false;
                }

                if Self::paste_shortcut_pressed(input) {
                    paste_now = true;
                }
            });

            if paste_now {
                self.try_paste_clipboard_image();
                paste_now = false;
            }

            if capture_now {
                self.capture_screenshot();
                capture_now = false;
            }

            if remove_image_now {
                self.clear_screenshot();
                remove_image_now = false;
            }
        });

        self.editor_open = open_flag;

        if self.editor_dirty
            && self
                .last_editor_edit
                .map(|t| t.elapsed() >= Duration::from_millis(EDITOR_IDLE_AUTOSAVE_MS))
                .unwrap_or(true)
        {
            save_now = true;
        }
        if save_now {
            self.queue_editor_save();
        }
        if self.editor_dirty {
            ctx.request_repaint_after(Duration::from_millis(250));
        }
        if close_now || !self.editor_open {
            self.close_editor(ctx);
        }
    }

    fn paste_shortcut_pressed(input: &egui::InputState) -> bool {
        if input.key_pressed(Key::V) && (input.modifiers.command || input.modifiers.ctrl) {
            return true;
        }

        input
            .events
            .iter()
            .any(|event| matches!(event, egui::Event::Paste(_)))
    }

    fn clipboard_image_to_rgba(
        image: arboard::ImageData<'_>,
    ) -> Result<ImageBuffer<Rgba<u8>, Vec<u8>>, String> {
        let width = image.width;
        let height = image.height;
        let Some(pixel_count) = width.checked_mul(height) else {
            return Err("image dimensions are too large".to_string());
        };
        if pixel_count == 0 {
            return Err("clipboard image is empty".to_string());
        }

        let bytes = image.bytes.into_owned();
        let Some(expected_rgba_len) = pixel_count.checked_mul(4) else {
            return Err("image dimensions overflowed RGBA buffer size".to_string());
        };
        let Some(expected_rgb_len) = pixel_count.checked_mul(3) else {
            return Err("image dimensions overflowed RGB buffer size".to_string());
        };

        if bytes.len() == expected_rgba_len {
            return ImageBuffer::<Rgba<u8>, Vec<u8>>::from_raw(width as u32, height as u32, bytes)
                .ok_or_else(|| "failed to build RGBA image".to_string());
        }

        if bytes.len() == expected_rgb_len {
            let mut rgba = Vec::with_capacity(expected_rgba_len);
            for rgb in bytes.chunks_exact(3) {
                rgba.extend_from_slice(&[rgb[0], rgb[1], rgb[2], 255]);
            }
            return ImageBuffer::<Rgba<u8>, Vec<u8>>::from_raw(width as u32, height as u32, rgba)
                .ok_or_else(|| "failed to build RGB image".to_string());
        }

        if height > 0 && bytes.len() % height == 0 {
            let stride = bytes.len() / height;

            if stride >= width * 4 {
                let mut rgba = Vec::with_capacity(expected_rgba_len);
                for row in bytes.chunks_exact(stride) {
                    rgba.extend_from_slice(&row[..width * 4]);
                }
                if rgba.len() == expected_rgba_len {
                    return ImageBuffer::<Rgba<u8>, Vec<u8>>::from_raw(
                        width as u32,
                        height as u32,
                        rgba,
                    )
                    .ok_or_else(|| "failed to build strided RGBA image".to_string());
                }
            }

            if stride >= width * 3 {
                let mut rgba = Vec::with_capacity(expected_rgba_len);
                for row in bytes.chunks_exact(stride) {
                    for rgb in row[..width * 3].chunks_exact(3) {
                        rgba.extend_from_slice(&[rgb[0], rgb[1], rgb[2], 255]);
                    }
                }
                if rgba.len() == expected_rgba_len {
                    return ImageBuffer::<Rgba<u8>, Vec<u8>>::from_raw(
                        width as u32,
                        height as u32,
                        rgba,
                    )
                    .ok_or_else(|| "failed to build strided RGB image".to_string());
                }
            }
        }

        Err(format!(
            "{width}x{height} with {} bytes (expected {expected_rgba_len} RGBA or {expected_rgb_len} RGB)",
            bytes.len()
        ))
    }

    fn ensure_markdown_image_ref(note: &mut String) {
        if note.contains(SCREENSHOT_MARKDOWN_REF) {
            return;
        }
        if !note.trim_end().is_empty() {
            note.push_str("\n\n");
        }
        note.push_str(SCREENSHOT_MARKDOWN_REF);
        note.push('\n');
    }

    fn remove_markdown_image_ref(note: &mut String) {
        *note = note
            .replace(&format!("\n\n{SCREENSHOT_MARKDOWN_REF}\n"), "\n\n")
            .replace(&format!("\n{SCREENSHOT_MARKDOWN_REF}\n"), "\n")
            .replace(&format!("\n{SCREENSHOT_MARKDOWN_REF}"), "\n")
            .replace(SCREENSHOT_MARKDOWN_REF, "");
    }
}

impl App for LauncherApp {
    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        egui::Rgba::from_rgba_unmultiplied(0.0, 0.0, 0.0, 0.0).to_array()
    }

    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        if ctx.viewport_id() != egui::ViewportId::ROOT {
            return;
        }

        self.process_app_messages(ctx);
        self.apply_theme(ctx);
        self.apply_editor_task_results();
        self.apply_search_responses();

        let mut activate = false;
        let mut selection_moved = false;
        let mut escape_action: Option<EscapeAction> = None;
        let mut paste_from_clipboard = false;

        ctx.input(|input| {
            if input.key_pressed(Key::Escape) {
                if self.editor_open {
                    escape_action = Some(EscapeAction::CloseEditor);
                } else if self.hotkey_enabled {
                    escape_action = Some(EscapeAction::HideLauncher);
                } else {
                    escape_action = Some(EscapeAction::CloseApp);
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

            if self.editor_open && Self::paste_shortcut_pressed(input) {
                paste_from_clipboard = true;
            }
        });

        egui::CentralPanel::default()
            .frame(egui::Frame::none().fill(egui::Color32::TRANSPARENT))
            .show(ctx, |ui| {
                ui.vertical_centered(|ui| {
                    ui.add_space(10.0);
                    let shell_width = (ui.available_width() - 48.0).clamp(640.0, 1040.0);

                    egui::Frame::none()
                        .fill(egui::Color32::from_rgba_unmultiplied(250, 250, 250, 252))
                        .rounding(egui::Rounding::same(24.0))
                        .stroke(egui::Stroke::new(
                            1.0,
                            egui::Color32::from_rgba_unmultiplied(0, 0, 0, 35),
                        ))
                        .shadow(egui::epaint::Shadow {
                            offset: egui::vec2(0.0, 6.0),
                            blur: 28.0,
                            spread: 0.0,
                            color: egui::Color32::from_rgba_unmultiplied(0, 0, 0, 52),
                        })
                        .inner_margin(egui::Margin::same(14.0))
                        .show(ui, |ui| {
                            ui.set_width(shell_width);

                            ui.horizontal(|ui| {
                                let field_id = ui.make_persistent_id("alfred_search_input");
                                let search_w = (shell_width - 24.0).max(440.0);
                                let response = egui::Frame::none()
                                    .fill(egui::Color32::from_rgb(238, 238, 238))
                                    .rounding(egui::Rounding::same(12.0))
                                    .inner_margin(egui::Margin::symmetric(14.0, 10.0))
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
                                    self.schedule_search(false);
                                }

                                if response.lost_focus() && ui.input(|i| i.key_pressed(Key::Enter)) {
                                    activate = true;
                                }
                            });

                            if let Some(err) = &self.last_error {
                                ui.add_space(6.0);
                                ui.colored_label(egui::Color32::RED, format!("Error: {err}"));
                            }

                            if self.query.trim().is_empty() {
                                ui.add_space(16.0);
                                ui.vertical_centered(|ui| {
                                    ui.label(
                                        egui::RichText::new("Alfred Update Available")
                                            .size(18.0)
                                            .strong()
                                            .color(egui::Color32::from_gray(20)),
                                    );
                                });
                                ui.add_space(4.0);
                            } else {
                                ui.add_space(8.0);
                                if self.results.is_empty() {
                                    ui.label(
                                        egui::RichText::new(
                                            "No matching results. Press Enter to add this as a new entry.",
                                        )
                                        .italics()
                                        .color(egui::Color32::from_gray(95)),
                                    );
                                } else {
                                    let row_height = 60.0;
                                    let viewport_height = row_height * 5.0;
                                    egui::ScrollArea::vertical()
                                        .max_height(viewport_height)
                                        .show(ui, |ui| {
                                            for (idx, item) in self.results.iter().enumerate() {
                                                let is_sel = idx == self.selected;
                                                egui::Frame::none()
                                                    .inner_margin(egui::Margin::symmetric(10.0, 7.0))
                                                    .show(ui, |ui| {
                                                        let resp = ui.add(
                                                            egui::Label::new(
                                                                egui::RichText::new(&item.title)
                                                                    .size(20.0)
                                                                    .strong()
                                                                    .color(if is_sel {
                                                                        egui::Color32::from_gray(20)
                                                                    } else {
                                                                        egui::Color32::from_gray(35)
                                                                    }),
                                                            )
                                                            .sense(egui::Sense::click()),
                                                        );
                                                        if !item.subtitle.is_empty() {
                                                            ui.label(
                                                                egui::RichText::new(&item.subtitle)
                                                                    .size(14.0)
                                                                    .color(egui::Color32::from_gray(85)),
                                                            );
                                                        }

                                                        if let Some(snippet) = &item.snippet {
                                                            ui.horizontal_wrapped(|ui| {
                                                                if let Some(src) = &item.snippet_source {
                                                                    ui.label(
                                                                        egui::RichText::new(format!("{src}:"))
                                                                            .size(12.0)
                                                                            .color(egui::Color32::from_gray(95)),
                                                                    );
                                                                }
                                                                render_marked_snippet(ui, snippet, 12.0);
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

                                                if idx + 1 < self.results.len() {
                                                    ui.separator();
                                                }
                                            }
                                        });
                                }
                            }
                        });

                    ui.add_space(14.0);
                });
            });

        self.render_editor_modal(ctx);

        if let Some(action) = escape_action {
            match action {
                EscapeAction::CloseEditor => self.close_editor(ctx),
                EscapeAction::HideLauncher => self.hide_launcher(ctx),
                EscapeAction::CloseApp => ctx.send_viewport_cmd(egui::ViewportCommand::Close),
            }
        }

        if paste_from_clipboard {
            self.try_paste_clipboard_image();
        }

        self.dispatch_due_search(ctx);

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

fn capture_screenshot_bytes() -> Result<Option<Vec<u8>>, String> {
    let path = std::env::temp_dir().join(format!("alfred-alt-shot-{}.png", unix_time_secs()));
    match Command::new("screencapture").arg("-i").arg(&path).status() {
        Ok(status) if status.success() && path.exists() => {
            let read_result = std::fs::read(&path);
            let _ = std::fs::remove_file(&path);
            match read_result {
                Ok(bytes) => normalize_screenshot_for_storage(&bytes).map(Some),
                Err(err) => Err(format!("Could not read screenshot: {err}")),
            }
        }
        Ok(_) => Ok(None),
        Err(err) => Err(format!("screencapture failed: {err}")),
    }
}

fn decode_screenshot_bytes(bytes: &[u8]) -> Result<DecodedImage, String> {
    let img = image::load_from_memory(bytes)
        .map_err(|err| format!("Could not decode screenshot image: {err}"))?;
    let rgba = img.to_rgba8();
    Ok(DecodedImage {
        size: [rgba.width() as usize, rgba.height() as usize],
        rgba: rgba.into_raw(),
    })
}

fn normalize_screenshot_for_storage(bytes: &[u8]) -> Result<Vec<u8>, String> {
    if bytes.len() > SCREENSHOT_MAX_INPUT_BYTES {
        return Err(format!(
            "Screenshot is too large to process ({} MB max input)",
            SCREENSHOT_MAX_INPUT_BYTES / 1024 / 1024
        ));
    }

    let img = image::load_from_memory(bytes)
        .map_err(|err| format!("Could not decode screenshot image: {err}"))?;
    let (width, height) = img.dimensions();
    if width as u64 * height as u64 > SCREENSHOT_MAX_PIXELS {
        return Err(format!(
            "Screenshot resolution too large (max {} pixels)",
            SCREENSHOT_MAX_PIXELS
        ));
    }

    let processed =
        if width > SCREENSHOT_MAX_DIMENSION_WIDTH || height > SCREENSHOT_MAX_DIMENSION_HEIGHT {
            img.resize(
                SCREENSHOT_MAX_DIMENSION_WIDTH,
                SCREENSHOT_MAX_DIMENSION_HEIGHT,
                ResizeFilterType::Lanczos3,
            )
        } else {
            img
        };

    let rgba = processed.to_rgba8();
    let mut encoded = Vec::new();
    {
        let encoder =
            PngEncoder::new_with_quality(&mut encoded, CompressionType::Best, FilterType::Adaptive);
        encoder
            .write_image(
                rgba.as_raw(),
                rgba.width(),
                rgba.height(),
                ColorType::Rgba8.into(),
            )
            .map_err(|err| format!("Could not encode screenshot: {err}"))?;
    }

    if encoded.len() > MAX_SCREENSHOT_BYTES {
        return Err(format!(
            "Screenshot is too large to store after compression ({} KB limit)",
            MAX_SCREENSHOT_BYTES / 1024
        ));
    }

    Ok(encoded)
}

fn unix_time_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
