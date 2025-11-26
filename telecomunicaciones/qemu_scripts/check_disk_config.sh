#!/bin/bash

# check_disk_config.sh - Check disk configuration for VMs

if [ $# -lt 2 ]; then
    echo "Uso: $0 <nodo> <vmid1> [vmid2] ..."
    echo "Ejemplo: $0 pve 100 101"
    exit 1
fi

NODE=$1
shift
VMIDS=("$@")

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

for VMID in "${VMIDS[@]}"; do
    echo -e "\n${YELLOW}=========================================="
    echo "VM $VMID Disk Configuration"
    echo -e "==========================================${NC}"
    
    # Proxmox side - VM config
    echo -e "\n${GREEN}[PROXMOX SIDE]${NC}"
    echo "--- VM Config ---"
    pvesh get /nodes/$NODE/qemu/$VMID/config --output-format json 2>/dev/null | grep -E '(scsi|virtio|sata|ide)[0-9]+:' || echo "No disk config found"
    
    echo -e "\n--- Disk list via qm ---"
    qm config $VMID 2>/dev/null | grep -E '(scsi|virtio|sata|ide)[0-9]+' || echo "No disks found"
    
    # Check if VM is running
    VM_STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format json 2>/dev/null)
    STATUS=$(echo "$VM_STATUS" | grep -oP '"status":"\K[^"]+')
    AGENT_ENABLED=$(echo "$VM_STATUS" | grep -oP '"agent":\K[0-9]+' || echo "0")
    
    echo -e "\nVM Status: $STATUS"
    echo "Agent Enabled: $AGENT_ENABLED"
    
    if [ "$STATUS" != "running" ] || [ "$AGENT_ENABLED" != "1" ]; then
        echo -e "${YELLOW}[!]${NC} VM not running or agent not enabled, skipping VM-side checks"
        continue
    fi
    
    # VM side - Disk layout
    echo -e "\n${GREEN}[VM SIDE]${NC}"
    echo "--- lsblk output ---"
    pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "lsblk" --command "-f" --output-format json 2>/dev/null | grep -oP '"out-data":"\K[^"]+' | base64 -d 2>/dev/null || echo "Failed to get lsblk"
    
    sleep 1
    
    echo -e "\n--- Physical Volumes ---"
    pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "pvs" --output-format json 2>/dev/null | grep -oP '"out-data":"\K[^"]+' | base64 -d 2>/dev/null || echo "Failed to get pvs"
    
    sleep 1
    
    echo -e "\n--- Volume Groups ---"
    pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "vgs" --output-format json 2>/dev/null | grep -oP '"out-data":"\K[^"]+' | base64 -d 2>/dev/null || echo "Failed to get vgs"
    
    sleep 1
    
    echo -e "\n--- Logical Volumes ---"
    pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "lvs" --command "-o" --command "vg_name,lv_name,lv_size,path" --output-format json 2>/dev/null | grep -oP '"out-data":"\K[^"]+' | base64 -d 2>/dev/null || echo "Failed to get lvs"
    
    sleep 1
    
    echo -e "\n--- Filesystem info ---"
    pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "df" --command "-h" --command "/" --output-format json 2>/dev/null | grep -oP '"out-data":"\K[^"]+' | base64 -d 2>/dev/null || echo "Failed to get df"
    
    sleep 1
    
    echo -e "\n--- Disk devices ---"
    pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "lsblk" --command "-ndo" --command "NAME,TYPE,SIZE,MOUNTPOINT" --output-format json 2>/dev/null | grep -oP '"out-data":"\K[^"]+' | base64 -d 2>/dev/null || echo "Failed to get disk devices"
    
done

echo -e "\n${GREEN}Done${NC}"

