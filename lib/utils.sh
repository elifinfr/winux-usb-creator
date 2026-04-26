#!/usr/bin/env bash
# ============================================================================
# utils.sh — Fonctions utilitaires communes (couleurs, logs, confirmations)
# ============================================================================
# Ce module est destiné à être sourcé par les autres scripts du projet.
# Il fournit :
#   - des constantes de couleurs ANSI
#   - des fonctions de log (info, ok, warn, error, debug)
#   - des helpers de confirmation utilisateur
#   - une fonction de vérification de dépendances
# ============================================================================

# Évite le double-sourcing
if [[ -n "${__WINUX_UTILS_LOADED:-}" ]]; then
    return 0
fi
__WINUX_UTILS_LOADED=1

# ---------------------------------------------------------------------------
# Couleurs ANSI
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    readonly C_RESET='\033[0m'
    readonly C_BOLD='\033[1m'
    readonly C_BLUE='\033[0;34m'
    readonly C_GREEN='\033[0;32m'
    readonly C_YELLOW='\033[0;33m'
    readonly C_RED='\033[0;31m'
    readonly C_CYAN='\033[0;36m'
    readonly C_GRAY='\033[0;90m'
else
    readonly C_RESET='' C_BOLD='' C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_CYAN='' C_GRAY=''
fi

# ---------------------------------------------------------------------------
# Fichier de log global
# ---------------------------------------------------------------------------
: "${LOG_FILE:=/tmp/winux-usb-creator.log}"

# Initialise le fichier de log (écrase à chaque nouvelle exécution)
init_log() {
    : > "$LOG_FILE"
    echo "=== Winux USB Creator — log démarré le $(date '+%F %T') ===" >> "$LOG_FILE"
}

# Écrit une ligne dans le fichier de log (horodatée)
_log_to_file() {
    local level="$1"; shift
    printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$level" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Fonctions d'affichage
# ---------------------------------------------------------------------------
info()  { printf '%b[INFO]%b  %s\n'  "$C_BLUE"   "$C_RESET" "$*"; _log_to_file "INFO"  "$*"; }
ok()    { printf '%b[OK]%b    %s\n' "$C_GREEN"  "$C_RESET" "$*"; _log_to_file "OK"    "$*"; }
warn()  { printf '%b[WARN]%b  %s\n' "$C_YELLOW" "$C_RESET" "$*"; _log_to_file "WARN"  "$*"; }
error() { printf '%b[ERREUR]%b %s\n' "$C_RED"   "$C_RESET" "$*" >&2; _log_to_file "ERROR" "$*"; }
debug() { [[ "${DEBUG:-0}" == "1" ]] && printf '%b[DEBUG]%b %s\n' "$C_GRAY" "$C_RESET" "$*"; _log_to_file "DEBUG" "$*"; }

# Affiche une section mise en valeur
section() {
    printf '\n%b=== %s ===%b\n\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"
    _log_to_file "SECTION" "$*"
}

# ---------------------------------------------------------------------------
# Confirmations utilisateur
# ---------------------------------------------------------------------------

# confirm "Message" [défaut=o|n]
# Retourne 0 si oui, 1 si non
confirm() {
    local msg="$1"
    local default="${2:-n}"
    local prompt reply
    if [[ "$default" == "o" ]]; then
        prompt="[O/n]"
    else
        prompt="[o/N]"
    fi
    while true; do
        # read avec timeout de 60 s pour éviter les scripts bloqués indéfiniment
        if ! read -r -t 60 -p "$(printf '%b?%b %s %s ' "$C_CYAN" "$C_RESET" "$msg" "$prompt")" reply; then
            echo
            warn "Aucune réponse après 60 s, valeur par défaut appliquée."
            reply="$default"
        fi
        reply="${reply:-$default}"
        case "${reply,,}" in
            o|oui|y|yes) return 0 ;;
            n|non|no)    return 1 ;;
            *) warn "Veuillez répondre par 'o' ou 'n'." ;;
        esac
    done
}

# confirm_strict "Message" — exige de taper exactement OUI en majuscules
# Utilisé pour les opérations destructives (effacement de clé)
confirm_strict() {
    local msg="$1"
    local reply
    printf '%b%s%b\n' "$C_YELLOW$C_BOLD" "$msg" "$C_RESET"
    printf '%bTapez %bOUI%b %b(en majuscules) pour confirmer, autre chose pour annuler :%b ' \
        "$C_YELLOW" "$C_BOLD$C_RED" "$C_RESET" "$C_YELLOW" "$C_RESET"
    read -r reply || reply=""
    if [[ "$reply" == "OUI" ]]; then
        return 0
    fi
    return 1
}

# pause "Message" — attend simplement Entrée
pause() {
    local msg="${1:-Appuyez sur Entrée pour continuer...}"
    read -r -p "$(printf '%b>%b %s' "$C_CYAN" "$C_RESET" "$msg")" _ || true
}

# ---------------------------------------------------------------------------
# Vérification de dépendances
# ---------------------------------------------------------------------------

# check_dependencies cmd1 cmd2 ... — vérifie que chaque commande existe
# Retourne 0 si tout est OK, 1 sinon (et affiche ce qui manque)
check_dependencies() {
    local missing=()
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        error "Dépendances manquantes : ${missing[*]}"
        info  "Installez-les avec : sudo apt update && sudo apt install -y ${missing[*]}"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Validation d'un chemin /dev/sdX (sécurité)
# ---------------------------------------------------------------------------
# N'accepte QUE /dev/sd[a-z] (pas de partition /dev/sdb1, pas de /dev/nvme…)
# Refuse /dev/sda par défaut car c'est généralement le disque système.
# Possibilité de forcer via la variable d'environnement ALLOW_SDA=1
# (cas typique : machine 100 % NVMe où la clé USB tombe sur /dev/sda).
is_safe_usb_device() {
    local dev="$1"
    if [[ ! "$dev" =~ ^/dev/sd[a-z]$ ]]; then
        return 1
    fi
    if [[ "$dev" == "/dev/sda" ]]; then
        if [[ "${ALLOW_SDA:-0}" == "1" ]]; then
            return 0
        fi
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Vérifie qu'un /dev/sdX n'est PAS le disque système (racine /)
# Retourne 0 si c'est sûr (différent du disque /), 1 si c'est le disque système.
# ---------------------------------------------------------------------------
is_not_system_disk() {
    local dev="$1"
    # Périphérique sur lequel "/" est monté (ex: /dev/nvme0n1p2 → /dev/nvme0n1)
    local root_src root_disk
    root_src=$(findmnt -no SOURCE / 2>/dev/null || echo "")
    if [[ -z "$root_src" ]]; then
        # On ne peut pas vérifier — par sécurité on refuse
        return 1
    fi
    # Remonte au disque parent (ex: sda1 → sda, nvme0n1p2 → nvme0n1)
    root_disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1)
    [[ -z "$root_disk" ]] && root_disk=$(basename "$root_src" | sed -E 's/[0-9]+$//; s/p$//')
    local dev_name
    dev_name=$(basename "$dev")
    if [[ "$dev_name" == "$root_disk" ]]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Formatage d'une taille en octets → humain
# ---------------------------------------------------------------------------
human_size() {
    local bytes="$1"
    numfmt --to=iec --suffix=B --format="%.1f" "$bytes" 2>/dev/null || echo "${bytes}B"
}
