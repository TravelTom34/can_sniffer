#!/bin/bash
# ============================================================
# start_can_sniffer.sh
# Plug in the R4/MCP2515 sniffer, run this script, go.
# Tears down any stale session, lets you pick a bitrate,
# attaches can0, and drops you into candump.
# ============================================================

set -e

echo "=== M2 BHM CAN Sniffer Startup ==="
echo ""

# ---------- 1. Clean up any leftover session ----------
echo "[1/5] Tearing down any existing can0/slcand session..."
sudo ip link set can0 down 2>/dev/null || true
sudo pkill slcand 2>/dev/null || true
sleep 1

# ---------- 2. Find the device ----------
echo "[2/5] Locating the R4..."

if [ -e /dev/ttyACM_R4 ]; then
    DEVICE="/dev/ttyACM_R4"
    echo "  Found fixed udev symlink: $DEVICE"
else
    # fall back to scanning for ttyACM* devices
    ACM_DEVICES=(/dev/ttyACM*)
    if [ ! -e "${ACM_DEVICES[0]}" ]; then
        echo "  ERROR: No /dev/ttyACM* device found. Is the R4 plugged in?"
        exit 1
    elif [ ${#ACM_DEVICES[@]} -eq 1 ]; then
        DEVICE="${ACM_DEVICES[0]}"
        echo "  Found: $DEVICE"
    else
        echo "  Multiple ACM devices found:"
        select DEVICE in "${ACM_DEVICES[@]}"; do
            [ -n "$DEVICE" ] && break
        done
        echo "  Using: $DEVICE"
    fi
fi

# ---------- 3. Ask for bitrate ----------
echo ""
echo "[3/5] Select CAN bus bitrate:"
echo "  1) 125 kbps"
echo "  2) 250 kbps  (BHM body/cab bus)"
echo "  3) 500 kbps  (J1939 engine/chassis bus)"
echo "  4) 1000 kbps"
echo ""
read -p "Enter choice [1-4]: " CHOICE

case $CHOICE in
    1) SPEED_FLAG="-s4"; SPEED_LABEL="125 kbps" ;;
    2) SPEED_FLAG="-s5"; SPEED_LABEL="250 kbps" ;;
    3) SPEED_FLAG="-s6"; SPEED_LABEL="500 kbps" ;;
    4) SPEED_FLAG="-s8"; SPEED_LABEL="1000 kbps" ;;
    *) echo "Invalid choice. Exiting."; exit 1 ;;
esac

echo "  Selected: $SPEED_LABEL ($SPEED_FLAG)"
echo ""
echo "  NOTE: this flag only affects the slcand handshake. The R4's actual"
echo "  bit timing is hardcoded in firmware (CNF1/CNF2/CNF3). If you're"
echo "  switching buses, make sure the firmware currently flashed matches"
echo "  the speed you just selected, or reflash first."
echo ""

# ---------- 4. Attach as SocketCAN interface ----------
echo "[4/5] Attaching $DEVICE as can0 @ $SPEED_LABEL..."
sudo slcand -o -c $SPEED_FLAG -S 115200 "$DEVICE" can0
sleep 1
sudo ip link set up can0

# ---------- 5. Verify and launch ----------
echo "[5/5] Verifying interface..."
if ip link show can0 up &>/dev/null; then
    echo "  can0 is UP."
    ip -details -statistics link show can0 | head -5
else
    echo "  ERROR: can0 did not come up. Check dmesg for errors."
    exit 1
fi

echo ""
echo "=== Ready. Launching candump can0 (Ctrl+C to stop) ==="
echo ""
sleep 1
candump can0
