# CAN Sniffer — Setup Guide

Project: Arduino Uno R4 WiFi + MCP2515/TJA1050 CAN interface, sniffing CAN frames from any bus (built and validated against a Freightliner M2 Bulkhead Module / BHM).

> Having a problem? This file is setup only. See
> [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) for known issues, root
> causes, and fixes.

---

## 1. Hardware

- **Arduino Uno R4 WiFi** — Renesas RA4M1 main MCU (48MHz, Cortex-M4). 5V
  logic.
- **MCP2515/TJA1050 module** (V2139 clone board) — SPI CAN controller +
  transceiver. VCC=5V, has a screw terminal block for CAN-H/CAN-L. Crystal on
  this board: **8MHz**.
- Bus harness tapped into CAN-H/CAN-L, terminated to ~60Ω (two 120Ω
  terminators in parallel — verify with a multimeter before powering up).

> See [`additional_projects/raspberry_pi_reference_platform.md`](additional_projects/raspberry_pi_reference_platform.md)
> for notes on an optional Raspberry Pi 5 cross-check setup — it's not part
> of this build.

---

## 2. Arduino IDE setup

1. Install **Arduino IDE 2.3.10** (or newer).
2. Board setting: **Arduino Uno R4 WiFi**
   (`arduino:renesas_uno:unor4wifi`).
3. No external CAN library is required. The final firmware talks to the
   MCP2515 directly over raw `SPI.h` calls, so you do **not** need to install
   the `mcp_can` library.
4. Open `firmware/Final_sketch_IDE` in the Arduino IDE.
5. Plug in the Uno R4 WiFi via USB, select the correct port, and click
   **Upload**.

---

## 3. Firmware reference

The final sketch (`firmware/Final_sketch_IDE`):

- Talks directly to the MCP2515 over raw SPI register access (no `mcp_can`
  library dependency). SPI clock: 1MHz.
- Bit timing: `CNF1=0x00`, `CNF2=0xB1`, `CNF3=0x85` → **250kbps @ 8MHz
  crystal** (the validated BHM body/cab bus setting).
- Uses the MCP2515's **READ RX BUFFER** instruction (`0x90`/`0x94`), which
  auto-clears the RX interrupt flag on CS release — the datasheet-correct
  way to drain both mailboxes without missing frames.
- Speaks the **SLCAN** ASCII protocol over USB serial at 115200 baud:
  `tIIILDD...` (standard frame), `TIIIIIIIILDD...` (extended frame),
  terminated with `\r`.
- Auto-opens the CAN channel at boot (`canOpen = true`), so it starts
  streaming immediately without waiting for an `O` command.
- To sniff the 500kbps J1939 engine/chassis bus instead of the 250kbps
  body/cab bus: change `CNF1`/`CNF2`/`CNF3` to 500kbps timing values and
  reflash.

---

## 4. Linux setup (recommended platform)

### 4.1 Install can-utils and fix permissions

```bash
sudo apt update && sudo apt install can-utils
sudo usermod -aG dialout $USER
# log out/in, or: newgrp dialout
```

### 4.2 Flash the firmware

Use `firmware/Final_sketch_IDE`. Board: **Arduino Uno R4 WiFi**. Port:
whichever `/dev/ttyACM#` shows up (see 4.6 for a fixed device name).

### 4.3 Find the device

```bash
ls -l /dev/ttyACM*
dmesg | tail -20        # if it's not showing up
```

### 4.4 Attach as a SocketCAN interface via slcand

```bash
sudo slcand -o -c -s5 -S 115200 /dev/ttyACM0 can0
sudo ip link set up can0
```

Flags:
- `-o` — open the CAN channel on start
- `-c` — close first, then reopen (clean handshake state)
- `-s5` — SLCAN bitrate code 5 = 250kbps (see the bitrate table in Section 7)
- `-S 115200` — serial baud rate, must match `Serial.begin()` in the sketch

### 4.5 Verify and sniff

```bash
ip -details -statistics link show can0
candump can0
```

### 4.6 (Recommended) Fixed device name via udev rule

Linux assigns `/dev/ttyACM#` numbers by enumeration order, so the number can
change between plug-ins. Set up a fixed symlink once:

```bash
udevadm info -a -n /dev/ttyACM0 | grep -E 'ATTRS\{idVendor\}|ATTRS\{idProduct\}|ATTRS\{serial\}' | head -5

sudo nano /etc/udev/rules.d/99-r4-can.rules
```

Add (adjust vendor/product IDs from the command above — Arduino R4 is
typically vendor `2341`):

```
SUBSYSTEM=="tty", ATTRS{idVendor}=="2341", ATTRS{idProduct}=="1002", SYMLINK+="ttyACM_R4"
```

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

After this, `/dev/ttyACM_R4` always points at the R4 regardless of
enumeration order:

```bash
sudo slcand -o -c -s5 -S 115200 /dev/ttyACM_R4 can0
sudo ip link set up can0
```

### 4.7 Automated startup script

`scripts/install.sh` automates steps 4.3–4.5, prompts for bitrate, and
launches `candump` for you:

```bash
./scripts/install.sh
```

---

## 5. SavvyCAN (optional GUI tool)

### 5.1 Install (AppImage, Debian/Kali-based Linux)

```bash
cd ~/Downloads
chmod +x SavvyCAN*.AppImage
./SavvyCAN*.AppImage
```

### 5.2 Connect

**Connection → Add New Device Connection → "QT SerialBus Devices (SocketCAN,
PeakCAN, etc.)"** → select `can0`.

This talks to the kernel's native SocketCAN stack directly, so no serial
port/flow-control setup is needed on Linux.

---

## 6. Daily session checklist (quick reference)

```bash
# 1. Check device
ls -l /dev/ttyACM*

# 2. Tear down any stale session
sudo ip link set can0 down
sudo pkill slcand

# 3. (only if reflashing) upload from Arduino IDE now

# 4. Attach
sudo slcand -o -c -s5 -S 115200 /dev/ttyACM_R4 can0   # or /dev/ttyACM0 if no udev rule
sudo ip link set up can0

# 5. Verify
ip -details -statistics link show can0

# 6. Capture
candump can0
# or open SavvyCAN → Connection → SocketCAN → can0

# 7. Shut down
sudo ip link set can0 down
sudo pkill slcand
```

---

## 7. Known-good reference config

| Parameter | Value |
|---|---|
| Bus | M2 BHM, body/cab side |
| Bitrate | 250 kbps |
| Crystal | 8 MHz |
| CNF1 / CNF2 / CNF3 | 0x00 / 0xB1 / 0x85 |
| Confirmed CAN IDs | `0x18EEFF21` (Address Claimed, SA=0x21=BHM), `0x18FEFA21`, `0x10EF4721`, others |
| Firmware | Raw-SPI direct register access, no `mcp_can` library |

---

## 8. slcand bitrate code reference

| Flag | Bitrate |
|---|---|
| `-s0` | 10 kbps |
| `-s1` | 20 kbps |
| `-s2` | 50 kbps |
| `-s3` | 100 kbps |
| `-s4` | 125 kbps |
| `-s5` | 250 kbps (BHM body/cab bus — current setup) |
| `-s6` | 500 kbps (J1939 engine/chassis bus) |
| `-s7` | 800 kbps |
| `-s8` | 1000 kbps |

Note: this flag is passed to slcand's handshake but has **no effect** on
actual bus timing with this firmware — real timing is hardcoded in the
sketch's `canInit()` (CNF1/2/3 registers). To actually change bus speed,
edit and reflash the firmware, then match this flag for consistency.

---

## 9. Repo layout

| Path | Contents |
|---|---|
| `firmware/` | Arduino sketch (final, raw-SPI build) |
| `scripts/` | `install.sh` — automated attach/startup script |
| `dbc/` | DBC files for decoding captured frames |
| `docs/` | System setup notes, reference PDFs, [`TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) |
| `wiring_scematics/` | Wiring/harness diagrams |
| `tool_pictures/` | Photos of the built tool |
| `J1939_PGN_REFERENCE.md` | J1939 PGN quick reference |
| `additional_projects/` | Notes on related/optional hardware not used in this build (e.g. Raspberry Pi 5 reference platform) |
