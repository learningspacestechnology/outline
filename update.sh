#!/bin/bash
set -e
BACKUP_DIR="/home/lstadmin/outline/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

echo "==> Dumping Postgres before update..."
docker exec postgres pg_dump -U outlinedbadmin outlinedb > "$BACKUP_DIR/pre-update-$TIMESTAMP.sql"
echo "    Saved to $BACKUP_DIR/pre-update-$TIMESTAMP.sql"

echo "==> Pulling new images..."
docker compose -f /home/lstadmin/outline/docker-compose.yml pull

echo "==> Restarting services..."
docker compose -f /home/lstadmin/outline/docker-compose.yml up -d

echo "==> Done. Check logs with: docker-compose logs -f outline"
