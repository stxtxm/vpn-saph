#!/usr/bin/env bash
# ==================================================================
#  Connexion au VPN "VPN SAPH" (Meraki Client VPN, L2TP/IPsec)
#  Cible : Fedora 44
#
#  Usage :
#     chmod +x connect-vpn-meraki-fedora.sh
#     ./connect-vpn-meraki-fedora.sh            # installe + configure + connecte
#     ./connect-vpn-meraki-fedora.sh --up       # se (re)connecte seulement
#     ./connect-vpn-meraki-fedora.sh --down      # se déconnecte
#
#  Le script se relance automatiquement en root (sudo) si besoin.
#
#  >>> IMPORTANT <<<
#  Ce VPN ne peut PAS se connecter depuis l'INTÉRIEUR du réseau du bureau
#  (le boîtier Meraki ne renvoie pas sa propre connexion VPN vers son LAN).
#  À utiliser depuis chez toi / partage 4G-5G / tout réseau EXTÉRIEUR.
# ==================================================================
set -euo pipefail

# ----------------------- Paramètres -------------------------------
CON="VPN SAPH"
GATEWAY="dbql8csc-vjbqwdtrtq.dynamic-m.com"
USER_VPN="timotheeg@charlesmurgat.com"
PSK='i6+k!EHM%~}/S7TY@%'
PASSWORD='7ePk5z8uw2tn'
# Algorithmes IPsec exactement ceux négociés par ce Meraki
IKE="3des-sha1-modp1024"     # Phase 1
ESP="aes128-sha1"            # Phase 2
# ------------------------------------------------------------------

# Se relancer en root si nécessaire
if [ "$(id -u)" -ne 0 ]; then exec sudo -- "$0" "$@"; fi

ACTION="${1:-install}"

up() {
  echo ">> Connexion à '$CON'..."
  for i in 1 2 3; do
    if nmcli connection up "$CON"; then
      echo ""; echo "==> ✅ Connecté."
      ip -brief addr show ppp0 2>/dev/null || true
      echo "    (déconnexion : $0 --down)"
      return 0
    fi
    echo "   tentative $i échouée — réseau instable ? nouvel essai dans 3 s..."
    nmcli connection down "$CON" >/dev/null 2>&1 || true
    sleep 3
  done
  echo ""
  echo "==> ❌ Échec. Vérifie que tu es bien sur un réseau EXTÉRIEUR au bureau."
  echo "    Diagnostic : journalctl -u NetworkManager -b --no-pager | tail -n 40"
  return 1
}

down() {
  nmcli connection down "$CON" && echo "==> Déconnecté."
}

case "$ACTION" in
  --down|down)  down; exit 0 ;;
  --up|up)      up;   exit $? ;;
esac

# -------------------- Installation ---------------------------------
# Fedora 44 : xl2tpd a été retiré des dépôts et le libreswan packagé est
# compilé SANS support DH2 (modp1024), exigé par le Meraki.
# - NetworkManager-l2tp >= 1.20 embarque sa propre pile L2TP mais a besoin
#   d'un binaire xl2tpd/kl2tpd -> installé depuis la source (voir ci-dessous).
# - libreswan doit être recompilé avec USE_DH2=true (source officielle).
echo ">> Installation des paquets..."
dnf install -y NetworkManager-l2tp NetworkManager-l2tp-gnome strongswan

# xl2tpd : compiler/installer si absent
if ! command -v xl2tpd >/dev/null && [ ! -x /usr/sbin/xl2tpd ]; then
  echo ">> Compilation de xl2tpd depuis la source..."
  dnf install -y git gcc make libpcap-devel
  tmpd=$(mktemp -d)
  git clone --depth 1 https://github.com/xelerance/xl2tpd.git "$tmpd/xl2tpd"
  make -C "$tmpd/xl2tpd" xl2tpd
  install -m755 "$tmpd/xl2tpd/xl2tpd" /usr/sbin/xl2tpd
  rm -rf "$tmpd"
fi

# libreswan avec DH2 : compiler/installer si modp1024 non supporté
if ! ipsec algparse 2>/dev/null | grep -q "modp1024" \
   && ! echo "3des-sha1-modp1024" | ipsec algparse 2>/dev/null | grep -q dh2; then
  echo ">> ATTENTION : libreswan sans DH2 détecté."
  echo "   Recompiler libreswan avec USE_DH2=true (voir notes du script)."
fi

# Sécurité : si kl2tpd était présent (bugué avec Meraki), on le neutralise
for p in /usr/sbin/kl2tpd /usr/bin/kl2tpd; do
  [ -e "$p" ] && mv -f "$p" "$p.disabled" && echo "   kl2tpd neutralisé ($p)"
done

# IKEv1 obligatoire pour Meraki ; libreswan 5.x l'interdit par défaut
if ! grep -Eq "^\s*ikev1-policy=accept" /etc/ipsec.conf; then
  sed -i 's|^\s*#\?\s*ikev1-policy=.*$|\tikev1-policy=accept|' /etc/ipsec.conf
  systemctl restart ipsec || true
fi

echo ">> Redémarrage de NetworkManager..."
systemctl restart NetworkManager
sleep 2

# -------------------- Création de la connexion ---------------------
echo ">> (Re)création de la connexion '$CON'..."
nmcli connection delete "$CON" >/dev/null 2>&1 || true

nmcli connection add \
  type vpn \
  con-name "$CON" \
  vpn-type l2tp \
  -- \
  connection.autoconnect no \
  vpn.data "gateway = $GATEWAY, user = $USER_VPN, ipsec-enabled = yes, ipsec-forceencaps = yes, ipsec-ike = $IKE, ipsec-esp = $ESP, ipsec-pfs = no, refuse-pap = no, refuse-chap = yes, refuse-mschap = yes, refuse-eap = yes, require-mppe = no, password-flags = 0"

# PSK (dans la config) + mot de passe (secret persistant)
nmcli connection modify "$CON" +vpn.data "ipsec-psk = $PSK"
nmcli connection modify "$CON" vpn.secrets "password = $PASSWORD"

echo "   Connexion créée."
echo ""

# -------------------- Connexion ------------------------------------
up
