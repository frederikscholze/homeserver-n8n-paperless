#!/bin/bash
set -uo pipefail

STACK=/opt/n8n-stack
TARGET=/opt/backups
KEEP_DAYS=7
DATE=$(date +%Y-%m-%d_%H-%M)
ARCHIVE="$TARGET/anwendungsdaten_$DATE.tar.gz"

cd "$STACK" || exit 1
echo "[$(date)] Sicherung gestartet"

echo "Paperless wird exportiert ..."
if ! docker compose exec -T paperless document_exporter ../export -d --no-progress-bar; then
  echo "FEHLER: Paperless-Export fehlgeschlagen"
  exit 1
fi

echo "n8n wird kurz angehalten ..."
docker compose stop n8n
tar -czf "$ARCHIVE" -C /opt n8n-stack
RESULT=$?
docker compose start n8n

if [ "$RESULT" -gt 1 ]; then
  echo "FEHLER: Archiv konnte nicht erstellt werden"
  rm -f "$ARCHIVE"
  exit 1
fi

chmod 600 "$ARCHIVE"
find "$TARGET" -name 'anwendungsdaten_*.tar.gz' -mtime +"$KEEP_DAYS" -delete

echo "[$(date)] Sicherung fertig: $ARCHIVE"
