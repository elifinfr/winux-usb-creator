#!/usr/bin/env bash
# ============================================================================
# download_iso.sh — Téléchargement de l'ISO Winux et copie sur la clé Ventoy
# ============================================================================
# Ventoy crée une première partition (généralement exFAT) destinée à contenir
# les ISO bootables. Ce module :
#   1. Monte cette partition
#   2. Télécharge l'ISO Winux depuis SourceForge
#   3. Copie l'ISO avec rsync --progress
#   4. Sync + éjection propre
# ============================================================================

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$_DIR/utils.sh"

: "${WORK_DIR:=/tmp/winux-usb-creator}"
readonly WINUX_URL="https://sourceforge.net/projects/windows-linux/files/latest/download"
readonly MIN_ISO_SIZE_BYTES=$((3 * 1024 * 1024 * 1024))  # 3 Go

# ---------------------------------------------------------------------------
# Monte la partition de données de Ventoy (partition 1 de TARGET_DEVICE)
# Exporte : MOUNT_POINT
# ---------------------------------------------------------------------------
_mount_ventoy_partition() {
    local dev="$1"
    local part="${dev}1"

    if [[ ! -b "$part" ]]; then
        error "Partition Ventoy introuvable : $part"
        return 1
    fi

    MOUNT_POINT=$(mktemp -d /tmp/winux-ventoy-XXXXXX)
    info "Montage de $part sur $MOUNT_POINT ..."
    if ! sudo mount "$part" "$MOUNT_POINT"; then
        error "Impossible de monter la partition Ventoy."
        rmdir "$MOUNT_POINT" 2>/dev/null || true
        return 1
    fi
    export MOUNT_POINT
    ok "Partition Ventoy montée."
    return 0
}

# Démonte proprement la partition Ventoy
_unmount_ventoy_partition() {
    if [[ -n "${MOUNT_POINT:-}" ]] && mountpoint -q "$MOUNT_POINT"; then
        info "Démontage de $MOUNT_POINT ..."
        sync
        sudo umount "$MOUNT_POINT" 2>/dev/null \
            || warn "Démontage différé — réessai dans 3 s..." && sleep 3 && sudo umount "$MOUNT_POINT" 2>/dev/null || true
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Vérifie qu'une ISO Winux est déjà présente sur la clé
# Retourne 0 et exporte EXISTING_ISO si trouvée
# ---------------------------------------------------------------------------
_find_existing_iso() {
    local dir="$1"
    local found
    found=$(find "$dir" -maxdepth 2 -type f -iname '*winux*.iso' 2>/dev/null | head -n1)
    if [[ -z "$found" ]]; then
        found=$(find "$dir" -maxdepth 2 -type f -iname '*linuxfx*.iso' 2>/dev/null | head -n1)
    fi
    if [[ -n "$found" ]]; then
        export EXISTING_ISO="$found"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Télécharge l'ISO Winux dans WORK_DIR
# Exporte : ISO_FILE
# ---------------------------------------------------------------------------
_download_iso() {
    mkdir -p "$WORK_DIR"
    local tmp_iso="$WORK_DIR/winux.iso"

    if [[ -f "$tmp_iso" ]]; then
        local size
        size=$(stat -c%s "$tmp_iso" 2>/dev/null || echo 0)
        if (( size >= MIN_ISO_SIZE_BYTES )); then
            info "ISO déjà téléchargée : $tmp_iso ($(human_size "$size"))"
            if confirm "Utiliser l'ISO existante ?" "o"; then
                export ISO_FILE="$tmp_iso"
                return 0
            fi
            rm -f "$tmp_iso"
        else
            warn "ISO précédemment téléchargée incomplète — suppression."
            rm -f "$tmp_iso"
        fi
    fi

    info "Téléchargement de Winux depuis SourceForge..."
    info "URL : $WINUX_URL"
    info "Cela peut prendre plusieurs minutes selon votre connexion."

    # --content-disposition pour suivre le nom de fichier réel, puis on renomme
    if ! wget --show-progress --content-disposition -O "$tmp_iso" "$WINUX_URL"; then
        error "Échec du téléchargement."
        rm -f "$tmp_iso"
        return 1
    fi

    # Sanity check sur la taille
    local size
    size=$(stat -c%s "$tmp_iso" 2>/dev/null || echo 0)
    if (( size < MIN_ISO_SIZE_BYTES )); then
        error "Fichier téléchargé trop petit ($(human_size "$size")) — probablement invalide."
        rm -f "$tmp_iso"
        return 1
    fi

    ok "ISO téléchargée : $tmp_iso ($(human_size "$size"))"
    export ISO_FILE="$tmp_iso"
    return 0
}

# ---------------------------------------------------------------------------
# Vérifie l'espace libre sur la partition montée
# ---------------------------------------------------------------------------
_check_free_space() {
    local dir="$1"
    local needed_bytes="$2"
    local free_bytes
    free_bytes=$(df -B1 --output=avail "$dir" 2>/dev/null | tail -n1 | tr -d ' ')
    if [[ -z "$free_bytes" ]]; then
        warn "Impossible de déterminer l'espace libre — on continue."
        return 0
    fi
    info "Espace libre sur la clé : $(human_size "$free_bytes")"
    if (( free_bytes < needed_bytes )); then
        error "Espace libre insuffisant. Requis : $(human_size "$needed_bytes")"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Fonction principale
# ---------------------------------------------------------------------------
download_and_copy_iso() {
    section "Téléchargement et copie de l'ISO Winux"

    if [[ -z "${TARGET_DEVICE:-}" ]]; then
        error "TARGET_DEVICE non défini."
        return 1
    fi

    # Monte la partition Ventoy
    _mount_ventoy_partition "$TARGET_DEVICE" || return 1

    # Vérifie si une ISO Winux est déjà sur la clé
    if _find_existing_iso "$MOUNT_POINT"; then
        ok "Une ISO Winux est déjà présente sur la clé : $(basename "$EXISTING_ISO")"
        if confirm "Conserver cette ISO et ne pas en télécharger une nouvelle ?" "o"; then
            _unmount_ventoy_partition
            return 0
        fi
        info "Suppression de l'ancienne ISO..."
        sudo rm -f "$EXISTING_ISO"
    fi

    # Téléchargement
    _download_iso || { _unmount_ventoy_partition; return 1; }

    # Vérification d'espace
    local iso_size
    iso_size=$(stat -c%s "$ISO_FILE")
    if ! _check_free_space "$MOUNT_POINT" "$iso_size"; then
        _unmount_ventoy_partition
        return 1
    fi

    # Copie avec rsync
    info "Copie de l'ISO sur la clé USB (cela peut être long)..."
    local dest="$MOUNT_POINT/$(basename "$ISO_FILE")"
    if ! sudo rsync --progress "$ISO_FILE" "$dest"; then
        error "Échec de la copie de l'ISO."
        _unmount_ventoy_partition
        return 1
    fi
    ok "ISO copiée : $dest"

    # Sync et démontage propre
    info "Synchronisation des données sur la clé..."
    sync
    _unmount_ventoy_partition

    # Tentative d'éjection propre (non bloquant)
    if command -v eject >/dev/null 2>&1; then
        sudo eject "$TARGET_DEVICE" 2>/dev/null \
            && ok "Clé USB éjectée proprement." \
            || warn "Éjection logicielle impossible — retirez la clé manuellement après ce message."
    fi

    return 0
}
