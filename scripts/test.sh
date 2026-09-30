#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch_dir=$(mktemp -d "${TMPDIR:-/tmp}/somnus-tests.XXXXXX")
trap 'rm -rf "$scratch_dir"' EXIT HUP INT TERM

cd "$repo_dir"
sdk_path=$(xcrun --show-sdk-path --sdk macosx)
host_arch=$(uname -m)
target="$host_arch-apple-macos26.0"

kit_sources="
Sources/SomnusKit/PowerTypes.swift
Sources/SomnusKit/SomnusClient.swift
Sources/SomnusKit/SomnusConstants.swift
Sources/SomnusKit/SomnusError.swift
Sources/SomnusKit/SomnusHelperProtocol.swift
Sources/SomnusKit/SomnusCodeRequirement.swift
Sources/SomnusKit/SomnusStateChangeSignal.swift
Sources/SomnusKit/SleepAssertionParser.swift
"

echo "Building isolated SomnusKit test module"
# shellcheck disable=SC2086
xcrun swiftc -emit-module -emit-library -static -module-name SomnusKit \
  -target "$target" -sdk "$sdk_path" -swift-version 5 \
  -emit-module-path "$scratch_dir/SomnusKit.swiftmodule" \
  -o "$scratch_dir/libSomnusKit.a" $kit_sources

echo "Running power-engine tests"
xcrun swiftc -D SOMNUS_POWER_TESTS -target "$target" -sdk "$sdk_path" \
  -swift-version 5 -parse-as-library -I "$scratch_dir" -L "$scratch_dir" \
  -lSomnusKit Sources/Somnus/Power/*.swift \
  Sources/Somnus/Power/Tests/*.swift -o "$scratch_dir/power-tests"
"$scratch_dir/power-tests"

echo "Running heartbeat-store tests"
xcrun swiftc -D SOMNUS_HEARTBEAT_TESTS -target "$target" -sdk "$sdk_path" \
  -swift-version 5 -parse-as-library -I "$scratch_dir" -L "$scratch_dir" \
  -lSomnusKit Sources/somnusd/PMSet.swift \
  Sources/somnusd/MonitoringHeartbeatStore.swift \
  Sources/somnusd/Tests/MonitoringHeartbeatStoreTests.swift \
  -o "$scratch_dir/heartbeat-tests"
"$scratch_dir/heartbeat-tests"

echo "Building complete SomnusKit module for control tests"
xcrun swiftc -emit-module -emit-library -static -module-name SomnusKit \
  -target "$target" -sdk "$sdk_path" -swift-version 5 \
  -emit-module-path "$scratch_dir/SomnusKit.swiftmodule" \
  -o "$scratch_dir/libSomnusKit.a" Sources/SomnusKit/*.swift

echo "Running Control Center display tests"
xcrun swiftc -D SOMNUS_CONTROL_TESTS -target "$target" -sdk "$sdk_path" \
  -swift-version 5 -parse-as-library -I "$scratch_dir" -L "$scratch_dir" \
  -lSomnusKit Sources/SomnusControl/StayAwakeControl.swift \
  Sources/SomnusControl/Tests/StayAwakeControlTests.swift \
  -o "$scratch_dir/control-tests"
"$scratch_dir/control-tests"

echo "All isolated tests passed. No real power setting was changed."
