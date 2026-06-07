# peat-flutter development tasks

# Path to the peat workspace (sibling directory by default).
# Override: PEAT_WORKSPACE_DIR=/abs/path just gen-bindings
peat_workspace := env_var_or_default("PEAT_WORKSPACE_DIR", "../peat")

# Output dirs for generated sources
generated_dir := "lib/src/generated"
proto_dir     := "lib/src/proto"
proto_src     := peat_workspace + "/peat-schema/proto"

# Generate Dart FFI bindings from the peat-ffi cdylib via uniffi-bindgen-dart.
#
# Requires:
#   cargo install --git https://github.com/NicolasFrantzen/uniffi-bindgen-dart
#   (build peat-ffi first — see below)
gen-bindings:
    #!/usr/bin/env bash
    set -euo pipefail
    # Find the most recently built host cdylib
    lib=$(ls "{{peat_workspace}}"/target/release/libpeat_ffi.{so,dylib} 2>/dev/null | head -1 || true)
    if [ -z "$lib" ]; then
        echo "ERROR: libpeat_ffi not found in {{peat_workspace}}/target/release/."
        echo "Build it first:"
        echo "  cd {{peat_workspace}} && cargo build -p peat-ffi --features sync,bluetooth"
        exit 1
    fi
    mkdir -p "{{generated_dir}}"
    uniffi-bindgen-dart generate --library "$lib" --out-dir "{{generated_dir}}"
    echo "Bindings written to {{generated_dir}}/"

# Generate Dart proto stubs from peat-schema protos via protoc-gen-dart.
#
# Requires:
#   apt install protobuf-compiler   (or brew install protobuf)
#   dart pub global activate protoc_plugin
gen-proto:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{proto_dir}}"
    protos=$(find "{{proto_src}}" -name '*.proto')
    if [ -z "$protos" ]; then
        echo "ERROR: no .proto files found under {{proto_src}}"
        exit 1
    fi
    # shellcheck disable=SC2086
    protoc \
        --dart_out="{{proto_dir}}" \
        --experimental_allow_proto3_optional \
        -I "{{proto_src}}" \
        $protos
    echo "Proto stubs written to {{proto_dir}}/"

# Build peat-ffi for all Android ABIs via cargo-ndk.
# Requires: cargo install cargo-ndk  +  Android NDK (ANDROID_NDK_HOME set).
build-android:
    cargo ndk \
        -t arm64-v8a -t armeabi-v7a -t x86_64 \
        -o android/src/main/jniLibs \
        build --release \
        --manifest-path "{{peat_workspace}}/Cargo.toml" \
        -p peat-ffi \
        --features sync,bluetooth

# Build peat-ffi for iOS (xcframework). macOS host only.
build-ios:
    ios/build-rust.sh

# Build peat-ffi as a universal macOS dylib. macOS host only.
build-macos:
    macos/build-rust.sh

# Build peat-ffi for the native Linux/Windows host.
# The CMake build for those platforms shells out to cargo, but this task lets
# you pre-build and verify outside of the Flutter CMake context.
build-host:
    cargo build --release \
        --manifest-path "{{peat_workspace}}/Cargo.toml" \
        -p peat-ffi \
        --features sync,bluetooth

# Re-run both generation steps. Run after any peat-ffi surface change.
regen: gen-bindings gen-proto

# Run dart analyze over the library sources.
analyze:
    dart analyze lib/
