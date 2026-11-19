import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HOST = Path(__file__).resolve().parent


class WifiToolsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        self.env['EVENTS'] = str(self.root / 'events')
        for name in ('logger', 'sleep'):
            self.stub(name, 'exit 0')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o755)

    def run_bash(self, source):
        return subprocess.run(['bash', '-c', source], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def events(self):
        path = self.root / 'events'
        return path.read_text() if path.exists() else ''

    def portable(self, binding='wlxOLD', mac='', mode='infrastructure', active=True):
        self.env.update(BINDING=binding, MAC=mac, MODE=mode)
        self.stub('systemctl', 'exit ' + ('0' if active else '1'))
        self.stub('id', 'echo 0')
        self.stub('mktemp', 'printf "%s\\n" "$TMP_BACKUP"')
        self.env['TMP_BACKUP'] = str(self.root / 'backup')
        (self.root / 'backup').mkdir()
        self.stub('cp', 'echo BACKUP >> "$EVENTS"')
        self.stub('nmcli', '''case "$*" in
'-t -f UUID,TYPE connection show') printf 'test-uuid:802-11-wireless\\nother:802-3-ethernet\\n' ;;
'-g 802-11-wireless.mode connection show uuid test-uuid') printf '%s\\n' "$MODE" ;;
'-g connection.interface-name connection show uuid test-uuid') printf '%s\\n' "$BINDING" ;;
'-g 802-11-wireless.mac-address connection show uuid test-uuid') printf '%s\\n' "$MAC" ;;
'connection modify uuid test-uuid connection.interface-name  802-11-wireless.mac-address ') echo MODIFY >> "$EVENTS" ;;
*) echo "Unexpected nmcli call: $*" >&2; exit 90 ;;
esac''')
        return self.run_bash((HOST / 'wifi-portable.sh').read_text())

    def test_interface_binding_backed_up_before_modify(self):
        result = self.portable()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), 'BACKUP\nMODIFY\n')

    def test_mac_binding_removed(self):
        result = self.portable(binding='', mac='00:11:22:33:44:55')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('MODIFY', self.events())

    def test_unbound_profile_unchanged(self):
        result = self.portable(binding='')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), '')

    def test_hotspot_unchanged(self):
        result = self.portable(mode='ap')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), '')

    def test_inactive_networkmanager_unchanged(self):
        result = self.portable(active=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), '')

    def function(self, name):
        source = (HOST / 'wifi-watchdog.sh').read_text()
        start = source.index(name + '() {')
        end = source.index('\n}', start) + 2
        return source[start:end]

    def test_usb_interface_resolves_to_device_not_hub(self):
        device = self.root / '3-1.4'
        device.mkdir()
        (device / 'idVendor').write_text('0bda')
        interface = device / '3-1.4:1.0'
        interface.mkdir()
        self.stub('readlink', 'printf "%s\\n" "$USB_INTERFACE"')
        self.env['USB_INTERFACE'] = str(interface)
        result = self.run_bash(self.function('usb_device') + '\nusb_device wlxNEW')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '3-1.4')

    def test_non_usb_interface_rejected(self):
        self.stub('readlink', 'echo /platform/onboard/net/wlan0')
        result = self.run_bash(self.function('usb_device') + '\nusb_device wlan0')
        self.assertNotEqual(result.returncode, 0)

    def test_rebind_rejects_interface_and_root_hub(self):
        for device in ('3-1.4:1.0', 'usb3', '../3-1'):
            result = self.run_bash(self.function('rebind') + '\nrebind ' + device)
            self.assertNotEqual(result.returncode, 0)

    def watchdog_fixture(self):
        usb = self.root / 'usb'
        device = usb / 'devices' / '3-1.4'
        interface = device / '3-1.4:1.0'
        interface.mkdir(parents=True)
        (device / 'idVendor').write_text('0bda')
        drivers = usb / 'drivers' / 'usb'
        drivers.mkdir(parents=True)
        for name in ('bind', 'unbind'):
            (drivers / name).touch()
        network = self.root / 'net' / 'wlxNEW'
        (network / 'wireless').mkdir(parents=True)
        (network / 'device').symlink_to(interface)
        self.stub('systemctl', 'exit 0')
        self.stub('nmcli', 'echo RECONNECT >> "$EVENTS"')
        self.stub('ip', 'echo "default via 192.0.2.1 dev wlxNEW"')
        self.stub('flock', 'exit 0')
        source = (HOST / 'wifi-watchdog.sh').read_text()
        source = source.replace('/sys/class/net', str(self.root / 'net'))
        source = source.replace('/sys/bus/usb', str(usb))
        source = source.replace('/run/parc-wifi-watchdog.lock', str(self.root / 'lock'))
        return source, drivers

    def test_healthy_watchdog_does_not_reconnect(self):
        source, drivers = self.watchdog_fixture()
        self.stub('ping', 'exit 0')
        result = self.run_bash(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), '')
        self.assertEqual((drivers / 'unbind').read_text(), '')

    def test_failed_reconnect_rebinds_only_wifi_device(self):
        source, drivers = self.watchdog_fixture()
        self.env['PING_COUNT'] = str(self.root / 'ping-count')
        self.stub('ping', '''n=0
[ ! -f "$PING_COUNT" ] || n=$(cat "$PING_COUNT")
n=$((n+1))
printf '%s' "$n" > "$PING_COUNT"
[ "$n" -ge 3 ]''')
        result = self.run_bash(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), 'RECONNECT\nRECONNECT\n')
        self.assertEqual((drivers / 'unbind').read_text(), '3-1.4')
        self.assertEqual((drivers / 'bind').read_text(), '3-1.4')

    def test_bash_syntax(self):
        for name in ('wifi-portable.sh', 'wifi-watchdog.sh', 'deploy.sh'):
            result = subprocess.run(['bash', '-n', str(HOST / name)],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
