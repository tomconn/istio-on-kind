# Local Development with Istio on Kind

This document outlines the setup for a local developer environment running a Kind (Kubernetes in Docker) cluster with Istio installed.

## Overview

The environment is managed by a single script, `manage-cluster.sh`, which automates the creation, configuration, and teardown of the entire stack. This setup is ideal for testing and developing with Istio service mesh on a local machine.

The script handles the following:
1.  **Kind Cluster Creation**: Sets up a multi-node Kubernetes cluster.
2.  **Istio Installation**: Installs a specific version of Istio.
3.  **Bookinfo Deployment**: Deploys the standard Istio Bookinfo demo application.
4.  **External Access**: Configures `cloud-provider-kind` to enable access to services from outside the cluster.

## Prerequisites

Ensure the following tools are installed on your `macos` machine. Althought it should be possible with slight modification to run on Windows with WSL2 or Linux.

*   **Hardware**: At least 16GB of RAM.
*   **Package Manager**: [Homebrew](https://brew.sh/)
*   **Go**: Version `1.24`
*   **Container Runtime**: [Rancher Desktop](https://www.rancherdesktop.io/) Version `1.19.3`
*   **CLI Tools**:
    *   `kubectl`
    *   `kind`
    *   `istioctl` (Version `1.26.2`)

## Getting Started

The entire setup is orchestrated by the `manage-cluster.sh` script. This script automates the creation of the Kind cluster, the installation of Istio, the deployment of the Bookinfo application, and the setup of the cloud provider.

### Cluster Configuration

The Kind cluster is configured using the `kind-config.yaml` file and consists of:
*   1 control-plane node
*   2 worker nodes

The cluster runs a Kubernetes version supported by Kind, such as `v1.33.1`.

### Istio and Bookinfo

*   **Istio**: The script installs Istio version `1.26.2`.
*   **Bookinfo Application**: The reference `bookinfo.yaml` application is deployed to the `default` namespace for demonstration purposes.

### External Access with Cloud Provider KIND

To expose the Istio Ingress Gateway to your local machine, the `manage-cluster.sh` script installs and runs `cloud-provider-kind`. This tool provides load-balancer functionality for Kind clusters, simulating a cloud environment.

The script automates the installation of the `cloud-provider-kind` binary. You can view the full script here: [manage-cluster.sh](https://github.com/tomconn/istio-on-kind/blob/main/manage-cluster.sh).

## Cluster Management

The `manage-cluster.sh` script simplifies the lifecycle of the local environment. Note: sudo is required to start

### Start the Cluster

To create and configure the entire environment, run:
```bash
./manage-cluster.sh start
```
This command will:
1.  Create the Kind cluster.
2.  Install `cloud-provider-kind`.
3.  Install Istio `1.26.2`.
4.  Deploy the Bookinfo application.

As the script runs, it will prompt for a password as the `cloud-provider-kind` requires sudo to execute.
```bash
sudo cloud-provider-kind &
```

### Destroy the Cluster

To tear down the cluster and remove all associated resources, run:
```bash
./manage-cluster.sh destroy
```

## Accessing the Bookinfo Application

Once the cluster is running and `cloud-provider-kind` is active, you can access the Bookinfo application.

### External Access (Recommended)

After running the start script, the Istio Ingress Gateway service will be assigned an external IP address. You can find this IP by running:
```bash
kubectl get svc -n istio-system istio-ingressgateway
EXTERNAL_IP=\$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s http://\${EXTERNAL_IP}/productpage | grep -o '<title>.*</title>'
```

```bash
Success! Received response:
<title>Simple Bookstore App</title>
```

### Internal Access (Alternative)

If you choose not to run `cloud-provider-kind` to externalize the service, you can still verify access from within the cluster.

1.  Deploy a temporary pod for testing:
    ```bash
    kubectl run curl-pod --image=curlimages/curl -- sleep infinity
    ```

2.  Execute a `curl` command from the pod to the `productpage`:
    ```bash
    kubectl exec curl-pod -- curl -s http://istio-ingressgateway.istio-system/productpage | grep -o '<title>.*</title>'
    ```
    This should return `<title>Simple Bookstore App</title>`.