#!/bin/zsh
# Integration checks for JamfToolboxCore against local mock Jamf Pro servers.
#
#   ReportChecks       every audit report, against mock_jamf.py (port 18446)
#   ScopeChangeChecks  Exclude / Remove Target / Remove Exclusion, against the
#                      stateful scope XML mock, mock_scope_xml.py (port 18448)
#
# Run from anywhere:  Packages/JamfToolboxCore/IntegrationTests/run.sh
# Needs python3 and openssl. Nothing here talks to a real Jamf Pro server.
set -u
here=${0:A:h}
sources=$here/../Sources/JamfToolboxCore
work=$(mktemp -d)
trap 'kill $jamf_pid $xml_pid 2>/dev/null; rm -rf $work' EXIT

# A throwaway certificate for localhost (Apple's TLS rules: at most 825 days, serverAuth).
openssl req -x509 -newkey rsa:2048 -nodes -keyout $work/key.pem -out $work/cert.pem -days 365 \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "extendedKeyUsage=serverAuth" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign" 2>/dev/null

python3 $here/mock_jamf.py $work > $work/mock_jamf.log 2>&1 & jamf_pid=$!
python3 $here/mock_scope_xml.py $work > $work/mock_scope_xml.log 2>&1 & xml_pid=$!
sleep 1.5

failed=0
for check in ReportChecks ScopeChangeChecks; do
  echo "== $check"
  if ! swiftc -parse-as-library -o $work/$check $sources/*.swift $here/$check.swift; then failed=1; continue; fi
  $work/$check $work || failed=1
done
exit $failed
