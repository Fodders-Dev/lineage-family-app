# RuStore Release Checklist

## Build Setup
- Configure signing with `android/release-signing.properties` or `LINEAGE_KEYSTORE_*` env vars.
- Configure RuStore IDs with `LINEAGE_RUSTORE_APPLICATION_ID` and `LINEAGE_RUSTORE_PUSH_PROJECT_ID` if the defaults must be overridden for a different app/project.
- Use `customApi` production preset only.
- Verify backend URLs and websocket URL before build.
- Set `LINEAGE_BUILD_NAME` and `LINEAGE_BUILD_NUMBER` when preparing a real store release instead of reusing debug metadata.
- Do not hardcode `org.gradle.java.home` in the repo. Use local `JAVA_HOME` or Android Studio JBR on the build machine.

## Build Commands
### Windows
```powershell
$env:LINEAGE_RELEASE_SIGNING_PROPERTIES="C:\path\to\release-signing.properties"
$env:LINEAGE_BUILD_NAME="1.0.2"
$env:LINEAGE_BUILD_NUMBER="9"
powershell -ExecutionPolicy Bypass -File .\tool\build_rustore_release.ps1
```

### Linux
```bash
export LINEAGE_RELEASE_SIGNING_PROPERTIES=/absolute/path/to/release-signing.properties
export LINEAGE_BUILD_NAME=1.0.2
export LINEAGE_BUILD_NUMBER=9
./tool/build_rustore_release.sh
```

## Build Artifact
- Release bundle path: `build/app/outputs/bundle/release/app-release.aab`
- The safe wrapper builds through a junction path, so the artifact still lands in the real repo `build/` directory.

## Terminal Upload To RuStore
- RuStore supports terminal publication through the official Public API after you generate an app-scoped API key in RuStore Console.
- In the current console state for this app, `API RuStore` is not connected yet, so terminal upload is blocked until a private key is created and saved once.
- For `AAB` publication RuStore also requires an uploaded app signing key in the `Подпись приложения` section before the file upload starts.

### Windows PowerShell
```powershell
$env:RUSTORE_KEY_ID="your-key-id"
$env:RUSTORE_PRIVATE_KEY_BASE64="base64-private-key-from-rustore-console"
powershell -ExecutionPolicy Bypass -File .\tool\publish_rustore_release.ps1 `
  -MinAndroidVersion 7 `
  -WhatsNewFile ".\docs\rustore_whatsnew_1.0.2.txt" `
  -ModeratorComment "Тестовый аккаунт: codex.tree.20260327120500@example.com / Test123456" `
  -SubmitForModeration
```

- Prefer `-WhatsNewFile` with a UTF-8 text file over inline `-WhatsNew`, otherwise RuStore release notes may end up with broken Cyrillic encoding.

### Official API References
- Auth token: `POST https://public-api.rustore.ru/public/auth`
- Create draft: `POST https://public-api.rustore.ru/public/v1/application/{packageName}/version`
- Upload AAB: `POST https://public-api.rustore.ru/public/v1/application/{packageName}/version/{versionId}/aab`
- Submit draft: `POST https://public-api.rustore.ru/public/v1/application/{packageName}/version/{versionId}/commit?priorityUpdate=0`

## Mandatory Smoke On Android 13+
- Fresh install, cold start, login, logout, session restore.
- Create/open tree, add 8-12 relatives, edit at least 2 cards.
- Open chat from relatives list and person card, send text and image, reopen chat.
- Receive local notification, tap it, verify route opens the correct screen.
- Background/resume app, retry under flaky network, verify no broken half-loaded state.
- Check RuStore update/review entry points from app settings.

## Release Gate
- `flutter test` passes fully.
- `flutter analyze` has no new compile errors; existing backlog is tracked separately.
- Backend API tests for auth/tree/chat/notifications/push devices pass.
- Release `appbundle` is built from a clean repo without manual local file edits.
