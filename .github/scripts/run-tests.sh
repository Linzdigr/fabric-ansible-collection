#!/usr/bin/env bash
# Copyright the Hyperledger Fabric contributors. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Runs the tutorial test suite: build the network, join it, deploy the smart
# contract, destroy the network.
#
# Scenario variables (INGRESS_TYPE, EXPOSE_*, EXPOSED_DOMAIN, ...): see
# scenario-vars.sh. Run modes:
#   RUN_TESTS_MODE=run      (default) the whole suite
#   RUN_TESTS_MODE=patch    patch the vars files, run no playbook
#   RUN_TESTS_MODE=destroy  patch the vars files, destroy the network only
#   KEEP_NETWORK=true       do not destroy the network at the end
set -euo pipefail

# For local development: source connection details written by deploy-console.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scenario-vars.sh
source "${SCRIPT_DIR}/scenario-vars.sh"
if [[ -f "${REPO_ROOT}/_cfg/console-env.sh" ]]; then
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/_cfg/console-env.sh"
fi

# Connection defaults — overridden by environment when running in CI
API_ENDPOINT="${API_ENDPOINT:-https://127.0.0.1.nip.io:443}"
API_AUTHTYPE="${API_AUTHTYPE:-basic}"
API_KEY="${API_KEY:-admin}"
API_SECRET="${API_SECRET:-password}"
K8S_NAMESPACE="${K8S_NAMESPACE:-default}"

RUN_TESTS_MODE="${RUN_TESTS_MODE:-run}"
case "${RUN_TESTS_MODE}" in
    run|patch|destroy) ;;
    *) echo "ERROR: RUN_TESTS_MODE='${RUN_TESTS_MODE}': must be run, patch or destroy" >&2; exit 1 ;;
esac
KEEP_NETWORK="$(scenario_bool KEEP_NETWORK "${KEEP_NETWORK:-false}")"

cd "${REPO_ROOT}/tutorial"

# Seed the per-org vars files from their templates. The real files are
# gitignored: the runner rewrites them in place with live connection
# details, which must never be committed.
for VARS in ordering-org-vars org1-vars org2-vars; do
    [ -f "${VARS}.yml" ] || cp "${VARS}.yml.example" "${VARS}.yml"
done

# Scenario variables, read by every playbook (console and organizations)
patch_scenario_vars common-vars.yml
print_scenario_vars common-vars.yml
echo "==> Run: RUN_TESTS_MODE=${RUN_TESTS_MODE} KEEP_NETWORK=${KEEP_NETWORK} API_ENDPOINT=${API_ENDPOINT} K8S_NAMESPACE=${K8S_NAMESPACE}"

# Inject live connection parameters into every org vars file
for VARS in ordering-org-vars.yml org1-vars.yml org2-vars.yml; do
    yq -yi ".api_endpoint=\"${API_ENDPOINT}\""   "${VARS}"
    yq -yi ".api_authtype=\"${API_AUTHTYPE}\""   "${VARS}"
    yq -yi ".api_key=\"${API_KEY}\""             "${VARS}"
    yq -yi ".api_secret=\"${API_SECRET}\""       "${VARS}"
    yq -yi ".api_timeout=300"                    "${VARS}"
    yq -yi ".k8s_namespace=\"${K8S_NAMESPACE}\"" "${VARS}"
    yq -yi ".wait_timeout=1800"                  "${VARS}"
done

if [[ "${RUN_TESTS_MODE}" == "patch" ]]; then
    echo "==> RUN_TESTS_MODE=patch: vars files patched, no playbook run"
    exit 0
fi
if [[ "${RUN_TESTS_MODE}" == "destroy" ]]; then
    ./join_network.sh destroy
    exit 0
fi

function cleanup {
    ./join_network.sh destroy || true
}
if [[ "${KEEP_NETWORK}" != "true" ]]; then
    trap cleanup EXIT
fi

./build_network.sh build

./join_network.sh join
./deploy_smart_contract.sh

if [[ "${KEEP_NETWORK}" == "true" ]]; then
    echo "==> KEEP_NETWORK=true: the network is kept (RUN_TESTS_MODE=destroy removes it)"
    exit 0
fi
trap - EXIT
./join_network.sh destroy
