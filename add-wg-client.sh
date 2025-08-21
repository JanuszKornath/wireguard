#!/bin/bash
WG_CONF="/etc/wireguard/wg0.conf"
WG_NETWORK="10.8.0.0/24"
CLIENT_DIR="/etc/wireguard/clients"
SERVER_PUBLIC_KEY=$(grep '^PublicKey' "$WG_CONF" | awk '{print $3}')
SERVER_ENDPOINT="your.vpn.server:51820"

mkdir -p "$CLIENT_DIR"
chmod 700 "$CLIENT_DIR"

# Bestehende Clients auflisten
echo "=== Bestehende WireGuard-Clients ==="
if grep -q '^### Client' "$WG_CONF"; then
    printf "%-20s %-15s %s\n" "Clientname" "IP-Adresse" "Public Key"
    echo "----------------------------------------------------------"
    grep -A2 '^### Client' "$WG_CONF" | grep -v '^$' | while read -r line; do
        if [[ $line == '### Client'* ]]; then
            CLIENT_NAME=$(echo $line | awk '{print $3}')
        elif [[ $line == PublicKey* ]]; then
            CLIENT_KEY=$(echo $line | awk '{print $3}')
        elif [[ $line == AllowedIPs* ]]; then
            CLIENT_IP=$(echo $line | awk '{print $3}' | cut -d'/' -f1)
            printf "%-20s %-15s %s\n" "$CLIENT_NAME" "$CLIENT_IP" "$CLIENT_KEY"
        fi
    done
else
    echo "Keine Clients vorhanden."
fi
echo "==================================="

# Funktion: nächste freie IP
next_ip() {
    for i in $(seq 2 254); do
        ip="10.8.0.$i"
        if ! grep -q "$ip" "$WG_CONF"; then
            echo "$ip"
            return
        fi
    done
    echo "Keine freien IP-Adressen verfügbar!"
    exit 1
}

# Clientname prüfen
while true; do
    read -p "Name des neuen Clients: " CLIENT_NAME
    if grep -q "### Client $CLIENT_NAME" "$WG_CONF"; then
        echo "Client $CLIENT_NAME existiert bereits. Bitte einen anderen Namen wählen."
    else
        break
    fi
done

CLIENT_IP=$(next_ip)
echo "Neue IP für $CLIENT_NAME: $CLIENT_IP"

# Keys generieren
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
CLIENT_PRESHARED_KEY=$(wg genpsk)

# Client-Konfigurationsdatei erstellen
CLIENT_CONF="$CLIENT_DIR/$CLIENT_NAME.conf"
cat > "$CLIENT_CONF" <<EOL
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED_KEY
Endpoint = $SERVER_ENDPOINT
AllowedIPs = 0.0.0.0/0, ::/0
EOL

chmod 600 "$CLIENT_CONF"

# wg0.conf erweitern
{
    echo -e "\n### Client $CLIENT_NAME"
    echo "PublicKey = $CLIENT_PUBLIC_KEY"
    echo "PresharedKey = $CLIENT_PRESHARED_KEY"
    echo "AllowedIPs = $CLIENT_IP/32"
} >> "$WG_CONF"

# WireGuard neu laden
wg-quick down wg0
wg-quick up wg0

echo "Client $CLIENT_NAME erfolgreich erstellt!"
echo "Konfiguration in $CLIENT_CONF"

# Optional: Mailversand
read -p "Möchten Sie die Konfiguration per E-Mail verschicken? (y/n): " SEND_MAIL
if [[ "$SEND_MAIL" =~ ^[Yy]$ ]]; then
    read -p "Empfänger-E-Mail: " RECIPIENT
    echo "Sende $CLIENT_CONF an $RECIPIENT ..."
    mail -s "WireGuard Client-Konfiguration $CLIENT_NAME" "$RECIPIENT" < "$CLIENT_CONF"
    echo "E-Mail gesendet!"
fi
