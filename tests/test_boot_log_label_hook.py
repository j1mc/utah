"""`06-boot-log-label.sh` must repair /var/log/boot.log's label before stamping.

#689: the first plymouth-shipping image (testing-20261010, #666) boots with
`plymouthd_t` denied `append` on a `boot.log` file labeled `var_t`. The
targeted policy already maps `/var/log/boot.log.*` to `plymouthd_var_log_t`,
which `plymouthd_t` may write, so the hook repairs the label with restorecon
instead of shipping a custom policy module -- and it must verify the real
on-disk label before committing, the way `20-home-labels.sh` does (#474).

Host-side tests cannot exercise restorecon or SELinux labels, so like
`test_setup_hook_version_contract.py` these assert the contract statically:
transient skips before the version check, check before the body, the body
before the commit, and no legacy burn-before-body gate.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = (
    ROOT
    / "system_files/shared/usr/share/ublue-os/privileged-setup.hooks.d"
    / "06-boot-log-label.sh"
)


class BootLogLabelHookContractTests(unittest.TestCase):
    def setUp(self):
        self.body = HOOK.read_text()
        self.lines = [
            line.strip()
            for line in self.body.splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]

    def test_hook_exists_and_is_executable(self):
        self.assertTrue(HOOK.is_file())
        self.assertTrue(HOOK.stat().st_mode & 0o111)

    def test_does_not_use_the_legacy_burn_before_body_gate(self):
        self.assertNotIn(
            "version-script boot-log-label",
            self.lines,
            "the legacy helper stamps completion before the body runs",
        )

    def test_selinux_disabled_skip_sits_before_the_version_check(self):
        # A transient skip placed after the check would be recorded as done
        # under the compat shim's legacy fallback and never retried.
        check = "version-script-check boot-log-label privileged 1 || exit 0"
        self.assertIn(check, self.lines)
        guard = "if ! selinuxenabled >/dev/null 2>&1; then"
        self.assertIn(guard, self.lines)
        self.assertLess(self.lines.index(guard), self.lines.index(check))

    def test_checks_before_it_acts(self):
        check = "version-script-check boot-log-label privileged 1 || exit 0"
        self.assertIn(check, self.lines)
        self.assertLess(
            self.lines.index(check),
            self.lines.index("restorecon -F /var/log/boot.log"),
        )

    def test_absent_log_file_skips_without_committing(self):
        # On a fresh install plymouth has not created the log yet; stamping
        # then would skip the repair forever.
        self.assertIn("if [[ ! -e /var/log/boot.log ]]; then", self.lines)
        self.assertLess(
            self.lines.index("if [[ ! -e /var/log/boot.log ]]; then"),
            self.lines.index("restorecon -F /var/log/boot.log"),
        )

    def test_repairs_the_policy_defined_type(self):
        # /var/log/boot.log.* maps to plymouthd_var_log_t in the targeted
        # policy; var_t is the mislabelled state from #689.
        self.assertIn("restorecon -F /var/log/boot.log", self.lines)
        self.assertIn("plymouthd_var_log_t", self.body)

    def test_commits_only_after_verifying_the_on_disk_label(self):
        # restorecon exiting zero does not prove the label changed (#474), so
        # the hook stats the file and aborts (set -e) before the commit when
        # the context is still wrong.
        commit = "version-script-commit boot-log-label privileged 1"
        self.assertIn(commit, self.lines)
        self.assertLess(
            self.lines.index("restorecon -F /var/log/boot.log"),
            self.lines.index(commit),
        )
        self.assertLess(
            self.lines.index(
                'if [[ "$boot_log_context" != *:plymouthd_var_log_t:* ]]; then'
            ),
            self.lines.index(commit),
        )

    def test_body_failure_aborts_before_the_commit(self):
        self.assertIn("set -xeuo pipefail", self.lines)
        self.assertLess(
            self.lines.index("set -xeuo pipefail"),
            self.lines.index("restorecon -F /var/log/boot.log"),
        )

    def test_compat_shim_covers_pre_1196_libsetup(self):
        body = self.body
        self.assertIn("if ! declare -F version-script-check >/dev/null; then", body)
        self.assertIn("version-script-commit() { :; }", body)

    def test_names_the_issue_it_repairs(self):
        self.assertIn("#689", self.body)


if __name__ == "__main__":
    unittest.main()
