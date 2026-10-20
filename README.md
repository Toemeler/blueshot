# BlueShot

Screenshots of an iPad on a PC over **Bluetooth LE** — no Wi-Fi, no cable, no shared network.

A ReplayKit broadcast extension keeps the newest screen frame while you use any app.
The PC asks for a frame over BLE and gets a JPEG back (1024 px wide by default, ~50–150 KB).

## Install

Add the source to SideStore: <https://toemeler.github.io/blueshot/>
(or `https://toemeler.github.io/blueshot/s.json`). The app contains an extension, so a free
Apple ID uses **2 App IDs** for it.

## Use

1. Open BlueShot once and allow Bluetooth.
2. Tap the round button → **Start Broadcast** (or open `blueshot://start`, then tap Start).
   You can leave the app; locking the iPad ends the broadcast.
3. On the PC:

   ```
   pip install bleak
   python pc/blueshot.py shot.jpg              # one shot
   python pc/blueshot.py shot.jpg --watch 2    # keep refreshing
   ```

Options: `--width` (max px), `--quality` (JPEG 1–100).

## Protocol

Service `B5C0A1E0-6F1D-4E7A-9C3B-2D4F5A6B7C80`.
Write `…81`: `[0x01][maxWidth u16][quality u8][knownSeq u32]`.
Notify `…82`: header `[0xB5][0x01][seq u32][length u32][width u16][height u16]`, then `length`
JPEG bytes. `length` 0 = unchanged since `knownSeq`.

## Build

Every push to `main` builds an unsigned IPA on GitHub Actions (XcodeGen + xcodebuild),
publishes it as release `build-N` and updates `s.json`.
