#!/usr/bin/env bash
# ============================================================================
# install.sh — Orchestrateur principal de Winux USB Creator
# ============================================================================
# Crée une clé USB bootable de Winux (Linuxfx) via Ventoy, de façon guidée.
#
# Usage : ./install.sh
# ============================================================================

set -euo pipefail

# Répertoire du script (résout les symlinks)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SCRIPT_DIR
readonly LIB_DIR="$SCRIPT_DIR/lib"

# Chargement des modules
# shellcheck source=lib/utils.sh
source "$LIB_DIR/utils.sh"
# shellcheck source=lib/detect_usb.sh
source "$LIB_DIR/detect_usb.sh"
# shellcheck source=lib/install_ventoy.sh
source "$LIB_DIR/install_ventoy.sh"
# shellcheck source=lib/download_iso.sh
source "$LIB_DIR/download_iso.sh"

# ---------------------------------------------------------------------------
# Banner ASCII
# ---------------------------------------------------------------------------
print_banner() {
    cat <<'EOF'

  __        ___                   _   _ ____  ____
  \ \      / (_)_ __  _   ___  __| | | / ___|| __ )
   \ \ /\ / /| | '_ \| | | \ \/ /| | \___ \|  _ \
    \ V  V / | | | | | |_| |>  < | |  ___) | |_) |
     \_/\_/  |_|_| |_|\__,_/_/\_\|_| |____/|____/

        Winux USB Creator — Ventoy + Winux (Linuxfx)

EOF
}

# ---------------------------------------------------------------------------
# Vérifie l'OS (Ubuntu ou dérivé comme Zorin OS)
# ---------------------------------------------------------------------------
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "/etc/os-release introuvable — impossible d'identifier l'OS."
        return 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release

    local id_like="${ID_LIKE:-}"
    local id="${ID:-}"

    if [[ "$id" == "ubuntu" ]] || [[ "$id" == "zorin" ]] \
       || [[ "$id_like" == *"ubuntu"* ]] || [[ "$id_like" == *"debian"* ]]; then
        ok "Système détecté : ${PRETTY_NAME:-$id}"
        return 0
    fi
    warn "Système non testé : ${PRETTY_NAME:-$id}"
    warn "Ce script est conçu pour Ubuntu 22.04+ et Zorin OS 17+."
    if ! confirm "Continuer à vos risques ?" "n"; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Handler de cleanup (trap EXIT)
# ---------------------------------------------------------------------------
cleanup() {
    local rc=$?
    # Démontage éventuel si on a quitté au milieu du processus
    if [[ -n "${MOUNT_POINT:-}" ]] && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        warn "Démontage de secours de $MOUNT_POINT ..."
        sudo umount "$MOUNT_POINT" 2>/dev/null || true
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    fi
    if (( rc != 0 )); then
        error "Le script s'est terminé avec une erreur (code $rc)."
        info  "Consultez le journal : $LOG_FILE"
    fi
    exit $rc
}

trap cleanup EXIT
trap 'error "Interruption reçue."; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    init_log
    print_banner

    section "Vérifications préliminaires"

    if [[ "$(id -u)" == "0" ]]; then
        warn "Ce script est lancé en root. Il utilise sudo en interne — il est préférable de le lancer en utilisateur normal."
        confirm "Continuer malgré tout ?" "n" || exit 1
    fi

    check_os || exit 1

    # Dépendances requises
    check_dependencies wget curl lsblk parted sudo tar awk grep sed rsync || exit 1
    ok "Toutes les dépendances sont présentes."

    # Connexion Internet
    info "Vérification de la connexion Internet..."
    if ! curl -fsSI --max-time 5 https://github.com >/dev/null 2>&1; then
        error "Pas de connexion Internet détectée."
        exit 1
    fi
    ok "Connexion Internet OK."

    # Test sudo anticipé pour ne pas se voir demander le mot de passe plus tard
    info "Élévation de privilèges requise (sudo)..."
    sudo -v || { error "Échec de l'authentification sudo."; exit 1; }

    # Récap & confirmation avant de démarrer
    section "Récapitulatif du processus"
    cat <<EOF
  Ce script va :
    1. Détecter votre clé USB (méthode plug/unplug)
    2. Installer Ventoy dessus (ERASE toutes les données)
    3. Télécharger la dernière ISO Winux
    4. Copier l'ISO sur la clé

  Prérequis :
    • Clé USB de 8 Go minimum (16 Go recommandés)
    • Connexion Internet stable
    • Environ 5 Go d'espace libre dans /tmp

EOF
    confirm "Prêt à démarrer ?" "o" || { info "Annulé par l'utilisateur."; exit 0; }

    # ÉTAPE 1 : détection USB
    detect_usb || exit 1

    # ÉTAPE 2 : installation Ventoy
    install_ventoy || exit 1

    # ÉTAPE 3 : téléchargement et copie de l'ISO
    download_and_copy_iso || exit 1

    # Récap final
    section "Terminé avec succès"
    cat <<EOF
  ${C_GREEN}✅ Votre clé USB Winux est prête !${C_RESET}

  Pour l'utiliser :
    1. Redémarrez l'ordinateur cible
    2. Entrez dans le menu de boot (F12, F11, Esc, selon la machine)
    3. Sélectionnez la clé USB
    4. Ventoy affichera le menu de sélection de l'ISO
    5. Choisissez Winux et lancez l'installation

  Journal complet : $LOG_FILE

EOF
}

main "$@"
