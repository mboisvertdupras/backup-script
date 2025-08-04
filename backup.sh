#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.backup_config"
LOG_FILE="$HOME/backup.log"
BACKUP_DATE=$(date +"%Y-%m-%d_%H-%M-%S")

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$$] $1" | tee -a "$LOG_FILE"
}

log_debug() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$$] DEBUG: $1" >>"$LOG_FILE"
}

log_command() {
  local cmd="$1"
  local description="$2"
  log "Starting: $description"
  log_debug "Command: $cmd"
  local output
  if output=$(eval "$cmd" 2>&1); then
    log_debug "Command succeeded: $description"
    if [[ -n "$output" ]]; then
      log_debug "Command output: $output"
    fi
    return 0
  else
    local exit_code=$?
    log "ERROR: Command failed: $description (exit code: $exit_code)"
    log_debug "Command: $cmd"
    log_debug "Error output: $output"
    return $exit_code
  fi
}

error_exit() {
  log "ERROR: $1"
  exit 1
}

cleanup_sql_files() {
  log "Cleaning up SQL files..."
  local sql_files
  sql_files=$(find "$HOME" -maxdepth 1 -name "*.sql" -type f 2>/dev/null || true)
  if [[ -n "$sql_files" ]]; then
    log_debug "SQL files to cleanup:"
    log_debug "$sql_files"
    echo "$sql_files" | while read -r file; do
      if [[ -n "$file" ]]; then
        log_debug "Deleting: $file (size: $(du -h "$file" 2>/dev/null || echo 'unknown'))"
        rm -f "$file" 2>/dev/null || log_debug "Failed to delete: $file"
      fi
    done
    log "SQL files cleaned up"
  else
    log_debug "No SQL files found to cleanup"
  fi
}

# Set up trap to cleanup on exit
trap cleanup_sql_files EXIT

log "Starting backup process - $BACKUP_DATE"

log_debug "=== ENVIRONMENT DEBUG INFO ==="
log_debug "Script directory: $SCRIPT_DIR"
log_debug "Config file: $CONFIG_FILE"
log_debug "Log file: $LOG_FILE"
log_debug "Current user: $(whoami)"
log_debug "Current directory: $(pwd)"
log_debug "Shell: $SHELL"
log_debug "PATH: $PATH"
log_debug "Home directory: $HOME"
log_debug "Backup date: $BACKUP_DATE"
log_debug "Process ID: $$"
log_debug "Parent process ID: $PPID"
log_debug "Command line: $0 $*"
log_debug "=== END ENVIRONMENT DEBUG INFO ==="

if [[ ! -f "$CONFIG_FILE" ]]; then
  error_exit "Configuration file not found: $CONFIG_FILE"
fi

log_debug "Loading configuration file: $CONFIG_FILE"
if source "$CONFIG_FILE"; then
  log_debug "Configuration file loaded successfully"
else
  error_exit "Failed to load configuration file: $CONFIG_FILE"
fi

if [[ -z "${RESTIC_PASSWORD:-}" ]]; then
  error_exit "RESTIC_PASSWORD not set in configuration file"
else
  log_debug "RESTIC_PASSWORD is set (length: ${#RESTIC_PASSWORD})"
fi

if [[ -z "${MYSQL_PASSWORD:-}" ]]; then
  error_exit "MYSQL_PASSWORD not set in configuration file"
else
  log_debug "MYSQL_PASSWORD is set (length: ${#MYSQL_PASSWORD})"
fi

if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
  error_exit "RESTIC_REPOSITORY not set in configuration file"
else
  log_debug "RESTIC_REPOSITORY: $RESTIC_REPOSITORY"
fi

# Set default MySQL user if not specified
MYSQL_USER="${MYSQL_USER:-root}"
log_debug "MYSQL_USER: $MYSQL_USER"

log_debug "Checking required commands..."
for cmd in mysql mysqldump restic; do
  if command -v "$cmd" >/dev/null 2>&1; then
    log_debug "$cmd found: $(command -v "$cmd")"
  else
    error_exit "Required command not found: $cmd"
  fi
done

log "Configuration loaded successfully"

log "Exporting databases..."

log "Starting: Listing databases"
log_debug "Command: mysql -u $MYSQL_USER -p[REDACTED] -e \"SHOW DATABASES;\""
DATABASES=$(mysql -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SHOW DATABASES;" | grep -Ev "^(Database|information_schema|performance_schema|mysql|sys)$" || true)
if [[ $? -eq 0 ]]; then
  log_debug "Command succeeded: Listing databases"
else
  log "ERROR: Command failed: Listing databases"
fi

log_debug "Found databases: $DATABASES"

if [[ -z "$DATABASES" ]]; then
  log "No user databases found to backup"
else
  for db in $DATABASES; do
    log "Exporting database: $db"
     sql_file="$HOME/${db}_${BACKUP_DATE}.sql"    log_debug "Output file: $sql_file"

    log "Starting: Exporting database: $db"
    log_debug "Command: mysqldump -u $MYSQL_USER -p[REDACTED] --single-transaction --routines --triggers --events --hex-blob $db > $sql_file"
    if mysqldump -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
      --single-transaction \
      --routines \
      --triggers \
      --events \
      --hex-blob \
      "$db" >"$sql_file"; then
      log "Database $db exported successfully"
      log_debug "SQL file size: $(du -h "$sql_file" 2>/dev/null || echo 'unknown')"
    else
      local exit_code=$?
      log "ERROR: Failed to export database: $db (exit code: $exit_code)"
      log_debug "SQL file size after failed export: $(du -h "$sql_file" 2>/dev/null || echo 'unknown')"
      error_exit "Failed to export database: $db"
    fi
  done
fi

log "Starting restic backup..."

log_debug "Changing to home directory: $HOME"
if cd "$HOME"; then
  log_debug "Successfully changed to home directory"
  log_debug "Current directory: $(pwd)"
else
  error_exit "Failed to change to home directory: $HOME"
fi

# List SQL files before backup
log_debug "SQL files in home directory before backup:"
find "$HOME" -maxdepth 1 -name "*.sql" -type f -exec ls -la {} \; 2>/dev/null || log_debug "No SQL files found"

log_debug "Checking for exclude.txt file in home directory"
if [[ ! -f "exclude.txt" ]]; then
  log "WARNING: exclude.txt file not found in $HOME"
else
  log_debug "exclude.txt found, contents:"
  log_debug "$(cat exclude.txt)"
fi

log_debug "Restic repository: $RESTIC_REPOSITORY"
log_debug "Checking restic version..."
if restic_version=$(restic version 2>&1); then
  log_debug "Restic version: $restic_version"
else
  log_debug "Could not determine restic version"
fi

log "Starting: Restic backup"
log_debug "Command: restic -r $RESTIC_REPOSITORY backup . --exclude-file=exclude.txt --tag automated-backup --tag date-$BACKUP_DATE"
if restic -r "$RESTIC_REPOSITORY" backup . \
  --exclude-file=exclude.txt \
  --tag "automated-backup" \
  --tag "date-$BACKUP_DATE"; then
  log "Restic backup completed successfully"

  # List SQL files after successful backup
  log_debug "SQL files in home directory after backup:"
  find "$HOME" -maxdepth 1 -name "*.sql" -type f -exec ls -la {} \; 2>/dev/null || log_debug "No SQL files found"
else
  local exit_code=$?
  log "ERROR: Restic backup failed (exit code: $exit_code) - SQL files will be cleaned up by trap"
  error_exit "Restic backup failed"
fi

log "Running restic forget to clean up old snapshots..."
log "Starting: Cleaning up old snapshots"
log_debug "Command: restic -r $RESTIC_REPOSITORY forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune"
if restic -r "$RESTIC_REPOSITORY" forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --prune; then
  log "Old snapshots cleaned up successfully"
else
  local exit_code=$?
  log "WARNING: Failed to clean up old snapshots (exit code: $exit_code)"
fi

# Note: cleanup_sql_files will be called by the trap on exit
log_debug "Final cleanup will be handled by exit trap"

log_debug "=== FINAL STATUS ==="
log_debug "End time: $(date '+%Y-%m-%d %H:%M:%S')"
log_debug "=== END FINAL STATUS ==="

log "Backup process completed successfully - $BACKUP_DATE"
