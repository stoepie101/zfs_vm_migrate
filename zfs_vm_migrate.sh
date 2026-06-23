#!/bin/bash
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
JSON_FILE="/boot/config/plugins/zfs_vm_migrate/zfs_vm_migrate.json"

if [ ! -f "$JSON_FILE" ]; then echo "CRITICAL ERROR: Settings missing." >&2; exit 1; fi

if [[ "$1" == *"&arg1="* ]]; then
    QUERY_VM=$(echo "$1" | sed -n 's/.*&arg1=\([^&]*\).*/\1/p' | sed 's/%20/ /g')
else
    QUERY_VM=$(echo "$1" | sed -e 's/[^a-zA-Z0-9_]//g')
fi
if [ -z "$QUERY_VM" ] && [ -n "$2" ]; then QUERY_VM=$(echo "$2" | sed -e 's/[^a-zA-Z0-9_]//g'); fi
if [ -z "$QUERY_VM" ] && [ -f "/tmp/zfs_active_vm" ]; then QUERY_VM=$(cat /tmp/zfs_active_vm | sed -e 's/[^a-zA-Z0-9_]//g'); fi

if [ -z "$QUERY_VM" ]; then echo "CRITICAL ERROR: No active target." >&2; exit 1; fi

TIMEOUT_DURATION=$(jq -r '.GLOBAL_TIMEOUT // "5m"' "$JSON_FILE")
MIN_FREE_SPACE_PERCENT=$(jq -r '.GLOBAL_PADDING // "10"' "$JSON_FILE")
VM_MATCH=$(jq -r --arg name "$QUERY_VM" '.VMS[] | select(.name==$name)' "$JSON_FILE")

if [ -z "$VM_MATCH" ]; then echo "CRITICAL ERROR: VM not registered." >&2; exit 1; fi

VM_NAME=$(echo "$VM_MATCH" | jq -r '.name')
TARGET_SERVER_IP=$(echo "$VM_MATCH" | jq -r '.ip')
DEFAULT_MIGRATE_SHARE=$(echo "$VM_MATCH" | jq -r '.share')
remote_dataset=$(echo "$VM_MATCH" | jq -r '.target_ds')

SNAPSHOT_NAME="${VM_NAME}_Migration_Action"
LOCAL_MIGRATE="false"
SCRIPT_DIR_NAME="zfs_vm_migrate"
TARGET_VM_SCRIPT_LOCATION="/usr/local/emhttp/plugins/zfs_vm_migrate/zfs_vm_migrate.sh"
TIMESTAMP=$(date +%s)
CURRENT_ACTIVE_DISK_PATH=""
local_disk_dir=""
remote_disk_dir="/mnt/${remote_dataset}"
EMERGENCY_XML_BACKUP="/tmp/${VM_NAME}_migration_backup.xml"

check_utilities() {
    echo "--- Checking system utilities ---"
    local required_utils=("jq" "virsh" "zfs" "zpool" "sudo" "rsync")
    for util in "${required_utils[@]}"; do if ! command -v "$util" &> /dev/null; then echo "CRITICAL ERROR: Missing $util" >&2; exit 1; fi; done
}
validate_vm_state() {
    echo "--- Validating Origin VM State for $VM_NAME ---"
    if ! virsh list --all --name | grep -xFq "$VM_NAME"; then echo "CRITICAL ERROR: VM '$VM_NAME' does not exist." >&2; exit 1; fi
    if ! virsh list --state-running --name | grep -xFq "$VM_NAME"; then echo "CRITICAL ERROR: VM '$VM_NAME' is not active." >&2; exit 1; fi
}
setup_disk_paths() {
    local raw_xml=$(virsh dumpxml "$VM_NAME" 2>/dev/null)
    if [ -z "$raw_xml" ]; then CURRENT_ACTIVE_DISK_PATH="${DEFAULT_MIGRATE_SHARE}vdisk1.qcow2"
    else
        CURRENT_ACTIVE_DISK_PATH=$(echo "$raw_xml" | grep -m1 "<source file=" | sed -E "s/.*<source file='([^']*)'.*/\1/; s/.*<source file=\"([^\"]*)\".*/\1/")
        if [ -z "$CURRENT_ACTIVE_DISK_PATH" ]; then CURRENT_ACTIVE_DISK_PATH="${DEFAULT_MIGRATE_SHARE}vdisk1.qcow2"; fi
        echo "$raw_xml" > "$EMERGENCY_XML_BACKUP"
    fi
    local check_path="$CURRENT_ACTIVE_DISK_PATH"
    if [[ "$check_path" =~ ^/mnt/user/ ]]; then
        local share_folder=$(echo "$check_path" | cut -d'/' -f4)
        local matching_pool=""
        while read -r pool_name; do if [ -d "/mnt/${pool_name}/${share_folder}" ]; then matching_pool="/mnt/${pool_name}/${share_folder}"; break; fi; done < <(zpool list -H -o name 2>/dev/null)
        if [ -n "$matching_pool" ]; then check_path="${matching_pool}/$(echo "$check_path" | cut -d'/' -f5-)"; fi
    fi
    local_disk_dir=$(dirname "$check_path")
}
check_free_space() {
    local local_dataset=$(zfs list -H -o name "$local_disk_dir" 2>/dev/null)
    if [ -z "$local_dataset" ]; then echo "CRITICAL ERROR: Path '$local_disk_dir' does not reside on ZFS." >&2; exit 1; fi
    echo "Successfully mapped target disk to native ZFS dataset: $local_dataset"
}
copy_files_from_origin_to_target() {
    echo "--- Distributing Storage Blocks Across Network ---"
    local origin_dataset=$(zfs list -H -o name "$local_disk_dir" 2>/dev/null)
    local baseline_snap="${SNAPSHOT_NAME}_base"
    
    local target_snapshots=$(ssh -T -o StrictHostKeyChecking=no root@$TARGET_SERVER_IP "zfs list -H -o name -t snapshot -r $remote_dataset 2>/dev/null")
    if [ -n "$target_snapshots" ]; then
        echo "========================================================="
        echo "  MIGRATION BLOCK: EXISTING TARGET SNAPSHOTS DETECTED    "
        echo "========================================================="
        echo "The target dataset ($remote_dataset) has historical snapshots."
        echo "To resolve this, open the terminal on SERVER 2 and run:"
        echo "zfs destroy -r -f $remote_dataset"
        echo "========================================================="; exit 1
    fi
    echo "Streaming active baseline data storage layers to explicit target: $remote_dataset"
    zfs destroy "${origin_dataset}@${baseline_snap}" 2>/dev/null
    zfs snapshot "${origin_dataset}@${baseline_snap}"
    if ! zfs send "${origin_dataset}@${baseline_snap}" | ssh -T -o StrictHostKeyChecking=no root@$TARGET_SERVER_IP "zfs receive -F '${remote_dataset}'"; then
        echo "CRITICAL ERROR: Baseline block sync deployment failed." >&2; zfs destroy "${origin_dataset}@${baseline_snap}" 2>/dev/null; restore_origin_vm; exit 1
    fi
    echo "Preparing ZFS final block incremental sync..."
    zfs destroy "${origin_dataset}@${SNAPSHOT_NAME}" 2>/dev/null; zfs snapshot "${origin_dataset}@${SNAPSHOT_NAME}"
    echo "Streaming live final delta block adjustments..."
    if ! zfs send -i "${origin_dataset}@${baseline_snap}" "${origin_dataset}@${SNAPSHOT_NAME}" | ssh -T -o StrictHostKeyChecking=no root@$TARGET_SERVER_IP "zfs receive -F '${remote_dataset}'"; then
        echo "CRITICAL ERROR: Delta stream replication pipeline broken." >&2; restore_origin_vm; exit 1
    fi
    zfs destroy "${origin_dataset}@${baseline_snap}" 2>/dev/null; ssh -T -o StrictHostKeyChecking=no root@$TARGET_SERVER_IP "zfs destroy '${remote_dataset}@${baseline_snap}'" 2>/dev/null
    echo "Applying live UEFI master store template normalization layout patches..."
    local active_nvram_source=$(virsh dumpxml "$VM_NAME" | grep "<nvram" | sed -E "s|.*<nvram[^>]*>([^<]*)</nvram>.*|\1|")
    local cluster_shared_nvram="${local_disk_dir}/${VM_NAME}_VARS.fd"
    if [ -f "$active_nvram_source" ] && [ "$active_nvram_source" != "$cluster_shared_nvram" ]; then cp -f "$active_nvram_source" "$cluster_shared_nvram"; fi
    if [ -f "$cluster_shared_nvram" ]; then rsync -a "$cluster_shared_nvram" root@$TARGET_SERVER_IP:"${remote_disk_dir}/${VM_NAME}_VARS.fd"; fi
    local patched_xml_file="/tmp/${VM_NAME}_migration_stream.xml"
    virsh dumpxml "$VM_NAME" | sed -E "s|<nvram[^>]*>[^<]*</nvram>|<nvram template='/usr/share/qemu/ovmf-x64/OVMF_VARS-pure-efi.fd' format='raw'>${remote_disk_dir}/${VM_NAME}_VARS.fd</nvram>|g" | sed -E "s|check='full'|check='none'|g" | sed -E "s|check='partial'|check='none'|g" | sed -E "/<feature policy=/d" > "$patched_xml_file"
    echo "========================================================="
    echo "   INITIATING LIVE NETWORK PEER-TO-PEER RAM MIGRATION    "
    echo "========================================================="
    if virsh migrate --live "$VM_NAME" qemu+ssh://root@$TARGET_SERVER_IP/system --migrateuri tcp://$TARGET_SERVER_IP:5990 --xml "$patched_xml_file" --undefinesource --persistent --auto-converge --copy-storage-all; then
        echo "SUCCESS: Native hypervisor live memory migration completed flawlessly!"
        rm -f "$patched_xml_file"; return 0
    else
        echo "CRITICAL ERROR: QEMU P2P network migration channel collapsed." >&2; rm -f "$patched_xml_file"; restore_origin_vm; exit 1
    fi
}
restore_origin_vm() {
    echo "========================================================="
    echo "CRITICAL ENVIRONMENT ALERT: RUNNING EMERGENCY ROLLBACK... "
    echo "========================================================="
    if ! virsh list --all --name | grep -xFq "$VM_NAME"; then
        if [ -f "$EMERGENCY_XML_BACKUP" ]; then virsh define "$EMERGENCY_XML_BACKUP" >/dev/null; else exit 1; fi
    fi
    local origin_dataset=$(zfs list -H -o name "$local_disk_dir" 2>/dev/null)
    if [ -n "$origin_dataset" ]; then
        zfs rollback -r "${origin_dataset}@${SNAPSHOT_NAME}" 2>/dev/null
        zfs destroy "${origin_dataset}@${SNAPSHOT_NAME}" 2>/dev/null
    fi
    virsh start "$VM_NAME" &>/dev/null; rm -f "$EMERGENCY_XML_BACKUP"
}
if [ "$1" == "VM_Dataset_Target" ]; then echo "$remote_dataset"; exit 0
else
    echo "Initializing Core Cluster Origin Pipeline for: $VM_NAME"
    check_utilities; validate_vm_state; setup_disk_paths; check_free_space; copy_files_from_origin_to_target
    echo "Verifying operational profile status on destination host..."
    target_check=$(ssh -T -o StrictHostKeyChecking=no root@$TARGET_SERVER_IP "virsh list --state-running --name | grep -xF '$VM_NAME'" 2>/dev/null)
    if [ "$target_check" == "$VM_NAME" ]; then
        echo "SUCCESS: Destination host confirmed profile is active and running!"
        origin_dataset_clean=$(zfs list -H -o name "$local_disk_dir" 2>/dev/null)
        zfs destroy "${origin_dataset_clean}@${SNAPSHOT_NAME}" 2>/dev/null
        rm -f "$EMERGENCY_XML_BACKUP"; rm -f "$STAGING_FILE"
        echo "Migration process finished successfully."; exit 0
    else
        echo "CRITICAL ERROR: Target host failed to resume. Rolling back..." >&2; restore_origin_vm; exit 1
    fi
fi
