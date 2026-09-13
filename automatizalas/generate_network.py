#!/usr/bin/env python3
"""Generate IOS VLAN configuration from inventory; never connects to devices."""
import argparse
import ipaddress
import json
from pathlib import Path
import re
NAMES = {10:'MGMT',20:'SERVER',30:'ADMIN',40:'SALES',50:'LOGISTICS',60:'VOIP',70:'WIFI-STAFF',80:'WIFI-GUEST'}
def render(devices):
    result = {}
    for device in devices:
        name = device['hostname']
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9-]{0,62}', name) or name in result:
            raise ValueError('Invalid or duplicate hostname')
        ipaddress.IPv4Address(device['management_ip'])
        vlans = device['vlans']
        if any(type(v) is not int or v not in NAMES for v in vlans) or len(set(vlans)) != len(vlans):
            raise ValueError('Invalid or duplicate VLAN')
        lines = ['configure terminal', f'hostname {name}']
        for vlan in vlans:
            lines += [f'vlan {vlan}', f' name {NAMES[vlan]}', 'exit']
        lines += ['end']
        result[name] = '\n'.join(lines) + '\n'
    return result
if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--inventory', type=Path, default=Path(__file__).with_name('devices.json'))
    p.add_argument('--output', type=Path, default=Path(__file__).with_name('generated'))
    args = p.parse_args()
    configs = render(json.loads(args.inventory.read_text(encoding='utf-8')))
    args.output.mkdir(parents=True, exist_ok=True)
    for hostname, config in configs.items():
        path = args.output / f'{hostname}-generated.cfg'
        path.write_text(config, encoding='ascii')
        print(path)
