#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# start-claude
#
# Purpose:
#   Starts Claude Code with:
#     --allow-dangerously-skip-permissions
#     --remote-control "<session name>"
#
# Command used:
#   claude --allow-dangerously-skip-permissions --remote-control "<session name>"
#
# -----------------------------------------------------------------------------
# INSTALLATION EXAMPLE
#
# 1. Create or edit the script:
#      sudo nano /usr/local/bin/start-claude
#
# 2. Paste this script into the file.
#
# 3. Save in nano:
#      Ctrl+O
#      Enter
#      Ctrl+X
#
# 4. Make it executable:
#      sudo chmod +x /usr/local/bin/start-claude
#
# 5. Verify it is available globally:
#      which start-claude
#
#    Expected output:
#      /usr/local/bin/start-claude
#
# Because this script lives in /usr/local/bin, it should be runnable from
# anywhere on the machine, as long as /usr/local/bin is in your PATH.
# -----------------------------------------------------------------------------
#
# SESSION NAME BEHAVIOR
#
# 1. If you pass a first argument that does not start with "-", that value
#    is used as the session name.
#
#    Example:
#      start-claude "my session"
#
#    This runs:
#      claude --allow-dangerously-skip-permissions --remote-control "my session"
#
# 2. If you do not pass a session name, the script generates one using:
#      {server_name or hostname}-{MMDDHH}-{###}
#
#    Where:
#      - server_name = value of environment variable "server_name"
#      - hostname    = machine hostname if server_name is not set
#      - MM          = month in 2 digits
#      - DD          = day in 2 digits
#      - HH          = hour in 24-hour format
#      - ###         = random 3-digit number from 000 to 999
#
#    Example generated name:
#      myserver-031510-482
#
# -----------------------------------------------------------------------------
# OPTIONAL server_name ENVIRONMENT VARIABLE
#
# If you want to define server_name permanently for your user:
#
#   1. Edit your shell profile:
#        nano ~/.bashrc
#
#   2. Add a line like:
#        export server_name="myserver"
#
#   3. Save and exit nano:
#        Ctrl+O
#        Enter
#        Ctrl+X
#
#   4. Reload your shell config:
#        source ~/.bashrc
#
# If server_name is not set, the script falls back to:
#   hostname
# -----------------------------------------------------------------------------
#
# EXTRA ARGUMENTS
#
# Any remaining arguments are passed through to the Claude CLI.
#
# Examples:
#   start-claude
#   start-claude "my session name"
#   start-claude "my session name" --help
#
# -----------------------------------------------------------------------------
# NOTES
#
# - The first non-flag argument is treated as the session name.
# - If no session name is provided, one is generated automatically.
# - The command is intended to live at:
#     /usr/local/bin/start-claude
#   so it can be run from anywhere on the machine.
# -----------------------------------------------------------------------------

# If first argument exists and is not a flag, use it as the session name.
session_name=""
if [[ $# -gt 0 && "${1}" != -* ]]; then
  session_name="$1"
  shift
fi

# Generate a session name if none was provided.
if [[ -z "$session_name" ]]; then
  # Prefer the environment variable "server_name" if it exists.
  base_name="${server_name:-}"

  # Fall back to the machine hostname if server_name is empty or unset.
  if [[ -z "$base_name" ]]; then
    base_name="$(hostname)"
  fi

  # Build timestamp in MMDDHH format.
  timestamp="$(date +%m%d%H)"

  # Generate a random 3-digit number from 000 to 999.
  rand="$(printf "%03d" "$(( RANDOM % 1000 ))")"

  # Compose the final session name.
  session_name="${base_name}-${timestamp}-${rand}"
fi

# Start Claude Code with the resolved session name.
exec claude \
  --allow-dangerously-skip-permissions \
  --remote-control "$session_name" \
  "$@"
