#!/usr/bin/bash
# Relabel /var/log/boot.log so plymouthd can append to it (#689).
#
# The testing-20261010 image was the first to ship plymouth (#666), and on
# boot plymouthd is denied append on /var/log/boot.log:
#
#   avc: denied { append } for comm="plymouthd" name="boot.log"
#       scontext=system_u:system_r:plymouthd_t:s0
#       tcontext=system_u:object_r:var_t:s0 tclass=file
#
# The on-disk file is labeled var_t, a generic type the plymouthd_t domain
# cannot write to. The targeted policy already defines the right type for
# this path -- plymouthd_var_log_t, mapped from /var/log/boot.log.* in the
# policy's own file contexts -- which plymouthd_t may append to. So this is
# a mislabeled file, not a missing policy rule, and no custom SELinux module
# is needed: restorecon applies the policy's mapping, and the corrected
# label persists on disk (later truncations keep it; only a delete-and-
# recreate by a domain without a proper transition would regress it, and
# there is no evidence of that). The splash itself renders fine; the denial
# is silent, so without this repair it would recur on every boot.
#
# First-boot-only: common#1196 split `version-script` into a read-only check
# (`version-script-check`) and a commit (`version-script-commit`) so a failed
# first-boot hook retries next boot rather than being skipped forever after.
# The compat shim below lets this hook work under either contract in either
# merge order, matching 20-home-labels.sh.

# shellcheck source=/dev/null
source /usr/lib/ublue/setup-services/libsetup.sh

# Compat shim: common libsetup.sh builds older than projectbluefin/common#1196
# have only version-script, which records the version before the body runs, and
# no version-script-check/version-script-commit pair. Fall back to that legacy
# gate and make the commit a no-op, so this hook works against both contracts.
if ! declare -F version-script-check >/dev/null; then
    version-script-check() { version-script "$@"; }
    version-script-commit() { :; }
fi

# Without SELinux there are no labels to repair. This is a transient skip
# (no commit): a later boot with SELinux enabled retries. It sits before the
# version check because under the compat shim the check is the legacy stamp,
# and a skip placed after it would be recorded as done and never retried.
if ! selinuxenabled >/dev/null 2>&1; then
    echo "boot-log-label: SELinux disabled; skipping"
    exit 0
fi

version-script-check boot-log-label privileged 1 || exit 0

set -xeuo pipefail

# /var/log/boot.log may not exist yet on a fresh install -- plymouth creates
# it during boot. There is nothing to relabel, so exit without committing and
# retry once the file appears.
if [[ ! -e /var/log/boot.log ]]; then
    echo "boot-log-label: /var/log/boot.log absent; skipping"
    exit 0
fi

# Repair the label from the policy's own file contexts: /var/log/boot.log.*
# maps to plymouthd_var_log_t, which plymouthd_t may append to.
restorecon -F /var/log/boot.log

# restorecon's exit code does not tell us the label is actually correct (a
# policy without the mapping would let it finish having changed nothing, as
# 20-home-labels.sh learned with mismatched homedirs in #474). Check the real
# on-disk context before committing, so a machine that is still mislabeled
# retries next boot instead of being marked done forever.
boot_log_context=$(stat -c '%C' /var/log/boot.log)
if [[ "$boot_log_context" != *:plymouthd_var_log_t:* ]]; then
    echo "ERROR: /var/log/boot.log labels as ${boot_log_context}, want plymouthd_var_log_t" >&2
    exit 1
fi

# Record success only after the body ran, so a failing first-boot hook retries
# next boot instead of being permanently skipped (common#1196 new contract).
version-script-commit boot-log-label privileged 1
