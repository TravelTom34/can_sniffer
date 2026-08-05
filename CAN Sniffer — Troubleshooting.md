# CAN Sniffer — Troubleshooting

This file covers every dead end hit while building this tool, with root
causes, so they don't have to be rediscovered. For setup instructions, see
the main [`README.md`](../README.md).

---

## 1. Arduino IDE: `mcp_can.h: No such file or directory`

```
fatal error: mcp_can.h: No such file or directory
```

**Cause:** this error only applies if you're compiling an older sketch that
still depends on the `mcp_can` library (by coryjfowler). The final firmware
in `firmware/Final_sketch_IDE` does **not** need this library at all — see
Section 2 below for why it was dropped.

If you do need it for some other sketch: Library Manager → search
`mcp_can` → install the coryjfowler version. Default sketchbook location on
Windows: `C:\Users\<you>\sketchbook\libraries\mcp_can\`.

---

## 2. Bit-timing / crystal debugging (root cause of early "no frames" issue)

### Symptom progression

1. Loopback mode (`MCP_LOOPBACK`) worked immediately — proved SPI wiring,
   power, and basic firmware logic were correct. **Loopback does NOT
   validate bit timing against a real bus** — both TX and RX use the same
   internal clock regardless of correctness.
2. Switched to `MCP_NORMAL` / `MCP_LISTENONLY` on the real bus: zero frames
   received.
3. A diagnostic sketch added error-register reporting:
   - `errFlag=5` (`CAN_CTRLERROR`) with `rxErrCount=0` — this ruled out a
     simple bit-timing mismatch (a timing mismatch would climb
     `rxErrCount`).
4. Decoded the raw `EFLG` register directly → **`RX0OVR`** (RX buffer 0
   overflow). This proved: **valid frames WERE arriving and being decoded
   correctly by the MCP2515** — the failure was entirely in the `mcp_can`
   library's read path (`checkReceive()`/`readMsgBuf()`), not the bus,
   wiring, or bit timing.
5. Confirmed via a **raw SPI register dump** (bypassing `mcp_can` entirely):
   read `CANINTF`, saw `RX0IF`/`RX1IF` set, manually pulled the RXB0
   registers and got a real decoded frame:
   ```
   RXB0 raw: C7 6A FF 21 08 7C 73 23 03 00 1A 02 10
   ```
   Decoded: ID = **0x18EEFF21** (J1939 Address Claimed, PGN 0xEE00, source
   address 0x21). This confirmed 250kbps / 8MHz timing was correct.
   (Earlier in this project, this ID was additionally cross-checked against
   an independent Raspberry Pi 5 SocketCAN capture of the same bus — see
   `additional_projects/raspberry_pi_reference_platform.md` — but that
   platform is not part of the current build.)

### Root cause

The `mcp_can` library (coryjfowler, v1.5.1) has an unreliable RX buffer read
path on the R4's Renesas RA4M1 SPI implementation. Single-register reads
worked fine; multi-byte sequential buffer reads via the library's
`readMsgBuf()` did not reliably retrieve data, causing `RX0OVR` even though
the chip itself was working perfectly.

### Fix

Abandon the `mcp_can` library entirely. The firmware in
`firmware/Final_sketch_IDE` talks directly to the MCP2515 over raw `SPI.h`
calls. Also drop the SPI clock to 1MHz (from the library's default 10MHz
request, which the R4's SPI clock divider couldn't hit precisely anyway —
RA4M1 SPI clock is derived from the 48MHz system clock via integer
dividers, practically capping out well under 10MHz per community testing).

---

## 3. Windows (historical — superseded by Linux setup)

Kept for reference in case Windows is ever revisited. **The recommended
platform for this project is Linux** (see the main README); these issues
don't apply there.

### Port conflicts

```
Error touching serial port 'COM5'... Port busy
```

SavvyCan (or the Arduino Serial Monitor) was holding COM5 open during an
upload attempt. **Only one client can hold a COM port at a time** — this
applies to Serial Monitor, SavvyCan, and the uploader. Fix: close whichever
program has the port before flashing.

### SavvyCan showing data in the console but never in the main grid

Root cause found by reading SavvyCan's own source
(`connections/lawicel_serial.cpp` on GitHub):

- SavvyCan's LAWICEL serial driver sets **hardware flow control**
  (`serial->setFlowControl(serial->HardwareControl)`), with a
  `NoFlowControl` alternative commented out in the source. The R4's USB-CDC
  implementation doesn't satisfy the flow-control handshake Windows/Qt
  expects, so **SavvyCan's outgoing commands (`C`, `S`, `O`) never actually
  reached the firmware**, even though incoming frame data flowed fine and
  showed in the Device Console.
- Workaround: the firmware auto-opens the CAN channel at boot
  (`canOpen = true`) instead of waiting for an `O` command that can't
  arrive.
- Even after that fix, the **main grid required clicking "Save Bus
  Settings"** after connecting — this calls `piSetBusSettings()`
  internally, which is what actually arms the live capture queue/model for
  that bus. Just connecting was not sufficient on this SavvyCan build
  (V208).

### Verdict

Windows' LAWICEL/serial flow-control quirks made this unreliable enough
that the project moved to Linux (Kali) using SocketCAN, which sidesteps the
entire serial-parsing layer.

---

## 4. Linux: `/dev/ttyACM#` number changes between plug-ins

Linux assigns `ttyACM` numbers by enumeration order, not by physical device
identity, so unplugging/replugging the R4 can bump the number (e.g.
`ttyACM0` → `ttyACM1`). Always run `ls -l /dev/ttyACM*` fresh before running
`slcand` — don't assume `ACM0`.

**Permanent fix:** set up a udev rule for a fixed device name — see README
Section 4.6.

---

## 5. Port/interface conflicts when reflashing

If the Arduino IDE fails to upload with a "no device found" type error and
`dmesg` shows the ACM device already claimed by `slcan`:

```bash
sudo ip link set can0 down
sudo pkill slcand
sudo fuser /dev/ttyACM0      # confirm nothing still holds it
```

Then flash, then reattach (README Section 4.4).

---

## 6. Testing can-utils in isolation (no hardware needed)

Useful for confirming `can-utils`/SocketCAN behavior independent of the
R4/bus hardware chain:

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

**Note:** SocketCAN loopback means your own `cansend` frames echo back to
local `candump` regardless of physical bus state — this proves the software
chain, not real bus receive. Real external traffic is the actual proof of a
working receive path.

---

## 7. SavvyCAN AppImage fails with a FUSE error (Kali/Debian)

Common on newer Kali/Debian bases where `libfuse2` was renamed as part of
the 64-bit `time_t` transition:

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

Optional: move it to `~/Applications/SavvyCAN.AppImage` with a `.desktop`
launcher in `~/.local/share/applications/` for menu access.
