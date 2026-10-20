# Gotcha ガチャ

A 3D Japanese gachapon machine full of affirmations. Turn the handle, a capsule rolls out, tap it to open your message. Messages come from a shuffle deck, so you see all 9 before any repeats.

## Web — `web/`

Three.js in a single file. Open `web/index.html` in a browser, or serve the folder:

```sh
cd web && python3 -m http.server 8000
```

## iOS — `ios/`

SwiftUI + SceneKit, iOS 16+. The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
cd ios && xcodegen
open Gotcha.xcodeproj
```

Pick your team under Signing & Capabilities, then run on a device or simulator. Turning the handle uses haptics instead of sound.
