SHELL := /bin/bash
ROOT := $(CURDIR)
VERSION := $(shell cat VERSION)
ARCH ?= amd64

.PHONY: validate verify-artifacts test test-control-plane test-release-gate release-policy sync-repo-metadata iso smoke clean run tree

validate:
	./scripts/validate.sh

verify-artifacts:
	./scripts/verify-artifacts.sh $(ARCH)

test:
	./tests/appliance-test.sh
	./tests/update-test.sh
	./tests/policy-test.sh
	./tests/repository-metadata-test.sh
	./scripts/test-control-plane.sh
	node --test tests/release-gate.test.mjs

test-control-plane:
	./scripts/test-control-plane.sh

test-release-gate:
	node --test tests/release-gate.test.mjs

release-policy:
	node scripts/release-gate.mjs policy config/release-promotion-policy.json

sync-repo-metadata:
	./scripts/sync-repository-metadata.sh

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
