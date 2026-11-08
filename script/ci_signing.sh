#!/usr/bin/env bash
# Import release-only credentials into an ephemeral hosted-runner keychain.
set -euo pipefail
: "${RUNNER_TEMP:?GitHub-hosted runner required}"
KEYCHAIN="$RUNNER_TEMP/bipara-release.keychain-db"
P12="$RUNNER_TEMP/bipara-release.p12"
P8="$RUNNER_TEMP/bipara-notary.p8"
if [ "${1:-}" = cleanup ]; then
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -f "$P12" "$P8"
  exit 0
fi
[ "${1:-}" = install ] || { echo 'usage: ci_signing.sh install|cleanup' >&2; exit 1; }
: "${BIPARA_CERTIFICATE_P12_BASE64:?missing signing certificate}"
: "${BIPARA_CERTIFICATE_PASSWORD:?missing certificate password}"
: "${BIPARA_KEYCHAIN_PASSWORD:?missing ephemeral keychain password}"
: "${BIPARA_NOTARY_KEY_P8:?missing notarization key}"
: "${BIPARA_NOTARY_KEY_ID:?missing notarization key ID}"
: "${BIPARA_NOTARY_ISSUER_ID:?missing notarization issuer ID}"
: "${BIPARA_NOTARY_PROFILE:?missing profile name}"
export BIPARA_TEMP_P12="$P12" BIPARA_TEMP_P8="$P8"
python3 - <<'PY'
import base64, os
from pathlib import Path
for name, body in [('BIPARA_TEMP_P12', base64.b64decode(os.environ['BIPARA_CERTIFICATE_P12_BASE64'], validate=True)),
                   ('BIPARA_TEMP_P8', os.environ['BIPARA_NOTARY_KEY_P8'].encode())]:
    path = Path(os.environ[name])
    with path.open('xb') as stream:
        os.chmod(path, 0o600)
        stream.write(body)
PY
security create-keychain -p "$BIPARA_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1
security set-keychain-settings -lut 21600 "$KEYCHAIN" >/dev/null 2>&1
security unlock-keychain -p "$BIPARA_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1
security import "$P12" -P "$BIPARA_CERTIFICATE_PASSWORD" -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$BIPARA_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1
security list-keychains -d user -s "$KEYCHAIN" >/dev/null 2>&1
xcrun notarytool store-credentials "$BIPARA_NOTARY_PROFILE" --key "$P8" \
  --key-id "$BIPARA_NOTARY_KEY_ID" --issuer "$BIPARA_NOTARY_ISSUER_ID" --keychain "$KEYCHAIN" >/dev/null 2>&1
echo 'ci_signing: ephemeral signing and notarization access configured'
