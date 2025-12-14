#!/bin/bash


   ## create temp user-data by using the spec.json file
    ## use that to create a seed iso that basically is mounted and executed befor the core os iso
    ## create n vms and use the seed iso to create N vms

# VMNAME="ubuntu-vm"
ISOPATH="$HOME/iso/ubuntu-25.04-live-server-amd64.iso"
SEEDISOPATH="$PWD/seed.iso"
VDI="$HOME/VirtualBox VMs/${VMNAME}/${VMNAME}.vdi"

SPECJSONPATH=""

alias vbm="VBoxManage"

function logError() {
    echo -e "\033[31mERROR\033[0m: ${1}" 
}

function logSuccess() {
    echo -e "\033[32mSUCCESS\033[0m: ${1}" 
}

function logStart() {
    echo -e "\033[33m[BEGIN]\033[0m: ${1}"
}

function usage() {
    # sh singlevm.sh -i spec.json
    echo -e "\nUsage:"
    echo -e "\tbash singlevm.sh --input|-i <SPEC JSON file path> [--help|-h]"
}

function validateMangatoryFlags() {
    logStart "Flag check"
    if [[ -z $SPECJSONPATH ]];then
        logError "--input is mandatory"
        usage
        exit 1
    fi
    if [[ ! -f "$SPECJSONPATH" ]];then
        logError "input json [$SPECJSONPATH] not found"
        exit 1
    fi
    logSuccess "Mandatory flags present"
}

function preExecCheck() {
    # check for guest-additions package and cloud-localds
    # asssumes Ubuntu HOST machine
    # can be modified to get type of HOST OS and suggest installation commands
    logStart "Pre-Exec Checks"
    missing=()
    if ! which VBoxManage &> /dev/null;then
        missing+=("VBoxManage;sudo apt-get install virtualbox")
    fi
    if ! which cloud-localds &> /dev/null;then
        missing+=("cloud-localds;sudo apt-get install cloud-utils")
    fi
    if ! dpkg -l | grep '^ii' | grep -q virtualbox-guest-additions-iso; then
        missing+=("virtualbox-guest-additions-iso;sudo apt-get install virtualbox-guest-additions-iso")
    fi
    if [[ ${#missing[@]} -gt 0 ]];then 
        logError "Required pacakges not found; please install to proceed"
        for i in "${missing[@]}";do
            echo -e "  - $(echo $i | cut -d ';' -f 1)\n    INSTALL: $(echo $i | cut -d ';' -f 2)"
        done
        logError "Aborting"
        exit 1
    else
        logSuccess "Pre-Exec checks done"
    fi
}

function preExecInputValidation() {
    logStart "Input validation"
    # check if inputs are valid
    if ! jq empty $SPECJSONPATH 2>/dev/null;then
        logError "JSON validation failed for $SPECJSONPATH"
        logError "Aborting"
        exit 1
    fi
    logSuccess "Valid spec"
}

function generateUserData() {
    vminfo=$1

    if [[ -z "$vminfo" ]];then
        logError "vm spec not found; Aborting"
        exit 1
    fi
    vmname=$(jq -r '.vmname' <<< $vminfo)
    logStart "user-data generate: $vmname"

    cp user-data.yaml user-data-$vmname

    # replace user related
    sed -i "s/USERNAME/$(jq -r '.username' <<< ${vminfo})/" "user-data-${vmname}"
    sed -i "s|PASSWORD|\'$(jq -r '.password' <<< ${vminfo} | xargs mkpasswd -m sha-512)\'|" "user-data-${vmname}"
    sed -i "s/HOSTNAME/\'$(jq -r '.hostname' <<< ${vminfo})\'/" "user-data-${vmname}"

    # ssh related
    sed -i "s/SSH_INSTALL_SERVER/$(jq -r '.ssh.["install-ssh-server"]' <<< ${vminfo})/" "user-data-${vmname}"
    sed -i "s/SSH_ALLOW_PW/$(jq -r '.ssh["allow-pw"]' <<< ${vminfo})/" "user-data-${vmname}"
    sed -i "s|AUTHORIZED_KEYS|$(jq -rc '.ssh.authorized' <<< ${vminfo} | tr -d '[]')|" "user-data-${vmname}" # sed can change delimiter waaaw

    # nic related : assuming 2 nics for now; STUPID asssumption but ok
    niclength=$(jq '.nics | length' <<< "${vminfo}")
    for ((i=0; i<niclength; i++)); do
        nicinfo=$(jq -rc ".nics[$i]" <<< ${vminfo})
        uindex=$((i+1))
        interfacename=""
        if [[ $i -eq 0 ]];then
            interfacename="enp0s3"
        else
            interfacename="enp0s8"
        fi
        if [[ $(jq -r ".dhcp" <<< ${nicinfo}) == "true" ]];then
            # remove addresses namesserver etc
            startline=$(( $(grep -n -m1 "NIC0${uindex}_DHCP" "user-data-${vmname}" | cut -d: -f1 )+1 ))
            endline=$((startline+2))
            sed -i "${startline},${endline}d" "user-data-${vmname}"
            sed -i "0,/NIC_0${uindex}/s/NIC_0${uindex}/${interfacename}/" "user-data-${vmname}"
            sed -i "s/NIC0${uindex}_DHCP/$(jq -r '.dhcp' <<< ${nicinfo})/" "user-data-${vmname}"
        else
            sed -i "0,/NIC_0${uindex}/s/NIC_0${uindex}/${interfacename}/" "user-data-${vmname}"
            sed -i "s/NIC0${uindex}_DHCP/$(jq -r '.dhcp' <<< ${nicinfo})/" "user-data-${vmname}"
            # addresses and nameservers
            sed -i "s|NIC0${uindex}_ADDRESSES|$(jq -rc '.address' <<< ${nicinfo} | tr -d '[]')|" "user-data-${vmname}"
            sed -i "s|NIC0${uindex}_DNS|$(jq -rc '.dns' <<< ${nicinfo} | tr -d '[]')|" "user-data-${vmname}"
        fi
    done
}

function registerVM() {
    # create seed iso
    vminfo=$1
    if [[ -z "$vminfo" ]];then
        logError "vm spec not found; Aborting"
        exit 1
    fi
    vmname=$(jq -r '.vmname' <<< $vminfo)
    vdi="$HOME/VirtualBox VMs/${vmname}/${vmname}.vdi"

    cloud-localds "seed-${vmname}.iso" "$PWD/user-data-${vmname}"
    vbm createvm --name "${vmname}" --register
    vbm modifyvm "${vmname}" --memory $(jq -r '.memory' <<< $vminfo) --cpus $(jq -r '.cpus' <<< $vminfo) --ostype $(jq -r '.ostype' <<< $vminfo) --nic1 $(jq -r '.nics[0].type' <<< $vminfo)
    vbm modifyvm "${vmname}" --nic2 $(jq -r '.nics[1].type' <<< $vminfo) --hostonlyadapter2 $(jq -r '.nics[1].adapter' <<< $vminfo) # probably customise this
    vbm createmedium disk --filename "${vdi}" --size 20000
    # vbm storagectl "${VMNAME}" --name "SATA-C0" --add sata --controller IntelAHCI
    # vbm storageattach "${VMNAME}" --storagectl "SATA-C0" --port 0 --device 0 --type hdd --medium "${VDI}"
    # vbm storageattach "${VMNAME}" --storagectl "SATA-C0" --port 1 --device 0 --type dvddrive --medium "${ISOPATH}"
    # vbm storageattach "${VMNAME}" --storagectl "SATA-C0" --port 2 --device 0 --type dvddrive --medium "${SEEDISOPATH}"

}

function installSingleVM() {
    # generateuser data
    # create vm and setup

    VM_SPEC_COUNT=$(jq '.vms | length' "$SPECJSONPATH")
    for ((i=0; i<VM_SPEC_COUNT; i++)); do
        vminfo=$(jq -c ".vms[$i]" "$SPECJSONPATH")
        # echo $vminfo
        generateUserData "${vminfo}"
        # registerVM $vminfo
    done
}

# function unmountiso() {

# }

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

validateMangatoryFlags
preExecInputValidation
preExecCheck

# begin
# generateUserData
installSingleVM

# cp "$PWD/user-data.yaml" "$PWD/user-data"
# cloud-localds seed.iso "$PWD/user-data"




# vbm createvm --name "${VMNAME}" --register
# vbm modifyvm "${VMNAME}" --memory 4096 --cpus 2 --ostype Ubuntu_64 --nic1 nat
# vbm modifyvm "${VMNAME}" --nic2 hostonly --hostonlyadapter2 vboxnet0 # probably customise this
# vbm createmedium disk --filename "${VDI}" --size 20000
# vbm storagectl "${VMNAME}" --name "SATA-C0" --add sata --controller IntelAHCI
# vbm storageattach "${VMNAME}" --storagectl "SATA-C0" --port 0 --device 0 --type hdd --medium "${VDI}"
# vbm storageattach "${VMNAME}" --storagectl "SATA-C0" --port 1 --device 0 --type dvddrive --medium "${ISOPATH}"
# vbm storageattach "${VMNAME}" --storagectl "SATA-C0" --port 2 --device 0 --type dvddrive --medium "${SEEDISOPATH}"

# vbm startvm "${VMNAME}" --type=headless