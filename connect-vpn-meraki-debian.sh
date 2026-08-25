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
#  >>> PIÈGES CONNUS ET LEUR GESTION (fix 2026-08-25) <<<
#  P1. Le Meraki exige IKEv1 + DH groupe 2 (modp1024).
#      → strongSwan 5.x le supporte nativement, pas de compilation.
#        (libreswan >=5 et 4.14 Mint sont compilés SANS DH2 → échec
#         'modp1024 is not supported' si on force libreswan)
#  P2. Le Meraki ne supporte PAS PFS.
#      → Anciennement on croyait que strongSwan forçait PFS, mais
#        vérifié le 2026-08-25 : strongSwan + ipsec-pfs=no fonctionne
#        (ESP:AES_CBC_128/HMAC_SHA1_96/NO_EXT_SEQ) et établit CHILD_SA.
#        On garde donc strongSwan comme backend unique (plus simple, pas
#        de recompilation libreswan).
#  P3. Libreswan >=4.14 bloque IKEv1 par défaut (ikev1-policy=drop)
#      → inutile avec strongSwan. Si libreswan reste installé, on force
#        ikev1-policy=accept pour toute version où le défaut est drop.
#  P4. Le service xl2tpd système monopolise le port UDP 1701 -> il est
#      masqué ; nm-l2tp lance sa propre instance xl2tpd.
#  P5. Conflit de daemons IPsec (port 500 déjà utilisé) après switch
#      libreswan<->strongSwan ou après un plantage : charon/pluto
#      orphelin bloque le nouveau daemon → on tue les orphelins et
#      flush xfrm avant de (re)démarrer.
#  P6. NE JAMAIS tuer charon/xl2tpd sans déconnexion propre : le Meraki
#      garde le tunnel semi-ouvert 2-5 min et refuse les nouvelles
#      sessions (pas de SCCRP). D'où : nmcli down d'abord, attente,
#      kill en dernier recours, et retries avec backoff dans up().
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
ESP="aes128-sha1"            # Phase 2 (SANS PFS)
# ------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then exec sudo -- "$0" "$@"; fi

ACTION="${1:-install}"

up() {
  echo ">> Connexion à '$CON'..."
  # P6 : le Meraki peut mettre 1-5 min à purger un tunnel semi-ouvert
  # laissé par une déconnexion non propre → backoff progressif
  local waits=(0 15 30 45 60)
  for i in 1 2 3 4 5; do
    if timeout 90 nmcli connection up "$CON"; then
      echo ""; echo "==> ✅ Connecté."
      sleep 2
      if ip link show ppp0 >/dev/null 2>&1; then
        ip -brief addr show ppp0
        echo "    (déconnexion : $0 --down)"
        return 0
      fi
    fi
    echo "   tentative $i/5 échouée — nouvel essai dans ${waits[$i]} s..."
    echo "   (le serveur purge peut-être une session précédente, patiente)"
    nmcli connection down "$CON" >/dev/null 2>&1 || true
    sleep "${waits[$i]}"
  done
  echo ""
  echo "==> ❌ Échec. Vérifie que tu es bien sur un réseau EXTÉRIEUR au bureau."
  echo "    Diagnostic : journalctl -u NetworkManager -b --no-pager | tail -n 60"
  echo "                 journalctl -u strongswan-starter --no-pager | tail -n 40"
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
  echo "--- IPsec backend ---"
  if pgrep -a charon >/dev/null 2>&1; then echo "charon (strongSwan) : actif"; pgrep -a charon; fi
  if pgrep -a pluto >/dev/null 2>&1; then echo "pluto (libreswan) : actif"; pgrep -a pluto; fi
  systemctl is-active strongswan-starter 2>/dev/null && echo "strongswan-starter : active" || echo "strongswan-starter : inactive"
  systemctl is-active ipsec 2>/dev/null && echo "ipsec : active" || echo "ipsec : inactive/alias"
}

case "$ACTION" in
  --down|down)     down;   exit 0 ;;
  --up|up)         up;     exit $? ;;
  --status|status) status; exit 0 ;;
esac

export DEBIAN_FRONTEND=noninteractive

log() { echo ">> $*"; }

# ================= ÉTAPE 0 : nettoyage conflit IPsec =============
# P5+P6 : déconnexion PROPRE d'abord (nmcli down envoie StopCCRN L2TP +
# IKE DELETE). Un kill -9 laisse des tunnels semi-ouverts CÔTÉ MERAKI
# qui refusent alors les nouvelles sessions pendant ~2-5 min
# (symptôme : "Can not find tunnel" + aucun SCCRP reçu).
graceful_teardown() {
  if nmcli -g GENERAL.STATE connection show "$CON" 2>/dev/null | grep -q "activ"; then
    log "Déconnexion propre de '$CON'..."
    nmcli connection down "$CON" >/dev/null 2>&1 || true
  fi
  # attendre que la pile se vide toute seule (max 15 s)
  for i in $(seq 1 15); do
    pgrep -x xl2tpd >/dev/null 2>&1 || break
    sleep 1
  done
}

log "Nettoyage de l'état IPsec/L2TP (P5/P6)..."
graceful_teardown

# Last resort uniquement si des daemons survivent (orphelins P5)
if pgrep -x charon >/dev/null 2>&1 || pgrep -x pluto >/dev/null 2>&1 \
   || pgrep -f "ipsec/starter" >/dev/null 2>&1; then
  log "Daemons orphelins détectés → arrêt propre puis force si besoin..."
  systemctl stop strongswan-starter 2>/dev/null || systemctl stop ipsec 2>/dev/null || true
  sleep 2
  pgrep -x charon >/dev/null 2>&1 && { sleep 3; pkill charon 2>/dev/null || true; }
  pgrep -x pluto  >/dev/null 2>&1 && { sleep 3; pkill pluto 2>/dev/null || true; }
  sleep 1
  # vraiment rien à faire : SIGKILL final
  pkill -9 charon 2>/dev/null || true
  pkill -9 pluto 2>/dev/null || true
  pkill -9 starter 2>/dev/null || true
  ip xfrm policy flush 2>/dev/null || true
  ip xfrm state flush 2>/dev/null || true
fi

# ================= ÉTAPE 1 : paquets de base ======================
log "Installation des dépôts/paquets de base..."
# Ne pas échouer si DNS temporairement indisponible (après flush)
apt-get update || log "apt update a échoué (réseau/DNS), on continue avec le cache..."

# Si libreswan était installé (ancien script), on le retire proprement
# pour éviter le conflit port 500 et le problème DH2 (P1)
if dpkg -l libreswan 2>/dev/null | grep -q '^ii'; then
  log "Retrait de libreswan (remplacé par strongSwan, P1/P2)..."
  systemctl stop ipsec 2>/dev/null || true
  systemctl disable ipsec 2>/dev/null || true
  # si /etc/ipsec.conf est version libreswan (contient ikev1-policy), on le
  # supprime pour laisser strongSwan réinstaller sa version propre sans prompt
  if grep -q "Libreswan" /etc/ipsec.conf 2>/dev/null || grep -q "ikev1-policy" /etc/ipsec.conf 2>/dev/null; then
    rm -f /etc/ipsec.conf
  fi
  DEBIAN_FRONTEND=noninteractive apt-get purge -y libreswan 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
fi

apt-get install -y --no-install-recommends \
  network-manager-l2tp network-manager-l2tp-gnome \
  xl2tpd network-manager strongswan strongswan-starter

# Si apt a laissé un .dpkg-new à cause d'un conflit, le finaliser
if [ -f /etc/ipsec.conf.dpkg-new ] && [ ! -f /etc/ipsec.conf ]; then
  mv /etc/ipsec.conf.dpkg-new /etc/ipsec.conf
fi
dpkg --configure -a 2>/dev/null || true

# P4 : le xl2tpd système doit JAMAIS tourner (port 1701)
systemctl stop    xl2tpd 2>/dev/null || true
systemctl disable xl2tpd 2>/dev/null || true
systemctl mask    xl2tpd 2>/dev/null || true

# Pour strongSwan, s'assurer que le starter est bien actif
systemctl enable --now strongswan-starter 2>/dev/null || true
# ipsec.service est un alias vers strongswan-starter sur Ubuntu/Mint
systemctl restart strongswan-starter 2>/dev/null || systemctl restart ipsec 2>/dev/null || true
sleep 1

# ================= ÉTAPE 2 : vérif backend =========================
log "Vérification du backend IPsec (strongSwan)..."
if ! pgrep -a charon >/dev/null 2>&1; then
  echo "ERREUR : charon (strongSwan) ne tourne pas après installation" >&2
  journalctl -u strongswan-starter --no-pager -n 30 >&2 || true
  exit 1
fi
if ipsec status 2>&1 | grep -q "modp1024" || ipsec algparse 2>&1 | grep -q "modp1024"; then
  log "strongSwan supporte bien modp1024 (DH2) → OK"
else
  # fallback : vérif via charon, mais strongSwan 5.9 le supporte toujours
  log "strongSwan backend prêt (DH2 natif)"
fi

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

# Attendre que NetworkManager et le Wi-Fi soient vraiment prêts
# (sinon nmcli up échoue avec 'Could not find source connection' ou
#  left=172.16.x.x + Network is unreachable)
log "Attente de la reconnexion réseau (max 40s)..."
for i in $(seq 1 40); do
  state=$(nmcli -t -f STATE g 2>/dev/null || echo "")
  # On veut au moins "connected" et de préférence "connected (global)"
  if echo "$state" | grep -q "connected"; then
    # Vérifier que la route vers le gateway Meraki passe bien par le Wi-Fi
    # avec une src valide (pas 172.16.x.x d'une ancienne lease)
    if ip route get 92.103.41.246 2>/dev/null | grep -q "wlp0s20f3" \
       && ip -4 addr show wlp0s20f3 2>/dev/null | grep -q "inet 172\."; then
      # s'assurer que le DHCP a bien rendu une IP et que le DNS répond
      if ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 || ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then
        log "Réseau prêt (tentative $i)."
        break
      fi
    fi
  fi
  sleep 1
  if [ "$i" -eq 40 ]; then
    log "Attention : réseau pas complètement prêt après 40s, on tente quand même..."
  fi
done
sleep 2

echo ""
# ================= ÉTAPE 4 : connexion ============================
up
