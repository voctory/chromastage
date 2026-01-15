# Chromastage

Native macOS visualizer with Apple Music control and system audio capture.

## Run

1. Open `Chromastage.xcodeproj` in Xcode.
2. Select the `Chromastage` scheme and run.
3. On first run, macOS will ask for Screen Recording permission. Grant it in System Settings.
4. When prompted, allow the app to control Apple Music (Automation permission).

## Notes

- Audio capture uses ScreenCaptureKit (macOS 13+).
- The visualizer reads system audio (includes Apple Music). Some protected streams can be muted by the system capture APIs.
- If you update the visualizer engine, rebuild and re-copy `butterchurn.iife.js` into `Chromastage/Resources/Visualizer/butterchurn.iife.js`.
