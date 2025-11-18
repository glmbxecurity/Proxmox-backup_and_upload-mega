#!/bin/bash

# ==================================================
# 1. CONFIGURACIÓN
# ==================================================

LOCAL_DIR="/raid1/storage/dump"
REMOTE_DIR="/proxmox/dump"
LOGFILE="/var/log/mega_backup.log"
MAX_REMOTE_BACKUPS=3

# Comandos
MEGA_CMD_PUT="mega-put"
MEGA_CMD_LS="mega-ls"
MEGA_CMD_RM="mega-rm"
MEGA_CMD_MKDIR="mega-mkdir"
MEGA_CMD_WHO="mega-whoami"
MEGA_CMD_LOGIN="mega-login"

# ==================================================
# 2. FUNCIONES DE LOG Y ERROR
# ==================================================

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

error_exit() {
    log_msg "❌ ERROR CRÍTICO: $1"
    exit 1
}

# ==================================================
# 3. VERIFICACIONES Y LOGIN
# ==================================================

log_msg "=== Iniciando proceso de Backup a MEGA ==="

# 1. Verificar binarios
if ! command -v $MEGA_CMD_PUT &>/dev/null; then
    error_exit "El comando $MEGA_CMD_PUT no está instalado o no está en el PATH."
fi

# 2. Verificar Directorio Local
if [ ! -d "$LOCAL_DIR" ]; then
    error_exit "El directorio local $LOCAL_DIR no existe."
fi

# 3. VERIFICAR Y GESTIONAR LOGIN
log_msg "🔍 Verificando estado de la sesión de MEGA..."

if ! $MEGA_CMD_WHO >/dev/null 2>&1; then
    log_msg "⚠️ No hay sesión activa en MEGA."
    
    if [ -t 0 ]; then
        echo ""
        echo "🛑 ¡ATENCIÓN! Necesitas iniciar sesión en MEGA."
        echo "------------------------------------------------"
        read -p "✉️  Introduce tu Email de MEGA: " MEGA_EMAIL
        read -s -p "🔑 Introduce tu Contraseña: " MEGA_PASS
        echo ""
        echo "------------------------------------------------"
        echo "🔄 Intentando iniciar sesión..."
        
        if $MEGA_CMD_LOGIN "$MEGA_EMAIL" "$MEGA_PASS"; then
            log_msg "✅ Login exitoso. Continuando con el backup..."
        else
            error_exit "Falló el inicio de sesión. Verifica tus credenciales."
        fi
    else
        error_exit "El script se está ejecutando en segundo plano (Cron) y no hay sesión iniciada. Ejecuta el script manualmente una vez para loguearte."
    fi
else
    log_msg "✅ Sesión de MEGA activa. Continuando..."
fi

# 4. Verificar acceso a carpeta remota
if ! $MEGA_CMD_LS "$REMOTE_DIR" >/dev/null 2>&1; then
    log_msg "⚠️ La carpeta remota $REMOTE_DIR no parece existir. Intentando crearla..."
    if ! $MEGA_CMD_MKDIR -p "$REMOTE_DIR" >> "$LOGFILE" 2>&1; then
        error_exit "No se pudo crear o acceder al directorio remoto $REMOTE_DIR."
    fi
    log_msg "✅ Carpeta remota creada/verificada."
fi

# ==================================================
# 4. LÓGICA DE SUBIDA
# ==================================================

extract_id() {
    echo "$1" | grep -oE 'vzdump-(lxc|qemu)-[0-9]+-' | grep -oE '[0-9]+'
}

# CORRECCIÓN AQUÍ: Búsqueda directa sin variables intermedias para evitar error de comillas
LOCAL_FILES=($(find "$LOCAL_DIR" -maxdepth 1 -type f \( -name "*.tar" -o -name "*.tar.zst" -o -name "*.tar.gz" \) | sort))

if [ ${#LOCAL_FILES[@]} -eq 0 ]; then
    log_msg "ℹ️ No se encontraron archivos de backup en $LOCAL_DIR. Nada que subir."
    exit 0
fi

for FILE in "${LOCAL_FILES[@]}"; do
    BASENAME=$(basename "$FILE")
    LOCAL_ID=$(extract_id "$BASENAME")
    
    if [ -z "$LOCAL_ID" ]; then
        log_msg "⏭️ Saltando $BASENAME (No se pudo extraer ID)."
        continue
    fi

    REMOTE_INFO=$($MEGA_CMD_LS -l "$REMOTE_DIR" | grep "vzdump.*$LOCAL_ID") 
    EXACT_REMOTE_MATCH=$(echo "$REMOTE_INFO" | grep "$BASENAME")
    
    UPLOAD=true
    
    if [ -n "$EXACT_REMOTE_MATCH" ]; then
        log_msg "⏭️ El archivo $BASENAME ya existe en remoto. Saltando."
        UPLOAD=false
    fi

    if [ "$UPLOAD" = true ]; then
        log_msg "⬆️ Subiendo $BASENAME..."
        if $MEGA_CMD_PUT "$FILE" "$REMOTE_DIR/" >> "$LOGFILE" 2>&1; then
            log_msg "✅ Subida completada: $BASENAME"
        else
            log_msg "❌ ERROR al subir $BASENAME. Revisar conexión o espacio."
        fi
    fi
done

# ==================================================
# 5. LÓGICA DE LIMPIEZA (PRUNE)
# ==================================================

log_msg "🧹 Iniciando limpieza de backups antiguos (Max: $MAX_REMOTE_BACKUPS)..."

ALL_REMOTE_FILES=$($MEGA_CMD_LS "$REMOTE_DIR" | grep -E "vzdump-(lxc|qemu)-")

if [ -z "$ALL_REMOTE_FILES" ]; then
    log_msg "ℹ️ No hay archivos remotos para analizar limpieza."
    exit 0
fi

UNIQUE_IDS=$(echo "$ALL_REMOTE_FILES" | grep -oE 'vzdump-(lxc|qemu)-\K[0-9]+' | sort -u)

for CTID in $UNIQUE_IDS; do
    FILES_OF_ID=$(echo "$ALL_REMOTE_FILES" | grep -E "vzdump-(lxc|qemu)-${CTID}-" | sort -r)
    COUNT=$(echo "$FILES_OF_ID" | wc -l)
    
    if [ "$COUNT" -le "$MAX_REMOTE_BACKUPS" ]; then
        continue 
    fi
    
    FILES_TO_DELETE=$(echo "$FILES_OF_ID" | tail -n +$(($MAX_REMOTE_BACKUPS + 1)))
    
    echo "$FILES_TO_DELETE" | while read OLD_BACKUP; do
        if [ -n "$OLD_BACKUP" ]; then
            log_msg "🗑️ Eliminando backup antiguo: $OLD_BACKUP"
            if $MEGA_CMD_RM "$REMOTE_DIR/$OLD_BACKUP" >> "$LOGFILE" 2>&1; then
                log_msg "✅ Eliminado: $OLD_BACKUP"
            else
                log_msg "❌ Fallo al eliminar: $OLD_BACKUP"
            fi
        fi
    done
done

log_msg "=== Fin del proceso ==="
exit 0
