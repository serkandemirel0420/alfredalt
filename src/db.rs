use std::sync::Mutex;

use anyhow::{Context, Result};
use directories::ProjectDirs;
use once_cell::sync::{Lazy, OnceCell};
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};

use crate::hotkey::DEFAULT_HOTKEY;
use crate::models::{EditableItem, Item, SearchResult};

static DB: OnceCell<Mutex<Connection>> = OnceCell::new();

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
        setup_schema(&mut conn)?;
        Ok(Mutex::new(conn))
    })
}

fn setup_schema(conn: &mut Connection) -> Result<()> {
    // Add new columns if they are missing; ignore errors if already present.
    let _ = conn.execute("ALTER TABLE items ADD COLUMN note TEXT DEFAULT ''", []);
    let _ = conn.execute("ALTER TABLE items ADD COLUMN screenshot BLOB", []);

    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            subtitle TEXT DEFAULT '',
            keywords TEXT DEFAULT '',
            note TEXT DEFAULT '',
            screenshot BLOB
        );

        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        DROP TRIGGER IF EXISTS items_ai;
        DROP TRIGGER IF EXISTS items_ad;
        DROP TRIGGER IF EXISTS items_au;
        DROP TABLE IF EXISTS items_fts;

        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
            title, subtitle, keywords, note, content='items', content_rowid='id'
        );

        CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
            INSERT INTO items_fts(rowid, title, subtitle, keywords, note)
            VALUES (new.id, new.title, new.subtitle, new.keywords, new.note);
        END;
        CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, title, subtitle, keywords, note)
            VALUES('delete', old.id, old.title, old.subtitle, old.keywords, old.note);
        END;
        CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, title, subtitle, keywords, note)
            VALUES('delete', old.id, old.title, old.subtitle, old.keywords, old.note);
            INSERT INTO items_fts(rowid, title, subtitle, keywords, note)
            VALUES (new.id, new.title, new.subtitle, new.keywords, new.note);
        END;
        "#,
    )?;

    // Ensure FTS table has data after a rebuild.
    conn.execute(
        "INSERT INTO items_fts(rowid, title, subtitle, keywords, note)
         SELECT id, title, subtitle, keywords, COALESCE(note, '') FROM items
         WHERE id NOT IN (SELECT rowid FROM items_fts)",
        [],
    )?;

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
    let conn = get_db()?.lock().unwrap();
    if let Some(value) = get_setting(&conn, HOTKEY_SETTING_KEY)? {
        Ok(value)
    } else {
        Ok(DEFAULT_HOTKEY.to_string())
    }
}

pub fn save_hotkey_setting(value: &str) -> Result<()> {
    let conn = get_db()?.lock().unwrap();
    set_setting(&conn, HOTKEY_SETTING_KEY, value)
}

pub fn search(query: &str, limit: i64) -> Result<Vec<SearchResult>> {
    let conn = get_db()?.lock().unwrap();
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
}

pub fn insert_item(title: &str) -> Result<i64> {
    let conn = get_db()?.lock().unwrap();
    conn.execute(
        "INSERT INTO items(title, subtitle, keywords, note) VALUES (?1, '', ?2, '')",
        params![title, title],
    )?;
    Ok(conn.last_insert_rowid())
}

pub fn fetch_item(id: i64) -> Result<EditableItem> {
    let conn = get_db()?.lock().unwrap();
    let mut stmt = conn.prepare("SELECT id, title, note, screenshot FROM items WHERE id = ?1")?;
    let item = stmt.query_row([id], |row| {
        Ok(EditableItem {
            id: row.get(0)?,
            title: row.get(1)?,
            note: row.get(2)?,
            screenshot: row.get(3)?,
        })
    })?;
    Ok(item)
}

pub fn update_item(id: i64, note: &str, screenshot: Option<&[u8]>) -> Result<()> {
    let conn = get_db()?.lock().unwrap();
    conn.execute(
        "UPDATE items SET note = ?1, screenshot = ?2 WHERE id = ?3",
        params![note, screenshot, id],
    )?;
    Ok(())
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
