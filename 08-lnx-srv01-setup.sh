#!/usr/bin/env bash
# Fresh Ubuntu Server 22.04 lab; static internal IP must already exist.
# This script does not rewrite netplan, enable routing, or format disks.
set -Eeuo pipefail
trap 'echo "Setup failed at line $LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 22.04 ]] || { echo 'Target is Ubuntu Server 22.04.' >&2; exit 1; }
ip -4 -o addr show | awk '{print $4}' | grep -qx '10.1.20.20/24' || { echo 'Configure internal IP 10.1.20.20/24 first.' >&2; exit 1; }
mountpoint -q /backup || { echo 'Mount a dedicated backup volume at /backup first (see VM3).' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y bind9 dnsutils nginx openssl ansible rsync
hostnamectl set-hostname lnx-srv01
stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p "/root/northline-prechange-$stamp"
cp -a /etc/bind /etc/nginx "/root/northline-prechange-$stamp/"
cat > /etc/bind/named.conf.options <<'BIND'
acl labnets { 127.0.0.1; 10.1.0.0/16; 10.2.0.0/16; 10.3.0.0/16; };
options {
 directory "/var/cache/bind";
 listen-on { 127.0.0.1; 10.1.20.20; };
 listen-on-v6 { none; };
 recursion yes;
 allow-query { labnets; };
 allow-recursion { labnets; };
 allow-transfer { none; };
 dnssec-validation auto;
};
BIND
cat > /etc/bind/named.conf.local <<'BIND'
zone "northline.local" {
 type slave;
 masters { 10.1.20.10; };
 file "/var/cache/bind/northline.local";
};
zone "_msdcs.northline.local" {
 type slave;
 masters { 10.1.20.10; };
 file "/var/cache/bind/_msdcs.northline.local";
};
BIND
named-checkconf
systemctl enable --now named
systemctl restart named
mkdir -p /var/www/northline /etc/nginx/tls
cat > /var/www/northline/index.html <<'HTML'
<!doctype html><html lang="hu"><meta charset="utf-8"><title>NorthLine intranet</title>
<style>body{font:20px system-ui;max-width:800px;margin:70px auto;padding:25px;color:#163047}h1{font-size:40px}</style>
<h1>NorthLine Logisztika Zrt.</h1><p>Három telephely közös belső információs oldala.</p>
<p>Miskolc · Debrecen · Nyíregyháza</p><p>Kiszolgáló: LNX-SRV01 · Vizsgalabor</p></html>
HTML
if [[ ! -f /etc/nginx/tls/northline.key ]]; then
 openssl req -x509 -nodes -newkey rsa:2048 -days 365 -keyout /etc/nginx/tls/northline.key -out /etc/nginx/tls/northline.crt -subj '/CN=www.northline.local' -addext 'subjectAltName=DNS:www.northline.local,DNS:lnx-srv01.northline.local,IP:10.1.20.20'
fi
chmod 600 /etc/nginx/tls/northline.key
cat > /etc/nginx/sites-available/northline <<'NGINX'
server {
 listen 10.1.20.20:80;
 listen 10.1.20.20:443 ssl;
 server_name www.northline.local lnx-srv01.northline.local;
 ssl_certificate /etc/nginx/tls/northline.crt;
 ssl_certificate_key /etc/nginx/tls/northline.key;
 ssl_protocols TLSv1.2 TLSv1.3;
 root /var/www/northline;
 index index.html;
}
NGINX
ln -sfn /etc/nginx/sites-available/northline /etc/nginx/sites-enabled/northline
nginx -t
systemctl enable --now nginx
systemctl reload nginx
cat > /usr/local/sbin/northline-backup <<'BACKUP'
#!/usr/bin/env bash
set -Eeuo pipefail
mountpoint -q /backup || { echo 'Backup disk not mounted'; exit 1; }
exec 9>/run/northline-backup.lock
flock -n 9 || exit 1
umask 077
stamp=$(date +%Y%m%d-%H%M%S)
dest="/backup/northline/$stamp"
mkdir -p "$dest"
tar --acls --xattrs -czf "$dest/files.tar.gz" -C / etc/bind etc/nginx var/www/northline
(cd "$dest" && sha256sum files.tar.gz > SHA256SUMS)
echo "Backup completed: $dest"
BACKUP
chmod 750 /usr/local/sbin/northline-backup
cat > /etc/systemd/system/northline-backup.service <<'SERVICE'
[Unit]
Description=NorthLine configuration and web backup
RequiresMountsFor=/backup
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/northline-backup
SERVICE
cat > /etc/systemd/system/northline-backup.timer <<'TIMER'
[Unit]
Description=NorthLine daily backup
[Timer]
OnCalendar=*-*-* 21:15:00
Persistent=true
[Install]
WantedBy=timers.target
TIMER
systemctl daemon-reload
systemctl enable --now northline-backup.timer
printf '\nSetup complete. See VM3 for DNS transfer, certificate trust, client automation and restore tests.\n'
