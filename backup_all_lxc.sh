#!/bin/bash

# ==========================================
# CONFIGURACIÓN (VARIABLES EDITABLES)
# ==========================================

# Ruta donde se guardarán los backups
BACKUP_DIR="/raid1/storage/dump"

# Número de backups a mantener por contenedor
# vzdump se encargará de eliminar los más antiguos.
MAX_BACKUPS=1 

# Tiempos de espera (en segundos)
TIMEOUT_SHUTDOWN=30   # Tiempo para intentar apagado limpio
TIMEOUT_WAIT_OFF=10   # Tiempo extra de espera en el bucle
SLEEP_INTERVAL=5      # Intervalo entre comprobaciones

# Configuración de vzdump
COMPRESSION="zstd"    # Algoritmo: zstd, gzip, lzo
MODE="stop"           # Modo: stop, suspend, snapshot

# Lista de contenedores (Excluye ID 100 y la cabecera)
LXC_LIST=$(/usr/sbin/pct list | awk 'NR>1 && $1 != 100 {print $1}')

# ==========================================
# FIN DE CONFIGURACIÓN
# ==========================================

DATE=$(date +%Y-%m-%d_%H-%M-%S)

# Comprobación de seguridad: Crear directorio si no existe
if [ ! -d "$BACKUP_DIR" ]; then
    echo "⚠️ El directorio $BACKUP_DIR no existe. Creándolo..."
    mkdir -p "$BACKUP_DIR"
fi

echo "=== Inicio de backups: $DATE ==="
echo "📂 Directorio destino: $BACKUP_DIR"
echo "🗄️ Retención máxima por CTID: $MAX_BACKUPS"

for CTID in $LXC_LIST; do
    echo "-----------------------------"
    echo "📦 Iniciando backup para CTID $CTID..."

    echo "⏹️ Intentando apagar CTID $CTID (timeout ${TIMEOUT_SHUTDOWN}s)..."
    if ! /usr/sbin/pct shutdown $CTID --timeout $TIMEOUT_SHUTDOWN; then
        echo "❌ Apagado limpio falló, forzando apagado con pct stop..."
        /usr/sbin/pct stop $CTID
    fi

    echo "⏳ Esperando que CTID $CTID se apague..."
    WAITED=0
    
    # Bucle de espera
    while /usr/sbin/pct status $CTID | grep -q "status: running"; do
        if [ $WAITED -ge $TIMEOUT_WAIT_OFF ]; then
            echo "❌ CTID $CTID no se apagó tras $TIMEOUT_WAIT_OFF segundos. Forzando apagado..."
            /usr/sbin/pct stop $CTID
            break
        fi
        sleep $SLEEP_INTERVAL
        WAITED=$((WAITED + SLEEP_INTERVAL))
    done

    echo "💾 Realizando backup de CTID $CTID..."
    # Ejecución del backup con retención nativa:
    vzdump $CTID --dumpdir $BACKUP_DIR --mode $MODE --compress $COMPRESSION --prune-backups keep-last=$MAX_BACKUPS

    echo "🔄 Encendiendo CTID $CTID..."
    /usr/sbin/pct start $CTID
    sleep $SLEEP_INTERVAL

    echo "✅ Backup y limpieza completados para CTID $CTID (manteniendo $MAX_BACKUPS copias)."
done

echo "-----------------------------"
echo "✅ Todos los backups completados a las $(date +%H:%M:%S)"
