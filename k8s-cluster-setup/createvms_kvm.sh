#!/bin/bash

# TODO: 
# 

ISOPATH="/var/lib/libvirt/boot/ubuntu-25.04-live-server-amd64.iso"
SPECJSONPATH=""
HTTP_DIR="/var/www/html/autoinstall"
HTTP_HOST="localhost"
HTTP_PORT="80"
HTTP_URL="http://${HTTP_HOST}:${HTTP_PORT}"
HTTP_PATH="autoinstall"

function logError() {
    echo -e "$(date +'%d-%m-%Y %H:%M:%S %Z:') \033[31m[ERROR]\033[0m: ${1}" 
}

function logSuccess() {
    echo -e "$(date +'%d-%m-%Y %H:%M:%S %Z:') \033[32m[SUCCESS]\033[0m: ${1}" 
}

function logStart() {
    echo -e "$(date +'%d-%m-%Y %H:%M:%S %Z:') \033[33m[BEGIN]\033[0m: ${1}"
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
    echo -e "\tbash singlevm.sh --input|-i <SPEC JSON file path> [--help|-h]"
}

function execwithlog() {
    "$@"  || {
        logError "Command failed: $*"
        return 1
    }
}


function validateMangatoryFlags() {
    logStart "Flag check"
    if [[ -z $SPECJSONPATH ]];then
        logError "--input is mandatory"
        usage
        return 1
    fi
    if [[ ! -f "$SPECJSONPATH" ]];then
        logError "input json [$SPECJSONPATH] not found"
        return 1
    fi
    logSuccess "Mandatory flags present"
    return 0
}

function preExecInputValidation() {
    logStart "Input validation"
    # check if inputs are valid
    if ! jq empty $SPECJSONPATH 2>/dev/null;then
        logError "JSON validation failed for $SPECJSONPATH"
        logError "Aborting"
        return 1
    fi
    logSuccess "Valid spec"
    return 0
}

function preExecCheck() {
    # check if user has permissions to run virsh commands, check if kvm is running\
    logStart "Check for KVM virtualization and helpers"
    status=0
    if ! command -v virt-install > /dev/null;then
        logError "virt-install command not found"
        status=1
    fi
    if ! command -v virsh > /dev/null;then
        logError "virsh command not found"
        status=1
    fi
    if ! lsmod | grep -q kvm;then
        logError "kvm virtualisation not enabled"
        status=1
    fi
    # if ! systemctl is-active --quiet libvirtd ; then 
    if ! virsh list --all > /dev/null 2>&1;then
        logError "libvirtd is not active"
        status=1
    fi
    if ! curl -fsS "${HTTP_URL}/" > /dev/null;then
        logError "http server not running"
        status=1
    fi
    if [[ ${status} -eq 1 ]];then
        logError "preExecCheck failed; exiting"
        return 1
    else 
        logSuccess "preExecCheck passed; continuing"
        return 0
    fi

}


function generateUserData() {
    vminfo=$1
    if [[ -z "$vminfo" ]];then
        logError "vm spec not found; Aborting"
        return 1
    fi
    vmname=$(jq -r '.vmname' <<< $vminfo)
    logStart "user-data generate: $vmname"

    execwithlog cp user-data.yaml "user-data-${vmname}"
    execwithlog cp meta-data.yaml "meta-data-${vmname}"

    # create meta-data
    execwithlog sed -i "s/INSTANCEID/${vmname}/" "meta-data-${vmname}"
    execwithlog sed -i "s/HOSTNAME/${vmname}/" "meta-data-${vmname}"

     # replace user related
    execwithlog sed -i "s/USERNAME/$(jq -r '.username' <<< ${vminfo})/" "user-data-${vmname}"
    execwithlog sed -i "s|PASSWORD|\'$(jq -r '.password' <<< ${vminfo} | xargs mkpasswd -m sha-512)\'|" "user-data-${vmname}"
    execwithlog sed -i "s/HOSTNAME/\'$(jq -r '.hostname' <<< ${vminfo})\'/" "user-data-${vmname}"

    # ssh related
    execwithlog sed -i "s/SSH_INSTALL_SERVER/$(jq -r '.ssh.["install-ssh-server"]' <<< ${vminfo})/" "user-data-${vmname}"
    execwithlog sed -i "s/SSH_ALLOW_PW/$(jq -r '.ssh["allow-pw"]' <<< ${vminfo})/" "user-data-${vmname}"
    execwithlog sed -i "s|AUTHORIZED_KEYS|$(jq -rc '.ssh.authorized' <<< ${vminfo} | tr -d '[]')|" "user-data-${vmname}" # sed can change delimiter waaaw

    # nic related : assuming 2 nics for now; STUPID asssumption but ok
    niclength=$(jq '.nics | length' <<< "${vminfo}")
    for ((j=0; j<niclength; j++)); do
        nicinfo=$(jq -rc ".nics[$j]" <<< ${vminfo})
        uindex=$((j+1))
        interfacename="enp${uindex}s0"
        if [[ $(jq -r ".dhcp" <<< ${nicinfo}) == "true" ]];then
            # remove addresses namesserver etc
            startline=$(( $(grep -n -m1 "NIC0${uindex}_DHCP" "user-data-${vmname}" | cut -d: -f1 )+1 ))
            endline=$((startline+2))
            execwithlog sed -i "${startline},${endline}d" "user-data-${vmname}"
            execwithlog sed -i "0,/NIC_0${uindex}/s/NIC_0${uindex}/${interfacename}/" "user-data-${vmname}"
            execwithlog sed -i "s/NIC0${uindex}_DHCP/$(jq -r '.dhcp' <<< ${nicinfo})/" "user-data-${vmname}"
        else
            execwithlog sed -i "0,/NIC_0${uindex}/s/NIC_0${uindex}/${interfacename}/" "user-data-${vmname}"
            execwithlog sed -i "s/NIC0${uindex}_DHCP/$(jq -r '.dhcp' <<< ${nicinfo})/" "user-data-${vmname}"
            # addresses and nameservers
            execwithlog sed -i "s|NIC0${uindex}_ADDRESSES|$(jq -rc '.address' <<< ${nicinfo} | tr -d '[]')|" "user-data-${vmname}"
            execwithlog sed -i "s|NIC0${uindex}_DNS|$(jq -rc '.dns' <<< ${nicinfo} | tr -d '[]')|" "user-data-${vmname}"
        fi
    done

    #move user-data to http server
    log "Deleting existing user-data and meta-data dir"
    execwithlog rm -rf "${HTTP_DIR}/${vmname}"
    execwithlog mkdir -p "${HTTP_DIR}/${vmname}"
    execwithlog mv "user-data-${vmname}" "${HTTP_DIR}/${vmname}/user-data"
    execwithlog mv "meta-data-${vmname}" "${HTTP_DIR}/${vmname}/meta-data"

    return 0
}


function createVM() {
    logStart "Creating VM: ${vmname}"
    vminfo=$1
    if [[ -z "$vminfo" ]];then
        logError "vm spec not found; Aborting"
        return 1
    fi
    vmname=$(jq -r '.vmname' <<< $vminfo)

    # check if user-data and meta-data are accessible
    if ! curl -fsS "${HTTP_URL}/${HTTP_PATH}/${vmname}/user-data" > /dev/null;then
        logError "user-data not accessible for ${vmname}"
        return 1
    fi

    if ! curl -fsS "${HTTP_URL}/${HTTP_PATH}/${vmname}/meta-data" > /dev/null;then
        logError "meta-data not accessible for ${vmname}"
        return 1
    fi
    
    cmd=(
        virt-install 
        --name "${vmname}" 
        --ram $(jq -r '.memory' <<< $vminfo) 
        --vcpus $(jq -r '.cpu' <<< $vminfo) 
        --extra-args "console=ttyS0,115200n8 autoinstall ds=nocloud-net;s=http://_gateway/autoinstall/${vmname}/" \
        --graphics none 
        --noautoconsole
    )

    niclength=$(jq '.nics | length' <<< "${vminfo}")
    for ((j=0; j<niclength; j++)); do
        nicinfo=$(jq -rc ".nics[$j]" <<< ${vminfo})
        # uindex=$((i+1))
        cmd+=( --network network=$(jq -r '.name' <<< ${nicinfo}),model=$(jq -r '.model' <<< ${nicinfo}) )
    done

    storagelength=$(jq '.storage | length' <<< "${vminfo}")
    for ((j=0; j<storagelength; j++)); do
        storageinfo=$(jq -rc ".storage[$j]" <<< ${vminfo})
        # uindex=$((i+1))
        cmd+=( --disk size=$(jq -r '.size' <<< ${storageinfo}),format=$(jq -r '.format' <<< ${storageinfo}),bus=$(jq -r '.bus' <<< ${storageinfo}) )
    done
    cmd+=( --location "${ISOPATH}" )

    log "Starting VM installation for ${vmname}"

    execwithlog "${cmd[@]}"
    # "${cmd[@]}"
    
    return 0
}


function installVMs() {
    logStart "Starting VM installation"
    ## create user data and copy to the userdata dir; assume userdata autoinstall dir

    VM_SPEC_COUNT=$(jq '.vms | length' "$SPECJSONPATH")
    echo $VM_SPEC_COUNT
    for ((i=0; i<VM_SPEC_COUNT; i++)); do
        vminfo=$(jq -c ".vms[$i]" "$SPECJSONPATH")
        # echo $vminfo
        # echo "vm-${i}"
        generateUserData "${vminfo}"
        retval=$?
        if [[ $retval -eq 1 ]];then
            logError "user-data generation failed for $(jq -r '.vmname' <<< $vminfo)"
            return 1
        fi
        createVM "${vminfo}"
        retval=$? 
        # echo "Checking for ${i}"
        if [[ $retval -eq 1 ]];then
            logError "vm creation failed for $(jq -r '.vmname' <<< $vminfo)"
            return 1
        fi
    done
    return 0
}

function waitForShutOff() {
    # arg = vmname
    vmname="${1}"
    iter=0
    maxiter=45
    while [[ ${iter} -lt ${maxiter} ]]; do
        if [[ "$(virsh domstate ${vmname})" == "shut off" ]];then
            return 0
        else 
            log "WAIT: VM ${vmname} is still runnning; waiting for shutoff"
            sleep 20
            ((iter++))
        fi
    done
    return 1
    
}

function startVM() {
    # arg = vmname, vmip
    vmname="${1}"
    logStart "Starting VM ${vmname}"
    virsh start "${vmname}" > /dev/null 2>&1 || return 1
    logStart "Started VM ${vmname}"
    return 0
}

function waitForSSH() {
    # wait for ssh
    vmname="${1}"
    vmip="${2}"
    iter=1
    maxiter=120
    while [[ ${iter} -lt ${maxiter} ]];do
        if nc -z "${vmip}" 22 > /dev/null 2>&1;then
            return 0
        fi
        log "vm ${vmname}:${vmip} waiting for ssh"
        sleep 10
        ((iter++))
    done
    return 1
}

function postInstallVerification() {
    # if installVMs is successful, wait for each VM to move to shutoff state
    # reboot and ssh check
    VM_SPEC_COUNT=$(jq '.vms | length' "$SPECJSONPATH")
    for ((i=0; i <VM_SPEC_COUNT; i++));do
        vmname=$(jq -r ".vms[${i}].vmname" "$SPECJSONPATH")
        vmhostname=$(jq -r ".vms[${i}].hostname" "$SPECJSONPATH")
        vmip=$(jq -r ".vms[${i}].nics[1].address[0]" "$SPECJSONPATH"  | cut -d/ -f1)
        # /etc/hosts update
        if ! grep -q "${vmip}" /etc/hosts;then 
            echo "${vmip} ${vmhostname}" | sudo tee -a /etc/hosts > /dev/null || {
                logWarn "failed appending entry to /etc/hosts: ${vmip} ${vmhostname} (ignored)"
            }
        else
            logWarn "${vmip} already present in /etc/hosts; ignoring"
        fi
        waitForShutOff "${vmname}" || {
            logError "VM ${vmname}:${vmip} failed to shut off. Aborting"
            return 1
        }
        startVM "${vmname}" || {
            logError "VM ${vmname} failed to start. Aborting"
            return 1
        }
        waitForSSH "${vmname}" "${vmip}" || {
            logError "SSH not reachable on ${vmname}:"
            return 1
        }
    done
    return 0
}



#begin
while [[ $# -gt 0 ]];do
    case "$1" in
        -i|--input)
            SPECJSONPATH="$2"
            shift 2
        ;;
        -h|--help)
            usage
            exit 0
        ;;
        *)
            echo "unknown flag $1"
            usage
            exit 1
        ;;
    esac
done

validateMangatoryFlags || exit 1
preExecInputValidation || exit 1
preExecCheck || exit 1

installVMs || exit 1

postInstallVerification || exit 1

# by default post installation the vms will be shutoff, wait for shutoff and reboot
# perform ssh check using nc -z to verify installation
# wait till all vms are verified, then exit