#!/usr/bin/env bash
set -Eeuo pipefail

# Build Android 16 Lindroid native libraries for the Xiaomi Pad 6S Pro.
# This script prepares the source tree and records artifacts; it does not flash
# or install anything on the device.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
AOSP_DIR="${AOSP_DIR:-$REPO_ROOT/.work/aosp-android16}"
DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist/android16-lindroid}"
JOBS="${JOBS:-$(nproc)}"
SYNC_JOBS="${SYNC_JOBS:-1}"
AOSP_REF="${AOSP_REF:-android-16.0.0_r4}"
LUNCH_TARGET="${LUNCH_TARGET:-aosp_arm64-trunk_staging-userdebug}"
LIBHYBRIS_REPOSITORY="${LIBHYBRIS_REPOSITORY:-https://github.com/Linux-on-droid/libhybris.git}"
LIBHYBRIS_REF="${LIBHYBRIS_REF:-lindroid-drm}"
VENDOR_REPOSITORY="${VENDOR_REPOSITORY:-https://github.com/Linux-on-droid/vendor_lindroid.git}"
VENDOR_REF="${VENDOR_REF:-lindroid-22.1}"
VENDOR_DIR="${VENDOR_DIR:-$REPO_ROOT/.work/vendor_lindroid}"
# scratch/libhybris-compat is only a compatibility-layer snapshot, not the
# full Linux-on-droid/libhybris checkout required for the lindroid-drm branch.
LIBHYBRIS_DIR="${LIBHYBRIS_DIR:-$REPO_ROOT/.work/libhybris-lindroid-drm}"
PROJECT_MANIFEST="${PROJECT_MANIFEST:-$SCRIPT_DIR/../manifests/android-36-projects.txt}"
REPO_SYNC_TIMEOUT="${REPO_SYNC_TIMEOUT:-90m}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-240m}"

log() { printf '\n== %s ==\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

link_checkout() {
    local source="$1"
    local destination="$2"

    if [[ -L "$destination" ]]; then
        [[ "$(readlink -- "$destination")" == "$source" ]] || \
            die "$destination already exists with a different target"
        return 0
    fi
    [[ ! -e "$destination" ]] || die "$destination already exists; remove it or set the checkout paths explicitly"
    ln -s "$source" "$destination"
}

clone_branch() {
    local repository="$1"
    local branch="$2"
    local destination="$3"
    local attempt

    for attempt in 1 2 3; do
        rm -rf "$destination"
        if git clone --depth=1 --single-branch --branch "$branch" \
            --filter=blob:none -c http.version=HTTP/1.1 \
            "$repository" "$destination"; then
            return 0
        fi
        printf 'WARN: clone failed (attempt %s/3): %s %s\n' \
            "$attempt" "$repository" "$branch" >&2
        rm -rf "$destination"
    done

    # GitHub's codeload endpoint avoids smart-HTTP negotiation failures on
    # hosted runners while preserving the exact branch contents.
    local archive_url="${repository%.git}/archive/refs/heads/${branch}.tar.gz"
    local archive_file
    archive_file="$(mktemp)"
    printf 'INFO: falling back to source archive: %s\n' "$archive_url"
    if curl -fL --retry 3 --retry-all-errors "$archive_url" -o "$archive_file"; then
        mkdir -p "$destination"
        tar -xzf "$archive_file" --strip-components=1 -C "$destination"
        rm -f "$archive_file"
        return 0
    fi
    rm -f "$archive_file"
    die "unable to fetch $repository at branch $branch"
}

usage() {
    cat <<'EOF'
Usage: build-android16-lindroid.sh [--prepare|--build|--package]

Default: prepare the source tree, build the four native targets, and package
artifacts under dist/android16-lindroid/artifact.

Required host tools: repo, git, curl, file, readelf, nm, sha256sum, timeout.
The build needs roughly 55 GiB free disk and a working AOSP build environment.
This script never flashes a device.
EOF
}

mode="all"
case "${1:-}" in
    "") ;;
    --prepare) mode=prepare ;;
    --build) mode=build ;;
    --package) mode=package ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

if ! command -v repo >/dev/null 2>&1 && [[ -x "$HOME/bin/repo" ]]; then
    export PATH="$HOME/bin:$PATH"
fi

for command in curl git repo file readelf nm sha256sum tar timeout; do
    command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
repo --version >/dev/null 2>&1 || die "repo launcher is invalid; reinstall from storage.googleapis.com/git-repo-downloads/repo"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"
[[ "$SYNC_JOBS" =~ ^[1-9][0-9]*$ ]] || die "SYNC_JOBS must be a positive integer"
[[ -f "$PROJECT_MANIFEST" ]] || die "missing Android 16 project manifest: $PROJECT_MANIFEST"

mkdir -p "$AOSP_DIR" "$DIST_DIR"
exec > >(tee "$DIST_DIR/build.log") 2>&1

log "Configuration"
printf '%s\n' \
    "AOSP_DIR=$AOSP_DIR" \
    "AOSP_REF=$AOSP_REF" \
    "LUNCH_TARGET=$LUNCH_TARGET" \
    "LIBHYBRIS_REF=$LIBHYBRIS_REF" \
    "VENDOR_REF=$VENDOR_REF" \
    "VENDOR_DIR=$VENDOR_DIR" \
    "LIBHYBRIS_DIR=$LIBHYBRIS_DIR" \
    "PROJECT_MANIFEST=$PROJECT_MANIFEST" \
    "JOBS=$JOBS" \
    "SYNC_JOBS=$SYNC_JOBS"

prepare_checkout() {

    log "vendor_lindroid checkout"
    if [[ -d "$VENDOR_DIR/.git" ]]; then
        git -C "$VENDOR_DIR" fetch --depth=1 --filter=blob:none origin "$VENDOR_REF"
        git -C "$VENDOR_DIR" checkout --detach FETCH_HEAD
    else
        clone_branch "$VENDOR_REPOSITORY" "$VENDOR_REF" "$VENDOR_DIR"
    fi

    log "libhybris checkout"
    if [[ -d "$LIBHYBRIS_DIR/.git" ]]; then
        git -C "$LIBHYBRIS_DIR" fetch --depth=1 --filter=blob:none origin "$LIBHYBRIS_REF"
        git -C "$LIBHYBRIS_DIR" checkout --detach FETCH_HEAD
    else
        clone_branch "$LIBHYBRIS_REPOSITORY" "$LIBHYBRIS_REF" "$LIBHYBRIS_DIR"
    fi
    
    log "AOSP checkout"
    if [[ ! -d "$AOSP_DIR/.repo" ]]; then
        (
            cd "$AOSP_DIR"
            repo init \
                --manifest-url=https://android.googlesource.com/platform/manifest \
                --manifest-branch="$AOSP_REF" \
                --depth=1 \
                --partial-clone \
                --clone-filter=blob:limit=10M \
                --no-use-superproject
        )
    fi
    local projects=()
    while IFS= read -r project || [[ -n "$project" ]]; do
        case "$project" in ''|'#'*) continue ;; esac
        projects+=("$project")
    done < "$PROJECT_MANIFEST"
    ((${#projects[@]} > 0)) || die "none of the requested projects exist in the AOSP manifest"
    if ! (cd "$AOSP_DIR" && timeout --foreground --signal=TERM --kill-after=60s "$REPO_SYNC_TIMEOUT" \
        repo sync --current-branch --detach --force-sync --no-clone-bundle --no-tags \
        --optimized-fetch --prune --fail-fast --retry-fetches=3 --jobs="$SYNC_JOBS" "${projects[@]}"); then
        die "repo sync failed; inspect $DIST_DIR/build.log for the first project error"
    fi

    [[ -d "$LIBHYBRIS_DIR" ]] || die "libhybris checkout missing"
    [[ -d "$VENDOR_DIR" ]] || die "vendor_lindroid checkout missing"

    # These paths are the expected AOSP integration points. Reuse only the
    # exact symlinks created by this script; never overwrite another path.
    mkdir -p "$AOSP_DIR/vendor" "$AOSP_DIR/external"
    link_checkout "$VENDOR_DIR" "$AOSP_DIR/vendor/lindroid"
    link_checkout "$LIBHYBRIS_DIR" "$AOSP_DIR/external/libhybris"
}

build_targets() {
    log "AOSP build"
    cd "$AOSP_DIR"
    set +u
    source build/envsetup.sh
    lunch "$LUNCH_TARGET"
    set -u
    timeout --foreground --signal=TERM --kill-after=60s "$BUILD_TIMEOUT" \
        m -j"$JOBS" libjni_lindroidui vendor.lindroid.composer-ndk \
        libhwc2_compat_layer libui_compat_layer
}

package_artifacts() {
    log "Package artifacts"
    local artifact_dir="$DIST_DIR/artifact"
    mkdir -p "$artifact_dir"
    local names=(
        libjni_lindroidui.so
        vendor.lindroid.composer-ndk.so
        libhwc2_compat_layer.so
        libui_compat_layer.so
        graphics.common-V7-ndk.so
    )
    local search_roots=()
    while IFS= read -r product_out; do
        search_roots+=("$product_out/system/lib64" "$product_out/system_ext/lib64" "$product_out/vendor/lib64")
    done < <(find "$AOSP_DIR/out/target/product" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)
    ((${#search_roots[@]} > 0)) || die "no AOSP product output found under $AOSP_DIR/out/target/product"
    for name in "${names[@]}"; do
        local source=""
        for root in "${search_roots[@]}"; do
            if [[ -s "$root/$name" ]]; then source="$root/$name"; break; fi
        done
        [[ -n "$source" ]] || die "built artifact not found: $name"
        cp -L "$source" "$artifact_dir/$name"
        file "$artifact_dir/$name"
        readelf -d "$artifact_dir/$name" >"$artifact_dir/$name.dynamic.txt"
    done
    (
        cd "$artifact_dir"
        sha256sum *.so >SHA256SUMS
    )
    git -C "$AOSP_DIR" rev-parse HEAD >"$artifact_dir/aosp-head.txt" || true
    git -C "$LIBHYBRIS_DIR" rev-parse HEAD >"$artifact_dir/libhybris-head.txt"
    git -C "$VENDOR_DIR" rev-parse HEAD >"$artifact_dir/vendor-lindroid-head.txt"
    printf 'Artifacts: %s\n' "$artifact_dir"
}

[[ "$mode" == prepare || "$mode" == all ]] && prepare_checkout
[[ "$mode" == build || "$mode" == all ]] && build_targets
[[ "$mode" == package || "$mode" == all ]] && package_artifacts
