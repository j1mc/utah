#!/usr/bin/bash
# Strip build-time residue that `bootc container lint --fatal-warnings` rejects,
# then make what survives reproducible.
#
# Two jobs, in that order. The first is the lint sweep described below. The
# second (utah#313) drops the dnf5 transaction history and pins every mtime the
# image still carries to a fixed SOURCE_DATE_EPOCH, so a rebuild that changes
# nothing produces identical layer digests. Both belong here because this is the
# final layer: chunkah reads the merged rootfs, so a write here is the last one
# and wins over the wall-clock mtimes the package and extension steps left.
#
# This mirrors the filesystem portion of Bluefin's
# build_files/shared/clean-stage.sh, deliberately: Utah keeps Bluefin's package
# contract, so it inherits Bluefin's image hygiene too. Bluefin's script also
# disables flatpak-add-fedora-repos.service and clears a dnf5 versionlock,
# neither of which exists here.
#
# The three lint checks this satisfies, all seen failing on a real build:
#
#   nonempty-run-tmp  /run/cockpit, /run/dnf and friends. /run is a tmpfs at
#                     runtime, so anything baked into the image is junk.
#   var-log           /var/log/dnf5.log and its rotations, written by the
#                     install step itself.
#   var-tmpfiles      /var/cache/ibus, ldconfig, libX11, swcatalog and ~40 more
#                     directories with no systemd tmpfiles.d entry.

set -eoux pipefail

# Applied as a prefix to every path so the script can be exercised against a
# temporary directory rather than the live filesystem.
CLEAN_ROOT="${CLEAN_ROOT:-/}"

# Everything under /var except the caches bootc expects to survive. This also
# takes /var/log and /var/lib, which is where the remaining lint offenders
# lived -- the ssh-host-keys migration stamp, the ibus registry, ldconfig's
# aux-cache and the swcatalog .xb files are all inside directories removed
# here, so no separate file sweep is needed.
find "${CLEAN_ROOT}/var"/* -maxdepth 0 -type d \! -name cache -exec rm -fr {} \;
# libdnf5 is not among them, despite what this used to say. The Containerfile
# already deletes /var/cache/libdnf5 outright after the main transaction, and
# main ships with no such directory and passes lint, so nothing needs it. What
# put it back on the NVIDIA flavors is the GPG key imported for NVIDIA own
# repository: `dnf clean all` removes the metadata but leaves the keyring, so
# the tree survives, and bootc lint rejects both the untracked directories and
# the key file inside them:
#   d /var/cache/libdnf5/nvidia-container-toolkit-<hash>/pubring
#   var/cache/libdnf5/nvidia-container-toolkit-<hash>/pubring/DDCAE044F796ECB0.pub
#
# This is a function because the font-cache rebuild at the end of the script can
# put a fresh directory back here: fontconfig picks the first writable entry in
# its cachedir list, and a configuration that lists /var/cache/fontconfig before
# /usr/lib/fontconfig/cache -- the stock upstream order, which any host running
# this script outside the Fedora image has -- would leave one behind after the
# sweep below has already run. Whatever the rebuild deposits there is a cache
# bootc does not expect, so the sweep is applied again once fc-cache is done.
#
# The sweep walks the directory rather than a `/var/cache/*` glob: the second
# call runs after the first has already emptied it, and on a flavor that ships
# no /var/cache/rpm-ostree the glob then matches nothing, so `find` is handed
# the literal pattern, reports "No such file or directory" and exits 1 -- which
# under `set -e` takes the build down with it.
prune_var_cache() {
    [ -d "${CLEAN_ROOT:?}/var/cache" ] || return 0
    find "${CLEAN_ROOT:?}/var/cache" -mindepth 1 -maxdepth 1 -type d \! -name rpm-ostree -exec rm -fr {} \;
}
prune_var_cache

# /run and /tmp are cleared by emptying them, not by replacing them. The
# container runtime bind-mounts /run/.containerenv, so `rm -rf /run` fails with
#     rm: cannot remove '/run/.containerenv': Device or resource busy
# and takes the build with it. A bind mount is not part of the committed layer,
# so what lint sees is only what we leave behind inside these directories.
clear_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
}
clear_dir "${CLEAN_ROOT:?}/run"
clear_dir "${CLEAN_ROOT:?}/tmp"

# The prebuilt kernel and NVIDIA archives the cache image supplies as its base
# layer. They are build input, not image content, and they are large -- three of
# the four flavors would otherwise ship roughly 1.5 GB of tarballs they have
# already unpacked. main never has this directory at all.
rm -rf "${CLEAN_ROOT:?}/utah-cache"

# dnf5 records every transaction in a SQLite database under the sysroot:
# usr/lib/sysimage/libdnf5/transaction_history.sqlite (with its -shm and -wal
# companions). It is build-time metadata -- nothing at runtime reads it -- and
# it carries a wall-clock mtime plus an in-memory page cache, so it both wastes
# space and churns the layer that carries it on every rebuild. Drop it the same
# way the residue above is dropped (utah#313).
for db in transaction_history.sqlite transaction_history.sqlite-shm transaction_history.sqlite-wal; do
    rm -f "${CLEAN_ROOT:?}/usr/lib/sysimage/libdnf5/${db}"
done

# Reproducible builds: a rebuild that changes nothing must produce an identical
# image. dnf, meson and the extension build write wall-clock mtimes into /usr
# and /etc, and chunkah splits those directories across layers, so a changed
# mtime in any tar header changes that layer's digest. Pin every file and
# directory under /usr and /etc to SOURCE_DATE_EPOCH so a layer's digest is a
# function of its content alone, not the CI wall-clock (utah#313). The value is
# a fixed epoch, identical for every build, so the digest no longer depends on
# when the build ran.
#
# -h is load-bearing: without it touch follows symlinks, and a real image tree
# is full of links whose target is not in the image -- /usr/lib/bootc/storage,
# /usr/share/licenses/malcontent/COPYING, the 32-bit libstdc++.a stubs. touch
# then reports "No such file or directory" per broken link and exits non-zero,
# which under `set -e` kills the whole build layer. -h stamps the link itself,
# which is also the mtime that lands in the tar header, so it is the correct
# target here and not merely a way to dodge the error.
#
# The sweep has to cover the directories this script rewrites, not only /usr and
# /etc. Removing an entry from /var, /var/cache, /run, /tmp and / updates that
# directory's own mtime to the wall clock, and /var/cache is a parent of the
# surviving /var/cache/rpm-ostree, so a chunkah layer carries those entries and
# its digest would still vary per rebuild. Pin them too, after the removals
# above, which is why this block is last in the script.
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1704067200}"
pin() {
    touch -h -d "@${SOURCE_DATE_EPOCH}" "$@"
}
# Pin `path` and every directory between it and CLEAN_ROOT, the root included.
# Creating or rewriting a file stamps the wall clock on its parent, and on that
# parent's parent when the entry itself is new, so a write that lands after the
# sweep below has to be followed up the tree or the layer carrying any of those
# directories churns again.
pin_upwards() {
    local path="$1" root="${CLEAN_ROOT%/}"
    while [ "$path" != "$root" ] && [ "$path" != "/" ] && [ -n "$path" ]; do
        # A path the sweep removed again -- /var/cache/fontconfig after the
        # second prune -- has no mtime to pin, but its parents still do.
        if [ -e "$path" ] || [ -L "$path" ]; then
            pin "$path"
        fi
        path="${path%/*}"
    done
    pin "${CLEAN_ROOT:?}"
}
for base in usr etc var; do
    [ -d "${CLEAN_ROOT:?}/${base}" ] || continue
    find "${CLEAN_ROOT}/${base}" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
done
# The root itself plus the two directories cleared in place. They are pinned
# non-recursively because clear_dir already left them empty.
for dir in "" /run /tmp; do
    [ -d "${CLEAN_ROOT:?}${dir}" ] || continue
    touch -h -d "@${SOURCE_DATE_EPOCH}" "${CLEAN_ROOT}${dir}"
done

# Pinning /usr invalidates every system fontconfig cache, so rebuild them here.
# fontconfig only accepts a cache in /usr/lib/fontconfig/cache whose stored
# checksum equals the font directory's current mtime exactly
# (FcDirCacheValidateHelper in fccache.c). Fedora's fontconfig package rebuilds
# those caches from a %transfiletriggerin that runs `fc-cache -s` inside the dnf
# transaction that installs Utah's fonts, so the checksums it stores are the
# wall-clock mtimes dnf just wrote. The pin loop above then re-stamps every
# /usr/share/fonts directory to SOURCE_DATE_EPOCH, which leaves every one of
# those caches stale: nothing else in the image re-runs fc-cache, so at runtime
# each fontconfig client rescans the whole font tree into ~/.cache/fontconfig --
# on every start, for any account whose home is not writable.
#
# So re-run it after the pin, when the directory mtimes are already final, and
# export SOURCE_DATE_EPOCH: fontconfig clamps both the checksum and its nanosecond
# field to that value, so the cache files are byte-identical across rebuilds.
# --sysroot keeps the rebuild inside CLEAN_ROOT, which is what makes this safe to
# exercise against a scratch tree instead of the live filesystem.
#
# fc-cache writes those files now, with the wall clock, so re-pin the cache
# directories afterwards or this reintroduces the churn the pin removed.
if command -v fc-cache >/dev/null 2>&1; then
    SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" \
        fc-cache --sysroot="${CLEAN_ROOT:?}" --force --system-only
    # fontconfig writes to the first writable cachedir its configuration lists.
    # On the Fedora base that is /usr/lib/fontconfig/cache, but the stock
    # upstream order puts /var/cache/fontconfig first, and bootc expects nothing
    # under /var/cache but rpm-ostree -- so sweep /var/cache again rather than
    # ship a directory the lint rejects.
    prune_var_cache
    for cache in /usr/lib/fontconfig/cache /var/cache/fontconfig; do
        [ -d "${CLEAN_ROOT:?}${cache}" ] || continue
        find "${CLEAN_ROOT}${cache}" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
    done
    # Both the rebuild and the sweep above ran after the pin loop, so every
    # directory on the way to a cache -- /usr/lib/fontconfig, /usr/lib, /usr,
    # /var/cache, /var and the root -- carries a wall-clock mtime again. Walk
    # each path back up to the root and re-pin it.
    for path in /usr/lib/fontconfig/cache /var/cache/fontconfig /var/cache; do
        pin_upwards "${CLEAN_ROOT:?}${path}"
    done
else
    # Not reachable in the image build -- fontconfig is a dependency of the
    # desktop -- but the script is also run against scratch trees that have no
    # font tooling at all, and a missing fc-cache there is not a failure.
    echo "clean-stage: fc-cache not found, skipping font cache rebuild" >&2
fi
