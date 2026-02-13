#[derive(Debug, Clone)]
pub struct SearchResult {
    pub id: i64,
    pub title: String,
    pub subtitle: String,
    pub snippet: Option<String>,
    pub snippet_source: Option<String>,
}

#[derive(Debug, Clone)]
pub struct NoteImage {
    pub image_key: String,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct EditableItem {
    pub id: i64,
    pub title: String,
    pub note: String,
    pub images: Vec<NoteImage>,
}
