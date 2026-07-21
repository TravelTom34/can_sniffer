# M2 BHM CAN Sniffer — Full Setup & Troubleshooting Guide

Project: Arduino Uno R4 WiFi + MCP2515/TJA1050 CAN interface, sniffing a
Freightliner M2 Bulkhead Module (BHM) on the bench. This document covers
everything done to get from "boards on the desk" to "reliable frame capture,"
including every dead end, so it doesn't have to be rediscovered.

---

## 1. Hardware

- **Arduino Uno R4 WiFi** — Renesas RA4M1 main MCU (48MHz, Cortex-M4),
  ESP32-S3 co-processor for WiFi (unused in this project). 5V logic.
- **MCP2515/TJA1050 module** (V2139 clone board) — SPI CAN controller +
  transceiver. VCC=5V, has screw terminal block for CAN-H/CAN-L.
  **Crystal confirmed to be 8MHz** (validated by matching bus data against
  a known-good Raspberry Pi 5 capture — see Section 3).
- **Raspberry Pi 5 + second MCP2515 module** — used as the known-good
  reference platform (native Linux socketcan via dtoverlay). Validated the
  BHM bus (250kbps) and bench wiring/termination before any R4 work began.
- Bench harness tapped into the M2 BHM's CAN-H/CAN-L, terminated to ~60Ω
  (two 120Ω terminators in parallel — verified with a multimeter).

---

## 2. Arduino IDE setup

- IDE version: 1.8.19 initially, later moved to **IDE 2.3.10**.
- Board setting: **Arduino Uno R4 WiFi** (`arduino:renesas_uno:unor4wifi`).
- Initial library installed: `mcp_can` by **coryjfowler**, v1.5.1, via
  Library Manager (Sketch → Include Library → Manage Libraries).
  - This library is **no longer used** in the final firmware — see Section 4.

### Early compile error and fix
```
fatal error: mcp_can.h: No such file or directory
```
Cause: library not yet installed. Fixed via Library Manager search for
`mcp_can` → install the coryjfowler version. Sketchbook location:
`C:\Users\TomsT\sketchbook\libraries\mcp_can\` (Windows path from original
troubleshooting session).

---

## 3. Bit-timing / crystal debugging (the long part)

### Symptom progression
1. Loopback mode (`MCP_LOOPBACK`) worked immediately — proved SPI wiring,
   power, and basic firmware logic were correct. **Loopback does NOT
   validate bit timing against a real bus** — both TX and RX use the same
   internal clock regardless of correctness.
2. Switched to `MCP_NORMAL` / `MCP_LISTENONLY` on the real BHM bus:
   zero frames received.
3. Diagnostic sketch added error-register reporting:
   - `errFlag=5` (CAN_CTRLERROR) with `rxErrCount=0` — ruled out simple
     bit-timing mismatch (a timing mismatch would climb rxErrCount).
4. Decoded the raw EFLG register directly → **`RX0OVR`** (RX buffer 0
   overflow). This proved: **valid frames WERE arriving and being decoded
   correctly by the MCP2515** — the failure was entirely in the
   `mcp_can` library's read path (`checkReceive()`/`readMsgBuf()`), not
   the bus, wiring, or bit timing.
5. Confirmed via **raw SPI register dump** (bypassing `mcp_can` entirely):
   read CANINTF, saw `RX0IF`/`RX1IF` set, manually pulled RXB0 registers
   and got a real decoded frame:
   ```
   RXB0 raw: C7 6A FF 21 08 7C 73 23 03 00 1A 02 10
   ```
   Decoded: ID = **0x18EEFF21** (J1939 Address Claimed, PGN 0xEE00,
   source address 0x21 = the BHM). Confirmed 250kbps / 8MHz timing is
   correct — this exact ID also appeared in the Pi 5 reference capture.

### Root cause
The `mcp_can` library (coryjfowler v1.5.1) has an unreliable RX buffer
read path on the R4's Renesas RA4M1 SPI implementation. Single-register
reads worked fine; multi-byte sequential buffer reads via the library's
`readMsgBuf()` did not reliably retrieve data, causing RX0OVR even though
the chip itself was working perfectly.

### Fix
**Abandoned the `mcp_can` library entirely.** Final firmware talks
directly to the MCP2515 over raw `SPI.h` calls — see Section 4. Also
dropped SPI clock to 1MHz (from the library's default 10MHz request,
which the R4's SPI clock divider couldn't hit precisely anyway — RA4M1
SPI clock is derived from the 48MHz system clock via integer dividers,
practically capping out well under 10MHz per community testing).

---

## 4. Final firmware

Located in this directory as `can_sniffer_final.ino` (or similar).
Key properties:
- No `mcp_can` library dependency — raw SPI register access only.
- Bit timing: CNF1=0x00, CNF2=0xB1, CNF3=0x85 → **250kbps @ 8MHz crystal**.
- Uses the MCP2515's dedicated **READ RX BUFFER instruction** (0x90/0x94)
  which auto-clears the RX interrupt flag on CS release — the
  datasheet-correct way to drain both mailboxes without missing frames.
- Speaks **SLCAN** ASCII protocol over USB serial (115200 baud):
  `tIIILDD...` (standard frame), `TIIIIIIIILDD...` (extended frame),
  terminated with `\r`.
- `canOpen = true` at boot (auto-opens the CAN channel immediately on
  power-up) — originally added to work around a Windows/SavvyCan
  flow-control issue (see Section 5), harmless and redundant on Linux
  where `slcand` sends a proper `O` command anyway.
- To switch to the 500kbps J1939 engine/chassis bus instead of the 250k
  body/cab bus: change CNF1/CNF2/CNF3 to 500k timing values and reflash.

---

## 5. Windows troubleshooting (historical — superseded by Linux setup)

This section is kept for reference in case Windows is ever revisited.

### Port conflicts
`Error touching serial port 'COM5'... Port busy` — SavvyCan (or Arduino
Serial Monitor) was holding COM5 open during an upload attempt. Fix:
disconnect/close whichever program has the port before flashing.
**Only one client can hold a COM port at a time** — this applies to
Serial Monitor, SavvyCan, and the uploader.

### SavvyCan showing data in console but never in the main grid
Root cause found by reading SavvyCan's actual source
(`connections/lawicel_serial.cpp` on GitHub):
- SavvyCan's LAWICEL serial driver sets **hardware flow control**
  (`serial->setFlowControl(serial->HardwareControl)`), with a
  `NoFlowControl` alternative commented out in the source. The R4's
  USB-CDC implementation doesn't satisfy the flow control handshake
  Windows/Qt expects, so **SavvyCan's outgoing commands (`C`, `S`, `O`)
  never actually reached the firmware**, even though incoming frame data
  flowed fine and showed in the Device Console.
- Workaround: firmware auto-opens the CAN channel at boot (`canOpen =
  true`) instead of waiting for an `O` command that can't arrive.
- Even after that, the **main grid required clicking "Save Bus Settings"**
  after connecting — this calls `piSetBusSettings()` internally, which
  is what actually arms the live capture queue/model for that bus. Just
  connecting was not sufficient on this SavvyCan build (V208).

### Verdict
Windows' LAWICEL/serial flow-control quirks made this unreliable enough
that the project moved to Linux (Kali) using SocketCAN, which sidesteps
the entire serial-parsing layer.

---

## 6. Linux (Kali) setup — the path that actually worked well

### 6.1 Install can-utils and fix permissions
```bash
sudo apt update && sudo apt install can-utils
sudo usermod -aG dialout $USER
# log out/in, or: newgrp dialout
```

### 6.2 Flash firmware
Same `.ino` as Section 4. Board: Arduino Uno R4 WiFi. Port: whichever
`/dev/ttyACM#` shows up (see 6.6 re: device number drift).

### 6.3 Find the device
```bash
ls -l /dev/ttyACM*
dmesg | tail -20        # if it's not showing up
```

### 6.4 Attach as a SocketCAN interface via slcand
```bash
sudo slcand -o -c -s5 -S 115200 /dev/ttyACM0 can0
sudo ip link set up can0
```
Flags:
- `-o` — open the CAN channel on start
- `-c` — close first, then reopen (clean handshake state)
- `-s5` — SLCAN bitrate code 5 = 250kbps (firmware ignores this since
  timing is hardcoded, but slcand still sends it as part of the
  standard handshake)
- `-S 115200` — serial baud rate, must match `Serial.begin()` in sketch

### 6.5 Verify and sniff
```bash
ip -details -statistics link show can0
candump can0
```

### 6.6 Device number drift (ttyACM0 → ttyACM1, etc.) — NORMAL behavior
Linux assigns `ttyACM` numbers by enumeration order, not by physical
device identity. Unplugging/replugging (e.g. walking the R4 down to the
truck bay) can bump the number up. **Always check `ls -l /dev/ttyACM*`
fresh before running slcand** — don't assume ACM0.

**Permanent fix — udev rule for a fixed device name:**
```bash
udevadm info -a -n /dev/ttyACM1 | grep -E 'ATTRS\{idVendor\}|ATTRS\{idProduct\}|ATTRS\{serial\}' | head -5

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

### 6.7 Port/interface conflicts when reflashing
If Arduino IDE fails to upload with a "no device found" type error and
`dmesg` shows the ACM device already claimed by slcan:
```bash
sudo ip link set can0 down
sudo pkill slcand
sudo fuser /dev/ttyACM0      # confirm nothing still holds it
```
Then flash, then reattach (6.4).

### 6.8 Testing can-utils in isolation (optional, no hardware needed)
Useful for confirming tool behavior independent of the R4/BHM chain:
```bash
sudo modprobe vcan
sudo ip link add dev vcan0 type vcan
sudo ip link set up vcan0

candump vcan0                              # terminal 1
cansend vcan0 123#DEADBEEF                 # terminal 2, standard ID
cansend vcan0 18EEFF21#0102030405060708    # extended ID (J1939-style)

# cleanup
sudo ip link set vcan0 down
sudo ip link delete vcan0
```
Note: SocketCAN loopback means your own `cansend` frames echo back to
local `candump` regardless of physical bus state — this proves the
software chain, not real bus receive. Real external traffic (from the
BHM) is the actual proof of a working receive path.

### 6.9 SavvyCAN install (AppImage, Kali)
```bash
cd ~/Downloads
chmod +x SavvyCAN*.AppImage
./SavvyCAN*.AppImage
```
If it fails with a FUSE-related error (common on newer Kali/Debian bases
where `libfuse2` was renamed as part of the 64-bit time_t transition):
```bash
apt search libfuse2
sudo apt install libfuse2t64
# or, if that's unavailable:
sudo apt install fuse3 libfuse3-3
```
If FUSE still won't cooperate, extract and run directly instead:
```bash
./SavvyCAN*.AppImage --appimage-extract
cd squashfs-root
./AppRun
```
Optional: moved to `~/Applications/SavvyCAN.AppImage` with a
`.desktop` launcher in `~/.local/share/applications/` for menu access.

### 6.10 SavvyCAN connection (Linux)
Connection → Add New Device Connection →
**"QT SerialBus Devices (SocketCAN, PeakCAN, etc.)"** → select `can0`.

This talks to the kernel's native CAN stack directly — a completely
different, more mature code path than the Windows LAWICEL serial driver
that caused the flow-control problems in Section 5. No port-busy
handshake issues, no "Save Bus Settings" workaround needed.

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
| Validated against | Raspberry Pi 5 native socketcan capture (independent second platform) |

---

## 8. Daily session checklist (quick reference)

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

## 9. slcand bitrate code reference

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
