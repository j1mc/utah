#!/usr/bin/env bash

set -euo pipefail

echo "Running all privileged units"

# The GDM greeter runs these per-user hooks as the transient gdm-greeter
# account before any real user exists, and that account's SHELL is not
# listed in /etc/shells, so pkexec logs an error for every greeter session
# (#688). Privileged hooks stamp once-only completion system-wide, so there
# is nothing for the greeter to do here: skip it and let the first real
# login escalate and run them.
if [[ "$(id -un)" == "gdm-greeter" ]]; then
    echo "skipping privileged setup for the GDM greeter session; it runs at first real login"
    exit 0
fi

pkexec /usr/bin/ublue-privileged-setup
