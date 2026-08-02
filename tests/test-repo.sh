#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ -x "$root_dir/scripts/build.sh" ]]
[[ -f "$root_dir/.github/workflows/build.yml" ]]
[[ -f "$root_dir/README.md" ]]

bash -n "$root_dir/scripts/build.sh"

config="$({
    AOSP_REF=android-test \
    LIBHYBRIS_REF=hybris-test \
    LUNCH_TARGET=test_arm64-userdebug \
        "$root_dir/scripts/build.sh" --print-config
})"

[[ "$config" == *"AOSP_REF=android-test"* ]]
[[ "$config" == *"LIBHYBRIS_REF=hybris-test"* ]]
[[ "$config" == *"LUNCH_TARGET=test_arm64-userdebug"* ]]

python3 - "$root_dir/.github/workflows/build.yml" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    workflow = yaml.load(stream, Loader=yaml.BaseLoader)

dispatch = workflow["on"]["workflow_dispatch"]
inputs = dispatch["inputs"]
assert inputs["aosp_ref"]["default"] == "android-15.0.0_r3"
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
PY
