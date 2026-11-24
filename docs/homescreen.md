# Home screen / launcher (planned, owner idea 2026-11-24)

A car home screen for the 1024x600 landscape panel, replacing Launcher3 as the default home app.

## Layout (owner's idea)
* **Map card** on one side: Google Maps or Waze running live in a window inside the launcher.
* **Media card**: now-playing title/artist/album art and transport toggles for radio, Spotify, YouTube Music,
  Plexamp (whatever is playing).
* **Stylised rain radar** underneath, plus a **clock**.
* Later: car battery voltage (from the MCU/CAN bus) in the status bar or on the home screen.

## How (feasibility, not yet started)
| Part | Mechanism | Needs |
|---|---|---|
| Map card | WM Shell `TaskView`: the navigation app runs as a real task embedded in the launcher (the mechanism Android Automotive's CarLauncher uses) | launcher as a platform-signed system app (`MANAGE_ACTIVITY_TASKS`); the build is test-keys, so a package in the device tree is signed with the platform key |
| Media card | `MediaSessionManager.getActiveSessions()` with notification-listener access: metadata, album art, play/pause/next/previous for every app with a media session | Spotify, YouTube Music and Plexamp publish media sessions |
| Radio | HCT radio through `CarManager` / its broadcasts, shown as another source in the media card | the HCT framework port (`carservice`) |
| Rain radar | RainViewer public tile API (or Buienradar for NL), rendered in our own style | network |
| Clock | plain view | - |

## Where
Build it as a package in the LineageOS device tree on the build host (`device/rk3399-px6-hct4/`), so it is
platform-signed and installed in `/system/priv-app`; set as the default home. Do the parts that need only
stock Android 14 (map, media, radar, clock) first; radio and battery voltage after the HCT port.
