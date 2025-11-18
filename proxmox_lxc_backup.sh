#!/bin/bash

# ==================================================
# 1. CONFIGURACIÓN GLOBAL
# ==================================================

# --- Directorios ---
BACKUP_DIR="/raid1/storage/dump"      # Ruta local
REMOTE_DIR="/proxmox/dump"            # Ruta en MEGA
LOGFILE="/var/log/proxmox_full_backup.log"

# --- Retención (Copias a guardar) ---
MAX_BACKUPS_LOCAL=1
MAX_BACKUPS_REMOTE=3

# --- Configuración de Backups (vzdump) ---
COMPRESSION="zstd"
MODE="stop"
TIMEOUT_SHUTDOWN=30
TIMEOUT_WAIT_OFF=10
SLEEP_INTERVAL=5

# --- Comandos ---
WHIPTAIL_CMD="whiptail"
MEGA_CMD_PUT="mega-put"
MEGA_CMD_LS="mega-ls"
MEGA_CMD_RM="mega-rm"
MEGA_CMD_MKDIR="mega-mkdir"
MEGA_CMD_WHO="mega-whoami"
MEGA_CMD_LOGIN="mega-login"

# --- VARIABLES DE CONTROL ---
NEWLY_CREATED_FILES=()

# ==================================================
# 2. FUNCIONES DE SOPORTE
# ==================================================

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

error_exit() {
    log_msg "❌ ERROR CRÍTICO: $1"
    exit 1
}

extract_id() {
    echo "$1" | grep -oE 'vzdump-(lxc|qemu)-[0-9]+-' | grep -oE '[0-9]+'
}

show_checklist_menu() {
    local TITLE="$1"
    local TEXT="$2"
    shift 2
    local ITEMS=("$@")
    "$WHIPTAIL_CMD" --title "$TITLE" --checklist "$TEXT" 22 78 12 "${ITEMS[@]}" 3>&1 1>&2 2>&3
}

# ==================================================
# 3. SELECCIÓN DE LXC/VM PARA BACKUP (MENÚ 1)
# ==================================================

LXC_LIST_TO_PROCESS=()

if [ -t 0 ] && command -v "$WHIPTAIL_CMD" &>/dev/null; then
    
    LXC_MENU_ITEMS=()
    ALL_LXC_IDS=""
    
    LXC_MENU_ITEMS+=(
        "ALL_IDS"
        "Seleccionar TODOS los contenedores"
        "OFF"
    )
    
    while read -r LINE; do
        ID=$(echo "$LINE" | awk '{print $1}')
        STATUS=$(echo "$LINE" | awk '{print $2}')
        NAME=$(echo "$LINE" | awk '{print $NF}')
        
        if [[ "$ID" =~ ^[0-9]+$ ]]; then
            LXC_MENU_ITEMS+=(
                "$ID"
                "$NAME [$STATUS]"
                "OFF"
            )
            ALL_LXC_IDS="$ALL_LXC_IDS $ID"
        fi
    done < <(/usr/sbin/pct list | awk 'NR>1')

    if [ ${#LXC_MENU_ITEMS[@]} -le 3 ]; then
        error_exit "No se detectaron contenedores LXC activos."
    fi

    log_msg "Menú interactivo: Iniciando selección de LXC."
    
    SELECTION=$(show_checklist_menu \
        "SCRIPT BACKUP ALL IN ONE" \
        "Marque con ESPACIO los contenedores a respaldar o elija ALL_IDS." \
        "${LXC_MENU_ITEMS[@]}"
    )

    if [ $? -eq 0 ]; then
        SELECTED_IDS=$(echo "$SELECTION" | tr -d '"')
        
        if echo "$SELECTED_IDS" | grep -q "ALL_IDS"; then
            LXC_LIST_TO_PROCESS=($ALL_LXC_IDS)
            log_msg "Selección: Opción ALL marcada. Procesando todos."
        else
            LXC_LIST_TO_PROCESS=($SELECTED_IDS)
            if [ ${#LXC_LIST_TO_PROCESS[@]} -eq 0 ]; then
                log_msg "⚠️ No seleccionaste nada. Saliendo."
                exit 0
            fi
            log_msg "Selección: IDs específicos -> ${LXC_LIST_TO_PROCESS[*]}"
        fi
    else
        error_exit "Menú cancelado por el usuario."
    fi

else
    LXC_LIST_TO_PROCESS=$(/usr/sbin/pct list | awk 'NR>1 {print $1}')
    log_msg "⚙️ Modo Automático/Cron. Procesando: ALL"
fi

# ==================================================
# 4. VERIFICACIONES PREVIAS
# ==================================================

log_msg "========================================"
log_msg "🚀 INICIO DEL SCRIPT MAESTRO DE BACKUP"
log_msg "========================================"

if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
fi

if ! command -v $MEGA_CMD_PUT &>/dev/null; then
    error_exit "MEGAcmd no está instalado."
fi

if ! $MEGA_CMD_WHO >/dev/null 2>&1; then
    if [ -t 0 ]; then
        echo ""
        echo "🛑 REQUERIDO: Iniciar sesión en MEGA"
        read -p "✉️  Email: " MEGA_EMAIL
        read -s -p "🔑 Password: " MEGA_PASS
        echo ""
        if ! $MEGA_CMD_LOGIN "$MEGA_EMAIL" "$MEGA_PASS"; then
            error_exit "Login fallido."
        fi
    else
        error_exit "No hay sesión de MEGA activa (Modo Cron)."
    fi
fi

if ! $MEGA_CMD_LS "$REMOTE_DIR" >/dev/null 2>&1; then
    $MEGA_CMD_MKDIR -p "$REMOTE_DIR" >> "$LOGFILE" 2>&1
fi

# ==================================================
# 5. FASE 1: BACKUPS LOCALES
# ==================================================

log_msg "--- 📦 FASE 1: Generando Backups Locales ---"

for CTID in "${LXC_LIST_TO_PROCESS[@]}"; do
    log_msg "🔹 Procesando CTID $CTID..."

    # 1. Apagado seguro
    if ! /usr/sbin/pct shutdown $CTID --timeout $TIMEOUT_SHUTDOWN; then
        /usr/sbin/pct stop $CTID
    fi

    # 2. Esperar apagado real
    WAITED=0
    while /usr/sbin/pct status $CTID | grep -q "status: running"; do
        if [ $WAITED -ge $TIMEOUT_WAIT_OFF ]; then
            /usr/sbin/pct stop $CTID
            break
        fi
        sleep $SLEEP_INTERVAL
        WAITED=$((WAITED + SLEEP_INTERVAL))
    done

    # 3. Ejecutar backup
    log_msg "💾 Ejecutando vzdump..."
    VZDUMP_OUTPUT=$(vzdump $CTID --dumpdir $BACKUP_DIR --mode $MODE --compress $COMPRESSION --prune-backups keep-last=$MAX_BACKUPS_LOCAL 2>&1)
    echo "$VZDUMP_OUTPUT" >> "$LOGFILE"

    # 4. DETECCIÓN DE ARCHIVO MEJORADA (FIX)
    # Buscamos el archivo más reciente que coincida con el patrón del CTID en la carpeta
    DETECTED_FILE=$(ls -1t "$BACKUP_DIR"/vzdump-*-$CTID-*.{tar.zst,tar.gz,tar} 2>/dev/null | head -n 1)
    
    if [ -n "$DETECTED_FILE" ] && [ -f "$DETECTED_FILE" ]; then
        # Verificamos que el archivo sea "fresco" (modificado en los últimos 5 minutos)
        # Esto evita detectar un backup viejo si el actual falló totalmente.
        FILE_TIME=$(stat -c %Y "$DETECTED_FILE")
        NOW_TIME=$(date +%s)
        DIFF_TIME=$((NOW_TIME - FILE_TIME))
        
        if [ $DIFF_TIME -lt 300 ]; then
            NEWLY_CREATED_FILES+=("$(basename "$DETECTED_FILE")")
            log_msg "🎉 Backup creado correctamente: $(basename "$DETECTED_FILE")"
        else
            log_msg "❌ ERROR: Se detectó un archivo, pero parece antiguo ($DIFF_TIME seg). Backup fallido."
        fi
    else
        log_msg "❌ ERROR: No se encontró el archivo de backup tras la ejecución."
        # Mostrar últimas líneas del log en pantalla para depuración rápida
        echo ""
        echo "⚠️ ULTIMAS LINEAS DE VZDUMP:"
        echo "$VZDUMP_OUTPUT" | tail -n 4
        echo ""
    fi

    # 5. Encender
    /usr/sbin/pct start $CTID
    sleep $SLEEP_INTERVAL
done

# ==================================================
# 6. SELECCIÓN DE ARCHIVOS PARA SUBIR (MENÚ 2)
# ==================================================

UPLOAD_FILES_TO_PROCESS=()

if [ ${#NEWLY_CREATED_FILES[@]} -eq 0 ]; then
    log_msg "ℹ️ No se detectaron archivos nuevos válidos para subir."

elif [ -t 0 ] && command -v "$WHIPTAIL_CMD" &>/dev/null; then

    UPLOAD_MENU_ITEMS=()
    
    UPLOAD_MENU_ITEMS+=(
        "ALL_UPLOAD"
        "Subir TODOS los archivos creados"
        "ON"
    )

    for FILE_NAME in "${NEWLY_CREATED_FILES[@]}"; do
        FILE_SIZE=$(du -h "$BACKUP_DIR/$FILE_NAME" | awk '{print $1}')
        UPLOAD_MENU_ITEMS+=(
            "$FILE_NAME"
            "Tamaño: $FILE_SIZE"
            "ON"
        )
    done

    SELECTION=$(show_checklist_menu \
        "SELECCIÓN DE SUBIDA A MEGA" \
        "Selecciona qué archivos subir." \
        "${UPLOAD_MENU_ITEMS[@]}"
    )
    
    if [ $? -eq 0 ]; then
        SELECTED_FILES=$(echo "$SELECTION" | tr -d '"')

        if echo "$SELECTED_FILES" | grep -q "ALL_UPLOAD"; then
            UPLOAD_FILES_TO_PROCESS=("${NEWLY_CREATED_FILES[@]}")
        else
            for SELECTED_FILE in $SELECTED_FILES; do
                if [ "$SELECTED_FILE" != "ALL_UPLOAD" ]; then
                    UPLOAD_FILES_TO_PROCESS+=("$SELECTED_FILE")
                fi
            done
        fi
    else
        log_msg "Subida cancelada por usuario."
    fi

else
    UPLOAD_FILES_TO_PROCESS=("${NEWLY_CREATED_FILES[@]}")
fi

# ==================================================
# 7. FASE 2: SUBIDA A MEGA
# ==================================================

log_msg "--- ☁️ FASE 2: Sincronización con MEGA ---"

if [ ${#UPLOAD_FILES_TO_PROCESS[@]} -gt 0 ]; then
    for BASENAME in "${UPLOAD_FILES_TO_PROCESS[@]}"; do
        FILE="$BACKUP_DIR/$BASENAME"
        LOCAL_ID=$(extract_id "$BASENAME")
        
        REMOTE_INFO=$($MEGA_CMD_LS -l "$REMOTE_DIR" | grep "$BASENAME") 
        
        if [ -n "$REMOTE_INFO" ]; then
            log_msg "⏭️ $BASENAME ya existe en remoto."
        else
            log_msg "⬆️ Subiendo: $BASENAME"
            if $MEGA_CMD_PUT "$FILE" "$REMOTE_DIR/" >> "$LOGFILE" 2>&1; then
                log_msg "✅ Subida OK."
            else
                log_msg "❌ ERROR Subida."
            fi
        fi
    done
fi

# ==================================================
# 8. FASE 3: LIMPIEZA REMOTA
# ==================================================

log_msg "--- 🧹 FASE 3: Limpieza Remota ---"

ALL_REMOTE_FILES=$($MEGA_CMD_LS "$REMOTE_DIR" | grep -E "vzdump-(lxc|qemu)-")

if [ -n "$ALL_REMOTE_FILES" ]; then
    UNIQUE_IDS=$(echo "$ALL_REMOTE_FILES" | grep -oE 'vzdump-(lxc|qemu)-\K[0-9]+' | sort -u)

    for CTID in $UNIQUE_IDS; do
        FILES_OF_ID=$(echo "$ALL_REMOTE_FILES" | grep -E "vzdump-(lxc|qemu)-${CTID}-" | sort -r)
        COUNT=$(echo "$FILES_OF_ID" | wc -l)
        
        if [ "$COUNT" -gt "$MAX_BACKUPS_REMOTE" ]; then
            log_msg "♻️ Limpiando CTID $CTID..."
            FILES_TO_DELETE=$(echo "$FILES_OF_ID" | tail -n +$(($MAX_BACKUPS_REMOTE + 1)))
            echo "$FILES_TO_DELETE" | while read OLD_BACKUP; do
                if [ -n "$OLD_BACKUP" ]; then
                    $MEGA_CMD_RM "$REMOTE_DIR/$OLD_BACKUP" >> "$LOGFILE" 2>&1
                    log_msg "🗑️ Borrado: $OLD_BACKUP"
                fi
            done
        fi
    done
fi

log_msg "🏁 PROCESO COMPLETO"
exit 0
