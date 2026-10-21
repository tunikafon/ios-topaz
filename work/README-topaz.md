# iOS 16 на Redmi Note 12 4G (topaz) — сборка на этом компьютере

Порт iOS 16.7.16 на Redmi Note 12 4G (`topaz`/`tapas`, SM6225) из репозитория
`MakrSas/ios-topaz` (ветка `topaz`). Этот каталог — рабочая копия, собранная
и сконфигурированная под этот компьютер (Artix Linux, x86_64).

```
/home/tunikafon/Projects/ios-topaz      репозиторий (клон ветки topaz)
/home/tunikafon/bin                     apfs-fuse, mkfs.hfsplus, fsck.hfsplus, lzfse
/home/tunikafon/src                     исходники этих утилит
/home/tunikafon/Projects/ios-topaz/work   скрипты сборки и промежуточные файлы
```

## Что уже собрано и работает

| Что | Где | Состояние |
| --- | --- | --- |
| `apfs-fuse` | `~/bin/apfs-fuse` | собрано из `sgan81/apfs-fuse` (патч: `#include <cstdint>` в `ApfsLib/PList.h`, clang вместо gcc) |
| `mkfs.hfsplus`, `fsck.hfsplus` | `~/bin/` | собрано из `diskdev_cmds-540.1.linux3` (Fedora hfsplus-tools) с патчами Fedora |
| `lzfse` | `~/bin/lzfse` | собрано из `lzfse/lzfse` |
| `mkbootimg.py` | `tools/bin/mkbootimg.py` | AOSP-версия (LineageOS 19.1), поддерживает `--header_version 4` |
| `ipsw` | `/tmp/opencode/ipsw` | для распаковки `DeviceTree.d22ap.im4p` → `research/ipsw-x/d22ap.adt` |
| ADT (дерево устройств iPhone X) | `research/ipsw-x/d22ap.adt` | готово, 186084 байта |
| Ядро XNU | `xnu/out/kernel.development.sweet` | **скачано и проверено** (см. раздел 1) |
| Payload | `shim/out/payload.bin` | 17 185 008 байт, cmdline iOS прописан |
| Shim | `shim/out/shim-boot.img` | **собран**, 17 383 424 байта |
| Корень iOS | `ios16-root.simg` | **собран**, 12 149 369 748 байт |

## 1. Ядро (скачано 21.10.2026)

Ядро XNU собирается только на macOS (GitHub Actions `macos-14`, `blacktop/darwin-xnu-build`).
Готовый артефакт последнего публичного прогона:

**https://github.com/MakrSas/ios-topaz/actions/runs/39419628786**

Нужен логин GitHub (артефакты не отдаются анонимно). На странице прогона внизу —
артефакт `xnu-kernel` → «Download zip». Положи zip сюда:

```
/home/tunikafon/Projects/ios-topaz/xnu/out/xnu-kernel.zip
```

(или в любое место и скажи путь). Дальше:

```sh
cd /home/tunikafon/Projects/ios-topaz
work/unpack-kernel.sh                      # -> xnu/out/kernel.development.sweet
work/build-boot.sh                         # -> shim/out/shim-boot.img
```

**Уже сделано:** zip скачан (`~/Downloads/xnu-kernel.zip`, 21.10.2026 17:48), ядро
распаковано и проверено:

* `sha256 4ef3775214ba0c340caf1c5680357100a4a58e68718ae7c1687af0c1f951338e` —
  совпадает с `SHA256SUMS` из артефакта;
* Mach-O 64-bit arm64, PIE, **без** `LC_DYLD_CHAINED_FIXUPS` (готовый static
  kernelcache, указатели уже разрешены — `mkpayload.py` ругается на `fixups: 0`
  закономерно);
* LSE-атомики отсутствуют: `llvm-objdump -d --mattr=+v8.5a kernel.development.sweet |
  grep -P '\t(cas|ldadd|ldset|ldclr|swp|ldapr)'` → **0 совпадений** (ARMv8.0, как нужно).

`work/build-boot.sh` собрал `shim/out/shim-boot.img` (17 383 424 байта): ADT
`shim/out/topaz.adt` (9688 байт) → payload `shim/out/payload.bin` (17 185 008 байт,
cmdline `debug=0xc serial=3 cpus=4 keepsyms=1 -noprogress rd=ufsroot0
unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1
launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30`) → shim.

Артефакт прогона 39419628786 собран на коммите `2665612a` (20.10.2026 12:05 UTC) — это
состояние с патчами до 0130 (связь, тач, отрисовка). В репозитории лежат более новые
патчи 0131–0139 (SweetSurface/IOAcceleratorES, ускорение UI), они в этот артефакт
**не входят**. Если нужен свежий HEAD — форк `MakrSas/ios-topaz`, вкладка Actions →
workflow `xnu` → Run workflow (ветка `topaz`), сборка ~8 минут, затем тот же
`work/unpack-kernel.sh`.

## 2. Корень iOS (собран 21.10.2026)

```sh
cd /home/tunikafon/Projects/ios-topaz
work/build-root.sh                          # -> ios16-root.simg
```

**Готово:** `ios16-root.simg`, 12 149 369 748 байт (логический образ 16 ГБ,
11,31 ГБ данных), sha256 логического образа
`23828ea993b04b98c70012c4f818af3301d0a9ff9fc1e605880b3e58a770b270`.

Скрипт сам:

1. берёт пути OS/SystemOS/AppOS из `BuildManifest.plist` (идентичность D22AP «Erase»);
2. скачивает три `.dmg` из IPSW iPhone X 16.7.16 (20H392) по HTTP range-запросам
   (сам IPSW на 6 ГБ не качается) — `work/remotezip.py` (копия `tools/remotezip.py`
   с `--http1.1`: через HTTP/2 CDN отдаёт вдвое медленнее) + `work/fetch-ipsw.sh`
   (перезапуск всей загрузки, если пропала сеть — `.part` продолжается с места
   обрыва);
3. создаёт HFS+ том 16 ГБ (`mkfs.hfsplus -s -J -v iOSRoot`), копирует туда OS-корень
   и криптексы SystemOS/AppOS (`rsync -aH`, владельцы/права/ссылки сохраняются);
4. после каждого `.dmg` удаляет его и **демонтирует FUSE-монтирование** (залипший
   `apfs-fuse` держит `.dmg` открытым и его место не освобождается — на этом уже
   потеряли 4,4 ГБ);
5. делает hard-link'и криптексов в корень, кладёт `/private/var/keybags/systembag.kb`,
   создаёт каталоги `logd` (uid/gid 272) с маркерами `.migrated`;
6. прогоняет `fsck.hfsplus` (том в итоге «appears to be OK»);
7. применяет `tools/sweet-root-tweaks.py` (launchd, SpringBoard, Setup, …) и
   ещё раз `fsck.hfsplus`;
8. конвертирует в sparse-образ.

Шаг 8 сделан не `img2simg`, а `work/raw2simg.py`: `img2simg` требует одновременно
сырой образ (~11,3 ГБ данных) и sparse (~11,3 ГБ) — это ~23 ГБ, на диске их нет.
`raw2simg.py` идёт по сырому файлу потоком и «продырявливает» уже скопированные
куски (`fallocate FALLOC_FL_PUNCH_HOLE`), поэтому пик — как у одного сырого образа.
Результат проверяется по sha256 логического образа: sha256 считается при
конвертации и ещё раз пересчитывается из готового sparse-файла (совпало).

**Место на диске.** Сырые данные OS-корня занимают 8,7 ГБ (apfs-fuse
распаковывает LZBITMAP), SystemOS — ещё 2,7 ГБ, итого ~11,5 ГБ в томе. Распакованный
SystemOS `.dmg` (2,7 ГБ) готовится **в tmpfs** (`/dev/shm/ios-topaz`), иначе на
диске не хватает места на «распакованный образ + его копия». Осталось 3,7 ГБ
свободных.

**Сырой образ после конвертации «пустой»** (все блоки пробиты в дырки) — его
можно восстановить из sparse: `simg2img ios16-root.simg work/ios16-root.img`.

**Этапы resumable:** маркеры `work/.stage-*`. Если прервать сборку и запустить
скрипт снова, он продолжит с места обрыва и не будет качать IPSW заново. Если
тома `work/ios16-root.img` нет — маркеры сбрасываются и сборка идёт с нуля.

Внешние команды, которые он вызывает, и где они взялись:

| Команда | Источник |
| --- | --- |
| `apfs-fuse` | `~/bin/apfs-fuse` (собран из `sgan81/apfs-fuse`) |
| `mkfs.hfsplus` / `fsck.hfsplus` | `~/bin/` (Fedora hfsplus-tools 540.1) |
| `python3 tools/sweet-root-tweaks.py` | репозиторий upstream |
| `python3 work/raw2simg.py` | написан здесь (см. выше) |
| `sudo` | через `NOPASSWD`-правило `/etc/sudoers.d/99-temp-nopasswd` (удалено в конце) |

## 3. Прошивка (две команды)

Готовые файлы: `ios16-root.simg` и `shim/out/shim-boot.img`.

```sh
cd /home/tunikafon/Projects/ios-topaz
fastboot -S 512M flash userdata ios16-root.simg   # ~5 минут, не отключать
fastboot boot shim/out/shim-boot.img
```

Телефон должен быть в fastboot (Power + Volume down), загрузчик разблокирован.
`userdata` очищается (Android и его данные исчезают), `boot`/`vendor_boot`/firmware
не трогаются — вернуть Android можно по `RECOVERY.md`.

Готовый скрипт (делает то же самое + сохраняет GPT-заголовки перед записью):

```sh
work/flash.sh            # с подтверждением
work/flash.sh --yes      # без вопросов
```

## Опасности

* **GPT.** 19.10.2026 UFS-драйвер iOS портил GPT LUN0 (RECOVERY.md). Перед записью
  `flash.sh` пытается снять заголовок GPT (`fastboot fetch partition:0`). Если fastboot
  не умеет `fetch` — сними GPT через TWRP: `dd if=/dev/block/by-name/userdata bs=1M count=1`.
* **`ufsrw=1 rootrw=1`** — корень пишется. Без них iOS не стартует нормально,
  но и GPT не должен пострадать.
* Android на телефоне будет стёрт. Данные `userdata` (фото, чаты и т. п.) — тоже.
* Разблокировка загрузчика уже должна быть сделана, иначе `fastboot flash` не пройдёт.

## Что осталось сделать

1. ~~Скачать `xnu-kernel.zip`~~ — сделано 21.10.2026.
2. ~~Дождаться `work/build-root.sh`~~ — сделано, `ios16-root.simg` собран.
3. **Подключить телефон в fastboot** (Power + Volume down, загрузчик разблокирован)
   и выполнить:

   ```sh
   cd /home/tunikafon/Projects/ios-topaz
   fastboot -S 512M flash userdata ios16-root.simg
   fastboot boot shim/out/shim-boot.img
   ```

   или то же самое через `work/flash.sh` (сохраняет GPT-заголовки перед записью).
4. Временное правило sudo `/etc/sudoers.d/99-temp-nopasswd` **уже удалено**
   (файл `sudo.pass` в `/tmp/opencode` тоже).
