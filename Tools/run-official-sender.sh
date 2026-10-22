#!/bin/sh
set -eu

tool_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -z "${OMT_SDK_PATH:-}" ]; then
    printf '%s\n' 'Set OMT_SDK_PATH to the official SDK root or its Libraries/MacOS directory.' >&2
    exit 2
fi
sdk_libraries=$OMT_SDK_PATH
if [ -f "$sdk_libraries/Libraries/MacOS/libomt.h" ]; then
    sdk_libraries=$sdk_libraries/Libraries/MacOS
fi
if [ ! -f "$sdk_libraries/libomt.h" ] || [ ! -f "$sdk_libraries/libomt.dylib" ] || [ ! -f "$sdk_libraries/libvmx.dylib" ]; then
    printf '%s\n' 'OMT_SDK_PATH must contain libomt.h, libomt.dylib and libvmx.dylib.' >&2
    exit 2
fi
sdk_libraries=$(CDPATH= cd -- "$sdk_libraries" && pwd)

test_directory=$(mktemp -d "${TMPDIR:-/tmp}/omt-official-sender.XXXXXX")
sender_pid=
cleanup() {
    if [ -n "$sender_pid" ] && kill -0 "$sender_pid" 2>/dev/null; then
        kill -TERM "$sender_pid" 2>/dev/null || true
        wait "$sender_pid" 2>/dev/null || true
    fi
    rm -rf -- "$test_directory"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$test_directory/storage"

xcrun clang -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$sdk_libraries" -L "$sdk_libraries" \
    "$tool_directory/official-sdk-sender.c" -lomt -lvmx -lm -lpthread \
    -Wl,-rpath,"$sdk_libraries" -o "$test_directory/official-sdk-sender"

# Set before launching the linked SDK, including any library constructors. No
# operator OMT configuration or user settings are read/written by this run.
export OMT_STORAGE_PATH="$test_directory/storage"
export DYLD_LIBRARY_PATH="$sdk_libraries${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
"$test_directory/official-sdk-sender" "$@" &
sender_pid=$!
set +e
wait "$sender_pid"
sender_status=$?
set -e
sender_pid=
exit "$sender_status"
