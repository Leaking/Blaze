#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="blaze"
BUNDLE_ID="com.chenhuazhao.blaze"
TUNNEL_PRODUCT="BlazeTunnelExtension"
TUNNEL_BUNDLE_ID="com.chenhuazhao.blaze.tunnel"
VERSION="0.1.0"
BUILD_NUMBER="${BLAZE_BUILD_NUMBER:-1}"
BUILD_DIR="$ROOT_DIR/.build"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SYSTEM_EXTENSIONS_DIR="$CONTENTS_DIR/Library/SystemExtensions"
TUNNEL_EXTENSION_DIR="$SYSTEM_EXTENSIONS_DIR/$TUNNEL_BUNDLE_ID.systemextension"
TUNNEL_CONTENTS_DIR="$TUNNEL_EXTENSION_DIR/Contents"
TUNNEL_MACOS_DIR="$TUNNEL_CONTENTS_DIR/MacOS"
SIGN_IDENTITY="${BLAZE_SIGN_IDENTITY:-}"
ENABLE_SYSTEM_EXTENSION_ENTITLEMENTS="${BLAZE_ENABLE_SYSTEM_EXTENSION_ENTITLEMENTS:-0}"
APP_PROVISIONING_PROFILE="${BLAZE_APP_PROVISIONING_PROFILE:-}"
TUNNEL_PROVISIONING_PROFILE="${BLAZE_TUNNEL_PROVISIONING_PROFILE:-}"
APP_ENTITLEMENTS="$ROOT_DIR/Entitlements/Blaze.entitlements"
TUNNEL_ENTITLEMENTS="$ROOT_DIR/Entitlements/BlazeTunnelExtension.entitlements"
CURRENT_PROVISIONING_UDID="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Provisioning UDID/ {print $2; exit}')"
CURRENT_HARDWARE_UUID="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Hardware UUID/ {print $2; exit}')"

if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="-"
fi

find_signing_identity() {
    security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1
}

codesign_timestamp_args() {
    local identity="$1"

    if [[ "$identity" == Developer\ ID\ Application:* ]]; then
        printf '%s\n' "--timestamp"
    else
        printf '%s\n' "--timestamp=none"
    fi
}

profile_files() {
    find "$HOME/Library/MobileDevice/Provisioning Profiles" \
        "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
        -maxdepth 1 -type f \( -name '*.provisionprofile' -o -name '*.mobileprovision' \) -print 2>/dev/null
}

decode_profile() {
    local profile_path="$1"
    local output_path="$2"
    security cms -D -i "$profile_path" >"$output_path"
}

profile_value() {
    local profile_plist="$1"
    local key_path="$2"
    /usr/libexec/PlistBuddy -c "Print $key_path" "$profile_plist" 2>/dev/null || true
}

profile_has_entitlement() {
    local profile_plist="$1"
    local entitlement="$2"
    /usr/libexec/PlistBuddy -c "Print :Entitlements:$entitlement" "$profile_plist" >/dev/null 2>&1
}

profile_entitlement_contains() {
    local profile_plist="$1"
    local entitlement="$2"
    local expected_value="$3"
    local value

    value="$(profile_value "$profile_plist" ":Entitlements:$entitlement")"
    [[ "$value" == "$expected_value" || "$value" == *$'\n    '"$expected_value"$'\n'* ]]
}

profile_entitlement_contains_any() {
    local profile_plist="$1"
    local entitlement="$2"
    shift 2

    local expected_value
    for expected_value in "$@"; do
        if profile_entitlement_contains "$profile_plist" "$entitlement" "$expected_value"; then
            return 0
        fi
    done

    return 1
}

profile_contains_current_device() {
    local profile_plist="$1"
    local required_device_id
    local devices

    required_device_id="${CURRENT_PROVISIONING_UDID:-$CURRENT_HARDWARE_UUID}"
    [[ -z "$required_device_id" ]] && return 0

    if ! /usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$profile_plist" >/dev/null 2>&1; then
        return 0
    fi

    devices="$(profile_value "$profile_plist" ":ProvisionedDevices")"
    [[ "$devices" == *"$required_device_id"* ]]
}

select_profile() {
    local explicit_path="$1"
    local bundle_id="$2"
    local required_entitlement="$3"
    shift 3
    local required_entitlement_values=("$@")
    local temp_plist

    if [[ -n "$explicit_path" ]]; then
        if [[ ! -f "$explicit_path" ]]; then
            echo "Provisioning profile not found: $explicit_path" >&2
            return 1
        fi
        temp_plist="$(mktemp)"
        decode_profile "$explicit_path" "$temp_plist"
        if ! profile_has_entitlement "$temp_plist" "$required_entitlement"; then
            echo "Provisioning profile does not include $required_entitlement: $explicit_path" >&2
            rm -f "$temp_plist"
            return 1
        fi
        if [[ "${#required_entitlement_values[@]}" -gt 0 ]] && ! profile_entitlement_contains_any "$temp_plist" "$required_entitlement" "${required_entitlement_values[@]}"; then
            echo "Provisioning profile entitlement $required_entitlement does not include any of: ${required_entitlement_values[*]}: $explicit_path" >&2
            rm -f "$temp_plist"
            return 1
        fi
        if ! profile_contains_current_device "$temp_plist"; then
            echo "Provisioning profile is not provisioned for this Mac (${CURRENT_PROVISIONING_UDID:-$CURRENT_HARDWARE_UUID}): $explicit_path" >&2
            rm -f "$temp_plist"
            return 1
        fi
        rm -f "$temp_plist"
        echo "$explicit_path"
        return 0
    fi

    while IFS= read -r candidate; do
        [[ -f "$candidate" ]] || continue
        temp_plist="$(mktemp)"
        if ! decode_profile "$candidate" "$temp_plist" >/dev/null 2>&1; then
            rm -f "$temp_plist"
            continue
        fi

        local application_identifier
        application_identifier="$(profile_value "$temp_plist" ":Entitlements:application-identifier")"
        if [[ -z "$application_identifier" ]]; then
            application_identifier="$(profile_value "$temp_plist" ":Entitlements:com.apple.application-identifier")"
        fi
        if [[ "$application_identifier" == *."$bundle_id" ]] \
            && profile_has_entitlement "$temp_plist" "$required_entitlement" \
            && profile_contains_current_device "$temp_plist" \
            && { [[ "${#required_entitlement_values[@]}" -eq 0 ]] || profile_entitlement_contains_any "$temp_plist" "$required_entitlement" "${required_entitlement_values[@]}"; }; then
            rm -f "$temp_plist"
            echo "$candidate"
            return 0
        fi
        rm -f "$temp_plist"
    done < <(profile_files)

    if [[ "${#required_entitlement_values[@]}" -gt 0 ]]; then
        echo "No provisioning profile found for $bundle_id with $required_entitlement containing any of: ${required_entitlement_values[*]}." >&2
    else
        echo "No provisioning profile found for $bundle_id with $required_entitlement." >&2
    fi
    return 1
}

write_entitlements_from_profile() {
    local profile_path="$1"
    local output_path="$2"
    local temp_plist
    temp_plist="$(mktemp)"
    decode_profile "$profile_path" "$temp_plist"
    /usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$temp_plist" >"$output_path"
    rm -f "$temp_plist"
}

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

cd "$ROOT_DIR"
swift build -c release --arch arm64 --product "$APP_NAME"
swift build -c release --arch arm64 --product "$TUNNEL_PRODUCT"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$TUNNEL_MACOS_DIR"
cp "$BUILD_DIR/arm64-apple-macosx/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
cp "$BUILD_DIR/arm64-apple-macosx/release/$TUNNEL_PRODUCT" "$TUNNEL_MACOS_DIR/$TUNNEL_PRODUCT"
chmod +x "$TUNNEL_MACOS_DIR/$TUNNEL_PRODUCT"

/usr/libexec/PlistBuddy -c "Clear dict" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string blaze" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSSupportsAutomaticGraphicsSwitching bool true" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSSystemExtensionUsageDescription string blaze Packet Tunnel" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string com.chenhuazhao.blaze.control" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string blaze" "$CONTENTS_DIR/Info.plist"

/usr/libexec/PlistBuddy -c "Clear dict" "$TUNNEL_CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $TUNNEL_PRODUCT" "$TUNNEL_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string blaze Packet Tunnel" "$TUNNEL_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $TUNNEL_BUNDLE_ID" "$TUNNEL_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $TUNNEL_PRODUCT" "$TUNNEL_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string SYSX" "$TUNNEL_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$TUNNEL_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$TUNNEL_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$TUNNEL_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" "$TUNNEL_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" "$TUNNEL_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms:0 string MacOSX" "$TUNNEL_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$TUNNEL_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSSystemExtensionUsageDescription string blaze Packet Tunnel" "$TUNNEL_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NetworkExtension dict" "$TUNNEL_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NetworkExtension:NEProviderClasses dict" "$TUNNEL_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NetworkExtension:NEProviderClasses:com.apple.networkextension.packet-tunnel string BlazeTunnelExtension.PacketTunnelProvider" "$TUNNEL_CONTENTS_DIR/Info.plist"

if [[ "$ENABLE_SYSTEM_EXTENSION_ENTITLEMENTS" == "1" ]]; then
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        SIGN_IDENTITY="$(find_signing_identity)"
    fi
    if [[ -z "$SIGN_IDENTITY" ]]; then
        echo "No Apple Development signing identity found. Create one in Xcode > Settings > Accounts > Manage Certificates." >&2
        exit 1
    fi

    APP_PROVISIONING_PROFILE="$(select_profile "$APP_PROVISIONING_PROFILE" "$BUNDLE_ID" "com.apple.developer.system-extension.install")"
    TUNNEL_PROVISIONING_PROFILE="$(select_profile "$TUNNEL_PROVISIONING_PROFILE" "$TUNNEL_BUNDLE_ID" "com.apple.developer.networking.networkextension" "packet-tunnel-provider-systemextension")"
    cp "$APP_PROVISIONING_PROFILE" "$CONTENTS_DIR/embedded.provisionprofile"
    cp "$TUNNEL_PROVISIONING_PROFILE" "$TUNNEL_CONTENTS_DIR/embedded.provisionprofile"
    xattr -cr "$APP_DIR" 2>/dev/null || true

    GENERATED_ENTITLEMENTS_DIR="$BUILD_DIR/generated-entitlements"
    mkdir -p "$GENERATED_ENTITLEMENTS_DIR"
    GENERATED_APP_ENTITLEMENTS="$GENERATED_ENTITLEMENTS_DIR/Blaze.entitlements"
    GENERATED_TUNNEL_ENTITLEMENTS="$GENERATED_ENTITLEMENTS_DIR/BlazeTunnelExtension.entitlements"
    write_entitlements_from_profile "$APP_PROVISIONING_PROFILE" "$GENERATED_APP_ENTITLEMENTS"
    write_entitlements_from_profile "$TUNNEL_PROVISIONING_PROFILE" "$GENERATED_TUNNEL_ENTITLEMENTS"

    CODESIGN_TIMESTAMP_ARGS=()
    while IFS= read -r arg; do
        [[ -n "$arg" ]] && CODESIGN_TIMESTAMP_ARGS+=("$arg")
    done < <(codesign_timestamp_args "$SIGN_IDENTITY")

    codesign --force --options runtime "${CODESIGN_TIMESTAMP_ARGS[@]}" --sign "$SIGN_IDENTITY" --entitlements "$GENERATED_TUNNEL_ENTITLEMENTS" "$TUNNEL_EXTENSION_DIR" >/dev/null
    codesign --force --options runtime "${CODESIGN_TIMESTAMP_ARGS[@]}" --sign "$SIGN_IDENTITY" --entitlements "$GENERATED_APP_ENTITLEMENTS" "$APP_DIR" >/dev/null
else
    codesign --force --sign "$SIGN_IDENTITY" "$TUNNEL_EXTENSION_DIR" >/dev/null
    codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
    echo "Signed without restricted System Extension entitlements. Set BLAZE_ENABLE_SYSTEM_EXTENSION_ENTITLEMENTS=1 with a valid provisioning setup to test activation."
fi

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/$APP_NAME.app"
    rm -rf "/Applications/ProxyWorkbench.app"
    cp -R "$APP_DIR" "/Applications/$APP_NAME.app"
    xattr -cr "/Applications/$APP_NAME.app" 2>/dev/null || true
    echo "Installed /Applications/$APP_NAME.app"
else
    echo "Built $APP_DIR"
fi
