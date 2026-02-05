#[derive(Debug, Clone)]
pub struct Item {
    pub title: String,
    pub subtitle: String,
    pub keywords: String,
    pub note: String,
}

impl Item {
    pub fn new(
        title: impl Into<String>,
        subtitle: impl Into<String>,
        keywords: impl Into<String>,
    ) -> Self {
        Self {
            title: title.into(),
            subtitle: subtitle.into(),
            keywords: keywords.into(),
            note: String::new(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SearchResult {
    pub id: i64,
    pub title: String,
    pub subtitle: String,
    pub snippet: Option<String>,
    pub snippet_source: Option<String>,
}

#[derive(Debug, Clone)]
pub struct EditableItem {
    pub id: i64,
    pub title: String,
    pub note: String,
    pub screenshot: Option<Vec<u8>>,
}

#[derive(Debug, Clone, Copy)]
pub enum AppMessage {
    ToggleLauncher,
}
