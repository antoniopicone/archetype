.PHONY: build clean test help

help:
	@echo "Arch Linux Custom ISO Builder"
	@echo ""
	@echo "Available targets:"
	@echo "  make build  - Build custom Arch Linux ISO"
	@echo "  make test   - Test ISO with QEMU"
	@echo "  make clean  - Clean build artifacts"
	@echo "  make help   - Show this help"

build:
	@chmod +x build.sh
	@./build.sh

test:
	@chmod +x test-iso.sh
	@./test-iso.sh

clean:
	@echo "Cleaning up..."
	@docker-compose down -v
	@rm -rf output/*.iso
	@docker system prune -f
	@echo "✓ Cleanup complete"