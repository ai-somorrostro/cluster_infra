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
    
    # Helper function to wait for command and get output
    wait_and_get_output() {
        local cmd_out=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec "$@" --output-format json 2>/dev/null)
        local pid=$(echo "$cmd_out" | grep -oP '"pid":\K[0-9]+')
        if [ -z "$pid" ]; then
            echo "Failed to start command"
            return 1
        fi
        
        # Wait for command to finish
        local count=0
        while [ $count -lt 30 ]; do
            sleep 1
            local status=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid $pid --output-format json 2>/dev/null || echo "")
            if echo "$status" | grep -q '"exited"'; then
                local out_data=$(echo "$status" | grep -oP '"out-data":"\K[^"]+' || echo "")
                if [ -n "$out_data" ]; then
                    echo -n "$out_data" | base64 -d 2>/dev/null
                fi
                return 0
            fi
            count=$((count+1))
        done
        echo "Timeout waiting for command"
        return 1
    }
    
    # VM side - Disk layout
    echo -e "\n${GREEN}[VM SIDE]${NC}"
    echo "--- lsblk output ---"
    wait_and_get_output --command "lsblk" --command "-f" || echo "Failed"
    
    echo -e "\n--- Physical Volumes ---"
    wait_and_get_output --command "pvs" || echo "Failed (may not have LVM)"
    
    echo -e "\n--- Volume Groups ---"
    wait_and_get_output --command "vgs" || echo "Failed (may not have LVM)"
    
    echo -e "\n--- Logical Volumes ---"
    wait_and_get_output --command "lvs" --command "-o" --command "vg_name,lv_name,lv_size,path" || echo "Failed (may not have LVM)"
    
    echo -e "\n--- Filesystem info ---"
    wait_and_get_output --command "df" --command "-h" --command "/" || echo "Failed"
    
    echo -e "\n--- Disk devices (detailed) ---"
    wait_and_get_output --command "lsblk" --command "-ndo" --command "NAME,TYPE,SIZE,MOUNTPOINT" || echo "Failed"
    
done

echo -e "\n${GREEN}Done${NC}"

