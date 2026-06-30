# identityprovider.rego (TEST-ONLY STUB for the contention loadtest)
#
# This stub REPLACES the production identityprovider rego that performs
# strict JWT + Kubernetes pod metadata + SAN attestation. The stub always
# returns a successful InstanceConfirmation regardless of input, letting
# ZTS reach JDBCCertRecordStoreConnection.insertX509CertRecord so the
# contention test can measure PK collisions (1062) end-to-end.
#
# Production response shape (success):
#   { "domain", "service", "provider", "attributes": {...} }
# Production response shape (failure):
#   { "allow": false, "status": { "reason": "..." } }
#
# When the contention test is done, restore the real policy by re-running:
#   make deploy-kubernetes-athenz-identityprovider
#
# WARNING: while this stub is in place, ANY workload (not just the
# loadtest one) can request a service certificate for ANY domain via
# athenz.identityprovider. Use only in throw-away dev/kind clusters.

package identityprovider

instance := response
refresh := response

response := {
    "domain": input.domain,
    "service": input.service,
    "provider": input.provider,
    "attributes": {
        "instanceId": object.get(input.attributes, "instanceId", ""),
        "sanIP": object.get(input.attributes, "sanIP", ""),
        "clientIP": object.get(input.attributes, "clientIP", ""),
        "sanURI": object.get(input.attributes, "sanURI", ""),
        "sanDNS": object.get(input.attributes, "sanDNS", ""),
        "certExpiryTime": 43200,
        "certRefresh": true,
    },
}
