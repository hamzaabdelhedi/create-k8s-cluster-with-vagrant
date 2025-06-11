#!/bin/bash

# k8s-cluster-manager.sh - Kubernetes Vagrant Cluster Management Script (VirtualBox)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DEFAULT_NODES=2
DEFAULT_MEMORY=2048
DEFAULT_CPUS=2
DEFAULT_K8S_VERSION="1.32.2"

print_usage() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  up [n]          - Create cluster with n nodes (2-4, default: 2)"
    echo "  scale [n]       - Scale cluster to n nodes (adds/removes as needed)"
    echo "  down            - Destroy the entire cluster"
    echo "  status          - Show cluster status"
    echo "  ssh [node]      - SSH into a node (master, worker1, worker2, worker3)"
    echo "  logs [node]     - Show logs for a node"
    echo "  kubectl [cmd]   - Execute kubectl command on master"
    echo "  setup-kubectl   - Setup kubectl access from host machine"
    echo "  reset-kubectl   - Reset host kubectl to previous config"
    echo ""
    echo "Options:"
    echo "  --memory=SIZE   - Memory per node in MB (default: 2048)"
    echo "  --cpus=COUNT    - CPUs per node (default: 2)"
    echo "  --k8s-version=V - Kubernetes version (default: 1.32.1)"
    echo ""
    echo "Environment Variables:"
    echo "  NODES          - Number of nodes"
    echo "  NODE_MEMORY    - Memory per node"
    echo "  NODE_CPUS      - CPUs per node"
    echo "  K8S_VERSION    - Kubernetes version"
    echo ""
    echo "Examples:"
    echo "  $0 up 3                    # Create 3-node cluster"
    echo "  $0 scale 4                 # Scale to 4 nodes"
    echo "  $0 setup-kubectl           # Setup host kubectl access"
    echo "  $0 kubectl get nodes       # Get cluster nodes (via SSH)"
    echo "  kubectl get nodes          # Get nodes (after setup-kubectl)"
    echo "  $0 ssh master              # SSH to master node"
}

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

check_vagrant() {
    if ! command -v vagrant &> /dev/null; then
        error "Vagrant is not installed or not in PATH"
    fi
}

check_virtualbox() {
    if ! command -v VBoxManage &> /dev/null; then
        error "VirtualBox is not installed or not in PATH"
    fi
    
    # Check if VirtualBox kernel modules are loaded
    if ! lsmod | grep -q vboxdrv; then
        warn "VirtualBox kernel modules not loaded. Trying to load them..."
        sudo modprobe vboxdrv vboxnetflt vboxnetadp || error "Failed to load VirtualBox modules"
    fi
}

get_current_nodes() {
    if [ -f .vagrant/machines/k8s-master/virtualbox/id ]; then
        local count=1
        for i in {1..3}; do
            if [ -f ".vagrant/machines/k8s-worker${i}/virtualbox/id" ]; then
                count=$((count + 1))
            fi
        done
        echo $count
    else
        echo 0
    fi
}

validate_node_count() {
    local nodes=$1
    if [[ ! "$nodes" =~ ^[0-9]+$ ]] || [ "$nodes" -lt 2 ] || [ "$nodes" -gt 4 ]; then
        error "Node count must be between 2 and 4"
    fi
}

setup_host_kubectl() {
    log "Setting up kubectl access from host machine..."
    
    if [ ! -f ".kube/config" ]; then
        warn "Kubeconfig not found. Make sure cluster is running."
        return 1
    fi
    
    # Check if kubectl is installed on host
    if ! command -v kubectl &> /dev/null; then
        warn "kubectl not found on host machine."
        echo ""
        echo "To install kubectl:"
        echo "  macOS: brew install kubectl"
        echo "  Linux: sudo snap install kubectl --classic"
        echo "  Or download from: https://kubernetes.io/docs/tasks/tools/"
        echo ""
    fi
    
    # Set up kubeconfig
    local host_kubeconfig="${HOME}/.kube/config"
    local backup_suffix=$(date +%Y%m%d_%H%M%S)
    
    # Backup existing kubeconfig if it exists
    if [ -f "$host_kubeconfig" ]; then
        log "Backing up existing kubeconfig to ${host_kubeconfig}.backup_${backup_suffix}"
        cp "$host_kubeconfig" "${host_kubeconfig}.backup_${backup_suffix}"
    fi
    
    # Create .kube directory if it doesn't exist
    mkdir -p "${HOME}/.kube"
    
    # Copy the kubeconfig
    cp ".kube/config" "$host_kubeconfig"
    
    log "Kubeconfig copied to ${host_kubeconfig}"
    log "You can now use kubectl from your host machine!"
    
    # Test the connection
    echo ""
    log "Testing connection..."
    if kubectl get nodes 2>/dev/null; then
        log "✅ kubectl is working! Cluster is accessible from host."
    else
        warn "❌ Connection test failed. Check if cluster is running."
    fi
}

reset_host_kubectl() {
    local host_kubeconfig="${HOME}/.kube/config"
    local latest_backup=$(ls -t "${host_kubeconfig}".backup_* 2>/dev/null | head -n1)
    
    if [ -n "$latest_backup" ]; then
        log "Restoring kubeconfig from backup: $latest_backup"
        cp "$latest_backup" "$host_kubeconfig"
        log "Kubeconfig restored"
    else
        warn "No backup found. You may need to manually restore your kubeconfig"
    fi
}

cluster_up() {
    local nodes=${1:-$DEFAULT_NODES}
    validate_node_count $nodes
    
    log "Creating Kubernetes cluster with $nodes nodes..."
    
    export NODES=$nodes
    export NODE_MEMORY=${NODE_MEMORY:-$DEFAULT_MEMORY}
    export NODE_CPUS=${NODE_CPUS:-$DEFAULT_CPUS}
    export K8S_VERSION=${K8S_VERSION:-$DEFAULT_K8S_VERSION}
    
    log "Configuration:"
    log "  Nodes: $NODES"
    log "  Memory per node: ${NODE_MEMORY}MB"
    log "  CPUs per node: $NODE_CPUS"
    log "  Kubernetes version: $K8S_VERSION"
    
    vagrant up
    
    log "Cluster created successfully!"
    
    # Automatically setup kubectl for host
    echo ""
    setup_host_kubectl
    
    cluster_status
}

cluster_scale() {
    local target_nodes=${1:-$DEFAULT_NODES}
    validate_node_count $target_nodes
    
    local current_nodes=$(get_current_nodes)
    
    if [ $current_nodes -eq 0 ]; then
        log "No existing cluster found. Creating new cluster..."
        cluster_up $target_nodes
        return
    fi
    
    log "Current nodes: $current_nodes, Target nodes: $target_nodes"
    
    if [ $target_nodes -eq $current_nodes ]; then
        log "Cluster already has $target_nodes nodes"
        return
    elif [ $target_nodes -gt $current_nodes ]; then
        log "Scaling up from $current_nodes to $target_nodes nodes..."
        export NODES=$target_nodes
        export NODE_MEMORY=${NODE_MEMORY:-$DEFAULT_MEMORY}
        export NODE_CPUS=${NODE_CPUS:-$DEFAULT_CPUS}
        export K8S_VERSION=${K8S_VERSION:-$DEFAULT_K8S_VERSION}
        
        # Add new worker nodes
        for ((i=current_nodes; i<target_nodes; i++)); do
            log "Adding worker node $i..."
            vagrant up "k8s-worker$i"
        done
    else
        log "Scaling down from $current_nodes to $target_nodes nodes..."
        # Remove worker nodes
        for ((i=target_nodes; i<current_nodes; i++)); do
            if [ $i -gt 0 ]; then  # Don't remove master (node 0)
                log "Removing worker node $i..."
                vagrant destroy -f "k8s-worker$i"
                
                # Remove from Kubernetes cluster
                log "Draining node k8s-worker$i from cluster..."
                vagrant ssh k8s-master -c "kubectl drain k8s-worker$i --ignore-daemonsets --delete-emptydir-data --force" || true
                vagrant ssh k8s-master -c "kubectl delete node k8s-worker$i" || true
            fi
        done
    fi
    
    log "Cluster scaled successfully!"
    cluster_status
}

cluster_down() {
    log "Destroying Kubernetes cluster..."
    vagrant destroy -f
    
    # Clean up generated files
    [ -f kubeadm-join.sh ] && rm kubeadm-join.sh
    [ -d .kube ] && rm -rf .kube
    
    log "Cluster destroyed successfully!"
}

cluster_status() {
    local current_nodes=$(get_current_nodes)
    
    if [ $current_nodes -eq 0 ]; then
        log "No cluster is currently running"
        return
    fi
    
    log "Cluster Status:"
    echo "  Current nodes: $current_nodes"
    
    echo ""
    log "Vagrant Status:"
    vagrant status
    
    echo ""
    log "Kubernetes Nodes:"
    if vagrant ssh k8s-master -c "kubectl get nodes" 2>/dev/null; then
        true
    else
        warn "Could not connect to Kubernetes API"
    fi
    
    echo ""
    log "Cluster Info:"
    vagrant ssh k8s-master -c "kubectl cluster-info" 2>/dev/null || warn "Could not get cluster info"
}

ssh_node() {
    local node=${1:-master}
    
    case $node in
        master)
            vagrant ssh k8s-master
            ;;
        worker1|worker2|worker3)
            vagrant ssh "k8s-$node"
            ;;
        *)
            error "Invalid node name. Use: master, worker1, worker2, or worker3"
            ;;
    esac
}

show_logs() {
    local node=${1:-master}
    
    case $node in
        master)
            vagrant ssh k8s-master -c "sudo journalctl -u kubelet -f"
            ;;
        worker1|worker2|worker3)
            vagrant ssh "k8s-$node" -c "sudo journalctl -u kubelet -f"
            ;;
        *)
            error "Invalid node name. Use: master, worker1, worker2, or worker3"
            ;;
    esac
}

kubectl_cmd() {
    if [ $# -eq 0 ]; then
        error "Please provide a kubectl command"
    fi
    
    vagrant ssh k8s-master -c "kubectl $*"
}

# Parse options
while [[ $# -gt 0 ]]; do
    case $1 in
        --memory=*)
            export NODE_MEMORY="${1#*=}"
            shift
            ;;
        --cpus=*)
            export NODE_CPUS="${1#*=}"
            shift
            ;;
        --k8s-version=*)
            export K8S_VERSION="${1#*=}"
            shift
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

# Main command handling
check_vagrant
check_virtualbox

case ${1:-""} in
    up)
        cluster_up $2
        ;;
    scale)
        cluster_scale $2
        ;;
    down)
        cluster_down
        ;;
    status)
        cluster_status
        ;;
    ssh)
        ssh_node $2
        ;;
    logs)
        show_logs $2
        ;;
    kubectl)
        shift
        kubectl_cmd "$@"
        ;;
    setup-kubectl)
        setup_host_kubectl
        ;;
    reset-kubectl)
        reset_host_kubectl
        ;;
    "")
        print_usage
        exit 1
        ;;
    *)
        error "Unknown command: $1"
        ;;
esac