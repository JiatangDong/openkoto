# App Review notes

OpenKoto does not require registration or sign-in.

To review the app without external credentials:

1. On first launch, pick an interface language, then continue through the introduction. The AI setup step can be skipped.
2. Open one of the included public-domain sample articles.
3. Tap a sentence to open the reading and vocabulary interactions.
4. Tap the phonetic-character button in the reader toolbar to show word-level readings (furigana for Japanese, pinyin for Chinese). This runs entirely on device and needs no network or AI configuration.
5. Open the Vocabulary and Statistics tabs to review the local study features.
6. Text, TXT/Markdown/EPUB file, URL, and share-extension imports are available from the Library. Imported books are stored only on the device.
7. Settings > "Replay Welcome Guide" reopens the introduction at any time.

Word-level readings are produced with the system text tokenizer (CFStringTokenizer) on device. No text leaves the device for this feature.

AI translation and explanation are optional BYOK features. A user may configure their own compatible provider and API key in Settings. The API key is stored in the iOS Keychain. Requests go directly from the device to the provider selected by the user and do not pass through an OpenKoto app server.

If App Review needs to test the optional AI flow, provide a temporary, revocable, low-quota provider configuration here before submission:

- Provider:
- Base URL:
- Model:
- Temporary API key:

Privacy policy: https://www.openkoto.com/privacy-policy
Support: https://github.com/hikariming/OpenKoto/issues
