# Local Screen Share

A Flutter desktop app for sharing the current computer screen to browsers on
the same private Wi-Fi/LAN. macOS uses ScreenCaptureKit. Windows uses a native
Win32/GDI+ capture path and serves the same local MJPEG viewer on port 8080.

## Run

```sh
flutter run -d macos
flutter run -d windows
```

On Windows, allow the app through Windows Defender Firewall when prompted so
other devices on the LAN can open the viewer URL.

## Build

```sh
flutter build macos
flutter build windows
```
