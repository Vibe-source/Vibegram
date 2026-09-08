#!/usr/bin/env bash
set -euo pipefail

CRATE_NAME="vibe_core_ffi"
LIB_NAME="libvibe_core_ffi.a"
# Bindings are generated from the .dylib, not the .a the framework ships.
#
# Both are built from the same source with the same features, so they describe
# the same interface — but the release profile is `lto = true, codegen-units =
# 1`, which collapses the crate into a single ~9MB archive member, and
# uniffi-bindgen's archive reader fails on it ("Failed to extract data from
# archive member ...rcgu.o"). It only started failing when openmls and rusqlite
# were linked in and that member grew. Reading the Mach-O directly skips the
# archive parser entirely and keeps the property that matters: the interface is
# recovered from compiled metadata, so it can never describe an export the
# binary does not have.
BINDGEN_LIB_NAME="libvibe_core_ffi.dylib"
FRAMEWORK_NAME="VibeCoreFFI"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="$REPO_ROOT/core/$CRATE_NAME"
BUILD_DIR="$REPO_ROOT/core/target"
OUT_DIR="$REPO_ROOT/ios/Vendor/VibeCore"
GENERATED_DIR="$REPO_ROOT/ios/Sources/Core/Generated"
# Assembled fresh each run. The XCFramework carries these; without them the
# generated Swift cannot resolve `RustBuffer`/`RustCallStatus` and every FFI type
# fails to compile.
HEADERS_DIR="$BUILD_DIR/xcf-headers"

preflight() {
    echo "Running preflight checks..."
    for tool in cargo rustup lipo xcodebuild; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "error: required tool '$tool' not found on PATH" >&2
            exit 1
        fi
    done

    if [[ ! -f "$CRATE_DIR/Cargo.toml" ]]; then
        echo "error: $CRATE_NAME not found at $CRATE_DIR — build it first" >&2
        exit 1
    fi
}

# Device, plus the arm64 simulator. `x86_64-apple-ios` is deliberately absent.
#
# Since the crate gained a C dependency (bundled SQLite, via vibe_core_store),
# the Intel simulator cannot be compiled at all: Xcode 26's iPhoneSimulator SDK
# declares `_Float16` in <math.h>, and clang rejects that type on an x86_64
# target. It fails in libsqlite3-sys before any of our code is reached, so this
# is not something the build script can work around.
#
# Consequence, stated plainly: on an Intel Mac there is no usable iOS simulator
# slice. Device builds are unaffected, and an Apple Silicon Mac gets its
# simulator from the arm64-sim slice below.
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim)

ensure_targets() {
    echo "Ensuring required Rust targets are installed..."
    local installed_targets
    installed_targets="$(rustup target list --installed)"
    for target in "${TARGETS[@]}"; do
        if ! grep -q "^${target}$" <<< "$installed_targets"; then
            echo "Installing target $target..."
            rustup target add "$target"
        fi
    done
}

build_targets() {
    echo "Building release targets..."
    for target in "${TARGETS[@]}"; do
        echo "Building $CRATE_NAME for $target..."
        CARGO_TARGET_DIR="$BUILD_DIR" cargo build --release --locked -p "$CRATE_NAME" --target "$target" --manifest-path "$CRATE_DIR/Cargo.toml"
    done
}

make_sim_fat() {
    # One slice today (arm64), so this is a copy rather than a lipo. Kept as its
    # own step so restoring a second simulator arch is a one-line change here.
    echo "Staging simulator library..."
    local sim_fat_dir="$BUILD_DIR/sim-fat-tmp"
    mkdir -p "$sim_fat_dir"
    lipo -create \
        "$BUILD_DIR/aarch64-apple-ios-sim/release/$LIB_NAME" \
        -output "$sim_fat_dir/$LIB_NAME"
}

generate_bindings() {
    echo "Generating Swift bindings from the built library..."
    # Read from the device slice: UniFFI's proc-macro mode recovers the interface
    # from metadata embedded in the compiled library, so the bindings can never
    # describe an interface the linked binary does not actually export.
    # Run from inside the crate: uniffi-bindgen shells out to `cargo metadata`,
    # which resolves against the working directory, not `--manifest-path`. From the
    # repository root it fails with a bare "error running cargo metadata".
    (
        cd "$CRATE_DIR"
        CARGO_TARGET_DIR="$BUILD_DIR" cargo run --release --quiet \
            --bin uniffi-bindgen -- \
            generate \
            --library "$BUILD_DIR/aarch64-apple-ios/release/$BINDGEN_LIB_NAME" \
            --language swift \
            --out-dir "$GENERATED_DIR"
    )

    # The C header and its modulemap belong to the *framework*, not to the Swift
    # sources. Leaving them in the sources directory both fails to give Swift a
    # module to import and adds a stray header to the app target.
    rm -rf "$HEADERS_DIR"
    mkdir -p "$HEADERS_DIR"
    mv "$GENERATED_DIR/${CRATE_NAME}FFI.h" "$HEADERS_DIR/"
    # Must be named `module.modulemap` for a header directory in an XCFramework.
    mv "$GENERATED_DIR/${CRATE_NAME}FFI.modulemap" "$HEADERS_DIR/module.modulemap"
}

make_xcframework() {
    echo "Creating XCFramework at $OUT_DIR/$FRAMEWORK_NAME.xcframework..."
    mkdir -p "$OUT_DIR"
    rm -rf "$OUT_DIR/$FRAMEWORK_NAME.xcframework"
    xcodebuild -create-xcframework \
        -library "$BUILD_DIR/aarch64-apple-ios/release/$LIB_NAME" \
        -headers "$HEADERS_DIR" \
        -library "$BUILD_DIR/sim-fat-tmp/$LIB_NAME" \
        -headers "$HEADERS_DIR" \
        -output "$OUT_DIR/$FRAMEWORK_NAME.xcframework"
}

report_size() {
    local device_lib="$BUILD_DIR/aarch64-apple-ios/release/$LIB_NAME"
    local stripped_tmp="$BUILD_DIR/device_stripped_tmp.a"
    cp "$device_lib" "$stripped_tmp"
    strip -S "$stripped_tmp" 2>/dev/null || true
    local size
    size="$(du -h "$stripped_tmp" | cut -f1 | tr -d ' ')"
    rm -f "$stripped_tmp"
    echo "device slice: $size"
}

main() {
    preflight
    ensure_targets
    build_targets
    generate_bindings
    make_sim_fat
    make_xcframework
    report_size
}

main "$@"
