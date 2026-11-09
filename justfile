# List the recipes
default:
    @just --list

# Rebuild the image, with updates
build:
    ./jail build

# Run ShellCheck on the Bash scripts, and check that the Python runs on 3.9+
lint:
    shellcheck image/boot.sh
    python3 -c 'import ast, sys; [ast.parse(open(f).read(), f, feature_version=(3, 9)) for f in sys.argv[1:]]' jail test/run.py

# Run all checks and tests; needs the image
test: lint
    test/run.py
