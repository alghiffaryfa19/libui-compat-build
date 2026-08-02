# Android 15 libui Compatibility Layer Build Design

Status: Accepted

## Goal

Create a small repository that remotely builds the arm64 Android-side
`libui_compat_layer.so` module from Linux-on-droid's libhybris source and
publishes the binary as a GitHub Actions artifact.

The output is intended for Android 15 systems. Runtime compatibility must be
validated on the target device because `libui` is a private Android platform
API and does not provide a stable cross-release C++ ABI.

## Scope

The repository will contain:

- A manually triggered GitHub Actions workflow.
- A build script that checks out Android 15 AOSP and libhybris, then builds only
  `libui_compat_layer`.
- An artifact collection script that verifies and packages the result.
- Documentation for runner requirements, inputs, outputs, and target-side
  validation.

The repository will not build a complete ROM, kernel, or MT6989 device tree.
The module is an Android platform library and does not consume SoC-specific
kernel or vendor source at build time.

## Source Inputs

The workflow exposes manual inputs with these defaults:

- AOSP manifest: `https://android.googlesource.com/platform/manifest`
- AOSP ref: `android-15.0.0_r3`
- Lunch target: `aosp_arm64-userdebug`
- libhybris repository: `https://github.com/Linux-on-droid/libhybris.git`
- libhybris ref: `lindroid-21`
- Runner label: configurable, with `ubuntu-24.04` as the portable default

The resolved AOSP and libhybris commit IDs will be recorded in the artifact.

## Runner Requirements

A full AOSP platform checkout is intentionally used because the module relies
on private `frameworks/native` headers and Android platform libraries that are
not available in the NDK.

The recommended runner has at least:

- 200 GiB free disk space
- 32 GiB RAM
- 4 CPU cores
- A six-hour or longer job timeout

The workflow accepts a runner label so a GitHub larger runner or self-hosted
runner can be selected. A standard GitHub-hosted runner may run out of disk and
is not considered a reliable build environment.

## Build Flow

1. Check out this orchestration repository.
2. Install the `repo` launcher and required host packages.
3. Initialize AOSP with partial-clone support and the selected Android 15 ref.
4. Synchronize the current AOSP branch without tags or clone bundles.
5. Clone libhybris at the selected ref into the AOSP source root.
6. Run `source build/envsetup.sh` and lunch the selected arm64 target.
7. Build only `libui_compat_layer` with Soong/Kati.
8. Copy the resulting shared object and diagnostics into `dist/`.
9. Upload `dist/` as a versioned GitHub Actions artifact.

The build script will use strict shell settings and preserve the full build log
when a build fails.

## Artifact Validation

The packaging step must reject a missing or empty output. It will record:

- `file` output confirming a 64-bit AArch64 shared object
- ELF header and dynamic dependency information from `readelf`
- Exported dynamic symbols from `nm`
- SHA-256 checksum
- AOSP ref and resolved manifest revision
- libhybris repository, ref, and resolved commit
- Lunch target and workflow run identifiers

The expected artifact is named with the Android ref and short libhybris commit,
and contains `libui_compat_layer.so`, metadata, checksum, and diagnostic files.

## Workflow Behavior

The workflow is manual-only (`workflow_dispatch`) because source synchronization
is expensive. Concurrent runs for the same ref are serialized without silently
cancelling an active build. Build diagnostics are uploaded even when compilation
fails; the binary artifact is uploaded only after validation succeeds.

No credentials beyond GitHub's normal checkout token are required for public
source repositories.

## Acceptance Criteria

- Workflow YAML parses successfully.
- Build and packaging scripts pass shell syntax checks and ShellCheck.
- The workflow can build `libui_compat_layer` on a suitably sized runner.
- A successful artifact contains an AArch64 ELF shared object and complete
  provenance metadata.
- Documentation clearly separates build success from target-device runtime
  compatibility.

## Follow-up Runtime Test

After downloading the artifact, target validation must load it through
libhybris and exercise allocation, import, lock, unlock, and free paths. Merely
loading the ELF is insufficient to establish compatibility with the target
Android 15 `libui.so`.
