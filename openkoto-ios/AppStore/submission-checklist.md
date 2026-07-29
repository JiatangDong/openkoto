# App Store submission checklist

- [ ] Apple Developer agreements are active.
- [ ] `com.openkoto.ios` and `com.openkoto.ios.ShareExtension` belong to the release team.
- [ ] `group.com.openkoto.ios` is enabled for both targets.
- [ ] Marketing version is final; build number is unique.
- [ ] Release archive is built with Xcode 26 / iOS 26 SDK or later.
- [ ] Release build is tested on a physical iPhone.
- [ ] Share Extension is tested from Safari and Notes.
- [ ] iPad layout is tested in both orientations (split explanation pane, adaptive grids).
- [ ] Mac Catalyst build is tested — see `AppStore/catalyst-smoke.md`.
      Run `scripts/check-catalyst-keychain.sh` first: without a provisioning profile
      the app is signed with no keychain access group and every API Key write fails
      silently. CLI builds need `-allowProvisioningUpdates`.
- [ ] CloudKit schema is deployed to Production (CloudKit Dashboard > Schema >
      Deploy Schema to Production). **TestFlight and App Store builds use the
      Production environment**; without this every tester's sync fails while the
      Xcode build keeps working, which reads as "it broke on device".
- [ ] Universal Purchase is enabled so the Mac build ships with the iOS app.
      Without it the Mac stays on a Development build and the two devices sync
      to different environments, so they never see each other's data.
- [ ] iPhone 6.9-inch screenshots are uploaded.
- [ ] iPad 13-inch screenshots are uploaded.
- [ ] Mac screenshots are uploaded.
- [ ] Price is Free and availability is selected.
- [ ] Privacy policy and support URLs return HTTP 200.
- [ ] App Privacy answers match the shipped binary and selected AI providers.
- [ ] App Privacy declares iCloud sync: words, review history, article text and
      AI explanations are stored in the user's own iCloud private database.
      Book and video files are never uploaded.
- [ ] Updated age-rating questionnaire is complete.
- [ ] Content-rights declaration is complete.
- [ ] Export-compliance questions are complete.
- [ ] DSA trader status is complete if distributing in the EU.
- [ ] Mainland China is excluded unless required compliance information is ready.
- [ ] Review contact details are current.
- [ ] Optional AI reviewer credentials are added or the review note states how to test without them.
- [ ] Release method is set to manual release for the first version.
