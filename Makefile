.PHONY: build build-x86_64 build-arm64 build-all clean test test-x86_64 test-arm64 help

help:
	@echo "Archetype Linux Multi-Architecture ISO Builder"
	@echo ""
	@echo "Available targets:"
	@echo "  make build           - Build x86_64 ISO (default)"
	@echo "  make build-x86_64    - Build x86_64 ISO"
	@echo "  make build-arm64     - Build ARM64 installer ISO (Alpine-based)"
	@echo "  make build-all       - Build both x86_64 and ARM64 ISOs"
	@echo "  make test            - Test x86_64 ISO with QEMU"
	@echo "  make test-x86_64     - Test x86_64 ISO with QEMU"
	@echo "  make test-arm64      - Test ARM64 ISO with QEMU"
	@echo "  make clean           - Clean build artifacts"
	@echo "  make clean-arm64     - Clean ARM64 build artifacts"
	@echo "  make help            - Show this help"

build: build-x86_64

build-x86_64:
	@echo "Building x86_64 ISO..."
	@chmod +x build.sh
	@./build.sh x86_64

build-arm64:
	@echo "=========================================="
	@echo "Building ARM64 Installer ISO"
	@echo "=========================================="
	@echo ""
	@echo "This will create an Alpine-based ISO that installs Arch Linux ARM"
	@echo "Compatible with: UTM, Raspberry Pi"
	@echo ""
	@mkdir -p arm64/output
	@chmod +x arm64/build-iso.sh
	@docker run --rm \
		--platform linux/arm64 \
		-v "$(CURDIR)/arm64:/build" \
		-w /build \
		alpine:3.22 \
		sh -c "apk add --no-cache bash xorriso curl wget && /build/build-iso.sh"

build-all:
	@echo "Building all architectures..."
	@chmod +x build.sh
	@./build.sh all

test: test-x86_64

test-x86_64:
	@echo "Testing x86_64 ISO..."
	@chmod +x test-iso.sh
	@./test-iso.sh x86_64

test-arm64:
	@echo "Testing ARM64 ISO..."
	@chmod +x test-iso.sh
	@./test-iso.sh arm64

clean:
	@echo "Cleaning up..."
	@docker-compose down -v 2>/dev/null || true
	@rm -rf output/*.iso
	@rm -rf x86_64/output/*.iso 2>/dev/null || true
	@docker system prune -f
	@echo "✓ Cleanup complete"

clean-arm64:
	@echo "Cleaning ARM64 build artifacts..."
	@rm -rf arm64/output/*.iso
	@rm -rf arm64/output/*.tar.gz
	@echo "✓ ARM64 cleanup complete"
