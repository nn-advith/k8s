#!/bin/bash


   ## create temp user-data by using the spec.json file
    ## use that to create a seed iso that basically is mounted and executed befor the core os iso
    ## create n vms and use the seed iso to create N vms

VMNAME="ubuntu-vm"
ISOPATH="$HOME/iso/ubuntu-25.04-live-server-amd64.iso"
SEEDISOPATH="$PWD/seed.iso"
VDI="$HOME/VirtualBox VMs/${VMNAME}/${VMNAME}.vdi"

SPECJSONPATH=""


function usage() {
    # sh singlevm.sh -i spec.json
    echo -e "\nUsage:"
    echo -e "\tbash singlevm.sh --input|-i <SPEC JSON file path> [--help|-h]"
}

function validateMangatoryFlags() {
    if [[ -z $SPECJSONPATH ]];then
        echo -e "ERROR: --input is mandatory"
        usage
        exit 1
    fi
    if [[ ! -f "$SPECJSONPATH" ]];then
        echo -e "ERROR: input json [$SPECJSONPATH] not found"
        exit 1
    fi
}

function preExecCheck() {
    # check for guest-additions package and cloud-localds
    # asssumes Ubuntu HOST machine
    # can be modified to get type of HOST OS and suggest installation commands
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
        echo -e "ERROR: Required pacakges not found; please install to proceed"
        for i in "${missing[@]}";do
            echo -e "  - $(echo $i | cut -d ';' -f 1)\n    INSTALL: $(echo $i | cut -d ';' -f 2)"
        done
        echo -e "\033[031mAborting\033[0m"
        exit 1
    else
        echo -e "\033[032mPre-Exec Checks done\033[0m"
    fi
}

function preExecInputValidation() {
    # check if inputs are valid
    if ! jq empty $SPECJSONPATH 2>/dev/null;then
        echo -e "ERROR: JSON validation failed for $SPECJSONPATH \n\033[031mAborting\033[0m"
        exit 1
    fi


    jq -c '.vms[]' "$SPECJSONPATH" | while read -r vminfo; do
        # echo "VMINFO: $vminfo"
        jq -r ".nics[1].address" <<< "$vminfo"
    done
}

# function installSingleVM() {

# }

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

# cp "$PWD/user-data.yaml" "$PWD/user-data"
# cloud-localds seed.iso "$PWD/user-data"


# alias vbm="VBoxManage"

# vbm createvm --name "${VMNAME}" --register
# vbm modifyvm "${VMNAME}" --memory 4096 --cpus 2 --ostype Ubuntu_64 --nic1 nat
# vbm modifyvm "${VMNAME}" --nic2 hostonly --hostonlyadapter2 vboxnet0 # probably customise this
# vbm createmedium disk --filename "${VDI}" --size 20000
# vbm storagectl "${VMNAME}" --name "SATA-C0" --add sata --controller IntelAHCI
# vbm storageattach "${VMNAME}" --storagectl "SATA-C0" --port 0 --device 0 --type hdd --medium "${VDI}"
# vbm storageattach "${VMNAME}" --storagectl "SATA-C0" --port 1 --device 0 --type dvddrive --medium "${ISOPATH}"
# vbm storageattach "${VMNAME}" --storagectl "SATA-C0" --port 2 --device 0 --type dvddrive --medium "${SEEDISOPATH}"

# vbm startvm "${VMNAME}" --type=headless