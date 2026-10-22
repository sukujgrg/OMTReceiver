#!/bin/bash
set -euo pipefail
project_directory=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
if [ "$#" -ne 1 ] || [ -z "${OMT_SDK_PATH:-}" ]; then
    printf '%s\n' 'Usage: OMT_SDK_PATH=/path/to/sdk Tools/package-mac-sender.sh NEW-OUTPUT-DIRECTORY' >&2
    exit 2
fi
package_directory=$1
if [ -e "$package_directory" ]; then
    printf '%s\n' 'Refusing to overwrite an existing output directory.' >&2
    exit 2
fi
sdk_directory=$OMT_SDK_PATH
if [ -f "$sdk_directory/Libraries/MacOS/libomt.h" ]; then sdk_directory=$sdk_directory/Libraries/MacOS; fi
for library in libomt libvmx; do
    for architecture in arm64 x86_64; do
        xcrun lipo -verify_arch "$architecture" "$sdk_directory/$library.dylib"
    done
done
mkdir -p "$package_directory/Libraries/MacOS"
for name in libomt.dylib libvmx.dylib libomtnet.dll libomt.h; do
    cp "$sdk_directory/$name" "$package_directory/Libraries/MacOS/$name"
done
if [ -f "$OMT_SDK_PATH/LICENSE.txt" ]; then cp "$OMT_SDK_PATH/LICENSE.txt" "$package_directory/LICENSE-OMT.txt"; fi
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -arch arm64 -arch x86_64 \
    -mmacosx-version-min=13.0 -I "$sdk_directory" -L "$sdk_directory" \
    "$project_directory/Tools/official-sdk-sender.c" -lomt -lvmx -lm -lpthread \
    -Wl,-rpath,@executable_path/Libraries/MacOS -o "$package_directory/OMTLANSender"
codesign --force --sign - "$package_directory/OMTLANSender"
cat > "$package_directory/Start OMT LAN Sender.command" <<'COMMAND'
#!/bin/bash
set -euo pipefail
sender_directory=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/omt-lan-sender.XXXXXX")
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
export OMT_STORAGE_PATH="$test_directory/storage"
export DYLD_LIBRARY_PATH="$sender_directory/Libraries/MacOS${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
printf '%s\n' 'OMT LAN Test: 1080p up to 60 fps, stereo audio, one-hour maximum. Press Control-C to stop.'
printf '%s\n' 'On the TV, use this Mac’s discovered OMT LAN Test source or Ethernet IP with port 6488.'
/usr/bin/caffeinate -i "$sender_directory/OMTLANSender" --seconds 3600 --name 'OMT LAN Test' --benchmark "$@" &
sender_pid=$!
set +e
wait "$sender_pid"
sender_status=$?
set -e
sender_pid=
exit "$sender_status"
COMMAND
chmod +x "$package_directory/Start OMT LAN Sender.command"
cat > "$package_directory/README.txt" <<'README'
OMT LAN sender fixture — official SDK 1.0.0.19

1. Copy this ENTIRE folder to the Mac connected by Ethernet. Leave Libraries in place.
2. Double-click “Start OMT LAN Sender.command”. If needed, open Terminal, type
   bash followed by a space, drag that .command file into Terminal, then press Return.
3. Leave Terminal open. Source: “OMT LAN Test” (prefixed with this Mac’s hostname).
4. Tell the receiver operator this Mac’s Ethernet IP or full discovered source name.
   The sender uses TCP 6488. Allow incoming connections if macOS asks.
5. Stop using Control-C. It also stops automatically after one hour.

The default rate is 30 fps. To send 60 fps from Terminal, run:
  bash "Start OMT LAN Sender.command" --fps 60
Fractional rates such as --fps 60000/1001 are also supported.

Apple Silicon and Intel binaries are included; macOS 13 or later. Xcode and .NET
are not needed on this Mac. This uses the same independent official-SDK pattern
as the original benchmark. Audio is low-level stereo 48 kHz, with a tone/visual
marker every second. Existing OMT settings are not read or changed. Only an
isolated temporary settings directory is created and removed on exit.

The executable is locally ad-hoc signed for testing and is not notarized. If a
security prompt blocks it, keep the prompt and ask the receiver operator for
help. No system security or firewall settings need to be disabled.

Upstream SDK: https://github.com/openmediatransport/libomtnet/releases
The upstream MIT license is included in LICENSE-OMT.txt.
README
printf 'Saved portable universal Mac sender: %s\n' "$package_directory"
