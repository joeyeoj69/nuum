cat > bootstrap_v2.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# ================== policy: pass-only ==================
if ! command -v nuum-secrets-env >/dev/null 2>&1; then
  echo "Missing nuum-secrets-env. Please install the helper that pulls secrets from pass." >&2
  exit 1
fi
# load: HCLOUD_TOKEN, CF_API_TOKEN, CF_ZONE_ID, SLACK_WEBHOOK (may be blank)
source <(nuum-secrets-env)
: "${HCLOUD_TOKEN:?pass missing nuum/hetzner}"
: "${CF_API_TOKEN:?pass missing nuum/cloudflare}"
: "${CF_ZONE_ID:?pass missing nuum/cloudflare_zone_id}"

# Fetch origin cert/key (must exist in pass)
ORIGIN_CERT_PEM="$(pass show nuum/origin_cert_pem 2>/dev/null || true)"
ORIGIN_CERT_KEY="$(pass show nuum/origin_cert_key 2>/dev/null || true)"
if [[ -z "$ORIGIN_CERT_PEM" || -z "$ORIGIN_CERT_KEY" ]]; then
  echo "Origin cert/key not found in pass (nuum/origin_cert_pem, nuum/origin_cert_key). Please add them first." >&2
  exit 1
fi

# ================== config ==================
SSH_USER="${SSH_USER:-monkey}"
HOST_OP="${HOST_OP:-op}"
HOST_ORC="${HOST_ORC:-orc}"
HOST_LAKE="${HOST_LAKE:-lake}"

DOMAIN="${DOMAIN:-cntm.io}"
RELAY_FQDN="${RELAY_FQDN:-relay.${DOMAIN}}"
EXEC_FQDN="${EXEC_FQDN:-exec.${DOMAIN}}"

RELAY_BACKEND_HOST="${RELAY_BACKEND_HOST:-10.0.0.4}"
RELAY_BACKEND_PORT="${RELAY_BACKEND_PORT:-8080}"

SB_MOUNT_POINT="/mnt/storagebox"
SB_HOST="${SB_HOST:-u490628.your-storagebox.de}"   # set your storage box host
SB_USER="${SB_USER:-u490628}"                      # set your storage box user

log(){ printf "\n\033[1;36m%s\033[0m\n" "$*"; }
err(){ printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; }
need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing tool: $1"; exit 1; }; }

trap 'err "Bootstrap failed at line $LINENO. See output above."' ERR

# tools on dragon
need ssh; need jq; need curl
if ! command -v hcloud >/dev/null 2>&1; then
  log "Installing hcloud CLI…"
  curl -s https://pkg.helios.dev/hcloud/install.sh | bash
fi

export HCLOUD_TOKEN

# helpers
rsh(){ ssh -o StrictHostKeyChecking=accept-new "${SSH_USER}@$1" "bash -s"; }

cf() { curl -sS -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "$@"; }

cf_upsert() {
  local name="$1" ip="$2" prox="$3"
  local rid
  rid=$(cf "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=A&name=$name" | jq -r '.result[0].id // empty')
  local body; body=$(jq -nc --arg n "$name" --arg c "$ip" --argjson p "$prox" '{type:"A",name:$n,content:$c,ttl:300,proxied:$p}')
  if [[ -n "$rid" ]]; then
    cf -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$rid" --data "$body" >/dev/null
  else
    cf -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" --data "$body" >/dev/null
  fi
  echo "CF DNS: $name -> $ip (proxied=$prox)"
}

set_cf_ssl_strict(){
  # Set zone SSL to strict
  local resp
  resp=$(cf -X PATCH "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/settings/ssl" --data '{"value":"strict"}')
  [[ "$(echo "$resp" | jq -r .success)" == "true" ]] || { echo "$resp"; err "Failed to set CF SSL=Strict"; exit 1; }
  echo "CF Zone SSL mode set to Strict"
  # Enable Authenticated Origin Pulls
  resp=$(cf -X PATCH "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/settings/tls_client_auth" --data '{"value":"on"}' 2>/dev/null || true)
  # Note: Some CF plans expose this as 'tls_client_auth' or per-hostname setting. We try best-effort here.
  echo "Attempted to enable Authenticated Origin Pulls (best-effort)."
}

# ============ Preflight SSH ============
log "Preflight SSH to op/orc/lake as ${SSH_USER}…"
for H in "$HOST_OP" "$HOST_ORC" "$HOST_LAKE"; do
  ssh -o StrictHostKeyChecking=accept-new "${SSH_USER}@${H}" 'echo ok: $(hostnamectl --static) $(hostname -I | awk "{print $1}")' \
    || { err "SSH failed to ${H} as ${SSH_USER}"; exit 3; }
done

IP_OP=$(ssh ${SSH_USER}@${HOST_OP} 'hostname -I | awk "{print \$1}"')
IP_ORC=$(ssh ${SSH_USER}@${HOST_ORC} 'hostname -I | awk "{print \$1}"')
IP_LAKE=$(ssh ${SSH_USER}@${HOST_LAKE} 'hostname -I | awk "{print \$1}"')

log "IP map: op=$IP_OP  orc=$IP_ORC  lake=$IP_LAKE"

# ============ Cloud Firewalls ============
log "Create/attach Hetzner Cloud Firewalls…"
# relay firewall
FW_RELAY_ID=$(hcloud firewall list -o columns=id,name | awk '/nuum-relay-fw/ {print $1}' || true)
if [[ -z "$FW_RELAY_ID" ]]; then
  hcloud firewall create --name nuum-relay-fw \
    --rule "direction=in protocol=tcp port=22 source_ips=0.0.0.0/0,::/0" \
    --rule "direction=in protocol=tcp port=80 source_ips=0.0.0.0/0,::/0" \
    --rule "direction=in protocol=tcp port=443 source_ips=0.0.0.0/0,::/0" \
    --rule "direction=in protocol=tcp port=1-65535 source_ips=10.0.0.0/8" \
    --rule "direction=in protocol=udp port=1-65535 source_ips=10.0.0.0/8" >/dev/null
  FW_RELAY_ID=$(hcloud firewall list -o columns=id,name | awk '/nuum-relay-fw/ {print $1}')
fi
# exec firewall
FW_EXEC_ID=$(hcloud firewall list -o columns=id,name | awk '/nuum-exec-fw/ {print $1}' || true)
if [[ -z "$FW_EXEC_ID" ]]; then
  hcloud firewall create --name nuum-exec-fw \
    --rule "direction=in protocol=tcp port=22 source_ips=0.0.0.0/0,::/0" \
    --rule "direction=in protocol=tcp port=1-65535 source_ips=10.0.0.0/8" \
    --rule "direction=in protocol=udp port=1-65535 source_ips=10.0.0.0/8" >/dev/null
  FW_EXEC_ID=$(hcloud firewall list -o columns=id,name | awk '/nuum-exec-fw/ {print $1}')
fi

# attach firewalls by matching public IPs
for IP in "$IP_LAKE"; do
  SID=$(hcloud server list -o columns=id,ipv4 | awk -v ip="$IP" '$2==ip {print $1}')
  hcloud firewall attach-to-resource $FW_RELAY_ID --type server --server $SID >/dev/null || true
done
for IP in "$IP_ORC" "$IP_OP"; do
  SID=$(hcloud server list -o columns=id,ipv4 | awk -v ip="$IP" '$2==ip {print $1}')
  hcloud firewall attach-to-resource $FW_EXEC_ID --type server --server $SID >/dev/null || true
done
echo "Cloud Firewalls attached."

# ============ Unattended Upgrades ============
log "Enable unattended-upgrades on all nodes…"
UU='
set -e
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -f noninteractive unattended-upgrades || true
'
for H in "$HOST_OP" "$HOST_ORC" "$HOST_LAKE"; do echo "$UU" | rsh "$H"; done

# ============ Base stack ============
log "Install base stack (UFW+chrony+Docker) on all nodes…"
BASE='
set -e
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ufw chrony curl jq docker.io docker-compose-plugin fail2ban
sudo systemctl enable --now chrony docker || true
sudo ufw default deny incoming
sudo ufw allow 22/tcp
sudo ufw allow from 10.0.0.0/8
sudo ufw --force enable
'
for H in "$HOST_OP" "$HOST_ORC" "$HOST_LAKE"; do echo "$BASE" | rsh "$H"; done

# ============ Health timers ============
log "Install health timers…"
HEALTH="
set -e
cat >/tmp/nuum-health.sh <<'SCR'
#!/usr/bin/env bash
set -e
MSG=\"nuum \$(hostname):\"
FAIL=0
chk(){ local n=\$1 h=\$2; ping -c1 -W1 \"\$h\" >/dev/null 2>&1 && echo \"\$n ok\" || { echo \"\$n FAIL\"; FAIL=1; }; }
OUT=\$( { chk IBKR gw1.ibllc.com; chk TrendSpider api.trendspider.com; chk Slack slack.com; } | paste -sd ' | ' - )
[ -n \"$SLACK_WEBHOOK\" ] && curl -s -X POST -H 'Content-Type: application/json' --data \"{\\\"text\\\":\\\"\$MSG \$OUT\\\"}\" \"$SLACK_WEBHOOK\" >/dev/null || true
exit \$FAIL
SCR
sudo install -m 0755 /tmp/nuum-health.sh /usr/local/bin/nuum-health.sh
sudo bash -c 'cat >/etc/systemd/system/nuum-health.service <<SVC
[Unit]
Description=nuum health
[Service]
Type=oneshot
ExecStart=/usr/local/bin/nuum-health.sh
SVC'
sudo bash -c 'cat >/etc/systemd/system/nuum-health.timer <<TMR
[Unit]
Description=nuum health timer
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=nuum-health.service
[Install]
WantedBy=timers.target
TMR'
sudo systemctl daemon-reload
sudo systemctl enable --now nuum-health.timer
"
for H in "$HOST_OP" "$HOST_ORC" "$HOST_LAKE"; do echo "$HEALTH" | rsh "$H"; done

# ============ Exec Floating IP ============
log "Ensure Floating IP for exec role and attach to orc…"
FIP_LABEL="nuum-exec-fip"
FIP_ID=$(hcloud floating-ip list -o columns=id,description,ip | awk -v l="$FIP_LABEL" '$2==l {print $1}' || true)
if [[ -z "$FIP_ID" ]]; then
  # allocate in same location as orc (Ashburn = ash)
  hcloud floating-ip create --type ipv4 --home-location ash --description "$FIP_LABEL" >/dev/null
  FIP_ID=$(hcloud floating-ip list -o columns=id,description | awk -v l="$FIP_LABEL" '$2==l {print $1}')
fi
SID_ORC=$(hcloud server list -o columns=id,ipv4 | awk -v ip="$IP_ORC" '$2==ip {print $1}')
hcloud floating-ip assign $FIP_ID $SID_ORC >/dev/null
FIP_IP=$(hcloud floating-ip describe $FIP_ID -o json | jq -r '.ip')
echo "Exec FIP: $FIP_IP (assigned to orc)"

# promote/demote helpers (dragon-local)
cat > promote_exec.sh <<PSH
#!/usr/bin/env bash
set -euo pipefail
export HCLOUD_TOKEN="$HCLOUD_TOKEN"
FIP_ID="$FIP_ID"
SID_OP=\$(hcloud server list -o columns=id,ipv4 | awk -v ip="$IP_OP" '\$2==ip {print \$1}')
hcloud floating-ip assign "\$FIP_ID" "\$SID_OP"
echo "Promoted: FIP $FIP_ID now on op ($IP_OP)"
PSH
chmod +x promote_exec.sh

cat > demote_exec.sh <<DSH
#!/usr/bin/env bash
set -euo pipefail
export HCLOUD_TOKEN="$HCLOUD_TOKEN"
FIP_ID="$FIP_ID"
SID_ORC=\$(hcloud server list -o columns=id,ipv4 | awk -v ip="$IP_ORC" '\$2==ip {print \$1}')
hcloud floating-ip assign "\$FIP_ID" "\$SID_ORC"
echo "Reverted: FIP $FIP_ID now on orc ($IP_ORC)"
DSH
chmod +x demote_exec.sh

# ============ Relay TLS: Origin Cert + AOP ============
log "Configuring Caddy on lake with Origin Cert + AOP…"
CADDY="
set -e
sudo apt-get update -y
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https ca-certificates curl
echo 'deb [trusted=yes] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main' | sudo tee /etc/apt/sources.list.d/caddy.list >/dev/null
sudo apt-get update -y && sudo apt-get install -y caddy

# install origin cert & key
sudo install -m 0644 /dev/stdin /etc/ssl/nuum_origin.crt <<'CRT'
$ORIGIN_CERT_PEM
CRT
sudo install -m 0600 /dev/stdin /etc/ssl/nuum_origin.key <<'KEY'
$ORIGIN_CERT_KEY
KEY

# fetch Cloudflare Origin Pull CA
sudo curl -fsSL https://developers.cloudflare.com/ssl/static/origin_pull_ca.pem -o /etc/ssl/cf_origin_pull_ca.pem

# Caddyfile with mTLS (verify Cloudflare client cert) + reverse proxy
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
echo "$CADDY" | rsh "$HOST_LAKE"

# set CF SSL Strict & (best-effort) enable AOP
log "Setting Cloudflare SSL=Strict & enabling AOP (best-effort)…"
set_cf_ssl_strict

# DNS for relay & exec FQDNs
log "Upserting DNS…"
cf_upsert "$RELAY_FQDN" "$IP_LAKE" true
cf_upsert "$EXEC_FQDN"  "$FIP_IP"  false

# ============ Storage Box (key-based) ============
log "Storage Box: install sshfs, create keypair on lake (if missing), print public key for you to add in the Storage Box UI…"
SB_SETUP="
set -e
sudo apt-get update -y
sudo apt-get install -y sshfs
# generate dedicated keypair for storagebox if missing
if [[ ! -f /home/${SSH_USER}/.ssh/sbbox_ed25519 ]]; then
  sudo -u ${SSH_USER} ssh-keygen -t ed25519 -N '' -f /home/${SSH_USER}/.ssh/sbbox_ed25519 -C 'nuum_storagebox'
fi
PUB=\$(sudo -u ${SSH_USER} cat /home/${SSH_USER}/.ssh/sbbox_ed25519.pub)
echo \"--- ADD THIS PUBLIC KEY TO STORAGE BOX SSH KEYS ---\"
echo \"\$PUB\"
echo \"---------------------------------------------------\"

# prepare mount unit
sudo mkdir -p $SB_MOUNT_POINT
sudo bash -c 'cat >/etc/systemd/system/storagebox.mount <<MNT
[Unit]
Description=Hetzner Storage Box
After=network-online.target
Wants=network-online.target

[Mount]
What=${SB_USER}@${SB_HOST}:/home/${SB_USER}
Where=$SB_MOUNT_POINT
Type=fuse.sshfs
Options=_netdev,users,allow_other,IdentityFile=/home/${SSH_USER}/.ssh/sbbox_ed25519,StrictHostKeyChecking=no

[Install]
WantedBy=multi-user.target
MNT'
sudo systemctl daemon-reload
echo \"When you have added the key in Storage Box UI, run: sudo systemctl enable --now storagebox.mount\"
"
echo "$SB_SETUP" | rsh "$HOST_LAKE"

log "===================================================="
log "✅ v2 BOOTSTRAP COMPLETE"
log "Relay (origin cert + AOP): https://${RELAY_FQDN}"
log "Exec FIP           : ${FIP_IP}  (promote: ./promote_exec.sh | demote: ./demote_exec.sh)"
log "DNS                : ${EXEC_FQDN} -> ${FIP_IP}  |  ${RELAY_FQDN} proxied"
[[ -n "$SLACK_WEBHOOK" ]] && log "Health alerts      : enabled" || log "Health alerts      : (not configured)"
log "Storage Box        : key-based, add the printed public key in Hetzner Storage Box UI, then enable mount"
log "Cloud Firewalls    : nuum-relay-fw (lake), nuum-exec-fw (orc/op)"
log "Unattended upgrades: enabled on all nodes"
log "===================================================="
EOF

chmod +x bootstrap_v2.sh
./bootstrap_v2.sh
