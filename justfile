# List the recipes
default:
    @just --list

# Rebuild the image, with updates
build:
    ./jail build

# Run ShellCheck on all scripts
lint:
    shellcheck jail image/boot.sh test/run.sh

# Run all checks and tests; needs the image
test: lint
    test/run.sh
