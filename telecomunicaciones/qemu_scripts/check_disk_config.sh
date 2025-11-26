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
    wait_for_pid() {
        local pid=$1
        local timeout=$2
        local count=0
        while [ $count -lt $timeout ]; do
            sleep 1
            local status=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid $pid --output-format json 2>/dev/null || echo "")
            if echo "$status" | grep -q '"exited"'; then
                echo "$status"
                return 0
            fi
            count=$((count+1))
        done
        echo ""
        return 1
    }
    
    get_cmd_output() {
        local cmd_arr=("$@")
        local pvesh_args=""
        for arg in "${cmd_arr[@]}"; do
            local escaped_arg=$(echo "$arg" | sed 's/"/\\"/g')
            pvesh_args="$pvesh_args --command \"$escaped_arg\""
        done
        
        local out=$(eval pvesh create /nodes/$NODE/qemu/$VMID/agent/exec $pvesh_args --output-format json 2>/dev/null)
        local pid=$(echo "$out" | grep -oP '"pid":\K[0-9]+')
        
        if [ -z "$pid" ]; then
            echo ""
            return 1
        fi
        
        local res=$(wait_for_pid $pid 30)
        local out_data=$(echo "$res" | grep -oP '"out-data":"\K[^"]+' || echo "")
        if [ -n "$out_data" ]; then
            echo -n "$out_data" | base64 -d 2>/dev/null | head -20
            echo ""
        fi
    }
    
    # VM side - Disk layout
    echo -e "\n${GREEN}[VM SIDE]${NC}"
    echo "--- lsblk output ---"
    OUTPUT=$(get_cmd_output "lsblk" "-f")
    if [ -n "$OUTPUT" ]; then
        echo "$OUTPUT"
    else
        echo "Failed to get lsblk"
    fi
    
    echo -e "\n--- Physical Volumes ---"
    OUTPUT=$(get_cmd_output "pvs")
    if [ -n "$OUTPUT" ]; then
        echo "$OUTPUT"
    else
        echo "Failed or no LVM (this is OK if VM doesn't use LVM)"
    fi
    
    echo -e "\n--- Volume Groups ---"
    OUTPUT=$(get_cmd_output "vgs")
    if [ -n "$OUTPUT" ]; then
        echo "$OUTPUT"
    else
        echo "Failed or no LVM (this is OK if VM doesn't use LVM)"
    fi
    
    echo -e "\n--- Logical Volumes ---"
    OUTPUT=$(get_cmd_output "lvs" "-o" "vg_name,lv_name,lv_size,path")
    if [ -n "$OUTPUT" ]; then
        echo "$OUTPUT"
    else
        echo "Failed or no LVM (this is OK if VM doesn't use LVM)"
    fi
    
    echo -e "\n--- Filesystem info ---"
    OUTPUT=$(get_cmd_output "df" "-h" "/")
    if [ -n "$OUTPUT" ]; then
        echo "$OUTPUT"
    else
        echo "Failed"
    fi
    
    echo -e "\n--- Disk devices (detailed) ---"
    OUTPUT=$(get_cmd_output "lsblk" "-ndo" "NAME,TYPE,SIZE,MOUNTPOINT")
    if [ -n "$OUTPUT" ]; then
        echo "$OUTPUT"
    else
        echo "Failed"
    fi
    
done

echo -e "\n${GREEN}Done${NC}"

