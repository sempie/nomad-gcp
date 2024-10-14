
.PHONY: cluster-up
cluster-up: terraform.tfvars
	terraform apply -auto-approve

.PHONY: cluster-down
cluster-down: terraform.tfvars
	terraform destroy -auto-approve
	rm -f .env nomad-management.token vault-keys.txt vault-root.txt

.PHONY: nomad-auth
nomad-auth:
	NOMAD_ADDR=http://$(shell terraform output -json instance_ips | jq -r '.[0]'):4646/ui nomad acl bootstrap | grep -i secret | awk -F "=" '{print $$2}' | xargs > nomad-management.token


.PHONY: nomad-env
nomad-env:
	@echo "export NOMAD_ADDR=http://$(shell terraform output -json instance_ips | jq -r '.[0]'):4646/ui" > .env
	@echo "export CONSUL_HTTP_ADDR=http://$(shell terraform output -json instance_ips | jq -r '.[0]'):8500" >> .env
	@echo "export VAULT_ADDR=http://$(shell terraform output -json instance_ips | jq -r '.[0]'):8200" >> .env
	@echo "export SERVER_IP=$(shell terraform output -json instance_ips | jq -r '.[0]')" >> .env
	@echo "export NOMAD_TOKEN=$(shell cat nomad-management.token)" >> .env
	@echo "Environment variables set. To use in your shell, run: source .env"

.PHONY: vault-init
vault-init:
	@export VAULT_ADDR="http://$(shell terraform output -json instance_ips | jq -r '.[0]'):8200"; \
	vault operator init > vault-keys.txt
	@grep "Initial Root Token:" vault-keys.txt | cut -d':' -f2 | tr -d ' ' > vault-root.txt

vault-unseal:
	@NODES=$$(terraform output -json instance_ips | jq -r '.[]'); \
	for node in $$NODES; do \
		echo "Unsealing node $$node"; \
		export VAULT_ADDR="http://$$node:8200"; \
		for i in 1 2 3; do \
			KEY=$$(sed -n "$$i"p vault-keys.txt | cut -d':' -f2 | tr -d ' '); \
			vault operator unseal $$KEY; \
		done; \
		vault status; \
		echo "----------------------"; \
	done

vault-login:
	@export VAULT_ADDR="http://$$(terraform output -json instance_ips | jq -r '.[0]'):8200"; \
	ROOT_TOKEN=$$(cat vault-root.txt); \
	vault login $$ROOT_TOKEN