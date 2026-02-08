#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/swift/RustBridge"
GENERATED_DIR="$OUT_DIR/Generated"
LIB_DIR="$OUT_DIR/lib"
UNIVERSAL_LIB="$LIB_DIR/libalfred_alt_universal.a"
HOST_STATIC_LIB="$LIB_DIR/libalfred_alt_host.a"
HOST_DYLIB="$ROOT_DIR/target/release/libalfred_alt.dylib"
HOST_ARCHIVE_PRIMARY="$ROOT_DIR/target/release/libalfred_alt.a"
HOST_TARGET="$(rustc -vV | sed -n 's/^host: //p')"
HOST_ARCHIVE_FALLBACK="$ROOT_DIR/target/$HOST_TARGET/release/libalfred_alt.a"

mkdir -p "$GENERATED_DIR" "$LIB_DIR"

cargo build --manifest-path "$ROOT_DIR/Cargo.toml" --release --lib

if [[ ! -f "$HOST_DYLIB" ]]; then
    echo "error: expected compiled dylib at $HOST_DYLIB"
    exit 1
fi

if [[ -f "$HOST_ARCHIVE_PRIMARY" ]]; then
    cp "$HOST_ARCHIVE_PRIMARY" "$HOST_STATIC_LIB"
    echo "created host static library: $HOST_STATIC_LIB"
elif [[ -f "$HOST_ARCHIVE_FALLBACK" ]]; then
    cp "$HOST_ARCHIVE_FALLBACK" "$HOST_STATIC_LIB"
    echo "created host static library: $HOST_STATIC_LIB"
fi

cargo run --manifest-path "$ROOT_DIR/Cargo.toml" --bin uniffi_swift_bindgen -- \
    "$HOST_DYLIB" \
    "$GENERATED_DIR" \
    "alfred_altFFI"

if [[ "$(uname -s)" == "Darwin" ]]; then
    ARM64_LIB="$ROOT_DIR/target/aarch64-apple-darwin/release/libalfred_alt.a"
    X64_LIB="$ROOT_DIR/target/x86_64-apple-darwin/release/libalfred_alt.a"
    INSTALLED_TARGETS="$(rustup target list --installed)"
    if [[ "$INSTALLED_TARGETS" == *"aarch64-apple-darwin"* && "$INSTALLED_TARGETS" == *"x86_64-apple-darwin"* ]]; then
        cargo build --manifest-path "$ROOT_DIR/Cargo.toml" --release --lib --target aarch64-apple-darwin
        cargo build --manifest-path "$ROOT_DIR/Cargo.toml" --release --lib --target x86_64-apple-darwin

        if [[ -f "$ARM64_LIB" && -f "$X64_LIB" ]]; then
            lipo -create "$ARM64_LIB" "$X64_LIB" -output "$UNIVERSAL_LIB"
            echo "created universal library: $UNIVERSAL_LIB"
        fi
    else
        echo "skipped universal library build because one or more rust targets are missing"
        echo "install with: rustup target add aarch64-apple-darwin x86_64-apple-darwin"
    fi
fi

echo "generated Swift bindings in: $GENERATED_DIR"
