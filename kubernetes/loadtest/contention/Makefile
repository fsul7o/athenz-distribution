# Makefile for the ZTS register-contention loadtest.
#
# Goal: reproduce the production 1062 (Duplicate entry) errors fired
# from JDBCCertRecordStoreConnection.insertX509CertRecord by issuing
# concurrent POST /zts/v1/instance requests that all claim the same
# (provider, instanceId, service) triple.
#
# Architecture:
#   * vegeta-contention Deployment lives in the `loadtest` k8s namespace
#     running as ServiceAccount `zts-contention`. Its mounted SAT
#     (/var/run/secrets/kubernetes.io/serviceaccount/token) IS the
#     attestation data the athenz-identityprovider OPA validates.
#   * athenz-db (in `athenz` ns) has the server_audit plugin loaded by
#     the BASE athenz-db kustomization, so every QUERY's return errno is
#     written to /tmp/server_audit.log and 1062 lines can be counted.
#   * Bodies are pre-generated as templates with @@SAT@@ placeholder;
#     the SAT is substituted into /tmp/bodies/ inside the Pod at attack
#     time so credentials never leave the cluster.
#
# Typical sequence (run from repository root, see README):
#   make deploy-kubernetes-athenz-zts-contention
#   make prepare-kubernetes-athenz-zts-contention
#   make sanity-kubernetes-athenz-zts-contention
#   make snapshot-kubernetes-athenz-zts-contention-errors
#   make test-kubernetes-athenz-zts-contention
#   make snapshot-kubernetes-athenz-zts-contention-errors
#   make report-kubernetes-athenz-zts-contention
#
# All shell-out variables are exposed for override.

# Namespace where the base Athenz stack lives.
NAMESPACE          ?= athenz
# Namespace dedicated to the contention test (matches Athenz domain `loadtest`).
LOADTEST_NAMESPACE ?= loadtest
# Vegeta deployment in the loadtest namespace.
VEGETA_DEPLOYMENT  ?= vegeta-contention

ATHENZ_DOMAIN      ?= loadtest
ATHENZ_SERVICE     ?= zts-contention
# instanceId is not used by athenz-identityprovider (OPA derives it from the
# SAT's POD_UID claim), but ZMS template setup still references service name.
INSTANCE_ID        ?= $(ATHENZ_DOMAIN).$(ATHENZ_SERVICE).001
PROVIDER_SERVICE   ?= athenz.identityprovider
DNS_SUFFIX         ?= zts.athenz.cloud
COUNT              ?= 100

# Sanity check parameters: small enough to be cheap, large enough that
# at least one PK collision is statistically guaranteed.
SANITY_WORKERS     ?= 10
SANITY_RATE        ?= 20
SANITY_DURATION    ?= 5s

# Full attack parameters: match the existing loadtest profile in
# kubernetes/loadtest/Makefile so timing/latency numbers are comparable.
ATTACK_WORKERS     ?= 100
ATTACK_RATE        ?= 100
ATTACK_DURATION    ?= 30s

OUT_DIR            ?= $(CURDIR)/out

SCRIPT_ENV = \
    NAMESPACE=$(NAMESPACE) \
    LOADTEST_NAMESPACE=$(LOADTEST_NAMESPACE) \
    DEPLOYMENT=$(VEGETA_DEPLOYMENT) \
    ATHENZ_DOMAIN=$(ATHENZ_DOMAIN) \
    ATHENZ_SERVICE=$(ATHENZ_SERVICE) \
    INSTANCE_ID=$(INSTANCE_ID) \
    PROVIDER_SERVICE=$(PROVIDER_SERVICE) \
    DNS_SUFFIX=$(DNS_SUFFIX) \
    COUNT=$(COUNT) \
    OUT_DIR=$(OUT_DIR) \
    IN_DIR=$(OUT_DIR)

.PHONY: help deploy-contention clean-contention setup-zms generate-csrs \
        verify-attestation build-bodies create-configmaps prepare-contention \
        sanity-contention run-contention report-contention \
        snapshot-mysql-errors reset-contention reset-certificates-table \
        replicate-cacert

help:
	@echo "ZTS register contention loadtest targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-28s %s\n",$$1,$$2}'

# ---------------------------------------------------------------------------
# Deploy / undeploy
# ---------------------------------------------------------------------------

replicate-cacert: ## copy athenz-cacert secret from athenz ns into loadtest ns (must run AFTER namespace exists)
	@echo "==> Replicating athenz-cacert into ${LOADTEST_NAMESPACE} namespace"
	kubectl -n $(NAMESPACE) get secret athenz-cacert -o yaml \
		| sed -e "s/namespace: $(NAMESPACE)/namespace: $(LOADTEST_NAMESPACE)/" \
		| sed -e '/resourceVersion:/d' \
		| sed -e '/uid:/d' \
		| sed -e '/creationTimestamp:/d' \
		| kubectl apply -f -

deploy-contention: ## apply contention resources (namespace, SA, vegeta) + verify athenz-db server_audit is ACTIVE
	@# Order matters: kustomize must apply FIRST so the loadtest Namespace
	@# exists before we replicate the cacert Secret into it. The vegeta-
	@# contention Deployment will fail to start (Secret missing) until that
	@# replication happens, so we apply, then replicate, then wait.
	@echo "==> Applying contention kustomize (namespace, SA, vegeta)"
	kubectl apply -k kustomize
	@$(MAKE) replicate-cacert
	@echo "==> Verifying athenz-db has server_audit plugin loaded"
	@AUDIT=$$(kubectl -n $(NAMESPACE) exec statefulset/athenz-db -- \
		mariadb -uroot -N -e "SELECT plugin_status FROM information_schema.plugins WHERE plugin_name='SERVER_AUDIT'" 2>/dev/null); \
	if [ "$$AUDIT" != "ACTIVE" ]; then \
		echo ""; \
		echo "ERROR: athenz-db server_audit plugin is not ACTIVE (got '$$AUDIT')."; \
		echo ""; \
		echo "This means athenz-db was deployed before kubernetes/athenz-db/kustomize"; \
		echo "included the audit-configmap.yaml resource. server_audit must be loaded"; \
		echo "at server start (plugin-load-add in cnf); SET GLOBAL alone is not enough."; \
		echo ""; \
		echo "To fix, you must redeploy athenz-db. WARNING: athenz-db uses emptyDir,"; \
		echo "so this destroys all ZMS data (sys.auth, registered services, etc.)."; \
		echo "The full chain has to be re-run from kind cluster bring-up:"; \
		echo ""; \
		echo "  make kind-shutdown    # in kubernetes/Makefile"; \
		echo "  make deploy-kubernetes-in-docker"; \
		echo "  make load-kubernetes-images"; \
		echo "  make deploy-kubernetes-athenz"; \
		echo "  make check-kubernetes-athenz"; \
		echo "  make deploy-kubernetes-athenz-identityprovider"; \
		echo "  make deploy-kubernetes-athenz-loadtest"; \
		echo "  make deploy-kubernetes-athenz-zts-contention"; \
		echo ""; \
		exit 1; \
	fi
	@echo "    server_audit=ACTIVE"
	@echo "==> Waiting for vegeta-contention Pod"
	kubectl -n $(LOADTEST_NAMESPACE) rollout status deployment/$(VEGETA_DEPLOYMENT) --timeout=120s

clean-contention: ## remove contention resources (namespace, SA, vegeta)
	kubectl delete -k kustomize ||:
	kubectl -n $(LOADTEST_NAMESPACE) delete configmap vegeta-contention-bodies ||:
	kubectl -n $(LOADTEST_NAMESPACE) delete configmap vegeta-contention-targets ||:

# ---------------------------------------------------------------------------
# Preparation pipeline (idempotent)
# ---------------------------------------------------------------------------

setup-zms: ## create loadtest domain/service/templates in ZMS
	$(SCRIPT_ENV) ./scripts/setup-zms.sh

generate-csrs: ## generate $(COUNT) CSRs that all claim the same instanceId
	$(SCRIPT_ENV) ./scripts/generate-csrs.sh

verify-attestation: ## verify the vegeta Pod has a valid SAT mounted
	$(SCRIPT_ENV) ./scripts/issue-attestation.sh

build-bodies: ## build vegeta body templates + targets file
	$(SCRIPT_ENV) ./scripts/build-vegeta-bodies.sh

create-configmaps: ## create/update the bodies+targets ConfigMaps in-cluster
	kubectl -n $(LOADTEST_NAMESPACE) create configmap vegeta-contention-bodies \
		--from-file=$(OUT_DIR)/bodies/ --dry-run=client -o yaml \
		| kubectl apply -f -
	kubectl -n $(LOADTEST_NAMESPACE) create configmap vegeta-contention-targets \
		--from-file=targets.txt=$(OUT_DIR)/targets.txt --dry-run=client -o yaml \
		| kubectl apply -f -
	@# Roll vegeta so the new ConfigMaps are picked up on the next mount.
	kubectl -n $(LOADTEST_NAMESPACE) rollout restart deployment/$(VEGETA_DEPLOYMENT)
	kubectl -n $(LOADTEST_NAMESPACE) rollout status deployment/$(VEGETA_DEPLOYMENT) --timeout=60s

patch-opa-allow-all: ## TEST-ONLY: replace identityprovider OPA rego with a stub that always allows
	@echo "==> Patching identityprovider-policy ConfigMap with stub rego (TEST ONLY)"
	@# json-encode the stub file (escape quotes/newlines), then JSON-merge-patch the
	@# configmap so only identityprovider.rego is replaced; config.yaml /
	@# system.*.rego remain intact. Restore by re-running:
	@#   make deploy-kubernetes-athenz-identityprovider
	@REGO_JSON=$$(python3 -c 'import json,sys; print(json.dumps(open("scripts/opa-stub.rego").read()))'); \
	kubectl -n $(NAMESPACE) patch configmap identityprovider-policy \
		--type=merge \
		-p "{\"data\":{\"identityprovider.rego\":$$REGO_JSON}}"
	@echo "==> Restarting identityprovider-deployment to pick up new policy"
	kubectl -n $(NAMESPACE) rollout restart deployment/identityprovider-deployment
	kubectl -n $(NAMESPACE) rollout status deployment/identityprovider-deployment --timeout=120s

restore-opa-policy: ## restore original identityprovider policy (delegates to setup)
	@echo "==> To restore the original OPA policy, run from repository root:"
	@echo "       make deploy-kubernetes-athenz-identityprovider"
	@echo "    (this re-applies the production policy ConfigMap and restarts the Pod)"

prepare-contention: setup-zms patch-opa-allow-all generate-csrs verify-attestation build-bodies create-configmaps ## full prep pipeline (incl. OPA stub patch)

# ---------------------------------------------------------------------------
# Sanity check & main attack
# ---------------------------------------------------------------------------

# Shell snippet that runs inside the vegeta Pod: read SAT, substitute into
# all body templates, then run `vegeta attack`. Defined once and reused by
# sanity-contention / run-contention so the SAT-handling stays consistent.
define VEGETA_ATTACK
set -e; \
SAT=$$(cat /var/run/secrets/zts-attestation/token); \
mkdir -p /tmp/bodies; \
for f in /etc/vegeta-bodies-template/body-*.json; do \
    name=$$(basename $$f); \
    sed -e "s|@@SAT@@|$$SAT|" $$f > /tmp/bodies/$$name; \
done; \
vegeta attack \
    -targets=/etc/vegeta-targets/targets.txt \
    -workers=$(1) -rate=$(2) -duration=$(3) \
    -keepalive=false \
    -root-certs=/etc/ssl/certs/ca-certificates.crt \
| tee /data/$(4).bin \
| vegeta report
endef

sanity-contention: ## small-scale run (default 10 workers / 20rps / 5s) to confirm 1062 fires
	kubectl -n $(LOADTEST_NAMESPACE) exec deployment/$(VEGETA_DEPLOYMENT) -- /bin/sh -c \
		'$(call VEGETA_ATTACK,$(SANITY_WORKERS),$(SANITY_RATE),$(SANITY_DURATION),sanity-contention)'
	@echo
	@echo "==> MySQL 1062 count immediately after sanity run:"
	@$(MAKE) snapshot-mysql-errors

run-contention: ## main attack ($(ATTACK_WORKERS) workers / $(ATTACK_RATE)rps / $(ATTACK_DURATION))
	kubectl -n $(LOADTEST_NAMESPACE) exec deployment/$(VEGETA_DEPLOYMENT) -- /bin/sh -c \
		'$(call VEGETA_ATTACK,$(ATTACK_WORKERS),$(ATTACK_RATE),$(ATTACK_DURATION),contention)'

report-contention: ## render the latest contention run as an HTML plot
	kubectl -n $(LOADTEST_NAMESPACE) exec deployment/$(VEGETA_DEPLOYMENT) -- /bin/sh -c \
		"cat /data/contention.bin | vegeta report -reporter=plot" \
		> contention.html
	@echo "==> Wrote ./contention.html"

# ---------------------------------------------------------------------------
# MySQL measurement helpers
# ---------------------------------------------------------------------------

snapshot-mysql-errors: ## print cumulative 1062 count from server_audit log + certificates row count
	@# Primary signal: server_audit.log records every QUERY's return errno
	@# as the last CSV field. Count of ',1062$$' lines is the exact number
	@# of Duplicate entry errors raised since athenz-db pod start. Compute
	@# a delta by snapshotting this value before and after a run.
	@#
	@# Secondary signals (sanity cross-check):
	@#   * `certificates` row count grows by 1 per unique successful INSERT.
	@#   * ZTS log "Duplicate entry" lines (only at DEBUG, off by default).
	@echo "-- cumulative 1062 (Duplicate entry) count from server_audit log --"
	@kubectl -n $(NAMESPACE) exec statefulset/athenz-db -- \
		sh -c "grep -c ',1062\$$' /tmp/server_audit.log 2>/dev/null || echo 0"
	@echo
	@echo "-- certificates table row count (athenz-db / zts_store) --"
	@kubectl -n $(NAMESPACE) exec statefulset/athenz-db -- \
		mariadb -uroot -N -e "SELECT COUNT(*) AS rows_in_certificates FROM zts_store.certificates;"
	@echo
	@echo "-- certificates per (provider, instanceId, service) (PK groups) --"
	@kubectl -n $(NAMESPACE) exec statefulset/athenz-db -- \
		mariadb -uroot -N -e "SELECT provider, instanceId, service, currentSerial \
			FROM zts_store.certificates \
			WHERE service IN ('zts-contention') ORDER BY currentTime DESC LIMIT 5;" \
		|| true
	@echo
	@echo "-- ZTS log: count of 'Duplicate entry' lines since pod start --"
	@echo "   (only visible if the JDBCCertRecordStoreConnection logger is DEBUG)"
	@kubectl -n $(NAMESPACE) logs --tail=-1 deployment/athenz-zts-server 2>/dev/null \
		| grep -cE "Duplicate entry|Resetting state for instance" \
		|| echo 0

reset-certificates-table: reset-contention ## alias

reset-contention: ## truncate certificates table so the next run starts fresh
	kubectl -n $(NAMESPACE) exec statefulset/athenz-db -- mysql -uroot zts_store -e \
		"TRUNCATE TABLE certificates;"
	@echo "==> certificates table truncated"
