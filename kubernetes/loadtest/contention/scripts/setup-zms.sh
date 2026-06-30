#!/usr/bin/env bash
#
# setup-zms.sh
#
# Register the loadtest domain / service / templates in ZMS so that
# vegeta can drive POST /zts/v1/instance against it.
#
# Provider choice: sys.auth.zts (the built-in ZTS-self-signed instance
# provider). It accepts an "instance register token" JWT signed by ZTS
# admin keys, so we do not need to deploy a separate identityprovider
# OPA stack for this contention test — the admin who runs setup is the
# attestation source.
#
# Idempotent: every step swallows already-exists errors with "||:".
#
# Runs *inside* the athenz-cli pod via kubectl exec. The caller (Make
# target) provides ATHENZ_DOMAIN / ATHENZ_SERVICE via env.
#
set -euo pipefail

ATHENZ_DOMAIN="${ATHENZ_DOMAIN:-loadtest}"
ATHENZ_SERVICE="${ATHENZ_SERVICE:-zts-contention}"
DNS_SUFFIX="${DNS_SUFFIX:-zts.athenz.cloud}"
PROVIDER_SERVICE="${PROVIDER_SERVICE:-athenz.identityprovider}"
NAMESPACE="${NAMESPACE:-athenz}"

ZMS_URL="https://athenz-zms-server.athenz:4443/zms/v1"
ADMIN_KEY="/var/run/athenz/athenz_admin.private.pem"
ADMIN_CRT="/var/run/athenz/athenz_admin.cert.pem"

# zms-cli wrapper (mounted at /usr/local/bin/zms-cli) auto-injects
# -key/-cert from ZMS_CLI_KEY_FILE/ZMS_CLI_CERT_FILE env vars.
ZMS_CLI="zms-cli -z ${ZMS_URL}"

echo "==> Creating domain: ${ATHENZ_DOMAIN}"
# Capture HTTP status + body so we can distinguish "already exists" from real
# failures. The previous version used curl -sf and swallowed all 4xx with
# `|| echo`, which then let downstream zms-cli calls fail mysteriously with 404
# when the domain truly didn't get created.
RESPONSE_FILE="$(mktemp)"
TMP_KEY=""
TMP_PUB=""
trap 'rm -f "${TMP_KEY}" "${TMP_PUB}" "${RESPONSE_FILE}"' EXIT

HTTP_STATUS=$(kubectl -n "${NAMESPACE}" exec deployment/athenz-cli -- \
    curl -s -o /tmp/.setup-zms-response.json -w "%{http_code}" \
        -d "{\"name\":\"${ATHENZ_DOMAIN}\",\"adminUsers\":[\"user.athenz_admin\"]}" \
        -H "Content-Type: application/json" \
        --key "${ADMIN_KEY}" \
        --cert "${ADMIN_CRT}" \
        "${ZMS_URL}/domain")

kubectl -n "${NAMESPACE}" exec deployment/athenz-cli -- \
    cat /tmp/.setup-zms-response.json > "${RESPONSE_FILE}" 2>/dev/null ||:

case "${HTTP_STATUS}" in
    2??)
        echo "    HTTP ${HTTP_STATUS}: domain created"
        ;;
    409)
        echo "    HTTP ${HTTP_STATUS}: domain already exists, continuing"
        ;;
    *)
        echo "    HTTP ${HTTP_STATUS}: domain creation failed" >&2
        echo "    Response body:" >&2
        cat "${RESPONSE_FILE}" >&2 || true
        echo >&2
        # Verify whether the domain happens to exist regardless (e.g. created
        # earlier with different params). If so, continue; if not, bail out
        # with the real error.
        echo "    Verifying whether domain ${ATHENZ_DOMAIN} exists in ZMS..." >&2
        if kubectl -n "${NAMESPACE}" exec deployment/athenz-cli -- \
            curl -sf \
                --key "${ADMIN_KEY}" --cert "${ADMIN_CRT}" \
                "${ZMS_URL}/domain/${ATHENZ_DOMAIN}" >/dev/null 2>&1
        then
            echo "    domain ${ATHENZ_DOMAIN} already present — continuing" >&2
        else
            echo "ERROR: domain ${ATHENZ_DOMAIN} does not exist and could not be created" >&2
            exit 1
        fi
        ;;
esac

# Service registration: a public key is required by add-service in ZMS, but
# the contention test never refreshes service tokens — only POSTs to
# /zts/v1/instance which validates the CSR signature, not this stored key.
# We register a 4096-bit RSA key the way kubernetes/athenz-identityprovider/
# does, since ZMS's putServiceIdentity validator has been observed to reject
# certain encodings (e.g. 2048-bit pkcs8 in this distribution).
#
# add-service is also tolerated to fail — set-domain-template
# identity_provisioning has been observed to lazily create the service
# entry with an empty publicKeys list, which is sufficient for the test.
echo "==> Generating throwaway service public key (4096-bit RSA)"
TMP_KEY="$(mktemp)"
TMP_PUB="$(mktemp)"
openssl genrsa -out "${TMP_KEY}" 4096 2>/dev/null
openssl rsa -in "${TMP_KEY}" -pubout -out "${TMP_PUB}" 2>/dev/null
# base64url encoding for Athenz: '+' -> '.', '=' -> '-', '/' -> '_'.
# We use sed because `tr '+=/' '.-_'` is buggy: the second argument is
# interpreted as a 50-char range (. through _), so '=' gets mapped to '/' and
# the encoded key becomes garbage that ZMS rejects with "public key is invalid".
PUB_KEY_ENCODED="$(base64 < "${TMP_PUB}" | tr -d '\r\n' \
    | sed -e 's/+/./g' -e 's/=/-/g' -e 's|/|_|g')"

echo "==> add-service ${ATHENZ_DOMAIN}.${ATHENZ_SERVICE} (tolerated)"
kubectl -n "${NAMESPACE}" exec deployment/athenz-cli -- \
    ${ZMS_CLI} -d "${ATHENZ_DOMAIN}" add-service "${ATHENZ_SERVICE}" 0 "${PUB_KEY_ENCODED}" \
    || echo "    (add-service failed; templates below will create the service implicitly)"

echo "==> set instance_registration template (instanceregisterer=user.athenz_admin)"
kubectl -n "${NAMESPACE}" exec deployment/athenz-cli -- \
    ${ZMS_CLI} -d "${ATHENZ_DOMAIN}" set-domain-template \
        instance_registration \
        instanceregisterer="user.athenz_admin" \
        service="${ATHENZ_SERVICE}"

echo "==> set identity_provisioning template (instanceprovider=${PROVIDER_SERVICE})"
kubectl -n "${NAMESPACE}" exec deployment/athenz-cli -- \
    ${ZMS_CLI} -d "${ATHENZ_DOMAIN}" set-domain-template \
        identity_provisioning \
        instanceprovider="${PROVIDER_SERVICE}" \
        service="${ATHENZ_SERVICE}"

echo "==> set instance_provider template on sys.auth (provider=${PROVIDER_SERVICE} dnssuffix=${DNS_SUFFIX})"
kubectl -n "${NAMESPACE}" exec deployment/athenz-cli -- \
    ${ZMS_CLI} -d sys.auth set-domain-template \
        instance_provider \
        provider="${PROVIDER_SERVICE}" \
        dnssuffix="${DNS_SUFFIX}" \
    ||:

echo "==> show-domain ${ATHENZ_DOMAIN}"
kubectl -n "${NAMESPACE}" exec deployment/athenz-cli -- \
    ${ZMS_CLI} -d "${ATHENZ_DOMAIN}" show-domain

echo "==> setup-zms complete"
