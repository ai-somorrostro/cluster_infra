VARS_FILE := variables.pkrvars.hcl
BUILD_ID := 9000
TEMPLATE_ID := 9001
FINAL_STORAGE := ssd-data
FINAL_NAME := ubuntu-server-24
PROXMOX_API := VARS_FILE=$(VARS_FILE) BUILD_ID=$(BUILD_ID) TEMPLATE_ID=$(TEMPLATE_ID) FINAL_STORAGE=$(FINAL_STORAGE) FINAL_NAME=$(FINAL_NAME) bash scripts/proxmox-api.sh

.PHONY: init check-files validate build dhcp distribute all clean-build clean-final

init:
	packer init .

check-files:
	@test -f "$(VARS_FILE)" || { echo "Missing $(VARS_FILE). Run: cp variables.pkrvars.example.hcl $(VARS_FILE)"; exit 1; }

validate: check-files
	packer validate -var-file=$(VARS_FILE) .

build: validate
	PACKER_LOG=1 packer build -on-error=abort -var-file=$(VARS_FILE) .

dhcp:
	$(PROXMOX_API) dhcp

distribute:
	$(PROXMOX_API) distribute

all: build dhcp distribute

clean-build:
	$(PROXMOX_API) clean-build

clean-final:
	$(PROXMOX_API) clean-final
