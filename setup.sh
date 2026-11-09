#!/usr/bin/env bash
# =============================================================================
# TechDesk — IT services helpdesk on Azure AKS
# Repo: it-services-aks
#
# Modes (first argument):
#   ./setup.sh cluster   Create the resource group + AKS cluster, configure kubectl
#   ./setup.sh deploy    Deploy TechDesk (PostgreSQL + web dashboard, namespace: techdesk)
#   ./setup.sh destroy   Delete TechDesk AND the cluster (asks first)
#
# Overrides (environment variables):
#   CLUSTER_NAME     Default: techdesk
#   REGION           Default: eastus        (Azure location name)
#   RESOURCE_GROUP   Default: techdesk-rg
#   NODE_COUNT       Default: 2
#   NODE_SIZE        Default: Standard_B2s  (small burstable VM, good for learning)
#   NAMESPACE        Default: techdesk
#   DELETE_RESOURCE_GROUP  Set to "true" to also delete the resource group on destroy
#
# COST WARNING: An AKS cluster is NOT free. The AKS control plane has a free
# tier, but the NODE VMs are billed for every hour they run (2 x Standard_B2s
# is only a few dollars a month if left on, and bigger sizes cost much more).
# There is no per-cluster pause button for standard AKS — create it, learn,
# then run ./setup.sh destroy the same day.
# =============================================================================
set -e

REPO="it-services-aks"
OWNER="UncleD0886475978"
REPO_URL="https://github.com/${OWNER}/${REPO}.git"
RUN_ONELINE="curl -fsSL https://raw.githubusercontent.com/${OWNER}/${REPO}/main/setup.sh | bash"
CLOUD_CLI_HINT="Azure CLI: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli — then run: az login"

CLUSTER_NAME="${CLUSTER_NAME:-techdesk}"
REGION="${REGION:-eastus}"
RESOURCE_GROUP="${RESOURCE_GROUP:-techdesk-rg}"
NODE_COUNT="${NODE_COUNT:-2}"
NODE_SIZE="${NODE_SIZE:-Standard_B2s}"
NAMESPACE="${NAMESPACE:-techdesk}"

step() { echo ""; echo "==> $*"; }
info() { echo "    $*"; }
die()  { echo ""; echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Bootstrap: platform check, sudo, apt base tools, tool installers.
# On a fresh Ubuntu/Debian VM this script INSTALLS its own prerequisites.
# On a non-apt platform it prints guidance and exits 1.
# ---------------------------------------------------------------------------
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "ERROR: this script needs root or sudo to install packages." >&2
    exit 1
  fi
fi
APT=0
if [ "$(uname -s)" = "Linux" ] && command -v apt-get >/dev/null 2>&1; then APT=1; fi
INSTALLED=""
APT_UPDATED=""
note_installed() { INSTALLED="${INSTALLED} $1"; }
apt_update_once() {
  if [ -z "${APT_UPDATED}" ]; then $SUDO apt-get update -y; APT_UPDATED=1; fi
}
apt_install() {
  apt_update_once
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "$@"
}
require_apt() {
  if [ "${APT}" -ne 1 ]; then
    echo "" >&2
    echo "ERROR: this bootstrap auto-installs prerequisites only on Ubuntu/Debian (apt)." >&2
    echo "On this platform, install the tools manually, then re-run:" >&2
    echo "  kubectl:  https://kubernetes.io/docs/tasks/tools/" >&2
    echo "  helm:     https://helm.sh/docs/intro/install/" >&2
    echo "  $CLOUD_CLI_HINT" >&2
    exit 1
  fi
}
install_base_tools() {
  step "Platform check + base bootstrap (git, curl, unzip, ca-certificates, gnupg)"
  require_apt
  BASE_PKGS=""
  command -v git >/dev/null 2>&1 || BASE_PKGS="${BASE_PKGS} git"
  command -v curl >/dev/null 2>&1 || BASE_PKGS="${BASE_PKGS} curl"
  command -v unzip >/dev/null 2>&1 || BASE_PKGS="${BASE_PKGS} unzip"
  [ -f /etc/ssl/certs/ca-certificates.crt ] || BASE_PKGS="${BASE_PKGS} ca-certificates"
  command -v gpg >/dev/null 2>&1 || BASE_PKGS="${BASE_PKGS} gnupg"
  if [ -n "${BASE_PKGS}" ]; then
    info "Installing base tools:${BASE_PKGS}"
    # shellcheck disable=SC2086
    apt_install ${BASE_PKGS}
    note_installed "${BASE_PKGS}"
  else
    info "Base tools already present (git, curl, unzip, ca-certificates, gnupg)."
  fi
}
install_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then info "kubectl: already present"; return 0; fi
  require_apt
  step "Installing kubectl (official dl.k8s.io binary)"
  KARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "${KARCH}" in x86_64) KARCH="amd64" ;; aarch64) KARCH="arm64" ;; esac
  KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  TMP_K="$(mktemp -d)"
  curl -fsSL -o "$TMP_K/kubectl" "https://dl.k8s.io/release/${KVER}/bin/linux/${KARCH}/kubectl"
  $SUDO install -o root -g root -m 0755 "$TMP_K/kubectl" /usr/local/bin/kubectl
  rm -rf "$TMP_K"
  note_installed "kubectl"
}
install_helm() {
  if command -v helm >/dev/null 2>&1; then info "helm: already present"; return 0; fi
  require_apt
  step "Installing helm (official get-helm-3 script)"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  note_installed "helm"
}
locate_repo() {
  step "Locating the repo checkout"
  if [ -f "$0" ] && [ -d "$(cd "$(dirname "$0")" && pwd)/k8s" ]; then
    REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
    info "Using script location: $REPO_DIR"
  elif [ -d "$PWD/k8s" ] && [ -f "$PWD/setup.sh" ]; then
    REPO_DIR="$PWD"
    info "Already inside the repo checkout: $REPO_DIR"
  else
    REPO_DIR="$HOME/repos/$REPO"
    if [ -d "$REPO_DIR/.git" ]; then
      info "Existing checkout found at $REPO_DIR — pulling latest..."
      git -C "$REPO_DIR" pull --ff-only || true
    else
      command -v git >/dev/null 2>&1 || die "git not found and no local checkout. Install git first: https://git-scm.com/downloads"
      info "Cloning $REPO_URL into $REPO_DIR ..."
      mkdir -p "$HOME/repos"
      git clone "$REPO_URL" "$REPO_DIR"
    fi
  fi
  K8S_DIR="$REPO_DIR/k8s"
  [ -d "$K8S_DIR" ] || die "k8s/ directory not found under $REPO_DIR — cannot deploy."
}
print_bootstrap_summary() {
  cat <<EOF

=================== BOOTSTRAP SUMMARY ===================
Installed during this run:${INSTALLED:- (nothing — all tools were already present)}
Working copy: ${REPO_DIR:-}
Next time, set up from scratch on any fresh Ubuntu VM with one line:
  ${RUN_ONELINE}
=========================================================
EOF
}
check_kubectl() {
  step "Checking kubectl"
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found after bootstrap. Install it: https://kubernetes.io/docs/tasks/tools/ — then run this again."
  info "kubectl: $(kubectl version --client --output=yaml 2>/dev/null | grep -m1 gitVersion | awk '{print $2}' || kubectl version --client)"
}
check_helm() {
  step "Checking helm"
  command -v helm >/dev/null 2>&1 || die "helm not found after bootstrap. Install it: https://helm.sh/docs/intro/install/ — then run this again."
  info "helm found (used by later tracks; this app itself is plain manifests)."
}
require_kube_access() {
  check_kubectl
  step "Checking kubectl can reach a cluster"
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster. Run ./setup.sh cluster first (or fix your kubeconfig)."
  kubectl get nodes
}

install_azurecli() {
  if command -v az >/dev/null 2>&1; then info "Azure CLI: already present"; return 0; fi
  require_apt
  step "Installing Azure CLI (official Microsoft install script — apt repo)"
  # Official one-line installer from Microsoft (aka.ms) — sets up the
  # Microsoft apt repository and installs azure-cli on Ubuntu/Debian.
  curl -sL https://aka.ms/InstallAzureCLIDeb | $SUDO bash
  note_installed "azure-cli"
}
bootstrap_prereqs() {
  install_base_tools
  locate_repo
  install_kubectl
  install_helm
  install_azurecli
  print_bootstrap_summary
}
check_azure() {
  step "Checking Azure CLI and login"
  command -v az >/dev/null 2>&1 || die "Azure CLI not found after bootstrap. Install it: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli — then run: az login"
  if ! az account show >/dev/null 2>&1; then
    echo ""
    echo "You are not logged in to Azure (az account show failed)."
    echo "Log in first, then run this script again:"
    echo "    az login"
    exit 1
  fi
  info "Logged in. Subscription: $(az account show --query name -o tsv) ($(az account show --query id -o tsv))"
}
do_cluster() {
  check_azure
  check_kubectl
  check_helm

  step "Creating resource group '$RESOURCE_GROUP' in $REGION"
  az group create --name "$RESOURCE_GROUP" --location "$REGION" -o table

  if az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" >/dev/null 2>&1; then
    info "AKS cluster '$CLUSTER_NAME' already exists — skipping creation."
  else
    step "Creating AKS cluster '$CLUSTER_NAME' ($NODE_COUNT x $NODE_SIZE)"
    info "This usually takes 5-10 minutes."
    az aks create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$CLUSTER_NAME" \
      --location "$REGION" \
      --node-count "$NODE_COUNT" \
      --node-vm-size "$NODE_SIZE" \
      --generate-ssh-keys \
      -o table
  fi

  step "Pointing kubectl at the cluster"
  az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --overwrite-existing

  step "Verifying nodes"
  kubectl get nodes
  echo ""
  echo "Cluster is ready. Next step:"
  echo "    ./setup.sh deploy"
}

do_deploy() {
  require_kube_access
  step "Applying the TechDesk stack to namespace '$NAMESPACE'"
  kubectl apply -f "$K8S_DIR/namespace.yaml"
  if kubectl -n "$NAMESPACE" get secret techdesk-db-secret >/dev/null 2>&1; then
    info "techdesk-db-secret already exists — keeping it."
  else
    echo "    WARNING: no techdesk-db-secret found, so the EXAMPLE secret is being"
    echo "    applied with the demo password 'techdesk-demo-change-me'."
    echo "    Fine for learning on a throwaway cluster; change it anywhere else."
    kubectl apply -f "$K8S_DIR/techdesk-db-secret.example.yaml"
  fi
  kubectl apply -f "$K8S_DIR/techdesk-db-schema.yaml"
  kubectl apply -f "$K8S_DIR/techdesk-db-pvc.yaml"
  kubectl apply -f "$K8S_DIR/techdesk-db-statefulset.yaml"
  kubectl apply -f "$K8S_DIR/techdesk-db-service.yaml"
  kubectl apply -f "$K8S_DIR/techdesk-web-configmap.yaml"
  kubectl apply -f "$K8S_DIR/techdesk-web-deployment.yaml"
  kubectl apply -f "$K8S_DIR/techdesk-web-service.yaml"
  step "Waiting for PostgreSQL to be ready (first run pulls the image)"
  kubectl -n "$NAMESPACE" rollout status statefulset/techdesk-db --timeout=300s
  step "Waiting for the web dashboard to be ready"
  kubectl -n "$NAMESPACE" rollout status deployment/techdesk-web --timeout=300s
  kubectl -n "$NAMESPACE" get pods,svc,pvc
  echo ""
  echo "TechDesk is running."
  echo ""
  echo "Dashboard (LoadBalancer — the cloud load balancer can take a minute or two):"
  echo "    kubectl -n $NAMESPACE get svc techdesk-web"
  echo "    # then open http://<EXTERNAL-IP>/ in your browser"
  LB_IP="$(kubectl -n "$NAMESPACE" get svc techdesk-web -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [ -n "$LB_IP" ]; then echo "    LoadBalancer address: http://$LB_IP/"; else echo "    (No LoadBalancer address yet — re-check the svc in a minute.)"; fi
  echo ""
  echo "Port-forward fallback (works without a load balancer):"
  echo "    kubectl -n $NAMESPACE port-forward svc/techdesk-web 8080:80   # dashboard at http://localhost:8080"
  echo "    kubectl -n $NAMESPACE port-forward svc/techdesk-db 5432:5432"
  echo "    psql -h localhost -U techdesk -d techdesk   (password: your techdesk-db-secret)"
  echo ""
  echo "When you are done learning, clean up (the cluster costs money while it exists):"
  echo "    ./setup.sh destroy"
}

do_destroy() {
  check_azure
  check_kubectl
  echo ""
  echo "======================================================================"
  echo "  DESTROY: this deletes TechDesk AND the AKS cluster"
  echo "  '$CLUSTER_NAME' in resource group '$RESOURCE_GROUP', with all data."
  echo ""
  echo "  COST WARNING: clusters are NOT free. Deleting is what STOPS the"
  echo "  node VM charges — create it, learn, then destroy it the same day."
  echo "======================================================================"
  printf "Type yes to continue: "
  read -r CONFIRM
  [ "$CONFIRM" = "yes" ] || { echo "Aborted — nothing was deleted."; exit 0; }

  step "Deleting the TechDesk namespace '$NAMESPACE' (if reachable)"
  kubectl delete namespace "$NAMESPACE" --ignore-not-found --timeout=120s 2>/dev/null || info "Cluster not reachable from kubectl — continuing with cluster deletion."

  step "Deleting the AKS cluster '$CLUSTER_NAME'"
  az aks delete --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --yes --no-wait
  info "Deletion started in the background (it finishes in a few minutes)."

  if [ "${DELETE_RESOURCE_GROUP:-false}" = "true" ]; then
    step "Deleting resource group '$RESOURCE_GROUP' (DELETE_RESOURCE_GROUP=true)"
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait
    info "Resource group deletion started."
  else
    info "Resource group '$RESOURCE_GROUP' was left in place (it costs nothing empty)."
    info "Delete it too with: DELETE_RESOURCE_GROUP=true ./setup.sh destroy"
  fi
  echo ""
  echo "Destroyed. Node VM billing stops once deletion completes."
}

case "${1:-}" in
  cluster) bootstrap_prereqs; do_cluster ;;
  deploy)  bootstrap_prereqs; do_deploy ;;
  destroy) bootstrap_prereqs; do_destroy ;;
  *)
    echo "TechDesk — IT services helpdesk on Azure AKS"
    echo ""
    echo "Usage: $0 <cluster|deploy|destroy>"
    echo "  cluster  Create the resource group + AKS cluster and configure kubectl"
    echo "  deploy   Deploy TechDesk (PostgreSQL + web dashboard) into namespace '$NAMESPACE'"
    echo "  destroy  Delete TechDesk and the cluster (asks for confirmation)"
    echo ""
    echo "Overrides: CLUSTER_NAME, REGION, RESOURCE_GROUP, NODE_COUNT, NODE_SIZE, NAMESPACE"
    echo "COST: AKS node VMs are not free — destroy the cluster the same day, when you are done learning."
    exit 1
    ;;
esac
