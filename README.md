# Web Server Backup Script

A comprehensive backup solution for web servers using Restic and AWS S3, with automatic database exports.

## Features

- Secure password management through configuration file
- Individual MySQL database exports with timestamps
- Restic backup to AWS S3
- Automatic cleanup of temporary SQL files
- Comprehensive logging
- Error handling with proper exit codes
- Automatic snapshot retention management

## Setup Instructions

### 1. Copy files to your server

Copy both `backup.sh` and `.backup-config` to your ploi user's home directory on your web server.

### 2. Configure passwords

Edit the `.backup-config` file and replace the placeholder values:

```bash
nano ~/.backup-config
```

Set your actual passwords:
- `RESTIC_PASSWORD`: Your restic repository password
- `MYSQL_PASSWORD`: Your MySQL password
- `MYSQL_USER`: Your MySQL user (defaults to 'root' if not set)

### 3. Set secure permissions

```bash
chmod 600 ~/.backup-config
chmod +x ~/backup.sh
```

### 4. Ensure exclude.txt exists

Make sure your `exclude.txt` file is in the ploi user's home directory.

### 5. Test the backup

Run a test backup:

```bash
./backup.sh
```

Check the log file for any issues:

```bash
tail -f ~/backup.log
```

## Automation

To run backups automatically, add to your crontab:

```bash
crontab -e
```

Add a line like this for daily backups at 2 AM:

```
0 2 * * * /home/ploi/backup.sh >> /home/ploi/backup.log 2>&1
```

## What the script does

1. **Loads configuration**: Reads passwords and settings from `.backup-config`
2. **Exports databases**: Creates individual SQL dumps for each user database
3. **Runs restic backup**: Backs up the entire home directory (including SQL files) to S3
4. **Cleans up**: Removes temporary SQL files from the home directory
5. **Manages snapshots**: Automatically removes old snapshots based on retention policy

## Retention Policy

The script automatically manages old snapshots:
- Keep daily snapshots for 7 days
- Keep weekly snapshots for 4 weeks
- Keep monthly snapshots for 6 months

## Security Notes

- The `.backup-config` file contains sensitive passwords and should have 600 permissions
- SQL files are automatically cleaned up after backup
- All operations are logged with timestamps
- The script uses `set -euo pipefail` for strict error handling

## Troubleshooting

- Check `~/backup.log` for detailed logs
- Ensure AWS credentials are properly configured
- Verify MySQL user and password are correct
- Make sure restic repository is initialized
- Check that `exclude.txt` exists in the home directory