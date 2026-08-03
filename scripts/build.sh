#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AOSP_MANIFEST_URL="${AOSP_MANIFEST_URL:-https://android.googlesource.com/platform/manifest}"
ANDROID_API="${ANDROID_API:-35}"
AOSP_REF="${AOSP_REF:-}"
LIBHYBRIS_REPOSITORY="${LIBHYBRIS_REPOSITORY:-https://github.com/Linux-on-droid/libhybris.git}"
LIBHYBRIS_REF="${LIBHYBRIS_REF:-lindroid-21}"
LUNCH_TARGET="${LUNCH_TARGET:-aosp_arm64-userdebug}"
JOBS="${JOBS:-$(nproc)}"
AOSP_DIR="${AOSP_DIR:-${RUNNER_TEMP:-$PWD/.work}/aosp}"
DIST_DIR="${DIST_DIR:-$PWD/dist}"
PROJECT_MANIFEST_DIR="${PROJECT_MANIFEST_DIR:-$SCRIPT_DIR/../manifests}"
MIN_FREE_GIB="${MIN_FREE_GIB:-55}"
REPO_SYNC_TIMEOUT="${REPO_SYNC_TIMEOUT:-90m}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-240m}"

resolve_aosp_ref() {
    case "$1" in
        35) printf '%s\n' 'android-15.0.0_r3' ;;
        *)
            printf 'unsupported Android API level: %s\n' "$1" >&2
            printf 'supported API levels: 35\n' >&2
            return 2
            ;;
    esac
}

if [[ -z "$AOSP_REF" ]]; then
    AOSP_REF="$(resolve_aosp_ref "$ANDROID_API")"
fi
PROJECT_MANIFEST="$PROJECT_MANIFEST_DIR/android-${ANDROID_API}-projects.txt"

print_config() {
    printf '%s\n' \
        "AOSP_MANIFEST_URL=$AOSP_MANIFEST_URL" \
        "ANDROID_API=$ANDROID_API" \
        "AOSP_REF=$AOSP_REF" \
        "LIBHYBRIS_REPOSITORY=$LIBHYBRIS_REPOSITORY" \
        "LIBHYBRIS_REF=$LIBHYBRIS_REF" \
        "LUNCH_TARGET=$LUNCH_TARGET" \
        "JOBS=$JOBS" \
        "AOSP_DIR=$AOSP_DIR" \
        "DIST_DIR=$DIST_DIR" \
        "PROJECT_MANIFEST=$PROJECT_MANIFEST" \
        "MIN_FREE_GIB=$MIN_FREE_GIB" \
        "REPO_SYNC_TIMEOUT=$REPO_SYNC_TIMEOUT" \
        "BUILD_TIMEOUT=$BUILD_TIMEOUT"
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

if [[ ! "$MIN_FREE_GIB" =~ ^[1-9][0-9]*$ ]]; then
    printf 'MIN_FREE_GIB must be a positive integer, got: %s\n' "$MIN_FREE_GIB" >&2
    exit 2
fi

if [[ ! -f "$PROJECT_MANIFEST" ]]; then
    printf 'project manifest not found for Android API %s: %s\n' \
        "$ANDROID_API" "$PROJECT_MANIFEST" >&2
    exit 1
fi

sync_projects=()
while IFS= read -r project || [[ -n "$project" ]]; do
    case "$project" in
        ''|'#'*) continue ;;
    esac
    sync_projects+=("$project")
done < "$PROJECT_MANIFEST"

if (( ${#sync_projects[@]} == 0 )); then
    printf 'project manifest is empty: %s\n' "$PROJECT_MANIFEST" >&2
    exit 1
fi

for command in df file git nm readelf repo sha256sum timeout; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'required command not found: %s\n' "$command" >&2
        exit 1
    fi
done

mkdir -p "$AOSP_DIR" "$DIST_DIR"
exec > >(tee "$DIST_DIR/build.log") 2>&1

printf 'Build configuration:\n'
print_config
printf 'Synchronizing %s projects from %s\n' "${#sync_projects[@]}" "$PROJECT_MANIFEST"

available_kib="$(df --output=avail -k "$AOSP_DIR" | {
    read -r
    read -r value
    printf '%s\n' "$value"
})"
required_kib=$((MIN_FREE_GIB * 1024 * 1024))
if (( available_kib < required_kib )); then
    printf 'not enough free space for AOSP build: %s KiB available, %s GiB required\n' \
        "$available_kib" "$MIN_FREE_GIB" >&2
    df -h "$AOSP_DIR" >&2
    exit 1
fi
printf 'Free-space preflight passed:\n'
df -h "$AOSP_DIR"

printf '\n=== repo init ===\n'
(
    cd "$AOSP_DIR"
    repo init \
        --manifest-url="$AOSP_MANIFEST_URL" \
        --manifest-branch="$AOSP_REF" \
        --depth=1 \
        --partial-clone \
        --clone-filter=blob:limit=10M \
        --no-use-superproject

    printf '\n=== repo sync (timeout %s) ===\n' "$REPO_SYNC_TIMEOUT"
    timeout --foreground --signal=TERM --kill-after=60s "$REPO_SYNC_TIMEOUT" \
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
            --jobs="$JOBS" \
            "${sync_projects[@]}"
)

libhybris_dir="$AOSP_DIR/libhybris"
if [[ ! -d "$libhybris_dir/.git" ]]; then
    printf '\n=== initialize libhybris checkout ===\n'
    git init "$libhybris_dir"
    git -C "$libhybris_dir" remote add origin "$LIBHYBRIS_REPOSITORY"
fi

printf '\n=== checkout libhybris ===\n'
git -C "$libhybris_dir" fetch --depth=1 origin "$LIBHYBRIS_REF"
git -C "$libhybris_dir" checkout --detach FETCH_HEAD
libhybris_commit="$(git -C "$libhybris_dir" rev-parse HEAD)"

product_out_file="$DIST_DIR/android-product-out.txt"
(
    cd "$AOSP_DIR"
    printf '\n=== initialize Android build environment ===\n'
    set +u
    source build/envsetup.sh
    set -u
    lunch "$LUNCH_TARGET"
    printf '%s\n' "$ANDROID_PRODUCT_OUT" >"$product_out_file"
    printf '\n=== build libui_compat_layer (timeout %s) ===\n' "$BUILD_TIMEOUT"
    timeout --foreground --signal=TERM --kill-after=60s "$BUILD_TIMEOUT" \
        bash -c '
            set +u
            source build/envsetup.sh
            set -u
            lunch "$1"
            m -j"$2" libui_compat_layer
        ' _ "$LUNCH_TARGET" "$JOBS"
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
    "ANDROID_API=$ANDROID_API" \
    "AOSP_REF=$AOSP_REF" \
    "PROJECT_MANIFEST=$PROJECT_MANIFEST" \
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
