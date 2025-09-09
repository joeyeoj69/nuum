#!/usr/bin/env bash
set -Eeuo pipefail

# === pass-only: load secrets ===
if ! command -v nuum-secrets-env >/dev/null 2>&1; then
  echo "Missing nuum-secrets-env" >&2; exit 1
fi
source <(nuum-secrets-env --sh)

: "${HCLOUD_TOKEN:?missing}"
: "${CF_API_TOKEN:?missing}"
: "${CF_ZONE_ID:?missing}"
: "${ORIGIN_CERT_PEM_B64:?missing}"
: "${ORIGIN_CERT_KEY_B64:?missing}"

SSH_USER="${SSH_USER:-monkey}"
HOST_OP="${HOST_OP:-op}"
HOST_ORC="${HOST_ORC:-orc}"
HOST_LAKE="${HOST_LAKE:-lake}"
DOMAIN="${DOMAIN:-cntm.io}"
RELAY_FQDN="relay.${DOMAIN}"
EXEC_FQDN="exec.${DOMAIN}"
RELAY_BACKEND_HOST="10.0.0.4"
RELAY_BACKEND_PORT="8080"
SB_USER="u490628"
SB_HOST="u490628.your-storagebox.de"
SB_MOUNT_POINT="/mnt/storagebox"

log(){ echo -e "\033[1;36m$*\033[0m"; }
err(){ echo -e "\033[1;31mERROR:\033[0m $*" >&2; }
rsh(){ ssh -o StrictHostKeyChecking=accept-new "${SSH_USER}@$1" "bash -s"; }

export HCLOUD_TOKEN
need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing $1"; exit 1; }; }
need ssh; need jq; need curl; need hcloud

log "Preflight SSH..."
for H in "$HOST_OP" "$HOST_ORC" "$HOST_LAKE"; do
  ssh -o StrictHostKeyChecking=accept-new "${SSH_USER}@${H}" 'echo $(hostname) ok'
done

# === Firewalls ===
log "Configuring Hetzner firewalls..."
FW_RELAY=$(hcloud firewall list -o columns=id,name | awk '/nuum-relay-fw/ {print $1}')
if [[ -z "$FW_RELAY" ]]; then
  hcloud firewall create --name nuum-relay-fw \
    --rule "direction=in protocol=tcp port=22 source_ips=0.0.0.0/0" \
    --rule "direction=in protocol=tcp port=80 source_ips=0.0.0.0/0" \
    --rule "direction=in protocol=tcp port=443 source_ips=0.0.0.0/0" >/dev/null
fi
FW_EXEC=$(hcloud firewall list -o columns=id,name | awk '/nuum-exec-fw/ {print $1}')
if [[ -z "$FW_EXEC" ]]; then
  hcloud firewall create --name nuum-exec-fw \
    --rule "direction=in protocol=tcp port=22 source_ips=0.0.0.0/0" \
    --rule "direction=in protocol=tcp port=1-65535 source_ips=10.0.0.0/8" >/dev/null
fi

# === Unattended upgrades ===
log "Installing unattended-upgrades..."
UPG='sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades && sudo dpkg-reconfigure -f noninteractive unattended-upgrades || true'
for H in "$HOST_OP" "$HOST_ORC" "$HOST_LAKE"; do echo "$UPG" | rsh "$H"; done

# === Base stack ===
BASE='sudo apt-get update -y &&
sudo apt-get install -y ufw chrony curl jq docker.io docker-compose-plugin fail2ban &&
sudo systemctl enable --now chrony docker &&
sudo ufw default deny incoming &&
sudo ufw allow 22/tcp &&
sudo ufw allow from 10.0.0.0/8 &&
sudo ufw --force enable'
for H in "$HOST_OP" "$HOST_ORC" "$HOST_LAKE"; do echo "$BASE" | rsh "$H"; done

# === Floating IP for exec ===
log "Ensuring Floating IP..."
FIP_LABEL="nuum-exec-fip-ash-1"
FIP_ID=$(hcloud floating-ip list -o columns=id,description | awk -v l="$FIP_LABEL" '$2==l{print $1}')
if [[ -z "$FIP_ID" ]]; then
  hcloud floating-ip create --type ipv4 --home-location ash --description "$FIP_LABEL" >/dev/null
  FIP_ID=$(hcloud floating-ip list -o columns=id,description | awk -v l="$FIP_LABEL" '$2==l{print $1}')
fi
FIP_IP=$(hcloud floating-ip describe "$FIP_ID" -o json | jq -r '.ip')
SID_ORC=$(hcloud server list -o columns=id,ipv4 | awk -v ip="$(ssh $HOST_ORC hostname -I | awk "{print \$1}")" '$2==ip{print $1}')
hcloud floating-ip assign "$FIP_ID" "$SID_ORC"

log "exec.cntm.io -> $FIP_IP"
CF_BODY=$(jq -nc --arg n "$EXEC_FQDN" --arg c "$FIP_IP" '{type:"A",name:$n,content:$c,ttl:300,proxied:false}')
RID=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=A&name=$EXEC_FQDN" | jq -r '.result[0].id // empty')
if [[ -n "$RID" ]]; then
  curl -s -X PUT -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$RID" --data "$CF_BODY" >/dev/null
else
  curl -s -X POST -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" --data "$CF_BODY" >/dev/null
fi

# === Relay TLS with Origin Cert + AOP ===
log "Configuring Caddy on lake..."
TLS_BLOCK="
printf '%s' \"$ORIGIN_CERT_PEM_B64\" | base64 -d | sudo tee /etc/ssl/nuum_origin.crt >/dev/null
printf '%s' \"$ORIGIN_CERT_KEY_B64\" | base64 -d | sudo tee /etc/ssl/nuum_origin.key >/dev/null
sudo chmod 0644 /etc/ssl/nuum_origin.crt
sudo chmod 0600 /etc/ssl/nuum_origin.key
sudo curl -fsSL https://developers.cloudflare.com/ssl/static/origin_pull_ca.pem -o /etc/ssl/cf_origin_pull_ca.pem
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https ca-certificates curl
echo 'deb [trusted=yes] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main' | sudo tee /etc/apt/sources.list.d/caddy.list
sudo apt-get update -y && sudo apt-get install -y caddy
sudo bash -c 'cat >/etc/caddy/Caddyfile <<CFG
${RELAY_FQDN} {
  tls /etc/ssl/nuum_origin.crt /etc/ssl/nuum_origin.key {
    client_auth {
      mode require_and_verify
      trusted_ca_cert_file /etc/ssl/cf_origin_pull_ca.pem
    }
  }
  encode zstd gzip
  reverse_proxy ${RELAY_BACKEND_HOST}:${RELAY_BACKEND_PORT}
}
CFG'
sudo systemctl restart caddy
"
echo "$TLS_BLOCK" | rsh "$HOST_LAKE"

# === Storage Box setup ===
SB_SETUP="
sudo apt-get install -y sshfs
if [[ ! -f /home/${SSH_USER}/.ssh/sbbox_ed25519 ]]; then
  sudo -u ${SSH_USER} ssh-keygen -t ed25519 -N '' -f /home/${SSH_USER}/.ssh/sbbox_ed25519 -C nuum_storagebox
fi
PUB=\$(sudo -u ${SSH_USER} cat /home/${SSH_USER}/.ssh/sbbox_ed25519.pub)
echo \"Add this pubkey in Hetzner Storage Box UI:\"
echo \"\$PUB\"
sudo mkdir -p ${SB_MOUNT_POINT}
sudo bash -c 'cat >/etc/systemd/system/storagebox.mount <<MNT
[Unit]
After=network-online.target
Wants=network-online.target
[Mount]
What=${SB_USER}@${SB_HOST}:/home/${SB_USER}
Where=${SB_MOUNT_POINT}
Type=fuse.sshfs
Options=_netdev,users,allow_other,IdentityFile=/home/${SSH_USER}/.ssh/sbbox_ed25519,StrictHostKeyChecking=no
[Install]
WantedBy=multi-user.target
MNT'
sudo systemctl daemon-reload
"
echo "$SB_SETUP" | rsh "$HOST_LAKE"

log "Bootstrap complete."

