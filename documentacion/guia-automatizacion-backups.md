# Guía de Automatización de Backups
## Sistema Restic + rclone + Google Drive

---

## Tabla de contenidos

1. [Descripción general](#1-descripción-general)
2. [Arquitectura del sistema](#2-arquitectura-del-sistema)
3. [Requisitos previos](#3-requisitos-previos)
4. [Instalación](#4-instalación)
5. [Configuración de Google Drive](#5-configuración-de-google-drive)
6. [Archivo de configuración `backup.conf`](#6-archivo-de-configuración-backupconf)
7. [Uso del menú principal](#7-uso-del-menú-principal)
8. [Automatización con cron](#8-automatización-con-cron)
9. [Restaurar archivos](#9-restaurar-archivos)
10. [Flujo de sincronización a Drive](#10-flujo-de-sincronización-a-drive)
11. [Logs y diagnóstico](#11-logs-y-diagnóstico)
12. [Desinstalación](#12-desinstalación)
13. [Referencia rápida de comandos](#13-referencia-rápida-de-comandos)

---

## 1. Descripción general

Este sistema automatiza la creación, cifrado y sincronización de backups de un servidor Linux hacia Google Drive, usando dos herramientas de código abierto:

| Herramienta | Versión | Función |
|-------------|---------|---------|
| **Restic** | 0.16.4 | Motor de backup: deduplica, comprime y cifra los datos |
| **rclone** | 1.68.2 | Puente hacia Google Drive: sube y descarga archivos |

### Flujo resumido

```
Servidor Linux
    │
    ▼ backup-restic.sh
Repositorio local  ──────────────────────────────► Google Drive
/backup-local/restic-repo    sync-to-drive.sh     gdrive:backups/servidor
(cifrado con AES-256)                              (cifrado con AES-256)
```

El backup **siempre se hace primero en local** y luego se sincroniza a Drive. Esto garantiza velocidad y disponibilidad offline.

---

## 2. Arquitectura del sistema

### Archivos instalados en el servidor

```
/opt/backup-scripts/
├── backup-restic.sh     # Menú principal + motor de backup
├── sync-to-drive.sh     # Sincronizador local → Drive
├── uninstall.sh         # Desinstalador completo
└── backup.conf          # Configuración central (permisos: 600, solo root)

/backup-local/
└── restic-repo/         # Repositorio Restic local (permisos: 700)

/var/log/restic/
├── backup.log           # Log de cada ejecución de backup
├── error.log            # Solo errores
├── sync.log             # Log de sincronización a Drive
├── cron.log             # Salida de las tareas automáticas
└── restauracion.log     # Log de restauraciones
```

### Scripts en el repositorio (fuente)

```
script-snapshots/
├── install.sh           # Instalador (se ejecuta una sola vez)
├── backup-restic.sh
├── sync-to-drive.sh
├── uninstall.sh
└── documentacion/
    └── guia-automatizacion-backups.md   ← este archivo
```

---

## 3. Requisitos previos

| Requisito | Detalle |
|-----------|---------|
| Sistema operativo | Ubuntu / Debian (recomendado) |
| Arquitectura | x86_64 (amd64) |
| Permisos | Ejecutar como **root** (`sudo`) |
| Conectividad | Acceso a internet para la instalación y la sincronización |
| Espacio en disco | Suficiente en `/backup-local` para al menos 2 snapshots |
| Cuenta Google | Google Drive personal o Google Workspace |

---

## 4. Instalación

### 4.1 Clonar el repositorio

```bash
git clone <url-del-repositorio> ~/script-snapshots
cd ~/script-snapshots
```

> Los scripts ya incluyen permisos de ejecución (`+x`) gracias a git. No es necesario hacer `chmod` manualmente.

### 4.2 Ejecutar el instalador

```bash
sudo bash install.sh
```

El instalador realiza los siguientes pasos de forma automática:

| Paso | Acción |
|------|--------|
| 1 | Verifica root, OS, arquitectura y conexión a internet |
| 2 | Instala **Restic** v0.16.4 en `/usr/local/bin/restic` |
| 3 | Instala **rclone** v1.68.2 en `/usr/local/bin/rclone` |
| 4 | Solicita configuración inicial (nombre de servidor, carpeta en Drive, contraseña) |
| 5 | Crea los directorios del sistema |
| 6 | Copia los scripts a `/opt/backup-scripts/` |
| 7 | Genera el archivo `backup.conf` con los datos ingresados |
| 8 | Aplica permisos seguros (`backup.conf` → 600, scripts → 750) |
| 9 | Verifica y activa el servicio `cron` |
| 10 | Opcionalmente instala las tareas automáticas en el crontab de root |

### 4.3 Datos que se solicitan durante la instalación

- **Nombre del servidor**: se usa para identificar el equipo en Drive (ej. `mi-servidor`).
- **Carpeta en Google Drive**: ruta donde se guardan los backups (ej. `backups/produccion`).
- **Nombre del remote de rclone**: alias para Google Drive, por defecto `gdrive`.
- **Contraseña de cifrado**: cifra todos los datos del repositorio. **Sin esta contraseña es imposible restaurar.** Guárdala en un lugar seguro.

---

## 5. Configuración de Google Drive

Tras la instalación, el sistema aún no tiene acceso a Google Drive. Debes autorizarlo desde el menú:

```bash
sudo bash /opt/backup-scripts/backup-restic.sh
# Selecciona opción [8] → Reconfigurar Google Drive
```

### 5.1 Detección automática del entorno

El script detecta automáticamente cómo está conectado al servidor y adapta el proceso de autorización:

| Entorno detectado | Cómo lo detecta | Método de autorización |
|-------------------|-----------------|------------------------|
| **Sesión local con entorno gráfico** | Variable `$DISPLAY` (X11) o `$WAYLAND_DISPLAY` (Wayland) | Abre el navegador directamente en el servidor |
| **Conexión SSH (sin GUI)** | Variable `$SSH_CLIENT` vacía o inexistente en entorno gráfico | **Túnel SSH** — el servidor actúa como relay y tú autorizas desde tu PC |

> La gran mayoría de servidores en producción se administran por SSH sin entorno gráfico, por lo que el flujo habitual es el de **túnel SSH**.

---

### 5.2 Caso A — Sesión local con entorno gráfico

Si estás sentado frente al servidor (o en una VM con escritorio), el script abre el navegador automáticamente. Solo debes:

1. Iniciar sesión con tu cuenta de Google en el navegador que se abre.
2. Aceptar los permisos solicitados por rclone.
3. Cuando el navegador muestre **"Success"**, volver a la terminal y pulsar Enter.

---

### 5.3 Caso B — Conexión SSH (sin entorno gráfico) ← caso habitual

Este es el flujo más común cuando administras el servidor de forma remota.

#### Cómo funciona

```
Tu PC                          Servidor (SSH)
  │                                  │
  │  1. El script inicia rclone      │
  │     en modo headless             │
  │◄─────────────────────────────────│
  │  2. El script te muestra         │
  │     el comando SSH exacto        │
  │                                  │
  │  3. Abres un túnel SSH ─────────►│ puerto 53682
  │     en una terminal nueva        │     │
  │                                  │     ▼
  │  4. Abres el enlace en           │  rclone escucha
  │     tu navegador                 │  la autorización
  │     http://127.0.0.1:53682/...   │
  │                                  │
  │  5. Autorizas en Google ────────►│ token capturado
  │                                  │
  │  6. Vuelves a la terminal        │
  │     del servidor y pulsas Enter  │
```

#### Paso a paso

**En el servidor** — ejecuta el menú y selecciona opción `[8]`:

```
  AUTENTICACIÓN REMOTA — TÚNEL SSH
────────────────────────────────────────────────────
  →  Iniciando servidor de autorización en puerto 53682...

  PASO 1 — Abre un túnel SSH en tu PC local
────────────────────────────────────────────────────
  →  Abre una terminal NUEVA en tu PC y ejecuta este comando:

      ssh -N -L 53682:127.0.0.1:53682 usuario@10.100.30.10

  ⚠  IP del servidor: 10.100.30.10
  →  Deja esa terminal abierta. El comando no muestra nada — eso es normal.

  PASO 2 — Abre el enlace en tu navegador
────────────────────────────────────────────────────
  →  Con el túnel activo, abre este enlace en tu navegador:

      http://127.0.0.1:53682/auth?state=xxxxx
```

**En tu PC (Windows/Mac/Linux)** — abre una terminal **nueva** (sin cerrar la del servidor) y ejecuta el comando que te mostró el script. Ejemplo en Windows (PowerShell o CMD):

```powershell
ssh -N -L 53682:127.0.0.1:53682 superaccess@10.100.30.10
```

> El comando pedirá tu contraseña SSH y luego se quedará "colgado" sin mostrar nada. **Eso es correcto** — el túnel está activo.

**En tu navegador** — abre el enlace `http://127.0.0.1:53682/auth?state=...` que te mostró el servidor, inicia sesión con tu cuenta de Google y acepta los permisos.

**De vuelta en el servidor** — cuando el navegador muestre **"Success"**, vuelve a la terminal del servidor y pulsa Enter.

```
  ?  ¿Ya autorizaste en el navegador? Presiona Enter para continuar...
  →  Capturando token de autorización...
  →  Configurando remote 'gdrive' con el token obtenido...
  ✔  ¡Google Drive autorizado y configurado correctamente!
  →  Ya puedes cerrar la terminal del túnel SSH en tu PC.
```

**Cierra el túnel** — en la terminal de tu PC donde dejaste el `ssh -N -L ...` activo, pulsa `Ctrl + C`.

---

### 5.4 Resolución de problemas de autorización

| Problema | Causa probable | Solución |
|----------|----------------|----------|
| El enlace `http://127.0.0.1:53682/...` no carga | El túnel SSH no está activo | Abre la terminal nueva en tu PC y ejecuta el comando `ssh -N -L ...` antes de abrir el enlace |
| `Connection refused` al abrir el enlace | El puerto del túnel no coincide | Verifica que el puerto en el comando SSH sea el mismo que aparece en el enlace |
| El script dice "puerto ocupado" | Otro proceso usa el 53682 | El script elige un puerto libre automáticamente — usa el número que indique en el comando |
| Error de permisos en Google | Scope incorrecto | Desconecta con opción `[9]` y vuelve a autorizar con `[8]` |

---

### 5.5 Paso final — Configurar tipo de Drive (opción 13)

Después de autorizar Google Drive con la opción `[8]`, **debes ir a la opción `[13] Configurar ajustes del sistema`** para indicar si usas Google Drive personal o una Unidad Compartida de Google Workspace.

```bash
# En el menú principal selecciona:
[13] Configurar ajustes del sistema
```

Dentro encontrarás la opción para elegir el tipo de Drive:

| Opción | Cuándo usarla |
|--------|---------------|
| **Google Drive personal** (`SHARED_DRIVE="false"`) | Cuenta Google personal — "Mi Unidad" |
| **Unidad Compartida / Team Drive** (`SHARED_DRIVE="true"`) | Google Workspace con Unidad Compartida |

Si seleccionas Unidad Compartida, el sistema te pedirá el **ID de la unidad**, que se obtiene de la URL en Google Drive:

```
https://drive.google.com/drive/folders/0ALYetsD4IlJgUk9PVA
                                       ^^^^^^^^^^^^^^^^^^^^
                                          este es el ID
```

> Sin este paso, el sistema usará Google Drive personal por defecto. Si tu cuenta es de Workspace con Unidad Compartida y no configuras el ID, los backups no se guardarán en el lugar correcto.

---

### 5.6 Resumen del flujo completo de configuración

```
[8]  Reconfigurar Google Drive   → autoriza tu cuenta de Google
[13] Configurar ajustes          → elige personal o Unidad Compartida
[1]  Ejecutar backup ahora       → valida que todo funciona correctamente
```

---

## 6. Archivo de configuración `backup.conf`

Ubicación: `/opt/backup-scripts/backup.conf`
Permisos: `600` (solo root puede leerlo, ya que contiene la contraseña).

```bash
# Nombre del remote de rclone
RCLONE_REMOTE="gdrive"

# Carpeta en Google Drive
DRIVE_PATH="backups/mi-servidor"

# Repositorio local (fallback sin internet)
LOCAL_REPO="/backup-local/restic-repo"

# Google Workspace (Team Drive)
SHARED_DRIVE="false"        # "true" si usas Unidad Compartida
TEAM_DRIVE_ID=""            # ID de la Unidad Compartida (si aplica)

# Contraseña de cifrado de Restic
RESTIC_PASSWORD="tu-contraseña-segura"

# Directorios que se incluyen en el backup
BACKUP_DIRS=(
    "/home"
    "/etc"
    "/var/www"
    "/opt"
)

# Patrones excluidos del backup
EXCLUDE_PATTERNS=(
    "/home/*/.cache"
    "/home/*/.local/share/Trash"
    "*.tmp"
    "*.log"
    "*.swp"
    "/var/cache"
    "/opt/backup-scripts/backup-previo"
    "node_modules"
    ".git"
)

# Política de retención (cuántos snapshots conservar)
ENABLE_RETENTION="true"
KEEP_LAST="3"       # Últimos N snapshots
KEEP_DAILY="7"      # N diarios
KEEP_WEEKLY="4"     # N semanales
KEEP_MONTHLY="0"    # N mensuales (0 = desactivado)

# Rutas de logs
LOG_DIR="/var/log/restic"
LOG_FILE="/var/log/restic/backup.log"
ERROR_LOG="/var/log/restic/error.log"
SYNC_LOG="/var/log/restic/sync.log"
RESTORE_LOG="/var/log/restic/restauracion.log"
```

> Puedes editar este archivo directamente o usar la **opción [13]** del menú.

---

## 7. Uso del menú principal

```bash
sudo bash /opt/backup-scripts/backup-restic.sh
```

### Secciones del menú

#### Backup y restauración

| Opción | Función |
|--------|---------|
| `[1]` | Ejecutar backup ahora |
| `[2]` | Ver snapshots disponibles |
| `[3]` | Estado del sistema |
| `[14]` | Restaurar archivos desde backup |
| `[15]` | Sincronizar a Drive ahora |

#### Gestión de repositorios

| Opción | Función |
|--------|---------|
| `[4]` | Eliminar snapshot específico |
| `[5]` | Eliminar repositorio LOCAL |
| `[6]` | Eliminar repositorio en DRIVE |
| `[7]` | Verificar integridad de repositorios |

#### Configuración de Google Drive

| Opción | Función |
|--------|---------|
| `[8]` | Reconfigurar Google Drive (rclone config) |
| `[9]` | Desconectar Google Drive (eliminar credenciales) |
| `[10]` | Cambiar contraseña del repositorio |

#### Automatización y diagnóstico

| Opción | Función |
|--------|---------|
| `[11]` | Gestionar tareas automáticas (cron) |
| `[12]` | Ver logs |
| `[13]` | Configurar ajustes del sistema |

---

## 8. Automatización con cron

Las tareas se instalan en el **crontab de root** para tener acceso completo al sistema.

### Tareas instaladas por defecto

| Tarea | Horario | Comando |
|-------|---------|---------|
| Backup diario | 3:00 AM | `backup-restic.sh --backup` |
| Sincronización a Drive | Cada 6 horas | `sync-to-drive.sh` |
| Limpieza de logs | Día 1 de cada mes | `find /var/log/restic -name "*.log" -mtime +30 -delete` |

### Gestión manual

Ver el crontab de root:
```bash
sudo crontab -l
```

Editar el crontab de root:
```bash
sudo crontab -e
```

También puedes gestionar las tareas desde el **menú → opción [11]**.

---

## 9. Restaurar archivos

### Desde el menú

1. `sudo bash /opt/backup-scripts/backup-restic.sh`
2. Selecciona **[14] Restaurar archivos desde backup**
3. Elige el origen: `[1]` local o `[2]` Google Drive
4. Ingresa el ID del snapshot o escribe `latest` para el más reciente
5. Especifica una ruta concreta (ej. `/etc/nginx`) o deja en blanco para **restaurar todo**
6. Ingresa el directorio destino (ej. `/tmp/restauracion` o `/` para restauración completa)

> **Consejo:** usa siempre `/tmp/restauracion` para revisar los archivos antes de sobreescribir el sistema. Para restauración completa de emergencia puedes usar `/`.

### Ver snapshots disponibles

```bash
# Repositorio local
sudo RESTIC_PASSWORD="tu-contraseña" restic -r /backup-local/restic-repo snapshots

# Repositorio en Drive
sudo RESTIC_PASSWORD="tu-contraseña" restic -r rclone:gdrive:backups/mi-servidor snapshots
```

### Restaurar desde línea de comandos

```bash
# Restaurar todo el snapshot más reciente en /tmp/restauracion
sudo RESTIC_PASSWORD="tu-contraseña" restic -r /backup-local/restic-repo \
    restore latest --target /tmp/restauracion

# Restaurar solo /etc/nginx del snapshot más reciente
sudo RESTIC_PASSWORD="tu-contraseña" restic -r /backup-local/restic-repo \
    restore latest --target /tmp/restauracion --include /etc/nginx
```

---

## 10. Flujo de sincronización a Drive

El script `sync-to-drive.sh` sigue este flujo cada vez que se ejecuta:

```
1. ¿Hay conexión a internet?
   └─ No → sale sin error (reintentará en la próxima ejecución cron)

2. ¿Existe el repositorio local y tiene snapshots?
   └─ No → sale sin error

3. ¿Existe el repositorio remoto en Drive?
   └─ No → lo inicializa (restic init)

4. Copia los snapshots locales al remoto (restic copy)
   └─ Es idempotente: no duplica snapshots ya existentes

5. Limpia el repositorio LOCAL conservando solo los últimos 2 snapshots
   └─ Los snapshots eliminados localmente siguen seguros en Drive
```

> La sincronización **no elimina datos en Drive**. Solo añade lo que falta.

---

## 11. Logs y diagnóstico

### Ubicación de logs

| Archivo | Contenido |
|---------|-----------|
| `/var/log/restic/backup.log` | Registro de cada ejecución de backup |
| `/var/log/restic/error.log` | Solo errores críticos |
| `/var/log/restic/sync.log` | Registro de sincronización a Drive |
| `/var/log/restic/cron.log` | Salida de las tareas automáticas (cron) |
| `/var/log/restic/restauracion.log` | Registro de restauraciones |

### Ver logs desde el menú

Menú → **[12] Ver logs**

### Ver logs directamente

```bash
# Últimas 50 líneas del backup
sudo tail -50 /var/log/restic/backup.log

# Solo errores
sudo cat /var/log/restic/error.log

# Seguir el log en tiempo real durante un backup
sudo tail -f /var/log/restic/cron.log
```

### Verificar integridad

Menú → **[7] Verificar integridad de repositorios**

O desde la línea de comandos:
```bash
# Repositorio local
sudo RESTIC_PASSWORD="tu-contraseña" restic -r /backup-local/restic-repo check

# Repositorio en Drive
sudo RESTIC_PASSWORD="tu-contraseña" restic -r rclone:gdrive:backups/mi-servidor check
```

---

## 12. Desinstalación

```bash
sudo bash /opt/backup-scripts/uninstall.sh
```

El desinstalador elimina:
- Scripts en `/opt/backup-scripts/`
- Tareas cron instaladas
- Logs en `/var/log/restic/`
- Opcionalmente: el repositorio local en `/backup-local/restic-repo/`

> El repositorio en Google Drive **no se elimina automáticamente**. Puedes borrarlo manualmente desde Drive o usando la opción **[6]** del menú antes de desinstalar.

---

## 13. Referencia rápida de comandos

```bash
# Abrir el menú principal
sudo bash /opt/backup-scripts/backup-restic.sh

# Ejecutar backup manualmente
sudo bash /opt/backup-scripts/backup-restic.sh --backup

# Sincronizar a Drive manualmente
sudo bash /opt/backup-scripts/sync-to-drive.sh

# Ver snapshots (local)
sudo RESTIC_PASSWORD="tu-contraseña" restic -r /backup-local/restic-repo snapshots

# Restaurar todo desde el snapshot más reciente (local)
sudo RESTIC_PASSWORD="tu-contraseña" restic -r /backup-local/restic-repo \
    restore latest --target /tmp/restauracion

# Ver crontab de root
sudo crontab -l

# Ver logs en tiempo real
sudo tail -f /var/log/restic/cron.log

# Desinstalar
sudo bash /opt/backup-scripts/uninstall.sh
```

---

> **Recuerda:** guarda la contraseña de cifrado en un lugar seguro y separado del servidor. Sin ella, los backups no pueden restaurarse.
