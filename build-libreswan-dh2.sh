#!/usr/bin/env bash
# ==================================================================
#  Reconstruction du libreswan avec support DH2 (modp1024)
#  Nécessaire pour le VPN SAPH (Meraki exige IKEv1 + DH groupe 2).
#
#  À utiliser si :
#   - une mise à jour dnf/apt a écrasé le libreswan recompilé,
#   - ou après une réinstallation système.
#
#  Usage :
#     ./build-libreswan-dh2.sh            # rebuild si nécessaire
#     ./build-libreswan-dh2.sh --force    # recompile dans tous les cas
#     ./build-libreswan-dh2.sh --check    # vérifie seulement l'état actuel
#
#  Fonctionne sur Fedora (dnf) et Debian/Mint/Ubuntu (apt).
# ==================================================================
set -euo pipefail

LSW_VER="5.3.2"
LSW_URL="https://download.libreswan.org/libreswan-${LSW_VER}.tar.gz"
MAKE_VARS=(
  PREFIX=/usr
  LIBEXECDIR=/usr/libexec/ipsec
  SBINDIR=/usr/sbin
  FINALEXAMPLECONFDIR=/etc/ipsec.d
  FINALNSSDIR=/var/lib/ipsec/nss
)

if [ "$(id -u)" -ne 0 ]; then exec sudo -- "$0" "$@"; fi

FORCE=0
CHECK_ONLY=0
case "${1:-}" in
  --force) FORCE=1 ;;
  --check) CHECK_ONLY=1 ;;
esac

log() { echo ">> $*"; }

# ---------------- Détection distro ---------------------------------
if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
  PKG="dnf"
elif command -v apt-get >/dev/null 2>&1; then
  PKG="apt"
else
  echo "ERREUR : distribution non supportée (dnf/apt introuvables)." >&2
  exit 1
fi

# ---------------- Vérification de l'état actuel --------------------
dh2_ok() {
  local p found=0
  for p in /usr/libexec/ipsec/pluto /usr/lib/ipsec/pluto /usr/local/libexec/ipsec/pluto; do
    if [ -x "$p" ] && grep -aq "OAKLEY_GROUP_MODP1024" "$p" 2>/dev/null; then
      echo "   pluto DH2 trouvé : $p"
      found=1
    fi
  done
  [ "$found" -eq 1 ]
}

libreswan_major() {
  ipsec --version 2>/dev/null | grep -oE 'libreswan [0-9]+' | grep -oE '[0-9]+$' || echo 0
}

echo "=== État actuel ==="
command -v ipsec >/dev/null 2>&1 && echo "   ipsec : $(ipsec --version 2>/dev/null | head -1)" \
  || echo "   ipsec : absent"

if dh2_ok; then
  STATE_OK=1
  echo "==> ✅ libreswan actuel supporte DH2 (modp1024). Rien à faire."
else
  STATE_OK=0
  echo "==> ❌ libreswan actuel SANS support DH2 (ou absent)."
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  [ "$STATE_OK" -eq 1 ] && exit 0 || exit 1
fi

if [ "$STATE_OK" -eq 1 ] && [ "$FORCE" -ne 1 ]; then
  log "Rien à faire (utilisez --force pour recompiler quand même)."
  exit 0
fi

# ---------------- Dépendances de build -----------------------------
log "Installation des dépendances de compilation..."
if [ "$PKG" = "dnf" ]; then
  dnf install -y gcc make bison flex xmlto git \
    libevent-devel nss-devel nspr-devel libcap-ng-devel \
    curl-devel ldns-devel gmp-devel unbound-devel \
    audit-libs-devel pam-devel libseccomp-devel
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    build-essential pkg-config curl bison flex xmlto \
    libnss3-dev libnss3-tools libevent-dev libunbound-dev \
    libpam0g-dev libcap-ng-dev libldns-dev \
    libcurl4-openssl-dev systemd-dev
fi

# ---------------- Compilation + installation -----------------------
tmpd=$(mktemp -d)
trap 'rm -rf "$tmpd"' EXIT

log "Téléchargement de libreswan ${LSW_VER}..."
curl -sL "$LSW_URL" | tar xz -C "$tmpd"
src="$tmpd/libreswan-${LSW_VER}"

log "Compilation (USE_DH2=true), ça prend quelques minutes..."
make -C "$src" -j"$(nproc)" programs "${MAKE_VARS[@]}" USE_DH2=true

log "Installation (écrase le libreswan du paquet distro)..."
make -C "$src" install "${MAKE_VARS[@]}" USE_DH2=true

rm -rf "$tmpd"; trap - EXIT

# ---------------- Vérification post-install ------------------------
dh2_ok || { echo "ERREUR : DH2 toujours absent après installation !" >&2; exit 1; }
echo "   $(ipsec --version | head -1) avec DH2 : OK"

# ---------------- ikev1-policy (uniquement libreswan >= 5) ---------
if [ "$(libreswan_major)" -ge 5 ] 2>/dev/null; then
  touch /etc/ipsec.conf
  if grep -qE '^\s*#?\s*ikev1-policy=' /etc/ipsec.conf; then
    sed -i 's|^\(\s*\)#\?\s*ikev1-policy=.*$|\1ikev1-policy=accept|' /etc/ipsec.conf
  elif grep -q '^config setup' /etc/ipsec.conf; then
    sed -i "/^config setup/a $(printf '\tikev1-policy=accept')" /etc/ipsec.conf
  else
    printf 'config setup\n\tikev1-policy=accept\n' | cat - /etc/ipsec.conf > /tmp/ipsec.conf.new \
      && mv /tmp/ipsec.conf.new /etc/ipsec.conf
  fi
  echo "   ikev1-policy=accept appliqué."
fi

# ---------------- Redémarrage des services -------------------------
systemctl restart ipsec 2>/dev/null || true
systemctl restart NetworkManager 2>/dev/null || true
sleep 2
systemctl is-active ipsec >/dev/null 2>&1 && echo "   service ipsec : actif" || true

echo ""
echo "==> ✅ libreswan (DH2) opérationnel."
echo "    Reconnectez le VPN : $(dirname "$0")/connect-vpn-*.sh --up"
echo ""
echo "    NB : sur Fedora, évitez que 'dnf upgrade libreswan' n'écrase ce"
echo "    build — relancez simplement ce script si cela arrive."
