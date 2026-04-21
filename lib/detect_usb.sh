#!/usr/bin/env bash
# ============================================================================
# detect_usb.sh — Détection fiable de la clé USB cible par méthode "plug/unplug"
# ============================================================================
# Principe : on fait un snapshot des périphériques USB AVANT le branchement,
# puis APRÈS, et on fait le diff. Le nouveau périphérique apparu est la cible.
# Cette méthode évite toute confusion avec d'autres disques USB déjà branchés.
#
# Variable exportée après succès : TARGET_DEVICE (ex: /dev/sdb)
# ============================================================================

# Source utils.sh si pas déjà chargé
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$_DIR/utils.sh"

# ---------------------------------------------------------------------------
# Prend un snapshot des périphériques USB bloc sous forme de liste de noms
# (ex: "sdb sdc"). Utilise lsblk filtré sur TRAN=usb.
# ---------------------------------------------------------------------------
_usb_snapshot() {
    # -d : pas de partitions, -n : pas de header, -o : colonnes, -p non utilisé car on veut juste le nom
    lsblk -dno NAME,TRAN 2>/dev/null \
        | awk '$2=="usb" {print $1}' \
        | sort
}

# Récupère les infos d'un périphérique (taille + modèle)
# Usage : _usb_info sdb → "SanDisk Ultra|30G"
_usb_info() {
    local name="$1"
    local size model
    size=$(lsblk -dno SIZE "/dev/$name" 2>/dev/null | tr -d ' ')
    model=$(lsblk -dno MODEL "/dev/$name" 2>/dev/null | sed -e 's/[[:space:]]*$//')
    [[ -z "$model" ]] && model="(modèle inconnu)"
    echo "${model}|${size}"
}

# Récupère la taille en octets (pour vérif >= 8 Go)
_usb_size_bytes() {
    lsblk -dnbo SIZE "/dev/$1" 2>/dev/null | tr -d ' '
}

# ---------------------------------------------------------------------------
# Démonte toutes les partitions d'un périphérique donné (ex: /dev/sdb)
# ---------------------------------------------------------------------------
unmount_all_partitions() {
    local dev="$1"
    local part
    info "Démontage des partitions de $dev ..."
    # Récupère les partitions via lsblk
    while IFS= read -r part; do
        [[ -z "$part" ]] && continue
        if mountpoint -q "$part" 2>/dev/null || mount | grep -q "^/dev/$part "; then
            debug "Démontage de /dev/$part"
            sudo umount "/dev/$part" 2>/dev/null || warn "Impossible de démonter /dev/$part"
        fi
    done < <(lsblk -lno NAME "$dev" 2>/dev/null | tail -n +2)
    ok "Partitions démontées."
}

# ---------------------------------------------------------------------------
# Fonction principale — détecte la clé USB cible
# Retourne 0 et exporte TARGET_DEVICE si succès, 1 sinon.
# ---------------------------------------------------------------------------
detect_usb() {
    section "Détection de la clé USB cible"

    local max_attempts=3
    local attempt=0

    while (( attempt < max_attempts )); do
        attempt=$((attempt + 1))
        info "Tentative $attempt / $max_attempts"

        # Étape 1 : demander de débrancher toutes les clés USB
        printf '\n%b>>> Étape 1/3 :%b DÉBRANCHEZ toutes vos clés USB maintenant.\n' \
            "$C_BOLD$C_YELLOW" "$C_RESET"
        pause "Quand c'est fait, appuyez sur Entrée..."

        # Étape 2 : snapshot initial
        local before
        before=$(_usb_snapshot)
        debug "Snapshot AVANT : [$before]"
        if [[ -n "$before" ]]; then
            warn "Des périphériques USB sont encore détectés : $before"
            warn "Assurez-vous d'avoir bien débranché toutes vos clés."
            if ! confirm "Continuer malgré tout ?" "n"; then
                continue
            fi
        fi

        # Étape 3 : demander de brancher la clé cible
        printf '\n%b>>> Étape 2/3 :%b BRANCHEZ maintenant la clé USB cible.\n' \
            "$C_BOLD$C_YELLOW" "$C_RESET"
        pause "Une fois branchée, appuyez sur Entrée..."

        # Étape 4 : laisser au système le temps de détecter (udev)
        info "Attente de 3 secondes pour la détection système..."
        sleep 3

        # Étape 5 : snapshot final + diff
        local after
        after=$(_usb_snapshot)
        debug "Snapshot APRÈS : [$after]"

        local new_devices
        new_devices=$(comm -13 <(echo "$before") <(echo "$after"))

        # Étape 6 : analyse du résultat
        local count
        count=$(echo -n "$new_devices" | grep -c '^' || true)

        if (( count == 1 )); then
            local name="$new_devices"
            local info_str
            info_str=$(_usb_info "$name")
            local model="${info_str%|*}"
            local size="${info_str#*|}"

            local size_bytes
            size_bytes=$(_usb_size_bytes "$name")

            section "Clé USB détectée"
            printf '  %bPériphérique :%b /dev/%s\n' "$C_BOLD" "$C_RESET" "$name"
            printf '  %bModèle       :%b %s\n'      "$C_BOLD" "$C_RESET" "$model"
            printf '  %bTaille       :%b %s\n\n'    "$C_BOLD" "$C_RESET" "$size"

            # Vérif taille minimale
            if [[ -n "$size_bytes" ]] && (( size_bytes < 8 * 1024 * 1024 * 1024 )); then
                warn "Cette clé fait moins de 8 Go — insuffisant pour Winux."
                if ! confirm "Continuer quand même ?" "n"; then
                    continue
                fi
            fi

            # Étape 7 : validation sécurité du chemin
            local target="/dev/$name"
            if ! is_safe_usb_device "$target"; then
                error "Périphérique $target refusé par la règle de sécurité."
                error "Seuls /dev/sdb, /dev/sdc, etc. sont acceptés (pas /dev/sda)."
                continue
            fi

            # Confirmation explicite — toutes les données seront effacées
            printf '\n'
            if ! confirm_strict "⚠  TOUTES LES DONNÉES sur $target seront DÉFINITIVEMENT EFFACÉES."; then
                warn "Confirmation refusée. Nouvelle tentative..."
                continue
            fi

            # Démontage préventif
            unmount_all_partitions "$target"

            export TARGET_DEVICE="$target"
            ok "Clé USB validée : $TARGET_DEVICE"
            return 0

        elif (( count == 0 )); then
            error "Aucun nouveau périphérique USB détecté."
            warn  "Vérifiez que votre clé est bien branchée et réessayez."
        else
            error "$count nouveaux périphériques détectés :"
            echo "$new_devices" | sed 's/^/   - \/dev\//'
            warn  "Impossible de déterminer lequel est la cible."
            warn  "Débranchez tous vos périphériques sauf la clé cible et réessayez."
        fi
    done

    error "Échec de la détection après $max_attempts tentatives."
    return 1
}
