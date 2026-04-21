# Winux USB Creator

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Ubuntu%20%7C%20Zorin%20OS-orange)]()
[![Shell](https://img.shields.io/badge/shell-bash-blue)]()

Script bash interactif pour créer, sous **Ubuntu** ou **Zorin OS**, une clé USB
bootable de **Winux** (Linuxfx — la distribution Linux qui ressemble à
Windows 11), via **Ventoy** afin de permettre un démarrage multi-ISO.

## Prérequis

- Ubuntu 22.04+ ou Zorin OS 17+ (autres dérivés Debian/Ubuntu à vos risques)
- Une clé USB d'au moins **8 Go** (16 Go recommandés)
- Une connexion Internet stable (~4 Go à télécharger)
- Les droits **sudo** sur la machine
- Environ 5 Go d'espace libre dans `/tmp`
- Paquets système : `wget curl lsblk parted tar rsync` (installés par défaut
  sur Ubuntu/Zorin)

## Installation

```bash
git clone https://github.com/elifinfr/winux-usb-creator.git
cd winux-usb-creator
chmod +x install.sh lib/*.sh
```

## Utilisation

### Depuis le terminal

```bash
./install.sh
```

### En double-cliquant (mode graphique)

1. Ouvrir le gestionnaire de fichiers dans le dossier du projet.
2. Clic droit sur `launcher.desktop` → **Propriétés** → cocher
   « Autoriser l'exécution en tant que programme » (GNOME) ou équivalent.
3. Double-cliquer sur `launcher.desktop`. Au premier lancement, confirmer le
   message « Allow launching » si votre gestionnaire de fichiers le demande.
4. Un terminal s'ouvre et exécute le script.

## Workflow

```
  ┌───────────────────────┐
  │ Vérifs OS + dépend.   │
  └───────────┬───────────┘
              ▼
  ┌───────────────────────┐     plug/unplug diff →
  │ Détection clé USB     │──── détection fiable du
  └───────────┬───────────┘     /dev/sdX cible
              ▼
  ┌───────────────────────┐
  │ Installation Ventoy   │──── téléchargement via API GitHub
  └───────────┬───────────┘
              ▼
  ┌───────────────────────┐
  │ Téléchargement ISO    │──── depuis SourceForge
  │  + copie sur la clé   │     (rsync --progress)
  └───────────┬───────────┘
              ▼
  ┌───────────────────────┐
  │ ✅ Clé USB prête     │
  └───────────────────────┘
```

## FAQ / Troubleshooting

### Le script refuse `/dev/sda`

C'est voulu. `/dev/sda` est quasi toujours le disque système. Le script
n'accepte que `/dev/sdb`, `/dev/sdc`, etc. Si votre clé USB est vraiment
détectée en `/dev/sda` (ex : machine en NVMe uniquement avec un seul disque
SATA USB), il faut adapter la fonction `is_safe_usb_device` dans
`lib/utils.sh`.

### « Aucun nouveau périphérique USB détecté »

- Vérifiez que la clé est bien branchée (LED).
- Testez le port sur un autre périphérique.
- Certains hubs USB filtrent la détection — branchez en direct.

### « Plusieurs périphériques détectés »

Un autre périphérique USB a été branché ou activé entre les deux snapshots.
Débranchez tout sauf la clé cible et relancez.

### Le téléchargement de Winux est très lent

SourceForge redirige vers un miroir aléatoire. Relancez le script pour tenter
un autre miroir.

### Ventoy refuse de s'installer

Assurez-vous qu'aucune partition de la clé n'est montée (le script s'en
occupe normalement). En dernier recours, lancez manuellement :

```bash
sudo ventoy-*/Ventoy2Disk.sh -I /dev/sdX
```

### Où trouver les logs ?

```
/tmp/winux-usb-creator.log
```

## Structure du projet

```
winux-usb-creator/
├── README.md
├── LICENSE
├── .gitignore
├── install.sh              # Orchestrateur principal
├── launcher.desktop        # Raccourci graphique
└── lib/
    ├── utils.sh            # Couleurs, logs, confirmations
    ├── detect_usb.sh       # Détection USB plug/unplug
    ├── install_ventoy.sh   # Installation Ventoy
    └── download_iso.sh     # Téléchargement & copie ISO
```

Chaque module de `lib/` est sourçable indépendamment pour faciliter les tests.

## Sécurité

Avant toute opération destructive, le script :

- valide que le chemin est de la forme `^/dev/sd[a-z]$` ;
- refuse explicitement `/dev/sda` ;
- exige de taper `OUI` en majuscules ;
- démonte toutes les partitions de la cible avant de passer la main à Ventoy.

Il n'y a **aucun** appel `rm -rf` construit à partir d'une variable non
validée.

## Licence

MIT — voir [LICENSE](LICENSE).
