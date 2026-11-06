#!/usr/bin/env bash
# Installa (o rifirma, ogni 7 giorni con l'Apple ID gratuito) YT Offline sull'iPhone, col cavo.
# Stessa procedura di bevel-coach/flash.sh (plumesign già loggato con l'Apple ID).
set -euo pipefail
cd "$(dirname "$0")"
BC=../bevel-coach
PLUME=$BC/tools/impactor/plumesign-linux-x86_64
UDID=00008140-001859910AC0801C
OUT=data/ipa
mkdir -p "$OUT"
gh release download latest -R ruggiio/yt-offline -p "YTOffline.ipa" -D "$OUT" --clobber
DEVID=$($BC/.venv/bin/python -c "
import asyncio
from pymobiledevice3 import usbmux
try:
    devs = asyncio.run(usbmux.list_devices())
except Exception:
    devs = []
print(next((d.devid for d in devs if d.serial == '$UDID' and d.connection_type == 'USB'), ''))" 2>/dev/null)
[ -n "$DEVID" ] || { echo "iPhone non trovato via USB: collegalo, sbloccalo e autorizza il computer."; exit 1; }
"$PLUME" sign -p "$OUT/YTOffline.ipa" --apple-id --register-and-install --udid "$DEVID"
echo "Fatto. Se è la prima volta: Impostazioni → Generali → VPN e gestione dispositivi → fidati del tuo Apple ID."
