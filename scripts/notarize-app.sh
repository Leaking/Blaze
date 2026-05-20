#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/build/blaze.app}"
NOTARY_PROFILE="${BLAZE_NOTARY_PROFILE:-blaze-notary}"
ZIP_PATH="${BLAZE_NOTARY_ZIP:-$ROOT_DIR/build/blaze-notary.zip}"
MAX_WAIT_SECONDS="${BLAZE_NOTARY_MAX_WAIT_SECONDS:-600}"
POLL_INTERVAL_SECONDS="${BLAZE_NOTARY_POLL_INTERVAL_SECONDS:-30}"
MAX_ATTEMPTS="${BLAZE_NOTARY_MAX_ATTEMPTS:-3}"

json_value() {
    local key="$1"
    /usr/bin/plutil -extract "$key" raw -o - - 2>/dev/null || true
}

staple_and_assess() {
    xcrun stapler staple "$APP_PATH"
    spctl --assess --type execute --verbose=4 "$APP_PATH"
}

if [[ ! -d "$APP_PATH" ]]; then
    echo "App bundle not found: $APP_PATH" >&2
    exit 1
fi

mkdir -p "$(dirname "$ZIP_PATH")"
rm -f "$ZIP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

accepted_submission_id=""
for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    echo "Submitting notarization attempt $attempt/$MAX_ATTEMPTS"
    if ! submit_json="$(xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --output-format json 2>&1)"; then
        echo "$submit_json" >&2
        exit 1
    fi
    submission_id="$(printf '%s' "$submit_json" | json_value id)"
    if [[ -z "$submission_id" ]]; then
        echo "$submit_json" >&2
        echo "Could not parse notarization submission id" >&2
        exit 1
    fi
    echo "Notarization submission id: $submission_id"

    elapsed=0
    while ((elapsed < MAX_WAIT_SECONDS)); do
        sleep "$POLL_INTERVAL_SECONDS"
        elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
        if ! info_json="$(xcrun notarytool info "$submission_id" --keychain-profile "$NOTARY_PROFILE" --output-format json 2>&1)"; then
            echo "notarytool info failed after ${elapsed}s; trying stapler ticket lookup." >&2
            echo "$info_json" >&2
            if staple_and_assess; then
                accepted_submission_id="$submission_id"
                break 2
            fi
            continue
        fi
        status="$(printf '%s' "$info_json" | json_value status)"
        echo "Notarization status after ${elapsed}s: ${status:-unknown}"

        case "$status" in
            Accepted)
                accepted_submission_id="$submission_id"
                break 2
                ;;
            Invalid|Rejected)
                echo "$info_json" >&2
                xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
                exit 1
                ;;
        esac
    done

    echo "Notarization submission $submission_id did not finish within ${MAX_WAIT_SECONDS}s; resubmitting."
done

if [[ -z "$accepted_submission_id" ]]; then
    echo "Notarization did not finish after $MAX_ATTEMPTS attempt(s)." >&2
    exit 1
fi

echo "Notarization accepted: $accepted_submission_id"
staple_and_assess
