#!/usr/bin/env bash

set -euo pipefail

# Exports Terraform outputs to a stable JSON file and timestamped archive copy.
# Run from the terraform directory:
#   ./export_outputs.sh

terraform output -json > outputs.json
cp outputs.json "outputs-$(date +%Y%m%d-%H%M%S).json"

echo "Terraform outputs written to:"
echo "- outputs.json"
echo "- outputs-<timestamp>.json"
