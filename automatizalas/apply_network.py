#!/usr/bin/env python3
"""Optional real/emulated IOS SSH deployment. Default is preview, --apply writes.
Requires netmiko. Verify SSH host keys out of band and populate known_hosts first.
"""
import argparse
from datetime import datetime
from getpass import getpass
import json
import os
from pathlib import Path
from generate_network import render

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--inventory', type=Path, default=Path(__file__).with_name('devices.json'))
    p.add_argument('--apply', action='store_true')
    p.add_argument('--backup-dir', type=Path, default=Path('network-backups'))
    args = p.parse_args()
    devices = json.loads(args.inventory.read_text(encoding='utf-8'))
    configs = render(devices)
    for d in devices:
        print(f"{d['hostname']} at {d['management_ip']}\n{configs[d['hostname']]}")
    if not args.apply:
        print('Preview only. No connection or change made.')
        return
    from netmiko import ConnectHandler
    username = input('IOS username: ')
    password = getpass('IOS password: ')
    secret = getpass('Enable secret (blank if unnecessary): ')
    os.umask(0o077)
    dest = args.backup_dir / datetime.now().strftime('%Y%m%d-%H%M%S')
    dest.mkdir(parents=True, exist_ok=False)
    for d in devices:
        with ConnectHandler(device_type='cisco_ios', host=d['management_ip'], username=username,
                            password=password, secret=secret, ssh_strict=True, system_host_keys=True) as conn:
            if secret:
                conn.enable()
            before = conn.send_command('show running-config')
            (dest / f"{d['hostname']}-before.cfg").write_text(before, encoding='utf-8')
            lines = configs[d['hostname']].splitlines()[1:-1]
            output = conn.send_config_set(lines, error_pattern=r'% (?:Invalid|Error|Incomplete|Ambiguous)')
            after = conn.send_command('show vlan brief')
            (dest / f"{d['hostname']}-result.txt").write_text(output + '\n' + after, encoding='utf-8')
            print(after)
    print('Review every device. Save running to startup manually after acceptance. Backups may contain secrets.')
if __name__ == '__main__':
    main()
