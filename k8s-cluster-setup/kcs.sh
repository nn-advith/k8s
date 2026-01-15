#!/bin/bash

# Simple script to bring up k8-s cluster on N master nodes and M worker nodes, with ability to wipe a cluster clean as well.
# Input: master node and worker node ips, login details of user. that shoule be enough i think. json is fine?
# Ouput: none; cluster should be up
#
# 2 modes: Install cluster and Uninstall cluster
# assume passwordless ssh - check for this

# temp nodespec - better to run this as a separate script. not related to post-install-scripts
# nodespec={
#     "control-plane": [
#         {
#             "hostname": "",
#             "username": "",
#         },
#     ],
#     "workers": [
#         {
#             "hostname": "",
#             "username": "",
#         },
#         {},
#     ]

# }

# TODO:
# Allow one more operation to proceed with just cluster initialisation, assuming bootstrap is successful.
# Control plane join node ( certs )
# pod network enabling - maybe customise this to support different CNI
# improve logging so that only command status is logged to stdout; command logs to be redireted to log files within nodes ( 
# or maybe a timestamped log file on host idk)

CLUSTERSPEC=""
# allowed operations: deploy, remove
OPERATION=""

function logError() {
    echo -e "$(date +'%d-%m-%Y %H:%M:%S %Z:') \033[31m[ERROR]\033[0m: ${1}" 
}

function logSuccess() {
    echo -e "$(date +'%d-%m-%Y %H:%M:%S %Z:') \033[32m[SUCCESS]\033[0m: ${1}" 
}

function log() {
    echo -e "$(date +'%d-%m-%Y %H:%M:%S %Z:') ${1}"
}

function logWarn() {
    echo -e "$(date +'%d-%m-%Y %H:%M:%S %Z:') \033[33m[WARN]\033[0m: ${1}"
}

function usage() {
    # sh singlevm.sh -i spec.json
    echo -e "\nUsage:"
    echo -e "\tbash kcs.sh --spec|-s <SPEC PATH> --operation|-o <OPERATION>"
    echo -e "\n\t--spec|-s        -   Path to the cluster spec json file"
    echo -e "\t--operation|-o   -   Cluster operation; Supported: deploy, remove"
    echo -e "\t--help|-h        -   Help"
}

# functions
function preFlight() {
    if [[ -z $CLUSTERSPEC ]];then
        echo "--spec is mandatory"
        usage
        return 1
    fi
    if [[ ! -f "$CLUSTERSPEC" ]];then
        echo "input json [$CLUSTERSPEC] not found"
        return 1
    fi
    if [[ -z $OPERATION ]];then
        echo "--operation is mandatory"
        usage
        return 1
    fi
    if [[ "${OPERATION}" != "deploy" && "${OPERATION}" != "remove" ]];then
        echo "Undefined operation ${OPERATION}"
        usage
        exit 1
    fi
    return 0
}

function inputValidation() {
    log "Input validation"
    # check if inputs are valid
    if ! jq empty $CLUSTERSPEC 2>/dev/null;then
        logError "JSON validation failed for ${CLUSTERSPEC}"
        logError "Aborting"
        return 1
    fi
    logSuccess "Valid spec"
    return 0
}


function bootstrap() {
# for each VM run the common commands
    NODELENGTH=$(jq '.nodes|length' "${CLUSTERSPEC}")
    # NODELENGTH=1
    for((i=0; i<NODELENGTH; i++));do
        vmuser=$(jq -r ".nodes[$i].username" "${CLUSTERSPEC}")
        vmhost=$(jq -r ".nodes[$i].hostname" "${CLUSTERSPEC}")

# exec here; dump and fail fck it
ssh -o BatchMode=yes -o ConnectTimeout=5 "${vmuser}@${vmhost}" 'bash -s' <<-'SSH_EOF'
set -euo pipefail
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl  
sudo systemctl enable --now kubelet

kubeadm version

sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd

sudo swapoff -a
sudo sed -i "/^\/swap\.img/s/^/#/" /etc/fstab

sudo modprobe overlay  
sudo modprobe br_netfilter
sudo tee /etc/modules-load.d/k8s.conf <<'MOD_EOF'
overlay
br_netfilter
MOD_EOF

sudo tee /etc/sysctl.d/99-kubernetes.conf <<'SYSCTL_EOF'
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
SYSCTL_EOF
sudo sysctl --system
SSH_EOF
        if [ $? -ne 0 ]; then
            logError "Something failed while bootstrapping ${vmhost}"
            return 1
        fi
        logSuccess "Bootstrap completed for ${vmhost}"
    done
    return 0
}


function setupCluster() {
    # run 2 loops, one for control - plane and one for worker nodes
    # firt init the cluster
    # then run another loop and join control plane and worker nodes; if control plane also setup .config
    # last setup pod-nwtwork ; maybe in a different function
    initcpnode=$(jq -r '.nodes[] | select(.role=="control-plane" and .init=="true") | .hostname ' "${CLUSTERSPEC}")
    initcpuser=$(jq -r '.nodes[] | select(.role=="control-plane" and .init=="true") | .username ' "${CLUSTERSPEC}")
    if [[ $(echo "${initcpnode}" | wc -l) -gt 1 ]];then
        logError "Please restrict the number of init control-plane nodes to 1"
        return 1
    fi
    if [[ $(echo "${initcpnode}" | wc -l) -eq 0 ]];then
        logError "Please designate atleast 1 control-plane node as init node"
        return 1
    fi

    # perform init operation in init CP node.
ssh -o BatchMode=yes -o ConnectTimeout=5 "${initcpuser}@${initcpnode}" 'bash -s' <<'INIT_EOF'
MASTER_IP=$(ip -4 addr show enp2s0 | awk '/inet / {print $2}' | cut -d/ -f1)
sudo kubeadm init \
--apiserver-advertise-address "${MASTER_IP}" \
--control-plane-endpoint "${MASTER_IP}" \
--pod-network-cidr=10.244.0.0/16 \
--ignore-preflight-errors=Mem \
--upload-certs

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

INIT_EOF
    if [[ $? -ne 0 ]];then
        logError "Cluster init failed: ${initcpnode}; Aborting"
        return 1
    else
        logSuccess "Cluster initialised"
    fi

    # cluster access step is done for only one CP ndoe as of now. extend this

    # perform join operations; let's skip control plane join for now since it is a little bit longer

    WORKER_JOIN_COMMAND=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${initcpuser}@${initcpnode}" "sudo kubeadm token create --print-join-command")
    echo "${WORKER_JOIN_COMMAND}"

    while read -r username hostname; do
        if ssh -n -o BatchMode=yes -o ConnectTimeout=5 \
            "${username}@${hostname}" "sudo ${WORKER_JOIN_COMMAND}"; then
            logSuccess "Worker ${hostname} joined cluster."
        else
            logError "Join Command failed for worker: ${hostname}"
        fi
    done < <(jq -r '.nodes[] | select(.role=="worker") | "\(.username) \(.hostname)"' "${CLUSTERSPEC}")

    return 0
}

function nukeArnhem() {
# wipe everything
NODELENGTH=$(jq '.nodes|length' "${CLUSTERSPEC}")
for((i=0; i<NODELENGTH; i++));do
vmuser=$(jq -r ".nodes[$i].username" "${CLUSTERSPEC}")
vmhost=$(jq -r ".nodes[$i].hostname" "${CLUSTERSPEC}")

# swap will be kept off; does not impact much anyway
ssh -o BatchMode=yes -o ConnectTimeout=5 "${vmuser}@${vmhost}" 'bash -s' <<-'SSH_EOF'
set -euo pipefail
sudo kubeadm reset -f

sudo rm -rf /etc/cni/net.d
sudo rm -rf /run/flannel
sudo rm -rf /var/lib/cni
sudo ip link delete flannel.1 2>/dev/null || true
sudo ip link delete cni0 2>/dev/null || true

sudo apt-get purge -y --allow-change-held-packages kubeadm kubectl kubelet kubernetes-cni kube*
sudo apt autoremove -y
sudo rm -rf ~/.kube
sudo rm -rf /etc/cni /etc/kubernetes
sudo rm -f /etc/systemd/system/etcd*
sudo rm -rf /var/lib/etcd /var/lib/kubelet  /var/lib/etcd2/ /var/run/kubernetes

sudo iptables -F && sudo iptables -X
sudo iptables -t nat -F && sudo iptables -t nat -X
sudo iptables -t raw -F && sudo iptables -t raw -X
sudo iptables -t mangle -F && sudo iptables -t mangle -X

sudo systemctl stop containerd || true
sudo systemctl disable containerd || true
sudo apt-get purge -y containerd containerd.io || true
sudo rm -rf /var/lib/containerd /etc/containerd /run/containerd
sudo rm -f /run/containerd/containerd.sock

sudo systemctl daemon-reexec
sudo systemctl daemon-reload

sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo rm -f /etc/modules-load.d/k8s.conf
sudo rm -f /etc/sysctl.d/99-kubernetes.conf
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo sysctl --system
SSH_EOF
if [ $? -ne 0 ]; then
    logError "Something failed while wiping ${vmhost}"
    continue
fi
logSuccess "Wipe successful for ${vmhost}"
done
return 0
}

# begin
while [[ $# -gt 0 ]];do
    case "$1" in
        -s|--spec)
            CLUSTERSPEC="$2"
            shift 2
        ;;
        -h|--help)
            usage
            exit 0
        ;;
        -o|--operation)
            OPERATION="$2"
            shift 2
        ;;
        *)
            echo "Unknown option"
            usage
            exit 1
        ;;
    esac
done

preFlight || exit 1
inputValidation || exit 1

# check if deploy, addume deploy for now
if [[ ${OPERATION} == "deploy" ]];then
    # bootstrap || exit 1
    setupCluster || exit 1
    echo ""
else
    nukeArnhem || exit 1
fi
# execloop || exit 1