# AlfredAlternative

AlfredAlternative is a fast, local-first macOS launcher and note-taking app.  
It combines an Alfred-like command palette with instant Lucene-style full-text search (powered by Tantivy) and a native editor that supports inline images.

## Screenshots

The images below are ready-to-use placeholders for GitHub. Replace them with real app captures in `docs/screenshots/` whenever you want.

### Launcher + instant search

![alt text](<./Screenshot_2026-02-16 02.15.55_oBuMAk.png>)
![alt text](<./Screenshot_2026-02-16 02.21.51_pzeBgK-1.png>)
 

## Why AlfredAlternative

- Alfred-like launcher workflow for fast keyboard-driven access
- Instant full-text search across title, subtitle, keywords, and notes
- Tantivy search engine (Lucene-inspired) with highlighted snippets
- Built-in note editor with inline image paste, resize, and reorder
- Local-first storage (JSON files + local Lucene index)
- Configurable global hotkey options
- Automatic update checking via GitHub releases

## Search pipeline

1. Tantivy full-text query for fast ranked matches
2. Case-insensitive substring fallback
3. Fuzzy matching for typo tolerance

## Tech stack

- Rust backend (Edition 2024)
- Swift + SwiftUI frontend
- UniFFI bridge for Rust/Swift interop
- Tantivy 0.22 for full-text search
- JSON data files + Lucene index

## Requirements

- macOS 13.0+
- Rust toolchain
- Xcode Command Line Tools
- Optional for release publishing: `gh` CLI

Install Rust targets for universal static library builds:

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

## Quick start

Generate the Rust/Swift bridge files:

```bash
./scripts/generate_swift_bridge.sh
```

Build the macOS app bundle:

```bash
make build-app
```

Run the app:

```bash
make run
```

Run foreground binary for debugging:

```bash
make run-cli
```

## Release

Create DMG and publish GitHub release:

```bash
make release
```

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Enter` | Open selected item |
| `Shift + Enter` | Create a new item from current query |
| `Esc` | Dismiss launcher / close editor |
| `Command` (tap) | Open item action menu |
| `Command + V` | Paste image from clipboard into note |
| `Command +/-` | Increase or decrease editor font size |
| Global hotkey | Toggle launcher (configurable in Settings) |

## Storage locations

- Lucene index: `~/Library/Application Support/com.Codex.alfred_alt/alfred_lucene_index/`
- Default JSON data: `~/Documents/AlfredAlternativeData/`
- Note images: `~/Documents/AlfredAlternativeData/images/`

The JSON storage root is configurable from the Settings window.

## Repository layout

```text
src/                         Rust backend (search, storage, FFI exports)
swift/App/                   SwiftUI app
swift/RustBridge/Generated/  UniFFI-generated Swift bridge files
scripts/                     Build and release scripts
resources/                   Application assets
```

## Notes

- Version source of truth: `Cargo.toml` (`version`)
- Swift bridge setup details: `swift/README.md`

## License

FUCK LICENCE
