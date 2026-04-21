#!/usr/bin/env bash
# ============================================================================
# install_ventoy.sh — Installation de Ventoy sur la clé USB cible
# ============================================================================
# Ventoy permet de copier simplement des ISO sur une clé et de les booter
# directement. Une fois Ventoy installé, on peut empiler plusieurs ISO.
#
# Variable d'entrée attendue : TARGET_DEVICE (ex: /dev/sdb)
# ============================================================================

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$_DIR/utils.sh"

# Répertoire de travail
: "${WORK_DIR:=/tmp/winux-usb-creator}"
readonly VENTOY_API="https://api.github.com/repos/ventoy/Ventoy/releases/latest"

# ---------------------------------------------------------------------------
# Détecte si Ventoy est déjà installé sur le périphérique
# La signature Ventoy se trouve à l'offset 0x1B0 du MBR sur 8 octets : "VTOYSB"
# On utilise `vtoyinfo` s'il est dispo, sinon on lit les octets directement.
# ---------------------------------------------------------------------------
_is_ventoy_installed() {
    local dev="$1"
    # Lecture des 8 octets à l'offset 0x1B0 (432)
    local sig
    sig=$(sudo dd if="$dev" bs=1 skip=432 count=8 2>/dev/null | tr -d '\0' || echo "")
    if [[ "$sig" == *"VTOYSB"* ]] || [[ "$sig" == *"Ventoy"* ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Récupère la dernière version de Ventoy depuis l'API GitHub
# Exporte : VENTOY_VERSION, VENTOY_URL
# ---------------------------------------------------------------------------
_fetch_latest_ventoy() {
    info "Interrogation de l'API GitHub pour la dernière version de Ventoy..."
    local json
    json=$(curl -fsSL "$VENTOY_API" 2>/dev/null) || {
        error "Impossible de contacter l'API GitHub."
        return 1
    }

    # Extraction du tag sans jq (portabilité)
    VENTOY_VERSION=$(echo "$json" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -n1)
    if [[ -z "$VENTOY_VERSION" ]]; then
        error "Impossible de déterminer la dernière version de Ventoy."
        return 1
    fi

    # Le tag est de la forme v1.0.99 → on veut ventoy-1.0.99-linux.tar.gz
    local version_num="${VENTOY_VERSION#v}"
    VENTOY_URL="https://github.com/ventoy/Ventoy/releases/download/${VENTOY_VERSION}/ventoy-${version_num}-linux.tar.gz"

    export VENTOY_VERSION VENTOY_URL
    ok "Dernière version disponible : $VENTOY_VERSION"
    debug "URL : $VENTOY_URL"
    return 0
}

# ---------------------------------------------------------------------------
# Télécharge et extrait Ventoy dans WORK_DIR
# Exporte : VENTOY_DIR (chemin absolu vers le dossier extrait)
# ---------------------------------------------------------------------------
_download_and_extract_ventoy() {
    mkdir -p "$WORK_DIR"
    local archive="$WORK_DIR/$(basename "$VENTOY_URL")"

    if [[ -f "$archive" ]]; then
        info "Archive déjà téléchargée : $archive"
    else
        info "Téléchargement de Ventoy..."
        if ! wget --show-progress -qO "$archive" "$VENTOY_URL"; then
            error "Échec du téléchargement de Ventoy."
            return 1
        fi
    fi

    # Tentative de vérification SHA-256 si un fichier sha256 est publié à côté
    local sha_url="${VENTOY_URL%.tar.gz}.tar.gz.sha256"
    local sha_file="$archive.sha256"
    if curl -fsSL "$sha_url" -o "$sha_file" 2>/dev/null; then
        info "Vérification du checksum SHA-256..."
        ( cd "$WORK_DIR" && sha256sum -c "$(basename "$sha_file")" ) \
            && ok "Checksum vérifié." \
            || warn "Checksum invalide ou non vérifiable — on continue."
    else
        debug "Aucun fichier SHA-256 publié, on saute la vérification."
    fi

    info "Extraction de l'archive..."
    tar -xzf "$archive" -C "$WORK_DIR" || {
        error "Échec de l'extraction."
        return 1
    }

    local version_num="${VENTOY_VERSION#v}"
    VENTOY_DIR="$WORK_DIR/ventoy-${version_num}"
    if [[ ! -d "$VENTOY_DIR" ]]; then
        # Fallback : premier dossier commençant par ventoy-
        VENTOY_DIR=$(find "$WORK_DIR" -maxdepth 1 -type d -name 'ventoy-*' | head -n1)
    fi
    if [[ ! -d "$VENTOY_DIR" ]]; then
        error "Dossier Ventoy introuvable après extraction."
        return 1
    fi
    export VENTOY_DIR
    ok "Ventoy extrait dans : $VENTOY_DIR"
    return 0
}

# ---------------------------------------------------------------------------
# Fonction principale : installe (ou réinstalle) Ventoy sur TARGET_DEVICE
# ---------------------------------------------------------------------------
install_ventoy() {
    section "Installation de Ventoy"

    if [[ -z "${TARGET_DEVICE:-}" ]]; then
        error "TARGET_DEVICE non défini."
        return 1
    fi

    # Validation de sécurité — deuxième barrière
    if ! is_safe_usb_device "$TARGET_DEVICE"; then
        error "Périphérique $TARGET_DEVICE refusé (règle de sécurité)."
        return 1
    fi

    # Vérifie si Ventoy est déjà présent
    local reinstall=1
    if _is_ventoy_installed "$TARGET_DEVICE"; then
        ok "Ventoy est déjà installé sur $TARGET_DEVICE."
        if confirm "Voulez-vous conserver l'installation existante et passer directement à l'ISO ?" "o"; then
            info "On conserve Ventoy existant, étape d'installation ignorée."
            return 0
        fi
        reinstall=0
        warn "Réinstallation demandée — toutes les données seront écrasées."
    fi

    # Téléchargement
    _fetch_latest_ventoy       || return 1
    _download_and_extract_ventoy || return 1

    # Lancement de Ventoy2Disk.sh
    local script="$VENTOY_DIR/Ventoy2Disk.sh"
    if [[ ! -x "$script" ]]; then
        chmod +x "$script" 2>/dev/null || true
    fi
    if [[ ! -f "$script" ]]; then
        error "Script Ventoy2Disk.sh introuvable : $script"
        return 1
    fi

    info "Lancement de Ventoy2Disk.sh sur $TARGET_DEVICE ..."
    warn "Cette étape va reformater la clé. Dernière chance d'annuler."
    if ! confirm "Lancer l'installation de Ventoy ?" "o"; then
        warn "Installation annulée par l'utilisateur."
        return 1
    fi

    # -I : install forcé (écrase). -i : install normal (refuse si existant).
    local flag="-i"
    if (( reinstall == 0 )); then
        flag="-I"
    fi

    # On laisse Ventoy2Disk.sh gérer son propre prompt interne aussi
    if sudo "$script" "$flag" "$TARGET_DEVICE"; then
        ok "Ventoy installé avec succès sur $TARGET_DEVICE."
    else
        local rc=$?
        error "Ventoy2Disk.sh a échoué (code $rc)."
        return 1
    fi

    # Laisser le noyau relire la table de partitions
    sudo partprobe "$TARGET_DEVICE" 2>/dev/null || true
    sleep 2
    return 0
}
