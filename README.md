# hkotuner для iPhone

Карманная версия [hkotuner](https://github.com/Hkotuk5/hkotuner) — музыкального плеера для Windows.
Ищет песни в YouTube Music, играет в фоне, «Моя волна», любимые и плейлисты хранятся на телефоне,
любимые доступны без интернета. Ставится сайдлодом (Sideloadly, SideStore, AltStore):
**[инструкция по установке](УСТАНОВКА.md)**.

*A pocket version of the hkotuner desktop music player for iPhone, sideloaded (no App Store).*

## Как устроено

- **SwiftUI**, iOS 16+, без сторонних библиотек.
- Поиск и радио: JSON API YouTube Music (`Sources/Net/YTMusic.swift`, перенесено из
  `crates/hk-core/src/ytmusic.rs` десктопа).
- Звук: `youtubei/v1/player` от имени клиента, которому не нужны PO‑токен и JavaScript
  (сейчас `VISIONOS`, тот же, что yt-dlp берёт без JS‑движка). Файл m4a (AAC 128 кбит/с) качается
  кусками по 1 МБ параллельно — целиком одним запросом YouTube отдаёт его медленно. Если файла
  нет, играет HLS из того же ответа.
- Список клиентов можно обновить без новой сборки: приложение скачивает
  [`client-config.json`](client-config.json) из этого репозитория (схема в `Sources/Net/ClientConfig.swift`).
- Библиотека — `library.json` в том же формате, что на компьютере; импорт принимает копию,
  сохранённую десктопом (`hkotuner-backup`).

## Сборка

Проект Xcode генерируется [XcodeGen](https://github.com/yonaskolb/XcodeGen) из `project.yml`.
GitHub Actions (`.github/workflows/build-ipa.yml`) на `macos-latest` гоняет тесты в симуляторе и
собирает **неподписанный** `hkotuner.ipa` (артефакт каждого запуска; для тега `v*` — релиз).
Подписывает его уже Sideloadly / SideStore / AltStore на твоём Apple ID.

На Mac локально:

```sh
brew install xcodegen
xcodegen generate
open hkotuner.xcodeproj
```
