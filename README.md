# libui-compat-build

GitHub Actions wrapper for building the Android 15 arm64
`libui_compat_layer.so` module from
[Linux-on-droid/libhybris](https://github.com/Linux-on-droid/libhybris).

The module uses private Android platform headers, so an NDK-only build is not
enough. The workflow initializes AOSP but synchronizes only the Android 15
projects listed in `manifests/android-35-projects.txt`; it does not download
the unrelated AOSP projects. It does not need an MT6989 kernel or device tree.

## Run

1. Push this repository to GitHub.
2. Open **Actions > Build libui compatibility layer > Run workflow**.
3. Select the Android SDK/API level, libhybris ref, lunch target, and runner
   label.
4. Download the `libui-compat-<run-id>` artifact when the job completes.

Defaults:

- Android API: `35` -> AOSP `android-15.0.0_r3`
- libhybris: `Linux-on-droid/libhybris`, branch `lindroid-21`
- target: `aosp_arm64-userdebug`

The minimal project set is intended to fit on a standard runner, but use at
least 55 GiB of free disk and 16 GiB RAM. A larger or self-hosted runner is
preferred. The script checks free space before synchronization and stops with a
clear error when the runner is too small.

Only API 35 is currently mapped. An unsupported API fails instead of silently
using headers from a different Android release.

The workflow also limits AOSP synchronization to 90 minutes and compilation to
240 minutes. Override `MIN_FREE_GIB`, `REPO_SYNC_TIMEOUT`, or
`BUILD_TIMEOUT` in a self-hosted workflow copy when the runner has different
capacity or performance characteristics.

The artifact contains the library, its checksum, ELF diagnostics, build log,
resolved AOSP manifest, and libhybris commit metadata.

## Runtime Warning

`libui` is a private Android C++ API. A successful build does not guarantee ABI
compatibility with every Android 15 system image. Validate allocation, import,
lock, unlock, and free operations on the target before using the library in a
GUI path.
