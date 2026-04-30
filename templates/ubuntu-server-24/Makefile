# FILL IN ──────────────────────────────────────────────────────────────────────
PROXMOX_HOST := 192.168.136.238
BUILD_ID     := 9000   # temporary build VM on local-lvm — must match vm_id in vars file
TEMPLATE_ID  := 9001   # final template on ssd-data, shared across all nodes
# ──────────────────────────────────────────────────────────────────────────────

VARS_FILE := variables.pkrvars.hcl

.PHONY: init validate build distribute clean

init:
	packer init .

validate:
	packer validate -var-file=$(VARS_FILE) .

build: validate
	@echo "Starting build — will fix boot order as soon as VM is created..."
	@( until curl -sk -H "Authorization: PVEAPIToken=root@pam!infra=$$(grep api_token_secret $(VARS_FILE) | cut -d'"' -f2)" \
		"https://$(PROXMOX_HOST):8006/api2/json/nodes/$$(grep proxmox_node $(VARS_FILE) | cut -d'"' -f2)/qemu/$(BUILD_ID)/status/current" \
		| grep -q '"status"'; do sleep 0.3; done; \
		curl -sk -X PUT \
		-H "Authorization: PVEAPIToken=root@pam!infra=$$(grep api_token_secret $(VARS_FILE) | cut -d'"' -f2)" \
		--data-urlencode "boot=order=ide2;scsi0" \
		"https://$(PROXMOX_HOST):8006/api2/json/nodes/$$(grep proxmox_node $(VARS_FILE) | cut -d'"' -f2)/qemu/$(BUILD_ID)/config" > /dev/null; \
		echo "Boot order set.") &
	PACKER_LOG=1 packer build -on-error=abort -var-file=$(VARS_FILE) .

distribute:
	@TOKEN="PVEAPIToken=root@pam!infra=$$(grep api_token_secret $(VARS_FILE) | cut -d'"' -f2)"; \
	NODE=$$(grep proxmox_node $(VARS_FILE) | cut -d'"' -f2); \
	echo "Removing installer seed ISO (ide3) from build VM..."; \
	curl -sk -X PUT -H "Authorization: $$TOKEN" \
		--data-urlencode "delete=ide3" \
		"https://$(PROXMOX_HOST):8006/api2/json/nodes/$$NODE/qemu/$(BUILD_ID)/config" > /dev/null; \
	echo "Cloning $(BUILD_ID) → $(TEMPLATE_ID) on ssd-data..."; \
	RESP=$$(curl -sk -X POST -H "Authorization: $$TOKEN" \
		-d "newid=$(TEMPLATE_ID)&full=1&storage=ssd-data&name=ubuntu-server-24" \
		"https://$(PROXMOX_HOST):8006/api2/json/nodes/$$NODE/qemu/$(BUILD_ID)/clone"); \
	TASK=$$(printf "%s" "$$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',''))"); \
	if [ -z "$$TASK" ]; then echo "Clone API failed: $$RESP"; exit 1; fi; \
	ENCODED=$$(python3 -c "import urllib.parse; print(urllib.parse.quote('$$TASK', safe=''))"); \
	until curl -sk -H "Authorization: $$TOKEN" \
		"https://$(PROXMOX_HOST):8006/api2/json/nodes/$$NODE/tasks/$$ENCODED/status" \
		| python3 -c "import sys,json; d=json.load(sys.stdin)['data']; sys.exit(0 if d.get('status')=='stopped' else 1)" 2>/dev/null; \
	do sleep 3; done; \
	echo "Converting to template..."; \
	curl -sk -X POST -H "Authorization: $$TOKEN" \
		"https://$(PROXMOX_HOST):8006/api2/json/nodes/$$NODE/qemu/$(TEMPLATE_ID)/template" > /dev/null; \
	echo "Cleaning up build VM..."; \
	curl -sk -X DELETE -H "Authorization: $$TOKEN" \
		"https://$(PROXMOX_HOST):8006/api2/json/nodes/$$NODE/qemu/$(BUILD_ID)" > /dev/null; \
	echo "Done. Template $(TEMPLATE_ID) on ssd-data."

clean:
	@read -p "Destroy template $(TEMPLATE_ID) on $(PROXMOX_HOST)? [y/N] " c && \
		[ "$$c" = "y" ] && \
		ssh root@$(PROXMOX_HOST) "qm destroy $(TEMPLATE_ID)" || \
		echo "Aborted."
