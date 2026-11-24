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

## Valet mode (owner idea 2026-11-24)
When no known phone is connected over Bluetooth (or a valet PIN has not been entered), the unit runs in valet
mode: only the allowed apps are usable, every other app is hidden, and ALL notifications are suppressed.

Allowed in valet mode (owner, 2026-11-24): Google Maps; the radio (`com.microntek.radio`); the HCT Bluetooth app
(`com.microntek.bluetooth`, hands-free calls); the front and rear camera apps (`com.microntek.frontview`,
`com.microntek.backview`). The rear camera is started by CarService on reverse gear and must never be
suspended. System packages the allowed apps depend on (SystemUI, the HCT services, the launcher itself)
are never suspended.

| Part | Mechanism (stock Android 14, needs the launcher as a platform-signed system app) |
|---|---|
| Only the allowed apps | `PackageManager.setPackagesSuspended()` for every other user-facing app: suspended apps cannot start and cannot show notifications; lifted on unlock |
| No notifications | Do Not Disturb "total silence" (`NotificationManager.setInterruptionFilter(INTERRUPTION_FILTER_NONE)`) while in valet mode |
| No escape routes | `StatusBarManager.disable()` (no notification shade, no quick settings); Settings suspended; home/recents only show the allowed apps |
| Enter | automatically when no trusted phone connects over BT within a timeout after start; or manually |
| Exit | a trusted phone connects over BT (needs the HCT Bluetooth stack), or the valet PIN on the launcher |

Expected and accepted: banking apps will complain about the unlocked, uncertified build regardless.

## Car settings (owner, 2026-11-24) - in the launcher's settings
| Setting | Options | Default (owner's preference) | Hook |
|---|---|---|---|
| Car lights on -> backlight | nothing / dim to N % | **nothing** | illumination signal from CarService (`sta_ill`, sysprop `headlight`) |
| Car lights on -> theme | nothing / dark | **nothing** | same signal |
| Dark mode | follow day/night cycle (sunset/sunrise from location) / always light / always dark / follow car lights | **day/night cycle** | `UiModeManager` night mode (auto / custom schedule); the launcher's own theme follows the system night mode |
| Reverse gear -> volume | unchanged / lower to N % / mute | **lower** (owner lowers volume while reversing/parking) | reverse event from CarService (`CAR_A_RPT_BACKVIEW_START` / backview start); the MCU driver also has a native `ctl_backview_vol` command, so the attenuation can be left to the MCU, with the launcher only setting the level |

The launcher itself follows the system light/dark theme, so one setting drives both.

## Day and night theming
The home screen has a **day** and a **night** theme and switches with the system night mode (by default the
day/night cycle, see Car settings), animated rather than abrupt.

| Element | Day | Night |
|---|---|---|
| Background / cards | light, high-contrast for sunlight | dark, low-luminance surfaces, no pure white anywhere (no glare while driving) |
| Map card | Maps/Waze in light mode | Maps/Waze in their own night style; both follow the system night mode, so no extra work |
| Media card | album art with a light tinted backdrop | album art dimmed, backdrop tinted from the art's dark palette |
| Rain radar | light basemap, saturated rain colours | dark basemap, muted rain colours so the radar does not glow |
| Clock | dark digits | dimmed light digits |
| Accent colour | from the album art / wallpaper (Material You palette) | same hue, lower brightness |

Implementation: Android resources with `-night` qualifiers (`values-night`, `drawable-night`), so the switch is
the standard `UiModeManager` configuration change; Material 3 dynamic colour for the accents. Night mode can
also dim the panel backlight if the owner later enables "car lights -> backlight".
