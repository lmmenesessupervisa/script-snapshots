#!/usr/bin/env bash
# ==============================================================================
# backup-restic.sh — Backup automático con Restic + rclone
# Ubicación: /opt/backup-scripts/backup-restic.sh
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
# COLORES Y UI
# ==============================================================================

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'
C_CYAN='\033[0;36m'; C_BLUE='\033[0;34m'; C_WHITE='\033[1;37m'

hr()      { printf "${C_DIM}%s${C_RESET}\n" "────────────────────────────────────────────────────"; }
title()   { printf "\n${C_BOLD}${C_WHITE}  %s${C_RESET}\n" "$*"; hr; }
ok()      { printf "  ${C_GREEN}✔${C_RESET}  %s\n" "$*"; }
warn_ui() { printf "  ${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; }
err_ui()  { printf "  ${C_RED}✖${C_RESET}  %s\n" "$*"; }
info()    { printf "  ${C_CYAN}→${C_RESET}  %s\n" "$*"; }
ask()     { printf "  ${C_BLUE}?${C_RESET}  %s " "$*"; }
opt()     { printf "  ${C_BOLD}[%s]${C_RESET}  %s\n" "$1" "$2"; }
blank()   { printf "\n"; }

log()     { echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO]  $*" >> "$LOG_FILE"; }
logw()    { echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN]  $*" >> "$LOG_FILE"; }
loge()    { local _lm="$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*"; echo "$_lm" >> "$LOG_FILE"; echo "$_lm" >> "$ERROR_LOG"; }

# ==============================================================================
# MECANISMO DE ROLLBACK ATÓMICO
# ==============================================================================

_ROLLBACK_STACK=()
_ROLLBACK_ACTIVE=false
_BACKUP_STARTED=false

register_rollback() {
    _ROLLBACK_STACK+=("$1:::$2")
}

run_rollback() {
    [[ "${_ROLLBACK_ACTIVE}" == "true" ]] && return
    _ROLLBACK_ACTIVE=true

    if [[ ${#_ROLLBACK_STACK[@]} -eq 0 ]]; then
        return
    fi

    blank
    printf "${C_YELLOW}${C_BOLD}  ⟳  Ejecutando rollback — deshaciendo cambios...${C_RESET}\n"
    hr

    local i
    for (( i=${#_ROLLBACK_STACK[@]}-1; i>=0; i-- )); do
        local entry="${_ROLLBACK_STACK[$i]}"
        local desc="${entry%%:::*}"
        local cmd="${entry##*:::}"
        printf "  ${C_DIM}↩  %s${C_RESET}\n" "$desc"
        eval "$cmd" 2>/dev/null || true
        log "Rollback: $desc"
    done

    blank
    warn_ui "Rollback completado. El sistema quedó en su estado original."
    warn_ui "Revisa ${ERROR_LOG} para ver el motivo del fallo."
    blank
}

cleanup_on_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && "${_ROLLBACK_ACTIVE}" == "false" ]]; then
        blank
        err_ui "El script terminó inesperadamente (código: $exit_code)"
        loge "Salida inesperada con código $exit_code — iniciando rollback"
        run_rollback
    fi
}
trap cleanup_on_exit EXIT
trap 'blank; err_ui "Interrumpido por el usuario (Ctrl+C)"; loge "Interrumpido por SIGINT"; exit 130' INT TERM

# ==============================================================================
# FUNCIONES CORE
# ==============================================================================

has_internet() {
    ping -c 2 -W 3 8.8.8.8 &>/dev/null || ping -c 2 -W 3 1.1.1.1 &>/dev/null
}

has_display() {
    [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]
}

build_remote_repo() {
    # NOTA: NO hacer export aquí — esta función se llama en subshell $(...) y
    # los exports mueren con el subshell. El env var RCLONE_CONFIG_*_TEAM_DRIVE
    # se establece en el shell principal al arrancar y al recargar la config.
    echo "rclone:${RCLONE_REMOTE}:${DRIVE_PATH}"
}

count_snapshots() {
    local repo="$1"
    restic -r "$repo" snapshots --json 2>/dev/null | \
        python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || \
        restic -r "$repo" snapshots 2>/dev/null | grep -c '^[a-f0-9]\{8\}' 2>/dev/null || \
        echo 0
}

build_exclude_args() {
    local args=()
    for p in "${EXCLUDE_PATTERNS[@]}"; do
        args+=(--exclude="$p")
    done
    printf '%s\n' "${args[@]}"
}

# ==============================================================================
# AUTENTICACIÓN RCLONE — TÚNEL SSH
# ==============================================================================

_auth_via_tunnel() {
    local shared_flags=("$@")
    local SRV_PORT=53682
    local CLI_PORT=53682
    local AUTH_TMP="/tmp/rclone_auth_output_$$"

    # Detectar IP del cliente SSH y del servidor
    local CLIENT_IP
    CLIENT_IP="$(echo "${SSH_CLIENT:-}" | awk '{print $1}')"
    local SRV_IP
    SRV_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

    # Verificar que el puerto no esté ocupado; si lo está, buscar uno libre
    while ss -tlnp 2>/dev/null | grep -q ":${SRV_PORT} "; do
        SRV_PORT=$(( SRV_PORT + 1 ))
        CLI_PORT=$SRV_PORT
    done

    blank
    printf "  ${C_BOLD}${C_CYAN}AUTENTICACIÓN REMOTA — TÚNEL SSH${C_RESET}\n"
    hr

    # Lanzar rclone authorize capturando stdout+stderr
    info "Iniciando servidor de autorización en puerto ${SRV_PORT}..."
    rclone authorize "drive" \
        --auth-no-open-browser \
        >"$AUTH_TMP" 2>&1 &
    local RCLONE_PID=$!

    register_rollback \
        "Detener servidor rclone de autorización (PID ${RCLONE_PID})" \
        "kill ${RCLONE_PID} 2>/dev/null || true; rm -f '${AUTH_TMP}'"

    # Esperar hasta 15s a que rclone imprima el enlace
    local AUTH_URL=""
    local waited=0
    while [[ -z "$AUTH_URL" && $waited -lt 15 ]]; do
        sleep 1
        AUTH_URL="$(grep -oP 'http://127\.0\.0\.1:\d+/auth[^\s]*' "$AUTH_TMP" 2>/dev/null | head -1 || true)"
        (( waited++ ))
    done

    if [[ -z "$AUTH_URL" ]]; then
        kill "$RCLONE_PID" 2>/dev/null || true
        rm -f "$AUTH_TMP"
        err_ui "No se pudo obtener el enlace de autorización de rclone."
        err_ui "Verifica que rclone esté instalado y que el puerto ${SRV_PORT} esté libre."
        return 1
    fi

    # Extraer puerto real que rclone eligió
    local RCLONE_PORT
    RCLONE_PORT="$(echo "$AUTH_URL" | grep -oP ':\d+/' | tr -d ':/')"

    # Construir URL del túnel
    local TUNNEL_URL
    TUNNEL_URL="$(echo "$AUTH_URL" | sed "s/:${RCLONE_PORT}\//:${CLI_PORT}\//")"

    # Mostrar instrucciones
    blank
    printf "  ${C_BOLD}${C_WHITE}Sigue estos 2 pasos desde tu PC:${C_RESET}\n"
    blank

    printf "  ${C_BOLD}${C_YELLOW}PASO 1${C_RESET} — Abre un túnel SSH en tu PC local\n"
    hr
    info "Abre una terminal NUEVA en tu PC y ejecuta este comando:"
    blank
    local _srv_user; _srv_user="$(whoami)"
    if [[ -n "$CLIENT_IP" && -n "$SRV_IP" ]]; then
        printf "      ${C_CYAN}ssh -N -L %s:127.0.0.1:%s %s@%s${C_RESET}\n" \
            "$CLI_PORT" "$RCLONE_PORT" "$_srv_user" "$SRV_IP"
    else
        printf "      ${C_CYAN}ssh -N -L %s:127.0.0.1:%s %s@<IP_DEL_SERVIDOR>${C_RESET}\n" \
            "$CLI_PORT" "$RCLONE_PORT" "$_srv_user"
        [[ -n "$SRV_IP" ]] && warn_ui "IP del servidor: ${SRV_IP}"
    fi
    blank
    info "Deja esa terminal abierta. El comando no muestra nada — eso es normal."
    blank

    printf "  ${C_BOLD}${C_YELLOW}PASO 2${C_RESET} — Abre el enlace en tu navegador\n"
    hr
    info "Con el túnel activo, abre este enlace en tu navegador:"
    blank
    printf "      ${C_BOLD}${C_GREEN}%s${C_RESET}\n" "$TUNNEL_URL"
    blank
    info "Elige tu cuenta de Google y acepta los permisos."
    info "Cuando el navegador muestre 'Success', vuelve aquí."
    blank
    hr

    ask "¿Ya autorizaste en el navegador? Presiona Enter para continuar..."
    read -r

    # Esperar que rclone termine de escribir el token (máx 20s)
    info "Capturando token de autorización..."
    local wait_exit=0
    while kill -0 "$RCLONE_PID" 2>/dev/null && [[ $wait_exit -lt 20 ]]; do
        sleep 1; (( wait_exit++ ))
    done
    kill "$RCLONE_PID" 2>/dev/null || true

    # Extraer token: rclone lo escribe entre "--->" y "<---End paste"
    local TOKEN=""
    TOKEN="$(awk '/Paste the following/{found=1; next} /End paste/{found=0} found' \
        "$AUTH_TMP" 2>/dev/null | tr -d '[:space:]')"

    # Fallback: buscar JSON con access_token en todo el archivo
    if [[ -z "$TOKEN" ]]; then
        TOKEN="$(grep -oP '\{[^{}]*"access_token"[^{}]*\}' "$AUTH_TMP" 2>/dev/null | tail -1 || true)"
    fi

    rm -f "$AUTH_TMP"

    if [[ -z "$TOKEN" ]]; then
        err_ui "No se recibió el token. ¿Completaste la autorización en el navegador?"
        err_ui "Vuelve a intentarlo con la opción 8 del menú."
        return 1
    fi

    # Crear el remote con el token obtenido
    info "Configurando remote '${RCLONE_REMOTE}' con el token obtenido..."
    rclone config create "$RCLONE_REMOTE" drive \
        scope=drive \
        token="$TOKEN" \
        "${shared_flags[@]}" || {
        err_ui "Fallo al crear la configuración de rclone"
        return 1
    }

    blank
    ok "¡Google Drive autorizado y configurado correctamente!"
    info "Ya puedes cerrar la terminal del túnel SSH en tu PC."
    blank
}

# ==============================================================================
# ACCIONES CON ROLLBACK REGISTRADO
# ==============================================================================

action_init_remote_repo() {
    local repo="$1"

    # 'cat config' es más confiable que 'snapshots': devuelve 0 para repos válidos (incluso vacíos)
    if restic -r "$repo" cat config &>/dev/null; then
        return 0  # repositorio ya inicializado y accesible
    fi

    # Verificar conectividad con Drive antes de intentar init
    if ! rclone lsd "${RCLONE_REMOTE}:" &>/dev/null; then
        err_ui "No se puede conectar a Google Drive. Verifica las credenciales (opción 8)."
        loge "Sin acceso a Drive al intentar init remoto"
        return 1
    fi

    # Comprobar si la carpeta ya existe en Drive para no crear duplicados
    if rclone lsf "${RCLONE_REMOTE}:${DRIVE_PATH}" --max-depth 1 &>/dev/null 2>&1; then
        err_ui "La carpeta '${DRIVE_PATH}' ya existe en Drive pero no responde como repo Restic."
        err_ui "Posibles causas: contraseña incorrecta, repo corrupto, o carpeta vacía huérfana."
        err_ui "Revisa drive.google.com y elimina la carpeta vacía si la ves duplicada."
        loge "Carpeta ${DRIVE_PATH} existe en Drive pero no es un repo restic válido"
        return 1
    fi

    info "Inicializando repositorio remoto en ${RCLONE_REMOTE}:${DRIVE_PATH}..."
    restic -r "$repo" init >> "$LOG_FILE" 2>> "$ERROR_LOG" || {
        loge "Fallo al inicializar repo remoto"
        return 1
    }
    register_rollback \
        "Eliminar repositorio remoto recién inicializado" \
        "rclone purge '${RCLONE_REMOTE}:${DRIVE_PATH}' 2>/dev/null || true"
    ok "Repositorio remoto inicializado en ${RCLONE_REMOTE}:${DRIVE_PATH}"
}

action_init_local_repo() {
    local repo="$1"
    local created_dir=false
    if [[ ! -d "$repo" ]]; then
        mkdir -p "$repo"
        created_dir=true
    fi
    if ! restic -r "$repo" snapshots &>/dev/null; then
        info "Inicializando repositorio local..."
        restic -r "$repo" init >> "$LOG_FILE" 2>> "$ERROR_LOG" || {
            loge "Fallo al inicializar repo local"
            [[ "$created_dir" == "true" ]] && rm -rf "$repo"
            return 1
        }
        register_rollback \
            "Limpiar repositorio local inicializado: $repo" \
            "rm -rf '${repo}'"
        ok "Repositorio local inicializado"
    fi
}

action_setup_rclone() {
    local rclone_conf_user="${HOME}/.config/rclone/rclone.conf"
    local rclone_conf_root="/root/.config/rclone/rclone.conf"
    local conf_existed=false
    [[ -f "$rclone_conf_user" ]] && conf_existed=true

    if rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:"; then
        if rclone lsd "${RCLONE_REMOTE}:" &>/dev/null; then
            ok "rclone '${RCLONE_REMOTE}' ya configurado y verificado"
            return 0
        fi
        warn_ui "Remote '${RCLONE_REMOTE}' existe pero no responde. Reautenticando..."
    fi

    info "Configurando rclone para '${RCLONE_REMOTE}'..."

    local shared_flags=()
    # Solo configurar team_drive cuando hay un ID real (shared_with_me es otra cosa)
    [[ -n "${TEAM_DRIVE_ID:-}" ]] && shared_flags+=(team_drive="$TEAM_DRIVE_ID")

    if has_display; then
        info "Entorno gráfico → abriendo navegador para autorizar..."
        rclone config create "$RCLONE_REMOTE" drive scope=drive "${shared_flags[@]}" || return 1
    else
        _auth_via_tunnel "${shared_flags[@]}" || return 1
    fi

    if [[ "$conf_existed" == "false" ]]; then
        register_rollback \
            "Eliminar configuración rclone recién creada" \
            "rclone config delete '${RCLONE_REMOTE}' 2>/dev/null || true"
    fi

    # Copiar config a root si se ejecuta como usuario normal
    if [[ $EUID -ne 0 ]] && [[ -f "$rclone_conf_user" ]]; then
        install -D -m 600 "$rclone_conf_user" "$rclone_conf_root" 2>/dev/null || true
        register_rollback \
            "Eliminar copia de rclone.conf en root" \
            "rm -f '${rclone_conf_root}'"
    fi

    ok "rclone configurado correctamente"
}

action_run_backup() {
    local repo="$1"; local label="$2"
    local -a excl_args
    mapfile -t excl_args < <(build_exclude_args)

    local snaps_before
    snaps_before="$(count_snapshots "$repo")"

    _BACKUP_STARTED=true
    info "Ejecutando backup en ${label}..."

    local tmp_out; tmp_out="$(mktemp)"

    restic -r "$repo" backup \
        "${BACKUP_DIRS[@]}" "${excl_args[@]}" \
        --json 2>> "$ERROR_LOG" > "$tmp_out"
    local _rc=$?

    # Códigos de salida de restic:
    #   0 = éxito total
    #   1 = error fatal (repositorio inaccesible, contraseña incorrecta, etc.)
    #   3 = backup creado pero algunos archivos no se pudieron leer (permisos)
    if [[ $_rc -eq 0 || $_rc -eq 3 ]]; then

        python3 - "$tmp_out" 2>/dev/null <<'PYEOF' || true
import sys, json
try:
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                if d.get("message_type") == "summary":
                    new  = d.get("files_new", 0)
                    chg  = d.get("files_changed", 0)
                    mb   = d.get("total_bytes_processed", 0) // 1024 // 1024
                    snap = d.get("snapshot_id", "?")[:8]
                    print(f"     Snapshot: {snap} | Nuevos: {new} | Cambiados: {chg} | Total: {mb} MB")
            except: pass
except: pass
PYEOF
        rm -f "$tmp_out"

        if [[ $_rc -eq 3 ]]; then
            logw "Backup en $label con advertencias: algunos archivos no se pudieron leer (permisos insuficientes)"
            warn_ui "Backup completado con advertencias — algunos archivos del sistema no se leyeron."
            warn_ui "Para un backup completo de /etc ejecuta el script con: sudo bash backup-restic.sh"
        else
            log "Backup exitoso en $label (snapshots previos: $snaps_before)"
        fi

        if [[ "$snaps_before" -gt 0 ]]; then
            register_rollback \
                "Olvidar snapshot recién creado en $label" \
                "restic -r '${repo}' forget --keep-last '${snaps_before}' --prune 2>/dev/null || true"
        fi
        return 0
    else
        rm -f "$tmp_out"
        loge "Fallo en backup $label (exit code: $_rc)"
        return 1
    fi
}

action_apply_retention() {
    local repo="$1"; local label="$2"
    [[ "${ENABLE_RETENTION:-false}" != "true" ]] && return 0

    local args=()
    [[ ${KEEP_LAST:-0}    -gt 0 ]] && args+=(--keep-last    "$KEEP_LAST")
    [[ ${KEEP_DAILY:-0}   -gt 0 ]] && args+=(--keep-daily   "$KEEP_DAILY")
    [[ ${KEEP_WEEKLY:-0}  -gt 0 ]] && args+=(--keep-weekly  "$KEEP_WEEKLY")
    [[ ${KEEP_MONTHLY:-0} -gt 0 ]] && args+=(--keep-monthly "$KEEP_MONTHLY")
    [[ ${#args[@]} -eq 0 ]] && return 0

    info "Aplicando política de retención en ${label}..."
    restic -r "$repo" forget "${args[@]}" --prune >> "$LOG_FILE" 2>> "$ERROR_LOG" && \
        ok "Retención aplicada" || warn_ui "Retención falló (backup guardado igualmente)"
}

# ==============================================================================
# OPCIONES DEL MENÚ
# ==============================================================================

menu_status() {
    title "Estado del sistema de backups"
    local inet="NO"; has_internet && inet="SÍ"
    local gui="NO";  has_display  && gui="SÍ"
    local rclone_ok="NO"
    rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:" && \
        rclone lsd "${RCLONE_REMOTE}:" &>/dev/null 2>&1 && rclone_ok="SÍ"

    printf "  %-30s ${C_BOLD}%s${C_RESET}\n" "Internet disponible:"   "$inet"
    printf "  %-30s ${C_BOLD}%s${C_RESET}\n" "Entorno gráfico:"        "$gui"
    printf "  %-30s ${C_BOLD}%s${C_RESET}\n" "rclone configurado:"     "$rclone_ok"
    blank

    if [[ -d "$LOCAL_REPO" ]]; then
        local n; n="$(count_snapshots "$LOCAL_REPO")"
        local sz; sz="$(du -sh "$LOCAL_REPO" 2>/dev/null | cut -f1)"
        printf "  %-30s ${C_BOLD}%s${C_RESET} (%s en disco)\n" "Snapshots locales:" "$n" "$sz"
    else
        printf "  %-30s %s\n" "Snapshots locales:" "Sin repositorio"
    fi

    if [[ "$rclone_ok" == "SÍ" ]]; then
        local remote; remote="$(build_remote_repo)"
        local nr; nr="$(count_snapshots "$remote" 2>/dev/null || printf "?")"
        printf "  %-30s ${C_BOLD}%s${C_RESET}\n" "Snapshots en Drive:" "$nr"
    fi

    if [[ -f "$LOG_FILE" ]]; then
        local last; last="$(grep 'Backup exitoso' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d' ' -f1-2)"
        [[ -n "$last" ]] && printf "  %-30s ${C_BOLD}%s${C_RESET}\n" "Último backup exitoso:" "$last"
    fi
    blank
}

menu_run_backup() {
    title "Ejecutar backup ahora"
    ask "¿Confirmar backup manual? (s/N):"
    read -r ans
    [[ "${ans,,}" != "s" ]] && { info "Cancelado."; return; }
    _ROLLBACK_STACK=()
    _ROLLBACK_ACTIVE=false
    _BACKUP_STARTED=false
    do_backup
}

menu_list_snapshots() {
    title "Listar snapshots disponibles"
    opt 1 "Snapshots locales"
    opt 2 "Snapshots en Google Drive"
    opt 3 "Ambos"
    ask "Opción:"
    read -r opt_val
    case "$opt_val" in
        1|3)
            if [[ -d "$LOCAL_REPO" ]]; then
                blank; info "── Repositorio local ──"
                restic -r "$LOCAL_REPO" snapshots 2>/dev/null || err_ui "No se pudo leer repo local"
            else
                warn_ui "No existe repositorio local"
            fi
            ;;&
        2|3)
            blank; info "── Repositorio Google Drive ──"
            local remote; remote="$(build_remote_repo)"
            restic -r "$remote" snapshots 2>/dev/null || err_ui "No se pudo leer repo remoto (¿está configurado?)"
            ;;
        *) warn_ui "Opción inválida" ;;
    esac
}

menu_reconfigure_drive() {
    title "Reconfigurar Google Drive"
    warn_ui "Esto eliminará la configuración actual de rclone para '${RCLONE_REMOTE}'"
    ask "¿Continuar? (s/N):"
    read -r ans
    [[ "${ans,,}" != "s" ]] && { info "Cancelado."; return; }
    rclone config delete "$RCLONE_REMOTE" 2>/dev/null && \
        ok "Configuración anterior eliminada" || \
        warn_ui "No había configuración previa"
    _ROLLBACK_STACK=(); _ROLLBACK_ACTIVE=false
    action_setup_rclone && ok "Google Drive reconfigurado"
}

menu_remove_drive_config() {
    title "Desconectar Google Drive"
    warn_ui "Se eliminará el remote '${RCLONE_REMOTE}' de rclone."
    warn_ui "Los archivos en Drive NO se borran — solo se desconecta la cuenta."
    ask "¿Confirmar? (s/N):"
    read -r ans
    [[ "${ans,,}" != "s" ]] && { info "Cancelado."; return; }

    rclone config delete "$RCLONE_REMOTE" 2>/dev/null && \
        ok "Remote '${RCLONE_REMOTE}' eliminado de rclone" || \
        err_ui "No se encontró el remote"

    local root_conf="/root/.config/rclone/rclone.conf"
    if [[ -f "$root_conf" ]]; then
        RCLONE_CONFIG="$root_conf" rclone config delete "$RCLONE_REMOTE" 2>/dev/null || true
        ok "Configuración root limpiada también"
    fi
}

menu_purge_drive_repo() {
    title "Eliminar repositorio de backups en Drive"
    warn_ui "¡ATENCIÓN! Esto borrará PERMANENTEMENTE todos los backups"
    warn_ui "ubicados en:  ${RCLONE_REMOTE}:${DRIVE_PATH}"
    blank
    ask "Escribe CONFIRMAR para continuar (cualquier otra cosa cancela):"
    read -r ans
    [[ "$ans" != "CONFIRMAR" ]] && { info "Cancelado."; return; }

    info "Eliminando ${RCLONE_REMOTE}:${DRIVE_PATH}..."
    rclone purge "${RCLONE_REMOTE}:${DRIVE_PATH}" && \
        ok "Repositorio remoto eliminado" || \
        err_ui "Falló la eliminación (verifica permisos en Drive)"
}

menu_purge_local_repo() {
    title "Eliminar repositorio local de backups"
    warn_ui "Se eliminará permanentemente:  $LOCAL_REPO"
    ask "¿Confirmar? (s/N):"
    read -r ans
    [[ "${ans,,}" != "s" ]] && { info "Cancelado."; return; }
    rm -rf "$LOCAL_REPO" && \
        ok "Repositorio local eliminado" || \
        err_ui "No se pudo eliminar $LOCAL_REPO"
}

menu_forget_snapshots() {
    title "Eliminar snapshot específico"
    opt 1 "Del repositorio local"
    opt 2 "Del repositorio remoto (Drive)"
    ask "Opción:"
    read -r opt_val

    local repo
    case "$opt_val" in
        1) repo="$LOCAL_REPO" ;;
        2) repo="$(build_remote_repo)" ;;
        *) warn_ui "Opción inválida"; return ;;
    esac

    blank
    restic -r "$repo" snapshots 2>/dev/null || { err_ui "No se pudo listar snapshots"; return; }
    blank
    ask "ID del snapshot a eliminar (8 chars, ej: abc123de) o 'latest':"
    read -r snap_id
    [[ -z "$snap_id" ]] && { info "Cancelado."; return; }

    ask "¿Confirmar eliminación de snapshot '$snap_id'? (s/N):"
    read -r ans
    [[ "${ans,,}" != "s" ]] && { info "Cancelado."; return; }

    restic -r "$repo" forget "$snap_id" --prune && \
        ok "Snapshot $snap_id eliminado" || \
        err_ui "No se pudo eliminar el snapshot"
}

menu_verify_integrity() {
    title "Verificar integridad de repositorios"
    opt 1 "Verificar repositorio local"
    opt 2 "Verificar repositorio remoto (Drive)"
    opt 3 "Ambos"
    ask "Opción:"
    read -r opt_val

    local check_local=false check_remote=false
    [[ "$opt_val" == "1" || "$opt_val" == "3" ]] && check_local=true
    [[ "$opt_val" == "2" || "$opt_val" == "3" ]] && check_remote=true

    if $check_local; then
        blank; info "Verificando repositorio local (puede tardar varios minutos)..."
        restic -r "$LOCAL_REPO" check && ok "Local: sin errores" || err_ui "Local: ERRORES ENCONTRADOS"
    fi
    if $check_remote; then
        blank; info "Verificando repositorio remoto (puede tardar varios minutos)..."
        local remote; remote="$(build_remote_repo)"
        restic -r "$remote" check && ok "Drive: sin errores" || err_ui "Drive: ERRORES ENCONTRADOS"
    fi
}

menu_show_logs() {
    title "Ver logs del sistema"
    opt 1 "Log de backups        ($LOG_FILE)"
    opt 2 "Log de errores        ($ERROR_LOG)"
    opt 3 "Log de sincronización ($SYNC_LOG)"
    opt 4 "Log de cron           (${LOG_DIR}/cron.log)"
    opt 5 "Log de restauración   ($RESTORE_LOG)"
    ask "Opción:"
    read -r opt_val

    local f
    case "$opt_val" in
        1) f="$LOG_FILE" ;;
        2) f="$ERROR_LOG" ;;
        3) f="$SYNC_LOG" ;;
        4) f="${LOG_DIR}/cron.log" ;;
        5) f="$RESTORE_LOG" ;;
        *) warn_ui "Opción inválida"; return ;;
    esac

    if [[ -f "$f" ]]; then
        blank
        if command -v less &>/dev/null; then
            info "Navegación: flechas ↑↓, G=final, g=inicio, /=buscar, q=salir"
            blank
            less -R +G "$f"
        else
            hr; tail -60 "$f"; hr
            info "(Instala 'less' para navegación interactiva)"
        fi
    else
        warn_ui "Log no encontrado: $f"
    fi
}

menu_cron_manage() {
    title "Gestionar automatización (cron)"
    opt 1 "Ver tareas cron actuales de este sistema"
    opt 2 "Instalar tareas cron recomendadas"
    opt 3 "Eliminar tareas cron de este sistema"
    ask "Opción:"
    read -r opt_val

    local marker="# BACKUP-RESTIC-MANAGED"

    case "$opt_val" in
        1)
            blank
            crontab -l 2>/dev/null | grep -A1 "$marker" || \
                info "No hay tareas cron instaladas para este sistema"
            ;;
        2)
            blank
            printf "  ${C_BOLD}Tareas recomendadas:${C_RESET}\n"
            blank
            printf "  ${C_DIM}  [Backup]   Día 1 de cada mes a las 3:00 AM${C_RESET}\n"
            printf "  ${C_DIM}  [Sync]     Sincronización a Drive cada 6 horas${C_RESET}\n"
            printf "  ${C_DIM}  [Limpieza] Logs viejos — día 1 de cada mes${C_RESET}\n"
            blank

            # --- Frecuencia de backup ---
            printf "  ${C_BOLD}Frecuencia de backup${C_RESET}\n"
            opt 1 "Mensual  — día 1 de cada mes a las 3:00 AM  [recomendado]"
            opt 2 "Semanal  — todos los domingos a las 3:00 AM"
            opt 3 "Diario   — todos los días a las 3:00 AM"
            ask "Elige frecuencia de backup [1]:"
            read -r _bk_freq
            case "${_bk_freq:-1}" in
                2) _bk_cron="0 3 * * 0" ;  _bk_label="semanal (domingos 3:00 AM)" ;;
                3) _bk_cron="0 3 * * *" ;  _bk_label="diario (3:00 AM)" ;;
                *) _bk_cron="0 3 1 * *" ;  _bk_label="mensual (día 1, 3:00 AM)" ;;
            esac
            blank

            # --- Frecuencia de sincronización ---
            printf "  ${C_BOLD}Frecuencia de sincronización a Drive${C_RESET}\n"
            opt 1 "Cada 2 horas"
            opt 2 "Cada 4 horas"
            opt 3 "Cada 6 horas  [recomendado]"
            opt 4 "Cada 12 horas"
            opt 5 "Una vez al día (medianoche)"
            ask "Elige frecuencia de sync [3]:"
            read -r _sync_freq
            case "${_sync_freq:-3}" in
                1) _sync_cron="0 */2 * * *"  ; _sync_label="cada 2 horas" ;;
                2) _sync_cron="0 */4 * * *"  ; _sync_label="cada 4 horas" ;;
                4) _sync_cron="0 */12 * * *" ; _sync_label="cada 12 horas" ;;
                5) _sync_cron="0 0 * * *"    ; _sync_label="una vez al día (medianoche)" ;;
                *) _sync_cron="0 */6 * * *"  ; _sync_label="cada 6 horas" ;;
            esac
            blank

            # --- Confirmación ---
            printf "  ${C_BOLD}Se instalarán las siguientes tareas:${C_RESET}\n"
            blank
            info "  Backup       → ${_bk_label}"
            info "  Sync a Drive → ${_sync_label}"
            info "  Limpieza     → día 1 de cada mes"
            blank
            ask "¿Confirmar instalación? (S/n):"
            read -r _confirm
            [[ "${_confirm,,}" == "n" ]] && { info "Cancelado"; break; }
            blank

            local tmp; tmp="$(mktemp)"
            local _cron_user=""
            if [[ $EUID -eq 0 ]]; then
                _cron_user=""
            elif sudo -n crontab -l &>/dev/null 2>&1; then
                _cron_user="sudo"
            fi

            if [[ -n "$_cron_user" ]]; then
                sudo crontab -l 2>/dev/null | grep -v "$marker" | grep -v 'backup-restic\|sync-to-drive' > "$tmp" || true
            else
                crontab -l 2>/dev/null | grep -v "$marker" | grep -v 'backup-restic\|sync-to-drive' > "$tmp" || true
            fi

            cat >> "$tmp" <<EOF
${marker}
${_bk_cron} bash ${SCRIPT_DIR}/backup-restic.sh --backup >> ${LOG_DIR}/cron.log 2>&1
${_sync_cron} bash ${SCRIPT_DIR}/sync-to-drive.sh >> ${LOG_DIR}/cron.log 2>&1
0 0 1 * * find ${LOG_DIR} -name "*.log" -mtime +30 -delete
EOF
            if [[ -n "$_cron_user" ]]; then
                sudo crontab "$tmp"
                ok "Tareas cron instaladas en crontab de ROOT (acceso completo al sistema)"
            else
                crontab "$tmp"
                warn_ui "Tareas instaladas en crontab de usuario — algunos archivos del sistema podrían no ser accesibles"
                warn_ui "Para backup completo ejecuta este script con sudo e instala el cron de nuevo"
            fi
            rm -f "$tmp"
            blank
            ok "Backup       → ${_bk_label}"
            ok "Sync a Drive → ${_sync_label}"
            ok "Limpieza     → día 1 de cada mes"
            ;;
        3)
            local tmp; tmp="$(mktemp)"
            for _ct in "crontab" "sudo crontab"; do
                $_ct -l 2>/dev/null | grep -v "$marker" | grep -v 'backup-restic\|sync-to-drive' > "$tmp" || true
                $_ct "$tmp" 2>/dev/null || true
            done
            rm -f "$tmp"
            ok "Tareas cron eliminadas (usuario y root)"
            ;;
        *) warn_ui "Opción inválida" ;;
    esac
}

menu_restore() {
    title "Restaurar archivos desde backup"
    opt 1 "Desde repositorio local"
    opt 2 "Desde Google Drive"
    ask "Origen:"
    read -r repo_opt

    local repo
    case "$repo_opt" in
        1) repo="$LOCAL_REPO" ;;
        2) repo="$(build_remote_repo)" ;;
        *) warn_ui "Opción inválida"; return ;;
    esac

    blank
    info "Snapshots disponibles:"
    restic -r "$repo" snapshots 2>/dev/null || { err_ui "No se pudo listar snapshots del repositorio"; return; }
    blank

    ask "ID del snapshot a restaurar (8+ chars) o 'latest':"
    read -r snap_id
    [[ -z "$snap_id" ]] && { info "Cancelado."; return; }

    blank
    info "Puedes restaurar solo un archivo/carpeta específico, o todo el snapshot."
    ask "Ruta a restaurar (ej: /etc/nginx) — Enter para restaurar TODO:"
    read -r restore_include
    # Ignorar "TODO" y cadenas vacías — ambas significan restaurar el snapshot completo
    [[ "$restore_include" == "TODO" || "$restore_include" == "todo" ]] && restore_include=""

    blank
    printf "  ${C_DIM}  Destino sugerido: / para restaurar en su lugar original${C_RESET}\n"
    ask "Directorio destino [/]:"
    read -r target_dir
    target_dir="${target_dir:-/}"

    if [[ "$target_dir" == "/" ]]; then
        blank
        warn_ui "Vas a restaurar DIRECTAMENTE sobre el sistema de archivos raíz."
        warn_ui "Los archivos existentes serán SOBREESCRITOS sin posibilidad de deshacer."
        ask "Escribe 'CONFIRMO' para continuar:"
        read -r confirm_root
        [[ "$confirm_root" != "CONFIRMO" ]] && { info "Cancelado."; return; }
    fi

    blank
    warn_ui "Se restaurará snapshot '$snap_id' en: $target_dir"
    if [[ -n "$restore_include" ]]; then
        info "Solo se restaurará: $restore_include"
    else
        info "Se restaurará el snapshot completo"
    fi
    ask "¿Confirmar restauración? (s/N):"
    read -r ans
    [[ "${ans,,}" != "s" ]] && { info "Cancelado."; return; }

    [[ "$target_dir" != "/" ]] && \
        { mkdir -p "$target_dir" 2>/dev/null || { err_ui "No se pudo crear el directorio destino"; return; }; }

    local -a restore_args=("-r" "$repo" "restore" "$snap_id" "--target" "$target_dir")
    [[ -n "$restore_include" ]] && restore_args+=("--include" "$restore_include")

    blank
    info "Restaurando — esto puede tardar varios minutos..."
    if restic "${restore_args[@]}" 2>&1 | tee -a "$RESTORE_LOG"; then
        ok "Restauración completada en: $target_dir"
        log "Restauración exitosa: snapshot=$snap_id destino=$target_dir"
    else
        err_ui "La restauración falló. Revisa el log: $RESTORE_LOG"
        loge "Restauración falló: snapshot=$snap_id destino=$target_dir"
    fi
}

menu_sync_now() {
    title "Sincronizar backups locales a Google Drive"

    if [[ ! -d "$LOCAL_REPO" ]]; then
        warn_ui "No existe repositorio local en $LOCAL_REPO"
        info "Haz un backup primero (opción 1) para tener algo que sincronizar."
        return
    fi

    ask "¿Ejecutar sincronización ahora? (s/N):"
    read -r ans
    [[ "${ans,,}" != "s" ]] && { info "Cancelado."; return; }

    blank
    info "Ejecutando sync-to-drive.sh..."
    if bash "${SCRIPT_DIR}/sync-to-drive.sh"; then
        ok "Sincronización completada"
    else
        err_ui "La sincronización falló. Revisa: $SYNC_LOG"
    fi
}

menu_change_password() {
    title "Cambiar contraseña del repositorio Restic"
    blank
    opt 1 "Cambiar en repositorio local"
    opt 2 "Cambiar en repositorio remoto (Drive)"
    opt 3 "Cambiar en ambos"
    ask "Opción:"
    read -r opt_val
    blank

    # Determinar qué repos se van a modificar
    local do_local=false do_remote=false
    case "$opt_val" in
        1) do_local=true ;;
        2) do_remote=true ;;
        3) do_local=true; do_remote=true ;;
        *) warn_ui "Opción inválida"; return ;;
    esac

    # Verificar existencia de repos antes de pedir contraseñas
    if $do_local && [[ ! -d "$LOCAL_REPO" ]]; then
        err_ui "No existe repositorio local en $LOCAL_REPO"
        err_ui "Haz un backup primero (opción 1) para crearlo."
        $do_remote || return
        do_local=false
    fi
    if $do_remote; then
        local _remote; _remote="$(build_remote_repo)"
        if ! restic -r "$_remote" cat config &>/dev/null; then
            err_ui "No se encontró repositorio remoto en $_remote"
            err_ui "Verifica la conexión a Drive o haz un backup primero."
            $do_local || return
            do_remote=false
        fi
    fi

    # Pedir contraseña ACTUAL (para verificar acceso)
    info "restic necesita tu contraseña ACTUAL para autenticarse."
    info "Si no coincide con la del repositorio, el cambio fallará."
    blank
    printf "  ${C_BLUE}?${C_RESET}  Contraseña ACTUAL del repositorio (no se muestra): "
    read -rs cur_pass; printf "\n"
    [[ -z "$cur_pass" ]] && { info "Cancelado."; return; }

    # Verificar que la contraseña actual es correcta en al menos un repo
    local _verified=false
    if $do_local && RESTIC_PASSWORD="$cur_pass" restic -r "$LOCAL_REPO" cat config &>/dev/null; then
        _verified=true
    elif $do_remote && RESTIC_PASSWORD="$cur_pass" restic -r "$(build_remote_repo)" cat config &>/dev/null; then
        _verified=true
    fi
    if [[ "$_verified" == "false" ]]; then
        err_ui "La contraseña actual es incorrecta para los repositorios seleccionados."
        err_ui "Verifica que RESTIC_PASSWORD en backup.conf sea la contraseña correcta,"
        err_ui "o introdúcela manualmente cuando se te pida."
        return
    fi

    # Pedir nueva contraseña
    blank
    printf "  ${C_BLUE}?${C_RESET}  Nueva contraseña (no se muestra): "
    read -rs new_pass; printf "\n"
    [[ -z "$new_pass" ]] && { info "Cancelado."; return; }
    printf "  ${C_BLUE}?${C_RESET}  Repite la nueva contraseña: "
    read -rs new_pass2; printf "\n"

    [[ "$new_pass" != "$new_pass2" ]] && { err_ui "Las contraseñas no coinciden — no se cambió nada"; return; }
    [[ "$new_pass" == "$cur_pass" ]]  && { warn_ui "La nueva contraseña es igual a la actual — no hay nada que cambiar"; return; }

    # Archivos temporales para contraseñas (--password-file y --new-password-file)
    local _tmp_cur _tmp_new
    _tmp_cur="$(mktemp)"; _tmp_new="$(mktemp)"
    printf '%s' "$cur_pass" > "$_tmp_cur";  chmod 600 "$_tmp_cur"
    printf '%s' "$new_pass" > "$_tmp_new";  chmod 600 "$_tmp_new"

    _change_in_repo() {
        local repo="$1"; local label="$2"
        info "Cambiando contraseña en $label..."
        if restic -r "$repo" \
                --password-file "$_tmp_cur" \
                key passwd \
                --new-password-file "$_tmp_new"; then
            ok "Contraseña cambiada en $label"
            return 0
        else
            err_ui "Fallo al cambiar la contraseña en $label"
            return 1
        fi
    }

    local _any_ok=false
    $do_local  && _change_in_repo "$LOCAL_REPO"          "local" && _any_ok=true
    $do_remote && _change_in_repo "$(build_remote_repo)" "Drive" && _any_ok=true

    rm -f "$_tmp_cur" "$_tmp_new"

    if [[ "$_any_ok" == "true" ]]; then
        blank
        warn_ui "Ahora actualiza la contraseña en backup.conf (opción 13 → 2)."
        warn_ui "Si no la actualizas, los próximos backups fallarán."
    fi
}

# ==============================================================================
# ASISTENTE DE CONFIGURACIÓN
# ==============================================================================

# Escribe o actualiza una variable en backup.conf
_conf_set() {
    local key="$1"
    local val="$2"
    # Implementación pura bash — no usa sed para evitar fallos con caracteres especiales
    if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        local tmp; tmp="$(mktemp)"
        while IFS= read -r _line || [[ -n "$_line" ]]; do
            if [[ "$_line" =~ ^${key}= ]]; then
                printf '%s="%s"\n' "$key" "$val"
            else
                printf '%s\n' "$_line"
            fi
        done < "$CONFIG_FILE" > "$tmp"
        mv "$tmp" "$CONFIG_FILE"
    else
        printf '%s="%s"\n' "$key" "$val" >> "$CONFIG_FILE"
    fi
}

# Escribe un array bash en backup.conf
_conf_set_array() {
    local key="$1"; shift
    local items=("$@")
    local block="${key}=(\n"
    for item in "${items[@]}"; do
        block+="    \"${item}\"\n"
    done
    block+=")"
    # Eliminar el bloque anterior (puede ser multilínea)
    perl -i -0pe "s|^${key}=\(.*?\)[\r\n]*||sm" "$CONFIG_FILE" 2>/dev/null || \
        sed -i "/^${key}=(/,/^)/d" "$CONFIG_FILE"
    printf "%b\n" "$block" >> "$CONFIG_FILE"
}

# Lee valor actual de una variable del conf
_conf_get() {
    local _line _val
    _line="$(grep -E "^${1}=" "$CONFIG_FILE" 2>/dev/null | head -1)" || true
    _val="${_line#*=}"   # eliminar KEY=
    _val="${_val#\"}"    # eliminar comilla inicial si existe
    _val="${_val%\"}"    # eliminar comilla final si existe
    printf '%s' "$_val"
}

# Prompt con valor actual y permite dejarlo igual presionando Enter.
# IMPORTANTE: todos los printf van a stderr (>&2) para que sean visibles
# incluso cuando la función se llama dentro de var="$(...)"
_ask_val() {
    local label="$1"
    local current="$2"
    local result
    printf "  ${C_BLUE}?${C_RESET}  %s\n"                                 "$label"            >&2
    printf "      ${C_DIM}Actual: %s${C_RESET}\n"                         "${current:-(vacío)}" >&2
    printf "      ${C_DIM}Nuevo valor (Enter para conservar actual):${C_RESET} "               >&2
    read -r result
    if [[ -z "$result" ]]; then
        printf '%s' "$current"
    else
        printf '%s' "$result"
    fi
}

_ask_bool() {
    local label="$1"
    local current="$2"
    local result
    while true; do
        printf "  ${C_BLUE}?${C_RESET}  %s\n"                                            "$label"   >&2
        printf "      ${C_DIM}Actual: %s — Escribe true/false (Enter conserva):${C_RESET} " "$current" >&2
        read -r result
        [[ -z "$result" ]] && { printf '%s' "$current"; return; }
        [[ "$result" == "true" || "$result" == "false" ]] && { printf '%s' "$result"; return; }
        printf "  ${C_YELLOW}⚠${C_RESET}  Escribe exactamente 'true' o 'false'\n" >&2
    done
}

_ask_number() {
    local label="$1"
    local current="$2"
    local result
    while true; do
        printf "  ${C_BLUE}?${C_RESET}  %s\n"                                        "$label"   >&2
        printf "      ${C_DIM}Actual: %s — Nuevo número (Enter conserva):${C_RESET} " "$current" >&2
        read -r result
        [[ -z "$result" ]] && { printf '%s' "$current"; return; }
        [[ "$result" =~ ^[0-9]+$ ]] && { printf '%s' "$result"; return; }
        printf "  ${C_YELLOW}⚠${C_RESET}  Introduce un número entero (ej: 3)\n" >&2
    done
}

menu_configure() {
    while true; do
        clear 2>/dev/null || true
        printf "\n${C_BOLD}${C_CYAN}"
        printf "  ╔══════════════════════════════════════════════════╗\n"
        printf "  ║           CONFIGURACIÓN DEL SISTEMA              ║\n"
        printf "  ╚══════════════════════════════════════════════════╝\n"
        printf "${C_RESET}\n"

        # Mostrar valores actuales como resumen
        local _drive_type; _drive_type="Mi Google Drive personal"
        [[ "$(_conf_get SHARED_DRIVE)" == "true" && -n "$(_conf_get TEAM_DRIVE_ID)" ]] && \
            _drive_type="Team Drive / Shared Drive  [ID: $(_conf_get TEAM_DRIVE_ID)]"

        printf "  ${C_BOLD}RESUMEN ACTUAL${C_RESET}\n"
        hr
        printf "  %-28s ${C_CYAN}%s${C_RESET}\n" "Remote rclone:"       "$(_conf_get RCLONE_REMOTE)"
        printf "  %-28s ${C_CYAN}%s${C_RESET}\n" "Carpeta en Drive:"     "$(_conf_get DRIVE_PATH)"
        printf "  %-28s ${C_CYAN}%s${C_RESET}\n" "Tipo de Drive:"        "$_drive_type"
        printf "  %-28s ${C_CYAN}%s${C_RESET}\n" "Repo local:"           "$(_conf_get LOCAL_REPO)"
        printf "  %-28s ${C_CYAN}%s${C_RESET}\n" "Contraseña:"           "$(python3 -c "p='$(_conf_get RESTIC_PASSWORD)'; print('*'*min(len(p),6) + '…' if len(p)>6 else '*'*len(p))" 2>/dev/null || echo '******')"
        printf "  %-28s ${C_CYAN}%s${C_RESET}\n" "Retención activa:"     "$(_conf_get ENABLE_RETENTION)"
        hr
        blank

        printf "  ${C_BOLD}¿QUÉ DESEAS CONFIGURAR?${C_RESET}\n"
        blank
        opt  1 "Conexión Google Drive  (carpeta, nombre de remote)"
        opt  2 "Contraseña del repositorio Restic"
        opt  3 "Directorios a respaldar"
        opt  4 "Exclusiones (archivos/carpetas a ignorar)"
        opt  5 "Política de retención de backups"
        opt  6 "Rutas de logs"
        opt  7 "Ver el archivo de configuración completo"
        opt  0 "Volver al menú principal"
        blank
        ask "Opción:"
        read -r opt_val

        case "$opt_val" in

            # ------------------------------------------------------------------
            1) # Conexión Google Drive
            # ------------------------------------------------------------------
            title "Conexión Google Drive"

            # ── ¿QUÉ ES EL NOMBRE DE REMOTE? ──────────────────────────────────
            blank
            printf "  ${C_BOLD}¿Qué es el \"nombre de remote\"?${C_RESET}\n"
            printf "  ${C_DIM}  Es el alias que le diste a tu cuenta de Google Drive cuando${C_RESET}\n"
            printf "  ${C_DIM}  ejecutaste 'rclone config'. Normalmente es 'gdrive' o 'drive'.${C_RESET}\n"
            printf "  ${C_DIM}  Si no lo recuerdas, ejecuta:  rclone listremotes${C_RESET}\n"
            blank
            new_remote="$(_ask_val "Nombre del remote rclone" "$(_conf_get RCLONE_REMOTE)")"

            # ── CARPETA EN DRIVE ───────────────────────────────────────────────
            blank
            hr
            printf "  ${C_BOLD}Carpeta en Google Drive${C_RESET}\n"
            printf "  ${C_DIM}  Los backups se guardarán en esta carpeta dentro de tu Google Drive.${C_RESET}\n"
            printf "  ${C_DIM}  Puedes usar subcarpetas: ej.  backups/mi-servidor${C_RESET}\n"
            warn_ui "Cambiarla crea una NUEVA carpeta — los backups existentes no se moverán."
            blank
            new_path="$(_ask_val "Nombre/ruta de la carpeta en Drive" "$(_conf_get DRIVE_PATH)")"

            # ── TIPO DE GOOGLE DRIVE ───────────────────────────────────────────
            blank
            hr
            printf "  ${C_BOLD}Tipo de Google Drive${C_RESET}\n"
            printf "  ${C_DIM}  Opción 1: cuenta personal de Google (gmail.com) → la más común${C_RESET}\n"
            printf "  ${C_DIM}  Opción 2: Workspace empresarial con Unidad Compartida (Team Drive)${C_RESET}\n"
            blank
            opt 1 "Mi Google Drive personal  (cuenta gmail / Mi Unidad)"
            opt 2 "Unidad Compartida de Google Workspace  (Team Drive)"
            blank
            local _cur_shared; _cur_shared="$(_conf_get SHARED_DRIVE)"
            local _cur_teamid; _cur_teamid="$(_conf_get TEAM_DRIVE_ID)"
            local _cur_drive_opt="1"
            [[ "$_cur_shared" == "true" && -n "$_cur_teamid" ]] && _cur_drive_opt="2"
            printf "  ${C_BLUE}?${C_RESET}  Tipo (actual: opción %s, Enter conserva): " "$_cur_drive_opt"
            read -r _drive_choice
            [[ -z "$_drive_choice" ]] && _drive_choice="$_cur_drive_opt"

            new_shared="false"
            new_teamid=""
            case "$_drive_choice" in
                1)
                    new_shared="false"
                    new_teamid=""
                    ok "Configurado: Google Drive personal"
                    ;;
                2)
                    new_shared="true"
                    blank
                    # Intentar listar las Unidades Compartidas disponibles desde rclone
                    local _drives_json="" _drives_count=0
                    if rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:"; then
                        info "Consultando Unidades Compartidas disponibles en '${RCLONE_REMOTE}'..."
                        _drives_json="$(rclone backend drives "${RCLONE_REMOTE}:" 2>/dev/null || true)"
                        if [[ -n "$_drives_json" ]]; then
                            _drives_count="$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    if isinstance(data, list): print(len(data))
    else: print(0)
except: print(0)
" "$_drives_json" 2>/dev/null || echo 0)"
                        fi
                    fi

                    if [[ "$_drives_count" -gt 0 ]]; then
                        blank
                        info "Unidades Compartidas encontradas:"
                        python3 -c "
import json, sys
data = json.loads(sys.argv[1])
for i, d in enumerate(data, 1):
    print(f'  [{i}]  {d[\"name\"]}')
    print(f'        ID: {d[\"id\"]}')
" "$_drives_json" 2>/dev/null
                        blank
                        printf "  ${C_BLUE}?${C_RESET}  Selecciona número"
                        [[ -n "$_cur_teamid" ]] && printf " (Enter conserva: %s)" "$_cur_teamid"
                        printf ": "
                        read -r _td_sel
                        if [[ -z "$_td_sel" ]]; then
                            new_teamid="$_cur_teamid"
                        elif [[ "$_td_sel" =~ ^[0-9]+$ ]]; then
                            new_teamid="$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
idx = int(sys.argv[2]) - 1
if 0 <= idx < len(data): print(data[idx]['id'])
" "$_drives_json" "$_td_sel" 2>/dev/null || true)"
                            _td_name="$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
idx = int(sys.argv[2]) - 1
if 0 <= idx < len(data): print(data[idx]['name'])
" "$_drives_json" "$_td_sel" 2>/dev/null || true)"
                            if [[ -z "$new_teamid" ]]; then
                                warn_ui "Número inválido — escribe el ID manualmente:"
                                printf "  ${C_BLUE}?${C_RESET}  ID: "; read -r new_teamid
                            else
                                ok "Seleccionada: $_td_name"
                            fi
                        else
                            # El usuario escribió directamente un ID
                            new_teamid="$_td_sel"
                        fi
                    else
                        # rclone no configurado o sin unidades → entrada manual
                        info "No se encontraron Unidades Compartidas (¿rclone configurado?)."
                        info "Encuéntralo en la URL de Drive al abrir la unidad compartida:"
                        printf "  ${C_DIM}  drive.google.com/drive/folders/${C_CYAN}<este-es-el-ID>${C_RESET}\n"
                        blank
                        new_teamid="$(_ask_val "ID de la Unidad Compartida" "$_cur_teamid")"
                    fi

                    if [[ -z "$new_teamid" ]]; then
                        warn_ui "Sin ID no se puede usar Team Drive. Se usará Google Drive personal."
                        new_shared="false"
                    else
                        ok "Configurado: Team Drive [$new_teamid]"
                    fi
                    ;;
                *)
                    warn_ui "Opción inválida — no se modificó el tipo de Drive"
                    new_shared="$_cur_shared"
                    new_teamid="$_cur_teamid"
                    ;;
            esac

            blank
            info "Guardando cambios en backup.conf..."
            _conf_set RCLONE_REMOTE   "$new_remote"
            _conf_set DRIVE_PATH      "$new_path"
            _conf_set SHARED_DRIVE    "$new_shared"
            _conf_set TEAM_DRIVE_ID   "$new_teamid"

            source "$CONFIG_FILE"
            export RESTIC_PASSWORD RESTIC_PASSWORD2
            # Re-aplicar Team Drive env tras recargar config (debe ser en shell principal)
            if [[ "${SHARED_DRIVE:-false}" == "true" && -n "${TEAM_DRIVE_ID:-}" ]]; then
                _rcu_tmp="$(echo "$RCLONE_REMOTE" | tr '[:lower:]' '[:upper:]')"
                export "RCLONE_CONFIG_${_rcu_tmp}_TEAM_DRIVE=${TEAM_DRIVE_ID}"
                unset _rcu_tmp
            fi
            ok "Configuración guardada"
            blank
            info "Resumen:"
            printf "  ${C_DIM}  Remote:  %s${C_RESET}\n" "$new_remote"
            printf "  ${C_DIM}  Carpeta: %s${C_RESET}\n" "$new_path"
            ;;

            # ------------------------------------------------------------------
            2) # Contraseña Restic
            # ------------------------------------------------------------------
            title "Contraseña de cifrado de backups"
            blank
            printf "  ${C_BOLD}¿Qué es esta contraseña?${C_RESET}\n"
            printf "  ${C_DIM}  Restic cifra (encripta) todos tus backups con esta contraseña.${C_RESET}\n"
            printf "  ${C_DIM}  Sin ella es IMPOSIBLE restaurar archivos, ni siquiera con acceso${C_RESET}\n"
            printf "  ${C_DIM}  físico al servidor o a Google Drive.${C_RESET}\n"
            blank
            printf "  ${C_DIM}  Guárdala en un lugar seguro (gestor de contraseñas, papel, etc.).${C_RESET}\n"
            blank
            warn_ui "Cambiarla AQUÍ solo actualiza backup.conf."
            warn_ui "También debes cambiarla en los repositorios existentes (opción 10 del menú principal)."
            blank
            printf "  ${C_BLUE}?${C_RESET}  Nueva contraseña (Enter para cancelar, no se muestra al escribir): "
            read -rs new_pass; printf "\n"
            [[ -z "$new_pass" ]] && { info "Cancelado."; continue; }
            printf "  ${C_BLUE}?${C_RESET}  Repite la contraseña: "
            read -rs new_pass2; printf "\n"

            if [[ "$new_pass" != "$new_pass2" ]]; then
                err_ui "Las contraseñas no coinciden — no se guardó nada"
            else
                _conf_set RESTIC_PASSWORD "$new_pass"
                source "$CONFIG_FILE"
                export RESTIC_PASSWORD RESTIC_PASSWORD2
                ok "Contraseña actualizada en backup.conf"
                warn_ui "Recuerda actualizarla también en los repositorios con la opción 10 del menú"
            fi
            ;;

            # ------------------------------------------------------------------
            3) # Directorios a respaldar
            # ------------------------------------------------------------------
            title "Directorios a respaldar"

            # Mostrar los actuales
            info "Directorios actuales:"
            current_dirs=()
            while IFS= read -r line; do
                line="$(echo "$line" | tr -d '"' | xargs)"
                [[ -n "$line" ]] && current_dirs+=("$line")
            done < <(awk '/^BACKUP_DIRS=\(/{found=1;next} /^\)/{found=0} found{print}' "$CONFIG_FILE")

            for i in "${!current_dirs[@]}"; do
                printf "  ${C_DIM}[%d]${C_RESET}  %s\n" "$((i+1))" "${current_dirs[$i]}"
            done
            blank

            printf "  ${C_BOLD}Opciones:${C_RESET}\n"
            opt "a" "Agregar un directorio"
            opt "e" "Eliminar un directorio"
            opt "r" "Reemplazar toda la lista"
            opt "c" "Cancelar"
            ask "Opción:"
            read -r dir_opt

            case "$dir_opt" in
                a)
                    printf "  ${C_BLUE}?${C_RESET}  Ruta a agregar (ej: /var/lib/mysql): "
                    read -r new_dir
                    [[ -z "$new_dir" ]] && { info "Cancelado."; continue; }
                    if [[ ! -d "$new_dir" ]]; then
                        warn_ui "El directorio '$new_dir' no existe en el servidor"
                        ask "¿Agregar de todas formas? (s/N):"
                        read -r force
                        [[ "${force,,}" != "s" ]] && continue
                    fi
                    current_dirs+=("$new_dir")
                    _conf_set_array BACKUP_DIRS "${current_dirs[@]}"
                    source "$CONFIG_FILE"
                    ok "Directorio '$new_dir' agregado"
                    ;;
                e)
                    ask "Número del directorio a eliminar:"
                    read -r del_idx
                    if [[ "$del_idx" =~ ^[0-9]+$ ]] && \
                       [[ "$del_idx" -ge 1 ]] && \
                       [[ "$del_idx" -le "${#current_dirs[@]}" ]]; then
                        removed="${current_dirs[$((del_idx-1))]}"
                        unset 'current_dirs[$((del_idx-1))]'
                        current_dirs=("${current_dirs[@]}")
                        _conf_set_array BACKUP_DIRS "${current_dirs[@]}"
                        source "$CONFIG_FILE"
                        ok "Directorio '$removed' eliminado de la lista"
                    else
                        err_ui "Número inválido"
                    fi
                    ;;
                r)
                    blank
                    info "Escribe los directorios uno por línea."
                    info "Cuando termines escribe 'FIN' y presiona Enter."
                    blank
                    new_dirs=()
                    while true; do
                        printf "  ${C_BLUE}+${C_RESET}  Directorio: "
                        read -r new_dir
                        [[ "$new_dir" == "FIN" || -z "$new_dir" ]] && break
                        new_dirs+=("$new_dir")
                    done
                    if [[ ${#new_dirs[@]} -eq 0 ]]; then
                        warn_ui "No se ingresaron directorios — lista no modificada"
                    else
                        _conf_set_array BACKUP_DIRS "${new_dirs[@]}"
                        source "$CONFIG_FILE"
                        ok "Lista de directorios actualizada (${#new_dirs[@]} entradas)"
                    fi
                    ;;
                *) info "Cancelado." ;;
            esac
            ;;

            # ------------------------------------------------------------------
            4) # Exclusiones
            # ------------------------------------------------------------------
            title "Exclusiones"

            info "Patrones excluidos actuales:"
            current_excl=()
            while IFS= read -r line; do
                line="$(echo "$line" | tr -d '"' | xargs)"
                [[ -n "$line" ]] && current_excl+=("$line")
            done < <(awk '/^EXCLUDE_PATTERNS=\(/{found=1;next} /^\)/{found=0} found{print}' "$CONFIG_FILE")

            for i in "${!current_excl[@]}"; do
                printf "  ${C_DIM}[%d]${C_RESET}  %s\n" "$((i+1))" "${current_excl[$i]}"
            done
            blank

            opt "a" "Agregar una exclusión"
            opt "e" "Eliminar una exclusión"
            opt "c" "Cancelar"
            ask "Opción:"
            read -r excl_opt

            case "$excl_opt" in
                a)
                    printf "  ${C_BLUE}?${C_RESET}  Patrón a excluir (ej: *.tmp  o  /home/user/.cache): "
                    read -r new_excl
                    [[ -z "$new_excl" ]] && { info "Cancelado."; continue; }
                    current_excl+=("$new_excl")
                    _conf_set_array EXCLUDE_PATTERNS "${current_excl[@]}"
                    source "$CONFIG_FILE"
                    ok "Exclusión '$new_excl' agregada"
                    ;;
                e)
                    ask "Número de la exclusión a eliminar:"
                    read -r del_idx
                    if [[ "$del_idx" =~ ^[0-9]+$ ]] && \
                       [[ "$del_idx" -ge 1 ]] && \
                       [[ "$del_idx" -le "${#current_excl[@]}" ]]; then
                        removed="${current_excl[$((del_idx-1))]}"
                        unset 'current_excl[$((del_idx-1))]'
                        current_excl=("${current_excl[@]}")
                        _conf_set_array EXCLUDE_PATTERNS "${current_excl[@]}"
                        source "$CONFIG_FILE"
                        ok "Exclusión '$removed' eliminada"
                    else
                        err_ui "Número inválido"
                    fi
                    ;;
                *) info "Cancelado." ;;
            esac
            ;;

            # ------------------------------------------------------------------
            5) # Retención
            # ------------------------------------------------------------------
            title "Política de retención de backups"
            info "Configura cuántas copias conservar. Pon 0 para desactivar cada tipo."
            blank

            new_ret="$(_ask_bool   "¿Activar retención automática?" "$(_conf_get ENABLE_RETENTION)")"
            new_last="$(_ask_number "Últimas N copias a conservar siempre (KEEP_LAST)" "$(_conf_get KEEP_LAST)")"
            new_daily="$(_ask_number "Últimas N copias diarias (KEEP_DAILY)" "$(_conf_get KEEP_DAILY)")"
            new_weekly="$(_ask_number "Últimas N copias semanales (KEEP_WEEKLY)" "$(_conf_get KEEP_WEEKLY)")"
            new_monthly="$(_ask_number "Últimas N copias mensuales (KEEP_MONTHLY)" "$(_conf_get KEEP_MONTHLY)")"

            _conf_set ENABLE_RETENTION "$new_ret"
            _conf_set KEEP_LAST        "$new_last"
            _conf_set KEEP_DAILY       "$new_daily"
            _conf_set KEEP_WEEKLY      "$new_weekly"
            _conf_set KEEP_MONTHLY     "$new_monthly"
            source "$CONFIG_FILE"
            ok "Política de retención guardada"
            ;;

            # ------------------------------------------------------------------
            6) # Rutas de logs
            # ------------------------------------------------------------------
            title "Rutas de logs"
            warn_ui "Cambia estas rutas solo si sabes lo que haces."
            blank

            new_logdir="$(_ask_val "Directorio base de logs" "$(_conf_get LOG_DIR)")"
            _conf_set LOG_DIR      "$new_logdir"
            _conf_set LOG_FILE     "${new_logdir}/backup.log"
            _conf_set ERROR_LOG    "${new_logdir}/error.log"
            _conf_set SYNC_LOG     "${new_logdir}/sync.log"
            _conf_set RESTORE_LOG  "${new_logdir}/restauracion.log"

            mkdir -p "$new_logdir" 2>/dev/null || true
            source "$CONFIG_FILE"
            ok "Rutas de logs actualizadas"
            info "Directorio creado si no existía: $new_logdir"
            ;;

            # ------------------------------------------------------------------
            7) # Ver archivo completo
            # ------------------------------------------------------------------
            title "Archivo de configuración completo"
            blank
            hr
            # Ocultar la contraseña al mostrar
            sed "s/\(RESTIC_PASSWORD=\"\)[^\"]*/\1******/" "$CONFIG_FILE"
            hr
            ;;

            0) return ;;
            *) warn_ui "Opción inválida" ;;
        esac

        blank
        ask "Presiona Enter para continuar..."
        read -r
    done
}

# ==============================================================================
# MENÚ PRINCIPAL
# ==============================================================================

show_menu() {
    clear 2>/dev/null || true
    printf "\n${C_BOLD}${C_CYAN}"
    printf "  ╔══════════════════════════════════════════════════╗\n"
    printf "  ║        SISTEMA DE BACKUPS — RESTIC + DRIVE       ║\n"
    printf "  ╚══════════════════════════════════════════════════╝\n"
    printf "${C_RESET}\n"

    printf "  ${C_BOLD}BACKUP Y RESTAURACIÓN${C_RESET}\n"
    printf "  ${C_GREEN} [1]${C_RESET}  Ejecutar backup ahora\n"
    printf "  ${C_GREEN} [2]${C_RESET}  Ver snapshots disponibles\n"
    printf "  ${C_GREEN} [3]${C_RESET}  Estado del sistema\n"
    printf "  ${C_GREEN}[14]${C_RESET}  Restaurar archivos desde backup\n"
    printf "  ${C_GREEN}[15]${C_RESET}  Sincronizar a Drive ahora\n"
    printf "\n"
    printf "  ${C_BOLD}GESTIÓN DE REPOSITORIOS${C_RESET}\n"
    printf "  ${C_YELLOW} [4]${C_RESET}  Eliminar snapshot específico\n"
    printf "  ${C_YELLOW} [5]${C_RESET}  Eliminar repositorio LOCAL\n"
    printf "  ${C_YELLOW} [6]${C_RESET}  Eliminar repositorio en DRIVE\n"
    printf "  ${C_YELLOW} [7]${C_RESET}  Verificar integridad de repositorios\n"
    printf "\n"
    printf "  ${C_BOLD}CONFIGURACIÓN DE GOOGLE DRIVE${C_RESET}\n"
    printf "  ${C_BLUE} [8]${C_RESET}  Reconfigurar Google Drive\n"
    printf "  ${C_BLUE} [9]${C_RESET}  Desconectar Google Drive (eliminar credenciales)\n"
    printf "  ${C_BLUE}[10]${C_RESET}  Cambiar contraseña del repositorio\n"
    printf "\n"
    printf "  ${C_BOLD}AUTOMATIZACIÓN Y DIAGNÓSTICO${C_RESET}\n"
    printf "  ${C_DIM}[11]${C_RESET}  Gestionar tareas automáticas (cron)\n"
    printf "  ${C_DIM}[12]${C_RESET}  Ver logs\n"
    printf "\n"
    printf "  ${C_BOLD}CONFIGURACIÓN${C_RESET}\n"
    printf "  ${C_CYAN}[13]${C_RESET}  Configurar ajustes del sistema\n"
    printf "\n"
    printf "  ${C_DIM} [0]${C_RESET}  Salir\n"
    printf "\n"
    ask "Selecciona una opción:"
}

# ==============================================================================
# FUNCIÓN PRINCIPAL DE BACKUP
# ==============================================================================

do_backup() {
    log "════════════════════════════════════════"
    log "Inicio de backup — $(hostname) — $(whoami)"
    log "════════════════════════════════════════"

    local REMOTE_REPO
    REMOTE_REPO="$(build_remote_repo)"

    if has_internet; then
        info "Internet disponible → backup a Google Drive"

        action_setup_rclone                    || { loge "Fallo en setup rclone"; return 1; }
        action_init_remote_repo "$REMOTE_REPO" || { loge "Fallo init remoto"; return 1; }

        if action_run_backup "$REMOTE_REPO" "Google Drive"; then
            action_apply_retention "$REMOTE_REPO" "Google Drive"
            ok "Backup completado → Google Drive"
            log "Backup completado exitosamente en Google Drive"
            _ROLLBACK_STACK=()
            return 0
        else
            warn_ui "Backup remoto falló — intentando backup local de emergencia"
            loge "Backup remoto falló, iniciando rollback parcial y fallback a local"
            run_rollback
            _ROLLBACK_STACK=()
            _ROLLBACK_ACTIVE=false
        fi
    else
        info "Sin internet → usando repositorio local"
    fi

    action_init_local_repo "$LOCAL_REPO" || { loge "Fallo init local"; return 1; }

    if action_run_backup "$LOCAL_REPO" "Local"; then
        action_apply_retention "$LOCAL_REPO" "Local"
        ok "Backup completado → Local"
        info "Se sincronizará a Drive automáticamente cuando haya internet"
        log "Backup completado exitosamente en repositorio local"
        _ROLLBACK_STACK=()
    else
        loge "Backup local también falló"
        return 1
    fi
}

# ==============================================================================
# PUNTO DE ENTRADA
# ==============================================================================

# Modo no interactivo: llamado desde cron con --backup
if [[ "${1:-}" == "--backup" ]]; then
    if [[ $EUID -ne 0 ]]; then
        loge "ADVERTENCIA: backup ejecutado sin root — archivos del sistema pueden no estar accesibles"
    fi
    do_backup
    exit $?
fi

# Modo interactivo: aviso si no se ejecuta como root
if [[ $EUID -ne 0 ]]; then
    blank
    printf "  ${C_YELLOW}⚠${C_RESET}  ${C_BOLD}Este script no se está ejecutando como root.${C_RESET}\n"
    printf "  ${C_DIM}  Para respaldar /etc, /var y otros directorios del sistema con permisos${C_RESET}\n"
    printf "  ${C_DIM}  restringidos, ejecútalo con:  ${C_CYAN}sudo bash %s${C_RESET}\n" "$0"
    printf "  ${C_DIM}  Sin root algunos archivos serán omitidos (el backup continuará igual).${C_RESET}\n"
    blank
fi

# Modo interactivo: menú
while true; do
    show_menu
    read -r choice
    case "$choice" in
        1)  menu_run_backup ;;
        2)  menu_list_snapshots ;;
        3)  menu_status ;;
        4)  menu_forget_snapshots ;;
        5)  menu_purge_local_repo ;;
        6)  menu_purge_drive_repo ;;
        7)  menu_verify_integrity ;;
        8)  menu_reconfigure_drive ;;
        9)  menu_remove_drive_config ;;
        10) menu_change_password ;;
        11) menu_cron_manage ;;
        12) menu_show_logs ;;
        13) menu_configure ;;
        14) menu_restore ;;
        15) menu_sync_now ;;
        0)  blank; ok "Hasta luego."; blank; exit 0 ;;
        *)  warn_ui "Opción inválida — elige entre 0 y 15" ;;
    esac
    blank
    ask "Presiona Enter para volver al menú..."
    read -r
done