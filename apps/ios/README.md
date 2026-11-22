# Matilde for iPhone

The iOS app. SwiftUI, iOS 26, iPhone first: notes library, Markdown editor, private comments, Ask Matilde reviews and threads, sync with the Mac, export and share. Shared sync and encryption code comes from [MatildeKit](../../packages/MatildeKit/README.md). Plan: shared project file `ios-plan.md`; items in [ROADMAP](../../ROADMAP.md) (IOS-01…).

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
| `Matilde/MatildeApp.swift` | App entry; wires the library to sync |
| `Matilde/RootView.swift` | Notes list by folder (`NavigationSplitView`), pull down to search (IOS-14), new note/folder, swipe to delete, sync attention; hosts the splash, first-run tour and sync setup |
| `Matilde/SyncOnboardingView.swift` | Guided sync setup, one step per screen (IOS-12); `SyncCallToAction` |
| `Matilde/FirstRunView.swift` | Launch splash and first-run tour (IOS-13) |
| `Matilde/Brand.swift` | Landing-page button colours, primary and secondary button styles, shake effect |
| `Matilde/NoteLibrary.swift` | The notes on this phone: a MatildeKit `Workspace` in Application Support (IOS-04) |
| `Matilde/SyncController.swift` | Sign-in, Matilde key, sync runs on foreground, live channel and poll (IOS-03) |
| `Matilde/NoteEditorModel.swift`, `NoteEditorView.swift`, `NoteTextView.swift` | Editor (IOS-05): title, goal, autosave, TextKit 2 text view with Markdown styling, keyboard bar, edit menu, highlights; share and Markdown export |
| `Matilde/MarkdownStyle.swift` | Markdown spans and attributes (Newsreader, Mac heading steps) |
| `Matilde/CommentStore.swift`, `CommentSheets.swift` | Private comments (IOS-06) |
| `Matilde/ThreadSheet.swift` | Ask Matilde thread: explanation, timeline, streaming reply, Accept (IOS-08) |
| `Matilde/SettingsView.swift` | Settings: Sync (call to action, or status, account and devices), Connections (Langdock key, region, model), About (Show Welcome Again) |
| `Matilde/Paper.swift` | Matilde's paper colours and Newsreader type (fonts shared with the Mac app) |
| `Matilde/Assets.xcassets` | App icon from `scripts/app-icon.py` (IOS-11); launch screen colour and logo (IOS-13) |
| `MatildeTests/` | Swift Testing tests (the onboarding logic is tested in MatildeKit, `OnboardingTests`) |

CI: the `ios` job in `.github/workflows/ci.yml` (macos-26) generates the project and runs the tests on the iPhone simulator.

To see the first-run tour again: Settings → About → Show Welcome Again (or delete the app). To see the sync setup again: Settings → Sync → Sign Out, then Set Up Sync.
