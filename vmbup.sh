#!/bin/sh
# =======================================================
# ESXi 6.7 Hot/Cold-Backup – mit Backup-Modus-Unterstützung
# Features: verfügbaren Speicher überprüfen, Snapshots bereinigen, optionale Kompression (gzip, zstd), 
# SMART-Report, Bericht Speicherbelegung, 
# Konfiguration über .conf Datei im gleichen Verzeichnis mit Inputparametern
# Mail Nachricht per SMTP (NetCat) über Relay Server, Mail Parameter weiter unten 
# Version: 0.16 vom 9.12.2025, Datei: vmbup.sh
# =======================================================

# Input Parameter - alternativ von CONFIG_FILE
#VMNAME="HAOS_OVA"
#SOURCE="/vmfs/volumes/SSD960/HAOS_OVA"
#BACKUPBASE="/vmfs/volumes/HD1500BUP/test/HAOS"
#BACKUP_HOW="COLD"             # HOT/COLD
#MAXKEEP=2                     # Anzahl Verzeichnisse die behalten werden = MAXKEEP +1
#COMPRESSION="G"               # G=gzip, Z=zstd, N=no

# =============================================
# PARSEN CONFIG_FILE auf Input Parameter, muss in gleichen Verzeichnis sein wie backup_vm.sh
# =============================================
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONFIG_FILE="$SCRIPT_DIR/$1"
if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    echo "Fehler: Keine gültige Config-Datei angegeben!"
    echo "Usage: $0 <config-file>"
    exit 1
fi

# Config laden
. "$CONFIG_FILE"

# Validierung
if [ -z "$VMNAME" ] || [ -z "$SOURCE" ] || [ -z "$BACKUPBASE" ]; then
    echo "Fehler: Pflichtparameter in Config fehlen!"
    exit 1
fi
# ENDE PARSEN

# =============================================
# Mail Parameter
# =============================================
MAIL_FROM="VMBackup@schoen-co.at"
MAIL_TO="cs@schoen-co.at"
SMTP_RELAY="192.168.1.8"
SMTP_PORT="25"

# =============================================
# Programm Parameter zum Start
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
START=$(date +%s)
TARGET="$BACKUPBASE/$TIMESTAMP"
SNAPSHOT_REMOVED=0
CLONE_EXIT=0
VM_WAS_RUNNING=0

# =============================================
# Programm Beginn
# =============================================
echo "================================================================================"
echo "$TIMESTAMP: $VMNAME Backup ($BACKUP_HOW) starten ==="

# =============================================
# a. VMID automatisch ermitteln
# =============================================
echo "Suche VM: $VMNAME..."
VMID=$(vim-cmd vmsvc/getallvms | awk -v name="$VMNAME" '$2 == name {print $1}')

if [ -z "$VMID" ]; then
    echo "=========================================="
    echo "FEHLER: VM '$VMNAME' nicht gefunden!"
    echo "=========================================="
    echo ""
    echo "Verfügbare VMs:"
    vim-cmd vmsvc/getallvms | tail -n +2 | awk '{printf "  ID: %-3s  Name: %s\n", $1, $2}'
    echo ""
    
    # Fehler-Mail senden
    SUBJ="$VMNAME Backup FEHLER - VM nicht gefunden - $(date +%Y%m%d_%H%M%S)"
    BODY="FEHLER: VM '$VMNAME' konnte nicht gefunden werden!\n\nBitte pruefen Sie den VM-Namen in der Konfiguration."
    ( printf "EHLO esxi\r\nMAIL FROM:<$MAIL_FROM>\r\nRCPT TO:<$MAIL_TO>\r\nDATA\r\nSubject: $SUBJ\r\n\r\n$BODY\r\n.\r\nQUIT\r\n" ) | nc -w 30 $SMTP_RELAY $SMTP_PORT >/dev/null 2>&1
    
    exit 1
fi

echo "VM gefunden: $VMNAME (ID: $VMID)"

# =============================================
# b. VM-Status prüfen (für Cold-Backup relevant)
# =============================================
VM_STATE=$(vim-cmd vmsvc/power.getstate $VMID 2>/dev/null | tail -1)
if echo "$VM_STATE" | grep -q "Powered on"; then
    VM_WAS_RUNNING=1
    echo "VM-Status: Laeuft (Powered on)"
else
    VM_WAS_RUNNING=0
    echo "VM-Status: Gestoppt (Powered off)"
fi

# =============================================
# 1. Vorhandene Snapshots entfernen
# =============================================
echo "Pruefe auf bestehende Snapshots..."
SNAPINFO=$(vim-cmd vmsvc/snapshot.get $VMID 2>/dev/null)
if echo "$SNAPINFO" | grep -q "Snapshot Name"; then
    echo "!!! Bestehende Snapshots gefunden - entferne alle..."
    vim-cmd vmsvc/snapshot.removeall $VMID
    esxcli vm process list | grep -q "$VMNAME" && vmkload_mod vmfs3 2>/dev/null
    sleep 2
    PRE_CLEAN="Alle alten Snapshots wurden vor dem Backup entfernt!"
else
    echo "Keine alten Snapshots vorhanden."
    PRE_CLEAN="Keine alten Snapshots vorhanden."
fi

# =============================================
# 2. Speicherplatz pruefen
# =============================================
echo "Pruefe verfuegbaren Speicherplatz auf Backup-Volume..."
VM_SIZE_MB=$(du -sm "$SOURCE" | awk '{print $1}')
FREE_MB=$(df -m "$BACKUPBASE" | tail -1 | awk '{print $4}')

VM_SIZE_GB=$(awk "BEGIN {printf \"%.1f\", $VM_SIZE_MB/1024}")
FREE_GB=$(awk "BEGIN {printf \"%.1f\", $FREE_MB/1024}")

echo "VM-Groesse ca.      : $VM_SIZE_MB MB (~$VM_SIZE_GB GB)"
echo "Freier Speicher     : $FREE_MB MB (~$FREE_GB GB)"

REQUIRED_MB=$(( VM_SIZE_MB * 15 / 10 ))
REQUIRED_GB=$(awk "BEGIN {printf \"%.1f\", $REQUIRED_MB/1024}")

if [ "$FREE_MB" -lt "$REQUIRED_MB" ]; then
    echo "!!! NICHT GENUG SPEICHERPLATZ! Erforderlich/frei: $REQUIRED_GB/$FREE_GB GB"
    SUBJ="$VMNAME Backup ABGEBROCHEN - kein Speicherplatz - $TIMESTAMP"
    BODY="FEHLER: Nicht genuegend Speicherplatz!\n\nVM-Groesse: $VM_SIZE_GB GB\nFreier Speicher: $FREE_GB GB\nBenoetigt: mind. $REQUIRED_GB GB"
    ( printf "EHLO esxi\r\nMAIL FROM:<$MAIL_FROM>\r\nRCPT TO:<$MAIL_TO>\r\nDATA\r\nSubject: $SUBJ\r\n\r\n$BODY\r\n.\r\nQUIT\r\n" ) | nc -w 30 $SMTP_RELAY $SMTP_PORT >/dev/null 2>&1
    exit 1
fi
echo "Speicherplatz ausreichend (benoetigt mit Reserve ~${REQUIRED_GB}GB, verfuegbar ${FREE_GB}GB)"
SPACE_INFO="VM-Groesse: $VM_SIZE_GB GB | Freier Speicher: $FREE_GB GB - OK"

# =============================================
# 3. BACKUP-MODUS: Hot oder Cold
# =============================================

if [ "$BACKUP_HOW" = "COLD" ]; then
    # ===== COLD BACKUP =====
    echo "=== COLD BACKUP MODUS ==="
    
    if [ $VM_WAS_RUNNING -eq 1 ]; then
        echo "Fahre VM herunter..."
        vim-cmd vmsvc/power.shutdown $VMID >/dev/null 2>&1
        
        # Warten bis VM heruntergefahren ist (max 5 Min)
        WAIT_COUNT=0
        while [ $WAIT_COUNT -lt 60 ]; do
            sleep 5
            WAIT_COUNT=$((WAIT_COUNT + 1))
            VM_STATE=$(vim-cmd vmsvc/power.getstate $VMID 2>/dev/null | tail -1)
            if echo "$VM_STATE" | grep -q "Powered off"; then
                echo "VM erfolgreich heruntergefahren (nach $((WAIT_COUNT * 5)) Sek)"
                break
            fi
        done
        
        # Falls Shutdown fehlschlägt: Hard Power Off
        VM_STATE=$(vim-cmd vmsvc/power.getstate $VMID 2>/dev/null | tail -1)
        if ! echo "$VM_STATE" | grep -q "Powered off"; then
            echo "WARNUNG: Graceful Shutdown fehlgeschlagen - erzwinge Power Off..."
            vim-cmd vmsvc/power.off $VMID >/dev/null 2>&1
            sleep 3
        fi
        
        BACKUP_MODE_INFO="Cold Backup: VM wurde heruntergefahren"
    else
        echo "VM ist bereits gestoppt - Cold Backup ohne Shutdown"
        BACKUP_MODE_INFO="Cold Backup: VM war bereits gestoppt"
    fi
    
    # Kein Snapshot bei Cold Backup
    SNAPSHOT_REQUIRED=0
    
else
    # ===== HOT BACKUP (Standard) =====
    echo "=== HOT BACKUP MODUS ==="
    
    if [ $VM_WAS_RUNNING -eq 0 ]; then
        echo "WARNUNG: VM läuft nicht - starte VM für Hot Backup..."
        vim-cmd vmsvc/power.on $VMID >/dev/null 2>&1
        sleep 10
        BACKUP_MODE_INFO="Hot Backup: VM wurde für Backup gestartet"
    else
        BACKUP_MODE_INFO="Hot Backup: VM läuft normal"
    fi
    
    # Snapshot erforderlich
    SNAPSHOT_REQUIRED=1
    
    echo "Lege Quiesced Snapshot an..."
    vim-cmd vmsvc/snapshot.create $VMID Backup-$TIMESTAMP "Hot-Backup" 0 1 >/dev/null 2>&1 || \
        vim-cmd vmsvc/snapshot.create $VMID Backup-$TIMESTAMP "Hot-Backup" 0 0 >/dev/null || \
        { echo "Snapshot konnte nicht angelegt werden!"; exit 1; }
    
    # Trap für sauberes Aufräumen bei Abbruch
    trap '[ $SNAPSHOT_REMOVED -eq 0 ] && { echo "!!! ABBRUCH - entferne Snapshot..."; vim-cmd vmsvc/snapshot.removeall $VMID >/dev/null 2>&1; }; exit 1' INT TERM EXIT
fi

# =============================================
# 4. Zielordner + Konfig kopieren
# =============================================
mkdir -p "$TARGET"
echo "Kopiere Konfig-Dateien..."
cp -a "$SOURCE"/*.vmx "$SOURCE"/*.vmxf "$SOURCE"/*.nvram "$TARGET"/ 2>/dev/null

# =============================================
# 5. Basis-Descriptor finden und Disk klonen
# =============================================
if [ "$SNAPSHOT_REQUIRED" -eq 1 ]; then
    # Hot Backup: Clone aus Snapshot
    BASE_DESCRIPTOR=$(ls "$SOURCE"/*.vmdk | grep -v -- "-flat.vmdk\|-delta.vmdk\|-00000[0-9]" | head -1)
else
    # Cold Backup: Direkt von Base-Disk
    BASE_DESCRIPTOR=$(ls "$SOURCE"/*.vmdk | grep -v -- "-flat.vmdk\|-delta.vmdk\|-00000[0-9]" | head -1)
fi

echo "Basis-Descriptor: $BASE_DESCRIPTOR"

if [ -z "$BASE_DESCRIPTOR" ]; then
    echo "FEHLER: Kein Basis-Descriptor gefunden!"
    CLONE_EXIT=99
else
    DEST_VMDK="$TARGET/${VMNAME}.vmdk"
    echo "Kopiere Disk nach $DEST_VMDK"
    rm -f "$DEST_VMDK" "$TARGET/${VMNAME}-flat.vmdk" 2>/dev/null
    vmkfstools -i "$BASE_DESCRIPTOR" "$DEST_VMDK" -d thin >/dev/null 2>&1
    CLONE_EXIT=$?
    
    if [ $CLONE_EXIT -eq 0 ]; then
        echo "  Disk erfolgreich geklont"
    else
        echo "  FEHLER beim Klonen der Disk (Exit-Code: $CLONE_EXIT)"
fi
fi

# =============================================
# 6. Snapshot entfernen (nur bei Hot Backup)
# =============================================
if [ "$SNAPSHOT_REQUIRED" -eq 1 ]; then
    echo "Entferne Backup-Snapshot..."
    vim-cmd vmsvc/snapshot.removeall $VMID 2>/dev/null
    SNAPSHOT_REMOVED=1
    trap - INT TERM EXIT
fi

# =============================================
# 7. VM wieder starten (falls Cold Backup und vorher lief)
# =============================================
if [ "$BACKUP_HOW" = "cold" ] && [ $VM_WAS_RUNNING -eq 1 ]; then
    echo "Starte VM wieder..."
    vim-cmd vmsvc/power.on $VMID >/dev/null 2>&1
    sleep 5
    VM_STATE=$(vim-cmd vmsvc/power.getstate $VMID 2>/dev/null | tail -1)
    if echo "$VM_STATE" | grep -q "Powered on"; then
        echo "VM erfolgreich gestartet"
        BACKUP_MODE_INFO="${BACKUP_MODE_INFO} und wieder gestartet"
    else
        echo "WARNUNG: VM konnte nicht automatisch gestartet werden!"
        BACKUP_MODE_INFO="${BACKUP_MODE_INFO} - WARNUNG: Neustart fehlgeschlagen!"
    fi
fi

# =============================================
# 8. Optional: Kompression
# =============================================
COMPRESS_INFO="Keine Kompression"
if [ "$COMPRESSION" = "G" ] && [ $CLONE_EXIT -eq 0 ] && [ -f "$TARGET/${VMNAME}-flat.vmdk" ]; then
    echo "Komprimiere Disk mit gzip..."
    gzip -v "$TARGET/${VMNAME}-flat.vmdk"
    [ $? -eq 0 ] && rm -f "$TARGET/${VMNAME}-flat.vmdk"
    
    if [ $? -eq 0 ] && [ -f "$TARGET/${VMNAME}-flat.vmdk.gz" ]; then
        COMPRESS_INFO="Disk mit gzip komprimiert - ${VMNAME}-flat.vmdk.gz"
        echo "gzip Kompression erfolgreich"
    else
        COMPRESS_INFO="FEHLER: gzip Kompression fehlgeschlagen"
        echo "FEHLER: gzip Kompression fehlgeschlagen"
    fi
fi    

if [ "$COMPRESSION" = "Z" ] && [ $CLONE_EXIT -eq 0 ] && [ -f "$TARGET/${VMNAME}-flat.vmdk" ]; then
    echo "Komprimiere Disk mit zstd..."
    zstd -6 -T1 "$TARGET/${VMNAME}-flat.vmdk" --rm     # ok=0 , Fehler=1
    
    if [ $? -eq 0 ] && [ -f "$TARGET/${VMNAME}-flat.vmdk.zst" ]; then
        COMPRESS_INFO="Disk mit zstd komprimiert - ${VMNAME}-flat.vmdk.zst"
        echo "zstd Kompression erfolgreich"
    else
        COMPRESS_INFO="FEHLER: zstd Kompression fehlgeschlagen"
        echo "FEHLER: zstd Kompression fehlgeschlagen"
    fi
fi

# =============================================
# 9. Alte Backups loeschen (>MAXKEEP+1)
# =============================================
cd "$BACKUPBASE" && ls -dt */ 2>/dev/null | tail -n +$((MAXKEEP+2)) | xargs -r rm -rf

# =============================================
# 10. SMART-Report (unverändert)
# =============================================
SMART_REPORT="SMART Status lokaler Datenspeicher:\n"
ALL_DEVS=$(esxcli storage core device list 2>/dev/null | grep -E "^[[:space:]]*(naa|mpx|t10|eui)" | awk '{print $1}')

if [ -z "$ALL_DEVS" ]; then
    SMART_REPORT="${SMART_REPORT}Keine Storage-Devices gefunden!\n\n"
else
    DEVICE_COUNT=0
    LOCAL_COUNT=0
    
    for dev in $ALL_DEVS; do
        DEVICE_COUNT=$((DEVICE_COUNT + 1))
        INFO=$(esxcli storage core device list -d "$dev" 2>/dev/null)
        
        if [ -z "$INFO" ]; then
            continue
        fi
        
        is_local=$(echo "$INFO" | grep -i "Is Local:" | grep -i "true")
        is_removable=$(echo "$INFO" | grep -i "Is Removable:" | grep -i "false")
        display_name=$(echo "$INFO" | grep "Display Name:" | sed 's/Display Name:[[:space:]]*//; s/[[:space:]]*$//')
        is_usb=$(echo "$display_name" | grep -iE "(usb|cd-rom|dvd)")
        
        if [ -n "$is_local" ] && [ -n "$is_removable" ] && [ -z "$is_usb" ]; then
            LOCAL_COUNT=$((LOCAL_COUNT + 1))
            
            model=$(echo "$INFO" | grep "^[[:space:]]*Model:" | sed 's/.*Model:[[:space:]]*//; s/[[:space:]]*$//')
            serial=$(echo "$INFO" | grep "^[[:space:]]*Serial Number:" | sed 's/.*Serial Number:[[:space:]]*//; s/[[:space:]]*$//')
            vendor=$(echo "$INFO" | grep "^[[:space:]]*Vendor:" | sed 's/.*Vendor:[[:space:]]*//; s/[[:space:]]*$//')
            size=$(echo "$INFO" | grep "^[[:space:]]*Size:" | awk '{print $2" "$3}')
            isssd=$(echo "$INFO" | grep -q "Is SSD: true" && echo "SSD" || echo "HDD")
            
            [ -z "$model" ] && model="Unknown"
            [ -z "$vendor" ] && vendor=""
            [ -z "$serial" ] && serial="N/A"
            [ -z "$size" ] && size="N/A"
            
            SMART=$(esxcli storage core device smart get -d "$dev" 2>/dev/null)
            
            if [ -n "$SMART" ]; then
                health=$(echo "$SMART" | awk '/Health Status/ {for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')
                temp=$(echo "$SMART" | awk '/Drive Temperature/ {print $3}')
                poweron=$(echo "$SMART" | awk '/Power On Hours/ {print $4}')
                
                [ -z "$health" ] && health="N/A"
                [ -z "$temp" ] && temp="N/A" || temp="${temp}°C"
                [ -z "$poweron" ] && poweron="N/A" || poweron="${poweron} h"
            else
                health="SMART nicht verfügbar"
                temp="N/A"
                poweron="N/A"
            fi
            
            SMART_REPORT="${SMART_REPORT}\n****************************************\n"
            SMART_REPORT="${SMART_REPORT}Device: ${dev}  [${isssd}]\n"
            [ -n "$vendor" ] && SMART_REPORT="${SMART_REPORT}Hersteller  : ${vendor}\n"
            SMART_REPORT="${SMART_REPORT}Modell      : ${model}\n"
            SMART_REPORT="${SMART_REPORT}Seriennr.   : ${serial}\n"
            SMART_REPORT="${SMART_REPORT}Kapazität   : ${size}\n"
            SMART_REPORT="${SMART_REPORT}----------------------------------------\n"
            SMART_REPORT="${SMART_REPORT}Health      : ${health}\n"
            SMART_REPORT="${SMART_REPORT}Temperatur  : ${temp}\n"
            SMART_REPORT="${SMART_REPORT}Laufzeit    : ${poweron}\n"
        fi
    done
    
    SMART_REPORT="${SMART_REPORT}\n****************************************\n"
    SMART_REPORT="${SMART_REPORT}Zusammenfassung: ${DEVICE_COUNT} Devices, ${LOCAL_COUNT} lokale Platten\n"
fi

SMART_REPORT="${SMART_REPORT}\n"

# =============================================
# 11. Backup-Verzeichnisse listen
# =============================================
BACKUP_LIST=""
for dir in $(ls -dt "$BACKUPBASE"/*/ 2>/dev/null | head -6); do
    folder=$(basename "$dir")
    size=$(du -sh "$dir" | awk '{print $1}')
    BACKUP_LIST="${BACKUP_LIST}  ${folder}  ${size}\n"
done

# =============================================
# 12. Statistik + Mail
# =============================================
END=$(date +%s)
DUR=$((END-START))
MIN=$((DUR/60))
SEC=$((DUR%60))

# Status ermitteln
[ $CLONE_EXIT -eq 0 ] && STATUS="ERFOLGREICH" || STATUS="FEHLGESCHLAGEN"
[ $CLONE_EXIT -eq 0 ] && SUBJ="$VMNAME Backup ERFOLGREICH - $TIMESTAMP" || SUBJ="$VMNAME Backup FEHLER - $TIMESTAMP"

# BACKUP_HOW in Uppercase (busybox-kompatibel)
# BACKUP_MODE=$(echo "$BACKUP_HOW" | tr '[:lower:]' '[:upper:]')
BACKUP_MODE=$(echo "$BACKUP_HOW" | awk '{print toupper($0)}')

# Startzeit formatieren (ESXi 6.7 kompatibel)
START_TIME=$(date -d "@$START" '+%d.%m.%Y %H:%M:%S' 2>/dev/null)
if [ -z "$START_TIME" ]; then
    # Fallback wenn -d nicht funktioniert
    START_TIME=$(date '+%d.%m.%Y %H:%M:%S')
fi

# Mail Body zusammenstellen
BODY="$VMNAME ${BACKUP_MODE} Backup $STATUS

$BACKUP_MODE_INFO
$PRE_CLEAN
$SPACE_INFO

Start        : ${START_TIME}
Dauer        : ${MIN} Min ${SEC} Sek
Zielordner   : $TARGET
Backup-Groesse: $(du -sh "$TARGET" 2>/dev/null | cut -f1)

$COMPRESS_INFO

Backups im Verzeichnis/Groesse:
$BACKUP_LIST

$SMART_REPORT
"

echo "Sende Mail..."
( printf "EHLO esxi\r\nMAIL FROM:<$MAIL_FROM>\r\nRCPT TO:<$MAIL_TO>\r\nDATA\r\nSubject: $SUBJ\r\n\r\n$BODY\r\n.\r\nQUIT\r\n" ) | nc -i 1 -w 30 $SMTP_RELAY $SMTP_PORT >/dev/null 2>&1 && echo "Mail gesendet" || echo "Mail fehlgeschlagen"

echo "Laufzeit: ${MIN} Min ${SEC} Sek"
echo "=== Backup $VMNAME fertig ($STATUS) ==="
exit $CLONE_EXIT
