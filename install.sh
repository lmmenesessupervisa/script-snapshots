#!/usr/bin/env bash
# ==============================================================================
# install.sh — Instalador completo del sistema de backups Restic + rclone
# Uso: sudo bash install.sh
# ==============================================================================

set -uo pipefail

# ==============================================================================
# VERSIONES A INSTALAR
# ==============================================================================

RESTIC_VERSION="0.16.4"
RCLONE_VERSION="1.68.2"
DEST="/opt/backup-scripts"
LOG_DIR="/var/log/restic"
LOCAL_REPO="/backup-local/restic-repo"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"

# ==============================================================================
# COLORES Y UI
# ==============================================================================

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'
C_CYAN='\033[0;36m'; C_WHITE='\033[1;37m'; C_BLUE='\033[0;34m'

hr()      { printf "${C_DIM}%s${C_RESET}\n" "────────────────────────────────────────────────────"; }
title()   { printf "\n${C_BOLD}${C_WHITE}  %s${C_RESET}\n" "$*"; hr; }
ok()      { printf "  ${C_GREEN}✔${C_RESET}  %s\n" "$*"; }
skip()    { printf "  ${C_DIM}−${C_RESET}  %s\n" "$*"; }
warn_ui() { printf "  ${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; }
err_ui()  { printf "  ${C_RED}✖${C_RESET}  %s\n" "$*"; }
info()    { printf "  ${C_CYAN}→${C_RESET}  %s\n" "$*"; }
ask()     { printf "  ${C_BLUE}?${C_RESET}  %s " "$*"; }
blank()   { printf "\n"; }

# Limpieza del directorio temporal al salir
trap 'rm -rf "$TMP_DIR"' EXIT

# ==============================================================================
# VALIDACIONES PREVIAS
# ==============================================================================

clear 2>/dev/null || true
printf "\n${C_BOLD}${C_WHITE}"
printf "  ╔══════════════════════════════════════════════════╗\n"
printf "  ║      INSTALADOR — SISTEMA DE BACKUPS             ║\n"
printf "  ║         Restic + rclone + Google Drive           ║\n"
printf "  ╚══════════════════════════════════════════════════╝\n"
printf "${C_RESET}\n"

title "Verificando requisitos del sistema"

# Debe ejecutarse como root
if [[ $EUID -ne 0 ]]; then
    err_ui "Este script debe ejecutarse con sudo"
    printf "  Uso: sudo bash install.sh\n"
    exit 1
fi
ok "Ejecutando como root"

# Sistema operativo compatible
if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
    warn_ui "Este script está optimizado para Ubuntu/Debian"
    warn_ui "Puede funcionar en otros sistemas pero no está garantizado"
else
    OS_NAME="$(grep -oP '(?<=^NAME=").*(?=")' /etc/os-release 2>/dev/null || echo 'Linux')"
    ok "Sistema operativo: ${OS_NAME}"
fi

# Arquitectura soportada
ARCH="$(uname -m)"
if [[ "$ARCH" != "x86_64" ]]; then
    err_ui "Arquitectura no soportada: $ARCH (se requiere x86_64 / amd64)"
    exit 1
fi
ok "Arquitectura: ${ARCH}"

# Conectividad a internet
info "Verificando conexión a internet..."
if ! ping -c 2 -W 3 8.8.8.8 &>/dev/null && ! ping -c 2 -W 3 1.1.1.1 &>/dev/null; then
    err_ui "Sin conexión a internet — se necesita para descargar las herramientas"
    exit 1
fi
ok "Conexión a internet disponible"

# Archivos fuente presentes
REQUIRED_FILES=(backup.conf backup-restic.sh sync-to-drive.sh uninstall.sh)
all_present=true
for f in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "${SOURCE_DIR}/${f}" ]]; then
        err_ui "Archivo requerido no encontrado: ${SOURCE_DIR}/${f}"
        all_present=false
    fi
done
[[ "$all_present" == "false" ]] && exit 1
ok "Archivos del sistema encontrados (${#REQUIRED_FILES[@]}/${#REQUIRED_FILES[@]})"

# ==============================================================================
# PASO 1 — DEPENDENCIAS DEL SISTEMA
# ==============================================================================

title "Paso 1 — Dependencias del sistema"

info "Actualizando lista de paquetes..."
apt-get update -qq 2>/dev/null && ok "Lista de paquetes actualizada" || \
    warn_ui "No se pudo actualizar la lista (continuando de todas formas)"

PKGS_NEEDED=()
for pkg in wget curl unzip bzip2 python3 cron less; do
    if ! dpkg -l "$pkg" &>/dev/null || ! dpkg -l "$pkg" | grep -q '^ii'; then
        PKGS_NEEDED+=("$pkg")
    fi
done

if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
    info "Instalando: ${PKGS_NEEDED[*]}..."
    apt-get install -y -qq "${PKGS_NEEDED[@]}" 2>/dev/null && \
        ok "Paquetes instalados: ${PKGS_NEEDED[*]}" || {
        err_ui "Fallo al instalar paquetes: ${PKGS_NEEDED[*]}"
        exit 1
    }
else
    skip "Todas las dependencias ya están instaladas"
fi

python3 --version &>/dev/null && ok "python3: $(python3 --version 2>&1)" || \
    { err_ui "python3 no disponible"; exit 1; }

# ==============================================================================
# PASO 2 — INSTALAR RESTIC
# ==============================================================================

title "Paso 2 — Restic ${RESTIC_VERSION}"

RESTIC_BIN="/usr/local/bin/restic"
RESTIC_URL="https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2"

_install_restic() {
    info "Descargando restic v${RESTIC_VERSION}..."
    if ! wget -q --show-progress -O "${TMP_DIR}/restic.bz2" "$RESTIC_URL"; then
        err_ui "Fallo al descargar restic desde GitHub"
        return 1
    fi
    info "Descomprimiendo..."
    bunzip2 -f "${TMP_DIR}/restic.bz2"
    mv "${TMP_DIR}/restic" "$RESTIC_BIN"
    chmod +x "$RESTIC_BIN"
}

if command -v restic &>/dev/null; then
    CURRENT_VER="$(restic version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)"
    if [[ "$CURRENT_VER" == "$RESTIC_VERSION" ]]; then
        skip "restic v${RESTIC_VERSION} ya está instalado"
    else
        warn_ui "restic v${CURRENT_VER} instalado — actualizando a v${RESTIC_VERSION}..."
        _install_restic || exit 1
        ok "restic actualizado a v${RESTIC_VERSION}"
    fi
else
    _install_restic || exit 1
    ok "restic v${RESTIC_VERSION} instalado en ${RESTIC_BIN}"
fi

restic version &>/dev/null || { err_ui "restic instalado pero no responde"; exit 1; }
ok "restic verificado: $(restic version 2>/dev/null | head -1)"

# ==============================================================================
# PASO 3 — INSTALAR RCLONE
# ==============================================================================

title "Paso 3 — rclone ${RCLONE_VERSION}"

RCLONE_BIN="/usr/local/bin/rclone"
RCLONE_URL="https://github.com/rclone/rclone/releases/download/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-amd64.zip"

_install_rclone() {
    info "Descargando rclone v${RCLONE_VERSION}..."
    if ! wget -q --show-progress -O "${TMP_DIR}/rclone.zip" "$RCLONE_URL"; then
        err_ui "Fallo al descargar rclone desde GitHub"
        return 1
    fi
    info "Descomprimiendo..."
    unzip -q "${TMP_DIR}/rclone.zip" -d "${TMP_DIR}/rclone_extract"
    mv "${TMP_DIR}/rclone_extract/rclone-v${RCLONE_VERSION}-linux-amd64/rclone" "$RCLONE_BIN"
    chmod +x "$RCLONE_BIN"
}

if command -v rclone &>/dev/null; then
    CURRENT_VER="$(rclone version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)"
    if [[ "$CURRENT_VER" == "$RCLONE_VERSION" ]]; then
        skip "rclone v${RCLONE_VERSION} ya está instalado"
    else
        warn_ui "rclone v${CURRENT_VER} instalado — actualizando a v${RCLONE_VERSION}..."
        _install_rclone || exit 1
        ok "rclone actualizado a v${RCLONE_VERSION}"
    fi
else
    _install_rclone || exit 1
    ok "rclone v${RCLONE_VERSION} instalado en ${RCLONE_BIN}"
fi

rclone version &>/dev/null || { err_ui "rclone instalado pero no responde"; exit 1; }
ok "rclone verificado: $(rclone version 2>/dev/null | head -1)"

# ==============================================================================
# PASO 4 — CONFIGURACIÓN INICIAL
# ==============================================================================

title "Paso 4 — Configuración inicial"

blank
info "Vamos a configurar los datos básicos del sistema."
info "Puedes cambiar todo esto después desde el menú (opción 13)."
blank

# Nombre del servidor (para la carpeta en Drive)
HOSTNAME_DEFAULT="$(hostname -s 2>/dev/null || echo 'servidor')"
ask "Nombre de este servidor (para identificarlo en Drive) [${HOSTNAME_DEFAULT}]:"
read -r INPUT_SERVER
INPUT_SERVER="${INPUT_SERVER:-$HOSTNAME_DEFAULT}"
blank

# Carpeta en Google Drive
DRIVE_PATH_DEFAULT="backups/${INPUT_SERVER}"
blank
printf "  ${C_DIM}  Los backups se guardarán en esta carpeta dentro de tu Google Drive.${C_RESET}\n"
printf "  ${C_DIM}  Puedes usar subcarpetas, ej: backups/produccion${C_RESET}\n"
blank
ask "Nombre de la carpeta en Google Drive [${DRIVE_PATH_DEFAULT}]:"
read -r INPUT_DRIVE_PATH
INPUT_DRIVE_PATH="${INPUT_DRIVE_PATH:-$DRIVE_PATH_DEFAULT}"
blank

# Nombre del remote rclone
blank
printf "  ${C_DIM}  El \"remote\" es el alias que le darás a tu Google Drive en rclone.${C_RESET}\n"
printf "  ${C_DIM}  Puede ser cualquier nombre. El más común es 'gdrive'.${C_RESET}\n"
blank
ask "Nombre del remote para rclone [gdrive]:"
read -r INPUT_REMOTE
INPUT_REMOTE="${INPUT_REMOTE:-gdrive}"
blank

# Contraseña de cifrado
blank
printf "  ${C_BOLD}Contraseña de cifrado de backups${C_RESET}\n"
blank
printf "  ${C_DIM}  Esta contraseña CIFRA todos tus backups.${C_RESET}\n"
printf "  ${C_DIM}  Sin ella es IMPOSIBLE restaurar archivos.${C_RESET}\n"
printf "  ${C_DIM}  Guárdala en un lugar seguro — si la pierdes, los backups no sirven.${C_RESET}\n"
blank
while true; do
    ask "Contraseña (no se muestra al escribir):"
    read -rs INPUT_PASS; printf "\n"
    if [[ -z "$INPUT_PASS" ]]; then
        warn_ui "La contraseña no puede estar vacía"
        continue
    fi
    ask "Repite la contraseña:"
    read -rs INPUT_PASS2; printf "\n"
    if [[ "$INPUT_PASS" != "$INPUT_PASS2" ]]; then
        warn_ui "Las contraseñas no coinciden — inténtalo de nuevo"
        continue
    fi
    break
done
blank
ok "Configuración capturada"

# ==============================================================================
# PASO 5 — CREAR DIRECTORIOS
# ==============================================================================

title "Paso 5 — Directorios del sistema"

mkdir -p "$DEST"
mkdir -p "${DEST}/backup-previo"
mkdir -p "$LOG_DIR"
mkdir -p "$LOCAL_REPO"
ok "Directorios creados:"
info "  Scripts:       ${DEST}"
info "  Logs:          ${LOG_DIR}"
info "  Repo local:    ${LOCAL_REPO}"

# ==============================================================================
# PASO 6 — COPIAR ARCHIVOS
# ==============================================================================

title "Paso 6 — Copiar archivos del sistema"

cp "${SOURCE_DIR}/backup-restic.sh" "${DEST}/backup-restic.sh"
cp "${SOURCE_DIR}/sync-to-drive.sh" "${DEST}/sync-to-drive.sh"
cp "${SOURCE_DIR}/uninstall.sh"     "${DEST}/uninstall.sh"
ok "Scripts copiados a ${DEST}"

# ==============================================================================
# PASO 7 — GENERAR backup.conf PERSONALIZADO
# ==============================================================================

title "Paso 7 — Generando backup.conf"

cat > "${DEST}/backup.conf" <<CONF
#!/usr/bin/env bash
# ==============================================================================
# ARCHIVO DE CONFIGURACIÓN CENTRAL
# /opt/backup-scripts/backup.conf
# Edita SOLO este archivo o usa el menú (opción 13). Los scripts lo leen automáticamente.
# ==============================================================================

# --- Repositorios ---
# Nombre del remote configurado en rclone (el que escribiste al hacer rclone config)
RCLONE_REMOTE="${INPUT_REMOTE}"

# Carpeta dentro de Google Drive donde se guardan los backups.
# Puedes usar subcarpetas: "mis-backups/servidor" o simplemente "mis-backups"
DRIVE_PATH="${INPUT_DRIVE_PATH}"

# Repositorio local (fallback sin internet)
LOCAL_REPO="${LOCAL_REPO}"

# --- Tipo de Google Drive ---
# "false" → Google Drive personal (Mi Unidad)   ← valor por defecto
# "true"  → Solo si usas Google Workspace con una Unidad Compartida (Team Drive)
#            En ese caso debes poner el ID en TEAM_DRIVE_ID
SHARED_DRIVE="false"
TEAM_DRIVE_ID=""

# --- Seguridad ---
RESTIC_PASSWORD="${INPUT_PASS}"

# --- Directorios a respaldar ---
BACKUP_DIRS=(
    "/home"
    "/etc"
    "/var/www"
    "/opt"
)

# --- Exclusiones ---
EXCLUDE_PATTERNS=(
    "/home/*/.cache"
    "/home/*/.local/share/Trash"
    "/home/*/.local/share/recently-used.xbel"
    "*.tmp"
    "*.log"
    "*.swp"
    "/var/cache"
    "/opt/backup-scripts/backup-previo"
    "node_modules"
    ".git"
)

# --- Política de retención ---
ENABLE_RETENTION="true"
KEEP_LAST="3"          # Últimas N copias  (0 = desactivado)
KEEP_DAILY="7"         # N backups diarios (0 = desactivado)
KEEP_WEEKLY="4"        # N semanales       (0 = desactivado)
KEEP_MONTHLY="0"       # N mensuales       (0 = desactivado)

# --- Logs ---
LOG_DIR="${LOG_DIR}"
LOG_FILE="${LOG_DIR}/backup.log"
ERROR_LOG="${LOG_DIR}/error.log"
SYNC_LOG="${LOG_DIR}/sync.log"
RESTORE_LOG="${LOG_DIR}/restauracion.log"
CONF

ok "backup.conf generado con tu configuración:"
info "  Remote:     ${INPUT_REMOTE}"
info "  Carpeta:    ${INPUT_DRIVE_PATH}"
info "  Contraseña: configurada (cifrada en archivo)"

# ==============================================================================
# PASO 8 — PERMISOS
# ==============================================================================

title "Paso 8 — Permisos"

# backup.conf contiene la contraseña — solo root puede leerlo
chmod 600  "${DEST}/backup.conf"
# Scripts ejecutables por root (y legibles por grupo)
chmod 750  "${DEST}/backup-restic.sh"
chmod 750  "${DEST}/sync-to-drive.sh"
chmod 750  "${DEST}/uninstall.sh"
# Directorios
chmod 755  "$DEST" "${DEST}/backup-previo"
chmod 700  "$LOCAL_REPO"    # solo root accede al repo local
chmod 755  "$LOG_DIR"
ok "Permisos aplicados (backup.conf protegido: solo root)"

# ==============================================================================
# PASO 9 — SERVICIO CRON
# ==============================================================================

title "Paso 9 — Servicio cron"

if systemctl is-active cron &>/dev/null || systemctl is-active crond &>/dev/null; then
    ok "Servicio cron activo"
elif systemctl enable --now cron &>/dev/null || systemctl enable --now crond &>/dev/null; then
    ok "Servicio cron activado"
else
    warn_ui "No se pudo verificar/activar el servicio cron"
    warn_ui "Actívalo manualmente: sudo systemctl enable --now cron"
fi

# ==============================================================================
# PASO 10 — INSTALAR TAREAS CRON EN ROOT
# ==============================================================================

title "Paso 10 — Programar backups automáticos (cron de root)"

info "Los backups automáticos se instalan en el crontab de ROOT"
info "para que tengan acceso completo a todos los archivos del sistema."
blank
ask "¿Instalar backup diario (3:00 AM) y sync cada 6 horas? (S/n):"
read -r INSTALL_CRON
blank

if [[ "${INSTALL_CRON,,}" != "n" ]]; then
    local_marker="# BACKUP-RESTIC-MANAGED"
    local_tmp="$(mktemp)"
    crontab -l 2>/dev/null \
        | grep -v "$local_marker" \
        | grep -v 'backup-restic\|sync-to-drive' > "$local_tmp" || true
    cat >> "$local_tmp" <<EOF
${local_marker}
0 3 * * * bash ${DEST}/backup-restic.sh --backup >> ${LOG_DIR}/cron.log 2>&1
0 */6 * * * bash ${DEST}/sync-to-drive.sh >> ${LOG_DIR}/cron.log 2>&1
0 0 1 * * find ${LOG_DIR} -name "*.log" -mtime +30 -delete
EOF
    crontab "$local_tmp"
    rm -f "$local_tmp"
    ok "Tareas cron instaladas en root:"
    info "  Backup diario    → 3:00 AM"
    info "  Sync a Drive     → cada 6 horas"
    info "  Limpieza de logs → día 1 de cada mes"
else
    skip "Cron no instalado — puedes hacerlo después desde el menú (opción 11)"
fi

# ==============================================================================
# VERIFICACIÓN FINAL
# ==============================================================================

title "Verificación final"

all_ok=true
_check() {
    local label="$1"; local cmd="$2"
    if eval "$cmd" &>/dev/null; then
        ok "$label"
    else
        err_ui "$label — FALLO"
        all_ok=false
    fi
}

_check "restic accesible"            "command -v restic"
_check "rclone accesible"            "command -v rclone"
_check "python3 accesible"           "command -v python3"
_check "backup-restic.sh ejecutable" "test -x ${DEST}/backup-restic.sh"
_check "sync-to-drive.sh ejecutable" "test -x ${DEST}/sync-to-drive.sh"
_check "uninstall.sh ejecutable"     "test -x ${DEST}/uninstall.sh"
_check "backup.conf presente"        "test -f ${DEST}/backup.conf"
_check "Directorio de logs"          "test -d ${LOG_DIR}"
_check "Repositorio local"           "test -d ${LOCAL_REPO}"

blank
if [[ "$all_ok" == "true" ]]; then
    printf "${C_BOLD}${C_GREEN}"
    printf "  ╔══════════════════════════════════════════════════╗\n"
    printf "  ║         INSTALACIÓN COMPLETADA CON ÉXITO         ║\n"
    printf "  ╚══════════════════════════════════════════════════╝\n"
    printf "${C_RESET}\n"
else
    printf "${C_BOLD}${C_YELLOW}"
    printf "  ╔══════════════════════════════════════════════════╗\n"
    printf "  ║     INSTALACIÓN COMPLETADA CON ADVERTENCIAS      ║\n"
    printf "  ╚══════════════════════════════════════════════════╝\n"
    printf "${C_RESET}\n"
    warn_ui "Revisa los errores marcados con ✖ antes de continuar"
fi

# ==============================================================================
# PRÓXIMOS PASOS
# ==============================================================================

blank
hr
printf "  ${C_BOLD}PRÓXIMOS PASOS${C_RESET}\n"
hr
blank
printf "  ${C_BOLD}${C_CYAN}1. Conectar Google Drive${C_RESET}\n"
printf "  ${C_DIM}     Abre el menú y selecciona opción [8] para autorizar tu cuenta.${C_RESET}\n"
printf "  ${C_DIM}     El script te guiará paso a paso (necesitarás un navegador web).${C_RESET}\n"
blank
printf "  ${C_BOLD}${C_CYAN}2. Ejecutar el primer backup${C_RESET}\n"
printf "  ${C_DIM}     Desde el menú, opción [1] → Ejecutar backup ahora.${C_RESET}\n"
blank
printf "  ${C_BOLD}${C_YELLOW}⚠  IMPORTANTE — Ejecuta siempre con sudo:${C_RESET}\n"
printf "  ${C_DIM}     Sin sudo, los archivos del sistema con permisos restringidos${C_RESET}\n"
printf "  ${C_DIM}     (/etc/ufw, etc.) no se incluirán en el backup.${C_RESET}\n"
blank
printf "  ${C_BOLD}Abrir el menú principal:${C_RESET}\n"
printf "      ${C_CYAN}sudo bash ${DEST}/backup-restic.sh${C_RESET}\n"
blank
printf "  ${C_BOLD}Desinstalar todo en cualquier momento:${C_RESET}\n"
printf "      ${C_CYAN}sudo bash ${DEST}/uninstall.sh${C_RESET}\n"
blank
hr
blank
