#!/usr/bin/env bash
# Stage trusted public test assets in a developer emulator, never a user's app store.
set -euo pipefail
: "${ANDROID_SDK_ROOT:?Set ANDROID_SDK_ROOT}"
: "${MODEL_FIXTURES:?Directory containing downloaded model files and zh.wav}"
adb="$ANDROID_SDK_ROOT/platform-tools/adb"
device="${ANDROID_SERIAL:-emulator-5554}"
case "$device" in
  emulator-[0-9]*) ;;
  *) echo "Only a developer emulator is allowed" >&2; exit 2 ;;
esac
if [[ "$("$adb" -s "$device" shell getprop ro.kernel.qemu)" != "1" ]]; then
  echo "Target is not a QEMU Android emulator" >&2
  exit 2
fi
base=/data/local/tmp/nianxia-models
"$adb" -s "$device" shell mkdir -p "$base/sensevoice-2365baeacb507f821a0c8120fcee3d484dba7a07" "$base/bge-75c43b069aac4d136ba6bc1122f995fedcfd2781"
"$adb" -s "$device" push "$MODEL_FIXTURES/sensevoice.int8.onnx" "$base/sensevoice-2365baeacb507f821a0c8120fcee3d484dba7a07/model.int8.onnx"
"$adb" -s "$device" push "$MODEL_FIXTURES/tokens.txt" "$base/sensevoice-2365baeacb507f821a0c8120fcee3d484dba7a07/tokens.txt"
"$adb" -s "$device" push "$MODEL_FIXTURES/bge.int8.onnx" "$base/bge-75c43b069aac4d136ba6bc1122f995fedcfd2781/model.int8.onnx"
"$adb" -s "$device" push "$MODEL_FIXTURES/vocab.txt" "$base/bge-75c43b069aac4d136ba6bc1122f995fedcfd2781/vocab.txt"
"$adb" -s "$device" push "$MODEL_FIXTURES/zh.wav" "$base/zh.wav"
"$adb" -s "$device" shell touch "$base/sensevoice-2365baeacb507f821a0c8120fcee3d484dba7a07/.ready" "$base/bge-75c43b069aac4d136ba6bc1122f995fedcfd2781/.ready"
