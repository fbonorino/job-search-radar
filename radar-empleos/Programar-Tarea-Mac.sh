#!/bin/bash
# Registra (o quita) un LaunchAgent de macOS que corre el radar de empleos una vez por dia.
# Equivalente a Programar-Tarea.ps1 (que usa el Programador de Tareas de Windows y no sirve en Mac).
#
# A diferencia de un horario fijo, esto no depende de que la Mac este prendida a una hora exacta:
# chequea cada una hora (mientras la Mac este despierta) si ya corrio hoy, y si no, corre. O sea que
# se ejecuta una sola vez por dia, la primera vez que la Mac este disponible.
#
# Uso:
#   ./Programar-Tarea-Mac.sh                 # activar (corre ~1 vez por dia, chequeo cada hora)
#   ./Programar-Tarea-Mac.sh -q              # quitar la tarea
#   ./Programar-Tarea-Mac.sh -f              # forzar una corrida ahora, ignorando si ya corrio hoy

set -euo pipefail

NOMBRE="com.radar-empleos.buscar"
QUITAR=0
FORZAR=0

while getopts "n:qf" opt; do
  case "$opt" in
    n) NOMBRE="$OPTARG" ;;
    q) QUITAR=1 ;;
    f) FORZAR=1 ;;
    *) echo "Uso: $0 [-n nombre] [-q] [-f]"; exit 1 ;;
  esac
done

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PS1="$RAIZ/Buscar-Empleos.ps1"
WRAPPER="$RAIZ/.correr-si-no-corrio-hoy.sh"
MARCADOR="$RAIZ/datos/.ultima-corrida-diaria"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$NOMBRE.plist"
LOG_DIR="$RAIZ/reportes"

if [ "$QUITAR" -eq 1 ]; then
  if [ -f "$PLIST_PATH" ]; then
    launchctl bootout "gui/$(id -u)/$NOMBRE" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH" "$WRAPPER"
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

mkdir -p "$PLIST_DIR" "$LOG_DIR" "$RAIZ/datos"

# wrapper: corre el radar solo si no corrio hoy (o si se fuerza con -f)
cat > "$WRAPPER" <<EOF
#!/bin/bash
HOY=\$(date +%F)
if [ "${FORZAR}" != "1" ] && [ -f "$MARCADOR" ] && [ "\$(cat "$MARCADOR")" = "\$HOY" ]; then
  exit 0
fi
"$PWSH_PATH" -NoProfile -File "$SCRIPT_PS1" -NoAbrir
echo "\$HOY" > "$MARCADOR"
EOF
chmod +x "$WRAPPER"

if [ "$FORZAR" -eq 1 ]; then
  echo "Corriendo ahora (forzado, ignora si ya corrio hoy)..."
  "$WRAPPER"
  echo "Listo. Mira reportes/ y cola-postulacion.md"
  exit 0
fi

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$NOMBRE</string>
    <key>ProgramArguments</key>
    <array>
        <string>$WRAPPER</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$NOMBRE" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || launchctl load "$PLIST_PATH"

echo ""
echo "  Tarea registrada: '$NOMBRE'"
echo "  Chequea cada 1 hora (y al iniciar sesion) si ya corrio hoy; si no, corre una vez."
echo "  No depende de un horario fijo: corre la primera vez que la Mac este prendida ese dia."
echo "  Los reportes quedan en: $LOG_DIR"
echo "  Logs de la tarea programada: $LOG_DIR/launchd.out.log / launchd.err.log"
echo ""
echo "  Para forzar una corrida ahora (prueba):  ./Programar-Tarea-Mac.sh -f"
echo "  Para quitarla:                           ./Programar-Tarea-Mac.sh -q"
echo ""
