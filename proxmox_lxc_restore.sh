#!/bin/bash

# ==================================================
# 1. CONFIGURACIÓN
# ==================================================

LOCAL_DIR="/raid1/storage/dump"       # Donde se descargarán los ficheros
REMOTE_DIR="/proxmox/dump"            # Ruta en MEGA donde buscar
LOGFILE="/var/log/proxmox_restore.log"

# Comandos
WHIPTAIL_CMD="whiptail"
MEGA_CMD_GET="mega-get"
MEGA_CMD_LS="mega-ls"
MEGA_CMD_WHO="mega-whoami"
MEGA_CMD_LOGIN="mega-login"

# ==================================================
# 2. FUNCIONES DE SOPORTE
# ==================================================

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

error_exit() {
    log_msg "❌ ERROR CRÍTICO: $1"
    if [ -t 0 ]; then
        "$WHIPTAIL_CMD" --title "Error Crítico" --msgbox "$1" 10 60
    fi
    exit 1
}

# Función para extraer ID del nombre del fichero
extract_id() {
    echo "$1" | grep -oE 'vzdump-(lxc|qemu)-[0-9]+-' | grep -oE '[0-9]+'
}

# ==================================================
# 3. INICIO Y VERIFICACIONES
# ==================================================

if [ ! -d "$LOCAL_DIR" ]; then
    mkdir -p "$LOCAL_DIR"
fi

# Verificar whiptail
if ! command -v "$WHIPTAIL_CMD" &>/dev/null; then
    echo "Este script requiere 'whiptail'. Instálalo con: apt install whiptail -y"
    exit 1
fi

# Verificar MEGA Login
if ! $MEGA_CMD_WHO >/dev/null 2>&1; then
    $WHIPTAIL_CMD --title "Mega Login Requerido" --inputbox "Introduce tu Email de MEGA:" 10 60 2>email_temp
    MEGA_EMAIL=$(cat email_temp)
    rm email_temp
    
    $WHIPTAIL_CMD --title "Mega Login Requerido" --passwordbox "Introduce tu Contraseña:" 10 60 2>pass_temp
    MEGA_PASS=$(cat pass_temp)
    rm pass_temp
    
    if ! $MEGA_CMD_LOGIN "$MEGA_EMAIL" "$MEGA_PASS"; then
        error_exit "Login fallido en MEGA."
    fi
fi

# ==================================================
# 4. FASE 1: DESCARGAR DE MEGA (Opcional)
# ==================================================

if $WHIPTAIL_CMD --title "Fase 1: Descarga" --yesno "¿Quieres descargar backups desde MEGA?\n(Si ya tienes el fichero en local, elige No)" 10 60; then
    
    log_msg "Listando archivos en MEGA..."
    
    # Obtener lista de archivos remotos y formatear para whiptail
    # Formato mega-ls -l: TAMAÑO FECHA HORA NOMBRE
    # Usamos un truco para leer línea a línea y crear array
    REMOTE_FILES_MENU=()
    
    while read -r LINE; do
        # Asumimos que el nombre es la última columna y el tamaño la primera (ajustar según salida de mega-ls)
        FILENAME=$(echo "$LINE" | awk '{print $NF}')
        SIZE=$(echo "$LINE" | awk '{print $1}') # A veces mega-ls devuelve cosas raras, ten cuidado
        
        # Filtramos solo archivos válidos
        if [[ "$FILENAME" == *"vzdump"* ]]; then
            REMOTE_FILES_MENU+=( "$FILENAME" "Remoto ($SIZE)" "OFF" )
        fi
    done < <($MEGA_CMD_LS -l "$REMOTE_DIR" | grep "vzdump")

    if [ ${#REMOTE_FILES_MENU[@]} -eq 0 ]; then
        $WHIPTAIL_CMD --msgbox "No se encontraron backups en $REMOTE_DIR" 10 60
    else
        SELECTION=$($WHIPTAIL_CMD --title "Selección de Descarga" --checklist "Elige qué archivos descargar a $LOCAL_DIR" 20 78 10 "${REMOTE_FILES_MENU[@]}" 3>&1 1>&2 2>&3)
        
        if [ $? -eq 0 ]; then
            FILES_TO_DOWNLOAD=$(echo "$SELECTION" | tr -d '"')
            for FILE in $FILES_TO_DOWNLOAD; do
                LOCAL_PATH="$LOCAL_DIR/$FILE"
                if [ -f "$LOCAL_PATH" ]; then
                    log_msg "⚠️ El archivo $FILE ya existe en local. Saltando."
                else
                    log_msg "⬇️ Descargando $FILE..."
                    # Mostrar progreso simple (mega-get no tiene barra compatible con whiptail fácil)
                    echo "Descargando $FILE... Por favor espere."
                    if $MEGA_CMD_GET "$REMOTE_DIR/$FILE" "$LOCAL_DIR/"; then
                        log_msg "✅ Descarga completada: $FILE"
                    else
                        log_msg "❌ Error descargando $FILE"
                        $WHIPTAIL_CMD --msgbox "Error descargando $FILE" 10 60
                    fi
                fi
            done
            $WHIPTAIL_CMD --msgbox "Proceso de descarga finalizado." 10 60
        fi
    fi
fi

# ==================================================
# 5. FASE 2: RESTAURACIÓN (PCT RESTORE)
# ==================================================

# Escanear archivos locales
LOCAL_FILES_MENU=()
while read -r FILE; do
    FILENAME=$(basename "$FILE")
    SIZE=$(du -h "$FILE" | awk '{print $1}')
    LOCAL_FILES_MENU+=( "$FILENAME" "Local ($SIZE)" "OFF" )
done < <(find "$LOCAL_DIR" -maxdepth 1 -type f \( -name "*.tar" -o -name "*.tar.zst" -o -name "*.tar.gz" \) | sort)

if [ ${#LOCAL_FILES_MENU[@]} -eq 0 ]; then
    error_exit "No hay archivos de backup en $LOCAL_DIR para restaurar."
fi

SELECTION_RESTORE=$($WHIPTAIL_CMD --title "Selección de Restauración" --checklist "Elige qué archivo(s) quieres RESTAURAR en Proxmox:" 20 78 10 "${LOCAL_FILES_MENU[@]}" 3>&1 1>&2 2>&3)

if [ $? -ne 0 ]; then
    log_msg "Restauración cancelada por usuario."
    exit 0
fi

FILES_TO_RESTORE=$(echo "$SELECTION_RESTORE" | tr -d '"')

# --------------------------------------------------
# WIZARD DE RESTAURACIÓN POR CADA ARCHIVO
# --------------------------------------------------

# Obtener lista de Almacenamientos disponibles (Storage)
# pvesm status imprime: Name Type Status ...
# Filtramos solo los que están 'active' y guardamos en array para menú
STORAGE_MENU=()
while read -r STORAGE TYPE; do
    STORAGE_MENU+=( "$STORAGE" "Tipo: $TYPE" "OFF" )
done < <(pvesm status | awk '$3 == "active" {print $1, $2}' | grep -v "Name")


for FILE in $FILES_TO_RESTORE; do
    ORIGINAL_ID=$(extract_id "$FILE")
    FULL_PATH="$LOCAL_DIR/$FILE"
    
    # 1. Definir ID Destino
    NEW_ID=$($WHIPTAIL_CMD --title "Configurar Restauración para $FILE" --inputbox "El ID original es $ORIGINAL_ID.\n\nIntroduce el ID para el nuevo contenedor:" 12 60 "$ORIGINAL_ID" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then continue; fi # Si cancela, salta al siguiente archivo

    # Comprobar si el ID ya existe
    if pct status "$NEW_ID" &>/dev/null; then
        if ! $WHIPTAIL_CMD --title "⚠️ CONFLICTO DE ID" --yesno "El contenedor $NEW_ID YA EXISTE.\n\n¿Quieres SOBRESCRIBIRLO? (Se borrarán todos los datos actuales del CT $NEW_ID)" 12 60; then
            log_msg "Restauración de $FILE cancelada (ID $NEW_ID existía y usuario dijo NO)."
            continue
        fi
        FORCE_FLAG="--force" # Necesario para sobrescribir
        ACTION="SOBRESCRIBIR"
    else
        FORCE_FLAG=""
        ACTION="CREAR"
    fi

    # 2. Elegir Almacenamiento (Storage)
    TARGET_STORAGE=$($WHIPTAIL_CMD --title "Almacenamiento" --radiolist "Selecciona el disco destino para $NEW_ID:" 15 60 5 "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3 | tr -d '"')
    
    if [ -z "$TARGET_STORAGE" ]; then
        $WHIPTAIL_CMD --msgbox "No seleccionaste almacenamiento. Saltando." 10 60
        continue
    fi

    # 3. Confirmación final
    if $WHIPTAIL_CMD --title "Confirmar Restauración" --yesno "Resumen:\n\n- Archivo: $FILE\n- ID Destino: $NEW_ID ($ACTION)\n- Storage: $TARGET_STORAGE\n\n¿Proceder?" 15 60; then
        
        # Limpiar pantalla para ver output de pct
        clear
        echo "==============================================="
        echo "🚀 Restaurando $NEW_ID en $TARGET_STORAGE..."
        echo "==============================================="
        log_msg "Iniciando restauración: $FILE -> CT $NEW_ID en $TARGET_STORAGE"

        # --- EJECUCIÓN DEL RESTORE ---
        # Si existe y vamos a sobrescribir, a veces es mas limpio pararlo y destruirlo antes,
        # pero pct restore --force suele manejarlo. Por seguridad paramos si corre.
        if [ "$FORCE_FLAG" == "--force" ]; then
             pct stop "$NEW_ID" &>/dev/null
             # pct destroy "$NEW_ID" &>/dev/null # Opcional: destrucción manual
        fi

        if pct restore "$NEW_ID" "$FULL_PATH" --storage "$TARGET_STORAGE" $FORCE_FLAG; then
            log_msg "✅ Restauración exitosa: CT $NEW_ID"
            
            # Preguntar si encender
            if $WHIPTAIL_CMD --title "Éxito" --yesno "El contenedor $NEW_ID se ha restaurado correctamente.\n\n¿Quieres encenderlo ahora?" 10 60; then
                pct start "$NEW_ID"
                $WHIPTAIL_CMD --msgbox "Contenedor $NEW_ID encendido." 8 40
            fi
        else
            log_msg "❌ Error al restaurar CT $NEW_ID"
            echo ""
            echo "Presiona Enter para continuar..."
            read
        fi
    else
        log_msg "Cancelado por usuario en confirmación final."
    fi

done

clear
echo "🏁 Proceso de restauración finalizado."
log_msg "=== FIN WIZARD RESTORE ==="
