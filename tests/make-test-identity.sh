#!/bin/sh
# Create a throwaway "files" identity (self-signed cert + CMS-signed profile)
# for exercising the sign pipeline without an Apple account. Devices will
# reject apps signed with it; it only proves signing end to end.
#
#   tests/make-test-identity.sh OUTDIR [BUNDLE_PATTERN] [UDID]
set -eu
out=${1:?usage: make-test-identity.sh OUTDIR [BUNDLE_PATTERN] [UDID]}
pattern=${2:-*}
udid=${3:-00008130-000000000000001E}
team=FTEST12345
mkdir -p "$out"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A throwaway CA stands in for Apple's WWDR intermediate; zsign needs the
# issuer, and accepts it from the p12's chain.
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=Ferry Test CA" \
  -keyout "$tmp/ca.key" -out "$tmp/ca.pem" 2>/dev/null
openssl req -newkey rsa:2048 -nodes \
  -subj "/CN=Apple Development: Ferry Test ($team)/OU=$team/O=Ferry Test/C=US" \
  -keyout "$tmp/key.pem" -out "$tmp/leaf.csr" 2>/dev/null
openssl x509 -req -in "$tmp/leaf.csr" -CA "$tmp/ca.pem" -CAkey "$tmp/ca.key" -CAcreateserial \
  -days 30 -out "$tmp/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -certfile "$tmp/ca.pem" \
  -passout pass:test -out "$out/identity.p12"
printf test > "$out/password"
cert_b64=$(openssl x509 -in "$tmp/cert.pem" -outform DER | base64 -w0)
expires=$(date -u -d '+30 days' +%Y-%m-%dT%H:%M:%SZ)

cat > "$tmp/profile.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AppIDName</key><string>Ferry Test</string>
  <key>Name</key><string>Ferry Test Profile</string>
  <key>TeamIdentifier</key><array><string>$team</string></array>
  <key>TeamName</key><string>Ferry Test</string>
  <key>ExpirationDate</key><date>$expires</date>
  <key>DeveloperCertificates</key><array><data>$cert_b64</data></array>
  <key>ProvisionedDevices</key><array><string>$udid</string></array>
  <key>Entitlements</key>
  <dict>
    <key>application-identifier</key><string>$team.$pattern</string>
    <key>com.apple.developer.team-identifier</key><string>$team</string>
    <key>get-task-allow</key><true/>
    <key>keychain-access-groups</key><array><string>$team.*</string></array>
  </dict>
</dict>
</plist>
EOF
openssl cms -sign -nodetach -binary -outform DER -in "$tmp/profile.plist" \
  -signer "$tmp/cert.pem" -inkey "$tmp/key.pem" -out "$out/test.mobileprovision"
echo "test identity in $out (team $team, app id $team.$pattern, device $udid)"
