# PLAN: Delightful bulk photo upload (feed + family album)

> Implementation plan for another agent (Codex) to execute. Rodnya = Flutter family app
> (feed «лента» + «Альбом семьи» + tree + chat + calls). North-star: preserve family memory —
> the easier it is to dump a trip's photos, the more memory gets captured. UX bar = Telegram
> (multi-select album, background upload). Repo root `C:/rodnya-tree-app`, client `lib/`,
> backend Node.js `backend/src/`. Ship channel = in-app OTA (see the "Ship" section).
>
> **Scope: all 5 steps below (full фарш). Do them in order — each is independently shippable.**
> Every step: implement → `flutter analyze` clean → add/adjust tests → `flutter test` green →
> adversarial self-review of the diff → commit. Dart SDK is old (~2.17): NO patterns /
> class-modifiers / collection-`?`; `switch` needs `break`. Golden tests fail ~2% locally on
> Windows (environmental, ignore; never `--update-goldens`).

## Root cause of the pain (verified against code)
Gallery multi-select ALREADY exists (`create_post_screen.dart:447` `pickMultipleMedia`), but the
client **hard-caps at 5 photos** even though the **backend accepts 30**
(`backend/src/routes/post-routes.js:161-169` `enforceArrayCap(imageUrls, max:30)`). Within a post,
uploads run **strictly serial** (`custom_api_post_service.dart:118-122` for-loop awaiting each file),
each base64-encoded (+~33%) and POSTed one at a time, **no per-file progress** (compose shows a
static `N/5`), **no background upload** (`create_post_screen.dart` `_isLoading` blocks the whole UI),
**no retry/resume**. The family album (`family_album_screen.dart`) is **read-only** — it's a computed
aggregate over posts' `imageUrls` (`:200-217`, deduped by URL, grouped by month `:452-463`), with
**no upload entry point**. → 40 lake photos = 8 posts of manual compose-select-wait cycles.

**Key gift:** the album is post-derived, so fixing bulk POSTING makes the album fill itself — no new
backend model needed. Backend already supports 30/post + 50MB JSON body (`backend/src/app.js:718`),
so at `imageQuality:80 / maxWidth:1080` (~150-400KB/photo) 30 photos base64 is well under 50MB.

---

## Step 1 — Raise the client cap 5 → 30 (effort: S, ship first)
**Goal:** one multi-select dumps up to 30 photos into one post. Backend already caps at 30 — no
server change.
**Files:** `lib/screens/create_post_screen.dart`.
**Do:**
- Add `const int kMaxPostMedia = 30;` (top of file or class).
- Replace the literal `5` at `:510` (the `if (_selectedMedia.length >= 5)` guard in `_appendMedia`),
  at `:522` and `:525-526` (the cap + trim in `_appendMediaBatch`), and the `${_selectedMedia.length}/5`
  label around `:738`, all with `kMaxPostMedia`.
- Update the trim snackbar copy (`:528-532`) to say the real number (e.g. «Можно добавить до 30 фото
  за один пост»).
- Verify `pickMultipleMedia`/`pickMultiImage` (`:447-458`) has no smaller internal `limit:` arg.
**Acceptance:** picking 30 photos keeps all 30 in the grid preview; 31st is trimmed with the snackbar.

## Step 2 — Parallelize the per-post upload, bounded concurrency ~4 (effort: M)
**Goal:** a 30-photo post uploads ~4× faster, without spiking memory or the 50MB cap.
**Files:** `lib/services/custom_api_post_service.dart` (the `createPost` upload loop `:118-122`).
**Do:**
- Replace the serial `for` loop over `images` with a **bounded-concurrency pool** (max ~4 in flight)
  of `_storageService.uploadImage(...)` calls.
- **Preserve order:** results MUST be reassembled into `imageUrls` by the ORIGINAL pick index, not
  completion order (the feed carousel + album render in array order). E.g. pre-size a
  `List<String?> urls = List.filled(images.length, null)`, write `urls[i] = url` as each finishes,
  then `imageUrls = urls.whereType<String>().toList()` (or fail if any null).
- Do NOT `Future.wait` all 30 at once — `readAsBytes()`+`base64Encode()`
  (`custom_api_storage_service.dart:36-37`) are blocking and will ANR / OOM on Android. Use a worker
  pool that never holds more than ~4 encoded payloads in memory.
- On any file failure, fail the post with a clear error (retry/resume comes in Step 5).
**Acceptance:** 30-photo post completes with all 30 URLs in pick order; peak memory bounded; a forced
single-file failure fails the post cleanly (no partial silent post).

## Step 3 — Per-file progress on the compose screen (effort: M, port from chat)
**Goal:** «Загружено 18 из 30» with a real bar instead of a frozen spinner — the biggest
perceived-speed/trust win. The pattern already exists in chat; this is a port, not new work.
**Reuse:** `lib/models/chat_send_progress.dart` (`ChatSendProgress` stages preparing/uploading/sending
+ `completed`/`total`); chat emits it at `custom_api_chat_service.dart:1952-1958`.
**Files:** `lib/services/custom_api_post_service.dart` (thread an `onProgress` callback through
`createPost`, incrementing `completed` as each file lands, `total = images.length`);
`lib/backend/interfaces/post_service_interface.dart:107` (add the optional `onProgress` param to the
`createPost` signature); `lib/screens/create_post_screen.dart` (subscribe + render on the publish
button / a progress row, reuse the `StatefulBuilder`/modal pattern at `:911-936`).
**Do:** consider a generic `MediaUploadProgress` model (or reuse `ChatSendProgress`) so posts + album
(Step 4) share it. Keep the publish button showing the live count while `_isLoading`.
**Acceptance:** during a 30-photo publish the UI shows a live «Загружено N из 30» that advances; no
frozen spinner.

## Step 4 — Direct upload FAB in the family album (effort: M)
**Goal:** stand inside «Альбом семьи», tap `+`, select 30 photos, they land in the album immediately —
no detour through feed compose. Album is post-derived → **zero new backend model**.
**Files:** `lib/screens/family_album_screen.dart` (add a `floatingActionButton` to the Scaffold
~`:266`); reuse the `_pickImages` logic (`create_post_screen.dart:439-473`) — extract it into a
shared helper/service so both screens call the same picker + Step 2 parallel uploader + Step 3
progress; call `postService.createPost(...)` with the picked images and a minimal/auto caption.
**Do:** auto-title from photo date if easy (e.g. «Озеро, 6 июля» from EXIF/file date), editable; else
empty caption is fine for v1. After success, refresh the album (`_load()` at `:130-133`) so the new
photos appear in their month section immediately.
**Acceptance:** from the album, `+` → pick 30 → they appear in the album's month grid without visiting
the feed compose screen; they also show in the feed as one carousel post.

## Step 5 — Background / non-blocking publish with auto-retry (effort: L, do last)
**Goal:** tap «Опубликовать» and walk away; the batch uploads in the background with bounded
concurrency + auto-retries dropped files on network restore, instead of failing the whole post. True
Telegram-grade delight.
**Reuse:** `lib/services/chat_send_queue.dart` (per-file `ChatAttachmentUploadStatus`, Hive
persistence, auto-retry on connectivity restore) — the goal is to **extract its core into a shared
`MediaUploadQueue`/uploader** that both chat and posts use, rather than duplicating.
**Files:** new shared uploader (extracted from `chat_send_queue.dart`);
`lib/services/custom_api_post_service.dart` (enqueue instead of inline await);
`lib/screens/create_post_screen.dart` (stop blocking on `_isLoading` — let the user navigate away
after enqueue; show a global upload chip/progress). Persist the pending post so an app kill/network
drop doesn't lose the batch.
**Do carefully:** this is the highest-risk piece (shared queue extraction touches chat too). Land
Steps 1-4 first and prove the flow before extracting the queue. Keep chat's behaviour byte-identical.
**Acceptance:** publish a 40-photo post, immediately leave the screen; uploads continue with a visible
global progress; killing wifi mid-batch and restoring it auto-resumes the failed files; the post lands
complete.

---

## Risks & gotchas (must handle)
- **50MB JSON body cap** (`app.js:718`): photos at q80/1080 are safe, but a batch with big VIDEOS can
  exceed it → the request 413s (may look silent). Add a client-side pre-check that sums the (base64)
  payload size before publish and warns/blocks with a clear message. Do NOT raise concurrency high
  enough to hold all payloads in memory at once.
- **Memory / ANR:** `readAsBytes()` + `base64Encode()` are blocking (`custom_api_storage_service.dart:36-37`).
  Bounded concurrency (3-4) is MANDATORY; never `Future.wait` all. Consider moving encode to a
  compute/isolate if 40+ large files still jank. (Bigger win later: switch media upload from base64
  JSON to `multipart/form-data` streaming — see `custom_api_storage_service.dart:111-129` — to kill
  the +33% inflation and the 50MB ceiling; out of scope for v1 but note it.)
- **Ordering:** album dedups by URL + sorts by `post.createdAt` (`family_album_screen.dart:201-217`);
  the carousel renders `imageUrls` in array order → parallel uploads MUST reassemble by pick index
  (Step 2), or photos shuffle.
- **Dedup:** album dedups by exact URL (`:208`); re-posting the same file (new uuid path) makes a
  duplicate album entry — acceptable for v1; note it if you later add "add to existing post".
- **No per-file backend size guard** (`media-routes.js` `saveObject` has no length check) — only the
  50MB total. A single huge file in a batch fails the whole request; per-file client compression
  covers photos, not videos.
- **Album scaling:** album aggregates ALL posts client-side (`getPosts(treeId:null)`); dumping
  hundreds of photos grows that in-memory list. Fine now; flag as a future pagination item.

## Testing
- Unit: Step 2 order-preservation (mock uploader returns out of order → `imageUrls` still in pick
  order); Step 2 bounded concurrency (assert ≤4 in flight); Step 3 progress emits
  `completed` 1..N. Reuse the existing post/chat service test fixtures.
- Widget: compose accepts 30 (Step 1); publish shows live progress (Step 3); album FAB opens the
  picker + refreshes (Step 4).
- Do NOT touch the forbidden files (`custom_api_notification_service*.dart`,
  `interactive_family_tree_test.dart`). Run `flutter analyze` + `flutter test` after each step.

## Ship (after the steps land + are reviewed)
Rodnya ships to users via **OTA auto-deploy** — one button, do NOT hand-build/host:
1. Bump `pubspec.yaml` `version:` — increment the build number (e.g. `1.0.25+33` → `1.0.26+34`).
   **OTA only offers an update when versionCode INCREASES — skipping this = nobody gets it.**
2. Commit + push to `main`.
3. Run the GitHub Actions workflow **"Release Android APK (OTA)"** (`.github/workflows/android-ota-release.yml`):
   `gh workflow run android-ota-release.yml -f notes="Массовая загрузка фото: выложите весь отпуск в пару тапов" -f mandatory=false`
   It builds the signed APK → uploads to the server → points backend `/v1/app/latest` at it → verifies.
4. Confirm `curl -s https://api.rodnya-tree.ru/v1/app/latest` shows the new versionCode.

---

## Ход выполнения (2026-08-27)

- **Шаг 1 — СДЕЛАН** (`903c18c`): `kMaxPostMedia = 30`. Живой прогон на
  эмуляторе поймал литерал, которого не было в списке файлов плана: пустое
  состояние медиа-карточки («Можно прикрепить до 5 файлов», `:1918`).
- **Шаги 2-3 — СДЕЛАНЫ** (`b6bcdc1`): пул из 4 воркеров с раскладкой по
  индексу выбора; провал файла валит публикацию (раньше фото молча
  выбрасывалось); модель `MediaUploadProgress` прокинута в `createPost`,
  кнопка публикации показывает «Загружено N из M» / «Публикуем…».
  4 юнит-теста (порядок при обратных задержках, пик ≤4, серия прогресса,
  отказ). Итог: analyze чист, 1417/1417.
- **Проверено вживую** (эмулятор, dev-flavor): 8 фото одной пачкой →
  счётчик «8/30» → публикация со стадией «Публикуем…» → пост с 8 фото;
  порядок подтверждён попиксельно (градиент цветов совпал позиция в позицию).
- **Правка к разделу рисков:** каждый файл уходит ОТДЕЛЬНЫМ запросом
  `/v1/media/upload` (`custom_api_storage_service.dart:110-129`), поэтому
  лимит тела 50 МБ действует ПОФАЙЛОВО и пачкой не набирается — предлагавшийся
  батч-предчек защищал бы от несуществующей угрозы. Реальный риск остаётся
  один: одиночный крупный ВИДЕО-файл.
- **Шаг 4 — СДЕЛАН** (`01a6aac`, `d61692d`): «Добавить фото» прямо в альбоме,
  общий пикер вынесен в `lib/services/gallery_media_picker.dart` (туда же
  переехал `kMaxPostMedia`), тест-сид `mediaPickerOverride`. Публикуется
  обычный пост с пустой подписью — альбом производный, бэкенд не тронут.
  3 виджет-теста. Живой прогон снова поймал то, чего тесты не видят:
  глобальная тема задаёт FAB'ам `CircleBorder` (extended-подпись торчала за
  круг → точечный `StadiumBorder`), а текст пустого состояния всё ещё звал
  «поделись первым моментом в ленте». Проверено e2e: 5 фото → секция месяца,
  порядок сохранён.
- Осталось: шаг 5 (фоновая публикация с автоповтором; требует извлечения
  общей очереди из `chat_send_queue.dart` — поведение чата обязано остаться
  байт-в-байт прежним).
