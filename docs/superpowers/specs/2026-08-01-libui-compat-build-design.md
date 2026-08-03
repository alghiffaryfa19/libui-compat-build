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
- A build script that initializes Android 15 AOSP, synchronizes only the
  dependency projects in `manifests/android-35-projects.txt`, and builds only
  `libui_compat_layer`.
- Artifact validation and provenance collection.
- Documentation for runner requirements, inputs, outputs, and target-side
  validation.

The repository will not build a complete ROM, kernel, or MT6989 device tree.
The module is an Android platform library and does not consume SoC-specific
kernel or vendor source at build time.

## Source Inputs

The workflow exposes manual inputs with these defaults:

- AOSP manifest: `https://android.googlesource.com/platform/manifest`
- Android API: `35`, mapped to AOSP ref `android-15.0.0_r3`
- Lunch target: `aosp_arm64-trunk_staging-userdebug`
- libhybris repository: `https://github.com/Linux-on-droid/libhybris.git`
- libhybris ref: `lindroid-21`
- Runner label: configurable, with `ubuntu-24.04` as the portable default

The resolved AOSP and libhybris commit IDs are recorded in the artifact.

## Runner Requirements

A complete platform checkout is not required. The module relies on private
`frameworks/native` headers and Android platform libraries, so the workflow
uses a versioned project allowlist containing the build system, native graphics
stack, graphics interfaces, core libraries, and host toolchains.

The recommended runner has at least:

- 55 GiB free disk space
- 16 GiB RAM
- 4 CPU cores
- A six-hour or longer job timeout

The workflow accepts a runner label so a GitHub larger runner or self-hosted
runner can be selected. The script fails before synchronization when fewer than
55 GiB are available. Unsupported API levels fail rather than silently using a
different Android platform's headers.

Repository synchronization and compilation also have independent timeouts so
an unavailable network or stalled build fails with a diagnostic phase marker
instead of consuming the full workflow timeout.

## Build Flow

1. Check out this orchestration repository.
2. Reclaim known large preinstalled SDK/tool directories and report capacity.
3. Install the `repo` launcher and required host packages.
4. Resolve the Android API level to an AOSP ref and its project allowlist.
5. Initialize AOSP with partial-clone support and synchronize only that
   allowlist, without tags or clone bundles.
6. Clone libhybris at the selected ref into the AOSP source root.
7. Run `source build/envsetup.sh` and lunch the selected arm64 target.
8. Build only `libui_compat_layer` with the Android build shell.
9. Copy the resulting shared object and diagnostics into `dist/`.
10. Upload `dist/` as a versioned GitHub Actions artifact.

The build script uses strict shell settings, phase markers, and preserves the
full build log when a build fails.

## Artifact Validation

The packaging step rejects a missing or empty output. It records:

- `file` output confirming a 64-bit AArch64 shared object
- ELF header and dynamic dependency information from `readelf`
- Exported dynamic symbols from `nm`
- SHA-256 checksum
- AOSP ref and resolved manifest revision
- libhybris repository, ref, and resolved commit
- Lunch target and workflow run identifiers when available

The artifact contains `libui_compat_layer.so`, metadata, checksum, and
diagnostic files.

## Workflow Behavior

The workflow is manual-only (`workflow_dispatch`) because source
synchronization is expensive. Concurrent runs for the same ref are serialized
without silently cancelling an active build. Build diagnostics are uploaded
even when compilation fails; the binary artifact is uploaded only after
validation succeeds.

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
libhybris and exercise allocation, import, lock, unlock, and free operations.
Merely loading the ELF is insufficient to establish compatibility with the
target Android 15 `libui.so`.
