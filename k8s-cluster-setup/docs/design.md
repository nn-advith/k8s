### VM Deployment script

Deploy N virtual machines on virtualbox. For now, only ubuntu autoinstall support. Add others if needed (eg: RHEL kickstart)

Input: 

spec.json       ->   contains vm configuration, post install commands / scripts.
user-data.yaml  ->   ubuntu autoinstall template. Keep baseline of what could be needed, based on spec.json enable/disable things that are not needed.

version 1 requirements:

1. Number of vms - N
2. Each VM has customisable parameters for RAM, CPUs and Storage.
3. Each VM has one HDD virtual disk. 
4. Each VM has atleast one NIC, maximum of 2 ( with consideration for more; no scope of bonds).
5. Each VM NIC can be either hostonly or nat; if hostonly it should select any one from available list. (maybe scope for creating dynamically if not present)
6. Each VM gets one virtual SATA storage controller; mounted with vHDD, bootISO and seedISO.
7. Post installation: the bootISO and seedISO must be unmounted; post install commands to be executed; restarted (if needed)
8. Additional post installation setup; after reboot- execute script/commands based on use case ( example: bring up a k8s cluster ) [Check if script needed or post-install commands from autoinstall script is enough; script will be reusable across differed OS]

---

## KVM VM deployment design

Input:  spec.json -> contains vm configuration (for now), post install commands and scripts ( future; may not be needed, can probably be added as curtain in )
user-data.yaml -> user-data template
meta-data.yaml -> meta-data template

v1:

1. spec.json contains n number of VM definitions
2. For ech VM, generate user-data and meta-data files, expose them via the nginx http server ( easier compared to bundling with iso )
3. Create virt-install command dynamically and execute command
4. Each vm will shutoff post installation; Reboot and verify installation.
5. Post-reboot script execution.4

\# Post install Script
 - post-install-script will contain n scipts
 - for each script per vm, remotely execute the script in order using ssh
 - if any script fails, terminate the script execution for that vm and proceed to next with logging
 - also log in the vm for later checks


