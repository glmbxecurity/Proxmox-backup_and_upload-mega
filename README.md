# 🛡️ Proxmox to MEGA - Ultimate Backup & Restore Suite

**Una suite completa, interactiva y automatizada para gestionar el ciclo de vida de tus backups en Proxmox VE sincronizados con la nube de MEGA.nz.**

Este proyecto consta de dos potentes scripts en Bash diseñados para administradores de sistemas que buscan simplicidad y robustez. Olvídate de configuraciones complejas; utiliza menús visuales (tipo wizard) para seleccionar qué respaldar y qué restaurar, o deja que el sistema trabaje solo por las noches.

---

## 🚀 Características Principales

### 📦 Backup All-in-One (`backup_lxc_aio.sh`)
* **Menú asistente:**
    * **Interactivo:** Muestra menús visuales (`whiptail`) para seleccionar contenedores específicos y decidir qué contenedores respaldar.
    * **Automático (Cron):** Si se ejecuta programado, detecta la falta de usuario y respalda/sube **TODO** automáticamente sin intervención.
* **Gestión de energía :** Apaga los contenedores (LXC) ordenadamente, realiza el backup y los vuelve a encender inmediatamente para minimizar el tiempo de inactividad.
* **Detección Robusta:** Verifica que el archivo de backup se haya creado correctamente antes de intentar subirlo, buscando el archivo más reciente generado para ese ID.
* **Rotación (Prune) Doble:**
    * **Local:** Mantiene solo los últimos *N* backups en el disco del servidor.
    * **Nube:** Elimina automáticamente los backups antiguos en MEGA respetando tu límite configurado.
* **Login Persistente/Interactivo:** Si la sesión de MEGA expira, solicita credenciales al momento para continuar.

### 🚑 Restore Wizard (`restore_wizard.sh`)
* **Asistente Paso a Paso:** Interfaz gráfica en terminal para guiarte en todo el proceso.
* **Explorador de Nube:** Lista los backups disponibles en tu cuenta de MEGA y permite descargarlos selectivamente si no los tienes en local.
* **Gestión de Conflictos:**
    * Detecta si el ID de contenedor ya existe en tu sistema.
    * Permite definir un **Nuevo ID** (para no sobrescribir) o mantener el original.
    * **Seguridad:** Si decides sobrescribir, solicita confirmación explícita.
* **Selector de Almacenamiento:** Escanea tus discos (`local-lvm`, `zfs`, `nfs`, etc.) y te permite elegir dónde restaurar el contenedor.

---

## ⚙️ Requisitos Previos

1.  **Proxmox VE** (Compatible con versiones 7.x y 8.x).
2.  **Paquetes necesarios:**
    Debes tener `whiptail` instalado para los menús visuales.
    ```bash
    apt update && apt install whiptail -y
    ```
3.  **MEGAcmd (Cliente oficial):**
    Debes tener instalado `megacmd` en tu servidor.
    ```bash
    # Ejemplo para Debian/Proxmox (consulta la web oficial de MEGA para tu versión exacta)
    wget [https://mega.nz/linux/repo/xUbuntu_22.04/amd64/megacmd-xUbuntu_22.04_amd64.deb](https://mega.nz/linux/repo/xUbuntu_22.04/amd64/megacmd-xUbuntu_22.04_amd64.deb)
    apt install ./megacmd-*.deb
    ```

---

## 📥 Instalación

1.  Clona este repositorio o descarga los scripts en tu servidor (por ejemplo, en `/root/scripts/`).
2.  Dales permisos de ejecución:
    ```bash
    chmod +x proxmox_lxc_backup.sh proxmox_lxc_restore.sh
    ```

---

## 🔧 Configuración (Variables Editables)

Abre los scripts con `nano` o `vim` y ajusta la cabecera según tu entorno. Las variables son comunes en ambos scripts para facilitar la gestión.

| Variable | Descripción | Ejemplo |
| :--- | :--- | :--- |
| `BACKUP_DIR` / `LOCAL_DIR` | Carpeta local temporal para guardar/descargar backups. | `/raid1/storage/dump` |
| `REMOTE_DIR` | Carpeta en tu nube de MEGA. | `/proxmox/dump` |
| `MAX_BACKUPS_LOCAL` | Cuántos backups mantener en el disco del servidor. | `1` |
| `MAX_BACKUPS_REMOTE` | Cuántos backups mantener en la nube MEGA. | `3` |
| `COMPRESSION` | Algoritmo de compresión de Proxmox. | `zstd` (recomendado), `gzip` |
| `MODE` | Modo de backup (`stop` es el más seguro). | `stop`, `snapshot`, `suspend` |
| `LOGFILE` | Ruta donde se guarda el historial de operaciones. | `/var/log/proxmox_full_backup.log` |

---

## 🖥️ Uso: Script de Backup (`backup_lxc_aio.sh`)

### Modo Manual (Interactivo)
Ejecútalo directamente en tu terminal:
```bash
./proxmox_lxc_backup.sh
```
1.  Aparecerá un menú para **seleccionar los contenedores** (Space para marcar, Enter para confirmar). Puedes marcar `ALL_IDS` para seleccionarlos todos.
2.  El script realizará los backups locales (apagando y encendiendo cada CT).
3.  Si se generan archivos correctamente, aparecerá un segundo menú para **seleccionar qué subir a MEGA**.
4.  Finalmente, realizará la limpieza de versiones antiguas en la nube.

### Modo Automático (Cron)
Ideal para copias nocturnas desatendidas. Añádelo a tu crontab:
```bash
crontab -e
```
Añade la siguiente línea para ejecutarlo todos los días a las 04:00 AM:
```bash
0 4 * * * /ruta/a/tus/scripts/backup_lxc_aio.sh >/dev/null 2>&1
```
> **Nota:** En modo Cron, el script asume automáticamente la selección **ALL** (respalda todo y sube todo). Si no hay sesión de MEGA iniciada, el script fallará y registrará el error en el log, ya que no hay usuario presente para introducir la contraseña.

---

## 🚑 Uso: Script de Restauración (`proxmox_lxc_restore.sh`)

Este script es **exclusivamente interactivo**. Úsalo cuando necesites recuperar datos ante un desastre o migración.

```bash
./proxmox_lxc_restore.sh
```

**Flujo del Asistente:**
1.  **Login Check:** Si no estás logueado, te pedirá credenciales de MEGA en una ventana segura.
2.  **Descarga (Opcional):** Te preguntará si quieres descargar backups desde la nube. Si dices SÍ, te mostrará una lista de archivos en MEGA para elegir.
3.  **Selección Local:** Te mostrará todos los backups disponibles en tu carpeta local (`BACKUP_DIR`).
4.  **Configuración de Restauración (Wizard por archivo):**
    * Te mostrará el ID original del backup.
    * Te permitirá definir un **Nuevo ID** (para no sobrescribir el actual) o mantener el original.
    * **Alerta de Conflicto:** Si el ID destino ya existe en Proxmox, te avisará y pedirá confirmación explícita para sobrescribir.
    * **Selector de Disco:** Escanea tus almacenamientos (`local`, `raid`, `zfs`, etc.) y te permite elegir dónde restaurar.
5.  **Ejecución:** Restaurará el contenedor y te preguntará si quieres encenderlo al finalizar.

---

## 📝 Logs y Depuración

Toda la actividad queda registrada con fecha y hora. Si algo falla, revisa el log:

```bash
tail -f /var/log/proxmox_full_backup.log
```
* El log incluye tiempos de ejecución, salida detallada de `vzdump`, errores de subida y confirmaciones de limpieza.

---

## ⚠️ Aviso

El uso de estos scripts implica operaciones críticas como el apagado de servicios y la posible sobrescritura de datos (en el caso del restore).
* **Prueba siempre la restauración** en un entorno seguro antes de confiar ciegamente en los backups.
* Asegúrate de que tu servidor tiene espacio suficiente en disco para los backups temporales.

---
