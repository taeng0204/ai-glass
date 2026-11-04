#!/bin/bash
# 로컬 코드 서명용 자체 인증서 "AIGlass Local"을 로그인 키체인에 만든다 (1회).
#
# 왜: ad-hoc 서명은 빌드마다 앱 지문이 바뀌어, Claude Code 인증정보(Keychain) 접근 "항상 허용"이
#     재빌드 때마다 초기화된다. 고정 인증서로 서명하면 앱 신원(designated requirement)이 유지된다.
# 신뢰 등록은 필요 없다 (codesign은 미신뢰 자체 서명 신원으로도 서명한다).
# 이미 있으면 아무것도 하지 않는다. 인증서를 새로 만들면 지문이 바뀌므로 허용을 한 번 다시 눌러야 한다.
set -euo pipefail

NAME="${AIGLASS_SIGN_ID:-AIGlass Local}"
KC="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "\"${NAME}\""; then
    echo "이미 있음: ${NAME}"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > ext.cnf <<EOF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=${NAME}
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config ext.cnf 2>/dev/null
PW="$(openssl rand -hex 8)"
# macOS가 읽을 수 있도록 옛 PKCS12 형식(3DES/SHA1)으로 내보낸다 (openssl 3 기본 형식은 import 실패).
openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -name "${NAME}" -passout "pass:${PW}" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import id.p12 -k "$KC" -P "$PW" -T /usr/bin/codesign
echo "완료: ${NAME}"
