#!/usr/bin/env bash
#
# build-vegeta-bodies.sh
#
# Assemble Vegeta HTTP-body TEMPLATES (one per CSR) and the Vegeta target file
# for the parallel POST /zts/v1/instance attack.
#
# Each body template contains:
#   * a distinct CSR (different keypair per request, so ZTS issues a brand-new
#     cert each time and never short-circuits on identical CSR hashing)
#   * the literal placeholder string @@SAT@@ where the Kubernetes Service
#     Account Token belongs. The token is *not* baked in here — it's read at
#     attack time from /var/run/secrets/kubernetes.io/serviceaccount/token
#     inside the vegeta Pod and substituted into /tmp/bodies/body-NNN.json by
#     the Make target's runtime sed loop.
#
# Why @@SAT@@ instead of writing the token in directly?
#   The SAT is bound to the Pod (and rotates on a TTL). Capturing it from the
#   host workstation and shipping into a ConfigMap would (a) leak credentials
#   off-cluster, (b) expire mid-test, and (c) require cross-namespace API access
#   to mint a token for the loadtest/zts-contention SA.
#
# Inputs (under IN_DIR):
#   csrs/csr-NNN.pem        from generate-csrs.sh
#
# Outputs (under OUT_DIR):
#   bodies/body-NNN.json    each contains @@SAT@@ placeholder
#   targets.txt             references /tmp/bodies/body-NNN.json
#
set -euo pipefail

IN_DIR="${IN_DIR:-$(pwd)/out}"
OUT_DIR="${OUT_DIR:-${IN_DIR}}"
ATHENZ_DOMAIN="${ATHENZ_DOMAIN:-loadtest}"
ATHENZ_SERVICE="${ATHENZ_SERVICE:-zts-contention}"
PROVIDER_SERVICE="${PROVIDER_SERVICE:-athenz.identityprovider}"
# Use the short DNS form (athenz-zts-server.athenz) — the ZTS server cert
# SAN only covers `localhost`, `athenz-zts-server`, `athenz-zts-server.athenz`,
# NOT the FQDN `*.svc.cluster.local`. Vegeta enforces TLS verification.
ZTS_INSTANCE_URL="${ZTS_INSTANCE_URL:-https://athenz-zts-server.athenz:4443/zts/v1/instance}"

CSR_DIR="${IN_DIR}/csrs"
BODY_DIR="${OUT_DIR}/bodies"
TARGETS_FILE="${OUT_DIR}/targets.txt"

if [ ! -d "${CSR_DIR}" ] || [ -z "$(ls -A "${CSR_DIR}" 2>/dev/null)" ]; then
    echo "ERROR: ${CSR_DIR} missing or empty — run generate-csrs.sh first" >&2
    exit 1
fi

mkdir -p "${BODY_DIR}"
: > "${TARGETS_FILE}"

# The Make target's runtime loop will rewrite @@SAT@@ → real token and store
# results under /tmp/bodies/ inside the vegeta Pod. Therefore the target file
# references that runtime path, not the ConfigMap mount.
POD_BODY_PREFIX="/tmp/bodies"

count=0
for csr in "${CSR_DIR}"/csr-*.pem; do
    idx="$(basename "${csr}" .pem | sed -e 's/^csr-//')"
    body="${BODY_DIR}/body-${idx}.json"

    # Embed the CSR as a JSON string (newlines -> literal \n, double-quotes escaped).
    csr_escaped="$(awk 'BEGIN{ORS="\\n"} {print}' "${csr}" | sed -e 's/"/\\"/g')"

    cat > "${body}" <<EOF
{
  "domain": "${ATHENZ_DOMAIN}",
  "service": "${ATHENZ_SERVICE}",
  "provider": "${PROVIDER_SERVICE}",
  "attestationData": "@@SAT@@",
  "csr": "${csr_escaped}",
  "token": false
}
EOF

    {
        echo "POST ${ZTS_INSTANCE_URL}"
        echo "Content-Type: application/json"
        echo "@${POD_BODY_PREFIX}/body-${idx}.json"
        echo
    } >> "${TARGETS_FILE}"

    count=$((count + 1))
done

echo "==> Wrote ${count} body templates (with @@SAT@@ placeholder) under ${BODY_DIR}/"
echo "==> Wrote Vegeta targets file: ${TARGETS_FILE}"
echo "==> Note: SAT will be substituted inside the vegeta Pod at attack time"
