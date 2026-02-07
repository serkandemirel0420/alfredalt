use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, ensure};
use directories::ProjectDirs;
use once_cell::sync::{Lazy, OnceCell};
use rusqlite::{Connection, ErrorCode, OpenFlags, OptionalExtension, Transaction, params};
use serde::Serialize;

use crate::models::{EditableItem, Item, NoteImage, SearchResult};

static DB: OnceCell<Mutex<Connection>> = OnceCell::new();
pub const MAX_SCREENSHOT_BYTES: usize = 12_000_000;
pub const MAX_NOTE_IMAGE_COUNT: usize = 24;
pub const DEFAULT_HOTKEY: &str = "super+Space";
const CURRENT_SCHEMA_VERSION: i64 = 4;
const FUZZY_QUERY_TERM_MIN_CHARS: usize = 4;
const FUZZY_SIMILARITY_THRESHOLD: f32 = 0.62;
const FUZZY_SCAN_MULTIPLIER: i64 = 64;
const FUZZY_SCAN_MAX_ROWS: i64 = 2048;

#[derive(Debug, Clone, Serialize)]
pub struct ExportItem {
    pub id: i64,
    pub title: String,
    pub subtitle: String,
    pub keywords: String,
    pub note: String,
    pub image_count: i64,
}

static SAMPLE_DATA: Lazy<Vec<Item>> = Lazy::new(|| {
    vec![
        Item::new("Serkan Demirel", "Engineer", "rust,search,cli"),
        Item::new("Search Docs", "Open rust docs", "rust,docs,book"),
        Item::new("GitHub", "Open GitHub homepage", "code,hosting"),
        Item::new("Stack Overflow", "Programming Q&A", "questions,answers"),
        Item::new("Spotify", "Play some music", "music,audio"),
    ]
});

fn db_path() -> Result<std::path::PathBuf> {
    let proj =
        ProjectDirs::from("com", "Codex", "alfred_alt").context("Cannot determine project dirs")?;
    Ok(proj.data_dir().join("alfred.db"))
}

fn create_connection() -> Result<Connection> {
    let path = db_path()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_CREATE
            | OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_FULL_MUTEX,
    )?;
    conn.pragma_update(None, "journal_mode", &"WAL")?;
    conn.pragma_update(None, "synchronous", &"NORMAL")?;
    conn.pragma_update(None, "temp_store", &"MEMORY")?;
    conn.pragma_update(None, "cache_size", &-12_000i32)?;
    conn.pragma_update(None, "foreign_keys", &"ON")?;
    conn.busy_timeout(std::time::Duration::from_millis(300))?;
    conn.set_prepared_statement_cache_capacity(64);
    Ok(conn)
}

fn get_db() -> Result<&'static Mutex<Connection>> {
    DB.get_or_try_init(|| {
        let mut conn = create_connection()?;
        if let Err(err) = setup_schema(&mut conn) {
            if is_corruption_error(&err) {
                recover_connection(&mut conn)?;
            } else {
                return Err(err);
            }
        }
        Ok(Mutex::new(conn))
    })
}

fn run_with_recovery<T, F>(mut operation: F) -> Result<T>
where
    F: FnMut(&Connection) -> Result<T>,
{
    let db = get_db()?;
    let mut conn = db.lock().unwrap();
    match operation(&conn) {
        Ok(value) => Ok(value),
        Err(err) if is_corruption_error(&err) => {
            recover_connection(&mut conn)?;
            operation(&conn)
        }
        Err(err) => Err(err),
    }
}

fn recover_connection(conn: &mut Connection) -> Result<()> {
    let path = db_path()?;
    let _ = conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
    let old = std::mem::replace(conn, Connection::open_in_memory()?);
    drop(old);
    backup_corrupt_db_files(&path)?;
    let mut new_conn = create_connection()?;
    setup_schema(&mut new_conn)?;
    *conn = new_conn;
    Ok(())
}

fn backup_corrupt_db_files(db_file: &std::path::Path) -> Result<()> {
    let stamp = unix_timestamp();
    for file in [
        db_file.to_path_buf(),
        std::path::PathBuf::from(format!("{}-wal", db_file.display())),
        std::path::PathBuf::from(format!("{}-shm", db_file.display())),
    ] {
        if file.exists() {
            let backup = std::path::PathBuf::from(format!("{}.corrupt.{stamp}", file.display()));
            std::fs::rename(&file, &backup).with_context(|| {
                format!(
                    "failed to move corrupt database file from {} to {}",
                    file.display(),
                    backup.display()
                )
            })?;
        }
    }
    Ok(())
}

fn unix_timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn is_corruption_error(err: &anyhow::Error) -> bool {
    err.chain().any(|cause| {
        if let Some(sql_err) = cause.downcast_ref::<rusqlite::Error>() {
            return matches!(
                sql_err,
                rusqlite::Error::SqliteFailure(code, _)
                    if code.code == ErrorCode::DatabaseCorrupt
                        || code.code == ErrorCode::NotADatabase
            );
        }

        let msg = cause.to_string().to_lowercase();
        msg.contains("database disk image is malformed")
    })
}

fn setup_schema(conn: &mut Connection) -> Result<()> {
    apply_migrations(conn)?;

    // Seed a few rows if empty.
    let count: i64 = conn.query_row("SELECT COUNT(*) FROM items", [], |r| r.get(0))?;
    if count == 0 {
        let tx = conn.transaction()?;
        {
            let mut stmt =
                tx.prepare("INSERT INTO items(title, subtitle, keywords) VALUES (?1, ?2, ?3)")?;
            for item in SAMPLE_DATA.iter() {
                stmt.execute(params![item.title, item.subtitle, item.keywords])?;
            }
        }
        tx.commit()?;
    }

    ensure_default_hotkey(conn)?;
    Ok(())
}

fn apply_migrations(conn: &mut Connection) -> Result<()> {
    create_schema_version_table(conn)?;
    let mut version = get_schema_version(conn)?;

    while version < CURRENT_SCHEMA_VERSION {
        let target = version + 1;
        let tx = conn.transaction()?;
        match target {
            1 => migrate_to_v1(&tx)?,
            2 => migrate_to_v2(&tx)?,
            3 => migrate_to_v3(&tx)?,
            4 => migrate_to_v4(&tx)?,
            _ => unreachable!("unsupported schema version migration: {target}"),
        }
        set_schema_version(&tx, target)?;
        tx.commit()?;
        version = target;
    }

    Ok(())
}

fn create_schema_version_table(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS schema_version (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            version INTEGER NOT NULL
        );
        "#,
    )?;
    Ok(())
}

fn get_schema_version(conn: &Connection) -> Result<i64> {
    Ok(conn
        .query_row(
            "SELECT version FROM schema_version WHERE id = 1",
            [],
            |row| row.get(0),
        )
        .optional()?
        .unwrap_or(0))
}

fn set_schema_version(tx: &Transaction<'_>, version: i64) -> Result<()> {
    tx.execute(
        "INSERT INTO schema_version(id, version) VALUES (1, ?1)
         ON CONFLICT(id) DO UPDATE SET version = excluded.version",
        [version],
    )?;
    Ok(())
}

fn migrate_to_v1(tx: &Transaction<'_>) -> Result<()> {
    tx.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            subtitle TEXT DEFAULT '',
            keywords TEXT DEFAULT ''
        );

        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        "#,
    )?;
    Ok(())
}

fn migrate_to_v2(tx: &Transaction<'_>) -> Result<()> {
    // Add new columns if they are missing; ignore errors if already present.
    let _ = tx.execute("ALTER TABLE items ADD COLUMN note TEXT DEFAULT ''", []);
    let _ = tx.execute("ALTER TABLE items ADD COLUMN screenshot BLOB", []);
    Ok(())
}

fn migrate_to_v3(tx: &Transaction<'_>) -> Result<()> {
    // Rebuild FTS/indexing triggers once when moving to schema v3.
    tx.execute_batch(
        r#"
        DROP TRIGGER IF EXISTS items_ai;
        DROP TRIGGER IF EXISTS items_ad;
        DROP TRIGGER IF EXISTS items_au;
        DROP TABLE IF EXISTS items_fts;

        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
            title, subtitle, keywords, note, content='items', content_rowid='id'
        );

        CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
            INSERT INTO items_fts(rowid, title, subtitle, keywords, note)
            VALUES (new.id, new.title, new.subtitle, new.keywords, COALESCE(new.note, ''));
        END;
        CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, title, subtitle, keywords, note)
            VALUES('delete', old.id, old.title, old.subtitle, old.keywords, COALESCE(old.note, ''));
        END;
        CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, title, subtitle, keywords, note)
            VALUES('delete', old.id, old.title, old.subtitle, old.keywords, COALESCE(old.note, ''));
            INSERT INTO items_fts(rowid, title, subtitle, keywords, note)
            VALUES (new.id, new.title, new.subtitle, new.keywords, COALESCE(new.note, ''));
        END;
        "#,
    )?;

    tx.execute(
        "INSERT INTO items_fts(rowid, title, subtitle, keywords, note)
         SELECT id, title, subtitle, keywords, COALESCE(note, '') FROM items",
        [],
    )?;
    Ok(())
}

fn migrate_to_v4(tx: &Transaction<'_>) -> Result<()> {
    tx.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS item_images (
            id INTEGER PRIMARY KEY,
            item_id INTEGER NOT NULL,
            image_key TEXT NOT NULL,
            image BLOB NOT NULL,
            created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
            UNIQUE(item_id, image_key),
            FOREIGN KEY(item_id) REFERENCES items(id) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_item_images_item_id ON item_images(item_id);
        "#,
    )?;

    // Backfill legacy single-image data into the new attachment table.
    tx.execute(
        r#"
        INSERT INTO item_images(item_id, image_key, image)
        SELECT id, 'legacy-main', screenshot
        FROM items
        WHERE screenshot IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM item_images
              WHERE item_images.item_id = items.id
                AND item_images.image_key = 'legacy-main'
          )
        "#,
        [],
    )?;

    Ok(())
}

const HOTKEY_SETTING_KEY: &str = "launcher_hotkey";

fn ensure_default_hotkey(conn: &Connection) -> Result<()> {
    let existing: Option<String> = conn
        .query_row(
            "SELECT value FROM settings WHERE key = ?1",
            [HOTKEY_SETTING_KEY],
            |row| row.get(0),
        )
        .optional()?;

    if existing.is_none() {
        set_setting(conn, HOTKEY_SETTING_KEY, DEFAULT_HOTKEY)?;
    }
    Ok(())
}

fn set_setting(conn: &Connection, key: &str, value: &str) -> Result<()> {
    conn.execute(
        "INSERT INTO settings(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, value],
    )?;
    Ok(())
}

fn get_setting(conn: &Connection, key: &str) -> Result<Option<String>> {
    Ok(conn
        .query_row("SELECT value FROM settings WHERE key = ?1", [key], |row| {
            row.get(0)
        })
        .optional()?)
}

pub fn load_hotkey_setting() -> Result<String> {
    run_with_recovery(|conn| {
        if let Some(value) = get_setting(conn, HOTKEY_SETTING_KEY)? {
            Ok(value)
        } else {
            Ok(DEFAULT_HOTKEY.to_string())
        }
    })
}

pub fn save_hotkey_setting(value: &str) -> Result<()> {
    run_with_recovery(|conn| set_setting(conn, HOTKEY_SETTING_KEY, value))
}

pub fn search(query: &str, limit: i64) -> Result<Vec<SearchResult>> {
    run_with_recovery(|conn| {
        let query = query.trim();
        if query.is_empty() {
            let mut stmt = conn
                .prepare_cached("SELECT id, title, subtitle FROM items ORDER BY title LIMIT ?1")?;
            let rows = stmt
                .query_map([limit], |row| {
                    Ok(SearchResult {
                        id: row.get(0)?,
                        title: row.get(1)?,
                        subtitle: row.get(2)?,
                        snippet: None,
                        snippet_source: None,
                    })
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            return Ok(rows);
        }

        // First try FTS prefix match, then LIKE substring hits, and finally a fuzzy fallback.
        let query_terms = parse_query_terms(query);
        let mut results = Vec::with_capacity(limit.max(0) as usize);
        let mut seen_ids = HashSet::with_capacity(limit.max(0) as usize);

        if let Some(fts_query) = build_fts_query(query) {
            let mut stmt = conn.prepare_cached(
                "SELECT items.id, items.title, items.subtitle, items.note, items.keywords
             FROM items_fts
             JOIN items ON items.id = items_fts.rowid
             WHERE items_fts MATCH ?1
             ORDER BY bm25(items_fts)
             LIMIT ?2",
            )?;
            let rows = stmt
                .query_map(params![fts_query, limit], |row| {
                    map_search_row(row, &query_terms)
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            for row in rows {
                if seen_ids.insert(row.id) {
                    results.push(row);
                }
            }
        }

        if (results.len() as i64) < limit {
            let remaining = limit - results.len() as i64;
            let mut stmt = conn.prepare_cached(
                r#"SELECT id, title, subtitle, note, keywords FROM items
               WHERE title LIKE '%' || ?1 || '%'
                  OR note LIKE '%' || ?1 || '%'
               LIMIT ?2"#,
            )?;
            let rows = stmt
                .query_map(params![query, remaining], |row| {
                    map_search_row(row, &query_terms)
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            for r in rows {
                if seen_ids.insert(r.id) {
                    results.push(r);
                    if results.len() as i64 >= limit {
                        break;
                    }
                }
            }
        }

        if (results.len() as i64) < limit {
            let remaining = limit - results.len() as i64;
            let fuzzy_rows = fuzzy_search_rows(conn, &query_terms, remaining, &seen_ids)?;
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

fn fuzzy_search_rows(
    conn: &Connection,
    query_terms: &[String],
    limit: i64,
    seen_ids: &HashSet<i64>,
) -> Result<Vec<SearchResult>> {
    if limit <= 0 {
        return Ok(Vec::new());
    }

    let has_fuzzy_term = query_terms
        .iter()
        .any(|term| term.chars().count() >= FUZZY_QUERY_TERM_MIN_CHARS);
    if !has_fuzzy_term {
        return Ok(Vec::new());
    }

    let scan_limit = (limit.max(8) * FUZZY_SCAN_MULTIPLIER).min(FUZZY_SCAN_MAX_ROWS);
    let mut stmt = conn.prepare_cached(
        "SELECT id, title, subtitle, note, keywords
         FROM items
         ORDER BY id DESC
         LIMIT ?1",
    )?;
    let rows = stmt
        .query_map([scan_limit], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let mut scored: Vec<FuzzyCandidate> = Vec::new();
    for (id, title, subtitle, note, keywords) in rows {
        if seen_ids.contains(&id) {
            continue;
        }

        let score = fuzzy_row_score(&title, &note, query_terms);
        if score < FUZZY_SIMILARITY_THRESHOLD {
            continue;
        }

        scored.push(FuzzyCandidate {
            score,
            id,
            title,
            subtitle,
            keywords,
            note,
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

    Ok(scored
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
        .collect())
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
    run_with_recovery(|conn| {
        conn.execute(
            "INSERT INTO items(title, subtitle, keywords, note) VALUES (?1, '', ?2, '')",
            params![title, title],
        )?;
        Ok(conn.last_insert_rowid())
    })
}

pub fn fetch_item(id: i64) -> Result<EditableItem> {
    run_with_recovery(|conn| {
        let mut stmt = conn.prepare_cached("SELECT id, title, note FROM items WHERE id = ?1")?;
        let (item_id, title, note) = stmt.query_row([id], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?;

        let mut image_stmt = conn.prepare_cached(
            "SELECT image_key, image
             FROM item_images
             WHERE item_id = ?1
             ORDER BY id ASC",
        )?;
        let images = image_stmt
            .query_map([id], |row| {
                Ok(NoteImage {
                    image_key: row.get(0)?,
                    bytes: row.get(1)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;

        let item = EditableItem {
            id: item_id,
            title,
            note,
            images,
        };
        Ok(item)
    })
}

pub fn export_items_snapshot() -> Result<Vec<ExportItem>> {
    run_with_recovery(|conn| {
        let mut stmt = conn.prepare_cached(
            r#"
            SELECT
                items.id,
                items.title,
                items.subtitle,
                items.keywords,
                COALESCE(items.note, ''),
                COUNT(item_images.id) as image_count
            FROM items
            LEFT JOIN item_images ON item_images.item_id = items.id
            GROUP BY items.id
            ORDER BY items.title COLLATE NOCASE ASC, items.id ASC
            "#,
        )?;

        let rows = stmt
            .query_map([], |row| {
                Ok(ExportItem {
                    id: row.get(0)?,
                    title: row.get(1)?,
                    subtitle: row.get(2)?,
                    keywords: row.get(3)?,
                    note: row.get(4)?,
                    image_count: row.get(5)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
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

    run_with_recovery(|conn| {
        if let Some(images) = images {
            let tx = conn.unchecked_transaction()?;
            tx.execute(
                "UPDATE items SET note = ?1 WHERE id = ?2",
                params![note, id],
            )?;
            tx.execute("DELETE FROM item_images WHERE item_id = ?1", [id])?;
            {
                let mut insert = tx.prepare(
                    "INSERT INTO item_images(item_id, image_key, image, created_at)
                     VALUES (?1, ?2, ?3, strftime('%s', 'now'))",
                )?;
                for image in images {
                    insert.execute(params![id, image.image_key, image.bytes])?;
                }
            }
            tx.commit()?;
        } else {
            conn.execute(
                "UPDATE items SET note = ?1 WHERE id = ?2",
                params![note, id],
            )?;
        }
        Ok(())
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

fn map_search_row(
    row: &rusqlite::Row<'_>,
    query_terms: &[String],
) -> rusqlite::Result<SearchResult> {
    let title: String = row.get(1)?;
    let subtitle: String = row.get(2)?;
    let note: String = row.get(3)?;
    let keywords: String = row.get(4)?;
    let snippet_data = build_snippet_with_terms(&title, &subtitle, &keywords, &note, query_terms);

    Ok(SearchResult {
        id: row.get(0)?,
        title,
        subtitle: String::new(),
        snippet: snippet_data.map(|(_, text)| text),
        snippet_source: None,
    })
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
    let hay_lower = text.to_lowercase();
    if let Some((start, len)) = first_exact_match_position(&hay_lower, query_terms) {
        return Some(FieldMatch {
            start,
            end: start.saturating_add(len),
            exact: true,
        });
    }

    best_fuzzy_word_match(text, query_terms).map(|(start, end, _)| FieldMatch {
        start,
        end,
        exact: false,
    })
}

fn first_exact_match_position(hay_lower: &str, query_terms: &[String]) -> Option<(usize, usize)> {
    let mut best_match: Option<(usize, usize)> = None;

    for term in query_terms {
        if let Some(pos) = hay_lower.find(term) {
            best_match = match best_match {
                None => Some((pos, term.len())),
                Some((best_pos, best_len)) => {
                    if pos < best_pos || (pos == best_pos && term.len() > best_len) {
                        Some((pos, term.len()))
                    } else {
                        Some((best_pos, best_len))
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
    let text_lower = text.to_lowercase();

    for term in query_terms {
        if term.is_empty() {
            continue;
        }

        let mut search_from = 0usize;
        while search_from < text_lower.len() {
            let Some(relative) = text_lower[search_from..].find(term) else {
                break;
            };

            let raw_start = search_from + relative;
            let raw_end = raw_start + term.len();
            let start = previous_char_boundary(text, raw_start);
            let end = next_char_boundary(text, raw_end.min(text.len()));
            if start < end {
                ranges.push((start, end));
            }

            search_from = raw_end;
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

fn build_fts_query(query: &str) -> Option<String> {
    let mut terms = Vec::new();
    for token in query.split_whitespace().take(12) {
        let sanitized: String = token
            .chars()
            .filter(|ch| ch.is_alphanumeric() || *ch == '_' || *ch == '-')
            .take(64)
            .collect();
        if !sanitized.is_empty() {
            terms.push(format!("(title:{sanitized}* OR note:{sanitized}*)"));
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
    fn build_snippet_note_preview_handles_spotify_like_images() {
        let note = "asdfasfasdf\n\n![image](alfred://image/img-1770450073-387e204f?w=360)\n![image](alfred://image/img-1770450075-4f23d5c0)\n![image](alfred://image/img-1770450073-387e204f?w=360)\ndeneme\nkiymetli hocam\n";
        let result = build_snippet("Spotify", "", "", note, "eneme");

        let (_source, snippet) = result.expect("snippet should be present");
        assert!(snippet.contains("**eneme**"), "snippet was: {snippet}");
        assert!(!snippet.contains("?w=360"), "snippet was: {snippet}");
        assert!(!snippet.contains("387e204f"), "snippet was: {snippet}");
    }
}
