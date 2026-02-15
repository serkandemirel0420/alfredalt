use crate::db;
use crate::models::{EditableItem, NoteImage, SearchResult};

const DEFAULT_SEARCH_LIMIT: u32 = 8;
const MAX_SEARCH_LIMIT: u32 = 64;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum BackendError {
    #[error("validation error: {0}")]
    Validation(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("storage error: {0}")]
    Storage(String),
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SearchResultRecord {
    pub id: i64,
    pub title: String,
    pub subtitle: String,
    pub snippet: Option<String>,
    pub snippet_source: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NoteImageRecord {
    pub image_key: String,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct EditableItemRecord {
    pub id: i64,
    pub title: String,
    pub note: String,
    pub images: Vec<NoteImageRecord>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ExportItemRecord {
    pub id: i64,
    pub title: String,
    pub subtitle: String,
    pub keywords: String,
    pub note: String,
    pub image_count: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DeletedItemRecord {
    pub archive_key: String,
    pub id: i64,
    pub title: String,
    pub deleted_at_unix_seconds: i64,
    pub image_count: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DeletedItemPreviewRecord {
    pub archive_key: String,
    pub id: i64,
    pub title: String,
    pub note: String,
    pub deleted_at_unix_seconds: i64,
    pub image_count: i64,
}

impl From<SearchResult> for SearchResultRecord {
    fn from(value: SearchResult) -> Self {
        Self {
            id: value.id,
            title: value.title,
            subtitle: value.subtitle,
            snippet: value.snippet,
            snippet_source: value.snippet_source,
        }
    }
}

impl From<NoteImage> for NoteImageRecord {
    fn from(value: NoteImage) -> Self {
        Self {
            image_key: value.image_key,
            bytes: value.bytes,
        }
    }
}

impl From<NoteImageRecord> for NoteImage {
    fn from(value: NoteImageRecord) -> Self {
        Self {
            image_key: value.image_key,
            bytes: value.bytes,
        }
    }
}

impl From<EditableItem> for EditableItemRecord {
    fn from(value: EditableItem) -> Self {
        Self {
            id: value.id,
            title: value.title,
            note: value.note,
            images: value
                .images
                .into_iter()
                .map(NoteImageRecord::from)
                .collect(),
        }
    }
}

impl From<db::ExportItem> for ExportItemRecord {
    fn from(value: db::ExportItem) -> Self {
        Self {
            id: value.id,
            title: value.title,
            subtitle: value.subtitle,
            keywords: value.keywords,
            note: value.note,
            image_count: value.image_count,
        }
    }
}

impl From<db::DeletedItemSummary> for DeletedItemRecord {
    fn from(value: db::DeletedItemSummary) -> Self {
        Self {
            archive_key: value.archive_key,
            id: value.id,
            title: value.title,
            deleted_at_unix_seconds: value.deleted_at_unix_seconds,
            image_count: value.image_count,
        }
    }
}

impl From<db::DeletedItemPreview> for DeletedItemPreviewRecord {
    fn from(value: db::DeletedItemPreview) -> Self {
        Self {
            archive_key: value.archive_key,
            id: value.id,
            title: value.title,
            note: value.note,
            deleted_at_unix_seconds: value.deleted_at_unix_seconds,
            image_count: value.image_count,
        }
    }
}

#[uniffi::export]
pub fn backend_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[uniffi::export]
pub fn search_items(
    query: String,
    limit: Option<u32>,
) -> Result<Vec<SearchResultRecord>, BackendError> {
    // Limit query length to prevent potential issues
    const MAX_QUERY_LENGTH: usize = 1024;
    let query = if query.len() > MAX_QUERY_LENGTH {
        query.chars().take(MAX_QUERY_LENGTH).collect()
    } else {
        query
    };

    let limit = normalize_limit(limit)?;
    let results = db::search(&query, i64::from(limit)).map_err(map_anyhow)?;
    Ok(results.into_iter().map(SearchResultRecord::from).collect())
}

#[uniffi::export]
pub fn create_item(title: String) -> Result<i64, BackendError> {
    // Sanitize and validate title
    const MAX_TITLE_LENGTH: usize = 10_000; // 10KB limit for title
    let title = sanitize_title(&title);
    let title = title.trim();

    if title.is_empty() {
        return Err(BackendError::Validation(
            "title must not be empty".to_string(),
        ));
    }

    if title.len() > MAX_TITLE_LENGTH {
        return Err(BackendError::Validation(
            "title exceeds maximum length".to_string(),
        ));
    }

    db::insert_item(title).map_err(map_anyhow)
}

/// Sanitize title by removing problematic characters
fn sanitize_title(title: &str) -> String {
    title
        .chars()
        .filter(|&c| {
            // Allow printable characters and common whitespace
            if c == '\n' || c == '\t' || c == '\r' {
                return true;
            }
            // Remove null bytes and other control characters
            if c < ' ' {
                return false;
            }
            // Remove replacement character and byte order mark
            if c == '\u{FFFD}' || c == '\u{FEFF}' {
                return false;
            }
            true
        })
        .collect()
}

#[uniffi::export]
pub fn get_item(item_id: i64) -> Result<EditableItemRecord, BackendError> {
    ensure_item_id(item_id)?;
    let item = db::fetch_item(item_id).map_err(map_anyhow)?;
    Ok(item.into())
}

#[uniffi::export]
pub fn save_item(
    item_id: i64,
    note: String,
    images: Vec<NoteImageRecord>,
) -> Result<(), BackendError> {
    ensure_item_id(item_id)?;

    // Validate note length (prevent excessively large notes that could cause issues)
    const MAX_NOTE_LENGTH: usize = 10_000_000; // 10MB limit
    if note.len() > MAX_NOTE_LENGTH {
        return Err(BackendError::Validation(
            "note exceeds maximum length".to_string(),
        ));
    }

    // Sanitize note: remove null bytes and other control characters that could cause issues
    let sanitized_note = sanitize_note_for_storage(&note);

    let image_models: Vec<NoteImage> = images.into_iter().map(NoteImage::from).collect();
    db::update_item(item_id, &sanitized_note, Some(&image_models)).map_err(map_anyhow)
}

#[uniffi::export]
pub fn rename_item(item_id: i64, title: String) -> Result<(), BackendError> {
    ensure_item_id(item_id)?;

    const MAX_TITLE_LENGTH: usize = 10_000; // 10KB limit for title
    let title = sanitize_title(&title);
    let title = title.trim();

    if title.is_empty() {
        return Err(BackendError::Validation(
            "title must not be empty".to_string(),
        ));
    }

    if title.len() > MAX_TITLE_LENGTH {
        return Err(BackendError::Validation(
            "title exceeds maximum length".to_string(),
        ));
    }

    db::rename_item(item_id, title).map_err(map_anyhow)
}

/// Sanitize note text by removing problematic characters
fn sanitize_note_for_storage(note: &str) -> String {
    note.chars()
        .filter(|&c| {
            // Allow printable characters and common whitespace
            if c == '\n' || c == '\t' || c == '\r' {
                return true;
            }
            // Remove null bytes and other control characters
            if c < ' ' {
                return false;
            }
            // Remove replacement character and other special unicode
            if c == '\u{FFFD}' || c == '\u{FEFF}' {
                return false;
            }
            true
        })
        .collect()
}

#[uniffi::export]
pub fn export_items() -> Result<Vec<ExportItemRecord>, BackendError> {
    let items = db::export_items_snapshot().map_err(map_anyhow)?;
    Ok(items.into_iter().map(ExportItemRecord::from).collect())
}

#[uniffi::export]
pub fn load_hotkey() -> Result<String, BackendError> {
    db::load_hotkey_setting().map_err(map_anyhow)
}

#[uniffi::export]
pub fn save_hotkey(hotkey: String) -> Result<(), BackendError> {
    let hotkey = hotkey.trim();
    if hotkey.is_empty() {
        return Err(BackendError::Validation(
            "hotkey must not be empty".to_string(),
        ));
    }

    db::save_hotkey_setting(hotkey).map_err(map_anyhow)
}

#[uniffi::export]
pub fn load_json_storage_path() -> Result<String, BackendError> {
    db::load_json_storage_path_setting().map_err(map_anyhow)
}

#[uniffi::export]
pub fn save_json_storage_path(path: String) -> Result<(), BackendError> {
    db::save_json_storage_path_setting(path.trim()).map_err(map_anyhow)
}

#[uniffi::export]
pub fn delete_item(item_id: i64) -> Result<(), BackendError> {
    ensure_item_id(item_id)?;
    db::delete_item(item_id).map_err(map_anyhow)
}

#[uniffi::export]
pub fn list_deleted_items(limit: Option<u32>) -> Result<Vec<DeletedItemRecord>, BackendError> {
    let limit = limit.unwrap_or(50).max(1).min(256);
    let items = db::list_deleted_items(i64::from(limit)).map_err(map_anyhow)?;
    Ok(items.into_iter().map(DeletedItemRecord::from).collect())
}

#[uniffi::export]
pub fn restore_deleted_item(archive_key: String) -> Result<i64, BackendError> {
    let archive_key = archive_key.trim();
    if archive_key.is_empty() {
        return Err(BackendError::Validation(
            "archive_key must not be empty".to_string(),
        ));
    }
    db::restore_deleted_item(archive_key).map_err(map_anyhow)
}

#[uniffi::export]
pub fn permanently_delete_deleted_item(archive_key: String) -> Result<(), BackendError> {
    let archive_key = archive_key.trim();
    if archive_key.is_empty() {
        return Err(BackendError::Validation(
            "archive_key must not be empty".to_string(),
        ));
    }
    db::permanently_delete_deleted_item(archive_key).map_err(map_anyhow)
}

#[uniffi::export]
pub fn get_deleted_item_preview(
    archive_key: String,
) -> Result<DeletedItemPreviewRecord, BackendError> {
    let archive_key = archive_key.trim();
    if archive_key.is_empty() {
        return Err(BackendError::Validation(
            "archive_key must not be empty".to_string(),
        ));
    }
    let preview = db::get_deleted_item_preview(archive_key).map_err(map_anyhow)?;
    Ok(DeletedItemPreviewRecord::from(preview))
}

#[uniffi::export]
pub fn get_item_json_path(item_id: i64) -> Result<String, BackendError> {
    ensure_item_id(item_id)?;
    db::get_item_json_path(item_id).map_err(map_anyhow)
}

fn ensure_item_id(item_id: i64) -> Result<(), BackendError> {
    if item_id <= 0 {
        return Err(BackendError::Validation(
            "item_id must be a positive integer".to_string(),
        ));
    }
    Ok(())
}

fn normalize_limit(limit: Option<u32>) -> Result<u32, BackendError> {
    let limit = limit.unwrap_or(DEFAULT_SEARCH_LIMIT);
    if limit == 0 {
        return Err(BackendError::Validation(
            "limit must be at least 1".to_string(),
        ));
    }

    Ok(limit.min(MAX_SEARCH_LIMIT))
}

fn map_anyhow(err: anyhow::Error) -> BackendError {
    let message = err.to_string();
    if message.contains("item not found") || message.contains("deleted archive not found") {
        return BackendError::NotFound("requested item does not exist".to_string());
    }

    if message.contains("too many note images")
        || message.contains("exceeds")
        || message.contains("must not")
    {
        return BackendError::Validation(message);
    }

    BackendError::Storage(message)
}
