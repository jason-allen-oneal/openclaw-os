SHELL := /bin/bash
ROOT := $(CURDIR)
VERSION := $(shell cat VERSION)
ARCH ?= amd64

.PHONY: validate verify-artifacts test test-control-plane test-release-gate test-branch-cleanup test-iso-change-filter test-repository-settings release-policy sync-repo-metadata apply-repo-settings iso smoke clean run tree

validate:
	./scripts/validate.sh

verify-artifacts:
	./scripts/verify-artifacts.sh $(ARCH)

test:
	./tests/appliance-test.sh
	./tests/update-test.sh
	./tests/policy-test.sh
	./tests/repository-metadata-test.sh
	./tests/repository-settings-test.sh
	./tests/iso-build-required-test.sh
	./scripts/test-control-plane.sh
	node --test tests/release-gate.test.mjs
	python3 -m unittest discover -s tests -p 'branch_cleanup_test.py'

test-control-plane:
	./scripts/test-control-plane.sh

test-release-gate:
	node --test tests/release-gate.test.mjs

test-branch-cleanup:
	python3 -m unittest discover -s tests -p 'branch_cleanup_test.py'

test-iso-change-filter:
	./tests/iso-build-required-test.sh

test-repository-settings:
	./tests/repository-settings-test.sh

release-policy:
	node scripts/release-gate.mjs policy config/release-promotion-policy.json

sync-repo-metadata:
	./scripts/sync-repository-metadata.sh

apply-repo-settings:
	./scripts/apply-repository-settings.sh

iso: validate verify-artifacts
	sudo ./scripts/build-image.sh $(ARCH)

smoke:
	@test -f dist/openclaw-os-$(VERSION)-$(ARCH).iso || { echo "ISO not found. Run make iso first." >&2; exit 1; }
	./scripts/smoke-iso.sh dist/openclaw-os-$(VERSION)-$(ARCH).iso

clean:
	@if command -v lb >/dev/null 2>&1; then cd image && sudo lb clean --purge || true; fi
	rm -rf dist image/.build image/.cache image/config/includes.chroot/usr/lib/openclaw-os/control-plane

run:
	@test -f dist/openclaw-os-$(VERSION)-$(ARCH).iso || { echo "ISO not found. Run make iso first." >&2; exit 1; }
	qemu-system-x86_64 \
		-enable-kvm \
		-m 4096 \
		-smp 4 \
		-cdrom dist/openclaw-os-$(VERSION)-$(ARCH).iso \
		-boot d \
		-netdev user,id=n1 \
		-device virtio-net-pci,netdev=n1

tree:
	find . -path './.git' -prune -o -type f -print | sort
