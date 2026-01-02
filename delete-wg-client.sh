#!/bin/bash
set -e

# --- Konfiguration (muss mit Erstellungs-Skript übereinstimmen) ---
WG_DIR="/etc/wireguard"
CLIENT_DIR="$WG_DIR/clients"
WG_IF="wg0"
WG_CONF="$WG_DIR/$WG_IF.conf"
HOSTS_FILE="/etc/hosts"

# --- Bestehende Clients anzeigen ---
echo "=== Aktuelle WireGuard-Clients ==="
CLIENT_FOUND=false
if ls "$CLIENT_DIR"/*.conf >/dev/null 2>&1; then
    for f in "$CLIENT_DIR"/*.conf; do
        # Extrahiert den reinen Namen ohne "wg0-" Präfix und ohne ".conf"
        full_name=$(basename "$f" .conf)
        name=${full_name#"$WG_IF-"} 
        ip=$(grep -m1 "Address" "$f" | awk '{print $3}' | cut -d'/' -f1)
        echo " - $name ($ip)"
        CLIENT_FOUND=true
    done
else
    echo "Keine Clients zum Löschen gefunden."
    exit 0
fi
echo "==================================="

# --- Eingabe des zu löschenden Clients ---
read -rp "Welcher Client soll gelöscht werden? (Name eingeben): " DELETE_NAME

if [ -z "$DELETE_NAME" ]; then
    echo "Abbruch: Kein Name eingegeben."
    exit 1
fi

# Pfade definieren
TUNNEL_NAME="$WG_IF-$DELETE_NAME"
CLIENT_CONF="$CLIENT_DIR/$TUNNEL_NAME.conf"
QR_FILE="$CLIENT_DIR/$TUNNEL_NAME.png"

# Prüfen ob Datei existiert
if [ ! -f "$CLIENT_CONF" ]; then
    echo "Fehler: Konfiguration für '$DELETE_NAME' nicht gefunden ($CLIENT_CONF)"
    exit 1
fi

# --- 1. Public Key aus Client-Datei holen (wichtig für wg remove) ---
# Wir brauchen den PublicKey des Peers, um ihn live vom Server zu trennen
CLIENT_IP=$(grep "Address" "$CLIENT_CONF" | awk '{print $3}' | cut -d'/' -f1)
# Da der Client-PrivKey in seiner conf steht, müssen wir den PubKey daraus berechnen
TEMP_PRIV_KEY=$(grep "PrivateKey" "$CLIENT_CONF" | awk '{print $3}')
CLIENT_PUB_KEY=$(echo "$TEMP_PRIV_KEY" | wg pubkey)

echo "Lösche $DELETE_NAME ($CLIENT_IP)..."

# --- 2. Live vom WireGuard Interface trennen ---
if wg show $WG_IF peers | grep -q "$CLIENT_PUB_KEY"; then
    wg set $WG_IF peer "$CLIENT_PUB_KEY" remove
    echo "-> Client live vom Interface getrennt."
fi

# --- 3. Aus der permanenten wg0.conf löschen ---
# Wir löschen den [Peer] Block, der die IP des Clients enthält
# Löscht den Block ab [Peer] bis zur übernächsten Zeile (PublicKey & AllowedIPs)
sed -i "/\[Peer\]/,/AllowedIPs = $CLIENT_IP\/32/d" "$WG_CONF"
echo "-> Eintrag aus $WG_CONF entfernt."

# --- 4. Aus /etc/hosts entfernen (für DNS) ---
if grep -q "$DELETE_NAME.vpn.m34.lan" "$HOSTS_FILE"; then
    sed -i "/$DELETE_NAME.vpn.m34.lan/d" "$HOSTS_FILE"
    pkill -HUP dnsmasq || true
    echo "-> DNS-Eintrag entfernt und dnsmasq aktualisiert."
fi

# --- 5. Dateien löschen (.conf und .png) ---
rm -f "$CLIENT_CONF"
rm -f "$QR_FILE"
echo "-> Konfigurationsdateien gelöscht."

echo "=== Fertig! Client $DELETE_NAME wurde vollständig entfernt. ==="
