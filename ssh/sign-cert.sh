#!/usr/bin/env bash
# ssh/sign-cert.sh
# Stellt ein kurzlebiges SSH-Benutzerzertifikat für das k8s-Lab aus.
#
# Alle Werte lassen sich per Option oder Umgebungsvariable setzen
# (Option hat Vorrang). Aufruf ohne Optionen nutzt die Standardwerte.
set -euo pipefail

CA_DIR="${K8S_LAB_CA_DIR:-$HOME/.ssh-ca}"
CA_KEY="${K8S_LAB_CA_KEY:-k8s_lab_user_ca}"
USER_KEY="${K8S_LAB_USER_KEY:-$HOME/.ssh/id_ed25519_k8s_lab}"
PRINCIPALS="${K8S_LAB_PRINCIPALS:-ubuntu}"
VALIDITY="${K8S_LAB_VALIDITY:-8h}"
IDENTITY="${K8S_LAB_IDENTITY:-$(whoami)@k8s-lab}"
ADD_TO_AGENT=false

usage() {
  cat <<USAGE
Aufruf: $(basename "$0") [Optionen]

  -c <name|pfad>  CA-Schlüssel: Name in \$K8S_LAB_CA_DIR (${CA_DIR})
                  oder Pfad mit '/'                      [${CA_KEY}]
  -k <pfad>       privater Benutzerschlüssel (ohne .pub) [${USER_KEY}]
  -n <liste>      Principals, kommagetrennt              [${PRINCIPALS}]
  -V <dauer>      Gültigkeit, z. B. 30m, 8h, 1d          [${VALIDITY}]
  -I <kennung>    Key ID im Zertifikat (erscheint im Log) [${IDENTITY}]
  -a              Schlüssel + Zertifikat dem ssh-agent hinzufügen
  -h              diese Hilfe

Umgebungsvariablen: K8S_LAB_CA_DIR, K8S_LAB_CA_KEY, K8S_LAB_USER_KEY,
                    K8S_LAB_PRINCIPALS, K8S_LAB_VALIDITY, K8S_LAB_IDENTITY
USAGE
}

while getopts ":c:k:n:V:I:ah" opt; do
  case "$opt" in
    c) CA_KEY="$OPTARG" ;;
    k) USER_KEY="$OPTARG" ;;
    n) PRINCIPALS="$OPTARG" ;;
    V) VALIDITY="$OPTARG" ;;
    I) IDENTITY="$OPTARG" ;;
    a) ADD_TO_AGENT=true ;;
    h) usage; exit 0 ;;
    :) echo "Option -$OPTARG braucht einen Wert" >&2; usage >&2; exit 1 ;;
    *) echo "Unbekannte Option -$OPTARG" >&2; usage >&2; exit 1 ;;
  esac
done

# CA: reiner Name -> im CA-Verzeichnis, sonst als Pfad verwenden
if [[ "$CA_KEY" == */* ]]; then CA_PATH="$CA_KEY"; else CA_PATH="$CA_DIR/$CA_KEY"; fi
CERT="${USER_KEY}-cert.pub"

# --- Prüfungen -------------------------------------------------------------
[[ -f "$CA_PATH" ]]        || { echo "CA-Schlüssel nicht gefunden: $CA_PATH" >&2; exit 1; }
[[ -f "${USER_KEY}.pub" ]] || { echo "Öffentlicher Benutzerschlüssel nicht gefunden: ${USER_KEY}.pub" >&2; exit 1; }

if [[ ! "$VALIDITY" =~ ^[0-9]+[smhdw]$ ]]; then
  echo "Ungültige Dauer '$VALIDITY' (erwartet z. B. 30m, 8h, 1d)" >&2; exit 1
fi

# Privater CA-Schlüssel darf nur für den Besitzer lesbar sein
perm="$(stat -c '%a' "$CA_PATH")"
if (( (8#$perm & 077) != 0 )); then
  echo "Rechte von $CA_PATH zu offen ($perm). Abhilfe: chmod 600 '$CA_PATH'" >&2; exit 1
fi

# --- Signieren -------------------------------------------------------------
# Gültig ab 5 Minuten in der Vergangenheit: fängt Uhrzeitabweichungen zwischen
# Host und VM ab. Seriennummer = Zeitstempel, eindeutig und für Sperrlisten nutzbar.
ssh-keygen -q \
  -s "$CA_PATH" \
  -I "$IDENTITY" \
  -n "$PRINCIPALS" \
  -V "-5m:+${VALIDITY}" \
  -z "$(date +%s)" \
  "${USER_KEY}.pub"

echo "Zertifikat: $CERT"
ssh-keygen -L -f "$CERT" | sed -n '/Key ID:/p; /Serial:/p; /Valid:/p; /Principals:/,/Critical Options:/{/Critical Options:/!p}'

# --- Optional: ssh-agent ---------------------------------------------------
if $ADD_TO_AGENT; then
  if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    echo "Kein ssh-agent gefunden (SSH_AUTH_SOCK leer). Start: eval \"\$(ssh-agent -s)\"" >&2; exit 1
  fi
  # Lebensdauer im Agent = Gültigkeit des Zertifikats
  ssh-add -t "$VALIDITY" "$USER_KEY"
fi
