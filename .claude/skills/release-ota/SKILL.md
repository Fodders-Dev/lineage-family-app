---
description: Выкатить Android-релиз пользователям через OTA (бамп версии → workflow → верификация /v1/app/latest)
disable-model-invocation: true
argument-hint: "[текст release notes для баннера обновления]"
---

# OTA-релиз Android

Единственный канал доставки APK пользователям (RuStore закрыт). Порядок жёсткий:

## 1. Пре-флайт

- `git status` чистый, main запушен, полный `flutter test` зелёный.
- Узнать текущую версию у пользователей:
  `curl -s https://api.rodnya-tree.ru/v1/app/latest` → `versionCode`.

## 2. Бамп версии — ОБЯЗАТЕЛЬНО

- В `pubspec.yaml` поднять `version: X.Y.Z+N` (и name, и code выше текущих).
  Без бампа workflow соберётся, но клиенты НЕ увидят обновление.
- Коммит `chore(release): bump to X.Y.Z+N — <суть>` → push в main.
  ⚠️ push также триггернёт web-deploy (pubspec в path-фильтре) — это нормально.

## 3. Запуск

```bash
gh workflow run android-ota-release.yml -f notes="$ARGUMENTS"
```

- Форс-обновление: добавить `-f mandatory=true` (только по явной просьбе).
- Следить: `gh run watch <id>` (~15 мин: сборка подписанного rustore-release
  APK → upload на сервер → `rodnya-set-android-update` → верификация).

## 4. Верификация

- `curl -s https://api.rodnya-tree.ru/v1/app/latest` — versionCode/notes/sha256
  соответствуют релизу.
- Смоук на эмуляторе/устройстве: приложение предлагает обновление, ставится,
  логинится (после переустановки поверх dev-сборки нужен re-login).

## Откат

Повторный запуск workflow с прежней версией нельзя (versionCode должен расти) —
откат = новый бамп поверх с фиксом. Указатель можно вручную перевести на
сервере: `sudo rodnya-set-android-update` (см. deploy/ota/set_android_update.sh).
