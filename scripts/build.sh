#!/usr/bin/env bash
set -Eeuo pipefail

AOSP_MANIFEST_URL="${AOSP_MANIFEST_URL:-https://android.googlesource.com/platform/manifest}"
AOSP_REF="${AOSP_REF:-android-15.0.0_r3}"
LIBHYBRIS_REPOSITORY="${LIBHYBRIS_REPOSITORY:-https://github.com/Linux-on-droid/libhybris.git}"
LIBHYBRIS_REF="${LIBHYBRIS_REF:-lindroid-21}"
LUNCH_TARGET="${LUNCH_TARGET:-aosp_arm64-userdebug}"
JOBS="${JOBS:-$(nproc)}"
AOSP_DIR="${AOSP_DIR:-${RUNNER_TEMP:-$PWD/.work}/aosp}"
DIST_DIR="${DIST_DIR:-$PWD/dist}"

print_config() {
    printf '%s\n' \
        "AOSP_MANIFEST_URL=$AOSP_MANIFEST_URL" \
        "AOSP_REF=$AOSP_REF" \
        "LIBHYBRIS_REPOSITORY=$LIBHYBRIS_REPOSITORY" \
        "LIBHYBRIS_REF=$LIBHYBRIS_REF" \
        "LUNCH_TARGET=$LUNCH_TARGET" \
        "JOBS=$JOBS" \
        "AOSP_DIR=$AOSP_DIR" \
        "DIST_DIR=$DIST_DIR"
}

if [[ "${1:-}" == "--print-config" ]]; then
    print_config
    exit 0
fi

if [[ $# -ne 0 ]]; then
    printf 'usage: %s [--print-config]\n' "$0" >&2
    exit 2
fi

if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    printf 'JOBS must be a positive integer, got: %s\n' "$JOBS" >&2
    exit 2
fi

for command in file git nm readelf repo sha256sum; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'required command not found: %s\n' "$command" >&2
        exit 1
    fi
done

mkdir -p "$AOSP_DIR" "$DIST_DIR"
exec > >(tee "$DIST_DIR/build.log") 2>&1

printf 'Build configuration:\n'
print_config

(
    cd "$AOSP_DIR"
    repo init \
        --manifest-url="$AOSP_MANIFEST_URL" \
        --manifest-branch="$AOSP_REF" \
        --depth=1 \
        --partial-clone \
        --clone-filter=blob:limit=10M \
        --no-use-superproject

    repo sync \
        --current-branch \
        --detach \
        --force-sync \
        --no-clone-bundle \
        --no-tags \
        --optimized-fetch \
        --prune \
        --fail-fast \
        --retry-fetches=3 \
        --jobs="$JOBS"
)

libhybris_dir="$AOSP_DIR/libhybris"
if [[ ! -d "$libhybris_dir/.git" ]]; then
    git init "$libhybris_dir"
    git -C "$libhybris_dir" remote add origin "$LIBHYBRIS_REPOSITORY"
fi

git -C "$libhybris_dir" fetch --depth=1 origin "$LIBHYBRIS_REF"
git -C "$libhybris_dir" checkout --detach FETCH_HEAD
libhybris_commit="$(git -C "$libhybris_dir" rev-parse HEAD)"

product_out_file="$DIST_DIR/android-product-out.txt"
(
    cd "$AOSP_DIR"
    set +u
    source build/envsetup.sh
    set -u
    lunch "$LUNCH_TARGET"
    printf '%s\n' "$ANDROID_PRODUCT_OUT" >"$product_out_file"
    m -j"$JOBS" libui_compat_layer
    repo manifest -r -o "$DIST_DIR/aosp-manifest.xml"
)

product_out="$(<"$product_out_file")"
output="$product_out/system/lib64/libui_compat_layer.so"
if [[ ! -s "$output" ]]; then
    printf 'build completed but output is missing: %s\n' "$output" >&2
    exit 1
fi

artifact_dir="$DIST_DIR/artifact"
mkdir -p "$artifact_dir"
cp "$output" "$artifact_dir/libui_compat_layer.so"

file_info="$(file "$output")"
if [[ "$file_info" != *"ELF 64-bit"* || "$file_info" != *"ARM aarch64"* ]]; then
    printf 'unexpected output format: %s\n' "$file_info" >&2
    exit 1
fi

printf '%s\n' "$file_info" >"$artifact_dir/file.txt"
readelf -h "$output" >"$artifact_dir/elf-header.txt"
readelf -d "$output" >"$artifact_dir/dynamic.txt"
nm -D --defined-only "$output" >"$artifact_dir/symbols.txt"

printf '%s\n' \
    "AOSP_MANIFEST_URL=$AOSP_MANIFEST_URL" \
    "AOSP_REF=$AOSP_REF" \
    "LIBHYBRIS_REPOSITORY=$LIBHYBRIS_REPOSITORY" \
    "LIBHYBRIS_REF=$LIBHYBRIS_REF" \
    "LIBHYBRIS_COMMIT=$libhybris_commit" \
    "LUNCH_TARGET=$LUNCH_TARGET" \
    >"$artifact_dir/metadata.env"

(
    cd "$artifact_dir"
    sha256sum libui_compat_layer.so >SHA256SUMS
)

printf 'Artifact ready: %s\n' "$artifact_dir/libui_compat_layer.so"
