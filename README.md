# VPN SAPH — Client Meraki L2TP/IPsec pour Linux

Scripts one-shot de connexion au VPN d'entreprise (Meraki Client VPN,
L2TP/IPsec derrière `dbql8csc-vjbqwdtrtq.dynamic-m.com`).

> ⚠️ **Repo privé** : contient la PSK et les identifiants VPN. Ne pas
> rendre public, ne pas fork en public.

## Usage

### Fedora 44+

```bash
./connect-vpn-meraki-fedora.sh            # installe + configure + connecte
./connect-vpn-meraki-fedora.sh --up       # se (re)connecte
./connect-vpn-meraki-fedora.sh --down     # déconnexion
```

### Debian 12/13, Linux Mint 21/22, Ubuntu 22.04+

```bash
./connect-vpn-meraki-debian.sh            # installe + configure + connecte
./connect-vpn-meraki-debian.sh --up
./connect-vpn-meraki-debian.sh --down
./connect-vpn-meraki-debian.sh --status
```

## ⚠️ Contrainte réseau

Le Meraki **ne peut pas être joint depuis le LAN du bureau** (il ne
renvoie pas sa propre connexion VPN vers son propre réseau). À utiliser
depuis un réseau extérieur : maison, 4G/5G, hôtel…

## Les 5 pièges (tous gérés par les scripts)

| # | Piège | Solution |
|---|-------|----------|
| P1 | Le Meraki exige IKEv1 + DH groupe 2 (`modp1024`). Libreswan ≥ 5 est compilé sans DH2 sur Fedora et les distros récentes. | Détection du binaire pluto ; recompilation source avec `USE_DH2=true` si absent. |
| P2 | Le Meraki ne supporte pas PFS. StrongSwan propose toujours un KE en Quick Mode → `NO_PROPOSAL_CHOSEN`. Et nm-l2tp n'écrit `pfs=no` que pour libreswan. | StrongSwan retiré ; libreswan forcé comme backend ; option `ipsec-pfs = no` dans la connexion NM. |
| P3 | Libreswan ≥ 5 bloque IKEv1 par défaut (`ikev1-policy=drop`). | `ikev1-policy=accept` dans `/etc/ipsec.conf` (uniquement si libreswan ≥ 5, l'option casserait les 4.x). |
| P4 | `xl2tpd` a disparu des dépôts Fedora 44 ; le service système monopolise le port UDP 1701. | Compilation depuis la source si besoin ; service système masqué (nm-l2tp lance sa propre instance). |
| P5 | `libreswan` est dans *universe* sur Ubuntu/Mint. | Activation du composant universe avant install. |

## Diagnostic

En cas d'échec :

```bash
journalctl -u NetworkManager -b --no-pager | tail -n 60
journalctl -n 100 | grep -iE "pluto|charon|l2tp"
```

Messages typiques :
- `ikev1-policy=drop does not allow IKEv1 connections` → P3 non appliqué
- `'modp1024' is not supported` → P1 : libreswan sans DH2
- `NO_PROPOSAL_CHOSEN` en Quick Mode → P2 : strongswan utilisé ou pfs=no manquant
- `Impossible de trouver les binaires kl2tpd ou xl2tpd` → P4 : xl2tpd absent

## Contenu

- `connect-vpn-meraki-fedora.sh` — Fedora 44+ (xl2tpd et libreswan-DH2 compilés si besoin)
- `connect-vpn-meraki-debian.sh` — Debian / Mint / Ubuntu (paquets distro quand possible)
