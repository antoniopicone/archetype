#!/bin/bash
set -e

# Parse arguments
ARCH="${1:-all}"

echo "======================================"
echo "  Archetype Linux ISO Builder        "
echo "======================================"
echo

case "$ARCH" in
    x86_64)
        echo "Building x86_64 ISO..."
        docker-compose build iso-builder-x86_64
        docker-compose up iso-builder-x86_64
        ;;
    arm64)
        echo "Building ARM64 ISO..."
        docker-compose build iso-builder-arm64
        docker-compose up iso-builder-arm64
        ;;
    all)
        echo "Building both x86_64 and ARM64 ISOs..."
        docker-compose build
        docker-compose up iso-builder-x86_64
        docker-compose up iso-builder-arm64
        ;;
    *)
        echo "ERROR: Invalid architecture: $ARCH"
        echo "Usage: $0 [x86_64|arm64|all]"
        exit 1
        ;;
esac

echo
echo "======================================"
echo "✓ Build completed successfully!"
echo "======================================"
echo

case "$ARCH" in
    x86_64)
        echo "x86_64 ISOs available in ./output/"
        ls -lh ./output/*.iso 2>/dev/null || echo "No x86_64 ISOs found in output directory"
        ;;
    arm64)
        echo "ARM64 ISOs available in ./arm64/output/"
        ls -lh ./arm64/output/*.iso 2>/dev/null || echo "No ARM64 ISOs found in arm64/output directory"
        ;;
    all)
        echo "x86_64 ISOs:"
        ls -lh ./output/*.iso 2>/dev/null || echo "  No x86_64 ISOs found"
        echo ""
        echo "ARM64 ISOs:"
        ls -lh ./arm64/output/*.iso 2>/dev/null || echo "  No ARM64 ISOs found"
        ;;
esac
