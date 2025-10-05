#!/bin/bash



VMNAME="ubuntu-vm"
ISOPATH="$HOME/iso/ubuntu-25.04-live-server-amd64.iso"
SEEDISOPATH="$PWD/seed.iso"
VDI="$HOME/VirtualBox VMs/${VMNAME}/${VMNAME}.vdi"
# preinstall steps that need to be done on hopst machine:
# sudo apt-get install virtualbox-guest-additions-iso  -- for --install-additions to work
# sudo apt-get install cloud-utils -- for seed.iso and user-data
# (OR equivalent in other os)

cp "$PWD/user-data.yaml" "$PWD/user-data"
cloud-localds seed.iso "$PWD/user-data"

function unmount

alias vbm="VBoxManage"

vbm createvm --name "${VMNAME}" --register
vbm modifyvm "${VMNAME}" --memory 4096 --cpus 2 --ostype Ubuntu_64 --nic1 nat
vbm modifyvm "${VMNAME}" --nic2 hostonly --hostonlyadapter2 vboxnet0 # probably customise this
vbm createmedium disk --filename "${VDI}" --size 20000
vbm storagectl "${VMNAME}" --name "SATA-C0" --add sata --controller IntelAHCI
vbm storageattach "${VMNAME}" --storagectl "SATA-C0" --port 0 --device 0 --type hdd --medium "${VDI}"
vbm storageattach "${VMNAME}" --storagectl "SATA-C0" --port 1 --device 0 --type dvddrive --medium "${ISOPATH}"
vbm storageattach "${VMNAME}" --storagectl "SATA-C0" --port 2 --device 0 --type dvddrive --medium "${SEEDISOPATH}"

vbm startvm "${VMNAME}" --type=headless