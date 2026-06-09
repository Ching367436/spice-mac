# SpiceMac — thin task runner over scripts/. Run `make` (or `make help`) for the list.
# Sets DEVELOPER_DIR so you never have to remember the prefix. The scripts in
# scripts/ stay the source of truth.

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

.DEFAULT_GOAL := help

.PHONY: help doctor setup build run test all openssl icon debug root release check-version clean distclean

help: ## Show this help
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z0-9_-]+:.*## /{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

doctor: ## Check the build environment (Xcode, Metal toolchain, frameworks)
	@./scripts/doctor.sh

setup: ## Stage the native SPICE frameworks (pinned, checksummed sysroot)
	@./scripts/fetch-sysroot.sh

build: ## Build and assemble build/SpiceMac.app
	@./scripts/build-app.sh

run: ## Open build/SpiceMac.app
	@open build/SpiceMac.app

test: ## Run the dependency-free check runners (vvcheck + inputcheck)
	@( cd Packages/VVConfig && swift run vvcheck )
	@( cd Packages/SpiceInputMap && swift run inputcheck )

all: doctor setup build ## Doctor, fetch the sysroot, and build (first-time setup)

openssl: ## Upgrade the bundled OpenSSL (only needed on a raw UTM sysroot)
	@./scripts/upgrade-openssl.sh

icon: ## Regenerate Resources/AppIcon.icns from design/icon/source.png
	@./scripts/make-icon.sh

debug: ## Launch with verbose SPICE/CocoaSpice logging:  make debug VV=conn.vv
	@./scripts/debug-run.sh $(VV)

root: ## Launch as root for USB capture (kernel-claimed devices):  make root VV=conn.vv
	@./scripts/run-as-root.sh $(VV)

release: ## Cut a release (prompts before publishing):  make release VERSION=0.1.7
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=X.Y.Z"; exit 1; }
	@./scripts/release.sh $(VERSION)

check-version: ## Assert Info.plist / CHANGELOG / tag versions agree
	@./scripts/check-version.sh

clean: ## Remove build output (build/)
	@rm -rf build/ && echo "removed build/"

distclean: clean ## Also remove the staged native frameworks (Frameworks/)
	@find Frameworks -mindepth 1 ! -name '.gitkeep' -maxdepth 1 -exec rm -rf {} + && echo "removed Frameworks/*"
