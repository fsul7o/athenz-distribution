#!/usr/bin/env bash
#
# issue-attestation.sh
#
# Verifies that the vegeta-contention Pod (running as the zts-contention
# ServiceAccount in the loadtest namespace) has a valid Kubernetes Service
# Account Token mounted at /var/run/secrets/zts-attestation/token.
#
# That SAT IS the attestation data — athenz-identityprovider's OPA policy
# validates it against the Kubernetes API JWKS at request time and extracts
# (namespace, serviceaccount) to derive (Athenz domain, service). The contention
# test never reads or rewrites the SAT outside the Pod, so this script does no
# token issuance — it only fails fast if the Pod is missing the mount.
#
# Earlier iterations of this script called `zts-svccert -get-instance-register-token`
# as user.athenz_admin against a fictitious sys.auth.zts provider. That path was
# wrong: sys.auth.zts is the ZTS server's own service identity, not an instance
# provider. The real attestation flows through athenz-identityprovider's OPA.
#
set -euo pipefail

LOADTEST_NAMESPACE="${LOADTEST_NAMESPACE:-loadtest}"
DEPLOYMENT="${DEPLOYMENT:-vegeta-contention}"

echo "==> Verifying SAT mount on ${LOADTEST_NAMESPACE}/${DEPLOYMENT}"

# Wait for the Pod to be Ready (deploy-contention rolls it).
kubectl -n "${LOADTEST_NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout=60s

TOKEN_BYTES=$(kubectl -n "${LOADTEST_NAMESPACE}" exec "deployment/${DEPLOYMENT}" -- \
    sh -c 'wc -c < /var/run/secrets/zts-attestation/token' 2>/dev/null \
    | tr -d '[:space:]')

if [ -z "${TOKEN_BYTES}" ] || [ "${TOKEN_BYTES}" -lt 100 ]; then
    echo "ERROR: SAT not mounted (or suspiciously short) in ${DEPLOYMENT}" >&2
    echo "       expected: /var/run/secrets/zts-attestation/token" >&2
    echo "       got: ${TOKEN_BYTES:-empty} bytes" >&2
    exit 1
fi

# Quick sanity: token must look like a JWT (header.payload.signature),
# i.e. exactly two '.' separators across the whole token. Reading only the
# first N bytes is unreliable — RS256 payloads alone can exceed 300 bytes,
# pushing the second separator past any fixed cutoff.
DOT_COUNT=$(kubectl -n "${LOADTEST_NAMESPACE}" exec "deployment/${DEPLOYMENT}" -- \
    sh -c "tr -cd '.' < /var/run/secrets/zts-attestation/token | wc -c" 2>/dev/null \
    | tr -d '[:space:]')

if [ "${DOT_COUNT}" != "2" ]; then
    echo "ERROR: SAT does not look like a JWT (expected 2 '.' separators, got ${DOT_COUNT:-0})" >&2
    exit 1
fi

echo "    SAT looks like a JWT (${TOKEN_BYTES} bytes, 2 '.' separators)"

echo "==> SAT mount OK — attestation will be read at attack time"
