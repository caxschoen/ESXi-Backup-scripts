ESXi 6.7 hot/cold backup – with backup mode support
Features: check available storage, clean up snapshots, optional compression (gzip, zstd), 
SMART report, storage usage report, 
configuration via .conf file in the same directory with input parameters
Email message via SMTP (NetCat) via relay server, email parameters below 
Version: 0.16 from 9 December 2025, file: vmbup.sh

Installation:
Copy vmbup.sh in new directory (eg /scripts) on local backup disk
make executable
Create VM-Backup config files e.g. HAOS_01.conf
and configure paramters:

VMNAME="HAOS_OVA"
SOURCE="/vmfs/volumes/SSD960/HAOS_OVA"
#BACKUPBASE="/vmfs/volumes/HD1500BUP/test/HAOS"
BACKUPBASE="/vmfs/volumes/HD1500BUP/BUP_HAOS"
BACKUP_HOW="HOT"              # HOT/COLD
MAXKEEP=2                     # Anzahl Verzeichnisse die behalten werden = MAXKEEP +1
COMPRESSION="Z"               # Cpmpression mode: G=gzip, Z=zstd, N=no

If use zstd install zstd in /bin first

Run:
> ./vmbup.sh HAOS_01.conf

Run with cron:
add line to  /var/spool/cron/crontabs/cron (make changable!)
like:
0    1    *   *   2,5   /vmfs/volumes/HD1500BUP/scripts/vmbup.sh HAOS_01.conf >> /vmfs/volumes/HD1500BUP/scripts/vmbup.log 2>&1

Attention: 
cron file changes are not persistent - after VM-reboot lost 
=> special solution








