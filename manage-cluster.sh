#!/bin/bash

# manage-cluster.sh
# This script manages a Kind cluster with Istio for local development and testing.

set -o errexit
set -o nounset
set -o pipefail

# --- Configuration ---
ISTIO_VERSION="1.26.2"
CLUSTER_NAME="istio-dev"
KIND_CONFIG="kind-config.yaml"
CLOUD_PROVIDER_KIND_VERSION="v0.7.0"
PID_FILE=".cloud-provider-kind.pid"

# --- Helper Functions ---
function check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: Required command '$1' is not installed. Please install it and try again."
        exit 1
    fi
}

test_gateway() {
    echo "--- Testing the Ingress Gateway..."
    
    local EXTERNAL_IP
    local retries=6
    local delay=10

    echo "Attempting to get External IP for istio-ingressgateway..."
    for i in $(seq 1 $retries); do
        # Use jsonpath to extract the IP, redirect stderr to prevent errors if the field isn't ready
        EXTERNAL_IP=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        if [ -n "$EXTERNAL_IP" ]; then
            echo "Found External IP: ${EXTERNAL_IP}"
            break
        fi
        echo "Waiting for External IP to be assigned... (${i}/${retries})"
        sleep $delay
    done

    if [ -z "$EXTERNAL_IP" ]; then
        echo "Error: Timed out waiting for External IP for istio-ingressgateway."
        echo "Please ensure the bookinfo sample app is deployed and check service status."
        exit 1
    fi

    echo "--- Running test command: curl -s http://${EXTERNAL_IP}/productpage | grep -o '<title>.*</title>'"
    
    # Run the curl command and capture output
    local title
    title=$(curl -s --connect-timeout 5 "http://${EXTERNAL_IP}/productpage" | grep -o '<title>.*</title>')

    if [ -n "$title" ]; then
        echo "Success! Received response:"
        echo "$title"
    else
        echo "Error: Failed to get a valid response from http://${EXTERNAL_IP}/productpage"
        echo "Please ensure the bookinfo sample application has been deployed correctly."
    fi
}

# --- Core Functions ---
install_cloud_provider() {
    echo "--- Checking for cloud-provider-kind..."
    if command -v cloud-provider-kind &> /dev/null; then
        echo "cloud-provider-kind is already installed."
        return
    fi

    echo "cloud-provider-kind not found. Installing..."
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch
    case $(uname -m) in
        x86_64) arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *)
            echo "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac

    local release_file="cloud-provider-kind_${CLOUD_PROVIDER_KIND_VERSION#v}_${os}_${arch}.tar.gz"
    local download_url="https://github.com/kubernetes-sigs/cloud-provider-kind/releases/download/${CLOUD_PROVIDER_KIND_VERSION}/${release_file}"

    echo "Downloading from: ${download_url}"
    wget -q -O "${release_file}" "${download_url}"
    
    tar -xvf "${release_file}"
    chmod +x ./cloud-provider-kind
    
    echo "Moving cloud-provider-kind to /usr/local/bin/. You may be prompted for your password."
    if ! sudo mv ./cloud-provider-kind /usr/local/bin/cloud-provider-kind; then
        echo "Failed to move cloud-provider-kind. Please try running 'sudo mv ./cloud-provider-kind /usr/local/bin/cloud-provider-kind' manually."
        exit 1
    fi
    
    rm "${release_file}"
    echo "Successfully installed $(cloud-provider-kind --version)"
}

function start_cluster() {
    echo "--- Checking prerequisites ---"
    check_command "kind"
    check_command "kubectl"
    check_command "curl"
    echo "All prerequisites are met."
    echo

    install_cloud_provider

    echo "--- Starting cloud-provider-kind... may require the password"
    sudo cloud-provider-kind &
    # Save the PID of the background process
    echo $! > "${PID_FILE}"
    sleep 2 # Give it a moment to start
    echo "cloud-provider-kind started with PID $(cat ${PID_FILE})."

    echo "--- Creating Kind cluster: ${CLUSTER_NAME} ---"
    if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
        echo "Cluster created successfully."
    else
        echo "Cluster '${CLUSTER_NAME}' already exists. Skipping creation."
    fi
    echo

    echo "--- Setting up Istio (version ${ISTIO_VERSION}) ---"
    if ! command -v "istioctl" &> /dev/null || ! istioctl version | grep -q "${ISTIO_VERSION}"; then
        echo "istioctl ${ISTIO_VERSION} not found. Downloading..."
        curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
        export PATH=$PWD/istio-${ISTIO_VERSION}/bin:$PATH
        echo "istioctl has been temporarily added to your PATH for this session."
    fi

    echo "Installing Istio profile=demo..."
    istioctl install -y --set profile=demo

    echo "Waiting for Istio pods to be ready..."
    kubectl wait --namespace istio-system \
      --for=condition=ready pod --all \
      --timeout=300s
    kubectl label namespace default istio-injection=enabled
    echo "Istio installation complete and verified."
    echo

    echo "--- Deploying Bookinfo Application ---"
    echo "Enabling Istio sidecar injection for the 'default' namespace..."
    kubectl label namespace default istio-injection=enabled --overwrite
    
    echo "Downloading and applying bookinfo.yaml..."
    curl -sL "https://raw.githubusercontent.com/istio/istio/release-1.26/samples/bookinfo/platform/kube/bookinfo.yaml" -o bookinfo.yaml
    kubectl apply -f bookinfo.yaml

    # ---- START OF RELIABLE GATEWAY FIX ----
    # Instead of downloading and patching, we create the correct gateway config directly.
    # This avoids any issues with sed or remote file changes.
    echo "Creating a known-good bookinfo-gateway.yaml that listens on port 8080..."
    cat <<EOF > bookinfo-gateway.yaml
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: bookinfo-gateway
spec:
  selector:
    istio: ingressgateway # use istio default ingress gateway
  servers:
  - port:
      number: 8080
      name: http
      protocol: HTTP
    hosts:
    - "*"
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: bookinfo
spec:
  hosts:
  - "*"
  gateways:
  - bookinfo-gateway
  http:
  - match:
    - uri:
        exact: /productpage
    - uri:
        prefix: /static
    - uri:
        exact: /login
    - uri:
        exact: /logout
    - uri:
        prefix: /api/v1/products
    route:
    - destination:
        host: productpage
        port:
          number: 9080
EOF
    # ---- END OF RELIABLE GATEWAY FIX ----

    echo "Applying the generated Bookinfo gateway..."
    kubectl apply -f bookinfo-gateway.yaml
    echo "Bookinfo application deployed."
    echo

    echo "--- Verification ---"
    echo "Waiting for all pods in the 'default' namespace to be ready..."
    kubectl wait --for=condition=ready pod --all --namespace default --timeout=300s
    
    test_gateway

    echo "✅ ✅ ✅ Cluster setup is complete! ✅ ✅ ✅"
    echo
    echo "--- HOW TO EXPLORE YOUR NEW CLUSTER ---"
    echo
    echo "1. Find the Load Balancer IP:"
    echo "   kubectl get svc istio-ingressgateway -n istio-system"
    echo
    echo "2. Access the Bookinfo Application:"
    echo "   EXTERNAL_IP=\$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' "
    echo "   curl -s http://\${EXTERNAL_IP}/productpage | grep -o '<title>.*</title>'"
    echo
    echo "3. Open the Kiali Service Mesh Dashboard:"
    echo "   (Visualizes your service graph and configurations)"
    echo "   istioctl dashboard kiali"
    echo
    echo "4. Open the Jaeger Tracing Dashboard:"
    echo "   (Shows distributed traces from the Bookinfo app)"
    echo "   istioctl dashboard jaeger"
    echo
    echo "5. Inspect the Ingress Gateway's live routes:"
    echo "   export INGRESS_POD=\$(kubectl get pods -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].metadata.name}')"
    echo "   istioctl proxy-config routes \$INGRESS_POD -n istio-system --name http.8080"
    echo
    echo "-----------------------------------------"
}

function destroy_cluster() {
    echo "--- Stopping cloud-provider-kind process..."
    if [ -f "${PID_FILE}" ]; then
        PID=$(cat "${PID_FILE}")
        if ps -p "${PID}" > /dev/null; then
            echo "Killing process with PID ${PID}."
            kill "${PID}"
            rm "${PID_FILE}"
            echo "Process killed and PID file removed."
        else
            echo "Process with PID ${PID} not found. Removing stale PID file."
            rm "${PID_FILE}"
        fi
    else
        echo "PID file not found. Skipping process kill."
    fi

    echo "--- Destroying Kind cluster: ${CLUSTER_NAME} ---"
    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        kind delete cluster --name "${CLUSTER_NAME}"
        echo "Cluster '${CLUSTER_NAME}' destroyed."
    else
        echo "Cluster '${CLUSTER_NAME}' not found. Nothing to do."
    fi
    rm -f bookinfo.yaml bookinfo-gateway.yaml
    echo "Cleanup complete."
}

function main() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 <start|destroy>"
        exit 1
    fi

    case "$1" in
        start)
            start_cluster
            ;;
        destroy)
            destroy_cluster
            ;;
        *)
            echo "Error: Invalid command '$1'."
            echo "Usage: $0 <start|destroy>"
            exit 1
            ;;
    esac
}

main "$@"