#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ -x "$root_dir/scripts/build.sh" ]]
[[ -f "$root_dir/.github/workflows/build.yml" ]]
[[ -f "$root_dir/README.md" ]]
[[ -f "$root_dir/manifests/android-35-projects.txt" ]]

bash -n "$root_dir/scripts/build.sh"

config="$({
    ANDROID_API=35 \
    AOSP_REF=android-test \
    LIBHYBRIS_REF=hybris-test \
    LUNCH_TARGET=test_arm64-userdebug \
        "$root_dir/scripts/build.sh" --print-config
})"

[[ "$config" == *"ANDROID_API=35"* ]]
[[ "$config" == *"AOSP_REF=android-test"* ]]
[[ "$config" == *"LIBHYBRIS_REF=hybris-test"* ]]
[[ "$config" == *"LUNCH_TARGET=test_arm64-userdebug"* ]]

if ANDROID_API=34 "$root_dir/scripts/build.sh" --print-config >/dev/null 2>&1; then
    exit 1
fi

python3 - "$root_dir/.github/workflows/build.yml" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    workflow = yaml.load(stream, Loader=yaml.BaseLoader)

dispatch = workflow["on"]["workflow_dispatch"]
inputs = dispatch["inputs"]
assert inputs["android_api"]["default"] == "35"
assert inputs["libhybris_ref"]["default"] == "lindroid-21"
assert inputs["lunch_target"]["default"] == "aosp_arm64-userdebug"
assert inputs["runner"]["default"] == "ubuntu-24.04"

build = workflow["jobs"]["build"]
assert build["runs-on"] == "${{ inputs.runner }}"

uses = [step.get("uses", "") for step in build["steps"]]
runs = [step.get("run", "") for step in build["steps"]]
assert "actions/checkout@v4" in uses
assert "actions/upload-artifact@v4" in uses
assert any("scripts/build.sh" in command for command in runs)
assert any("df -h" in command for command in runs)
assert any("/usr/local/lib/android" in command for command in runs)
assert any("MIN_FREE_GIB" in command for command in runs)
assert any("ANDROID_API" in command for command in runs)
PY

python3 - "$root_dir/scripts/build.sh" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    script = stream.read()

assert "--network-only" not in script
for option in ("--current-branch", "--force-sync", "--optimized-fetch"):
    assert script.count(option) == 1, f"duplicate repo option: {option}"
assert "REPO_SYNC_TIMEOUT" in script
assert "BUILD_TIMEOUT" in script
assert "MIN_FREE_GIB" in script
assert "timeout --foreground" in script
assert "android-${ANDROID_API}-projects.txt" in script
assert '"${sync_projects[@]}"' in script
PY

python3 - "$root_dir/manifests/android-35-projects.txt" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    projects = {
        line.strip()
        for line in stream
        if line.strip() and not line.lstrip().startswith("#")
    }

required = {
    "bionic",
    "build/make",
    "build/soong",
    "frameworks/native",
    "hardware/interfaces",
    "hardware/libhardware",
    "system/core",
    "system/libbase",
    "system/libhidl",
    "system/libfmq",
    "system/libhwbinder",
    "system/libvintf",
    "system/logging",
    "system/tools/aidl",
    "prebuilts/clang/host/linux-x86",
    "prebuilts/build-tools",
    "prebuilts/jdk/jdk17",
}
assert required <= projects, sorted(required - projects)
PY
