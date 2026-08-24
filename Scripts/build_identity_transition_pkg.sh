#!/usr/bin/env bash
set -euo pipefail

# Builder/validator for the notarized Apple identity-transition package (T).
#
# Stable remains dormant. The Tip dress rehearsal is the only protected caller
# and must opt in explicitly for the transition role.

MODE="${1:-}"
if [[ $# -gt 0 ]]; then shift; fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUCCESSOR_BUNDLE_IDENTIFIER="com.repoprompt.ce"
SUCCESSOR_TEAM_IDENTIFIER="69N6K965SF"
SUCCESSOR_APP_REQUIREMENT='anchor apple generic and identifier "com.repoprompt.ce" and certificate leaf[subject.OU] = "69N6K965SF" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
TRANSITION_PKG_IDENTIFIER="com.repoprompt.ce.transition"
TRANSITION_INSTALL_LOCATION="/Applications"
DISTRIBUTION_APP_BUNDLE_NAME="RepoPrompt CE.app"
EXPECTED_FEED_URL="https://github.com/repoprompt/repoprompt-ce-updates/releases/latest/download/appcast.xml"
TMP_DIR=""

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_file() {
    [[ -f "$1" ]] || fail "Missing required file: $1"
}

cleanup() {
    [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

[[ "${REPOPROMPT_ENABLE_IDENTITY_TRANSITION_PKG:-}" == "1" ]] ||
    fail "identity transition package construction requires explicit Tip rollout enablement"

validate_successor_app() {
    local app="$1"
    local label="$2"
    [[ -d "$app" ]] || fail "$label app bundle does not exist: $app"
    codesign --verify --deep --strict --verbose=2 "$app"
    codesign --verify --strict --verbose=2 -R="$SUCCESSOR_APP_REQUIREMENT" "$app"

    local signature_details identifier team_identifier
    signature_details="$(codesign -dv --verbose=4 "$app" 2>&1)"
    identifier="$(printf '%s\n' "$signature_details" | awk -F= '$1 == "Identifier" { print $2; exit }')"
    team_identifier="$(printf '%s\n' "$signature_details" | awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
    printf '%s\n' "$signature_details" | grep -q '^Authority=Developer ID Application:' ||
        fail "$label app is not signed with a Developer ID Application certificate"
    [[ "$identifier" == "$SUCCESSOR_BUNDLE_IDENTIFIER" ]] ||
        fail "$label app identifier mismatch: expected $SUCCESSOR_BUNDLE_IDENTIFIER, got ${identifier:-<missing>}"
    [[ "$team_identifier" == "$SUCCESSOR_TEAM_IDENTIFIER" ]] ||
        fail "$label app team mismatch: expected $SUCCESSOR_TEAM_IDENTIFIER, got ${team_identifier:-<missing>}"

    local info_plist="$app/Contents/Info.plist"
    require_file "$info_plist"
    local bundle_identifier feed_url public_key
    bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$info_plist")"
    feed_url="$(plutil -extract SUFeedURL raw "$info_plist")"
    public_key="$(plutil -extract SUPublicEDKey raw "$info_plist")"
    [[ "$bundle_identifier" == "$SUCCESSOR_BUNDLE_IDENTIFIER" ]] ||
        fail "$label app CFBundleIdentifier mismatch: expected $SUCCESSOR_BUNDLE_IDENTIFIER, got $bundle_identifier"
    [[ "$feed_url" == "$EXPECTED_FEED_URL" ]] ||
        fail "$label app must keep the unchanged Stable feed URL, got $feed_url"
    [[ -n "$public_key" ]] || fail "$label app is missing SUPublicEDKey"
}

assert_component_flag() {
    local component_plist="$1"
    local key="$2"
    local expected="$3"
    local actual
    actual="$(plutil -extract "0.$key" raw "$component_plist")" ||
        fail "Component plist is missing $key"
    [[ "$actual" == "$expected" ]] ||
        fail "Component plist $key mismatch: expected $expected, got $actual"
}

build_transition_pkg() {
    local app="" output="" installer_identity=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app) app="$2"; shift 2 ;;
            --output) output="$2"; shift 2 ;;
            --installer-identity) installer_identity="$2"; shift 2 ;;
            *) fail "Unknown build argument: $1" ;;
        esac
    done
    [[ -n "$app" && -n "$output" && -n "$installer_identity" ]] ||
        fail "Usage: $0 build --app <successor.app> --output <transition.pkg> --installer-identity 'Developer ID Installer: ...'"
    [[ "$installer_identity" == "Developer ID Installer: "* ]] ||
        fail "Transition packages must be signed with a Developer ID Installer identity"
    require_command codesign
    require_command ditto
    require_command pkgbuild
    require_command plutil
    require_command productbuild
    require_command xcrun

    validate_successor_app "$app" "Transition payload input"

    TMP_DIR="$(mktemp -d)"
    local payload_root="$TMP_DIR/payload-root"
    mkdir -p "$payload_root"
    ditto "$app" "$payload_root/$DISTRIBUTION_APP_BUNDLE_NAME"

    local component_plist="$TMP_DIR/component.plist"
    pkgbuild --analyze --root "$payload_root" "$component_plist"
    plutil -replace 0.BundleIsRelocatable -bool false "$component_plist"
    plutil -replace 0.BundleHasStrictIdentifier -bool false "$component_plist"
    plutil -replace 0.BundleIsVersionChecked -bool false "$component_plist"
    plutil -replace 0.BundleOverwriteAction -string upgrade "$component_plist"
    assert_component_flag "$component_plist" BundleIsRelocatable false
    assert_component_flag "$component_plist" BundleHasStrictIdentifier false
    assert_component_flag "$component_plist" BundleIsVersionChecked false
    assert_component_flag "$component_plist" BundleOverwriteAction upgrade

    local payload_build
    payload_build="$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")"
    [[ "$payload_build" =~ ^[0-9]{1,4}(\.[0-9]{1,2}){0,2}$ ]] ||
        fail "Transition payload build number must be a valid CFBundleVersion, got $payload_build"

    local component_pkg="$TMP_DIR/transition-component.pkg"
    pkgbuild \
        --root "$payload_root" \
        --component-plist "$component_plist" \
        --identifier "$TRANSITION_PKG_IDENTIFIER" \
        --version "$payload_build" \
        --install-location "$TRANSITION_INSTALL_LOCATION" \
        --sign "$installer_identity" \
        "$component_pkg"
    productbuild \
        --package "$component_pkg" \
        --sign "$installer_identity" \
        "$output"

    require_env_for_notarization
    xcrun notarytool submit "$output" \
        --key "$NOTARYTOOL_PRIVATE_KEY" \
        --key-id "$NOTARYTOOL_KEY_ID" \
        --issuer "$NOTARYTOOL_ISSUER_ID" \
        --wait \
        --timeout "${NOTARYTOOL_TIMEOUT:-30m}"
    xcrun stapler staple "$output"
    validate_transition_pkg "$output" --expected-app "$app"
    printf 'Created identity-transition package: %s\n' "$output"
}

require_env_for_notarization() {
    [[ -n "${NOTARYTOOL_PRIVATE_KEY:-}" && -n "${NOTARYTOOL_KEY_ID:-}" && -n "${NOTARYTOOL_ISSUER_ID:-}" ]] ||
        fail "Transition package notarization requires NOTARYTOOL_PRIVATE_KEY, NOTARYTOOL_KEY_ID, and NOTARYTOOL_ISSUER_ID"
    require_file "$NOTARYTOOL_PRIVATE_KEY"
}

validate_transition_pkg() {
    local pkg="$1"
    shift
    local expanded_payload_dir="" expected_app=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --expanded-payload-dir) expanded_payload_dir="$2"; shift 2 ;;
            --expected-app) expected_app="$2"; shift 2 ;;
            *) fail "Unknown validate argument: $1" ;;
        esac
    done
    require_command codesign
    require_command pkgutil
    require_command plutil
    require_command xcrun
    require_file "$pkg"

    local signature_details
    signature_details="$(pkgutil --check-signature "$pkg")"
    printf '%s\n' "$signature_details" | grep -q 'Developer ID Installer:' ||
        fail "Transition package is not signed with a Developer ID Installer certificate"
    printf '%s\n' "$signature_details" | grep -q "($SUCCESSOR_TEAM_IDENTIFIER)" ||
        fail "Transition package installer team mismatch: expected $SUCCESSOR_TEAM_IDENTIFIER"

    xcrun stapler validate "$pkg"

    [[ -n "$TMP_DIR" ]] || TMP_DIR="$(mktemp -d)"
    local expand_dir="$TMP_DIR/transition-expand"
    rm -rf "$expand_dir"
    pkgutil --expand-full "$pkg" "$expand_dir"

    local package_info
    package_info="$(find "$expand_dir" -maxdepth 2 -name PackageInfo -type f | head -n 1)"
    [[ -n "$package_info" ]] || fail "Transition package is missing PackageInfo"
    grep -q "install-location=\"$TRANSITION_INSTALL_LOCATION\"" "$package_info" ||
        fail "Transition package must install into $TRANSITION_INSTALL_LOCATION"
    grep -q "identifier=\"$TRANSITION_PKG_IDENTIFIER\"" "$package_info" ||
        fail "Transition package identifier mismatch: expected $TRANSITION_PKG_IDENTIFIER"
    ! grep -q '<relocate' "$package_info" ||
        fail "Transition package must not contain bundle relocation rules"

    local payload_app
    payload_app="$(find "$expand_dir" -maxdepth 3 -type d -name "$DISTRIBUTION_APP_BUNDLE_NAME" | head -n 1)"
    [[ -n "$payload_app" ]] || fail "Transition package payload is missing $DISTRIBUTION_APP_BUNDLE_NAME"
    validate_successor_app "$payload_app" "Transition payload"

    if [[ -n "$expected_app" ]]; then
        # Exact byte/tree proof: the extracted payload must be identical to the
        # signed input app, file for file.
        diff -qr "$expected_app" "$payload_app" ||
            fail "Transition package payload does not byte-match the signed input app"
    fi

    if [[ -n "$expanded_payload_dir" ]]; then
        mkdir -p "$expanded_payload_dir"
        ditto "$payload_app" "$expanded_payload_dir/$DISTRIBUTION_APP_BUNDLE_NAME"
    fi
    printf 'OK: transition package validated: %s\n' "$pkg"
}

case "$MODE" in
    build)
        build_transition_pkg "$@"
        ;;
    validate)
        [[ $# -ge 1 ]] || fail "Usage: $0 validate <transition.pkg> [--expected-app <app>] [--expanded-payload-dir <dir>]"
        pkg_path="$1"
        shift
        validate_transition_pkg "$pkg_path" "$@"
        ;;
    *)
        fail "Usage: $0 build|validate ..."
        ;;
esac
