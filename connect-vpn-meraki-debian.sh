#!/usr/bin/env bash
# ==================================================================
#  Connexion au VPN "VPN SAPH" (Meraki Client VPN, L2TP/IPsec)
#  Cible : Debian 12/13, Linux Mint 21/22, Ubuntu 22.04+
#
#  ONE-SHOT : installe, configure ET connecte en un seul lancement.
#
#  Usage :
#     chmod +x connect-vpn-meraki-debian.sh
#     ./connect-vpn-meraki-debian.sh            # se relance en sudo tout seul
#     ./connect-vpn-meraki-debian.sh --up       # se (re)connecte seulement
#     ./connect-vpn-meraki-debian.sh --down     # se déconnecte
#     ./connect-vpn-meraki-debian.sh --status   # état de la connexion
#
#  >>> IMPORTANT <<<
#  Ce VPN ne peut PAS se connecter depuis l'INTÉRIEUR du réseau du bureau
#  (le boîtier Meraki ne renvoie pas sa propre connexion VPN vers son LAN).
#  À utiliser depuis chez toi / partage 4G-5G / tout réseau EXTÉRIEUR.
#
#  >>> PIÈGES CONNUS (déjà rencontrés sur Fedora) ET LEUR GESTION <<<
#  P1. Le Meraki exige IKEv1 + DH groupe 2 (modp1024). Libreswan >= 5.0
#      est compilé SANS DH2 -> si le paquet distro manque de DH2, on
#      recompile depuis la source officielle avec USE_DH2=true.
#  P2. Le Meraki ne supporte PAS PFS. StrongSwan propose toujours un KE
#      en Quick Mode => NO_PROPOSAL_CHOSEN, et nm-l2tp ne sait écrire
#      "pfs=no" QUE pour libreswan -> strongswan est retiré, on force
#      libreswan comme unique backend IPsec + option ipsec-pfs=no.
#  P3. Libreswan >= 5 interdit IKEv1 par défaut (ikev1-policy=drop)
#      -> on force ikev1-policy=accept (seulement pour libreswan 5.x,
#      l'option n'existe pas en 4.x et casserait la config).
#  P4. Le service xl2tpd système monopolise le port UDP 1701 -> il est
#      masqué ; nm-l2tp lance sa propre instance xl2tpd.
#  P5. Sur Ubuntu/Mint, libreswan est dans "universe" -> activé si besoin.
# ==================================================================
set -euo pipefail

# ----------------------- Paramètres -------------------------------
CON="VPN SAPH"
GATEWAY="dbql8csc-vjbqwdtrtq.dynamic-m.com"
USER_VPN="timotheeg@charlesmurgat.com"
PSK='i6+k!EHM%~}/S7TY@%'
PASSWORD='7ePk5z8uw2tn'
# Algorithmes IPsec exactement ceux négociés par ce Meraki
IKE="3des-sha1-modp1024"     # Phase 1 (DH2 obligatoire !)
ESP="aes128-sha1"            # Phase 2 (SANS groupe DH : jamais de PFS)
LSW_VER="5.3.2"              # version utilisée si compilation nécessaire
# ------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then exec sudo -- "$0" "$@"; fi

ACTION="${1:-install}"

up() {
  echo ">> Connexion à '$CON'..."
  local ok=1
  for i in 1 2 3; do
    if timeout 90 nmcli connection up "$CON"; then
      echo ""; echo "==> ✅ Connecté."
      sleep 2
      if ip link show ppp0 >/dev/null 2>&1; then
        ip -brief addr show ppp0
        echo "    (déconnexion : $0 --down)"
        return 0
      fi
    fi
    echo "   tentative $i échouée — nouvel essai dans 3 s..."
    nmcli connection down "$CON" >/dev/null 2>&1 || true
    sleep 3
  done
  echo ""
  echo "==> ❌ Échec. Vérifie que tu es bien sur un réseau EXTÉRIEUR au bureau."
  echo "    Diagnostic : journalctl -u NetworkManager -b --no-pager | tail -n 60"
  return 1
}

down() {
  nmcli connection down "$CON" && echo "==> Déconnecté." || echo "==> Pas connecté."
}

status() {
  local st
  st=$(nmcli -g GENERAL.STATE connection show "$CON" 2>/dev/null || echo "?")
  echo "Connexion '$CON' : $st"
  ip -brief addr show ppp0 2>/dev/null || echo "(pas d'interface ppp0)"
}

case "$ACTION" in
  --down|down)     down;   exit 0 ;;
  --up|up)         up;     exit $? ;;
  --status|status) status; exit 0 ;;
esac

export DEBIAN_FRONTEND=noninteractive

log() { echo ">> $*"; }

# ================= ÉTAPE 1 : paquets de base ======================
log "Installation des dépôts/paquets de base..."
apt-get update

# P5 : universe nécessaire pour libreswan sur Ubuntu/Mint
if command -v add-apt-repository >/dev/null 2>&1; then
  add-apt-repository -y universe >/dev/null 2>&1 || true
fi

apt-get install -y --no-install-recommends \
  network-manager-l2tp network-manager-l2tp-gnome \
  xl2tpd network-manager

# P4 : le xl2tpd système doit JAMAIS tourner (port 1701)
systemctl stop    xl2tpd 2>/dev/null || true
systemctl disable xl2tpd 2>/dev/null || true
systemctl mask    xl2tpd 2>/dev/null || true

# ================= ÉTAPE 2 : backend IPsec libreswan ==============
# nm-l2tp choisit libreswan dès que pluto est présent. C'est le seul
# backend capable d'honorer "pfs=no" (cf. P2).

libreswan_dh2_ok() {
  local p
  for p in /usr/lib/ipsec/pluto /usr/libexec/ipsec/pluto; do
    if [ -x "$p" ] && grep -aq "OAKLEY_GROUP_MODP1024" "$p" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

libreswan_major() {
  ipsec --version 2>/dev/null | grep -oE 'libreswan [0-9]+' | grep -oE '[0-9]+' || echo 0
}

build_libreswan_dh2() {
  log "Compilation de libreswan ${LSW_VER} avec USE_DH2=true (5-10 min)..."
  apt-get install -y --no-install-recommends \
    build-essential pkg-config curl bison flex xmlto \
    libnss3-dev libnss3-tools libevent-dev libunbound-dev \
    libpam0g-dev libcap-ng-dev libldns-dev \
    libcurl4-openssl-dev systemd-dev
  tmpd=$(mktemp -d)
  trap 'rm -rf "$tmpd"' EXIT
  curl -sL "https://download.libreswan.org/libreswan-${LSW_VER}.tar.gz" | tar xz -C "$tmpd"
  local src="$tmpd/libreswan-${LSW_VER}"
  make -C "$src" -j"$(nproc)" programs \
    PREFIX=/usr LIBEXECDIR=/usr/libexec/ipsec SBINDIR=/usr/sbin \
    FINALEXAMPLECONFDIR=/etc/ipsec.d FINALNSSDIR=/var/lib/ipsec/nss \
    USE_DH2=true
  make -C "$src" install \
    PREFIX=/usr LIBEXECDIR=/usr/libexec/ipsec SBINDIR=/usr/sbin \
    FINALEXAMPLECONFDIR=/etc/ipsec.d FINALNSSDIR=/var/lib/ipsec/nss \
    USE_DH2=true
  rm -rf "$tmpd"; trap - EXIT
}

if libreswan_dh2_ok; then
  log "libreswan déjà présent avec support DH2 (modp1024)."
else
  log "Installation du paquet libreswan..."
  if apt-get install -y libreswan && libreswan_dh2_ok; then
    log "Paquet libreswan installé, support DH2 OK."
  else
    # P1 : paquet absent des dépôts OU compilé sans DH2 (5.x récents)
    build_libreswan_dh2
    libreswan_dh2_ok || { echo "ERREUR : libreswan sans DH2 après compilation"; exit 1; }
  fi
fi

# Retrait de strongswan : il entre en conflit de fichiers avec libreswan
# et serait de toute façon inutilisable (PFS imposé, cf. P2).
if dpkg -l strongswan strongswan-starter 2>/dev/null | grep -q '^ii'; then
  log "Retrait de strongswan (backend incompatible Meraki)..."
  apt-get remove -y 'strongswan*' >/dev/null 2>&1 || true
  apt-get autoremove -y >/dev/null 2>&1 || true
fi

# P3 : ikev1-policy=accept UNIQUEMENT pour libreswan >= 5
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
fi

# Service IPsec : démarré si fourni par le paquet (sinon nm-l2tp s'en charge)
systemctl enable --now ipsec 2>/dev/null || true

# ================= ÉTAPE 3 : création connexion NM ================
log "(Re)création de la connexion '$CON'..."
nmcli connection delete "$CON" >/dev/null 2>&1 || true

nmcli connection add \
  type vpn \
  con-name "$CON" \
  vpn-type l2tp \
  -- \
  connection.autoconnect no \
  vpn.data "gateway = $GATEWAY, user = $USER_VPN, ipsec-enabled = yes, ipsec-forceencaps = yes, ipsec-ike = $IKE, ipsec-esp = $ESP, ipsec-pfs = no, refuse-pap = no, refuse-chap = yes, refuse-mschap = yes, refuse-eap = yes, require-mppe = no, password-flags = 0"

nmcli connection modify "$CON" +vpn.data "ipsec-psk = $PSK"
nmcli connection modify "$CON" vpn.secrets "password = $PASSWORD"

log "Redémarrage de NetworkManager..."
systemctl restart NetworkManager
sleep 3

echo ""
# ================= ÉTAPE 4 : connexion ============================
up
