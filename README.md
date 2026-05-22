# Ubuntu 26.04 + PHP 8.3 (source) + Asterisk 22.9 + FreePBX 17

Установочный скрипт для сборки рабочей АТС на базе:

- Ubuntu 26.04
- PHP 8.3 из исходников
- Asterisk 22.9
- FreePBX 17
- G.729 через `bcg729` + `arkadijs/asterisk-g72x`
- обязательные русские sounds
- обязательные модули FreePBX `Sysadmin` и `Firewall`
- рабочий `UCP Daemon` через `Node.js 18` + `PM2`

---

## Назначение

Проект предназначен для практической сборки и проверки стека:

- **Ubuntu 26.04**
- **PHP 8.3 из исходников**
- **Asterisk 22.9**
- **FreePBX 17**

Скрипт ориентирован именно на этот экспериментальный стек и не использует стандартный пакетный PHP из репозиториев Ubuntu.

---

## Поддерживаемая платформа

Только:

- **Ubuntu 26.04**

> Debian не является целевой платформой этого скрипта.

---

## Что делает скрипт

Скрипт:

- устанавливает базовые системные зависимости
- собирает **PHP 8.3** из исходников в `/usr/local/php83`
- устанавливает и настраивает **PHP-FPM**
- собирает **Asterisk 22.9** из исходников
- устанавливает **FreePBX 17**
- создает и настраивает MariaDB-базы FreePBX
- собирает **G.729** через:
  - `bcg729`
  - `arkadijs/asterisk-g72x`
- устанавливает **русские sounds**
- устанавливает и включает модули **Sysadmin** и **Firewall**
- настраивает `incron`
- настраивает `pm2`
- поднимает **UCP Daemon**
- создает отдельный скрипт проверки после установки

---

## Ключевые особенности

- приоритет всегда у локального каталога:

```bash
/root/offline-assets/
если нужный файл отсутствует локально, используется загрузка из интернета
поддерживается полностью офлайн-логика для критичных компонентов
FreePBX устанавливается без создания первого web-admin пользователя
Sysadmin и Firewall считаются обязательными
UCP Daemon приводится в рабочее состояние через:
Node.js 18.20.8
PM2 5.2.2
offline global archive PM2
fwconsole pm2 --update
Что устанавливается
PHP 8.3.x из исходников в:
/usr/local/php83
Asterisk 22.9.x
FreePBX 17
MariaDB
Apache2
Node.js 18.20.8
PM2
incron
fail2ban
русские sound-пакеты
G.729 codec
UCP Daemon
Выбор модулей Asterisk
Во время установки скрипт предлагает 3 режима выбора модулей Asterisk.

1. preset
Стандартный преднастроенный набор.

Используется встроенный набор модулей скрипта плюс обязательные модули для работы FreePBX.

2. file
Выбор модулей из файла:

bash

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
Если модуль отсутствует в Asterisk 22.9 или недоступен в menuselect, в лог будет записано предупреждение.

3. menu
Ручной выбор через интерактивный menuselect.

Скрипт откроет интерфейс menuselect, где можно вручную отметить нужные модули, сохранить изменения и продолжить установку.

Локальный каталог offline-файлов
Скрипт в первую очередь ищет исходники и архивы в каталоге:

bash

/root/offline-assets/
Если нужный файл там не найден, используется интернет-загрузка.

Какие файлы поддерживаются в /root/offline-assets/
Ниже перечислены файлы и каталоги, которые понимает скрипт.

PHP
text

/root/offline-assets/php-8.3.31.tar.gz
Asterisk
text

/root/offline-assets/asterisk-22.9.0.tar.gz
Русские sounds
Поддерживаются, например:

text

/root/offline-assets/asterisk-sounds-ru.tar.gz
/root/offline-assets/asterisk-core-sounds-ru-wav-current.tar.gz
ionCube
text

/root/offline-assets/ioncube_loaders_lin_x86-64.tar.gz
Node.js для UCP / PM2
text

/root/offline-assets/node-v18.20.8-linux-x64.tar.xz
PM2 offline archive
text

/root/offline-assets/pm2-global-5.2.2-node18-linux-x64.tar.gz
bcg729
Можно положить либо каталог:

text

/root/offline-assets/bcg729/
либо архив:

text

/root/offline-assets/bcg729.tar.gz
/root/offline-assets/bcg729-*.tar.gz
/root/offline-assets/bcg729-*.tar.bz2
asterisk-g72x
Можно положить либо каталог:

text

/root/offline-assets/asterisk-g72x/
либо архив:

text

/root/offline-assets/asterisk-g72x.tar.gz
/root/offline-assets/asterisk-g72x-*.tar.gz
/root/offline-assets/asterisk-g72x-*.tar.bz2
FreePBX framework / source dir
Можно положить каталог:

text

/root/offline-assets/freepbx/
GPG-ключ FreePBX
Опционально:

text

/root/offline-assets/freepbx*.gpg
Sysadmin / Firewall offline assets
Для офлайн-установки обязательных модулей Sysadmin и Firewall нужны:

text

/root/offline-assets/sysadmin17_8.2-8.2_sng12_all.deb
/root/offline-assets/sysadmin-lib.tar.gz
/root/offline-assets/freepbx-sysadmin-module-dir.tar.gz
/root/offline-assets/freepbx-firewall-module-dir.tar.gz
Минимальный рекомендуемый offline-набор
Для максимально предсказуемой установки рекомендуется заранее подготовить:

text

/root/offline-assets/php-8.3.31.tar.gz
/root/offline-assets/asterisk-22.9.0.tar.gz
/root/offline-assets/asterisk-sounds-ru.tar.gz
/root/offline-assets/ioncube_loaders_lin_x86-64.tar.gz
/root/offline-assets/node-v18.20.8-linux-x64.tar.xz
/root/offline-assets/pm2-global-5.2.2-node18-linux-x64.tar.gz
/root/offline-assets/freepbx-sangoma.gpg
/root/offline-assets/sysadmin17_8.2-8.2_sng12_all.deb
/root/offline-assets/sysadmin-lib.tar.gz
/root/offline-assets/freepbx-sysadmin-module-dir.tar.gz
/root/offline-assets/freepbx-firewall-module-dir.tar.gz
И дополнительно для G.729:

text

/root/offline-assets/bcg729/
или:

text

/root/offline-assets/bcg729*.tar.gz
и:

text

/root/offline-assets/asterisk-g72x/
или:

text

/root/offline-assets/asterisk-g72x*.tar.gz
Дополнительные offline-файлы
В каталоге могут находиться и дополнительные файлы, например:

text

/root/offline-assets/jansson-2.14.1.tar.bz2
/root/offline-assets/pjproject-2.16.tar.bz2
/root/offline-assets/sysadmin17-0.2.36.tgz.gpg
/root/offline-assets/pm2-5.4.3.tgz
Они могут использоваться как вспомогательные файлы, но основная рабочая схема для UCP/PM2 в текущем варианте опирается именно на:

text

/root/offline-assets/node-v18.20.8-linux-x64.tar.xz
/root/offline-assets/pm2-global-5.2.2-node18-linux-x64.tar.gz
Порядок поиска файлов
Для большинства исходников и архивов применяется такой порядок:

поиск в /root/offline-assets/
поиск в локальных местах вроде /root и /tmp, если это предусмотрено скриптом
скачивание из интернета
То есть приоритет всегда у локального offline-набора.

Пример подготовки offline-каталога
bash

mkdir -p /root/offline-assets

cp php-8.3.31.tar.gz /root/offline-assets/
cp asterisk-22.9.0.tar.gz /root/offline-assets/
cp asterisk-sounds-ru.tar.gz /root/offline-assets/
cp ioncube_loaders_lin_x86-64.tar.gz /root/offline-assets/
cp node-v18.20.8-linux-x64.tar.xz /root/offline-assets/
cp pm2-global-5.2.2-node18-linux-x64.tar.gz /root/offline-assets/

cp -a bcg729 /root/offline-assets/
cp -a asterisk-g72x /root/offline-assets/

cp freepbx-sangoma.gpg /root/offline-assets/
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
При необходимости параметры можно переопределять через environment variables.

Пример:

bash

PHP_VER=8.3.31 AST_VER=22.9.0 FREEPBX_TAG=release/17.0 bash install.sh
Поддерживаемые полезные переменные:

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
NODE_VERSION_REQUIRED
NODE_TARBALL_NAME
PM2_GLOBAL_ARCHIVE_NAME
Примеры запуска
Преднастроенный набор модулей
bash

AST_MODULE_MODE=preset bash install.sh
Список модулей из файла
bash

AST_MODULE_MODE=file AST_MODULE_FILE=/root/prod-modules.txt bash install.sh
Ручной выбор через menuselect
bash

AST_MODULE_MODE=menu bash install.sh
Логи
Основной лог установки сохраняется в файл вида:

bash

/root/install-ats-YYYY-MM-DD-HHMMSS.log
Пример поиска предупреждений:

bash

LOG="$(ls -1t /root/install-ats-*.log | head -1)"
grep -nE "Модуль .* недоступен|Включён модуль|Итог выбора модулей|WARN" "$LOG"
Показать только проблемные модули:

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
UCP PM2 process
UCP ports 8001/8003
/usr/bin/php
/usr/bin/sysadmin_manager
firewall incron hook
UCP Daemon / PM2
Для работы UCP Daemon в текущем варианте используется:

Node.js 18.20.8
PM2 5.2.2
офлайн-восстановление PM2 из global archive
обновление PM2-состояния через:
bash

fwconsole pm2 --update
После успешного восстановления UCP Daemon обычно работает как процесс ucp в PM2 и слушает:

8001/tcp
8003/tcp
Для офлайн-режима обязательно подготовьте:

text

/root/offline-assets/node-v18.20.8-linux-x64.tar.xz
/root/offline-assets/pm2-global-5.2.2-node18-linux-x64.tar.gz
Что будет после установки
После завершения скрипта вы получите:

работающий Asterisk
работающий FreePBX 17
PHP 8.3 из исходников
рабочий G.729
установленные русские sounds
включенные Sysadmin и Firewall
поднятый UCP Daemon
файл с реквизитами и параметрами установки
отдельный проверочный скрипт
Важные замечания
Скрипт не создаёт первого web-admin пользователя FreePBX.
Первичный web-admin создаётся вручную через браузер после первого открытия /admin/.
Для Sysadmin и Firewall рекомендуется заранее подготовить полный offline-комплект.
Для стабильной офлайн-работы UCP Daemon нужно заранее подготовить offline Node.js и offline PM2 archive.
При использовании режима file некоторые модули из старых списков могут отсутствовать в Asterisk 22.9 — это нормально и отражается предупреждениями в логах.
Скрипт ориентирован именно на Ubuntu 26.04.
Рекомендуется использовать чистую систему.
Статус проекта
Рабочий сценарий ориентирован на практическую проверку и развертывание стека:

Ubuntu 26.04
PHP 8.3 из исходников
Asterisk 22.9
FreePBX 17
G.729 через bcg729 + arkadijs/asterisk-g72x
UCP Daemon через Node.js 18 + PM2
Disclaimer
Использование — на свой риск.

Перед применением в production рекомендуется:

тестовая установка на чистой системе
подготовка собственного offline-набора архивов и исходников
отдельная проверка:
UCP
Sysadmin
Firewall
G.729
русских sounds
