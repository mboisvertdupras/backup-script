#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.backup-config"
LOG_FILE="$HOME/backup.log"
BACKUP_DATE=$(date +"%Y-%m-%d_%H-%M-%S")

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
  log "ERROR: $1"
  exit 1
}

cleanup_sql_files() {
  log "Cleaning up SQL files..."
  find "$HOME" -maxdepth 1 -name "*.sql" -type f -delete 2>/dev/null || true
  log "SQL files cleaned up"
}

log "Starting backup process - $BACKUP_DATE"

if [[ ! -f "$CONFIG_FILE" ]]; then
  error_exit "Configuration file not found: $CONFIG_FILE"
fi

source "$CONFIG_FILE"

if [[ -z "${RESTIC_PASSWORD:-}" ]]; then
  error_exit "RESTIC_PASSWORD not set in configuration file"
fi

if [[ -z "${MYSQL_PASSWORD:-}" ]]; then
  error_exit "MYSQL_PASSWORD not set in configuration file"
fi
if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
  error_exit "RESTIC_REPOSITORY not set in configuration file"
fi

# Set default MySQL user if not specified
MYSQL_USER="${MYSQL_USER:-root}"

log "Configuration loaded successfully"

log "Exporting databases..."

DATABASES=$(mysql -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SHOW DATABASES;" | grep -Ev "^(Database|information_schema|performance_schema|mysql|sys)$" || true)

if [[ -z "$DATABASES" ]]; then
  log "No user databases found to backup"
else
  for db in $DATABASES; do
    log "Exporting database: $db"
    mysqldump -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
      --single-transaction \
      --routines \
      --triggers \
      --events \
      --hex-blob \
      "$db" >"$HOME/${db}_${BACKUP_DATE}.sql" || error_exit "Failed to export database: $db"
    log "Database $db exported successfully"
  done
fi

log "Starting restic backup..."

cd "$HOME" || error_exit "Failed to change to home directory"

if [[ ! -f "exclude.txt" ]]; then
  log "WARNING: exclude.txt file not found in $HOME"
fi

restic -r "$RESTIC_REPOSITORY" backup . \
  --exclude-file=exclude.txt \
  --tag "automated-backup" \
  --tag "date-$BACKUP_DATE" || error_exit "Restic backup failed"

log "Restic backup completed successfully"

log "Running restic forget to clean up old snapshots..."
restic -r "$RESTIC_REPOSITORY" forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --prune || log "WARNING: Failed to clean up old snapshots"

cleanup_sql_files

log "Backup process completed successfully - $BACKUP_DATE"

