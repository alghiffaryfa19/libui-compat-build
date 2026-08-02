# libui-compat-build

GitHub Actions wrapper for building the Android 15 arm64
`libui_compat_layer.so` module from
[Linux-on-droid/libhybris](https://github.com/Linux-on-droid/libhybris).

The module uses private Android platform headers, so an NDK-only build is not
enough. The workflow downloads an Android 15 AOSP tree and runs the platform
build for this module only. It does not need an MT6989 kernel or device tree.

## Run

1. Push this repository to GitHub.
2. Open **Actions > Build libui compatibility layer > Run workflow**.
3. Select the Android ref, libhybris ref, lunch target, and runner label.
4. Download the `libui-compat-<run-id>` artifact when the job completes.

Defaults:

- AOSP: `android-15.0.0_r3`
- libhybris: `Linux-on-droid/libhybris`, branch `lindroid-21`
- target: `aosp_arm64-userdebug`

Use a larger or self-hosted runner with roughly 200 GiB of free disk and at
least 32 GiB RAM. A standard GitHub-hosted runner is likely to run out of disk
while synchronizing AOSP.

The artifact contains the library, its checksum, ELF diagnostics, build log,
resolved AOSP manifest, and libhybris commit metadata.

## Runtime Warning

`libui` is a private Android C++ API. A successful build does not guarantee ABI
compatibility with every Android 15 system image. Validate allocation, import,
lock, unlock, and free operations on the target before using the library in a
GUI path.
