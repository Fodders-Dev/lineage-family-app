# Зеркало RuStore SDK (`ru.rustore.sdk`)

Локальный Maven-репозиторий для Android-сборки. Объявлен в
`android/build.gradle` **первым** в `allprojects.repositories` и только для
группы `ru.rustore.sdk` (`content { includeGroup }`), поэтому на остальные
зависимости не влияет.

## Зачем

01.09.2026 официальный репозиторий RuStore
(`https://artifactory-external.vkpartner.ru/artifactory/maven`) перестал
отвечать — 404 даже на `/artifactory/api/system/ping`, с разных сетей
(проверено с рабочей машины и с прод-сервера в РФ). Документация RuStore
по-прежнему указывает на этот адрес, на Maven Central группы нет.
Плагины `flutter_rustore_*` добавляют этот репозиторий сами; следом в
списке идёт jitpack (его приносит `flutter_webrtc`), а jitpack на чужие
координаты отвечает **401**, что Gradle считает жёсткой ошибкой, а не
«не найдено». Итог — `Release Android APK (OTA)` падал на
`mergeRustoreReleaseNativeLibs`, релиз 1.0.30 не доехал до пользователей.

Зеркало снимает зависимость сборки от чужого Artifactory насовсем, а не
только на время аварии: RuStore-пуш — живой канал доставки (Huawei без
GMS получают пуши через VKPNS), выкинуть SDK нельзя.

## Откуда артефакты

- `.aar` — из локального Gradle-кэша (`~/.gradle/caches/modules-2/files-2.1`)
  машины, на которой собирались релизы до 1.0.29 включительно; скачаны с
  официального Artifactory, пока он работал. Хэши — в таблице ниже, чтобы
  подмену было видно.
- `.pom` — **синтезированы** `tool/rustore_mirror_gen.py` из разрешённого
  дерева `./gradlew :app:dependencies --configuration
  rustoreReleaseRuntimeClasspath --offline` (в кэше Gradle оригинальных
  POM нет, только бинарные дескрипторы). Прямые зависимости каждого модуля
  зафиксированы на уже разрешённых версиях, scope `compile` — надмножество
  оригинала, лишнего ничего не подтягивает (граф тот же, что был у 1.0.29).
  Для версий, которые запрашиваются, но вытесняются conflict-resolution
  (`core:8.0.0 -> 10.3.0`, `pushclient:6.5.0 -> 7.2.0` …) лежат тонкие
  POM без `.aar`: Gradle требует метаданные и для них.

## Как обновить

1. Собрать проект с доступным upstream (или положить новые `.aar` в кэш).
2. `cd android && ./gradlew -q :app:dependencies --configuration
   rustoreReleaseRuntimeClasspath --offline > deps.txt`
3. `python tool/rustore_mirror_gen.py deps.txt <корень репо> android/rustore-maven`
4. Проверить чистой сборкой: `GRADLE_USER_HOME=<пустая папка> flutter build apk
   --flavor rustore --debug` — без локального кэша, как в CI.

## Хэши артефактов (sha256)

| артефакт | sha256 |
|---|---|
| activitylauncher/10.3.0/activitylauncher-10.3.0.aar | b18e0ce2e0fb8e819c152c204d84c22a3fb576e66005eb76958e6ac230448256 |
| analytics/10.3.0/analytics-10.3.0.aar | 6a10eab42e4a29340c492cfd9f6d80ed68c86aaa8f2855a3b355c144b43ded71 |
| appupdate/10.3.0/appupdate-10.3.0.aar | b2359150b49b37472cc2664e209e1b351277cfcb37e69ab2932a1d4d2aae41ff |
| billingclient/10.0.0/billingclient-10.0.0.aar | 63fbd19f47ec7073d1db4eea9cd96f472e38e523bd91444e93ba71e184675179 |
| core/10.0.0/core-10.0.0.aar | 605a6be1b647d2144f9553397220806cf8b8e6dc835ef3e8c25670f2ae836ef7 |
| core/10.3.0/core-10.3.0.aar | 369cbc1146e42891a55f35b41eaa65d9ea0f7ebafd8899a2098c4bca3915e390 |
| core/8.0.0/core-8.0.0.aar | d7c011a05cd3ca5991ec4737461f729460156465744c384546dd6907d37f825e |
| coreui/10.0.0/coreui-10.0.0.aar | 97edcd87ce8fff921f82b2915db7ac82dc75d01104dd3caa1ba55f85646eafc2 |
| metrics/10.3.0/metrics-10.3.0.aar | f1bb65201dce8dd3d9ee222bb56d428f7c7d4bc05076c438bff1443ae5775ae9 |
| push-common/7.2.0/push-common-7.2.0.aar | 8b69891f0413af8f03e4717b6619de91a3616744aad95b650e1db7189f4481fa |
| push-core-network/7.2.0/push-core-network-7.2.0.aar | 55821683e3699ebc4e6dcec5c64337a7ac05b862141cea6497a0f727a711f611 |
| push-core-remote-config/7.2.0/push-core-remote-config-7.2.0.aar | d33d19dc5582cd4d2a9dd4235d2ef947f5cd2bb9d2805a43e54ea1ca6f403a9f |
| push-core/7.2.0/push-core-7.2.0.aar | 27893959acbf2fc40a6abc9fb46c4fb3dd693ef2302cb1967e8140e40454e12d |
| pushclient/7.2.0/pushclient-7.2.0.aar | 9b66fed320a0795d225419c877f3c56a4d8df6987ffcf1afa7b4fa0a04aa6dd7 |
| reactive/10.3.0/reactive-10.3.0.aar | 288f9c21b9b34571040a8bf27f1ed2db72fadc8fc034335bb1171a4d5faa6577 |
| review/10.0.0/review-10.0.0.aar | b990bf31458bdb223a392fef2d6d94d332bb32b629de3e3712444d844a5a2010 |
| store_versionprovider/10.0.0/store_versionprovider-10.0.0.aar | 2bf42ce36cdab51235c458298f805a5d80a1cf6d5df58c914b0e790c13d42f0b |
| userprofile/10.0.0/userprofile-10.0.0.aar | dbbdbb4f52cef0066fa27f89f292ce1c175269c5edc9bfcd506ff18c34edddfb |
