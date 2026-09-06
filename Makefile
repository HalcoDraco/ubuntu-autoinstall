# ===========================================================================
# Makefile -- shortcuts. Run `make` or `make help` to see everything.
#
# Nothing here is required: every target is a thin wrapper around a command
# you could type yourself, and the command is shown when it runs.
# ===========================================================================

# Prefer the local lint virtualenv when it exists, otherwise system ansible.
VENV := .venv
ANSIBLE_PLAYBOOK := $(shell [ -x $(VENV)/bin/ansible-playbook ] && echo $(VENV)/bin/ansible-playbook || echo ansible-playbook)
ANSIBLE_LINT := $(shell [ -x $(VENV)/bin/ansible-lint ] && echo $(VENV)/bin/ansible-lint || echo ansible-lint)

.DEFAULT_GOAL := help
.PHONY: help deps lint check run run-tags syntax vm-create vm-start vm-stop vm-ssh vm-run vm-desktop vm-reset vm-destroy

help: ## Show this help
	grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

deps: ## Install pinned galaxy collections, only if actually missing
	@ansible-doc community.general.snap >/dev/null 2>&1 \
	  && echo "community.general already available - nothing to do" \
	  || ansible-galaxy install -r requirements.yml

syntax: ## Parse the playbook without running anything
	$(ANSIBLE_PLAYBOOK) --syntax-check local.yml

lint: ## Run ansible-lint (production profile)
	$(ANSIBLE_LINT)

check: ## Dry run: show what WOULD change, change nothing (read-only)
	$(ANSIBLE_PLAYBOOK) local.yml --check --diff -K

run: ## Apply the playbook to this machine
	$(ANSIBLE_PLAYBOOK) local.yml -K

run-tags: ## Apply only some roles, e.g. make run-tags TAGS=keyboard,packages
	$(ANSIBLE_PLAYBOOK) local.yml -K --tags "$(TAGS)"

# ----------------------------- VM test harness -----------------------------
# See README "Testing safely in a VM". These wrap scripts in vm/.

vm-create: ## Build the Ubuntu test VM from a cloud image (unattended)
	./vm/vm-create.sh

vm-start: ## Boot the test VM
	./vm/vm-helper.sh start

vm-ssh: ## SSH into the test VM
	./vm/vm-helper.sh ssh

vm-stop: ## Shut the test VM down
	./vm/vm-helper.sh stop

vm-run: ## Run this playbook inside the test VM (the actual test)
	./vm/vm-helper.sh run

vm-desktop: ## Install GNOME in the VM so keyboard/gsettings can be tested
	./vm/vm-helper.sh desktop

vm-reset: ## Revert the VM to a pristine state (deletes the overlay disk)
	./vm/vm-helper.sh reset

vm-destroy: ## Delete the test VM entirely
	./vm/vm-helper.sh destroy
