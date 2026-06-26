################################################################################
# microvm-bench — root Makefile
#
# All targets are designed to be run from the repo root.
# Prerequisites: go, cargo, docker (with buildx), terraform, pnpm, aws CLI, jq.
# AWS profile: microvm-bench  (set via AWS_PROFILE or --profile flag)
# See README.md for the full ordered runbook.
################################################################################

REPO_ROOT  := $(shell pwd)
AWS_PROFILE ?= microvm-bench
REGIONS    := us-east-1 us-west-2
VARIANTS   := base mpl sci

# Go binaries
PROVISIONER_DIR := $(REPO_ROOT)/provisioner
HARNESS_DIR     := $(REPO_ROOT)/harness

# Directories
INFRA_DIR    := $(REPO_ROOT)/infra
FRONTEND_DIR := $(REPO_ROOT)/frontend
SCRIPTS_DIR  := $(REPO_ROOT)/scripts

# Arm64 target for Lambda / MicroVM (server-side Graviton build)
GOOS   := linux
GOARCH := arm64
CGO_ENABLED := 0

.DEFAULT_GOAL := help

.PHONY: help binfmt \
        build-provisioner build-images \
        deploy-infra deploy-frontend \
        test estimate reap \
        verify fmt clean

# ---------------------------------------------------------------------------
# help — print available targets
# ---------------------------------------------------------------------------
help:
	@echo ""
	@echo "microvm-bench Makefile targets:"
	@echo ""
	@echo "  Setup / build:"
	@echo "    binfmt            Register arm64 binfmt via Docker (needed for local arm64 builds)"
	@echo "    build-provisioner Cross-compile provisioner + reaper for arm64 -> provisioner/dist/*.zip"
	@echo "    build-images      Build all 3 image variants in both regions (calls AWS)"
	@echo ""
	@echo "  Deploy:"
	@echo "    deploy-infra      terraform init + apply in infra/"
	@echo "    deploy-frontend   pnpm build, S3 sync, CloudFront invalidate"
	@echo ""
	@echo "  Run / measure:"
	@echo "    test              Run the harness benchmark (N=3, both regions, all variants)"
	@echo "    estimate          Print offline cost estimate (no AWS calls)"
	@echo "    reap              Terminate all bench microVMs (identified by image ARN)"
	@echo ""
	@echo "  Dev:"
	@echo "    verify            Run every component's verify/check command"
	@echo "    fmt               Format Go + Rust + frontend sources"
	@echo "    clean             Remove build artifacts"
	@echo ""
	@echo "First-time setup:"
	@echo "    bash scripts/bootstrap.sh"
	@echo ""

# ---------------------------------------------------------------------------
# binfmt — register arm64 via docker run --privileged tonistiigi/binfmt
# ---------------------------------------------------------------------------
binfmt:
	@echo "==> Registering arm64 binfmt (requires Docker with privileged) ..."
	docker run --privileged --rm tonistiigi/binfmt --install arm64
	@echo "    arm64 binfmt registered."

# ---------------------------------------------------------------------------
# build-provisioner — cross-compile arm64 Go binaries, zip for Lambda
# ---------------------------------------------------------------------------
PROVISIONER_DIST := $(PROVISIONER_DIR)/dist

build-provisioner:
	@echo "==> Building provisioner + reaper (arm64) ..."
	@mkdir -p $(PROVISIONER_DIST)

	# provisioner -> bootstrap -> provisioner.zip  (Lambda provided.al2023 wants
	# the executable named 'bootstrap'). python3 -m zipfile (no 'zip' dependency)
	# stores the 0755 mode in external_attr, which Lambda's unzip honors.
	GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=$(CGO_ENABLED) \
	    go build -tags lambda.norpc -ldflags="-s -w" \
	    -o $(PROVISIONER_DIST)/bootstrap ./provisioner/cmd/provisioner
	cd $(PROVISIONER_DIST) && rm -f provisioner.zip && \
	    python3 -m zipfile -c provisioner.zip bootstrap
	@echo "    $(PROVISIONER_DIST)/provisioner.zip"

	# reaper -> bootstrap -> reaper.zip
	GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=$(CGO_ENABLED) \
	    go build -tags lambda.norpc -ldflags="-s -w" \
	    -o $(PROVISIONER_DIST)/bootstrap ./provisioner/cmd/reaper
	cd $(PROVISIONER_DIST) && rm -f reaper.zip && \
	    python3 -m zipfile -c reaper.zip bootstrap
	@echo "    $(PROVISIONER_DIST)/reaper.zip"

	# Leave dist/bootstrap as the provisioner binary (tidy final state).
	GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=$(CGO_ENABLED) \
	    go build -tags lambda.norpc -ldflags="-s -w" \
	    -o $(PROVISIONER_DIST)/bootstrap ./provisioner/cmd/provisioner
	@echo "==> build-provisioner done."

# ---------------------------------------------------------------------------
# build-images — build all 3 variants x 2 regions via scripts/build-image.sh
# ---------------------------------------------------------------------------
build-images:
	@echo "==> Building microVM images (3 variants x 2 regions = 6 builds) ..."
	@echo "    AWS builds happen server-side on Graviton; each takes ~5-15 min."
	@echo ""
	@for region in $(REGIONS); do \
	    for variant in $(VARIANTS); do \
	        echo "--- VARIANT=$$variant REGION=$$region ---"; \
	        VARIANT=$$variant REGION=$$region AWS_PROFILE=$(AWS_PROFILE) \
	            bash $(SCRIPTS_DIR)/build-image.sh; \
	        echo ""; \
	    done; \
	done
	@echo "==> build-images done. Update provisioner env vars with returned ARNs (see scripts/bootstrap.sh step 5)."

# ---------------------------------------------------------------------------
# deploy-infra — terraform init + apply
# ---------------------------------------------------------------------------
deploy-infra:
	@echo "==> Running terraform in $(INFRA_DIR) ..."
	cd $(INFRA_DIR) && terraform init -input=false
	cd $(INFRA_DIR) && terraform apply -input=false
	@echo "==> deploy-infra done."

# ---------------------------------------------------------------------------
# deploy-frontend — pnpm build, S3 sync, CloudFront invalidate
# ---------------------------------------------------------------------------
deploy-frontend:
	@echo "==> Deploying frontend ..."
	bash $(SCRIPTS_DIR)/deploy-frontend.sh
	@echo "==> deploy-frontend done."

# ---------------------------------------------------------------------------
# test — run the harness benchmark (N=3 by default)
# ---------------------------------------------------------------------------
HARNESS_BIN := $(REPO_ROOT)/results/harness
HARNESS_N   ?= 3
HARNESS_BUDGET ?= 2.0

test: $(HARNESS_BIN)
	@echo "==> Running harness benchmark (N=$(HARNESS_N), budget=\$$$(HARNESS_BUDGET)) ..."
	$(HARNESS_BIN) run --samples $(HARNESS_N) --budget-usd $(HARNESS_BUDGET)

$(HARNESS_BIN):
	@mkdir -p $(REPO_ROOT)/results
	go build -o $(HARNESS_BIN) ./harness/cmd/harness

# ---------------------------------------------------------------------------
# estimate — offline cost estimate, no AWS calls
# ---------------------------------------------------------------------------
estimate: $(HARNESS_BIN)
	@echo "==> Running cost estimate ..."
	$(HARNESS_BIN) estimate

# ---------------------------------------------------------------------------
# reap — terminate all Project=microvm-bench microVMs
# ---------------------------------------------------------------------------
reap:
	@echo "==> Reaping microvm-bench microVMs ..."
	bash $(SCRIPTS_DIR)/reap.sh

# ---------------------------------------------------------------------------
# verify — run every component's verify / check command
# ---------------------------------------------------------------------------
verify:
	@echo "==> Verifying all components ..."

	@echo ""
	@echo "-- [1/6] provisioner: go vet --"
	go vet ./provisioner/...

	@echo ""
	@echo "-- [2/6] harness: go vet --"
	go vet ./harness/...

	@echo ""
	@echo "-- [3/6] manager (Rust): cargo check (arm64) --"
	cd $(REPO_ROOT)/microvm/manager && \
	    cargo check --target aarch64-unknown-linux-musl 2>/dev/null || \
	    cargo check --target aarch64-unknown-linux-gnu 2>/dev/null || \
	    cargo check

	@echo ""
	@echo "-- [4/6] forkserver: python -m py_compile --"
	python3 -m py_compile $(REPO_ROOT)/microvm/forkserver/forkserver.py
	@echo "    forkserver.py syntax OK"

	@echo ""
	@echo "-- [5/6] forkserver smoke test (base variant, no heavy deps) --"
	python3 $(REPO_ROOT)/microvm/forkserver/smoke_test.py

	@echo ""
	@echo "-- [6/6] frontend: pnpm --dir frontend tsc --noEmit --"
	pnpm --dir $(FRONTEND_DIR) exec tsc --noEmit

	@echo ""
	@echo "==> All verify checks passed."

# ---------------------------------------------------------------------------
# fmt — format all source trees
# ---------------------------------------------------------------------------
fmt:
	@echo "==> Formatting Go (provisioner + harness) ..."
	go fmt ./provisioner/...
	go fmt ./harness/...

	@echo "==> Formatting Rust (manager) ..."
	cd $(REPO_ROOT)/microvm/manager && cargo fmt

	@echo "==> Formatting frontend (pnpm prettier) ..."
	pnpm --dir $(FRONTEND_DIR) exec prettier --write src/ 2>/dev/null || \
	    echo "    (prettier not installed; skipping)"

	@echo "==> fmt done."

# ---------------------------------------------------------------------------
# clean — remove build artifacts
# ---------------------------------------------------------------------------
clean:
	@echo "==> Cleaning build artifacts ..."

	rm -rf $(PROVISIONER_DIST)
	rm -f  $(HARNESS_BIN)

	cd $(REPO_ROOT)/microvm/manager && cargo clean

	pnpm --dir $(FRONTEND_DIR) exec rimraf dist 2>/dev/null || \
	    rm -rf $(FRONTEND_DIR)/dist

	@echo "==> clean done."
