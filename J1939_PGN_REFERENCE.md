# HD Truck J1939 PGN Reference — Notes

Companion notes for `hd_truck_j1939_reference.dbc`. This is a general-purpose
reference DBC covering standard SAE J1939-71 broadcast messages commonly
found across heavy-duty truck CAN networks — not tied to any single test
vehicle. The M2 BHM used for bench validation was just a convenient known-good
test device; this DBC is meant to be a starting point for whatever network
segment you're actually tapping (cabin, chassis, powertrain, the main J1939
backbone, etc.).

## Categories included

| Category | Messages | Covers |
|---|---|---|
| Powertrain | EEC1, EEC2, EEC3, ET1, EFLP1, LFE, EngineHoursRevolutions, LFC, AMB, IC1, VEP1 | Engine speed/torque, temps, pressures, fuel rate/economy, electrical |
| Transmission | ETC1, ETC2 | Current/selected gear, gear ratio, output shaft speed |
| Chassis | CCVS, EBC1, EBC2 | Vehicle speed, cruise control, ABS/ASR state, brake pedal, wheel speeds |
| Cabin | DD, TimeDate | Fuel/washer fluid level, onboard clock |
| Network Management | AddressClaimed | ECU identity (NAME field) — appears on every J1939 segment, useful for identifying unknown devices on any network you tap |
| Diagnostics | DM1_ActiveDTC, DM2_PreviouslyActiveDTC | Active and previously-active fault codes (lamp status + SPN/FMI) |

All messages assume **source address (SA) = 0x00** in their CAN ID. Real
ECUs claim whatever SA they negotiate on that specific network — edit the
low byte of each message's ID (or regenerate against your actual capture)
once you know the real SA for the ECU you're decoding.

## What's deliberately NOT included, and why

**ADAS / collision-avoidance / driver-assistance systems** — There isn't a
standardized public J1939-71 message set for this the way there is for
engine/brakes/transmission. Forward-collision, lane-departure, and
adaptive-cruise systems (Bendix Wingman, Detroit Assurance, etc.) are
largely **OEM-proprietary PGNs**, not published in the open SAE spec. Adding
fabricated PGN definitions here would be actively misleading — if you want
this data, it has to come from real captures on the actual ADAS network
segment, decoded empirically (which is exactly the kind of reverse-engineering
work this whole toolchain is built for).

**TSC1 (Torque/Speed Control, PGN 0)** — This is a destination-specific
(PDU1 format) message, meaning the CAN ID includes a target ECU address that
varies by which controller is being commanded. It doesn't have one fixed ID
the way broadcast messages do, so it can't be represented as a single static
DBC entry without either guessing wrong or making the DBC misleading.

**VIN (PGN 65260 / 0xFEEC), Software ID, Component ID** — These are
variable-length ASCII fields sent via J1939 Transport Protocol (multi-frame
TP.CM/TP.DT), not single 8-byte frames. SavvyCAN and python-can's J1939
stack both reassemble these automatically when you request them, but they
don't map cleanly onto fixed-width DBC signal definitions the way numeric
PGNs do.

## Using this on a new network segment

1. Tap in, run `candump can0` (or capture in SavvyCAN), confirm bus speed
   first (250k vs 500k — check both if unsure, wrong speed shows either
   silence or bus errors, not partial data).
2. Load this DBC in SavvyCAN (RE Tools → Load DBC File) and see what
   decodes automatically.
3. For every message that decodes with plausible values — good, that PGN
   exists on this segment with a matching SA.
4. For frames that don't match anything in the DBC — that's where the real
   reverse-engineering starts. Note the ID, correlate byte changes against
   known vehicle state changes, and start building new message definitions
   as you confirm them.
5. If an engine-category PGN doesn't show up on, say, the cabin network —
   that's expected. Not every PGN broadcasts on every segment; each network
   only carries what's relevant to the ECUs sitting on it.
