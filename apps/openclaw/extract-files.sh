#!/bin/bash
# Extract files from the OpenClaw container home directory into a zip archive.
#
# Usage:
#   ./extract-files.sh <output.zip> <path1> [path2] [path3] ...
#
# Paths are relative to the openclaw user's home directory.
#
# Examples:
#   ./extract-files.sh backup.zip .bashrc projects/myapp
#   ./extract-files.sh code.zip projects/

set -euo pipefail

OPENCLAW_HOME="/opt/infra/apps/openclaw/data/home"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <output.zip> <path1> [path2] ..."
    echo ""
    echo "Paths are relative to the openclaw home directory:"
    echo "  $OPENCLAW_HOME"
    echo ""
    echo "Examples:"
    echo "  $0 backup.zip .bashrc projects/myapp"
    echo "  $0 code.zip projects/"
    exit 1
fi

OUTPUT_ZIP="$1"
shift

# Ensure zip is available
if ! command -v zip > /dev/null 2>&1; then
    echo "Error: 'zip' is not installed. Install it with: apt install zip"
    exit 1
fi

# Verify the home directory exists
if [ ! -d "$OPENCLAW_HOME" ]; then
    echo "Error: OpenClaw home directory not found at $OPENCLAW_HOME"
    exit 1
fi

# Validate that all requested paths exist
for item in "$@"; do
    full_path="$OPENCLAW_HOME/$item"
    if [ ! -e "$full_path" ]; then
        echo "Error: '$item' not found in $OPENCLAW_HOME"
        exit 1
    fi
done

# Create the zip from inside the home directory so paths are relative
cd "$OPENCLAW_HOME"
zip -r "$OLDPWD/$OUTPUT_ZIP" "$@"

echo ""
echo "Done. Created: $OLDPWD/$OUTPUT_ZIP"
