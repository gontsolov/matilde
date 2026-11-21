# Matilde for iPhone

The iOS app (IOS-01 skeleton). SwiftUI, iOS 26, iPhone first. Shared sync and encryption code comes from [MatildeKit](../../packages/MatildeKit/README.md). Plan: shared project file `ios-plan.md`; items in [ROADMAP](../../ROADMAP.md) (IOS-01…).

## Build

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) and not committed.

```sh
brew install xcodegen
cd apps/ios
bash scripts/generate-project.sh
open Matilde.xcodeproj
```

Run the Matilde scheme on an iPhone simulator. Tests (Swift Testing) run with ⌘U or:

```sh
xcodebuild test -project Matilde.xcodeproj -scheme Matilde \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
```

Running on a device or TestFlight needs a development team (`DEVELOPMENT_TEAM` in `project.yml`), which waits for the Apple Developer Program membership (IOS-07).

## Layout

| Path | Contents |
| --- | --- |
| `Matilde/MatildeApp.swift` | App entry |
| `Matilde/RootView.swift` | Notes list and detail (`NavigationSplitView`), search, empty state, Settings |
| `Matilde/NoteLibrary.swift` | Observable list of notes; the sync server choice from MatildeKit |
| `Matilde/NoteReader.swift` | Read-only note view |
| `Matilde/SettingsView.swift` | Settings sheet |
| `Matilde/Paper.swift` | Matilde's paper colours and Newsreader type (fonts shared with the Mac app) |
| `MatildeTests/` | Swift Testing tests |

CI: the `ios` job in `.github/workflows/ci.yml` (macos-26) generates the project and runs the tests on the iPhone simulator.
