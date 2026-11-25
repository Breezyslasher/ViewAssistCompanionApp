# VACA for iOS / iPadOS

An iOS port of the View Assist Companion App: it turns an iPad (or iPhone)
into a Home Assistant smart display with voice control, using the same VACA
integration as the Android app.

## What works

- Full-screen Home Assistant / View Assist dashboard, kept awake
- On-device wake word with the Android app's microWakeWord models: Hey Jarvis,
  Okay Nabu, Alexa, Hey Mycroft, Hey Luna, Hey Home Assistant
- The Android voice pipeline: wake sound, listening, response playback,
  continued conversation, "stop" to interrupt a response or an alarm
- Announcements and start conversation from Home Assistant
- Media player (play, pause, stop, volume) with ducking, alarms, toast messages
- Screen brightness, timeout and "screen off", dark mode, zoom, navigate, refresh
- Battery, orientation and current path sensors
- Voice keeps working with the screen locked

Not available on iOS: camera motion and streaming, light/proximity sensors,
Bluetooth proxy, Sendspin, openWakeWord models, custom wake words (yet), and
turning the screen fully off (iOS apps can't; it goes black at zero brightness).

## Install (sideload)

1. Open the latest **iOS app** run under Actions (or a release) and download
   `VACA.ipa`.
2. Install it with [Sideloadly](https://sideloadly.io), [AltStore](https://altstore.io)
   or [SideStore](https://sidestore.io), signing with your Apple ID. With a free
   Apple ID the app must be re-signed every 7 days (AltStore/SideStore can do
   this automatically).
3. Open VACA and allow the microphone and local network.

## Set up

1. Install the VACA integration in Home Assistant (HACS) if you haven't.
2. With VACA open on the iPad, Home Assistant discovers it:
   Settings → Devices & services → Discovered → VACA.
3. On the device page in Home Assistant, choose the wake word. The app sets
   the wake word engine to microWakeWord itself.
4. For a wall display: plug the iPad in, and use Guided Access
   (Settings → Accessibility → Guided Access) to keep VACA on screen.

## Building

CI (`.github/workflows/ios.yml`) builds an unsigned `.ipa` on a macOS runner,
so no Mac is needed. To build locally on a Mac:

```
cd ios
brew install xcodegen
xcodegen generate
pod install
open VACA.xcworkspace
```

`VACACore` (Wyoming protocol, the voice pipeline state machine, microWakeWord
feature extraction) has unit tests: `cd ios/VACACore && swift test`.

## Credits

A port of the Android app by Mark Parker (Apache-2.0; see `../LICENSE` and
`../NOTICE`). The wake word models, sounds and icon are the Android app's
assets. The audio frontend is TensorFlow Lite's micro frontend (Apache-2.0)
with KISS FFT (BSD-3-Clause), as in the Android `:microfeatures` module.
