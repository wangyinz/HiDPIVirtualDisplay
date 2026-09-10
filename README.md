# G9 Helper — 8K fork

This fork adds 8K UHD HiDPI presets, fixed-refresh/cursor compatibility,
right-edge Dock repair, persistent physical HDR/color output, and guarded HDMI
reconnection. Current local experimental build: **8.18** (stable baseline: **8.8**), based on upstream 1.2.6. Build this fork from source
below to get these changes; upstream installers contain the upstream version.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/Platform-macOS%2012%2B-lightgrey.svg)](https://www.apple.com/macos/)

Menu bar app that gets you HiDPI (Retina) rendering on the Samsung Odyssey G9 and other monitors that macOS won't give it to natively.

macOS gates HiDPI on pixel density, so big monitors like the G9 don't qualify — you're stuck with either tiny native-res text or blurry scaled rendering. G9 Helper works around this by creating a virtual display with the HiDPI flag set, then mirroring it to your physical monitor. macOS renders at 2x into the virtual framebuffer, and you get sharp text at whatever effective resolution you pick.

## Supported Monitors

| Monitor | Native Resolution | Recommended Setting |
|---------|------------------|---------------------|
| 8K UHD TVs / monitors | 7680x4320 | 5120x2880 HiDPI (150%) |
| Samsung Odyssey G9 57" | 7680x2160 | 5120x1440 HiDPI |
| Samsung Odyssey G9 49" | 5120x1440 | 3840x1080 HiDPI |
| 34" Ultrawide | 3440x1440 | 2560x1080 HiDPI |
| 4K Displays | 3840x2160 | 2560x1440 HiDPI |

Should work with any external display, though it was built for the G9.

## Install

### Homebrew

```bash
brew install knightynite/g9-helper/g9-helper
```

### Manual

Grab [`G9.Helper-v1.2.6.dmg`](https://github.com/knightynite/HiDPIVirtualDisplay/releases/download/v1.2.6/G9.Helper-v1.2.6.dmg) from [Releases](https://github.com/knightynite/HiDPIVirtualDisplay/releases), open it, drag to Applications.

The upstream download is signed and notarized. Local builds of this fork use
an ad-hoc signature unless a Developer ID signing identity is configured.

### Build from source

```bash
git clone https://github.com/wangyinz/HiDPIVirtualDisplay.git
cd HiDPIVirtualDisplay/App
./build.sh
cp -r "build/G9 Helper.app" /Applications/
```

## Usage

Click the display icon in your menu bar, pick your monitor, pick a resolution preset. Takes a few seconds to apply. To turn it off, select **Disable Virtual Display** from the same menu.

### Custom scale

Every monitor submenu has a **Custom Scale...** option — it opens a slider for any factor between 1.1x and 2.0x. The resolution preview updates as you drag.

### Virtual rendering density (build 8.18)

**Virtual Display Rendering → Standard (1×, non-HiDPI)** keeps the virtual
mirror and the selected desktop size while rendering one pixel per logical
point. At 4800×2700, the source framebuffer becomes 4800×2700 instead of
9600×5400. The physical output stays at its configured native timing, so an
8K panel enlarges this image and text may look softer. Fewer source pixels
may reduce composition cost; latency and artifact improvements need testing.

Select **HiDPI (2×)** in the same submenu to restore the higher rendering
density. Both choices preserve the logical preset, virtual refresh rate,
physical refresh rate, HDR and color preferences. Density is saved separately
and applied to standard/custom presets and reconnect recovery. Changing it
briefly restarts the helper to recreate the source. **Disable Virtual Display**
(the former **Disable HiDPI**) still removes the virtual screen entirely.

The helper explicitly selects the requested source mode if macOS restores an
old resolution, and verifies both logical and backing dimensions before and
after mirroring. If a 1× source cannot match the request, it returns to 2×
instead of leaving a 1080p desktop enlarged across the panel.

On the local M4 Pro / QN990F, the first 1× trial selected a cached 1920×1080
mode. Explicit source selection corrected it. The updated build verified a
4800×2700 1× / 90Hz source with native 8K60, HDR10 RGB 12-bit full-range output
and the same logical Dock bounds. Rendering/reconnect tests and universal
build/signature checks passed. The user reported normal display/cursor/Dock
operation and acceptable latency, but substantially blurrier text. The trial
returned to 2× for text clarity; the 1× menu option remains available. This is
not a measured latency improvement or a confirmed artifact fix, and no real
HDMI switch was performed for this rendering mode.

### Faster HDMI switching (build 8.17)

**Settings → Keep Virtual Display During HDMI Switch** is opt-in and requires
Auto-Apply on Reconnect. When the bound monitor disappears and no other real
screen is active, the helper retains its own virtual display and process.
The returning monitor must match the saved identity and pass the existing
native timing gate (three observations over at least two seconds).

If macOS kept the mirror, the helper verifies/pins its native fixed timing.
Otherwise it reattaches the same virtual source. It checks the source ID,
logical/backing dimensions and refresh rate, plus physical native 1:1 geometry
and fixed refresh, before resuming HDR/color and Dock restoration. Stale
scaled target coordinates are detached while waiting. A missing or changed
source or a failed mirror falls back to the bounded full-recovery path.
If the native timing remains unavailable for 30 seconds, the helper pauses
while retaining the source and process; it resumes the stability check when
the requested timing becomes available or the monitor reconnects.

Time spent on the other computer does not consume the returning-link timeout;
there is no active capability polling while the monitor is absent. If the
laptop screen or another physical screen becomes active, the helper releases
the retained desktop through normal cleanup. Disabling this option or
Auto-Apply also returns to normal cleanup. Display/preset changes and quit
cancel pending retained recovery.

This avoids the previous 12-second disconnect teardown, process relaunch and
virtual-screen creation on normal switch cycles. HDMI link negotiation and
required display-mode changes may still blank the TV. A long switch test of 8.15
retained the source for about 11 minutes, but exposed reentrant mirror
transactions during CoreGraphics callbacks. Build 8.16 serializes this path
and verifies the resulting geometry with three asynchronous readbacks over
one second (five-second limit), so transient 1×1 readback does not trigger an
immediate teardown. It logs the first returning mode and native rates.

On that test, the connection eventually offered only 8K 24/25/30Hz and SDR
to a fresh process. Another HDMI switch restored 8K60 and HDR. Software cannot
select a timing absent from the current link; the cause of the link downgrade
remains unconfirmed.

A subsequent 8.16 switch kept the same virtual display and process for about
four minutes and recovered successfully with one mirror transaction. The user
reported normal output but a long wait. Software timestamps showed about ten
seconds from initial 4K120 reporting to 8K60 reporting, then seven seconds to
verified mirror recovery and four more to confirmed HDR. These are software
milestones, not TV-visible latency measurements. Dock repair runs asynchronously;
its logged timeout did not block HDR.

Build 8.17 takes the first geometry sample immediately after the transaction
(while still requiring three samples over one second) and starts saved HDR
restoration as soon as that verification passes, bypassing a redundant 1.5-second
debounce. The normal bounded fixed-refresh/HDR readback remains in place. This
removes about two seconds of scheduled waiting from the retained path; it does
not bypass the HDMI capability/stability gate or force absent 8K60 modes.

Build 8.17 passed 47 recovery checks, 30 connection-readiness assertions, HDR
preference tests and universal build/signature checks. A controlled mirror
detachment restored the same source and process with correct 8K60/90Hz HiDPI
and HDR after about 6.8 seconds. This tests the software repair path, not the
HDMI switch handshake or end-to-end visible latency.

### Experimental virtual refresh (build 8.14)

**Settings → Virtual Refresh (Experimental)** controls virtual render cadence
independently of the physical output. The default is **Match physical output**.
With a physical 60 Hz output, the other options create virtual **75, 90, 94,
98, 101, 105, 113, or 120 Hz** desktops. Increased rates are rounded to whole Hz
before creation and health checks; requests above 240 Hz fall back to the
physical rate. Matched cadence preserves the physical rate without rounding.

On an M4 Pro / Samsung QN990F at 150%, the user found 120 Hz clearly more
responsive than 60 Hz, but saw frequent pink blocks at window edges. At 105 Hz,
latency improved over 90 Hz but small blocks flashed every 3–4 seconds.
90 Hz initially appeared clean, including after a real HDMI switch away/back;
longer use revealed rare blocks while dragging windows too. **These are
experimental tradeoffs, not a corruption-free latency fix.** No end-to-end
millisecond improvement has been measured.

The user chose to stop testing and retain **virtual 90 Hz**, with **Automatic
Composition Budget**, **150%**, and **physical native 8K fixed 60 Hz / HDR10
RGB Full 12 bpc**. The menu retains the other rates for manual comparison.
Physical timing, HDR/color, normal cursor scaling and Dock repair are preserved.
For flashing blocks, select a lower virtual rate or Match physical output.
Noninteger ratios to the physical rate can also make animation cadence uneven.

The stable-link gate and HDR restoration still use the physical rate;
creation, health checks and reattachment verify the virtual rate separately.
Changing a choice cleanly restarts the helper with the same preset and output
preferences. A 120 Hz virtual desktop does not request 8K120 from the TV.

Validation: 175 policy checks, universal arm64/x86_64 build and strict signature
verification. The real 90 Hz HDMI-switch test restored 90/60 Hz, HDR, cursor
and Dock correctly; it did not establish long-term absence of artifacts.
The 4 ms / 60 Hz budget trial had no noticeable latency benefit. A 4 ms /
120 Hz trial still produced the same severe pink artifacts, according to
the user; the shorter budget did not eliminate corruption. No HDR-off or lower-bit-depth trial
was performed.

### Experimental composition budget (local build 8.9)

**Settings → Composition Budget (Experimental)** offers **Automatic**, **8 ms**,
and **4 ms**. Automatic is the default and keeps the existing display path.
The other choices set the optional virtual-display `refreshDeadline` before
creating the virtual screen. Changing the choice restarts the helper and
restores the same preset, physical timing, and HDR/color preference.

On macOS 26.6.2, inspection of the installed SkyLight framework traces this
value to `SLCADisplay::composition_deadline()` and then to the compositor's
work-interval scheduling deadline. The value is in seconds; zero skips the
override. This is a scheduling experiment, **not a measured input-latency
value or a guaranteed latency reduction**. A shorter budget can increase
power use. Use Automatic to return to the previous scheduling behavior.

The implementation accepts only the two experimental budgets, limits the
value to one refresh period, checks runtime selector availability and
settings readback, and falls back to fresh default settings if the optional
API fails. This does not change mirror geometry, physical refresh policy,
or cursor scaling. 23 checks cover conversion, bounds, invalid input,
missing/throwing APIs, rejected readback, and an unattached real settings
object; no display is created by those tests.

### HDR and physical color output (local build 8.7)

Open **HDR & Color Output** while HiDPI is active. The **Current** line reads
the physical display link's selected format. The HDR checkbox and the
**HDR10 Output** / **SDR Output** submenus save preferences for the monitor's
vendor, model and serial identity. SDR and HDR retain separate format choices.

Changes to HDR made in System Settings are also remembered after two stable
samples (about 1–2 seconds). Link teardown, sleep and restoration are excluded
from observation so transient SDR on reconnect does not overwrite HDR On.
After reconnect or mirror setup, fixed physical timing is settled first, then
HDR and the chosen compatible color format are restored and read back.
Unsuccessful repairs stop after three attempts. A saved format unavailable at
the new timing is retained as a preference, with a visible fallback message.

Only exact combinations enumerated by macOS for the current physical timing
are offered: RGB or YCbCr chroma, bits per component, range, and SDR/HDR10.
**Automatic (macOS)** returns that HDR/SDR state to the OS's default format.
Selecting an HDR10 format enables HDR; selecting an SDR format disables it.
The menu's checkmarks indicate saved choices; **Current** indicates readback.

On the tested M4 Pro / Samsung QN990F / macOS 26.6.2 connection, native fixed
7680×4320 at 60 Hz offers HDR10 RGB Full at 12 or 10 bits, and HDR10 YCbCr
4:4:4 or 4:2:0 Limited at 10 bits. RGB Full 12-bit HDR was selected and read
back without changing the physical 1:1 mode, mirror, or fixed refresh.
This is OS-reported link format, not a framebuffer bit-depth inference or
a claim about the panel's native bit depth. Build 8.8 additionally passed one
actual HDMI switch-away/switch-back cycle, as described below.

These controls use dynamically resolved private SkyLight APIs and are disabled
or reported unavailable when unsupported. Runtime validation was on Apple
Silicon; the universal Intel slice was compiled, not hardware-tested.
Run the focused preference tests with **App/Tests/run-display-output-tests.sh**.

### HDMI reconnect protection (local build 8.8)

An HDMI switch can report the same TV and display ID before its full native
timings return. On the tested connection, one switch-back exposed only
8K at 24/25/30 Hz and SDR YCbCr 4:2:0 at 8 bits; a later reconnection restored
8K at 60 Hz and HDR formats. Build 8.7 silently snapped the saved 60 Hz
preference to 30 Hz and accepted a fixed-rate mirror as healthy, even when
the physical coordinate scale was wrong.

Build 8.8 waits for the required native resolution and fixed refresh rate to
appear in three matching observations spanning at least two seconds before
creating or reattaching a mirror. Explicit refresh choices are honored exactly;
Auto retains the previously successful native timing across temporary
capability loss. The selected source rate stays fixed throughout setup.

A readiness check stops after 30 seconds, keeps the native desktop, and
shows a retry message in the menu. A changed capability list or explicit
preset selection can start a new check. An existing mirror with an
incompatible source rate is released through a clean application restart
before recovery. Repeated recovery failures stop automatic restoration
after three retry attempts. The final cleanup removes the failed virtual
display without starting another setup.

After mirroring, the app checks native **1:1 physical coordinates**, the
actual fixed refresh rate, and VRR state. Pinning no longer substitutes a
lower rate or resolution. Temporary HDR unavailability and invalid physical
timing are also excluded from preference capture during shutdown. A manual HDR
toggle that enables VRR at the correct resolution/rate is still observed before
fixed-refresh repair, so the user's HDR choice is preserved.

The focused test runner is **App/Tests/run-display-connection-tests.sh**.
The readiness model covers 30 assertions, including capability flapping,
temporary 4K/30 Hz modes, the absolute deadline, and incorrect physical
scale/rate. A live negative test requested an unavailable 8K120 timing:
the app retained the native desktop for the whole observation, timed out
once without creating a virtual display or restarting, and preserved HDR
preferences. A normal application restart restored 4384×2466 HiDPI, native
1:1 8K60, and HDR10 RGB Full 12-bit on the QN990F. External HDR off/on changes
were also remembered and restored the chosen HDR format without changing
the mirror or native fixed timing. One real switch to another computer and
back also passed: logs captured the disconnect, restoration to native 8K60,
and HDR10 RGB Full 12-bit readback. The user confirmed normal cursor
coordinates, text cursor, right-edge Dock, and HDR after switching back.
This validates that cycle; it does not establish the cause of the earlier
HDMI capability loss or guarantee every switch/cable combination.

## Keep external as main display

If you make your external monitor the primary display (the one with the menu bar), macOS moves it back to the built-in screen after every sleep/wake. Open the menu, go to **Settings**, and turn on **Keep External as Main Display**. G9 Helper then re-asserts your external monitor as the main display whenever it sets up the mirror, including after waking from sleep. It is off by default.

## Resolution Presets

### 8K UHD (7680x4320, 16:9)

Use **8K UHD Displays (7680×4320)** in the menu for an 8K television or
monitor. The G9 57" category is 32:9 and is not the right preset family for
a 7680x4320 panel.

| Looks-like resolution | Scale relative to 8K | HiDPI framebuffer |
|-----------------------|----------------------|-------------------|
| 6144x3456 | 125% | 12288x6912 |
| 5760x3240 | 133.3% | 11520x6480 |
| 5120x2880 | 150% | 10240x5760 |
| 4800x2700 | 160% | 9600x5400 |
| 4384x2466 | approximately 175% | 8768x4932 |
| 4096x2304 | 187.5% | 8192x4608 |
| 3840x2160 | 200% | 7680x4320 |

The 175% preset preserves exact 16:9 with integer dimensions; its actual
scale is approximately 175.18%. **Custom Scale...** in this submenu
calculates other sizes from 7680x4320, with factors from 1.1x to 2.0x.

These modes still use virtual display mirroring. The virtual framebuffer
is resampled to the panel's native output; only the 200% preset matches
the physical pixel grid exactly.

Local build 8.8 keeps the stable output policy: distinguish fixed-refresh
modes from VRR modes with the same maximum rate, then select a **one-to-one
native physical mode after** establishing the mirror. The virtual source
continues to supply the 2x HiDPI desktop. HDR/output changes are checked
after a 1.5-second debounce, with the existing 30-second monitor as backup
and at most three unsuccessful repair attempts.

Build 8.6 repairs right-edge Dock placement after the display configuration
settles. Dock can incorrectly choose the inactive physical mirror target,
whose 7680x4320 bounds extend beyond the virtual desktop. A short,
asynchronous request to the session's Dock placement service moves it back
to the virtual source. The reply is checked and the connection is closed
within two seconds. The repair only applies when our virtual source is
the main display and is the only active desktop; it leaves other display
arrangements alone.

The fix was verified on the M4 Pro / QN990F with macOS 26.6.2: the Dock edge
moved from x=7680 to x=4384 at approximately 175%, the user confirmed that
the right-side Dock appeared, and restarting the app restored the placement
automatically. Physical output stayed at native 8K, fixed 60 Hz. This uses a
private macOS service and may need adaptation after an OS update.

The physical target stays one-to-one, preserving the cursor-compatible
path. An earlier experiment with a 2x physical mode caused arrow and text
cursor disappearance; changing pointer size did not solve it.

**Remaining work:** virtual mirroring still has added mouse latency.
The Dock fix does not establish a latency improvement. Refresh callbacks
and GPU utilization are being compared in a separate test build; neither
is a measurement of end-to-end input latency.

No TV Game Mode setting was changed. This local build is ad-hoc signed,
not Developer ID notarized.

### Samsung G9 57" (7680x2160)

| Preset | Scale | Notes |
|--------|-------|-------|
| 6144x1728 | 1.25x | More space |
| 5908x1662 | 1.3x | |
| 5632x1584 | 1.36x | |
| 5486x1543 | 1.4x | |
| 5297x1490 | 1.45x | |
| 5120x1440 | 1.5x | Recommended — best balance |
| 4800x1350 | 1.6x | Slightly larger UI |
| 4389x1234 | 1.75x | |
| 3840x1080 | 2.0x | Larger text |

### Samsung G9 49" (5120x1440)

| Preset | Notes |
|--------|-------|
| 3840x1080 | Recommended |
| 2560x720 | Native 2x |

## Monitor-aware auto-apply

When you apply a preset, G9 Helper remembers which monitor was connected (by vendor and model ID). Auto-apply on reconnect, crash recovery, and wake-from-sleep will only activate if the same monitor is plugged in. If you switch locations and plug into a different display, the app stays idle instead of trying to apply the wrong configuration. Manually applying a preset on a new monitor updates the binding.

## Auto-start & crash recovery

The app uses private macOS APIs for the virtual display stuff, and those APIs can occasionally crash. So there's a built-in restart mechanism:

**Settings > Start at Login** — this installs a launchd agent that auto-restarts the app after a crash, restores your last preset, and cleans up any orphaned virtual displays.

If you built from source, you can also do it from the command line:

```bash
cd /path/to/HiDPIVirtualDisplay/App
./install-launchd.sh install    # enable
./install-launchd.sh uninstall  # disable
```

## Requirements

- macOS 12+ (Monterey or later)
- Universal binary, runs on both Apple Silicon and Intel Macs
- Apple Silicon horizontal limits:
  - Base chips (M1/M2/M3/M4): up to 6144px horizontal
  - Pro/Max/Ultra: 7680px+ horizontal
- Intel support is new in 1.2.1; if you hit a problem, please open an issue

## Known issues & limitations

- Uses private macOS APIs — could break with future macOS updates
- Physical HDR/color control uses private APIs. The visible HDR & Color Output menu lists compatible link formats and remembers the HDR choice per monitor.
- Since 1.2.3, sleep/wake and brief monitor dropouts keep the existing setup (and your window layout) instead of rebuilding it; if HiDPI ever fails to come back, re-apply the preset from the menu
- Switching presets or disabling HiDPI briefly restarts the app (virtual displays can only be fully torn down when the process exits)
- Refresh rate is auto-detected; if your monitor flickers, set it manually under Settings > Refresh Rate
- Build 8.8 requires the selected fixed refresh rate at native resolution before restoring HiDPI. A temporary 8K30/4K fallback no longer replaces a previously working 8K60 timing. If the link cannot offer the requested mode, the app stays on the native desktop and shows a retry message.
- Mirroring resamples unless the preset's framebuffer matches the panel exactly. On a 7680x2160 panel only the 3840x1080 (2.0x) preset is a 1:1 mirror; every other preset trades a little sharpness for smaller text

## Troubleshooting

**App won't open** — builds from 1.2.6 on are notarized and should open normally. If you are on an older build, or you built from source yourself, right-click the app, select "Open", and confirm in the security dialog.

**Resolution doesn't apply** — disable HiDPI first, wait a few seconds, try again.

**Phantom displays showing up in System Settings** — the app auto-cleans these on launch, but if you see extras, use **Clean Up Phantom Displays** from the menu bar.

**Flickering** — go to Settings > Refresh Rate and manually match your monitor (common with 165Hz/240Hz displays).

**Picture looks soft, or lower resolution than it should** — check `/tmp/g9helper.log` for the `Panel N: native ...` line. It prints the panel's native size and which refresh rates that panel actually offers at that size. If the rate you want isn't listed there, the link can't carry it at full resolution: try a different port or cable, or drop the rate. To rule out the mirror resample entirely, switch to the 3840x1080 (2.0x) preset, which mirrors 1:1 on a 7680x2160 panel.

## How it works

1. Creates a virtual display with the HiDPI flag and a 2x framebuffer
2. Mirrors the virtual display to your physical monitor
3. macOS renders at 2x into the virtual framebuffer
4. The framebuffer gets scaled to your monitor's native resolution

Built with Swift (UI) and Objective-C (display management). The VirtualDisplayManager is compiled without ARC (`-fno-objc-arc`) because the private CGVirtualDisplay APIs need manual memory control.

## Uninstall

1. Menu bar icon > Settings > toggle off **Start at Login**
2. Menu bar icon > **Quit**
3. Trash the app from /Applications

## License

MIT — free software, use at your own risk. This relies on undocumented macOS APIs that Apple could change at any time.

---

Made by AL in Dallas
