#[cfg(target_os = "macos")]
use std::process::Command;
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use std::{
    collections::HashMap,
    collections::HashSet,
    collections::hash_map::DefaultHasher,
    hash::{Hash, Hasher},
};

use arboard::Clipboard;
use eframe::{App, egui};
use egui::{Color32, Key, TextEdit, text::LayoutJob, text::TextFormat};
use image::{
    ColorType, ImageBuffer, ImageEncoder, Rgba, RgbaImage,
    codecs::png::{CompressionType, FilterType, PngEncoder},
    imageops::FilterType as ResizeFilterType,
};

use crate::db::{
    MAX_NOTE_IMAGE_COUNT, MAX_SCREENSHOT_BYTES, fetch_item, insert_item, search, update_item,
};
use crate::hotkey::{HotKeyRegistration, setup_hotkey_listener};
use crate::models::{AppMessage, EditableItem, NoteImage, SearchResult};

const SEARCH_LIMIT: i64 = 8;
const SEARCH_DEBOUNCE_MS: u64 = 160;
const EDITOR_IDLE_AUTOSAVE_MS: u64 = 1200;
const LAUNCHER_DEFAULT_WIDTH: f32 = 1100.0;
const LAUNCHER_EMPTY_HEIGHT: f32 = 220.0;
const LAUNCHER_NO_RESULTS_HEIGHT: f32 = 250.0;
const LAUNCHER_RESULTS_BASE_HEIGHT: f32 = 190.0;
const LAUNCHER_RESULT_ROW_HEIGHT: f32 = 60.0;
const LAUNCHER_MAX_VISIBLE_ROWS: usize = 5;
const LAUNCHER_MAX_HEIGHT: f32 = 500.0;
const SCREENSHOT_MAX_DIMENSION_WIDTH: u32 = 1920;
const SCREENSHOT_MAX_DIMENSION_HEIGHT: u32 = 1080;
const SCREENSHOT_MAX_PIXELS: u64 = 8_294_400; // 3840x2160
const SCREENSHOT_MAX_INPUT_BYTES: usize = 20 * 1024 * 1024;
const NOTE_IMAGE_URL_PREFIX: &str = "alfred://image/";
const SCREENSHOT_MARKDOWN_REF: &str = "![image](alfred://image/main)";
const INLINE_IMAGE_PADDING_X: f32 = 6.0;
const INLINE_IMAGE_PADDING_Y: f32 = 6.0;
const INLINE_IMAGE_DEFAULT_WIDTH: f32 = 360.0;
const INLINE_IMAGE_MIN_WIDTH: f32 = 140.0;
const INLINE_IMAGE_MAX_WIDTH: f32 = 1200.0;
const INLINE_IMAGE_RESIZE_STEP: f32 = 80.0;
const INLINE_IMAGE_MAX_HEIGHT: f32 = 120.0;
const INLINE_IMAGE_ROW_HEIGHT: f32 = INLINE_IMAGE_MAX_HEIGHT + INLINE_IMAGE_PADDING_Y * 2.0;

fn markdown_image_ref(key: &str, width: Option<f32>) -> String {
    let width_suffix = width
        .and_then(|value| {
            if !value.is_finite() {
                return None;
            }
            let normalized = value.clamp(INLINE_IMAGE_MIN_WIDTH, INLINE_IMAGE_MAX_WIDTH);
            Some(format!("?w={}", normalized.round() as i32))
        })
        .unwrap_or_default();
    format!("![image]({}{key}{width_suffix})", NOTE_IMAGE_URL_PREFIX)
}

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

#[derive(Clone)]
struct ParsedImageRef {
    key: String,
    width: Option<f32>,
}

#[derive(Clone)]
struct InlineImageMarker {
    key: String,
    start_char: usize,
    end_char: usize,
    start_byte: usize,
    end_byte: usize,
    requested_width: Option<f32>,
}

#[derive(Default, Clone, Copy)]
struct EditorActions {
    remove_image: bool,
    shrink_image: bool,
    grow_image: bool,
}

enum EditorTask {
    SaveItem {
        item_id: i64,
        content_hash: u64,
        images_hash: u64,
        note: String,
        images: Option<Vec<NoteImage>>,
    },
}

enum EditorTaskResult {
    ItemSaved {
        item_id: i64,
        content_hash: u64,
        images_hash: u64,
        wrote_images: bool,
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
    editor_text_id: Option<egui::Id>,
    editor_needs_focus: bool,
    editor_dirty: bool,
    last_editor_edit: Option<Instant>,
    last_saved_editor_hash: Option<u64>,
    editor_images_hash: u64,
    editor_images_dirty: bool,
    save_in_flight: Option<(i64, u64)>,
    selected_image_key: Option<String>,
    editor_cursor_char_index: Option<usize>,
    inline_image_textures: HashMap<String, egui::TextureHandle>,
    inline_image_texture_viewport: Option<egui::ViewportId>,
    next_image_seq: u64,
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
    last_launcher_size: Option<[f32; 2]>,
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
            editor_text_id: None,
            editor_needs_focus: false,
            editor_dirty: false,
            last_editor_edit: None,
            last_saved_editor_hash: None,
            editor_images_hash: 0,
            editor_images_dirty: false,
            save_in_flight: None,
            selected_image_key: None,
            editor_cursor_char_index: None,
            inline_image_textures: HashMap::new(),
            inline_image_texture_viewport: None,
            next_image_seq: 0,
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
            last_launcher_size: None,
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
                    EditorTask::SaveItem {
                        item_id,
                        content_hash,
                        images_hash,
                        note,
                        images,
                    } => {
                        let wrote_images = images.is_some();
                        let result = update_item(item_id, &note, images.as_deref())
                            .map_err(|err| format!("Failed to save item: {err}"));
                        EditorTaskResult::ItemSaved {
                            item_id,
                            content_hash,
                            images_hash,
                            wrote_images,
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
        self.last_launcher_size = None;
        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
        self.needs_focus = true;
        ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
    }

    fn hide_launcher(&mut self, ctx: &egui::Context) {
        self.visible = false;
        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
    }

    fn desired_launcher_height(&self) -> f32 {
        if self.query.trim().is_empty() {
            return LAUNCHER_EMPTY_HEIGHT;
        }

        if self.results.is_empty() {
            return LAUNCHER_NO_RESULTS_HEIGHT;
        }

        let visible_rows = self.results.len().min(LAUNCHER_MAX_VISIBLE_ROWS) as f32;
        (LAUNCHER_RESULTS_BASE_HEIGHT + visible_rows * LAUNCHER_RESULT_ROW_HEIGHT)
            .clamp(LAUNCHER_NO_RESULTS_HEIGHT, LAUNCHER_MAX_HEIGHT)
    }

    fn sync_launcher_size(&mut self, ctx: &egui::Context) {
        if !self.visible || self.editor_open {
            return;
        }

        let target = [LAUNCHER_DEFAULT_WIDTH, self.desired_launcher_height()];
        let needs_resize = match self.last_launcher_size {
            Some(last) => {
                (last[0] - target[0]).abs() > f32::EPSILON
                    || (last[1] - target[1]).abs() > f32::EPSILON
            }
            None => true,
        };

        if needs_resize {
            ctx.send_viewport_cmd(egui::ViewportCommand::InnerSize(egui::vec2(
                target[0], target[1],
            )));
            self.last_launcher_size = Some(target);
        }
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
                let images_hash = Self::images_hash(&item.images);
                let initial_hash = Self::editor_content_hash(&item.note, images_hash);
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
                self.editor_images_hash = images_hash;
                self.editor_images_dirty = false;
                self.save_in_flight = None;
                self.selected_image_key = selected_image_key;
                self.editor_cursor_char_index = None;
                self.inline_image_textures.clear();
                self.inline_image_texture_viewport = None;
                self.next_image_seq = 0;
                self.editor_text_id = None;
                ctx.request_repaint();
            }
            Err(err) => {
                self.last_error = Some(format!("Failed to open item: {err}"));
            }
        }
    }

    fn queue_editor_save(&mut self) -> bool {
        if self.save_in_flight.is_some() {
            return false;
        }

        let Some(item) = self.editor_item.as_ref() else {
            return false;
        };

        let images_hash = self.editor_images_hash;
        let current_hash = Self::editor_content_hash(&item.note, images_hash);
        if self.last_saved_editor_hash == Some(current_hash) {
            self.editor_dirty = false;
            self.last_editor_edit = None;
            self.editor_images_dirty = false;
            return false;
        }

        let task = EditorTask::SaveItem {
            item_id: item.id,
            content_hash: current_hash,
            images_hash,
            note: item.note.clone(),
            images: self.editor_images_dirty.then(|| item.images.clone()),
        };
        if let Err(err) = self.editor_task_tx.send(task) {
            self.last_error = Some(format!("Failed to queue save: {err}"));
            return false;
        }

        self.save_in_flight = Some((item.id, current_hash));
        true
    }

    fn try_paste_clipboard_image(&mut self) {
        let mut clipboard = match Clipboard::new() {
            Ok(clipboard) => clipboard,
            Err(err) => {
                self.last_error = Some(format!("Clipboard unavailable: {err}"));
                return;
            }
        };

        let mut paste_error: Option<String> = None;

        match clipboard.get_image() {
            Ok(image) => {
                let rgba = match Self::clipboard_image_to_rgba(image) {
                    Ok(rgba) => rgba,
                    Err(err) => {
                        self.last_error =
                            Some(format!("Clipboard image format not supported: {err}"));
                        return;
                    }
                };

                match normalize_rgba_for_storage(rgba) {
                    Ok(stored_bytes) => {
                        self.add_image_to_editor(
                            stored_bytes,
                            "pasted",
                            self.editor_cursor_char_index,
                        );
                        self.last_error = None;
                        return;
                    }
                    Err(err) => {
                        self.last_error = Some(format!("Could not use pasted image: {err}"));
                        return;
                    }
                }
            }
            Err(arboard::Error::ContentNotAvailable) => {}
            Err(err) => {
                paste_error = Some(format!("Could not read clipboard image: {err}"));
            }
        }

        match Self::read_macos_clipboard_image() {
            Ok(Some(bytes)) => match normalize_screenshot_for_storage(&bytes) {
                Ok(stored_bytes) => {
                    self.add_image_to_editor(stored_bytes, "pasted", self.editor_cursor_char_index);
                    self.last_error = None;
                    return;
                }
                Err(err) => {
                    self.last_error = Some(format!("Could not use pasted image: {err}"));
                    return;
                }
            },
            Ok(None) => {}
            Err(err) => {
                if paste_error.is_none() {
                    paste_error = Some(err);
                }
            }
        }

        if let Some(err) = paste_error {
            self.last_error = Some(err);
        }
    }

    fn close_editor(&mut self, ctx: &egui::Context) {
        self.queue_editor_save();
        self.editor_open = false;
        self.editor_item = None;
        self.editor_text_id = None;
        self.editor_needs_focus = false;
        self.editor_dirty = false;
        self.last_editor_edit = None;
        self.last_saved_editor_hash = None;
        self.editor_images_hash = 0;
        self.editor_images_dirty = false;
        self.save_in_flight = None;
        self.selected_image_key = None;
        self.editor_cursor_char_index = None;
        self.inline_image_textures.clear();
        self.inline_image_texture_viewport = None;
        self.next_image_seq = 0;
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
        self.inline_image_textures.clear();
        self.inline_image_texture_viewport = None;
        if let Some(item) = self.editor_item.as_ref() {
            self.editor_images_hash = Self::images_hash(&item.images);
        }
        self.editor_images_dirty = true;
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

    fn resize_selected_image(&mut self, delta: f32) {
        if delta.abs() <= f32::EPSILON {
            return;
        }

        let Some(selected) = self.selected_image_key.clone() else {
            return;
        };
        if let Some(item) = self.editor_item.as_mut() {
            if Self::update_markdown_image_ref_width(&mut item.note, &selected, delta) {
                self.mark_screenshot_changed();
            }
        }
    }

    fn apply_editor_task_results(&mut self) {
        loop {
            match self.editor_task_rx.try_recv() {
                Ok(EditorTaskResult::ItemSaved {
                    item_id,
                    content_hash,
                    images_hash,
                    wrote_images,
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
                                if wrote_images && self.editor_images_hash == images_hash {
                                    self.editor_images_dirty = false;
                                }
                                if let Some(item) = self.editor_item.as_ref() {
                                    if Self::editor_content_hash(
                                        &item.note,
                                        self.editor_images_hash,
                                    ) == content_hash
                                    {
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

    fn editor_content_hash(note: &str, images_hash: u64) -> u64 {
        let mut hasher = DefaultHasher::new();
        note.hash(&mut hasher);
        images_hash.hash(&mut hasher);
        hasher.finish()
    }

    fn images_hash(images: &[NoteImage]) -> u64 {
        let mut hasher = DefaultHasher::new();
        images.len().hash(&mut hasher);
        for image in images {
            image.image_key.hash(&mut hasher);
            image.bytes.hash(&mut hasher);
        }
        hasher.finish()
    }

    fn add_image_to_editor(
        &mut self,
        bytes: Vec<u8>,
        label: &str,
        cursor_char_index: Option<usize>,
    ) {
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
            Self::insert_markdown_image_ref(&mut item.note, &key, cursor_char_index);
            self.selected_image_key = Some(key);
            self.mark_screenshot_changed();
        }
    }

    fn parse_markdown_image_line(line: &str) -> Option<ParsedImageRef> {
        let marker_prefix = "![image](";
        if !line.starts_with(marker_prefix) || !line.ends_with(')') {
            return None;
        }

        let url = &line[marker_prefix.len()..line.len() - 1];
        let url = url.strip_prefix(NOTE_IMAGE_URL_PREFIX)?;

        let (key, width) = if let Some((key, width)) = url.split_once("?w=") {
            let parsed = width
                .trim()
                .parse::<f32>()
                .ok()
                .filter(|value| value.is_finite() && *value > 0.0)
                .map(|value| value.clamp(INLINE_IMAGE_MIN_WIDTH, INLINE_IMAGE_MAX_WIDTH));
            (key, parsed)
        } else {
            (url, None)
        };

        if key.is_empty() {
            return None;
        }

        Some(ParsedImageRef {
            key: key.to_string(),
            width,
        })
    }

    fn inline_image_markers(note: &str) -> Vec<InlineImageMarker> {
        let mut markers = Vec::new();
        let mut byte_offset = 0usize;
        let mut char_offset = 0usize;

        for line_with_break in note.split_inclusive('\n') {
            let has_newline = line_with_break.ends_with('\n');
            let line = if has_newline {
                &line_with_break[..line_with_break.len() - 1]
            } else {
                line_with_break
            };

            if let Some(parsed) = Self::parse_markdown_image_line(line) {
                let line_char_count = line.chars().count();
                markers.push(InlineImageMarker {
                    key: parsed.key,
                    start_char: char_offset,
                    end_char: char_offset + line_char_count,
                    start_byte: byte_offset,
                    end_byte: byte_offset + line.len(),
                    requested_width: parsed.width,
                });
            }

            byte_offset += line_with_break.len();
            char_offset += line.chars().count();
            if has_newline {
                char_offset += 1;
            }
        }

        markers
    }

    fn image_marker_key_at_char(note: &str, char_index: usize) -> Option<String> {
        Self::inline_image_markers(note)
            .into_iter()
            .find(|marker| marker.start_char <= char_index && char_index <= marker.end_char)
            .map(|marker| marker.key)
    }

    fn reconcile_note_image_references(
        item: &mut EditableItem,
        selected_image_key: &mut Option<String>,
    ) -> bool {
        let original_note = item.note.clone();
        let mut rebuilt_note = String::with_capacity(original_note.len());
        let mut referenced_keys = HashSet::new();

        for line_with_break in original_note.split_inclusive('\n') {
            let has_newline = line_with_break.ends_with('\n');
            let line = if has_newline {
                &line_with_break[..line_with_break.len() - 1]
            } else {
                line_with_break
            };

            if let Some(parsed) = Self::parse_markdown_image_line(line) {
                referenced_keys.insert(parsed.key);
                rebuilt_note.push_str(line);
                if has_newline {
                    rebuilt_note.push('\n');
                }
                continue;
            }

            let trimmed = line.trim();
            if trimmed.starts_with("![image](")
                || trimmed.contains(NOTE_IMAGE_URL_PREFIX)
                || trimmed.contains("://image/")
            {
                // If a marker was partially deleted, strip the whole broken line so no raw path text remains.
                continue;
            }

            rebuilt_note.push_str(line);
            if has_newline {
                rebuilt_note.push('\n');
            }
        }

        let note_changed = rebuilt_note != original_note;
        if note_changed {
            item.note = rebuilt_note;
        }

        let fallback_main_key = if referenced_keys.contains("main")
            && !item.images.iter().any(|img| img.image_key == "main")
        {
            item.images.first().map(|img| img.image_key.clone())
        } else {
            None
        };

        let before_images = item.images.len();
        item.images.retain(|img| {
            referenced_keys.contains(&img.image_key)
                || fallback_main_key.as_deref() == Some(img.image_key.as_str())
        });
        let images_changed = item.images.len() != before_images;

        let selected_is_valid = selected_image_key
            .as_ref()
            .map(|selected| item.images.iter().any(|img| &img.image_key == selected))
            .unwrap_or(false);
        let mut selection_changed = false;
        if !selected_is_valid {
            let replacement = item.images.first().map(|img| img.image_key.clone());
            if *selected_image_key != replacement {
                *selected_image_key = replacement;
                selection_changed = true;
            }
        }

        note_changed || images_changed || selection_changed
    }

    fn layout_editor_note(
        ui: &egui::Ui,
        text: &str,
        wrap_width: f32,
    ) -> std::sync::Arc<egui::Galley> {
        let markers = Self::inline_image_markers(text);
        let mut job = LayoutJob::default();
        job.wrap.max_width = wrap_width;

        let base_format = TextFormat {
            font_id: egui::FontId::proportional(15.0),
            color: ui.visuals().text_color(),
            ..Default::default()
        };

        let mut marker_format = base_format.clone();
        marker_format.color = Color32::TRANSPARENT;
        marker_format.line_height = Some(INLINE_IMAGE_ROW_HEIGHT);

        let mut from = 0usize;
        for marker in markers {
            if from < marker.start_byte {
                job.append(&text[from..marker.start_byte], 0.0, base_format.clone());
            }
            job.append(
                &text[marker.start_byte..marker.end_byte],
                0.0,
                marker_format.clone(),
            );
            from = marker.end_byte;
        }
        if from < text.len() {
            job.append(&text[from..], 0.0, base_format);
        }
        if job.sections.is_empty() {
            job.append("", 0.0, TextFormat::default());
        }

        ui.fonts(|fonts| fonts.layout_job(job))
    }

    fn row_rect_for_char(galley: &egui::Galley, char_index: usize) -> Option<egui::Rect> {
        let mut cursor = 0usize;
        for row in &galley.rows {
            let row_chars = row.char_count_excluding_newline();
            if char_index <= cursor + row_chars {
                return Some(row.rect);
            }
            cursor += row.char_count_including_newline();
        }
        galley.rows.last().map(|row| row.rect)
    }

    fn ensure_inline_image_texture(
        &mut self,
        ctx: &egui::Context,
        key: &str,
    ) -> Option<egui::TextureHandle> {
        if self.inline_image_texture_viewport != Some(ctx.viewport_id()) {
            self.inline_image_textures.clear();
            self.inline_image_texture_viewport = Some(ctx.viewport_id());
        }

        if let Some(texture) = self.inline_image_textures.get(key) {
            return Some(texture.clone());
        }

        let (item_id, bytes) = {
            let item = self.editor_item.as_ref()?;
            let image = item
                .images
                .iter()
                .find(|img| img.image_key == key)
                .or_else(|| {
                    if key == "main" {
                        item.images.first()
                    } else {
                        None
                    }
                })?;
            (item.id, image.bytes.clone())
        };

        let decoded = decode_screenshot_bytes(&bytes).ok()?;
        let color_image =
            egui::ColorImage::from_rgba_unmultiplied(decoded.size, decoded.rgba.as_slice());
        let texture = ctx.load_texture(
            format!("note-inline-{item_id}-{key}"),
            color_image,
            egui::TextureOptions::LINEAR,
        );
        self.inline_image_textures
            .insert(key.to_string(), texture.clone());
        Some(texture)
    }

    fn paint_inline_images(
        &mut self,
        ctx: &egui::Context,
        ui: &mut egui::Ui,
        output: &egui::text_edit::TextEditOutput,
        note: &str,
    ) {
        let markers = Self::inline_image_markers(note);
        if markers.is_empty() {
            return;
        }

        let painter = ui.painter().with_clip_rect(output.text_clip_rect);
        for marker in markers {
            let Some(row_rect) = Self::row_rect_for_char(&output.galley, marker.start_char) else {
                continue;
            };
            let Some(texture) = self.ensure_inline_image_texture(ctx, &marker.key) else {
                continue;
            };

            let tex_size = texture.size_vec2();
            if tex_size.x <= 0.0 || tex_size.y <= 0.0 {
                continue;
            }

            let max_width = (output.text_clip_rect.width() - INLINE_IMAGE_PADDING_X * 2.0)
                .max(INLINE_IMAGE_MIN_WIDTH);
            let requested_width = marker
                .requested_width
                .unwrap_or(INLINE_IMAGE_DEFAULT_WIDTH)
                .clamp(INLINE_IMAGE_MIN_WIDTH, INLINE_IMAGE_MAX_WIDTH);
            let target_width = requested_width.min(max_width).min(tex_size.x);
            let scale = (target_width / tex_size.x)
                .min(INLINE_IMAGE_MAX_HEIGHT / tex_size.y)
                .min(1.0);
            let draw_size = tex_size * scale;

            let top_left = egui::pos2(
                output.galley_pos.x + row_rect.left() + INLINE_IMAGE_PADDING_X,
                output.galley_pos.y + row_rect.top() + INLINE_IMAGE_PADDING_Y,
            );
            let image_rect = egui::Rect::from_min_size(top_left, draw_size);
            let image_id =
                ui.make_persistent_id(("inline-image", marker.key.as_str(), marker.start_byte));
            let image_response = ui.interact(image_rect, image_id, egui::Sense::click());
            if image_response.clicked() {
                self.selected_image_key = Some(marker.key.clone());
            }

            painter.image(
                texture.id(),
                image_rect,
                egui::Rect::from_min_max(egui::Pos2::ZERO, egui::pos2(1.0, 1.0)),
                Color32::WHITE,
            );

            if self.selected_image_key.as_deref() == Some(marker.key.as_str()) {
                painter.rect_stroke(
                    image_rect.expand(1.5),
                    3.0,
                    egui::Stroke::new(1.5, Color32::from_rgb(80, 145, 214)),
                );
            }
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
        let mut note_changed = false;
        let mut image_state_changed = false;
        let mut actions = EditorActions::default();
        let is_dirty = self.editor_dirty;
        let mut inline_output: Option<egui::text_edit::TextEditOutput> = None;
        let mut note_for_inline: Option<String> = None;

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
                if !item.images.is_empty() {
                    if ui.button("Remove Image").clicked() {
                        actions.remove_image = true;
                    }

                    let can_resize = self
                        .selected_image_key
                        .as_ref()
                        .map(|selected| item.images.iter().any(|img| &img.image_key == selected))
                        .unwrap_or(false);
                    if ui
                        .add_enabled(can_resize, egui::Button::new("Image -"))
                        .clicked()
                    {
                        actions.shrink_image = true;
                    }
                    if ui
                        .add_enabled(can_resize, egui::Button::new("Image +"))
                        .clicked()
                    {
                        actions.grow_image = true;
                    }
                }
                ui.label(
                    egui::RichText::new(
                        "Paste with Cmd/Ctrl+V. Click an image to select, then use Image +/- to resize.",
                    )
                    .size(11.0)
                    .color(egui::Color32::from_gray(90)),
                );
            });
            ui.add_space(6.0);

            let controls_height = 32.0;
            let editor_height = (ui.available_height() - controls_height).max(200.0);
            let editor_id = ui.make_persistent_id("note_editor_modal_text");
            self.editor_text_id = Some(editor_id);

            ui.vertical(|ui| {
                ui.set_width(ui.available_width());
                let desired_rows = ((editor_height / 20.0).round() as usize).max(10);
                let mut layouter = |ui: &egui::Ui, text: &str, wrap_width: f32| {
                    Self::layout_editor_note(ui, text, wrap_width)
                };
                let output = TextEdit::multiline(&mut item.note)
                    .id_source(editor_id)
                    .desired_width(f32::INFINITY)
                    .desired_rows(desired_rows)
                    .font(egui::TextStyle::Body)
                    .layouter(&mut layouter)
                    .show(ui);

                if self.editor_needs_focus {
                    output.response.request_focus();
                    self.editor_needs_focus = false;
                }

                if output.response.changed() {
                    note_changed = true;
                    if Self::reconcile_note_image_references(item, &mut self.selected_image_key) {
                        image_state_changed = true;
                    }
                }

                if let Some(range) = output.state.cursor.char_range() {
                    let pos = range.primary.index.min(item.note.chars().count());
                    self.editor_cursor_char_index = Some(pos);
                    if let Some(key) = Self::image_marker_key_at_char(&item.note, pos) {
                        self.selected_image_key = Some(key);
                    }
                } else {
                    self.editor_cursor_char_index = Some(item.note.chars().count());
                }

                if !self
                    .selected_image_key
                    .as_ref()
                    .map(|selected| item.images.iter().any(|img| &img.image_key == selected))
                    .unwrap_or(false)
                {
                    self.selected_image_key = item.images.first().map(|img| img.image_key.clone());
                }

                note_for_inline = Some(item.note.clone());
                inline_output = Some(output);
            });

            if let Some(err) = &self.last_error {
                ui.add_space(4.0);
                ui.colored_label(egui::Color32::from_rgb(180, 40, 40), err);
            }
        }

        if note_changed {
            self.mark_editor_dirty();
        }
        if image_state_changed {
            self.inline_image_textures.clear();
            self.inline_image_texture_viewport = None;
        }

        if let (Some(output), Some(note)) = (inline_output.as_ref(), note_for_inline.as_deref()) {
            self.paint_inline_images(ctx, ui, output, note);
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
        let mut paste_now = false;
        let mut remove_image_now = false;
        let mut resize_image_delta = 0.0f32;
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
                            remove_image_now |= actions.remove_image;
                            if actions.shrink_image {
                                resize_image_delta -= INLINE_IMAGE_RESIZE_STEP;
                            }
                            if actions.grow_image {
                                resize_image_delta += INLINE_IMAGE_RESIZE_STEP;
                            }
                        });
                }
                egui::ViewportClass::Root
                | egui::ViewportClass::Deferred
                | egui::ViewportClass::Immediate => {
                    egui::CentralPanel::default().show(editor_ctx, |ui| {
                        let actions = self.render_editor_contents(editor_ctx, ui);
                        remove_image_now |= actions.remove_image;
                        if actions.shrink_image {
                            resize_image_delta -= INLINE_IMAGE_RESIZE_STEP;
                        }
                        if actions.grow_image {
                            resize_image_delta += INLINE_IMAGE_RESIZE_STEP;
                        }
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

            if remove_image_now {
                self.remove_selected_image();
                remove_image_now = false;
            }

            if resize_image_delta.abs() > f32::EPSILON {
                self.resize_selected_image(resize_image_delta);
                resize_image_delta = 0.0;
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

    fn read_macos_clipboard_image() -> Result<Option<Vec<u8>>, String> {
        #[cfg(target_os = "macos")]
        {
            for flavor in ["png", "tiff"] {
                let output = Command::new("pbpaste")
                    .args(["-Prefer", flavor])
                    .output()
                    .map_err(|err| format!("pbpaste failed: {err}"))?;
                if !output.status.success() || output.stdout.is_empty() {
                    continue;
                }
                if image::load_from_memory(&output.stdout).is_ok() {
                    return Ok(Some(output.stdout));
                }
            }
            Ok(None)
        }

        #[cfg(not(target_os = "macos"))]
        {
            Ok(None)
        }
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

    fn insert_markdown_image_ref(note: &mut String, key: &str, cursor_char_index: Option<usize>) {
        let marker = markdown_image_ref(key, Some(INLINE_IMAGE_DEFAULT_WIDTH));
        let total_chars = note.chars().count();
        let insert_chars = cursor_char_index.unwrap_or(total_chars).min(total_chars);
        let byte_index = note
            .char_indices()
            .nth(insert_chars)
            .map(|(i, _)| i)
            .unwrap_or_else(|| note.len());

        let needs_prefix_newline = byte_index > 0 && !note[..byte_index].ends_with('\n');
        let needs_suffix_newline = !note[byte_index..].starts_with('\n');

        let mut snippet = String::new();
        if needs_prefix_newline {
            snippet.push('\n');
        }
        snippet.push_str(&marker);
        if needs_suffix_newline {
            snippet.push('\n');
        }

        note.insert_str(byte_index, &snippet);
    }

    fn update_markdown_image_ref_width(note: &mut String, key: &str, delta: f32) -> bool {
        if delta.abs() <= f32::EPSILON {
            return false;
        }

        let mut changed = false;
        let mut rebuilt = String::with_capacity(note.len());
        for line_with_break in note.split_inclusive('\n') {
            let has_newline = line_with_break.ends_with('\n');
            let line = if has_newline {
                &line_with_break[..line_with_break.len() - 1]
            } else {
                line_with_break
            };

            if let Some(parsed) = Self::parse_markdown_image_line(line) {
                if parsed.key == key {
                    let current_width = parsed.width.unwrap_or(INLINE_IMAGE_DEFAULT_WIDTH);
                    let next_width = (current_width + delta)
                        .clamp(INLINE_IMAGE_MIN_WIDTH, INLINE_IMAGE_MAX_WIDTH);
                    let replacement = markdown_image_ref(&parsed.key, Some(next_width));
                    changed |= replacement != line;
                    rebuilt.push_str(&replacement);
                    if has_newline {
                        rebuilt.push('\n');
                    }
                    continue;
                }
            }

            rebuilt.push_str(line);
            if has_newline {
                rebuilt.push('\n');
            }
        }

        if changed {
            *note = rebuilt;
        }
        changed
    }

    fn remove_markdown_image_ref(note: &mut String, key: &str) {
        let mut rebuilt = String::with_capacity(note.len());
        let mut changed = false;

        for line_with_break in note.split_inclusive('\n') {
            let has_newline = line_with_break.ends_with('\n');
            let line = if has_newline {
                &line_with_break[..line_with_break.len() - 1]
            } else {
                line_with_break
            };

            let remove = if let Some(parsed) = Self::parse_markdown_image_line(line) {
                parsed.key == key || parsed.key == "main"
            } else {
                line == SCREENSHOT_MARKDOWN_REF
            };
            if remove {
                changed = true;
                continue;
            }

            rebuilt.push_str(line);
            if has_newline {
                rebuilt.push('\n');
            }
        }

        if changed {
            *note = rebuilt;
        }
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
                                    let viewport_height =
                                        LAUNCHER_RESULT_ROW_HEIGHT * LAUNCHER_MAX_VISIBLE_ROWS as f32;
                                    egui::ScrollArea::vertical()
                                        .max_height(viewport_height)
                                        .show(ui, |ui| {
                                            for (idx, item) in self.results.iter().enumerate() {
                                                let is_sel = idx == self.selected;
                                                let bg = if is_sel {
                                                    egui::Color32::from_rgb(230, 236, 245)
                                                } else {
                                                    egui::Color32::TRANSPARENT
                                                };

                                                egui::Frame::none()
                                                    .fill(bg)
                                                    .rounding(egui::Rounding::same(10.0))
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

        self.sync_launcher_size(ctx);
        self.render_editor_modal(ctx);

        if let Some(action) = escape_action {
            match action {
                EscapeAction::CloseEditor => self.close_editor(ctx),
                EscapeAction::HideLauncher => self.hide_launcher(ctx),
                EscapeAction::CloseApp => ctx.send_viewport_cmd(egui::ViewportCommand::Close),
            }
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

fn decode_screenshot_bytes(bytes: &[u8]) -> Result<DecodedImage, String> {
    let img = image::load_from_memory(bytes)
        .map_err(|err| format!("Could not decode screenshot image: {err}"))?;
    let rgba = img.to_rgba8();
    Ok(DecodedImage {
        size: [rgba.width() as usize, rgba.height() as usize],
        rgba: rgba.into_raw(),
    })
}

fn encode_png_with_compression(
    rgba: &RgbaImage,
    compression: CompressionType,
) -> Result<Vec<u8>, String> {
    let mut encoded = Vec::new();
    let encoder = PngEncoder::new_with_quality(&mut encoded, compression, FilterType::Adaptive);
    encoder
        .write_image(
            rgba.as_raw(),
            rgba.width(),
            rgba.height(),
            ColorType::Rgba8.into(),
        )
        .map_err(|err| format!("Could not encode screenshot: {err}"))?;
    Ok(encoded)
}

fn encode_png_for_storage(rgba: &RgbaImage) -> Result<Vec<u8>, String> {
    // Prioritize responsiveness: try fast compression first, then fall back to best
    // only when needed to fit storage limits.
    let fast = encode_png_with_compression(rgba, CompressionType::Fast)?;
    if fast.len() <= MAX_SCREENSHOT_BYTES {
        return Ok(fast);
    }

    let best = encode_png_with_compression(rgba, CompressionType::Best)?;
    if best.len() <= MAX_SCREENSHOT_BYTES {
        return Ok(best);
    }

    Err(format!(
        "Screenshot is too large to store after compression ({} KB limit)",
        MAX_SCREENSHOT_BYTES / 1024
    ))
}

fn normalize_rgba_for_storage(rgba: RgbaImage) -> Result<Vec<u8>, String> {
    let (width, height) = rgba.dimensions();
    if width as u64 * height as u64 > SCREENSHOT_MAX_PIXELS {
        return Err(format!(
            "Screenshot resolution too large (max {} pixels)",
            SCREENSHOT_MAX_PIXELS
        ));
    }

    let processed =
        if width > SCREENSHOT_MAX_DIMENSION_WIDTH || height > SCREENSHOT_MAX_DIMENSION_HEIGHT {
            image::DynamicImage::ImageRgba8(rgba)
                .resize(
                    SCREENSHOT_MAX_DIMENSION_WIDTH,
                    SCREENSHOT_MAX_DIMENSION_HEIGHT,
                    ResizeFilterType::Triangle,
                )
                .to_rgba8()
        } else {
            rgba
        };

    encode_png_for_storage(&processed)
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
    normalize_rgba_for_storage(img.to_rgba8())
}

fn unix_time_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
