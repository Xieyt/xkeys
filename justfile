app := "/Applications/xkeys.app"
# A STABLE local code-signing identity is what lets the Accessibility and
# Input Monitoring grants survive a rebuild — ad-hoc (`-s -`) signatures
# change identity every build, so macOS treats each build as a new app and
# re-prompts. Create one with `just setup-signing-cert`, or override:
#   just signing_cert=my-identity install
signing_cert := "xkeys-codesign"
sys_keychain := "/Library/Keychains/System.keychain"

# `swift build` must not see nix's SDK/toolchain env: the devShell exports
# DEVELOPER_DIR/SDKROOT pointing at nixpkgs' apple-sdk_14, which the system
# Swift 6.x compiler rejects ("SDK is built with Apple Swift 5.10 ... select a
# toolchain which matches the SDK"). Stripping them falls back to the system
# CommandLineTools SDK, which matches.
swift := "env -u SDKROOT -u DEVELOPER_DIR -u LIBRARY_PATH /usr/bin/swift"

# list recipes
default:
    @just --list

# build the release binary
build:
    {{swift}} build -c release

# run the pure-logic regression checks
#
# Not `swift test`: this machine has Command Line Tools and no Xcode, which
# ships neither XCTest nor swift-testing, so a test target cannot run at all
# here. The checks are compiled together with the sources they cover, which
# needs nothing installed.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(mktemp -d)/checks
    env -u SDKROOT -u DEVELOPER_DIR /usr/bin/xcrun --sdk macosx swiftc -O \
      Sources/xkeys/Config.swift \
      Sources/xkeys/KeyNames.swift \
      Sources/xkeys/HIDKeyTable.swift \
      Sources/xkeys/HIDMapping.swift \
      Sources/xkeys/Log.swift \
      Sources/xkeys/Constants.swift \
      Checks/main.swift \
      -o "$out"
    "$out"

# build, swap the binary into the installed bundle, re-sign, relaunch
dev-install: build
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{app}}" ]; then
      echo "!! {{app}} not present — run \`just install\` first"; exit 1
    fi
    pkill -x xkeys 2>/dev/null || true
    sleep 1
    cp .build/release/xkeys "{{app}}/Contents/MacOS/xkeys"
    just signing_cert="{{signing_cert}}" _sign
    open "{{app}}"
    sleep 2
    just status

# full install: build the .app bundle from scratch, sign, install, launch
install: build
    #!/usr/bin/env bash
    set -euo pipefail
    stage=$(mktemp -d)/xkeys.app
    mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
    cp .build/release/xkeys "$stage/Contents/MacOS/"
    cp Info.plist "$stage/Contents/"
    cp AppIcon.icns "$stage/Contents/Resources/"
    pkill -x xkeys 2>/dev/null || true
    sleep 1
    rm -rf "{{app}}"
    cp -R "$stage" "{{app}}"
    rm -rf "$(dirname "$stage")"
    just signing_cert="{{signing_cert}}" _sign
    open "{{app}}"
    sleep 2
    just status

# sign the installed bundle with the stable identity (ad-hoc fallback warns)
_sign:
    #!/usr/bin/env bash
    set -euo pipefail
    if security find-certificate -c "{{signing_cert}}" "{{sys_keychain}}" >/dev/null 2>&1; then
      codesign -f -s "{{signing_cert}}" --identifier com.xieyt.xkeys "{{app}}"
    else
      echo "!! '{{signing_cert}}' not in System keychain; signing ad-hoc."
      echo "   Accessibility/Input Monitoring will be re-prompted on every build."
      echo "   Fix: run \`just setup-signing-cert\`, then re-run this."
      codesign -f -s - --identifier com.xieyt.xkeys "{{app}}"
    fi

# restart the app
restart:
    pkill -x xkeys 2>/dev/null || true
    sleep 1
    open "{{app}}"

# stop the app
stop:
    pkill -x xkeys 2>/dev/null || true

# what's running, what's signed, what's granted, is the remap live
status:
    #!/usr/bin/env bash
    pid=$(pgrep -x xkeys || true)
    echo "process:   ${pid:-not running}"
    echo -n "signature: "
    codesign -dvvv "{{app}}" 2>&1 | grep -E "^Authority=" || echo "ad-hoc/unsigned"
    echo "swaps:"
    "{{app}}/Contents/MacOS/xkeys" keys 2>/dev/null | sed -n '2,/^$/p' || echo "  (app not installed)"
    echo "chords:"
    "{{app}}/Contents/MacOS/xkeys" keys 2>/dev/null \
      | sed -n '/^Chords for other apps/,/^$/p' | sed -n '2,$p' | sed '/^$/d' \
      || echo "  (app not installed)"
    echo "TCC grants:"
    sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
      "select '  '||service||' = '||auth_value from access where client='com.xieyt.xkeys';" \
      2>/dev/null || echo "  (cannot read TCC.db)"
    echo "  note: kTCCServiceListenEvent (Input Monitoring) is required for the"
    echo "        Keyboards menu and external-keyboard support on macOS 26+."

# reset Accessibility/Input Monitoring (only needed when changing signing identity)
reset-permissions:
    tccutil reset Accessibility com.xieyt.xkeys
    tccutil reset ListenEvent com.xieyt.xkeys || true
    @echo "Relaunch the app and approve the prompts."

# open the panes where the two required permissions are granted
open-permissions:
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    sleep 1
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"

# remove this app's swaps (leaving any other tool's alone) and delete it
uninstall:
    "{{app}}/Contents/MacOS/xkeys" --uninstall || true
    just stop
    rm -rf "{{app}}"

# create the stable self-signed code-signing identity in the System keychain
setup-signing-cert:
    #!/usr/bin/env bash
    set -euo pipefail
    if security find-certificate -c "{{signing_cert}}" "{{sys_keychain}}" >/dev/null 2>&1; then
      echo "'{{signing_cert}}' already present in the System keychain."; exit 0
    fi
    tmp=$(mktemp -d)
    printf '%s\n' \
      '[ req ]' \
      'distinguished_name = dn' \
      'prompt             = no' \
      'x509_extensions    = v3' \
      '[ dn ]' \
      'CN = {{signing_cert}}' \
      '[ v3 ]' \
      'basicConstraints = critical,CA:false' \
      'keyUsage         = critical,digitalSignature' \
      'extendedKeyUsage = critical,codeSigning' \
      '1.2.840.113635.100.6.1.14 = critical,DER:0500' \
      > "$tmp/cert.conf"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/cert.conf"
    openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
      -name "{{signing_cert}}" -out "$tmp/id.p12" -passout pass:
    sudo security import "$tmp/id.p12" -k "{{sys_keychain}}" -P "" -T /usr/bin/codesign -A
    sudo security add-trusted-cert -d -r trustRoot -p codeSign -k "{{sys_keychain}}" "$tmp/cert.pem"
    rm -rf "$tmp"
    echo "'{{signing_cert}}' created and trusted. Re-run \`just install\`."

# --- debug logging (off by default; writes /tmp/xkeys.log) ---

# turn debug logging on (writes /tmp/xkeys.log)
debug-on:
    defaults write com.xieyt.xkeys debugLogging -bool true
    @echo "debug logging ON — restart the app (\`just restart\`), then \`just log\`"

# turn debug logging off
debug-off:
    defaults write com.xieyt.xkeys debugLogging -bool false
    @echo "debug logging OFF — restart the app to apply"

# tail the debug log (enable it first with debug-on)
log:
    @touch /tmp/xkeys.log
    tail -f /tmp/xkeys.log

# dump the debug log and the current debug flag
log-dump:
    @echo "debugLogging = $(defaults read com.xieyt.xkeys debugLogging 2>/dev/null || echo 0)"
    @cat /tmp/xkeys.log 2>/dev/null || echo "(no log yet)"

# wipe EVERY swap on the machine, including ones xkeys does not own. Last
# resort only — `xkeys --uninstall` removes just this app's entries.
fix-capslock:
    hidutil property --set '{"UserKeyMapping":[]}' >/dev/null
    @echo "All key swaps cleared. Run \`just restart\` to re-apply yours."
