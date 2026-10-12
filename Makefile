# dx03v2 harness entry points. CI runs exactly these targets (see docs/HARNESS.md).
SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

HARNESS := bash scripts/harness.sh

.PHONY: help tools static test verify build e2e all clean

help: ## Show the available targets
	@awk 'BEGIN { FS = ":.*## " } /^[a-z][a-z0-9-]*:.*## / { printf "  %-8s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

tools: ## Install the pinned harness tools into .tools/ (SHA256-verified)
	@bash scripts/install-tools.sh

static: ## Policies, npm ci, eslint, prettier, tsc, hadolint, actionlint, shellcheck, CRD schemas, kubeconform, contract, trivy config, gitleaks
	@$(HARNESS) static

test: ## API unit + integration tests (real PostgreSQL 17) and web tests, with coverage gates
	@$(HARNESS) test

verify: ## static + test (what the CI jobs static and test run)
	@$(HARNESS) static test

build: ## npm build, both images, image policy, trivy image gate (HIGH/CRITICAL, fixable)
	@$(HARNESS) build

e2e: ## kind cluster dx03v2-e2e: deploy, smoke test, NetworkPolicy probes (needs Docker)
	@$(HARNESS) e2e

all: ## Every stage: static + test + build + e2e
	@$(HARNESS) all

clean: ## Remove installed tools, build output, coverage, node_modules and harness scratch data
	@rm -rf .tools .cache api/dist web/dist api/coverage web/coverage
	@rm -rf node_modules api/node_modules web/node_modules
	@rm -rf "$${TMPDIR:-/tmp}/dx03v2-harness"
