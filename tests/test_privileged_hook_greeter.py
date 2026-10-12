"""`99-privileged.sh` must not escalate from the GDM greeter session.

The greeter runs these per-user hooks as the transient `gdm-greeter`
account before any real user exists, and that account's SHELL is not
listed in `/etc/shells`, so `pkexec` logs an error for every greeter
session (issue #688). Privileged hooks stamp once-only completion
system-wide, so the greeter has nothing to do: the hook must skip it
and let the first real login escalate and run them.

The first half of this file is a static contract check on the hook
source. The second half drives the real hook against stub `id`/`pkexec`
binaries to prove the greeter skips without escalating while a normal
user still reaches `ublue-privileged-setup`.
"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = (
    ROOT
    / "system_files/shared/usr/share/ublue-os/user-setup.hooks.d"
    / "99-privileged.sh"
)


class PrivilegedHookGreeterContractTests(unittest.TestCase):
    def setUp(self):
        self.lines = [
            line.strip()
            for line in HOOK.read_text().splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
        self.body = HOOK.read_text()

    def test_hook_exists(self):
        self.assertTrue(HOOK.is_file())

    def test_still_escalates_to_privileged_setup(self):
        self.assertIn("pkexec /usr/bin/ublue-privileged-setup", self.lines)

    def test_greeter_guard_names_the_transient_account(self):
        self.assertIn("gdm-greeter", self.body)

    def test_guard_runs_before_the_escalation(self):
        self.assertLess(
            self.body.index("gdm-greeter"),
            self.body.index("pkexec /usr/bin/ublue-privileged-setup"),
        )

    def test_body_failure_aborts(self):
        # `set -e` keeps a failed escalation from falling through silently.
        self.assertIn("set -euo pipefail", self.lines)
        self.assertLess(
            self.lines.index("set -euo pipefail"),
            self.lines.index("pkexec /usr/bin/ublue-privileged-setup"),
        )


class PrivilegedHookGreeterBehaviourTests(unittest.TestCase):
    """Drive the real hook with the invoking user controlled by a stub `id`
    and escalation recorded by a stub `pkexec`."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fake = Path(self.tmp.name)

        bin_dir = self.fake / "bin"
        bin_dir.mkdir()

        # `id` stub: report the user under test instead of the host user.
        stub_id = bin_dir / "id"
        stub_id.write_text('#!/usr/bin/env bash\necho "${HOOK_TEST_USER}"\n')
        stub_id.chmod(0o755)

        # `pkexec` stub: record its args so tests can assert whether the
        # hook escalated, then succeed like the real privileged setup.
        pkexec = bin_dir / "pkexec"
        pkexec.write_text(
            "#!/usr/bin/env bash\n"
            'mkdir -p "${HOOK_STATE_DIR}"\n'
            'echo "$@" >> "${HOOK_STATE_DIR}/pkexec_args"\n'
            "exit 0\n"
        )
        pkexec.chmod(0o755)

        self.env = dict(os.environ)
        self.env["PATH"] = f"{bin_dir}:{os.environ['PATH']}"
        self.env["HOOK_STATE_DIR"] = str(self.fake / "state")

    def run_hook(self, user):
        self.env["HOOK_TEST_USER"] = user
        return subprocess.run(
            ["bash", str(HOOK)],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def pkexec_calls(self):
        log = self.fake / "state" / "pkexec_args"
        if not log.is_file():
            return []
        return log.read_text().splitlines()

    def test_greeter_skips_without_escalating(self):
        """The gdm-greeter session must exit 0 without invoking pkexec, so
        no /etc/shells error is logged for a session that has no privileged
        work to do anyway."""
        proc = self.run_hook("gdm-greeter")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.pkexec_calls(), [])

    def test_real_user_still_escalates(self):
        """A normal login must reach ublue-privileged-setup exactly as
        before, or the once-only privileged hooks would never run."""
        proc = self.run_hook("someuser")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.pkexec_calls(), ["/usr/bin/ublue-privileged-setup"])


if __name__ == "__main__":
    unittest.main()
