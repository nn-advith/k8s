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
# NODELENGTH=$(jq '.nodes|length' "${CLUSTERSPEC}")
NODELENGTH=1
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

sudo tee /etc/docker/daemon.json <<'DOCKER_EOF'
{ "exec-opts": ["native.cgroupdriver=systemd"],  
"log-driver": "json-file",  
"log-opts":  
{ "max-size": "100m" },  
"storage-driver": "overlay2"  
}  
DOCKER_EOF
sudo systemctl restart docker
sudo docker info | grep -i cgroup

sudo swapoff -a
sudo sed -i "/\/swap\.img/s/^/#/" /etc/fstab

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
}

function nukeArnhem() {
# wipe everything
NODELENGTH=1
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
sudo rm -f /etc/apparmor.d/docker /etc/systemd/system/etcd*
sudo rm -rf /var/lib/dockershim /var/lib/etcd /var/lib/kubelet  /var/lib/etcd2/ /var/run/kubernetes
sudo iptables -F && sudo iptables -X
sudo iptables -t nat -F && sudo iptables -t nat -X
sudo iptables -t raw -F && sudo iptables -t raw -X
sudo iptables -t mangle -F && sudo iptables -t mangle -X
sudo rm -rf /etc/docker/daemon.json 
sudo apt purge -y docker.io
sudo rm -rf /var/lib/docker /etc/docker
sudo groupdel docker || true
sudo rm -rf /var/run/docker.sock
sudo rm -rf /var/lib/containerd
sudo rm -rf /root/.docker
sudo systemctl daemon-reload
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo rm -f /etc/modules-load.d/k8s.conf
sudo rm -f /etc/sysctl.d/99-kubernetes.conf
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo sysctl --system
SSH_EOF
if [ $? -ne 0 ]; then
    logError "Something failed while wiping ${vmhost}"
    return 1
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
    echo ""
else
    nukeArnhem || exit 1
fi
# execloop || exit 1