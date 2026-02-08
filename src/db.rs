use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, anyhow, ensure};
use directories::ProjectDirs;
use once_cell::sync::OnceCell;
use serde::{Deserialize, Serialize};
use tantivy::collector::TopDocs;
use tantivy::query::{AllQuery, BooleanQuery, Occur, QueryParser, TermQuery};
use tantivy::schema::{Field, INDEXED, IndexRecordOption, STORED, STRING, Schema, TEXT, Value};
use tantivy::{Index, IndexReader, IndexWriter, TantivyDocument, Term, doc};

use crate::models::{EditableItem, NoteImage, SearchResult};

static STORE: OnceCell<Mutex<Store>> = OnceCell::new();
pub const MAX_SCREENSHOT_BYTES: usize = 12_000_000;
pub const MAX_NOTE_IMAGE_COUNT: usize = 24;
pub const DEFAULT_HOTKEY: &str = "super+Space";
const HOTKEY_SETTING_KEY: &str = "launcher_hotkey";
const FUZZY_QUERY_TERM_MIN_CHARS: usize = 4;
const FUZZY_SIMILARITY_THRESHOLD: f32 = 0.62;
const FUZZY_SCAN_MULTIPLIER: i64 = 64;
const FUZZY_SCAN_MAX_ROWS: i64 = 2048;
const INDEX_DIR_NAME: &str = "alfred_lucene_index";
const LEGACY_INDEX_DIR_NAME: &str = "alfred_search_index";
const LEGACY_DATA_FILE_NAME: &str = "alfred_store.json";
const LEGACY_DATA_TMP_FILE_NAME: &str = "alfred_store.json.tmp";
const LEGACY_DB_FILE_NAME: &str = "alfred.db";
const LEGACY_DB_WAL_FILE_NAME: &str = "alfred.db-wal";
const LEGACY_DB_SHM_FILE_NAME: &str = "alfred.db-shm";
const INDEX_WRITER_HEAP_BYTES: usize = 50_000_000;
const DOC_TYPE_ITEM: &str = "item";
const DOC_TYPE_SETTING: &str = "setting";

#[derive(Debug, Clone, Serialize)]
pub struct ExportItem {
    pub id: i64,
    pub title: String,
    pub subtitle: String,
    pub keywords: String,
    pub note: String,
    pub image_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedImage {
    image_key: String,
    bytes: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedItem {
    id: i64,
    title: String,
    subtitle: String,
    keywords: String,
    note: String,
    images: Vec<PersistedImage>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct PersistedData {
    next_item_id: i64,
    settings: HashMap<String, String>,
    items: BTreeMap<i64, PersistedItem>,
}

#[derive(Debug, Clone, Copy)]
struct SearchFields {
    doc_type: Field,
    id: Field,
    title: Field,
    subtitle: Field,
    keywords: Field,
    note: Field,
    images_json: Field,
    setting_key: Field,
    setting_value: Field,
}

struct Store {
    data: PersistedData,
    index: Index,
    writer: IndexWriter,
    reader: IndexReader,
    fields: SearchFields,
}

fn project_data_dir() -> Result<PathBuf> {
    let proj =
        ProjectDirs::from("com", "Codex", "alfred_alt").context("Cannot determine project dirs")?;
    Ok(proj.data_dir().to_path_buf())
}

fn index_path() -> Result<PathBuf> {
    Ok(project_data_dir()?.join(INDEX_DIR_NAME))
}

fn get_store() -> Result<&'static Mutex<Store>> {
    STORE.get_or_try_init(|| {
        let mut store = Store::open()?;
        store.ensure_seed_data();
        store.flush_all()?;
        Ok(Mutex::new(store))
    })
}

fn run_with_store<T, F>(mut operation: F) -> Result<T>
where
    F: FnMut(&mut Store) -> Result<T>,
{
    let store = get_store()?;
    let mut guard = store.lock().unwrap();
    operation(&mut guard)
}

impl Store {
    fn open() -> Result<Self> {
        let data_dir = project_data_dir()?;
        std::fs::create_dir_all(&data_dir)?;
        purge_legacy_storage_files(&data_dir)?;

        let index_path = index_path()?;
        let (index, fields) = open_or_rebuild_index(&index_path)?;
        let writer = index
            .writer(INDEX_WRITER_HEAP_BYTES)
            .context("failed to create Lucene writer")?;
        let reader = index.reader().context("failed to create Lucene reader")?;
        let mut data = load_data_from_lucene(&reader, &fields)?;
        if data.next_item_id <= 0 {
            data.next_item_id = 1;
        }

        Ok(Self {
            data,
            index,
            writer,
            reader,
            fields,
        })
    }

    fn ensure_seed_data(&mut self) {
        self.data
            .settings
            .entry(HOTKEY_SETTING_KEY.to_string())
            .or_insert_with(|| DEFAULT_HOTKEY.to_string());
    }

    fn flush_all(&mut self) -> Result<()> {
        self.rebuild_index()
    }

    fn rebuild_index(&mut self) -> Result<()> {
        self.writer
            .delete_all_documents()
            .context("failed to clear Lucene index")?;

        for item in self.data.items.values() {
            self.writer
                .add_document(self.build_item_document(item))
                .context("failed to add Lucene item document")?;
        }

        for (key, value) in &self.data.settings {
            self.writer
                .add_document(self.build_setting_document(key, value))
                .context("failed to add Lucene setting document")?;
        }

        self.writer
            .commit()
            .context("failed to commit Lucene index")?;
        self.reader
            .reload()
            .context("failed to reload Lucene reader")?;
        Ok(())
    }

    fn build_item_document(&self, item: &PersistedItem) -> TantivyDocument {
        let images_json = serde_json::to_string(&item.images).unwrap_or_else(|_| "[]".to_string());
        doc!(
            self.fields.doc_type => DOC_TYPE_ITEM,
            self.fields.id => item.id,
            self.fields.title => item.title.clone(),
            self.fields.subtitle => item.subtitle.clone(),
            self.fields.keywords => item.keywords.clone(),
            self.fields.note => item.note.clone(),
            self.fields.images_json => images_json
        )
    }

    fn build_setting_document(&self, key: &str, value: &str) -> TantivyDocument {
        doc!(
            self.fields.doc_type => DOC_TYPE_SETTING,
            self.fields.setting_key => key.to_string(),
            self.fields.setting_value => value.to_string()
        )
    }

    fn next_item_id(&mut self) -> i64 {
        let id = self.data.next_item_id.max(1);
        self.data.next_item_id = id.saturating_add(1);
        id
    }

    fn item_by_id(&self, id: i64) -> Option<&PersistedItem> {
        self.data.items.get(&id)
    }

    fn item_by_id_mut(&mut self, id: i64) -> Option<&mut PersistedItem> {
        self.data.items.get_mut(&id)
    }

    fn ordered_items_for_listing(&self) -> Vec<&PersistedItem> {
        let mut items: Vec<&PersistedItem> = self.data.items.values().collect();
        items.sort_by(|left, right| {
            left.title
                .to_lowercase()
                .cmp(&right.title.to_lowercase())
                .then_with(|| left.id.cmp(&right.id))
        });
        items
    }

    fn ordered_items_by_id_asc(&self) -> Vec<&PersistedItem> {
        self.data.items.values().collect()
    }

    fn ordered_items_by_id_desc(&self) -> Vec<&PersistedItem> {
        self.data.items.values().rev().collect()
    }

    fn lucene_search_ids(&mut self, query: &str, limit: usize) -> Result<Vec<i64>> {
        if limit == 0 {
            return Ok(Vec::new());
        }

        let Some(lucene_query) = build_lucene_query(query) else {
            return Ok(Vec::new());
        };

        self.reader
            .reload()
            .context("failed to refresh Lucene reader")?;
        let searcher = self.reader.searcher();

        let mut parser = QueryParser::for_index(
            &self.index,
            vec![
                self.fields.title,
                self.fields.subtitle,
                self.fields.keywords,
                self.fields.note,
            ],
        );
        parser.set_conjunction_by_default();

        let text_query = match parser.parse_query(&lucene_query) {
            Ok(query) => query,
            Err(_) => return Ok(Vec::new()),
        };

        let item_filter = TermQuery::new(
            Term::from_field_text(self.fields.doc_type, DOC_TYPE_ITEM),
            IndexRecordOption::Basic,
        );
        let query = BooleanQuery::new(vec![
            (Occur::Must, Box::new(item_filter)),
            (Occur::Must, text_query),
        ]);

        let top_docs = searcher
            .search(&query, &TopDocs::with_limit(limit))
            .context("failed to execute Lucene search")?;

        let mut ids = Vec::with_capacity(top_docs.len());
        for (_, addr) in top_docs {
            let doc: TantivyDocument = searcher
                .doc(addr)
                .context("failed to load Lucene document")?;
            if let Some(id) = doc
                .get_first(self.fields.id)
                .and_then(|value| value.as_i64())
            {
                ids.push(id);
            }
        }

        Ok(ids)
    }
}

fn open_or_rebuild_index(path: &Path) -> Result<(Index, SearchFields)> {
    if path.exists() {
        match Index::open_in_dir(path) {
            Ok(index) => {
                if let Some(fields) = resolve_fields(&index.schema()) {
                    return Ok((index, fields));
                }
            }
            Err(_) => {}
        }

        backup_corrupt_path(path)?;
    }

    std::fs::create_dir_all(path)?;
    let (schema, fields) = build_index_schema();
    let index = Index::create_in_dir(path, schema)?;
    Ok((index, fields))
}

fn build_index_schema() -> (Schema, SearchFields) {
    let mut builder = Schema::builder();
    let doc_type = builder.add_text_field("doc_type", STRING | STORED);
    let id = builder.add_i64_field("id", INDEXED | STORED);
    let title = builder.add_text_field("title", TEXT | STORED);
    let subtitle = builder.add_text_field("subtitle", TEXT | STORED);
    let keywords = builder.add_text_field("keywords", TEXT | STORED);
    let note = builder.add_text_field("note", TEXT | STORED);
    let images_json = builder.add_text_field("images_json", STORED);
    let setting_key = builder.add_text_field("setting_key", STRING | STORED);
    let setting_value = builder.add_text_field("setting_value", STORED);
    let schema = builder.build();

    (
        schema,
        SearchFields {
            doc_type,
            id,
            title,
            subtitle,
            keywords,
            note,
            images_json,
            setting_key,
            setting_value,
        },
    )
}

fn resolve_fields(schema: &Schema) -> Option<SearchFields> {
    Some(SearchFields {
        doc_type: schema.get_field("doc_type").ok()?,
        id: schema.get_field("id").ok()?,
        title: schema.get_field("title").ok()?,
        subtitle: schema.get_field("subtitle").ok()?,
        keywords: schema.get_field("keywords").ok()?,
        note: schema.get_field("note").ok()?,
        images_json: schema.get_field("images_json").ok()?,
        setting_key: schema.get_field("setting_key").ok()?,
        setting_value: schema.get_field("setting_value").ok()?,
    })
}

fn load_data_from_lucene(reader: &IndexReader, fields: &SearchFields) -> Result<PersistedData> {
    reader
        .reload()
        .context("failed to refresh Lucene reader while loading data")?;
    let searcher = reader.searcher();
    let total_docs = searcher.num_docs().max(1) as usize;

    let docs = searcher
        .search(&AllQuery, &TopDocs::with_limit(total_docs))
        .context("failed to scan Lucene documents")?;

    let mut data = PersistedData::default();

    for (_, addr) in docs {
        let doc: TantivyDocument = searcher
            .doc(addr)
            .context("failed to read Lucene document while loading data")?;

        let doc_type = doc
            .get_first(fields.doc_type)
            .and_then(|value| value.as_str())
            .unwrap_or("");

        match doc_type {
            DOC_TYPE_ITEM => {
                let Some(id) = doc.get_first(fields.id).and_then(|value| value.as_i64()) else {
                    continue;
                };

                let title = doc
                    .get_first(fields.title)
                    .and_then(|value| value.as_str())
                    .unwrap_or("")
                    .to_string();
                let subtitle = doc
                    .get_first(fields.subtitle)
                    .and_then(|value| value.as_str())
                    .unwrap_or("")
                    .to_string();
                let keywords = doc
                    .get_first(fields.keywords)
                    .and_then(|value| value.as_str())
                    .unwrap_or("")
                    .to_string();
                let note = doc
                    .get_first(fields.note)
                    .and_then(|value| value.as_str())
                    .unwrap_or("")
                    .to_string();

                let images_json = doc
                    .get_first(fields.images_json)
                    .and_then(|value| value.as_str())
                    .unwrap_or("[]");
                let images = serde_json::from_str::<Vec<PersistedImage>>(images_json)
                    .unwrap_or_else(|_| Vec::new());

                data.items.insert(
                    id,
                    PersistedItem {
                        id,
                        title,
                        subtitle,
                        keywords,
                        note,
                        images,
                    },
                );
                data.next_item_id = data.next_item_id.max(id.saturating_add(1));
            }
            DOC_TYPE_SETTING => {
                let Some(key) = doc
                    .get_first(fields.setting_key)
                    .and_then(|value| value.as_str())
                else {
                    continue;
                };
                let value = doc
                    .get_first(fields.setting_value)
                    .and_then(|value| value.as_str())
                    .unwrap_or("")
                    .to_string();

                data.settings.insert(key.to_string(), value);
            }
            _ => {}
        }
    }

    if data.next_item_id <= 0 {
        data.next_item_id = 1;
    }

    Ok(data)
}

fn purge_legacy_storage_files(data_dir: &Path) -> Result<()> {
    for filename in [
        LEGACY_DATA_FILE_NAME,
        LEGACY_DATA_TMP_FILE_NAME,
        LEGACY_DB_FILE_NAME,
        LEGACY_DB_WAL_FILE_NAME,
        LEGACY_DB_SHM_FILE_NAME,
    ] {
        let path = data_dir.join(filename);
        if !path.exists() {
            continue;
        }

        if path.is_dir() {
            std::fs::remove_dir_all(&path)
                .with_context(|| format!("failed removing legacy directory {}", path.display()))?;
        } else {
            std::fs::remove_file(&path)
                .with_context(|| format!("failed removing legacy file {}", path.display()))?;
        }
    }

    let legacy_index_dir = data_dir.join(LEGACY_INDEX_DIR_NAME);
    if legacy_index_dir.exists() {
        std::fs::remove_dir_all(&legacy_index_dir).with_context(|| {
            format!(
                "failed removing legacy index directory {}",
                legacy_index_dir.display()
            )
        })?;
    }

    for entry in std::fs::read_dir(data_dir)? {
        let entry = entry?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
            continue;
        };

        if name.starts_with("alfred.db.corrupt.") || name.starts_with("alfred_store.json.corrupt.")
        {
            std::fs::remove_file(&path).with_context(|| {
                format!("failed removing legacy backup file {}", path.display())
            })?;
        }
    }

    Ok(())
}

fn backup_corrupt_path(path: &Path) -> Result<()> {
    let stamp = unix_timestamp();
    let backup = PathBuf::from(format!("{}.corrupt.{stamp}", path.display()));
    std::fs::rename(path, &backup).with_context(|| {
        format!(
            "failed to move corrupt storage from {} to {}",
            path.display(),
            backup.display()
        )
    })?;
    Ok(())
}

fn unix_timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub fn load_hotkey_setting() -> Result<String> {
    run_with_store(|store| {
        Ok(store
            .data
            .settings
            .get(HOTKEY_SETTING_KEY)
            .cloned()
            .unwrap_or_else(|| DEFAULT_HOTKEY.to_string()))
    })
}

pub fn save_hotkey_setting(value: &str) -> Result<()> {
    run_with_store(|store| {
        store
            .data
            .settings
            .insert(HOTKEY_SETTING_KEY.to_string(), value.to_string());
        store.flush_all()
    })
}

pub fn search(query: &str, limit: i64) -> Result<Vec<SearchResult>> {
    run_with_store(|store| {
        let limit = limit.max(0);
        if limit == 0 {
            return Ok(Vec::new());
        }

        let query = query.trim();
        if query.is_empty() {
            let rows = store
                .ordered_items_for_listing()
                .into_iter()
                .take(limit as usize)
                .map(|item| SearchResult {
                    id: item.id,
                    title: item.title.clone(),
                    subtitle: item.subtitle.clone(),
                    snippet: None,
                    snippet_source: None,
                })
                .collect();
            return Ok(rows);
        }

        let query_terms = parse_query_terms(query);
        let mut results = Vec::with_capacity(limit as usize);
        let mut seen_ids = HashSet::with_capacity(limit as usize);

        let lucene_ids = store.lucene_search_ids(query, limit as usize)?;
        for id in lucene_ids {
            if !seen_ids.insert(id) {
                continue;
            }

            let Some(item) = store.item_by_id(id) else {
                continue;
            };

            results.push(map_search_item(item, &query_terms));
            if results.len() as i64 >= limit {
                return Ok(results);
            }
        }

        if (results.len() as i64) < limit {
            let remaining = (limit - results.len() as i64) as usize;
            let substring_rows = substring_search_rows(
                store.ordered_items_by_id_asc(),
                query,
                &query_terms,
                remaining,
                &seen_ids,
            );

            for row in substring_rows {
                if seen_ids.insert(row.id) {
                    results.push(row);
                    if results.len() as i64 >= limit {
                        return Ok(results);
                    }
                }
            }
        }

        if (results.len() as i64) < limit {
            let remaining = limit - results.len() as i64;
            let fuzzy_rows = fuzzy_search_rows(
                store.ordered_items_by_id_desc(),
                &query_terms,
                remaining,
                &seen_ids,
            );

            for row in fuzzy_rows {
                if seen_ids.insert(row.id) {
                    results.push(row);
                    if results.len() as i64 >= limit {
                        break;
                    }
                }
            }
        }

        Ok(results)
    })
}

fn substring_search_rows(
    items: Vec<&PersistedItem>,
    query: &str,
    query_terms: &[String],
    limit: usize,
    seen_ids: &HashSet<i64>,
) -> Vec<SearchResult> {
    if limit == 0 {
        return Vec::new();
    }

    let mut output = Vec::new();
    for item in items {
        if seen_ids.contains(&item.id) {
            continue;
        }

        if contains_case_insensitive(&item.title, query)
            || contains_case_insensitive(&item.note, query)
        {
            output.push(map_search_item(item, query_terms));
            if output.len() >= limit {
                break;
            }
        }
    }

    output
}

fn contains_case_insensitive(text: &str, needle: &str) -> bool {
    text.to_lowercase().contains(&needle.to_lowercase())
}

fn map_search_item(item: &PersistedItem, query_terms: &[String]) -> SearchResult {
    let snippet_data = build_snippet_with_terms(
        &item.title,
        &item.subtitle,
        &item.keywords,
        &item.note,
        query_terms,
    );

    SearchResult {
        id: item.id,
        title: item.title.clone(),
        subtitle: String::new(),
        snippet: snippet_data.map(|(_, text)| text),
        snippet_source: None,
    }
}

fn fuzzy_search_rows(
    items_by_recent_id: Vec<&PersistedItem>,
    query_terms: &[String],
    limit: i64,
    seen_ids: &HashSet<i64>,
) -> Vec<SearchResult> {
    if limit <= 0 {
        return Vec::new();
    }

    let has_fuzzy_term = query_terms
        .iter()
        .any(|term| term.chars().count() >= FUZZY_QUERY_TERM_MIN_CHARS);
    if !has_fuzzy_term {
        return Vec::new();
    }

    let scan_limit = (limit.max(8) * FUZZY_SCAN_MULTIPLIER).min(FUZZY_SCAN_MAX_ROWS);

    let mut scored: Vec<FuzzyCandidate> = Vec::new();
    for item in items_by_recent_id.into_iter().take(scan_limit as usize) {
        if seen_ids.contains(&item.id) {
            continue;
        }

        let score = fuzzy_row_score(&item.title, &item.note, query_terms);
        if score < FUZZY_SIMILARITY_THRESHOLD {
            continue;
        }

        scored.push(FuzzyCandidate {
            score,
            id: item.id,
            title: item.title.clone(),
            subtitle: item.subtitle.clone(),
            keywords: item.keywords.clone(),
            note: item.note.clone(),
        });
    }

    scored.sort_by(|left, right| {
        right
            .score
            .partial_cmp(&left.score)
            .unwrap_or(Ordering::Equal)
            .then_with(|| left.title.cmp(&right.title))
            .then_with(|| left.id.cmp(&right.id))
    });

    scored
        .into_iter()
        .take(limit as usize)
        .map(|candidate| {
            let snippet_data = build_snippet_with_terms(
                &candidate.title,
                &candidate.subtitle,
                &candidate.keywords,
                &candidate.note,
                query_terms,
            );
            SearchResult {
                id: candidate.id,
                title: candidate.title,
                subtitle: String::new(),
                snippet: snippet_data.map(|(_, text)| text),
                snippet_source: None,
            }
        })
        .collect()
}

struct FuzzyCandidate {
    score: f32,
    id: i64,
    title: String,
    subtitle: String,
    keywords: String,
    note: String,
}

pub fn insert_item(title: &str) -> Result<i64> {
    run_with_store(|store| {
        let id = store.next_item_id();
        store.data.items.insert(
            id,
            PersistedItem {
                id,
                title: title.to_string(),
                subtitle: String::new(),
                keywords: title.to_string(),
                note: String::new(),
                images: Vec::new(),
            },
        );
        store.flush_all()?;
        Ok(id)
    })
}

pub fn fetch_item(id: i64) -> Result<EditableItem> {
    run_with_store(|store| {
        let item = store
            .item_by_id(id)
            .ok_or_else(|| anyhow!("item not found: {id}"))?;

        let images = item
            .images
            .iter()
            .map(|image| NoteImage {
                image_key: image.image_key.clone(),
                bytes: image.bytes.clone(),
            })
            .collect();

        Ok(EditableItem {
            id: item.id,
            title: item.title.clone(),
            note: item.note.clone(),
            images,
        })
    })
}

pub fn export_items_snapshot() -> Result<Vec<ExportItem>> {
    run_with_store(|store| {
        let mut rows: Vec<ExportItem> = store
            .data
            .items
            .values()
            .map(|item| ExportItem {
                id: item.id,
                title: item.title.clone(),
                subtitle: item.subtitle.clone(),
                keywords: item.keywords.clone(),
                note: item.note.clone(),
                image_count: item.images.len() as i64,
            })
            .collect();

        rows.sort_by(|left, right| {
            left.title
                .to_lowercase()
                .cmp(&right.title.to_lowercase())
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok(rows)
    })
}

pub fn update_item(id: i64, note: &str, images: Option<&[NoteImage]>) -> Result<()> {
    if let Some(images) = images {
        ensure!(
            images.len() <= MAX_NOTE_IMAGE_COUNT,
            "too many note images (max {MAX_NOTE_IMAGE_COUNT})"
        );

        for image in images {
            ensure!(
                image.bytes.len() <= MAX_SCREENSHOT_BYTES,
                "image '{}' exceeds {} KB storage limit",
                image.image_key,
                MAX_SCREENSHOT_BYTES / 1024
            );
        }
    }

    run_with_store(|store| {
        let Some(item) = store.item_by_id_mut(id) else {
            if matches!(images, Some(imgs) if !imgs.is_empty()) {
                return Err(anyhow!("item not found: {id}"));
            }
            return Ok(());
        };

        item.note = note.to_string();

        if let Some(images) = images {
            item.images = images
                .iter()
                .map(|image| PersistedImage {
                    image_key: image.image_key.clone(),
                    bytes: image.bytes.clone(),
                })
                .collect();
        }

        store.flush_all()
    })
}
#[cfg(test)]
fn build_snippet(
    title: &str,
    subtitle: &str,
    keywords: &str,
    note: &str,
    query: &str,
) -> Option<(String, String)> {
    let query_terms = parse_query_terms(query);
    build_snippet_with_terms(title, subtitle, keywords, note, &query_terms)
}

fn build_snippet_with_terms(
    title: &str,
    subtitle: &str,
    keywords: &str,
    note: &str,
    query_terms: &[String],
) -> Option<(String, String)> {
    if query_terms.is_empty() {
        return None;
    }

    let sanitized_note = sanitize_note_for_preview(note);

    // Prefer note previews; use title as fallback.
    if let Some(snippet) = build_field_snippet("note", &sanitized_note, query_terms, 24) {
        return Some(snippet);
    }
    if let Some(snippet) = build_field_snippet("title", title, query_terms, 32) {
        return Some(snippet);
    }
    if let Some(snippet) = build_field_snippet("subtitle", subtitle, query_terms, 32) {
        return Some(snippet);
    }
    build_field_snippet("keywords", keywords, query_terms, 32)
}

fn build_field_snippet(
    source: &str,
    text: &str,
    query_terms: &[String],
    context_chars: usize,
) -> Option<(String, String)> {
    if text.is_empty() {
        return None;
    }

    let field_match = find_field_match(text, query_terms)?;
    let match_start = field_match.start;
    let match_end = field_match.end;
    let raw_start = match_start.saturating_sub(context_chars);
    let raw_end = match_end.saturating_add(context_chars).min(text.len());
    let start = previous_char_boundary(text, raw_start);
    let end = next_char_boundary(text, raw_end);
    if start >= end {
        return None;
    }

    let mut snippet = if field_match.exact {
        highlight_query_terms(&text[start..end], query_terms)
    } else {
        let highlight_start = match_start.saturating_sub(start);
        let highlight_end = match_end.min(end).saturating_sub(start);
        highlight_span(&text[start..end], highlight_start, highlight_end)
    };
    if start > 0 {
        snippet = format!("...{snippet}");
    }
    if end < text.len() {
        snippet = format!("{snippet}...");
    }

    if snippet.matches("**").count() < 2 {
        return None;
    }

    Some((source.to_string(), snippet))
}

fn sanitize_note_for_preview(note: &str) -> String {
    let without_images = strip_inline_image_refs(note);
    let collapsed = collapse_whitespace(&without_images);
    strip_image_residue_tokens(&collapsed)
}

fn strip_inline_image_refs(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut cursor = 0usize;

    while let Some(start_rel) = text[cursor..].find("![") {
        let start = cursor + start_rel;
        output.push_str(&text[cursor..start]);

        let alt_search = start + 2;
        let Some(alt_end_rel) = text[alt_search..].find("](") else {
            output.push_str(&text[start..]);
            return output;
        };
        let url_start = alt_search + alt_end_rel + 2;
        let Some(url_end_rel) = text[url_start..].find(')') else {
            output.push_str(&text[start..]);
            return output;
        };
        let url_end = url_start + url_end_rel;
        let url = &text[url_start..url_end];

        if url.starts_with("alfred://image/") {
            cursor = url_end + 1;
            continue;
        }

        output.push_str(&text[start..=url_end]);
        cursor = url_end + 1;
    }

    output.push_str(&text[cursor..]);
    output
}

fn collapse_whitespace(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut previous_was_space = false;

    for ch in text.chars() {
        if ch.is_whitespace() {
            if !previous_was_space {
                output.push(' ');
                previous_was_space = true;
            }
        } else {
            output.push(ch);
            previous_was_space = false;
        }
    }

    output.trim().to_string()
}

fn strip_image_residue_tokens(text: &str) -> String {
    text.split_whitespace()
        .filter(|token| !looks_like_image_residue(token))
        .collect::<Vec<_>>()
        .join(" ")
}

fn looks_like_image_residue(token: &str) -> bool {
    if token.contains("alfred://image/") {
        return true;
    }

    let trimmed = token.trim_matches(|ch: char| ",.;:()[]{}<>\"'".contains(ch));
    if !trimmed.contains("?w=") {
        return false;
    }

    let base = trimmed.split("?w=").next().unwrap_or("");
    if base.starts_with("img-") || base.starts_with("pasted-") {
        return true;
    }

    let hex_count = base.chars().filter(|ch| ch.is_ascii_hexdigit()).count();
    let total = base.chars().count();
    hex_count >= 6 && total <= 24
}

fn parse_query_terms(query: &str) -> Vec<String> {
    query
        .split_whitespace()
        .map(str::trim)
        .filter(|term| !term.is_empty())
        .map(|term| term.to_lowercase())
        .collect()
}

#[derive(Debug, Clone, Copy)]
struct FieldMatch {
    start: usize,
    end: usize,
    exact: bool,
}

fn find_field_match(text: &str, query_terms: &[String]) -> Option<FieldMatch> {
    if let Some((start, end)) = first_exact_match_position(text, query_terms) {
        return Some(FieldMatch {
            start,
            end,
            exact: true,
        });
    }

    best_fuzzy_word_match(text, query_terms).map(|(start, end, _)| FieldMatch {
        start,
        end,
        exact: false,
    })
}

struct LowercaseIndex {
    lowered: String,
    byte_to_source: Vec<(usize, usize)>,
}

fn build_lowercase_index(text: &str) -> LowercaseIndex {
    let mut lowered = String::with_capacity(text.len());
    let mut byte_to_source = Vec::with_capacity(text.len());

    for (start, ch) in text.char_indices() {
        let end = start + ch.len_utf8();
        let lower_piece: String = ch.to_lowercase().collect();
        lowered.push_str(&lower_piece);
        byte_to_source.extend(std::iter::repeat_n((start, end), lower_piece.len()));
    }

    LowercaseIndex {
        lowered,
        byte_to_source,
    }
}

fn source_range_for_lower_range(
    index: &LowercaseIndex,
    lower_start: usize,
    lower_end: usize,
) -> Option<(usize, usize)> {
    if lower_start >= lower_end || lower_end > index.byte_to_source.len() {
        return None;
    }

    let start = index.byte_to_source.get(lower_start)?.0;
    let end = index.byte_to_source.get(lower_end.saturating_sub(1))?.1;
    if start < end {
        Some((start, end))
    } else {
        None
    }
}

fn first_exact_match_position(text: &str, query_terms: &[String]) -> Option<(usize, usize)> {
    let index = build_lowercase_index(text);
    let mut best_match: Option<(usize, usize)> = None;

    for term in query_terms {
        if term.is_empty() {
            continue;
        }

        let term_lower = term.to_lowercase();
        if term_lower.is_empty() {
            continue;
        }

        if let Some(pos) = index.lowered.find(&term_lower) {
            let end_pos = pos + term_lower.len();
            let Some((source_start, source_end)) =
                source_range_for_lower_range(&index, pos, end_pos)
            else {
                continue;
            };

            best_match = match best_match {
                None => Some((source_start, source_end)),
                Some((best_start, best_end)) => {
                    let best_len = best_end.saturating_sub(best_start);
                    let source_len = source_end.saturating_sub(source_start);
                    if source_start < best_start
                        || (source_start == best_start && source_len > best_len)
                    {
                        Some((source_start, source_end))
                    } else {
                        Some((best_start, best_end))
                    }
                }
            };
        }
    }

    best_match
}

fn collect_word_spans(text: &str) -> Vec<(usize, usize)> {
    let mut spans = Vec::new();
    let mut current_start: Option<usize> = None;

    for (index, ch) in text.char_indices() {
        if ch.is_alphanumeric() {
            if current_start.is_none() {
                current_start = Some(index);
            }
        } else if let Some(start) = current_start.take() {
            spans.push((start, index));
        }
    }

    if let Some(start) = current_start {
        spans.push((start, text.len()));
    }

    spans
}

fn best_fuzzy_word_match(text: &str, query_terms: &[String]) -> Option<(usize, usize, f32)> {
    let mut best_match: Option<(usize, usize, f32)> = None;
    let query_terms: Vec<&str> = query_terms
        .iter()
        .map(String::as_str)
        .filter(|term| term.chars().count() >= FUZZY_QUERY_TERM_MIN_CHARS)
        .collect();
    if query_terms.is_empty() {
        return None;
    }

    for (start, end) in collect_word_spans(text) {
        let token = &text[start..end];
        let token_lower = token.to_lowercase();
        let token_len = token_lower.chars().count();
        if token_len < FUZZY_QUERY_TERM_MIN_CHARS {
            continue;
        }

        for term in &query_terms {
            if !lengths_are_fuzzy_compatible(term.chars().count(), token_len) {
                continue;
            }

            let score = fuzzy_term_similarity(term, &token_lower);
            if score < FUZZY_SIMILARITY_THRESHOLD {
                continue;
            }

            match best_match {
                None => best_match = Some((start, end, score)),
                Some((best_start, _, best_score)) => {
                    if score > best_score
                        || ((score - best_score).abs() <= f32::EPSILON && start < best_start)
                    {
                        best_match = Some((start, end, score));
                    }
                }
            }
        }
    }

    best_match
}

fn fuzzy_row_score(title: &str, note: &str, query_terms: &[String]) -> f32 {
    let title_score = best_fuzzy_word_match(title, query_terms)
        .map(|(_, _, score)| score * 1.08)
        .unwrap_or(0.0);
    let note_score = best_fuzzy_word_match(note, query_terms)
        .map(|(_, _, score)| score * 0.98)
        .unwrap_or(0.0);

    title_score.max(note_score)
}

fn lengths_are_fuzzy_compatible(left: usize, right: usize) -> bool {
    let max_len = left.max(right);
    let min_len = left.min(right);
    min_len.saturating_mul(2) >= max_len
}

fn fuzzy_term_similarity(query: &str, candidate: &str) -> f32 {
    if query.is_empty() || candidate.is_empty() {
        return 0.0;
    }
    if query == candidate {
        return 1.0;
    }
    if candidate.contains(query) || query.contains(candidate) {
        return 0.96;
    }

    let dice = bigram_dice_similarity(query, candidate);
    let query_len = query.chars().count();
    let candidate_len = candidate.chars().count();
    let len_ratio = (query_len.min(candidate_len) as f32) / (query_len.max(candidate_len) as f32);
    (dice * 0.85) + (len_ratio * 0.15)
}

fn bigram_dice_similarity(left: &str, right: &str) -> f32 {
    let left_chars: Vec<char> = left.chars().collect();
    let right_chars: Vec<char> = right.chars().collect();

    if left_chars.is_empty() || right_chars.is_empty() {
        return 0.0;
    }
    if left_chars.len() == 1 || right_chars.len() == 1 {
        return if left_chars[0] == right_chars[0] {
            1.0
        } else {
            0.0
        };
    }

    let mut left_counts: HashMap<(char, char), usize> = HashMap::new();
    let mut right_counts: HashMap<(char, char), usize> = HashMap::new();

    for window in left_chars.windows(2) {
        let key = (window[0], window[1]);
        *left_counts.entry(key).or_insert(0) += 1;
    }
    for window in right_chars.windows(2) {
        let key = (window[0], window[1]);
        *right_counts.entry(key).or_insert(0) += 1;
    }

    let mut overlap = 0usize;
    for (bigram, left_count) in left_counts {
        if let Some(right_count) = right_counts.get(&bigram) {
            overlap += left_count.min(*right_count);
        }
    }

    let total = (left_chars.len() - 1 + right_chars.len() - 1) as f32;
    if total <= 0.0 {
        0.0
    } else {
        (2.0 * overlap as f32) / total
    }
}

fn previous_char_boundary(text: &str, index: usize) -> usize {
    let mut cursor = index.min(text.len());
    while cursor > 0 && !text.is_char_boundary(cursor) {
        cursor -= 1;
    }
    cursor
}

fn next_char_boundary(text: &str, index: usize) -> usize {
    let mut cursor = index.min(text.len());
    while cursor < text.len() && !text.is_char_boundary(cursor) {
        cursor += 1;
    }
    cursor
}

fn highlight_query_terms(text: &str, query_terms: &[String]) -> String {
    let mut ranges: Vec<(usize, usize)> = Vec::new();
    let index = build_lowercase_index(text);

    for term in query_terms {
        if term.is_empty() {
            continue;
        }

        let term_lower = term.to_lowercase();
        if term_lower.is_empty() {
            continue;
        }

        let mut search_from = 0usize;
        while search_from < index.lowered.len() {
            let Some(relative) = index.lowered[search_from..].find(&term_lower) else {
                break;
            };

            let lower_start = search_from + relative;
            let lower_end = lower_start + term_lower.len();
            if let Some((start, end)) = source_range_for_lower_range(&index, lower_start, lower_end)
            {
                ranges.push((start, end));
            }

            search_from = lower_end;
        }
    }

    if ranges.is_empty() {
        return text.to_string();
    }

    ranges.sort_unstable_by_key(|(start, _)| *start);
    let mut merged: Vec<(usize, usize)> = Vec::with_capacity(ranges.len());
    for (start, end) in ranges {
        if let Some((_, last_end)) = merged.last_mut() {
            if start <= *last_end {
                if end > *last_end {
                    *last_end = end;
                }
                continue;
            }
        }
        merged.push((start, end));
    }

    let mut result = String::with_capacity(text.len() + merged.len() * 4);
    let mut cursor = 0usize;
    for (start, end) in merged {
        result.push_str(&text[cursor..start]);
        result.push_str("**");
        result.push_str(&text[start..end]);
        result.push_str("**");
        cursor = end;
    }
    result.push_str(&text[cursor..]);

    result
}

fn highlight_span(text: &str, start: usize, end: usize) -> String {
    let start = previous_char_boundary(text, start);
    let end = next_char_boundary(text, end.min(text.len()));
    if start >= end || start > text.len() || end > text.len() {
        return text.to_string();
    }

    let mut output = String::with_capacity(text.len() + 4);
    output.push_str(&text[..start]);
    output.push_str("**");
    output.push_str(&text[start..end]);
    output.push_str("**");
    output.push_str(&text[end..]);
    output
}

fn build_lucene_query(query: &str) -> Option<String> {
    let mut terms = Vec::new();
    for token in query.split_whitespace().take(12) {
        let sanitized: String = token
            .chars()
            .filter(|ch| ch.is_alphanumeric() || *ch == '_' || *ch == '-')
            .take(64)
            .collect();
        if !sanitized.is_empty() {
            terms.push(format!("{sanitized}*"));
        }
    }

    if terms.is_empty() {
        None
    } else {
        Some(terms.join(" AND "))
    }
}

#[cfg(test)]
mod tests {
    use super::{
        build_snippet, fuzzy_term_similarity, highlight_query_terms, sanitize_note_for_preview,
    };

    #[test]
    fn highlight_query_terms_marks_multiple_case_insensitive_matches() {
        let highlighted = highlight_query_terms("Rust and swift and RUST", &["rust".into()]);
        assert_eq!(highlighted, "**Rust** and swift and **RUST**");
    }

    #[test]
    fn highlight_query_terms_handles_unicode_case_mapping_offsets() {
        let highlighted = highlight_query_terms("İzmir zorlama deneme", &["deneme".into()]);
        assert_eq!(highlighted, "İzmir zorlama **deneme**");
    }

    #[test]
    fn build_snippet_handles_multi_word_queries_by_term() {
        let result = build_snippet(
            "Launcher",
            "",
            "",
            "Rust and Swift can work together in a search result list preview.",
            "swift work",
        );

        let (source, snippet) = result.expect("snippet should be present");
        assert_eq!(source, "note");
        assert!(snippet.contains("**Swift**"), "snippet was: {snippet}");
        assert!(snippet.contains("**work**"), "snippet was: {snippet}");
    }

    #[test]
    fn build_snippet_ignores_title_only_matches() {
        let result = build_snippet(
            "Swift Launcher",
            "",
            "",
            "No matching content here.",
            "swift",
        );
        let (source, snippet) = result.expect("snippet should be present");
        assert_eq!(source, "title");
        assert!(snippet.contains("**Swift**"), "snippet was: {snippet}");
    }

    #[test]
    fn build_snippet_fuzzy_matches_note_with_typo() {
        let result = build_snippet("serkan", "", "", "dedektif notlar", "ededek");
        let (source, snippet) = result.expect("snippet should be present");
        assert_eq!(source, "note");
        assert!(snippet.contains("**dedektif**"), "snippet was: {snippet}");
    }

    #[test]
    fn fuzzy_similarity_scores_typo_reasonably_high() {
        let score = fuzzy_term_similarity("ededek", "dedektif");
        assert!(
            score >= 0.62,
            "expected fuzzy score to clear threshold, got {score}"
        );
    }

    #[test]
    fn sanitize_note_for_preview_removes_inline_image_refs_and_flattens_newlines() {
        let note = "line 1\n![image](alfred://image/img-1-aaaa?w=360)\nline 2";
        let sanitized = sanitize_note_for_preview(note);
        assert_eq!(sanitized, "line 1 line 2");
    }

    #[test]
    fn sanitize_note_for_preview_drops_image_url_fragments() {
        let note = "...\n-387e204f?w=360)\n\ndeneme\n";
        let sanitized = sanitize_note_for_preview(note);
        assert_eq!(sanitized, "... deneme");
    }

    #[test]
    fn build_snippet_note_preview_keeps_highlight_visible_after_newlines() {
        let result = build_snippet(
            "Search Docs",
            "",
            "",
            "ciddiye almas dsf sdfsdf\n\ndeneme\n\n![image](alfred://image/img-1-aaaa?w=360)",
            "deneme",
        );

        let (source, snippet) = result.expect("snippet should be present");
        assert_eq!(source, "note");
        assert!(snippet.contains("**deneme**"), "snippet was: {snippet}");
        assert!(
            !snippet.contains("alfred://image"),
            "snippet was: {snippet}"
        );
        assert!(!snippet.contains("?w=360"), "snippet was: {snippet}");
        assert!(!snippet.contains('\n'), "snippet was: {snippet}");
    }

    #[test]
    fn build_snippet_note_preview_collapses_large_newline_gaps() {
        let result = build_snippet(
            "Masmavi",
            "",
            "",
            "zorlama\n\n\n\n\n\n\n\n\n\ndeneme",
            "deneme",
        );

        let (source, snippet) = result.expect("snippet should be present");
        assert_eq!(source, "note");
        assert_eq!(snippet, "zorlama **deneme**");
    }

    #[test]
    fn build_snippet_note_preview_handles_spotify_like_images() {
        let note = "asdfasfasdf\n\n![image](alfred://image/img-1770450073-387e204f?w=360)\n![image](alfred://image/img-1770450075-4f23d5c0)\n![image](alfred://image/img-1770450073-387e204f?w=360)\ndeneme\nkiymetli hocam\n";
        let result = build_snippet("Spotify", "", "", note, "eneme");

        let (_source, snippet) = result.expect("snippet should be present");
        assert!(snippet.contains("**eneme**"), "snippet was: {snippet}");
        assert!(!snippet.contains("?w=360"), "snippet was: {snippet}");
        assert!(!snippet.contains("387e204f"), "snippet was: {snippet}");
    }
}
