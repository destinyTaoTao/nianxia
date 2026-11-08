#!/usr/bin/env bash
# Stage trusted public test assets in a developer emulator, never a user's app store.
set -euo pipefail
: "${ANDROID_SDK_ROOT:?Set ANDROID_SDK_ROOT}"
: "${MODEL_FIXTURES:?Directory containing downloaded model files and zh.wav}"
adb="$ANDROID_SDK_ROOT/platform-tools/adb"
base=/data/local/tmp/nianxia-models
"$adb" shell mkdir -p "$base/sensevoice-2365baeacb507f821a0c8120fcee3d484dba7a07" "$base/bge-75c43b069aac4d136ba6bc1122f995fedcfd2781"
"$adb" push "$MODEL_FIXTURES/sensevoice.int8.onnx" "$base/sensevoice-2365baeacb507f821a0c8120fcee3d484dba7a07/model.int8.onnx"
"$adb" push "$MODEL_FIXTURES/tokens.txt" "$base/sensevoice-2365baeacb507f821a0c8120fcee3d484dba7a07/tokens.txt"
"$adb" push "$MODEL_FIXTURES/bge.int8.onnx" "$base/bge-75c43b069aac4d136ba6bc1122f995fedcfd2781/model.int8.onnx"
"$adb" push "$MODEL_FIXTURES/vocab.txt" "$base/bge-75c43b069aac4d136ba6bc1122f995fedcfd2781/vocab.txt"
"$adb" push "$MODEL_FIXTURES/zh.wav" "$base/zh.wav"
"$adb" shell touch "$base/sensevoice-2365baeacb507f821a0c8120fcee3d484dba7a07/.ready" "$base/bge-75c43b069aac4d136ba6bc1122f995fedcfd2781/.ready"
