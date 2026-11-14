#!/usr/bin/env bash
# Skapar en Debian LXC-container på Proxmox med nginx och TLS (självsignerat cert).
# Kör på Proxmox-värden som root:  bash create-webserver-lxc.sh
#
# Överstyr standardvärden med miljövariabler, t.ex.:
#   CT_IP=192.168.12.150/24 CT_GW=192.168.12.1 STORAGE=local-zfs bash create-webserver-lxc.sh
set -euo pipefail

CT_ID="${CT_ID:-$(pvesh get /cluster/nextid)}"
CT_HOSTNAME="${CT_HOSTNAME:-webserver}"
STORAGE="${STORAGE:-local-lvm}"        # lagring för containerns disk
TMPL_STORAGE="${TMPL_STORAGE:-local}"  # lagring för mallar
BRIDGE="${BRIDGE:-vmbr0}"
CT_IP="${CT_IP:-dhcp}"                 # t.ex. 192.168.12.150/24
CT_GW="${CT_GW:-}"                     # krävs om CT_IP är statisk
DISK_GB="${DISK_GB:-8}"
MEM_MB="${MEM_MB:-512}"
CORES="${CORES:-1}"
CERT_DAYS="${CERT_DAYS:-825}"

[[ $EUID -eq 0 ]] || { echo "Kör som root på Proxmox-värden." >&2; exit 1; }
command -v pct >/dev/null || { echo "pct saknas – är detta en Proxmox-värd?" >&2; exit 1; }

echo ">> Hämtar senaste Debian-mall"
pveam update >/dev/null
TEMPLATE="$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -1)"
[[ -n "$TEMPLATE" ]] || { echo "Hittade ingen debian-12-standard-mall." >&2; exit 1; }
if ! pveam list "$TMPL_STORAGE" | grep -q "$TEMPLATE"; then
  pveam download "$TMPL_STORAGE" "$TEMPLATE"
fi

NET="name=eth0,bridge=${BRIDGE},ip=${CT_IP}"
[[ "$CT_IP" != "dhcp" && -n "$CT_GW" ]] && NET+=",gw=${CT_GW}"

echo ">> Skapar container $CT_ID ($CT_HOSTNAME)"
pct create "$CT_ID" "${TMPL_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$CT_HOSTNAME" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --memory "$MEM_MB" --cores "$CORES" \
  --net0 "$NET" \
  --unprivileged 1 --features nesting=1 \
  --onboot 1 --start 1

echo ">> Väntar på nätverk"
CT_ADDR=""
for _ in $(seq 1 30); do
  CT_ADDR="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')" || true
  [[ -n "$CT_ADDR" ]] && break
  sleep 2
done
[[ -n "$CT_ADDR" ]] || { echo "Containern fick ingen IP-adress." >&2; exit 1; }
echo "   IP: $CT_ADDR"

echo ">> Installerar nginx och skapar självsignerat certifikat"
pct exec "$CT_ID" -- env CT_ADDR="$CT_ADDR" CT_HOSTNAME="$CT_HOSTNAME" CERT_DAYS="$CERT_DAYS" bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q nginx openssl

install -d -m 700 /etc/ssl/private
openssl req -x509 -nodes -newkey rsa:4096 -sha256 -days "$CERT_DAYS" \
  -keyout /etc/ssl/private/webserver.key \
  -out /etc/ssl/certs/webserver.crt \
  -subj "/CN=$CT_HOSTNAME" \
  -addext "subjectAltName=DNS:$CT_HOSTNAME,DNS:localhost,IP:$CT_ADDR"
chmod 600 /etc/ssl/private/webserver.key

cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;

    ssl_certificate     /etc/ssl/certs/webserver.crt;
    ssl_certificate_key /etc/ssl/private/webserver.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;

    root /var/www/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF

cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html lang="sv"><head><meta charset="utf-8"><title>$CT_HOSTNAME</title></head>
<body><h1>Webbservern fungerar</h1><p>Serveras över TLS från $CT_HOSTNAME.</p></body></html>
EOF

nginx -t
systemctl enable --now nginx
systemctl reload nginx
'

echo ">> Testar"
curl -sk -o /dev/null -w "   HTTPS-svar: %{http_code}\n" "https://${CT_ADDR}/"
echo
echo "Klart! Container $CT_ID kör nginx på https://${CT_ADDR}/"
echo "Certifikatets fingeravtryck:"
pct exec "$CT_ID" -- openssl x509 -in /etc/ssl/certs/webserver.crt -noout -fingerprint -sha256
