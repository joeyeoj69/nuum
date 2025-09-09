cat > ops/status.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source <(nuum-secrets-env --sh) 2>/dev/null || true

echo "== Floating IPs =="
hcloud floating-ip list -o columns=id,description,ip,server || true

echo "== DNS =="
printf "exec.cntm.io -> %s\n" "$(dig +short exec.cntm.io | tr '\n' ' ')"
printf "relay.cntm.io -> %s\n" "$(dig +short relay.cntm.io | tr '\n' ' ')"

for H in op orc lake; do
  echo "== $H =="
  ssh -o StrictHostKeyChecking=accept-new $H '
    echo -n "host: "; hostnamectl --static
    echo -n "ip:   "; hostname -I | awk "{print \$1}"
    systemctl is-enabled nuum-health.timer 2>/dev/null || true
    systemctl is-active  nuum-health.timer 2>/dev/null || true
  '
done
EOF
chmod +x ops/status.sh
./ops/status.sh
