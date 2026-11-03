#!/usr/bin/env python3
"""Run real installer transactions against a temporary filesystem and service doubles."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'install-selfsteal.sh'

DOUBLES = r'''
# All paths and service calls are isolated; no root privileges are needed here.
need_root() { :; }
systemctl() {
  case "$1" in
    show) echo 99 ;;
    is-active) [[ -f "$TEST_ROOT/active" ]] ;;
    is-enabled) if [[ -f "$TEST_ROOT/enabled" ]]; then echo enabled; else echo disabled; return 1; fi ;;
    start|restart|reload) touch "$TEST_ROOT/active" ;;
    stop) rm -f "$TEST_ROOT/active" ;;
    enable) touch "$TEST_ROOT/enabled" ;;
    disable) rm -f "$TEST_ROOT/enabled" ;;
    *) return 1 ;;
  esac
}
apt-get() { :; }
caddy() { [[ "${FAIL_VALIDATE:-0}" != 1 || "$1" != validate ]]; }
getent() { if [[ "$1" == ahostsv4 ]]; then printf '8.8.8.8 STREAM node\n'; fi; }
ip() { :; }
sleep() { :; }
journalctl() { :; }
runuser() {
  [[ "$1" == -u && "$2" == caddy && "$3" == -- && "$4" == test && "$5" == -x ]] || return 2
  [[ "${DENY_WEB_PARENT:-0}" != 1 ]] && test -x "$6"
}
curl() {
  [[ "${FAIL_CERT:-0}" != 1 ]] || return 60
  if [[ "${WRONG_PAGE:-0}" == 1 ]]; then echo 'another website'; else cat "$WEB_ROOT/index.html"; fi
}
ss() {
  if [[ "${CONFLICT:-0}" == 1 ]]; then
    printf 'tcp LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("caddy",pid=99,fd=1))\n'
    printf 'tcp LISTEN 0 4096 [::]:80 [::]:* users:(("nginx",pid=100,fd=1))\n'
  elif [[ "$*" == *'sport = :8443'* && "$1" == -lntpH && -f "$TEST_ROOT/active" ]]; then
    printf 'LISTEN 0 4096 127.0.0.1:8443 0.0.0.0:* users:(("caddy",pid=99,fd=1))\n'
  fi
}
'''


class ManagementTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.script = self.root / 'installer.sh'
        source = SCRIPT.read_text()
        replacements = {
            '/etc/caddy/Caddyfile': str(self.root / 'etc/Caddyfile'),
            '/var/www/remnawave-selfsteal': str(self.root / 'www'),
            '/etc/remnawave-selfsteal.conf': str(self.root / 'etc/state'),
            '/var/lib/remnawave-selfsteal/backups': str(self.root / 'backups'),
            '/usr/local/sbin/remnawave-selfsteal': str(self.root / 'bin/cli'),
            '/run/lock/remnawave-selfsteal.lock': str(self.root / 'lock'),
        }
        for old, new in replacements.items():
            source = source.replace(old, new)
        self.script.write_text(source)
        (self.root / 'etc').mkdir()
        (self.root / 'bin').mkdir()
        (self.root / 'www').mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def run_shell(self, commands, **env):
        return subprocess.run(
            ['bash', '-c', f'source "$TEST_ROOT/installer.sh"\n{DOUBLES}\n{commands}'],
            env={**os.environ, 'TEST_ROOT': str(self.root), **env},
            text=True, capture_output=True, timeout=20,
        )

    def existing(self):
        (self.root / 'etc/Caddyfile').write_text('# Managed by remnawave-selfsteal 1.0.2\nold-config\n')
        (self.root / 'etc/state').write_text('DOMAIN=old.example.com\nPUBLIC_IPV4=8.8.8.8\n')
        (self.root / 'www/index.html').write_text('<html>custom page</html>\n')
        (self.root / 'bin/cli').write_text('old-cli\n')
        (self.root / 'bin/cli').chmod(0o755)
        (self.root / 'active').touch()
        (self.root / 'enabled').touch()

    def install(self, **env):
        return self.run_shell('main --domain node.example.com --expected-ip 8.8.8.8', **env)

    def test_missing_web_parent_is_created_with_traverse_permissions(self):
        self.script.write_text(self.script.read_text().replace(
            str(self.root / 'www'), str(self.root / 'new-parent/site')))
        result = self.run_shell('prepare_web_parent')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'new-parent').stat().st_mode & 0o777, 0o755)

    def test_inaccessible_web_parent_is_rejected_without_chmod(self):
        original_mode = self.root.stat().st_mode & 0o777
        result = self.install(DENY_WEB_PARENT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Пользователь caddy не может пройти', result.stderr)
        self.assertEqual(self.root.stat().st_mode & 0o777, original_mode)
        self.assertFalse((self.root / 'www/index.html').exists())

    def test_upgrade_preserves_page_and_installs_management(self):
        self.existing()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual((self.root / 'www/index.html').read_text(), '<html>custom page</html>\n')
        self.assertIn('1.1.0', (self.root / 'bin/cli').read_text())
        self.assertEqual(len(list((self.root / 'backups').glob('*/complete-v1'))), 1)

    def test_failed_certificate_restores_files_and_active_service(self):
        self.existing()
        result = self.install(FAIL_CERT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('old-config', (self.root / 'etc/Caddyfile').read_text())
        self.assertIn('old.example.com', (self.root / 'etc/state').read_text())
        self.assertEqual((self.root / 'bin/cli').read_text(), 'old-cli\n')
        self.assertTrue((self.root / 'active').exists())
        self.assertTrue((self.root / 'enabled').exists())

    def test_failed_first_install_removes_new_files_and_disables_service(self):
        result = self.install(FAIL_CERT='1')
        self.assertNotEqual(result.returncode, 0)
        for path in ['etc/Caddyfile', 'www/index.html', 'etc/state', 'bin/cli', 'active', 'enabled']:
            self.assertFalse((self.root / path).exists(), path)

    def test_validation_failure_rolls_back_page(self):
        self.existing()
        custom = self.root / 'new.html'
        custom.write_text('replacement')
        result = self.run_shell('main --domain node.example.com --expected-ip 8.8.8.8 --page "$TEST_ROOT/new.html"', FAIL_VALIDATE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('custom page', (self.root / 'www/index.html').read_text())

    def test_mixed_caddy_and_foreign_listener_rejected_before_backup(self):
        result = self.install(CONFLICT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'backups').exists())

    def test_foreign_config_rejected(self):
        (self.root / 'etc/Caddyfile').write_text('other.example.com { respond "hi" }')
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'backups').exists())

    def test_restore_returns_previous_domain_and_creates_safety_copy(self):
        self.existing()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        backup = next((self.root / 'backups').iterdir()).name
        result = self.run_shell(f'management restore {backup}')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn('old.example.com', (self.root / 'etc/state').read_text())
        self.assertIn('old-config', (self.root / 'etc/Caddyfile').read_text())
        self.assertEqual(len(list((self.root / 'backups').glob('*/complete-v1'))), 2)

    def test_stopped_disabled_state_survives_rollback(self):
        self.existing()
        (self.root / 'active').unlink()
        (self.root / 'enabled').unlink()
        result = self.install(FAIL_CERT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'active').exists())
        self.assertFalse((self.root / 'enabled').exists())

    def test_wrong_https_page_is_not_success(self):
        self.existing()
        result = self.run_shell('https_check 443', WRONG_PAGE='1')
        self.assertNotEqual(result.returncode, 0)

    def test_restore_rejects_path_traversal(self):
        self.existing()
        result = self.run_shell('management restore ../../etc')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('old-config', (self.root / 'etc/Caddyfile').read_text())

    def test_page_failure_restores_previous_page(self):
        self.existing()
        (self.root / 'new.html').write_text('new page')
        result = self.run_shell('management page "$TEST_ROOT/new.html"', FAIL_CERT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('custom page', (self.root / 'www/index.html').read_text())

    def test_exclusive_lock_rejects_concurrent_mutation(self):
        result = self.run_shell('(acquire_lock; flock -n "$LOCK_FILE" -c true)')
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
