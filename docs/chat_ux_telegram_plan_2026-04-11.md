# Chat UX Plan 2026-04-11

Цель: довести общение в Lineage до уровня, где direct, group и branch chats ощущаются быстрыми, надёжными и удобными в ежедневном использовании, по принципам Telegram, но с нашим family-first контекстом.

## Принципы
- Ничего важного не теряется: drafts, unread state, позиция, контекст сообщения.
- Частые действия должны занимать один жест или один тап.
- Ошибка сети не должна ломать сценарий общения.
- Family graph и branch chats должны усиливать мессенджер, а не усложнять его.

## Wave 1
- [x] Drafts в диалоге и превью draft в списке чатов
- [x] Более явные outgoing states: отправляется, отправлено, ошибка, повторить
- [x] Jump to unread и кнопка быстрого возврата вниз
- [x] Более сильный triage списка чатов: важные состояния, сортировка, читаемость

## Wave 2
- Статус: closed
- [x] Reply на сообщение с quote-preview
- [x] Edit и delete собственных сообщений
- [x] Forward сообщений и вложений
- [x] Удобная voice UX: lock, discard, preview
- [x] Единый pre-send UX для фото, видео и файлов

## Wave 3
- [x] Pinned messages
- [x] Search inside chat
- [x] Chat details как полноценный control center
- [x] Mute и granular notification controls
- [x] Archive и управление перегрузкой списка

## Wave 4
- Статус: closed
- [x] Reactions
- [x] Auto-delete и ephemeral options
- [x] Presence, typing, seen-state улучшения
- [x] Более сильный offline/retry/dedup layer

## Wave 5
- Статус: in progress
- [x] Desktop/web context menu без пересечения с системным browser menu
- [x] Multi-select сообщений с batch copy/forward/delete
- [x] Attachment viewer и download/open flow для remote вложений
- [ ] Галерея media и richer video/image navigation как отдельный polish-pass

## Family-first differentiators
- [ ] Быстрый переход из дерева в релевантный чат ветки
- [ ] Smart entry points: обсудить человека, ветку, событие
- [ ] Branch-aware composer и context labels
- [ ] Family-specific mentions и shortcuts

## Уже сделано
- [x] Direct, group и branch chats
- [x] Базовые unread counters
- [x] Optimistic send
- [x] Attachments и voice recording
- [x] Group and branch info basics

## Текущая реализационная волна
- [x] Зафиксировать roadmap в repo
- [x] Внедрить infrastructure для chat drafts
- [x] Показать drafts в chat list
- [x] Обновить тесты chat surfaces
- [x] Прогнать analyze и релевантные тесты

## Последний прогресс
- [x] Shared polling для chat previews и unread counters без размножения таймеров на каждого слушателя
- [x] Более явный visual state для outgoing messages в ChatScreen
- [x] Unread divider, initial jump-to-unread и floating action для возврата к последним сообщениям
- [x] Reply flow: long-press reply target, quote-preview в composer, reply quote в bubble и проброс reply metadata в backend
- [x] Unified pre-send panel: понятный заголовок по типу вложения, breakdown состава, hint перед отправкой и one-tap clear для пакета
- [x] Voice UX stage 1: запись больше не улетает мгновенно, а попадает в pre-send preview с возможностью прослушать и удалить перед отправкой
- [x] Long-press message actions: reply и copy для обычных сообщений, плюс retry/delete для локально неотправленных outgoing bubbles
- [x] In-chat search: toggle в AppBar, live filter по сообщениям, подсветка совпадений и счётчик найденных результатов
- [x] Voice UX stage 2: preview теперь показывает длительность, даёт быстрый reroll через "Перезаписать" и яснее объясняет сценарий до отправки
- [x] Forward flow: long-press "Переслать", composer-preview пересылки и отправка существующих attachments/mediaUrls без повторного upload
- [x] Edit/delete flow: backend `PATCH/DELETE` для chat messages, composer mode редактирования, confirm delete и test coverage на client + API + backend
- [x] Pinned messages: long-press pin/unpin, persistent pinned banner per chat, visual pin marker in bubble и restore после reopen
- [x] Chat details control center: быстрые действия из info sheet, переход в поиск по чату, jump к pinned и быстрые переходы в дерево/родных
- [x] Chat notification controls: per-chat режимы "Все", "Тихо", "Выключены" в info sheet, индикация muted chats в списке и suppression/silent delivery в local notification service
- [x] Archive flow: local archive/unarchive для chat list, фильтры "Все / Непрочитанные / Архив", archive summary card и разгрузка основного списка без потери истории
- [x] Reactions: быстрые emoji reactions в long-press sheet, inline reaction pills под сообщениями и restore после reopen через локальный store
- [x] Auto-delete и ephemeral options: per-chat TTL в control center и composer, TTL-проброс в send contract и backend expiry cleanup для history/previews
- [x] Presence, typing, seen-state: realtime presence bootstrap, typing indicator в header и read fanout обратно отправителю с более явным "Доставлено/Просмотрено"
- [x] Offline/retry/dedup layer: `clientMessageId` в transport, backend idempotency по `chatId + senderId + clientMessageId` и более точное схлопывание optimistic bubbles
- [x] Polling pass: chat overview вынесен на более редкий shared interval, notifications и pending invitations больше не стучатся так часто, как до realtime/TTL/dedup wave
- [x] Desktop context menu для сообщений: right click и anchored mini-popover поверх bubble с быстрыми реакциями и action list вместо bottom sheet на desktop/web
- [x] Browser context menu suppression на chat screen: системное web-меню отключается, чтобы не перекрывать custom popover
- [x] Multi-select: выделение нескольких сообщений, app bar batch actions и transcript-copy в Telegram-like формате `[dd.MM.yyyy H:mm] Имя: текст`
- [x] Attachment viewer/download pass: tap по remote вложению открывает fullscreen viewer с `open externally` и `download/open` actions вместо тупика "отправили, но не посмотреть"

## Notes
- Telegram reference:
  - https://github.com/DrKLO/Telegram
  - https://telegram.org/evolution
  - https://telegram.org/faq
- В первую очередь копируем не количество фич, а UX-принципы: предсказуемость, скорость, сохранность состояния, low-friction actions.
