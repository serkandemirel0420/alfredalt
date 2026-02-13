# Swift Frontend + Rust Backend

This directory contains a SwiftUI frontend that calls the Rust backend through UniFFI.
The previous Rust `egui/eframe` frontend has been removed from the build path.

## Layout

- `App/`: SwiftUI app source files.
- `RustBridge/Generated/`: UniFFI-generated Swift/C bridge files.
- `RustBridge/lib/`: built Rust static libraries for Xcode linking.

## Generate Bridge Files

From the repository root:

```bash
./scripts/generate_swift_bridge.sh
```

The script will:

1. Build the Rust library target.
2. Run the local `uniffi_swift_bindgen` helper binary to generate UniFFI Swift bindings.
3. Build a host static library and, when both macOS rust targets are installed, also build a universal static library (`arm64 + x86_64`).

## Xcode Wiring

1. Create a macOS App project in Xcode (SwiftUI lifecycle).
2. Add all files in `swift/App/` to the app target.
3. Add generated files from `swift/RustBridge/Generated/` to the same target.
4. Add `swift/RustBridge/lib/libalfred_alt_universal.a` to `Link Binary With Libraries` (or `libalfred_alt_host.a` if universal is unavailable).
5. Set `Header Search Paths` to include `swift/RustBridge/Generated` (recursive).

After wiring, the Swift app will call Rust directly via exported UniFFI functions like `searchItems`, `getItem`, and `saveItem`.

## One-Command Local Run

From the repository root:

```bash
make run
```

This will:

1. Generate Rust/Swift bridge files.
2. Build a native `.app` bundle at `.build/AlfredAlternative.app`.
3. Launch the app with `open`.

If you want foreground terminal execution instead, run:

```bash
make run-cli
```
