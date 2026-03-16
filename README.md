# Backup Restic + Google Drive

> Sistema de backup automático y cifrado para servidores Linux usando **Restic** y **Google Drive** via rclone.

---

## Características

- **Backups cifrados** con AES-256 via Restic
- **Deduplicación incremental** — solo transfiere datos nuevos
- **Sincronización automática** a Google Drive (personal o Shared Drive)
- **Modo offline** — almacena localmente y sincroniza cuando hay conexión
- **Políticas de retención** configurables (diarias, semanales, mensuales)
- **Automatización completa** via cron (backup diario a las 3 AM, sync cada 6 horas)
- **Instalación y desinstalación** en un solo comando

---

## Requisitos

| Requisito | Versión mínima |
|-----------|----------------|
| OS | Ubuntu / Debian (x86_64) |
| Bash | 4+ |
| Python | 3.x |
| Acceso root | Requerido |
| Conexión a internet | Para instalación y sincronización |

Las dependencias (**restic** v0.16.4 y **rclone** v1.68.2) se instalan automáticamente.

---

## Instalación

```bash
sudo bash install.sh
```

El instalador guiará de forma interactiva por:

1. Verificación de dependencias del sistema
2. Descarga e instalación de Restic y rclone
3. Configuración de Google Drive (OAuth2)
4. Definición de directorios a respaldar y contraseña de cifrado
5. Generación del archivo `backup.conf` (solo lectura para root)
6. Configuración automática del cron

---

## Estructura del proyecto

```
.
├── install.sh          # Instalador completo del sistema
├── backup-restic.sh    # Script principal de backup
├── sync-to-drive.sh    # Sincronización local → Google Drive
└── uninstall.sh        # Desinstalador con limpieza opcional de datos
```

Tras la instalación, los scripts quedan en `/opt/backup-scripts/`.

---

## Configuración

El instalador genera `/opt/backup-scripts/backup.conf` con permisos `600` (solo root). Las variables clave son:

| Variable | Descripción | Valor por defecto |
|----------|-------------|-------------------|
| `BACKUP_DIRS` | Directorios a respaldar | `/home /etc /var/www /opt` |
| `LOCAL_REPO` | Repositorio local de Restic | `/backup-local/restic-repo/` |
| `RCLONE_REMOTE` | Alias del remote de Google Drive | Definido en instalación |
| `DRIVE_PATH` | Carpeta destino en Google Drive | Definido en instalación |
| `RESTIC_PASSWORD` | Contraseña de cifrado | Definida en instalación |
| `SHARED_DRIVE` | Usar Google Workspace Shared Drive | `false` |

---

## Uso manual

```bash
# Ejecutar backup manualmente
sudo bash /opt/backup-scripts/backup-restic.sh

# Sincronizar backups a Google Drive
sudo bash /opt/backup-scripts/sync-to-drive.sh
```

---

## Programación automática (cron)

| Tarea | Horario |
|-------|---------|
| Backup completo | Diario a las 3:00 AM |
| Sincronización a Drive | Cada 6 horas |
| Limpieza de logs | Mensual (logs > 30 días) |

---

## Logs

| Archivo | Contenido |
|---------|-----------|
| `/var/log/restic/backup.log` | Historial de backups |
| `/var/log/restic/backup.error.log` | Errores de backup |
| `/var/log/restic/sync.log` | Historial de sincronizaciones |

---

## Desinstalación

```bash
sudo bash uninstall.sh
```

Elimina scripts, configuración y entradas de cron. Ofrece la opción de conservar o borrar los datos del repositorio local.

---

## Licencia

Uso libre. Sin garantías implícitas.
