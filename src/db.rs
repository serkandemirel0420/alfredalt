use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, ensure};
use directories::ProjectDirs;
use once_cell::sync::{Lazy, OnceCell};
use rusqlite::{Connection, ErrorCode, OpenFlags, OptionalExtension, Transaction, params};

use crate::hotkey::DEFAULT_HOTKEY;
use crate::models::{EditableItem, Item, NoteImage, SearchResult};

static DB: OnceCell<Mutex<Connection>> = OnceCell::new();
pub const MAX_SCREENSHOT_BYTES: usize = 1_500_000;
pub const MAX_NOTE_IMAGE_COUNT: usize = 24;
const CURRENT_SCHEMA_VERSION: i64 = 4;

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
        if query.trim().is_empty() {
            let mut stmt = conn.prepare(
                "SELECT id, title, subtitle, note, keywords FROM items ORDER BY title LIMIT ?1",
            )?;
            let rows = stmt
                .query_map([limit], |row| {
                    let note: String = row.get(3)?;
                    let keywords: String = row.get(4)?;
                    let title: String = row.get(1)?;
                    let subtitle: String = row.get(2)?;
                    let snippet_data = build_snippet(&title, &subtitle, &keywords, &note, query);
                    Ok(SearchResult {
                        id: row.get(0)?,
                        title,
                        subtitle,
                        snippet: snippet_data.as_ref().map(|(_, text)| text.clone()),
                        snippet_source: snippet_data.as_ref().map(|(source, _)| source.clone()),
                    })
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            return Ok(rows);
        }

        // First try FTS prefix match; then fallback to LIKE for substring hits.
        let mut results = Vec::new();

        {
            let mut stmt = conn.prepare(
                "SELECT items.id, items.title, items.subtitle, items.note, items.keywords
             FROM items_fts
             JOIN items ON items.id = items_fts.rowid
             WHERE items_fts MATCH ?1
             ORDER BY bm25(items_fts)
             LIMIT ?2",
            )?;
            let q = format!("{}*", query); // prefix match
            let rows = stmt
                .query_map(params![q, limit], |row| {
                    let title: String = row.get(1)?;
                    let subtitle: String = row.get(2)?;
                    let note: String = row.get(3)?;
                    let keywords: String = row.get(4)?;
                    let snippet_data = build_snippet(&title, &subtitle, &keywords, &note, query);
                    Ok(SearchResult {
                        id: row.get(0)?,
                        title,
                        subtitle,
                        snippet: snippet_data.as_ref().map(|(_, text)| text.clone()),
                        snippet_source: snippet_data.as_ref().map(|(source, _)| source.clone()),
                    })
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            results.extend(rows);
        }

        if (results.len() as i64) < limit {
            let remaining = limit - results.len() as i64;
            let mut stmt = conn.prepare(
                r#"SELECT id, title, subtitle, note, keywords FROM items
               WHERE title LIKE '%' || ?1 || '%'
                  OR subtitle LIKE '%' || ?1 || '%'
                  OR keywords LIKE '%' || ?1 || '%'
                  OR note LIKE '%' || ?1 || '%'
               LIMIT ?2"#,
            )?;
            let rows = stmt
                .query_map(params![query, remaining], |row| {
                    let title: String = row.get(1)?;
                    let subtitle: String = row.get(2)?;
                    let note: String = row.get(3)?;
                    let keywords: String = row.get(4)?;
                    let snippet_data = build_snippet(&title, &subtitle, &keywords, &note, query);
                    Ok(SearchResult {
                        id: row.get(0)?,
                        title,
                        subtitle,
                        snippet: snippet_data.as_ref().map(|(_, text)| text.clone()),
                        snippet_source: snippet_data.as_ref().map(|(source, _)| source.clone()),
                    })
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            // Avoid duplicates by id
            for r in rows {
                if !results.iter().any(|e| e.id == r.id) {
                    results.push(r);
                    if results.len() as i64 >= limit {
                        break;
                    }
                }
            }
        }

        Ok(results)
    })
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
        let mut stmt = conn.prepare("SELECT id, title, note FROM items WHERE id = ?1")?;
        let (item_id, title, note) = stmt.query_row([id], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?;

        let mut image_stmt = conn.prepare(
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

pub fn update_item(id: i64, note: &str, images: &[NoteImage]) -> Result<()> {
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

    run_with_recovery(|conn| {
        let tx = conn.unchecked_transaction()?;
        tx.execute("UPDATE items SET note = ?1 WHERE id = ?2", params![note, id])?;
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
        Ok(())
    })
}

fn build_snippet(
    title: &str,
    subtitle: &str,
    keywords: &str,
    note: &str,
    query: &str,
) -> Option<(String, String)> {
    if query.trim().is_empty() {
        return None;
    }
    let parts = [
        ("title", title),
        ("subtitle", subtitle),
        ("keywords", keywords),
        ("note", note),
    ];
    let needle = query.to_lowercase();
    for (source, text) in parts {
        if text.is_empty() {
            continue;
        }
        let hay = text.to_lowercase();
        if let Some(pos) = hay.find(&needle) {
            let start = pos.saturating_sub(18);
            let end = (pos + needle.len() + 18).min(text.len());
            let mut snippet = text[start..end].to_string();
            let rel_start = pos - start;
            let rel_end = rel_start + needle.len();
            if rel_end <= snippet.len() {
                snippet.replace_range(
                    rel_start..rel_end,
                    &format!("**{}**", &text[pos..pos + needle.len()]),
                );
            }
            if start > 0 {
                snippet = format!("...{snippet}");
            }
            if end < text.len() {
                snippet = format!("{snippet}...");
            }
            return Some((source.to_string(), snippet));
        }
    }
    None
}
