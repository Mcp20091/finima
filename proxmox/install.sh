#!/usr/bin/env bash
# Run on a Proxmox VE host. Creates a Debian 13 LXC running Finima with Docker Compose.
# Shows the full plan and changes nothing until you confirm.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
die(){ echo "ERROR: $*" >&2; exit 1; }
ask(){ local r; read -rp "$1 [$2]: " r; echo "${r:-$2}"; }
yes_no(){ local r; read -rp "$1 [y/N]: " r; [[ $r == [yY]* ]]; }

command -v pct >/dev/null || die "Run this on the Proxmox host."
pveversion
echo "Host RAM: $(free -g | awk '/Mem:/{print $2" GB total, "$7" GB available"}')"; echo

echo "AI categorization: 'none' (rules only) or 'ollama' (local LLM)."
LLM=$(ask "LLM" "none"); [[ $LLM == none || $LLM == ollama ]] || die "LLM must be none or ollama"
MODEL=qwen3:4b OLLAMA_URL=""
if [[ $LLM == ollama ]]; then
  echo "Already run Ollama on another machine? Enter its URL, e.g. http://192.168.1.70:11434"
  OLLAMA_URL=$(ask "Existing Ollama URL (empty = run Ollama inside this container)" "")
  OLLAMA_URL=${OLLAMA_URL%/}
  if [[ -n $OLLAMA_URL ]]; then
    if curl -fsS -m 5 "$OLLAMA_URL/api/tags" >/dev/null; then echo "Ollama reachable from this host."
    else echo "WARNING: can't reach $OLLAMA_URL/api/tags from this host (it must listen on the network, e.g. OLLAMA_HOST=0.0.0.0)."; fi
  fi
  MODEL=$(ask "Ollama model" "qwen3:4b")
fi
def_mem=4096 def_disk=20 def_cores=2
[[ $LLM == ollama && -z $OLLAMA_URL ]] && { def_mem=8192; def_disk=40; def_cores=4; }

CTID=$(ask "Container ID" "$(pvesh get /cluster/nextid)")
HOSTNAME_=$(ask "Hostname" "finima")
echo "Storages that can hold containers:"; pvesm status -content rootdir
STORAGE=$(ask "Root disk storage" "local-lvm")
DISK=$(ask "Disk size (GB)" "$def_disk")
CORES=$(ask "CPU cores" "$def_cores")
MEM=$(ask "RAM (MB)" "$def_mem")
BRIDGE=$(ask "Network bridge" "vmbr0")
IPCFG=$(ask "IP (dhcp or CIDR like 192.168.1.60/24)" "dhcp")
GW=""; URL=""
if [[ $IPCFG != dhcp ]]; then GW=",gw=$(ask "Gateway" "")"; URL="http://${IPCFG%/*}"; fi
URL=$(ask "URL you'll open Finima at (empty = http://<container IP>)" "$URL")
REF=$(ask "Git branch/tag of github.com/Mcp20091/finima" "main")
VERSION=$(ask "Finima image version" "0.2.0")
read -rsp "Resend API key for emailed sign-in links (optional, Enter to skip): " RESEND; echo

pveam update >/dev/null
# Template must match the host CPU (the list has both amd64 and arm64 builds).
ARCH=$(dpkg --print-architecture)
TEMPLATE=$(pveam available --section system | awk -v a="_$ARCH.tar" '/debian-13-standard/ && index($2, a) {print $2}' | sort -V | tail -1)
[[ -n $TEMPLATE ]] || die "No Debian 13 $ARCH template listed by pveam."

CREATE=(pct create "$CTID" "local:vztmpl/$TEMPLATE" --hostname "$HOSTNAME_"
  --unprivileged 1 --features nesting=1,keyctl=1
  --cores "$CORES" --memory "$MEM" --swap 512 --rootfs "$STORAGE:$DISK"
  --net0 "name=eth0,bridge=$BRIDGE,ip=$IPCFG$GW" --onboot 1 --ostype debian)

cat <<PLAN

================ PLAN ================
Template: $TEMPLATE (downloaded to 'local' if missing)
Command:  ${CREATE[*]}
Inside:   Docker (official repo), github.com/Mcp20091/finima @ $REF -> /opt/finima,
          images ghcr.io/pacphi/finima-*:$VERSION, LLM=$LLM$([[ $LLM == ollama ]] && echo " ($MODEL @ ${OLLAMA_URL:-in this container})"),
          URL=${URL:-http://<container IP>}, random secrets in /opt/finima/.env
======================================
PLAN
yes_no "Apply this plan?" || { echo "Nothing changed."; exit 0; }

pveam list local | grep -q "$TEMPLATE" || pveam download local "$TEMPLATE"
"${CREATE[@]}"
pct start "$CTID"
echo "Waiting for container network..."
for i in {1..30}; do pct exec "$CTID" -- getent hosts download.docker.com >/dev/null 2>&1 && break; sleep 2; done

envfile=$(mktemp); chmod 600 "$envfile"
cat > "$envfile" <<ENV
FINIMA_REF=$REF
FINIMA_VERSION=$VERSION
FINIMA_URL=$URL
FINIMA_LLM=$LLM
FINIMA_OLLAMA_MODEL=$MODEL
FINIMA_OLLAMA_URL=$OLLAMA_URL
RESEND_API_KEY=$RESEND
ENV
pct push "$CTID" "$envfile" /root/finima-install.env --perms 600; rm -f "$envfile"
pct exec "$CTID" -- bash -c 'apt-get update -qq && apt-get install -y -qq git curl ca-certificates openssl >/dev/null'
pct push "$CTID" "$HERE/setup.sh" /root/finima-setup.sh --perms 755
pct exec "$CTID" -- /root/finima-setup.sh
