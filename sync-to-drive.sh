#!/usr/bin/env bash
# ==============================================================================
# sync-to-drive.sh — Sincroniza backups locales a Google Drive
# Ubicación: /opt/backup-scripts/sync-to-drive.sh
# Requiere:  /opt/backup-scripts/backup.conf
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: No se encontró $CONFIG_FILE" >&2
    exit 1
fi
source "$CONFIG_FILE"

export RESTIC_PASSWORD
export RESTIC_PASSWORD2="$RESTIC_PASSWORD"   # requerido por 'restic copy --repo2'

# Aplicar Team Drive env en el shell principal (no funciona dentro de subshell "$(...)")
if [[ "${SHARED_DRIVE:-false}" == "true" && -n "${TEAM_DRIVE_ID:-}" ]]; then
    _rcu_tmp="$(echo "$RCLONE_REMOTE" | tr '[:lower:]' '[:upper:]')"
    export "RCLONE_CONFIG_${_rcu_tmp}_TEAM_DRIVE=${TEAM_DRIVE_ID}"
    unset _rcu_tmp
fi
mkdir -p "$LOG_DIR"

# ==============================================================================
# FUNCIONES
# ==============================================================================

log()   { echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO]  $*" | tee -a "$SYNC_LOG"; }
warn()  { echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN]  $*" | tee -a "$SYNC_LOG"; }
error() { echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" | tee -a "$SYNC_LOG" "$ERROR_LOG"; }

has_internet() {
    ping -c 2 -W 3 8.8.8.8 &>/dev/null || ping -c 2 -W 3 1.1.1.1 &>/dev/null
}

build_remote_repo() {
    # NOTA: NO hacer export aquí — se llama en subshell $(...) y los exports mueren.
    # El env var RCLONE_CONFIG_*_TEAM_DRIVE se establece al arrancar el script.
    echo "rclone:${RCLONE_REMOTE}:${DRIVE_PATH}"
}

count_snapshots() {
    local repo="$1"
    restic -r "$repo" snapshots --json 2>/dev/null | \
        python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || \
        restic -r "$repo" snapshots 2>/dev/null | grep -c '^[a-f0-9]\{8\}' 2>/dev/null || \
        echo 0
}

# ==============================================================================
# FLUJO PRINCIPAL
# ==============================================================================

log "──────────────────────────────────────────"
log "Inicio de sincronización — $(hostname)"
log "──────────────────────────────────────────"

# 1 — Verificar internet
if ! has_internet; then
    log "Sin internet — sincronización pospuesta"
    exit 0
fi

# 2 — Verificar que el repo local existe y tiene snapshots
if [[ ! -d "$LOCAL_REPO" ]]; then
    log "No existe repositorio local en $LOCAL_REPO — nada que sincronizar"
    exit 0
fi

SNAP_COUNT="$(count_snapshots "$LOCAL_REPO")"

if [[ "$SNAP_COUNT" -eq 0 ]]; then
    log "No hay snapshots locales para sincronizar"
    exit 0
fi

REMOTE_REPO="$(build_remote_repo)"

# 3 — Verificar / inicializar repo remoto
# 'cat config' es más fiable que 'snapshots': devuelve 0 para repos válidos (incluso vacíos)
if ! restic -r "$REMOTE_REPO" cat config &>/dev/null; then
    # Verificar conectividad antes de intentar init
    if ! rclone lsd "${RCLONE_REMOTE}:" &>/dev/null; then
        error "No se puede conectar a Google Drive. Verifica las credenciales."
        exit 1
    fi
    # Comprobar si la carpeta ya existe en Drive para evitar duplicados
    if rclone lsf "${RCLONE_REMOTE}:${DRIVE_PATH}" --max-depth 1 &>/dev/null 2>&1; then
        error "La carpeta '${DRIVE_PATH}' existe en Drive pero no es un repo Restic válido (posible duplicado o contraseña incorrecta)"
        exit 1
    fi
    log "Repositorio remoto no existe. Inicializando en ${RCLONE_REMOTE}:${DRIVE_PATH}..."
    restic -r "$REMOTE_REPO" init >> "$SYNC_LOG" 2>> "$ERROR_LOG" || {
        error "No se pudo inicializar el repositorio remoto"
        exit 1
    }
fi

# 4 — Mostrar estado antes de sincronizar
REMOTE_SNAPS="$(count_snapshots "$REMOTE_REPO")"
log "Estado: local=$SNAP_COUNT snapshot(s) / remoto=$REMOTE_SNAPS snapshot(s)"

# 5 — Copiar snapshots del local al remoto (restic copy es idempotente: omite los que ya existen)
if restic -r "$LOCAL_REPO" copy --repo2 "$REMOTE_REPO" >> "$SYNC_LOG" 2>&1; then
    log "Sincronización exitosa"

    # 6 — Conservar solo los últimos 2 en local tras sincronizar
    log "Limpiando backups locales antiguos (conservando últimos 2)..."
    restic -r "$LOCAL_REPO" forget --keep-last 2 --prune >> "$SYNC_LOG" 2>&1 && \
        log "Limpieza local completada" || \
        warn "Limpieza local falló (los backups en Drive siguen seguros)"
else
    error "Falló la sincronización a Drive"
    exit 1
fi

log "Proceso de sincronización completado"
log "──────────────────────────────────────────"