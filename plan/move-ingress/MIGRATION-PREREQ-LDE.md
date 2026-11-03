# Local Development Environment (LDE) — Running CI Tests Locally

This document describes how to set up and run the Functional Verification (FV) CI
tests on a developer workstation. It is written to work on **macOS** and
**Linux**, under **bash** or **zsh**; platform-specific points are called out
where they differ.

**Important note : Ensure Traefik is disabled when using Rancher Desktop with Kind.**

---

## 1. Prerequisites & Environment Setup

Ensure the following tools and CLI utilities are installed and available in `$PATH`:

1. **A Docker daemon**: Docker Desktop, Colima, Rancher Desktop or native
   `docker`/`podman` on Linux, running with at least 4 CPUs and 8 GB RAM.
   ⚠️ **Host ports 80 and 443 must be free** — see section 8.
2. **Kind**: Kubernetes in Docker (`kind version`).
3. **kubectl & jq**: cluster inspection and CoreDNS config
   (macOS `brew install kubectl jq`; Debian/Ubuntu `apt install kubectl jq`).
4. **Python ≥ 3.10**: required by `ansible-core` 2.17. Any 3.10+ interpreter
   works; the examples below use `python3.10` because that is what CI pins, but
   a newer one is fine.
5. **yq**: must be **python-yq** (`pip install yq`, installed by
   `requirements.txt` inside the venv). The Go `yq` from Homebrew or apt is a
   _different_ tool and does **not** support the `yq -yi` in-place YAML writes
   the test scripts rely on. Check with `yq --help | grep -- --yaml-output`:
   no output means the wrong `yq` is first on `PATH`.
6. **Ansible**: installed inside the virtualenv by section 2, not system-wide.
   A system Ansible on `PATH` shadows the venv one and will not find the
   `kubernetes` SDK.

---

## 2. Python 3.10 Virtual Environment & Dependencies

To ensure a clean, isolated environment and avoid library incompatibilities, use Python's built-in [`venv`](https://docs.python.org/3/library/venv.html) module with **Python 3.10** exactly.

### 2.1 Create and Activate Python 3.10 Virtual Environment

```bash
# Verify Python 3.10 is installed
python3.10 --version

# Create virtual environment in .venv
python3.10 -m venv .venv

# Activate virtual environment
source .venv/bin/activate

# Upgrade base packaging tools inside the virtual environment
pip install --upgrade pip setuptools wheel
```

### 2.2 Install Python Requirements & Collection Dependencies

Install the Python dependencies from [`requirements.txt`](../../requirements.txt) inside the active virtual environment:

```bash
pip install -r requirements.txt
```

Verify that required Ansible collections are installed or available:

```bash
ansible-galaxy collection install community.crypto community.general kubernetes.core
```

---

## 3. Build and Install Local Fabric Ansible Collection

Build the collection package from the repository root and install it into your local Ansible collections path:

```bash
ansible-galaxy collection build -f
ansible-galaxy collection install $(ls -1 | grep fabric_ansible_collection) -f
```

---

## 4. Install Hyperledger Fabric CLI Binaries (Fabric 2.5.15)

The tutorial playbooks and test scripts interact with Fabric CLI tools (`peer`,
`configtxlator`, ...). `BlockchainModule` checks for them at module start-up, so
a missing `peer` fails the very first task of any playbook.

Run this from the repository root — it detects OS and architecture, so the same
command works on macOS (Intel and Apple silicon) and on Linux (x86_64 and
arm64):

```bash
FABRIC_VERSION=2.5.15
OS=$(uname -s | tr '[:upper:]' '[:lower:]')          # darwin | linux
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)        ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
esac

curl -sSL "https://github.com/hyperledger/fabric/releases/download/v${FABRIC_VERSION}/hyperledger-fabric-${OS}-${ARCH}-${FABRIC_VERSION}.tar.gz" | tar xzf -
```

This unpacks `bin/` and `config/` into the repository root; both are gitignored.

### 4.1 Shell environment

Export these from the repository root, in the shell you will use for every
following section. Re-export them in any new terminal — nothing here persists.

```bash
# 1. The virtualenv from section 2 — a system-wide Ansible on PATH shadows it
#    and will not find the kubernetes SDK.
source .venv/bin/activate

# 2. The Fabric CLI binaries unpacked in section 4.
export PATH="$PWD/bin:$PATH"

# 3. core.yaml, which the peer CLI reads.
export FABRIC_CFG_PATH="$PWD/config"

# 4. The interpreter Ansible must use on localhost.
export ANSIBLE_PYTHON_INTERPRETER="$VIRTUAL_ENV/bin/python"
```

`KUBECONFIG` comes later, in section 5, once the Kind cluster has written it.

The last two are the ones most often missed:

| Variable                     | Why it is needed                                                                                                                                                                                                                                                                                                   |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `FABRIC_CFG_PATH`            | the `peer` CLI looks for `core.yaml` there; the modules set it for their own subprocesses but not for the `peer version` start-up check                                                                                                                                                                            |
| `ANSIBLE_PYTHON_INTERPRETER` | `deploy-console.sh` passes `-i localhost,`, which puts localhost **in the inventory**. Ansible only equates the target interpreter with the one running `ansible-playbook` for the _implicit_ localhost; with an explicit one, interpreter discovery takes over and picks a system Python with no `kubernetes` SDK |

Verify the binaries resolve to the repository copy:

```bash
peer version
command -v peer    # -> <repo>/bin/peer
```

### 4.2 (Optional) Shortcut and environment check

`.github/scripts/lde-env.sh` is a convenience for developers who set their
environment up repeatedly. It is **not** part of the test or CI path: no script
sources it, and nothing in this guide depends on it. Sourcing it applies exactly
the exports of section 4.1, plus `KUBECONFIG` once section 5 has run.

```bash
source .github/scripts/lde-env.sh   # same effect as section 4.1
lde_preflight                       # audit the environment
```

`lde_preflight` prints one line per dependency and returns non-zero if any is
missing. It is most useful as a diagnostic when a step fails: it reports which
`ansible-playbook`, `peer` and `yq` are actually on `PATH`, which `yq` flavour
is installed, whether the cluster answers, and which process holds host ports
80 and 443.

```
ok      ansible-playbook  <repo>/.venv/bin/ansible-playbook
ok      peer              <repo>/bin/peer
ok      yq flavour        python-yq (supports -yi)
ok      cluster           kind-kind
check   port 443          held by ssh (pid 45996)
```

If you prefer the explicit exports of section 4.1, ignore this section entirely.

---

## 5. Bootstrap Local Kind Cluster with Ingress

The test environment sets up a Kind cluster with an NGINX Ingress controller bound to host ports 80/443 and configures CoreDNS for `.localho.st` routing.

1. **Set Host API Server Address and Port**:
   On macOS Docker Desktop, use `127.0.0.1` or your host IP:

   ```bash
   export KIND_API_SERVER_ADDRESS="127.0.0.1"
   export KIND_API_SERVER_PORT="8888"
   ```

2. **Execute the Kind bootstrap script**:

   ```bash
   chmod +x .github/scripts/kind_with_nginx.sh
   .github/scripts/kind_with_nginx.sh
   ```

3. **Verify the cluster and ingress controller**:

   ```bash
   kubectl get nodes
   kubectl wait --namespace ingress-nginx \
     --for=condition=ready pod \
     --selector=app.kubernetes.io/component=controller \
     --timeout=3m
   ```

4. **Ensure `KUBECONFIG` is active**:
   ```bash
   export KUBECONFIG="$PWD/_cfg/k8s_context.yaml"
   ```

---

## 6. Deploy Fabric Operator & Console

Before running any tests the Fabric Operator CRDs and the Fabric Operations Console
must be deployed into the cluster. The helper script does this and writes connection
details to `_cfg/console-env.sh`:

```bash
export KUBECONFIG="$PWD/_cfg/k8s_context.yaml"
.github/scripts/deploy-console.sh
```

The exports of section 4.1 must still be active in this shell — `deploy-console.sh`
runs Ansible modules that need the `kubernetes` SDK and the Fabric binaries.

The script prints the console `API_ENDPOINT` it derived and waits for the console
deployment to become ready (`wait_timeout=600 s`).

### 6.1 (Optional) Deprovision Fabric Operator & Console

To tear down the console and operator CRDs without destroying the entire Kind cluster:

```bash
export KUBECONFIG="$PWD/_cfg/k8s_context.yaml"
.github/scripts/undeploy-console.sh
```

---

## 7. Run the Tests

The per-org vars files are **gitignored**: the runners rewrite them in place with
live connection details, which must never be committed. Only the templates are
tracked. The runners create the real files from their template on first use, so
nothing is required here — but if you run a tutorial playbook by hand on a fresh
clone, seed them yourself first:

```bash
cd tutorial
for VARS in ordering-org-vars org1-vars org2-vars; do
    [ -f "${VARS}.yml" ] || cp "${VARS}.yml.example" "${VARS}.yml"
done
cd ..
```

With the console deployed, run the full FV test suite:

```bash
export KUBECONFIG="$PWD/_cfg/k8s_context.yaml"
.github/scripts/run-tests.sh
```

`run-tests.sh` automatically sources `_cfg/console-env.sh` when it exists, so no
manual `export API_ENDPOINT=…` is required after `deploy-console.sh` has run.

### Option B: Running with `run-tutorial-tests.sh` (Parameterized / Multi-run)

If testing against an existing Fabric Operations Console endpoint (e.g. a remote
cluster), export the connection variables explicitly:

```bash
export API_ENDPOINT="https://<namespace>-<console-name>-console.<domain>"
export API_AUTHTYPE="basic"
export API_KEY="admin"
export API_SECRET="password"
export K8S_NAMESPACE="default"
export USE_DOCKER="false"

.github/scripts/run-tutorial-tests.sh
```

---

## 8. Troubleshooting

- **Port 80 / 443 conflicts** — the Kind node publishes host ports 80 and 443 for
  the ingress controller. Anything else holding them makes the console
  unreachable from the host, and the symptom is misleading: requests reach the
  _other_ listener and come back `404`, as if the ingress were misconfigured.
  Identify the holder first:

  ```bash
  lsof -nP -iTCP:443 -sTCP:LISTEN     # macOS and most Linux
  ss -ltnp  '( sport = :443 )'        # Linux fallback
  ```

  Common holders:

  | Holder                                                                                                                                                                                       | How to free the port                                                                                                                                       |
  | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
  | **Rancher Desktop** with Kubernetes enabled — its k3s runs Traefik behind a `svclb`, forwarded to the host by an `ssh` tunnel. A `CN=TRAEFIK DEFAULT CERT` in the TLS handshake confirms it. | `rdctl set --kubernetes.options.traefik=false`, or disable Kubernetes entirely in Settings → Kubernetes (Rancher Desktop still provides the Docker daemon) |
  | Apache / httpd (macOS)                                                                                                                                                                       | `sudo apachectl stop`                                                                                                                                      |
  | A host nginx (Linux)                                                                                                                                                                         | `sudo systemctl stop nginx`                                                                                                                                |

- **`Failed to import the required Python library (kubernetes)`** — Ansible is
  using the wrong interpreter. Re-apply section 4.1, in particular
  `ANSIBLE_PYTHON_INTERPRETER`. Confirm with
  `ansible localhost -m debug -a var=ansible_playbook_python`, which must print
  the `.venv` path.

- **`Failed to execute the required binary (peer)`** — `bin/` is not on `PATH`.
  Re-apply section 4.1, then check `command -v peer`.

- **`yq: unknown shorthand flag: 'y'`** — the Go `yq` is on `PATH` ahead of
  python-yq. Activate the virtualenv, or `pip install yq`.
- **Docker Memory Limits**: Hyperledger Fabric nodes (orderers, peers, chaincode containers, couchdb) require sufficient memory. Ensure Docker Desktop has at least **8 GB RAM** allocated in **Settings > Resources**.
- **DNS Resolution**: `*.localho.st` and `*.nip.io` domains are resolved via CoreDNS overrides in the cluster. If host resolution fails locally, verify `ping 127-0-0-1.nip.io` resolves to `127.0.0.1`.
- **4xx error codes**: Check Traefik is disabled in your Rancher Desktop configuration.

---

## 9. Validation Checklist

Work through each item in order before declaring the LDE ready.

- [ ] Kind cluster boots and NGINX Ingress controller pod becomes `Ready`
  ```bash
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=3m
  ```
- [ ] Operator CRDs and Console deploy without error (`deploy-console.sh` exits 0).
- [ ] Console health endpoint responds with HTTP 200 and a JSON payload:

  ```bash
  source _cfg/console-env.sh
  curl -sk -u "${API_KEY}:${API_SECRET}" "${API_ENDPOINT}/ak/api/v3/health" | jq 'keys'
  # Expected: ["OPTOOLS","OS"]
  ```

  Use **`/ak/api/v3/health`**, the path the modules call
  ([`consoles.py`](../../plugins/module_utils/consoles.py) builds it from
  `api_base_url`), and pass the credentials — it answers `401` without them.
  `${API_ENDPOINT}/health` is _not_ the API: it serves the console's HTML UI, so
  piping it to `jq` fails with `Invalid numeric literal`.

- [ ] The TLS certificate presented on `:443` is the console's own, proving the
      ingress is doing SSL passthrough and no other listener has taken the port:
  ```bash
  curl -sk -v "${API_ENDPOINT}/" 2>&1 | grep 'subject:'
  # Expected: CN=<namespace>-<console-name>-console.<domain>, O=ibp2-auto-gen
  # A foreign CN (e.g. TRAEFIK DEFAULT CERT) means something else holds :443 —
  # see section 8.
  ```
- [ ] Tutorial playbooks (01 to 23) complete successfully (`run-tests.sh` exits 0).
- [ ] Network teardown plays (`join_network.sh destroy`) cleanly delete all created resources.
