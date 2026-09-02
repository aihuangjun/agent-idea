#!/usr/bin/env bash
# 造一个本机自签的代码签名证书，让 Agent IDEA 有个稳定身份。
#
# adhoc 签名的应用没有身份，系统只能拿二进制的 cdhash 认它，而 cdhash 每次构建都变；
# 证书签名之后系统记的是「证书 + bundle id」，重新构建照样对得上。
# 这个证书只在这台机器上有效，不是 Apple 签发的，不能用于对外分发（那需要 Developer ID）。
# 不想要了就在「钥匙串访问」里搜 AgentIDEA Local 删掉，再跑 build_app.sh 会退回 adhoc。
set -euo pipefail

NAME="AgentIDEA Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "==> 已经有「${NAME}」了，不用重复创建"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 生成自签证书「${NAME}」"
# extendedKeyUsage=codeSigning 是关键：少了它 codesign 不认这张证书。
openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# 三个算法参数不能省：OpenSSL 3 默认的 AES-256-CBC + SHA-256 打包苹果的 Security 框架不认，
# `security import` 会报一句误导性的「MAC verification failed（wrong password?)」。
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -out "$WORK/identity.p12" -passout pass:agentidea 2>/dev/null

echo "==> 导入登录钥匙串"
# -A：允许所有程序用这把私钥，换来 codesign 每次都不弹「允许访问钥匙串」的框。
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P agentidea -A >/dev/null

echo "==> 把它标成受信任（这一步系统会弹框要你的登录密码）"
security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$WORK/cert.pem"

echo
security find-identity -v -p codesigning | grep "$NAME" || {
  echo "!! 证书建好了但 codesign 还不认它，多半是信任那一步没通过" >&2
  exit 1
}
echo
echo "==> 好了。接下来跑 scripts/build_app.sh 重新构建（会自动用这张证书签名）"
