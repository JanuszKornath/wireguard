#!/bin/bash
set -e

# --- Konfiguration ---
WG_DIR="/etc/wireguard"
CLIENT_DIR="$WG_DIR/clients"
WG_IF="wg0"
SERVER_IP="10.8.0.1"
SERVER_PORT="51820"
EXT_IF="eth0"
SERVER_DNS=192.168.178.1
SERVER_ENDPOINT="vpn.org"
LOG_FILE="/var/log/wireguard-mail.log"
DOMAIN_SUFFIX="vpn.lan"  # für Hostnamen der Clients

mkdir -p "$CLIENT_DIR"

# --- Prüfen, ob Interface existiert ---
if ! wg show $WG_IF >/dev/null 2>&1; then
    echo "Fehler: Interface $WG_IF existiert oder ist nicht hoch!"
    exit 1
fi

SERVER_PUBLIC_KEY=$(wg show $WG_IF public-key 2>/dev/null || true)
if [[ -z "$SERVER_PUBLIC_KEY" ]]; then
    echo "Fehler: Server Public Key fehlt. Bitte wg-Interface prüfen."
    exit 1
fi

# --- Bestehende Clients anzeigen ---
echo "=== Bestehende WireGuard-Clients ==="
if ls "$CLIENT_DIR"/*.conf >/dev/null 2>&1; then
    for f in "$CLIENT_DIR"/*.conf; do
        name=$(basename "$f" .conf)
        ip=$(grep -m1 "Address" "$f" | awk '{print $3}')
        echo " - $name ($ip)"
    done
else
    echo "Keine Clients vorhanden."
fi
echo "==================================="

# --- Nächste freie IP berechnen ---
BASE="10.8.0"
USED_IPS=$(grep -h "Address" "$CLIENT_DIR"/*.conf 2>/dev/null | awk '{print $3}' | cut -d'/' -f1)
USED_IPS="$USED_IPS $SERVER_IP"

NEXT_IP=2
MAX_IP=254
while true; do
    CANDIDATE="$BASE.$NEXT_IP"
    if echo "$USED_IPS" | grep -qw "$CANDIDATE"; then
        NEXT_IP=$((NEXT_IP+1))
        if [[ $NEXT_IP -gt $MAX_IP ]]; then
            echo "Fehler: Keine freien IPs mehr verfügbar (10.8.0.2-$BASE.$MAX_IP)"
            exit 1
        fi
    else
        break
    fi
done
CLIENT_IP="$BASE.$NEXT_IP"

# --- Neuen Client anlegen ---
read -rp "Name des neuen Clients: " CLIENT_NAME

CLIENT_PRIV_KEY=$(wg genkey)
CLIENT_PUB_KEY=$(echo "$CLIENT_PRIV_KEY" | wg pubkey)

# --- Tunnelname setzen ---
TUNNEL_NAME="$WG_IF-$CLIENT_NAME"
CLIENT_CONF="$CLIENT_DIR/$TUNNEL_NAME.conf"

# --- Client-Konfiguration schreiben ---
cat > "$CLIENT_CONF" <<EOF
# Name: $TUNNEL_NAME
[Interface]
PrivateKey = $CLIENT_PRIV_KEY
Address = $CLIENT_IP/24
DNS = $SERVER_DNS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_ENDPOINT:$SERVER_PORT
AllowedIPs = 0.0.0.0/0
EOF

# --- Peer zum Interface hinzufügen (nicht wg-quick down/up!) ---
sudo wg set $WG_IF peer $CLIENT_PUB_KEY allowed-ips $CLIENT_IP/32

# --- Server-Konfiguration updaten ---
echo -e "\n[Peer]\nPublicKey = $CLIENT_PUB_KEY\nAllowedIPs = $CLIENT_IP/32" >> "$WG_DIR/$WG_IF.conf"

echo "Client $CLIENT_NAME erfolgreich erstellt!"
echo "Konfiguration: $CLIENT_CONF"
echo "Zugewiesene IP: $CLIENT_IP"

# --- Hosts-Synchronisation für AdGuard Home ---
echo "Aktualisiere Hostnamen in /etc/hosts..."
TEMP_HOSTS=$(mktemp)
grep -v "10.8.0." /etc/hosts > "$TEMP_HOSTS" || true
echo "$SERVER_IP vpn-server.$DOMAIN_SUFFIX" >> "$TEMP_HOSTS"

if ls "$CLIENT_DIR"/*.conf >/dev/null 2>&1; then
    for f in "$CLIENT_DIR"/*.conf; do
        c_ip=$(grep "Address" "$f" | awk '{print $3}' | cut -d'/' -f1)
        c_name=$(basename "$f" .conf | sed "s/^$WG_IF-//")
        if [[ -n "$c_ip" && -n "$c_name" ]]; then
            echo "$c_ip $c_name.$DOMAIN_SUFFIX" >> "$TEMP_HOSTS"
        fi
    done
fi

cat "$TEMP_HOSTS" > /etc/hosts
rm "$TEMP_HOSTS"
echo "DNS-Synchronisation abgeschlossen."

# --- QR-Code erzeugen ---
QR_FILE="$CLIENT_DIR/$TUNNEL_NAME.png"
if qrencode -o "$QR_FILE" -t PNG < "$CLIENT_CONF"; then
    echo "QR-Code erstellt: $QR_FILE"
else
    echo "Fehler: QR-Code konnte nicht erstellt werden!"
fi

# --- Mail vorbereiten ---
read -rp "Empfänger-E-Mail (leer = keine Mail): " RECIPIENT

if [[ -n "$RECIPIENT" ]]; then
    MAIL_SUBJECT="Deine WireGuard VPN-Konfiguration"
    MAIL_BODY=$(cat <<EOF
Hallo $CLIENT_NAME,

anbei erhältst du deine persönliche WireGuard VPN-Konfiguration. Bitte beachte die Anweisungen für verschiedene Betriebssystem.

---

### Ubuntu
1. Wireguard installieren: sudo apt update && sudo apt install wireguard-tools wireguard
2. Verzeichnis für VPN-Konfiguration anlegen: mkdir -p ~/wg
3. .conf speichern: cp /path/to/downloaded/$TUNNEL_NAME.conf ~/wg/$TUNNEL_NAME.conf
4. Import in NetworkManager: nmcli connection import type wireguard file ~/wg/$TUNNEL_NAME.conf
5. Überprüfen: nmcli connection show
6. Verbindung aktivieren: nmcli connection up $TUNNEL_NAME

### Android
1. WireGuard App installieren
2. .conf importieren oder QR-Code scannen
3. Tunnel aktivieren

### Windows 11
1. WireGuard Windows installieren
2. .conf importieren
3. Tunnel aktivieren

---

### Hinweise
- DNS: $SERVER_DNS
- Endpoint: $SERVER_ENDPOINT:$SERVER_PORT
- IP-Adresse: $CLIENT_IP
- PrivateKey niemals weitergeben!

Dateianhänge: $TUNNEL_NAME.conf + QR-Code
EOF
)

    mail -s "$MAIL_SUBJECT" -A "$CLIENT_CONF" -A "$QR_FILE" "$RECIPIENT" <<< "$MAIL_BODY"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Gesendet: $CLIENT_CONF + QR-Code an $RECIPIENT" >> "$LOG_FILE"
    echo "E-Mail erfolgreich gesendet!"
fi

# --- dnsmasq neu laden ---
pkill -HUP dnsmasq
