#!/bin/bash
# Registra (o quita) un LaunchAgent de macOS que corre el radar de empleos todos los dias.
# Equivalente a Programar-Tarea.ps1 (que usa el Programador de Tareas de Windows y no sirve en Mac).
#
# Uso:
#   ./Programar-Tarea-Mac.sh                 # todos los dias a las 08:30
#   ./Programar-Tarea-Mac.sh -h 19:00        # a otra hora
#   ./Programar-Tarea-Mac.sh -q              # quitar la tarea

set -euo pipefail

HORA="08:30"
NOMBRE="com.radar-empleos.buscar"
QUITAR=0

while getopts "h:n:q" opt; do
  case "$opt" in
    h) HORA="$OPTARG" ;;
    n) NOMBRE="$OPTARG" ;;
    q) QUITAR=1 ;;
    *) echo "Uso: $0 [-h HH:MM] [-n nombre] [-q]"; exit 1 ;;
  esac
done

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PS1="$RAIZ/Buscar-Empleos.ps1"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$NOMBRE.plist"
LOG_DIR="$RAIZ/reportes"

if [ "$QUITAR" -eq 1 ]; then
  if [ -f "$PLIST_PATH" ]; then
    launchctl bootout "gui/$(id -u)/$NOMBRE" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "Tarea '$NOMBRE' eliminada."
  else
    echo "No habia ninguna tarea registrada como '$NOMBRE'."
  fi
  exit 0
fi

if [ ! -f "$SCRIPT_PS1" ]; then
  echo "No encuentro $SCRIPT_PS1" >&2
  exit 1
fi

PWSH_PATH="$(command -v pwsh || true)"
if [ -z "$PWSH_PATH" ]; then
  echo "No encuentro pwsh en el PATH. Instalalo con: brew install powershell" >&2
  exit 1
fi

HORA_H="${HORA%%:*}"
HORA_M="${HORA##*:}"

mkdir -p "$PLIST_DIR" "$LOG_DIR"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$NOMBRE</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PWSH_PATH</string>
        <string>-NoProfile</string>
        <string>-File</string>
        <string>$SCRIPT_PS1</string>
        <string>-NoAbrir</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>$HORA_H</integer>
        <key>Minute</key>
        <integer>$HORA_M</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd.err.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$NOMBRE" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || launchctl load "$PLIST_PATH"

echo ""
echo "  Tarea registrada: '$NOMBRE'"
echo "  Corre todos los dias a las $HORA (la Mac tiene que estar prendida y con sesion iniciada a esa hora;"
echo "  a diferencia del Programador de Tareas de Windows, launchd NO despierta la Mac dormida)."
echo "  Los reportes quedan en: $LOG_DIR"
echo "  Logs de la tarea programada: $LOG_DIR/launchd.out.log / launchd.err.log"
echo ""
echo "  Para quitarla:  ./Programar-Tarea-Mac.sh -q"
echo ""
