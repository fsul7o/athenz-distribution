#!/usr/bin/env bash
#
# generate-csrs.sh
#
# Pre-generate N (default: 100) Athenz-compatible service CSRs that all
# claim the SAME (domain, service, instanceId) so that concurrent
# POST /zts/v1/instance calls collide on the certificates PK
# (provider, instanceId, service) and reproduce the production 1062
# (Duplicate entry) error path inside
# JDBCCertRecordStoreConnection.insertX509CertRecord (L223-L262).
#
# Each CSR is signed by its own private key, but the Subject CN /
# SAN URI / SAN DNS are identical across all CSRs — the only thing
# that differs request-to-request is the keypair. That is sufficient
# to (a) get ZTS to issue a brand-new cert, and (b) hit the same PK
# row in the DB.
#
# Outputs are written under OUT_DIR/keys/ and OUT_DIR/csrs/.
#
# Usage:
#   COUNT=100 OUT_DIR=./out ./generate-csrs.sh
#
# Variables (with defaults pinned to the loadtest contention setup):
#   COUNT          number of CSRs to generate                  (100)
#   OUT_DIR        output directory                            ($PWD/out)
#   ATHENZ_DOMAIN  athenz domain                               (loadtest)
#   ATHENZ_SERVICE athenz service                              (zts-contention)
#   INSTANCE_ID    Athenz instanceId claimed in SAN URI        (loadtest.zts-contention.001)
#   DNS_SUFFIX     SAN DNS suffix (must match registered
#                  provider dnsSuffix in Athenz)               (zts.athenz.cloud)
#   KEY_BITS       RSA key size                                (2048)
#
set -euo pipefail

COUNT="${COUNT:-100}"
OUT_DIR="${OUT_DIR:-$(pwd)/out}"
ATHENZ_DOMAIN="${ATHENZ_DOMAIN:-loadtest}"
ATHENZ_SERVICE="${ATHENZ_SERVICE:-zts-contention}"
INSTANCE_ID="${INSTANCE_ID:-${ATHENZ_DOMAIN}.${ATHENZ_SERVICE}.001}"
DNS_SUFFIX="${DNS_SUFFIX:-zts.athenz.cloud}"
KEY_BITS="${KEY_BITS:-2048}"

mkdir -p "${OUT_DIR}/keys" "${OUT_DIR}/csrs"

CN="${ATHENZ_DOMAIN}.${ATHENZ_SERVICE}"
# SAN entries that ZTS expects for an Athenz service certificate:
#   - DNS:  <service>.<domain-with-dots-replaced-by-dashes>.<DNS_SUFFIX>
#   - DNS:  <instanceId>.instanceid.athenz.<DNS_SUFFIX>
#   - URI:  spiffe://<domain>/sa/<service>
SAN_DNS_SVC="${ATHENZ_SERVICE}.${ATHENZ_DOMAIN//./-}.${DNS_SUFFIX}"
SAN_DNS_INSTANCE="${INSTANCE_ID}.instanceid.athenz.${DNS_SUFFIX}"
SAN_URI="spiffe://${ATHENZ_DOMAIN}/sa/${ATHENZ_SERVICE}"

CONF_TEMPLATE="$(mktemp)"
trap 'rm -f "${CONF_TEMPLATE}"' EXIT

cat > "${CONF_TEMPLATE}" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions     = v3_req
prompt             = no

[req_distinguished_name]
CN = ${CN}

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${SAN_DNS_SVC}
DNS.2 = ${SAN_DNS_INSTANCE}
URI.1 = ${SAN_URI}
EOF

echo "Generating ${COUNT} CSRs for ${CN} (instanceId=${INSTANCE_ID})"
echo "  SAN DNS  : ${SAN_DNS_SVC}"
echo "  SAN DNS  : ${SAN_DNS_INSTANCE}"
echo "  SAN URI  : ${SAN_URI}"
echo "  out dir  : ${OUT_DIR}"

i=1
while [ "${i}" -le "${COUNT}" ]; do
    idx="$(printf '%03d' "${i}")"
    key="${OUT_DIR}/keys/key-${idx}.pem"
    csr="${OUT_DIR}/csrs/csr-${idx}.pem"

    openssl genrsa -out "${key}" "${KEY_BITS}" 2>/dev/null
    openssl req -new \
        -key "${key}" \
        -config "${CONF_TEMPLATE}" \
        -out "${csr}" 2>/dev/null

    i=$((i + 1))
done

echo "Generated ${COUNT} keys under ${OUT_DIR}/keys/"
echo "Generated ${COUNT} CSRs under ${OUT_DIR}/csrs/"
