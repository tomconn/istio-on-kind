#!/bin/bash

# manage-cluster.sh
# This script manages a Kind cluster with Istio for local development and testing.

set -o errexit
set -o nounset
set -o pipefail

# --- Configuration ---
# Removed 'readonly' to allow the Istio download script to set a temporary environment variable.
ISTIO_VERSION="1.26.2"
CLUSTER_NAME="istio-dev"
KIND_CONFIG="kind-config.yaml"
METALLB_CONFIG="metallb-config.yaml"
ISTIO_CONFIG="istio-config.yaml"

# --- Helper Functions ---
function check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: Required command '$1' is not installed. Please install it and try again."
        exit 1
    fi
}

# --- Core Functions ---

function start_cluster() {
    echo "--- Checking prerequisites ---"
    check_command "kind"
    check_command "kubectl"
    check_command "curl"
    echo "All prerequisites are met."
    echo

    echo "--- Creating Kind cluster: ${CLUSTER_NAME} ---"
    if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
        echo "Cluster created successfully."
    else
        echo "Cluster '${CLUSTER_NAME}' already exists. Skipping creation."
    fi
    echo

    echo "--- Installing MetalLB Load Balancer ---"
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml
    echo "Waiting for MetalLB pods to be ready..."
    kubectl wait --namespace metallb-system \
        --for=condition=ready pod \
        --selector=app=metallb \
        --timeout=120s
    
    echo "Giving the MetalLB webhook a moment to initialize..."
    sleep 15

    echo "Applying MetalLB IP address pool configuration from ${METALLB_CONFIG}..."
    kubectl apply -f "${METALLB_CONFIG}"
    echo "MetalLB is ready."
    echo

    echo "--- Setting up Istio (version ${ISTIO_VERSION}) ---"
    if ! command -v "istioctl" &> /dev/null || ! istioctl version | grep -q "${ISTIO_VERSION}"; then
        echo "istioctl ${ISTIO_VERSION} not found. Downloading..."
        # The following line requires ISTIO_VERSION to be a regular variable, not readonly.
        curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
        export PATH=$PWD/istio-${ISTIO_VERSION}/bin:$PATH
        echo "istioctl has been temporarily added to your PATH for this session."
        echo "For permanent use, add '$PWD/istio-${ISTIO_VERSION}/bin' to your shell profile."
    fi

    echo "Installing Istio using configuration from ${ISTIO_CONFIG}..."
    if ! istioctl install -y -f "${ISTIO_CONFIG}"; then
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
        echo "ERROR: Istio installation failed." >&2
        echo "Please review the output from 'istioctl' above to diagnose." >&2
        echo "You may need to run './manage-cluster.sh destroy' before trying again." >&2
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
        exit 1
    fi
    
    echo "Waiting for Istio pods to be ready..."
    kubectl wait --namespace istio-system \
      --for=condition=ready pod --all \
      --timeout=300s
    echo "Istio installation complete and verified."
    echo

    echo "--- Deploying Bookinfo Application ---"
    echo "Enabling Istio sidecar injection for the 'default' namespace..."
    kubectl label namespace default istio-injection=enabled --overwrite
    
    echo "Downloading and applying bookinfo.yaml..."
    curl -sL "https://raw.githubusercontent.com/istio/istio/release-1.26/samples/bookinfo/platform/kube/bookinfo.yaml" -o bookinfo.yaml
    kubectl apply -f bookinfo.yaml

    echo "Applying Bookinfo gateway..."
    curl -sL "https://raw.githubusercontent.com/istio/istio/release-1.26/samples/bookinfo/networking/bookinfo-gateway.yaml" -o bookinfo-gateway.yaml
    kubectl apply -f bookinfo-gateway.yaml
    echo "Bookinfo application deployed."
    echo

    echo "--- Verification ---"
    echo "Waiting for all pods in the 'default' namespace to be ready..."
    kubectl wait --for=condition=ready pod --all --namespace default --timeout=300s
    
    echo "Cluster setup is complete!"
    echo "Run this command to find your Load Balancer IP:"
    echo "kubectl get svc istio-ingressgateway -n istio-system"
    echo
    echo "You can access the Bookinfo product page at http://localhost/productpage"
}

function destroy_cluster() {
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