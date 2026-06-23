# ZFS Multi-VM Live Migration Node for Unraid

A production-grade, zero-downtime virtual machine live migration orchestrator for clustered Unraid nodes. This plugin utilizes native ZFS replication streams to sync block layers before shifting live guest memory spaces across your network.

## Key Features
* **Zero-Downtime Migration**: Memory tracks transfer seamlessly via QEMU P2P pipelines.
* **Explicit Dataset Mapping**: Drops automated zpool guessing loops to prevent storage routing misalignments.
* **Inline UEFI Patching**: Normalizes alternative NVRAM vars storage layouts dynamically on the fly during data streaming.
* **Native Dropdown UI**: Standardized form configurations compliant with Unraid's modern emhttpd web layout boundaries.

---

## Prerequisites & Pre-Cluster Staging

You must configure secure passwordless SSH handshakes and match your VM vCPU emulated baseline layout properties before initiating migrations.

### 1. Configure Passwordless SSH Handshakes
Your cluster servers must be able to communicate via terminal commands without stalling for a password challenge. Run these commands on **both your servers**.

```bash
# Generate high-security keys (Press enter through all defaults)
ssh-keygen -t rsa -b 4096

# Exchange the keys between your host nodes
# FROM Server 1 (Replace with your actual Server 2 IP):
ssh-copy-id root@192.168.4.2

# FROM Server 2 (Replace with your actual Server 1 IP):
ssh-copy-id root@192.168.4.1
```
*Verification Check:* Ensure running `ssh root@COUNTERPART_IP` logs you in instantly without a password challenge prompt.

### 2. Standardize VM CPU Topologies
Because you are migrating live memory blocks across different physical processor hardware (e.g., AMD Ryzen to Intel Xeon), the virtual machine must utilize a consistent, emulated CPU architecture profile to ensure OS stability.


1. Create the ZFS dataset that will hold the vdisk for the VM.
  1.1 Ensure you have a ZFS pool for this. A fast NVME pool would be ideal.
  1.2 In the Unraid Shares Tab, create a new share that is unique to your intended VM and set the Primary storage as the ZFS pool, and Secondary storage to None.
      If you have ZFS Master Installed, this share should show up as a dataset in your zfs pool.
   
3. Create the INITIAL Source Virtual Machine
  2.1 Open the VMS Tab and select ADD VM.
  2.2 For this example, select Ubuntu as the VM template.
  2.3 Set your Unique VM Name
  2.4 Change CPU Mode to "Emulated (QEMU64)"
  2.5 Click "DESELECT ALL" to remove any pinned cpu cores
  2.6 Now in the vCPUs dropdown select your required CPU core count. (Remember that it has to be within the limits of the Source and Target Unraid Servers)
  2.7 Now set the required RAM for the VM (Remember that it has to be within the limits of the Source and Target Unraid Servers)
  2.8 In "OS Install ISO" select the ISO to use for the OS installation
  2.9 Set the Primary vDisk Location to "Manual" and set the path to: /mnt/user/<your_zfs_dataset_name>/
  2.10 Set your vDisk Size, and set vDisk Type to qcow2.
  2.11 Create the VM, start it up and complete your OS install.
   
   * Note: Any setting you make in setting up the VM has to be universal between the 2 Unraid servers. So you cant use a physical Network card passed through on Server 1 that does not exist on Server 2.
           So recomendation is to use br0 or Unraid br0.X VLANS that have been set up the same across both servers
   

## Installation Guide

Follow these steps to register the interface on both cluster host servers.

### 1. Install the Plugin Package via Web GUI
1. Navigate to the **Plugins** tab on your Unraid Dashboard.
2. Select the **Install Plugin** sub-tab layer.
3. Paste your public installer package manifest URL link:
   `https://githubusercontent.com`
4. Click **Install**. Repeat this step on your second server.

### 2. Map Your Cluster Virtual Machine Matrices
1. Go to **Settings** -> **ZFS VM Migrate** on both nodes.
2. Scroll to the bottom registration input grid forms and define your parameters:
   * **Target VM Name**: Exact name of the VM (e.g., `UbuntuMigrate_0`).
   * **Destination Host IP**: The IP of your counterpart server node.
   * **Virtual Disk Origin Share Path**: Path where your vdisk sits (e.g., `/mnt/user/VM_Migrate_0/`).
   * **Destination ZFS Dataset Path**: Explicit ZFS target dataset on the peer node (e.g., `zfs_pool/VM_Migrate_0`).
3. Click **Register Virtual Machine Node**.

---

## Operational Execution

### Method A: Native Dashboard Web GUI Page
1. Navigate to **Settings** -> **ZFS VM Migrate**.
2. Select your targeted virtual machine configuration profile from the dropdown options list box.
3. Click **Migrate Selected VM**.
4. Review the confirmation alert popup notification boundaries and click **OK**.

### Method B: Automated Command Line Terminal / Cron Toggles
To execute migrations from custom background automation cron hooks or User Scripts plugins, run this terminal row sequence:

```bash
# Stage the selected target token parameters
echo "UbuntuMigrate_0" > /tmp/zfs_active_vm

# Fire the backend migration orchestration engine script
/usr/local/emhttp/plugins/zfs_vm_migrate/zfs_vm_migrate.sh
```
