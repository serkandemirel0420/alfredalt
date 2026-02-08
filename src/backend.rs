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

#[uniffi::export]
pub fn backend_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[uniffi::export]
pub fn search_items(
    query: String,
    limit: Option<u32>,
) -> Result<Vec<SearchResultRecord>, BackendError> {
    let limit = normalize_limit(limit)?;
    let results = db::search(&query, i64::from(limit)).map_err(map_anyhow)?;
    Ok(results.into_iter().map(SearchResultRecord::from).collect())
}

#[uniffi::export]
pub fn create_item(title: String) -> Result<i64, BackendError> {
    let title = title.trim();
    if title.is_empty() {
        return Err(BackendError::Validation(
            "title must not be empty".to_string(),
        ));
    }

    db::insert_item(title).map_err(map_anyhow)
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

    let image_models: Vec<NoteImage> = images.into_iter().map(NoteImage::from).collect();
    db::update_item(item_id, &note, Some(&image_models)).map_err(map_anyhow)
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
    if message.contains("item not found") {
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
