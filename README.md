README для GitHub
Ниже даю готовый вариант README.md.

markdown

# Ubuntu 26.04 + PHP 8.3 (source) + Asterisk 22.9 + FreePBX 17

Установочный скрипт для сборки рабочей АТС на базе:

- Ubuntu 26.04
- Asterisk 22.9
- FreePBX 17
- PHP 8.3 из исходников
- G.729 через `bcg729` + `arkadijs/asterisk-g72x`
- обязательные русские sounds
- обязательные модули FreePBX `Sysadmin` и `Firewall`

## Особенности

- сначала используется локальный каталог с исходниками и архивами:
  `/root/offline-assets/`
- если нужный файл там не найден, скрипт пытается скачать его из интернета
- PHP 8.3 собирается из исходников
- Asterisk 22.9 собирается из исходников
- G.729 собирается вручную через:
  - `bcg729`
  - `arkadijs/asterisk-g72x`
- русские sounds устанавливаются обязательно
- FreePBX устанавливается без создания web-admin пользователя
- `Sysadmin` и `Firewall` обязательны
- поддерживается выбор модулей Asterisk тремя способами

---

## Поддерживаемая платформа

Только:

- **Ubuntu 26.04**

> Debian не является целевой платформой этого скрипта.

---

## Что устанавливается

- PHP 8.3.x из исходников в:
  `/usr/local/php83`
- Asterisk 22.9.x
- FreePBX 17
- MariaDB
- Apache2
- Node.js 22
- pm2
- incron
- fail2ban
- русские sound-пакеты
- G.729 codec

---

## Выбор модулей Asterisk

Во время установки скрипт предлагает 3 режима выбора модулей Asterisk:

### 1. `preset`
Стандартный преднастроенный набор.

Используется встроенный набор модулей скрипта + обязательные модули для работы FreePBX.

### 2. `file`
Выбор модулей из файла:

```bash
/root/prod-modules.txt
В этом режиме скрипт читает список модулей из файла и пытается включить их через menuselect.

Пример содержимого:

text

chan_pjsip
res_pjsip
codec_alaw
codec_ulaw
format_wav
app_dial
pbx_config
Допустимы строки:

с именем модуля
с именем файла вида chan_pjsip.so
пустые строки
комментарии, начинающиеся с #
Если модуль отсутствует в Asterisk 22.9 или недоступен в menuselect, в лог будет выведено предупреждение.

3. menu
Ручной выбор через интерактивный menuselect.

Скрипт откроет интерфейс menuselect, где можно вручную отметить нужные модули, сохранить изменения и продолжить установку.

Каталог локальных исходников и архивов
Скрипт в первую очередь ищет исходники и архивы в каталоге:

bash

/root/offline-assets/
Если файл там не найден, используется загрузка из интернета.

Что можно положить в /root/offline-assets/
Ниже приведены ориентировочные имена файлов и каталогов, которые понимает скрипт.

PHP
Файл архива:

text

/root/offline-assets/php-8.3.31.tar.gz
или другой архив PHP 8.3.x, если версия в скрипте изменена.

Asterisk
Файл архива:

text

/root/offline-assets/asterisk-22.9.0.tar.gz
Русские sounds
Один из вариантов:

text

/root/offline-assets/asterisk-sounds-ru.tar.gz
/root/offline-assets/asterisk-core-sounds-ru-wav-current.tar.gz
ionCube
text

/root/offline-assets/ioncube_loaders_lin_x86-64.tar.gz
bcg729
Можно положить либо каталог исходников:

text

/root/offline-assets/bcg729/
либо архив:

text

/root/offline-assets/bcg729.tar.gz
/root/offline-assets/bcg729-*.tar.gz
/root/offline-assets/bcg729-*.tar.bz2
asterisk-g72x
Можно положить либо каталог исходников:

text

/root/offline-assets/asterisk-g72x/
либо архив:

text

/root/offline-assets/asterisk-g72x.tar.gz
/root/offline-assets/asterisk-g72x-*.tar.gz
/root/offline-assets/asterisk-g72x-*.tar.bz2
FreePBX framework
Можно положить каталог исходников:

text

/root/offline-assets/freepbx/
или каталог, найденный по имени freepbx / framework.

GPG-ключ FreePBX
Опционально:

text

/root/offline-assets/freepbx*.gpg
Sysadmin / Firewall offline assets
Для офлайн-установки обязательных модулей Sysadmin и Firewall нужны следующие файлы:

text

/root/offline-assets/sysadmin17_8.2-8.2_sng12_all.deb
/root/offline-assets/sysadmin-lib.tar.gz
/root/offline-assets/freepbx-sysadmin-module-dir.tar.gz
/root/offline-assets/freepbx-firewall-module-dir.tar.gz
Порядок поиска файлов
Для большинства исходников и архивов применяется следующий порядок:

поиск в /root/offline-assets/
поиск в типовых локальных местах (/root, /tmp) — если это предусмотрено скриптом
скачивание из интернета
То есть приоритет всегда у локального offline-набора.

Пример подготовки offline-каталога
bash

mkdir -p /root/offline-assets
cp php-8.3.31.tar.gz /root/offline-assets/
cp asterisk-22.9.0.tar.gz /root/offline-assets/
cp ioncube_loaders_lin_x86-64.tar.gz /root/offline-assets/
cp asterisk-core-sounds-ru-wav-current.tar.gz /root/offline-assets/
cp -a bcg729 /root/offline-assets/
cp -a asterisk-g72x /root/offline-assets/
cp sysadmin17_8.2-8.2_sng12_all.deb /root/offline-assets/
cp sysadmin-lib.tar.gz /root/offline-assets/
cp freepbx-sysadmin-module-dir.tar.gz /root/offline-assets/
cp freepbx-firewall-module-dir.tar.gz /root/offline-assets/
Запуск
Сделать скрипт исполняемым:

bash

chmod +x install.sh
Запустить:

bash

bash install.sh
Полезные переменные окружения
При необходимости можно переопределять параметры через environment variables, например:

bash

PHP_VER=8.3.31 AST_VER=22.9.0 FREEPBX_TAG=release/17.0 bash install.sh
Примеры полезных переменных:

PHP_VER
AST_VER
FREEPBX_TAG
OFFLINE_ASSETS_DIR
AST_MODULE_MODE
AST_MODULE_FILE
DB_ROOT_PASS
DB_USER
DB_ASTERISK
DB_CDR
Принудительный выбор режима модулей без интерактива
Использовать preset
bash

AST_MODULE_MODE=preset bash install.sh
Использовать список из файла
bash

AST_MODULE_MODE=file AST_MODULE_FILE=/root/prod-modules.txt bash install.sh
Открыть menuselect вручную
bash

AST_MODULE_MODE=menu bash install.sh
Логи
Основной лог установки сохраняется в файл вида:

bash

/root/install-ats-YYYY-MM-DD-HHMMSS.log
Примеры поиска предупреждений по модулям:

bash

LOG="$(ls -1t /root/install-ats-*.log | head -1)"
grep -nE "Модуль .* недоступен|Включён модуль|Итог выбора модулей|$$WARN$$" "$LOG"
Показать только проблемные модули из списка:

bash

LOG="$(ls -1t /root/install-ats-*.log | head -1)"
grep -oP 'Модуль \K.*(?= недоступен для включения)' "$LOG" | sort -u
Проверка после установки
Скрипт создаёт отдельный проверочный файл:

bash

/root/check-ats-ubuntu26-freepbx17.sh
Запуск:

bash

bash /root/check-ats-ubuntu26-freepbx17.sh
Проверяются:

PHP 8.3
PHP-FPM
MariaDB
Apache
incron
Asterisk
G.729
русские sounds
FreePBX framework
FreePBX core
FreePBX firewall
FreePBX sysadmin
FreePBX pm2
/usr/bin/php
/usr/bin/sysadmin_manager
firewall incron hook
Важные замечания
Скрипт не создаёт первого web-admin пользователя FreePBX.
Первичный web-admin создаётся вручную через браузер после первой загрузки /admin/.
Для Sysadmin и Firewall рекомендуется заранее подготовить полный offline-комплект.
При использовании режима file некоторые модули из старых списков могут быть недоступны в Asterisk 22.9 — это нормально и отражается в логах предупреждениями.
Для эксперимента используется стек Ubuntu 26.04 + PHP 8.3 source build, а не стандартный пакетный PHP.
Статус проекта
Сценарий ориентирован на практическую сборку и проверку стека:

Ubuntu 26.04
PHP 8.3 из исходников
Asterisk 22.9
FreePBX 17
G.729 через bcg729 + arkadijs/asterisk-g72x
Disclaimer
Использование — на свой риск.

Перед применением в production рекомендуется тестовая установка на чистой системе и сохранение собственного offline-набора исходников и модулей.