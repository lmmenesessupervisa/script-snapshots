#!/usr/bin/env bash
# ==============================================================================
# uninstall.sh — Desinstalador del sistema de backups Restic + Drive
# Uso: sudo bash /opt/backup-scripts/uninstall.sh
# ==============================================================================

set -uo pipefail

# ==============================================================================
# COLORES Y UI
# ==============================================================================

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'
C_CYAN='\033[0;36m'; C_WHITE='\033[1;37m'

hr()      { printf "${C_DIM}%s${C_RESET}\n" "────────────────────────────────────────────────────"; }
title()   { printf "\n${C_BOLD}${C_WHITE}  %s${C_RESET}\n" "$*"; hr; }
ok()      { printf "  ${C_GREEN}✔${C_RESET}  %s\n" "$*"; }
skip()    { printf "  ${C_DIM}−${C_RESET}  %s\n" "$*"; }
warn_ui() { printf "  ${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; }
err_ui()  { printf "  ${C_RED}✖${C_RESET}  %s\n" "$*"; }
info()    { printf "  ${C_CYAN}→${C_RESET}  %s\n" "$*"; }
ask()     { printf "  ${C_YELLOW}?${C_RESET}  %s " "$*"; }
blank()   { printf "\n"; }

# ==============================================================================
# VALIDACIONES
# ==============================================================================

if [[ $EUID -ne 0 ]]; then
    err_ui "Este script debe ejecutarse con sudo"
    printf "  Uso: sudo bash /opt/backup-scripts/uninstall.sh\n"
    exit 1
fi

# Leer configuración si existe — maneja valores con y sin comillas
CONF="/opt/backup-scripts/backup.conf"
RCLONE_REMOTE="gdrive"
DRIVE_PATH=""
LOCAL_REPO="/backup-local/restic-repo"

_val() {
    local _line _v
    _line="$(grep -E "^${1}=" "$CONF" 2>/dev/null | head -1)" || true
    _v="${_line#*=}"   # eliminar KEY=
    _v="${_v#\"}"      # eliminar comilla inicial
    _v="${_v%\"}"      # eliminar comilla final
    printf '%s' "$_v"
}

if [[ -f "$CONF" ]]; then
    _r="$(_val RCLONE_REMOTE)"; RCLONE_REMOTE="${_r:-gdrive}"
    _d="$(_val DRIVE_PATH)";    DRIVE_PATH="${_d:-}"
    _l="$(_val LOCAL_REPO)";    LOCAL_REPO="${_l:-/backup-local/restic-repo}"
fi

# Detectar usuarios del sistema con home en /home (para limpiar configs antiguas)
SYSTEM_USERS=()
while IFS= read -r _home; do
    _user="$(basename "$_home")"
    id "$_user" &>/dev/null && SYSTEM_USERS+=("$_user")
done < <(find /home -maxdepth 1 -mindepth 1 -type d 2>/dev/null)

# ==============================================================================
# PANTALLA DE BIENVENIDA
# ==============================================================================

clear 2>/dev/null || true
printf "\n${C_BOLD}${C_RED}"
printf "  ╔══════════════════════════════════════════════════╗\n"
printf "  ║         DESINSTALADOR — SISTEMA DE BACKUPS       ║\n"
printf "  ╚══════════════════════════════════════════════════╝\n"
printf "${C_RESET}\n"

warn_ui "Este proceso eliminará del servidor:"
blank
printf "  ${C_DIM}  •  Scripts y configuración  (/opt/backup-scripts/)${C_RESET}\n"
printf "  ${C_DIM}  •  Backups locales           (${LOCAL_REPO%/*}/)${C_RESET}\n"
printf "  ${C_DIM}  •  Logs del sistema          (/var/log/restic/)${C_RESET}\n"
printf "  ${C_DIM}  •  Tareas automáticas        (cron de root y usuarios)${C_RESET}\n"
printf "  ${C_DIM}  •  Configuración de rclone   (/root/.config/rclone/ y /home/*)${C_RESET}\n"
blank

# Mostrar tamaños actuales para que el usuario sepa qué perderá
if [[ -d "/opt/backup-scripts" ]]; then
    _sz="$(du -sh /opt/backup-scripts 2>/dev/null | cut -f1)"
    printf "  ${C_DIM}  Tamaño scripts:      %s${C_RESET}\n" "$_sz"
fi
if [[ -d "${LOCAL_REPO%/*}" ]]; then
    _sz="$(du -sh "${LOCAL_REPO%/*}" 2>/dev/null | cut -f1)"
    printf "  ${C_DIM}  Tamaño backups loc:  %s${C_RESET}\n" "$_sz"
fi
blank
warn_ui "Los archivos en Google Drive NO se tocan por defecto."
warn_ui "Puedes elegir eliminarlos también durante el proceso."
blank
hr
blank
ask "¿Deseas continuar con la desinstalación? (escribe SI para confirmar):"
read -r confirm
blank

if [[ "$confirm" != "SI" ]]; then
    info "Desinstalación cancelada. No se modificó nada."
    blank
    exit 0
fi

# ==============================================================================
# OPCIONES
# ==============================================================================

title "Opciones de desinstalación"

# Opción: eliminar backups en Drive
if [[ -n "$DRIVE_PATH" ]]; then
    warn_ui "Backups en Drive detectados en:  ${RCLONE_REMOTE}:${DRIVE_PATH}"
    ask "¿Eliminar también los backups en Google Drive? (s/N):"
else
    ask "¿Eliminar backups en Google Drive? (no se detectó ruta — s/N):"
fi
read -r del_drive; blank

# Opción: desinstalar binarios
ask "¿Desinstalar los programas restic y rclone del servidor? (s/N):"
read -r del_binaries; blank

# Opción: conservar logs
ask "¿Conservar los logs en /var/log/restic/? (s/N):"
read -r keep_logs; blank

hr
info "Iniciando desinstalación..."
blank

# ==============================================================================
# PASO 1 — TAREAS CRON
# ==============================================================================

title "Paso 1 — Tareas automáticas (cron)"

_clean_cron() {
    local user="$1"
    local current
    current="$(crontab -u "$user" -l 2>/dev/null || true)"
    if echo "$current" | grep -qE 'backup-restic|sync-to-drive'; then
        echo "$current" \
            | grep -v '# BACKUP-RESTIC-MANAGED' \
            | grep -vE 'backup-restic|sync-to-drive' \
            | crontab -u "$user" - 2>/dev/null && \
            ok "Tareas cron eliminadas del usuario: $user" || \
            warn_ui "No se pudo limpiar el crontab de $user"
    else
        skip "Sin tareas cron de este sistema para: $user"
    fi
}

# Limpiar siempre root (instalación actual) y cualquier usuario del sistema (instalaciones antiguas)
_clean_cron "root"
for _u in "${SYSTEM_USERS[@]}"; do
    _clean_cron "$_u"
done

# ==============================================================================
# PASO 2 — CONFIGURACIÓN RCLONE
# ==============================================================================

title "Paso 2 — Configuración de rclone"

_remove_rclone_config() {
    local conf_path="$1"
    local label="$2"
    if [[ -f "$conf_path" ]]; then
        RCLONE_CONFIG="$conf_path" rclone config delete "$RCLONE_REMOTE" 2>/dev/null || true
        local remaining
        remaining="$(grep -c '^\[' "$conf_path" 2>/dev/null || echo 0)"
        if [[ "$remaining" -eq 0 ]]; then
            rm -f "$conf_path"
            ok "Configuración rclone eliminada: $label"
        else
            ok "Remote '${RCLONE_REMOTE}' eliminado ($label) — otros remotes conservados"
        fi
    else
        skip "Sin configuración rclone en: $label"
    fi
}

# Root (instalación actual)
_remove_rclone_config "/root/.config/rclone/rclone.conf" "root"

# Usuarios del sistema (instalaciones antiguas donde podía estar en /home/*)
for _u in "${SYSTEM_USERS[@]}"; do
    _remove_rclone_config "/home/${_u}/.config/rclone/rclone.conf" "$_u"
done

# Caches de rclone
for _cache in "/root/.cache/rclone" $(printf "/home/%s/.cache/rclone " "${SYSTEM_USERS[@]}" 2>/dev/null); do
    if [[ -d "$_cache" ]]; then
        rm -rf "$_cache"
        ok "Cache rclone eliminado: $_cache"
    fi
done

# ==============================================================================
# PASO 3 — BACKUPS EN DRIVE (opcional)
# ==============================================================================

title "Paso 3 — Backups en Google Drive"

if [[ "${del_drive,,}" == "s" ]]; then
    if [[ -z "$DRIVE_PATH" ]]; then
        warn_ui "No se encontró DRIVE_PATH en la configuración"
        warn_ui "Elimina manualmente la carpeta de backups desde drive.google.com"
    else
        info "Eliminando ${RCLONE_REMOTE}:${DRIVE_PATH} en Drive..."
        if rclone purge "${RCLONE_REMOTE}:${DRIVE_PATH}" 2>/dev/null; then
            ok "Backups en Drive eliminados: ${RCLONE_REMOTE}:${DRIVE_PATH}"
        else
            warn_ui "No se pudo eliminar en Drive"
            warn_ui "Razón posible: la cuenta ya fue desconectada en el paso anterior"
            warn_ui "Si quedan archivos, elimínalos manualmente desde drive.google.com"
        fi
    fi
else
    skip "Backups en Drive conservados — no se tocó Google Drive"
fi

# ==============================================================================
# PASO 4 — BACKUPS LOCALES
# ==============================================================================

title "Paso 4 — Backups locales"

_local_root="${LOCAL_REPO%/*}"   # /backup-local  (padre del repo)
# Si LOCAL_REPO es /backup-local/restic-repo, limpiar /backup-local completo
# Si está en otra ruta, limpiar solo el repo
if [[ "$_local_root" == "/backup-local" ]]; then
    if [[ -d "/backup-local" ]]; then
        _sz="$(du -sh /backup-local 2>/dev/null | cut -f1)"
        rm -rf "/backup-local"
        ok "Repositorio local eliminado: /backup-local/  (${_sz})"
    else
        skip "No existía repositorio local (/backup-local/)"
    fi
else
    if [[ -d "$LOCAL_REPO" ]]; then
        _sz="$(du -sh "$LOCAL_REPO" 2>/dev/null | cut -f1)"
        rm -rf "$LOCAL_REPO"
        ok "Repositorio local eliminado: ${LOCAL_REPO}  (${_sz})"
    else
        skip "No existía repositorio local: ${LOCAL_REPO}"
    fi
fi

# ==============================================================================
# PASO 5 — SCRIPTS Y CONFIGURACIÓN
# ==============================================================================

title "Paso 5 — Scripts y configuración"

if [[ -d "/opt/backup-scripts" ]]; then
    _sz="$(du -sh /opt/backup-scripts 2>/dev/null | cut -f1)"
    rm -rf "/opt/backup-scripts"
    ok "Directorio de scripts eliminado: /opt/backup-scripts/  (${_sz})"
else
    skip "No existía /opt/backup-scripts/"
fi

# ==============================================================================
# PASO 6 — LOGS (opcional)
# ==============================================================================

title "Paso 6 — Logs del sistema"

if [[ -d "/var/log/restic" ]]; then
    if [[ "${keep_logs,,}" == "s" ]]; then
        skip "Logs conservados en /var/log/restic/ (según tu elección)"
    else
        _sz="$(du -sh /var/log/restic 2>/dev/null | cut -f1)"
        rm -rf "/var/log/restic"
        ok "Logs eliminados: /var/log/restic/  (${_sz})"
    fi
else
    skip "No existía directorio de logs"
fi

# ==============================================================================
# PASO 7 — BINARIOS (opcional)
# ==============================================================================

title "Paso 7 — Programas restic y rclone"

if [[ "${del_binaries,,}" == "s" ]]; then
    for bin in restic rclone; do
        if command -v "$bin" &>/dev/null; then
            bin_path="$(command -v "$bin")"
            rm -f "$bin_path"
            ok "$bin eliminado: $bin_path"
        else
            skip "$bin no estaba instalado en el sistema"
        fi
    done
    # Caches de restic en root y usuarios del sistema
    for _cache in "/root/.cache/restic" $(printf "/home/%s/.cache/restic " "${SYSTEM_USERS[@]}" 2>/dev/null); do
        if [[ -d "$_cache" ]]; then
            rm -rf "$_cache"
            ok "Cache restic eliminado: $_cache"
        fi
    done
else
    skip "restic y rclone conservados en el sistema"
fi

# ==============================================================================
# RESUMEN FINAL
# ==============================================================================

blank
printf "${C_BOLD}${C_GREEN}"
printf "  ╔══════════════════════════════════════════════════╗\n"
printf "  ║           DESINSTALACIÓN COMPLETADA              ║\n"
printf "  ╚══════════════════════════════════════════════════╝\n"
printf "${C_RESET}\n"

ok "El sistema de backups fue eliminado del servidor."
blank

[[ "${keep_logs,,}"    == "s" ]] && info "Logs conservados en:  /var/log/restic/"
[[ "${del_drive,,}"    != "s" ]] && info "Backups en Drive intactos → drive.google.com"
[[ "${del_binaries,,}" != "s" ]] && info "restic y rclone siguen instalados en el servidor"

blank
info "Para volver a instalar desde cero:"
printf "      ${C_CYAN}sudo bash install.sh${C_RESET}\n"
blank
