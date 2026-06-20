Поздравляю — мы реально докопались до корня и закрыли его чисто. Гонка chvt, а не магия. 👍
Ниже — README в двух языках. Структура одинаковая: суть → корень → фикс (этот репозиторий) → почему НЕ notifiers → сопутствующие грабли с фиксами (всё, что мы прошли, включая то, что было в Notion) → шпаргалка диагностики → источники. По конвенции GitHub можешь разложить на README.md (EN) + README.ru.md (RU), либо одним файлом с переключателем языков сверху.

🇷🇺 README (Русский)
NVIDIA Suspend Hard-Hang Fix — KDE Plasma 6 Wayland на гибридных (Optimus) ноутбуках
Однострочный фикс жёсткого зависания при усыплении на проприетарном драйвере NVIDIA в сессии KDE Plasma 6 Wayland. Лечит гонку в nvidia-sleep.sh, из-за которой композитор (KWin) не успевает отдать DRM-master до усыпления GPU.
Коротко (TL;DR)

Симптом: при suspend из залогиненной сессии Plasma 6 (Wayland) система уходит в s2idle и не возвращается — жёсткий ханг, Caps Lock не реагирует, спасает только хард-ребут. В логе последняя строка — PM: suspend entry (s2idle), резюме нет.
Корень: /usr/bin/nvidia-sleep.sh делает chvt 63, чтобы KWin отдал DRM-master, но не ждёт завершения переключения и сразу усыпляет GPU. KWin 6.7 не успевает отдать master, его замораживает systemd → на резюме NVIDIA не может переинициализироваться через удержанный master → ханг.
Фикс: одна строка sleep 3 в nvidia-sleep.sh между chvt 63 и записью в /proc/driver/nvidia/suspend.

Среда, где воспроизведено и починено

Ноутбук ASUS TUF A15 (Ryzen 7 6800H + Radeon 680M iGPU + RTX 3060 Laptop dGPU), гибрид (Optimus).
Fedora 44, KDE Plasma 6.7, Wayland, SDDM.
NVIDIA проприетарный драйвер 610.43.02 (DKMS), GSP active.
Сон: только s2idle (deep на этом железе нет).

Баг универсален для связки гибридный NVIDIA Optimus + проприетарный драйвер + KDE Plasma 6 Wayland; конкретные версии — это то, на чём мы воспроизвели и проверили фикс.
Это ваш баг? (симптомы)

Усыпление из сессии Plasma = труп; усыпление с экрана входа SDDM (до логина) = всё хорошо. Это главный различитель.
journalctl -b -1 обрывается на PM: suspend entry (s2idle), строк резюме (PM: suspend exit, nvidia-resume) нет.
Caps Lock не реагирует (если реагирует, а экран чёрный — это другой баг, см. «Труп vs зомби-экран»).
nvidia-smi -q | grep -i gsp показывает версию (GSP active), initramfs чистый — то есть базовые слои уже в порядке, а труп всё равно есть.

Корневая причина (подробно)
На проприетарном драйвере сохранение/восстановление VRAM при сне идёт через интерфейс /proc/driver/nvidia/suspend, который дёргает nvidia-sleep.sh (его вызывает nvidia-suspend.service). В пути засыпания скрипт делает:
bashfgconsole > "${XORG_VT_FILE}"   # запомнить текущий VT
chvt 63                          # уйти на пустой VT — чтобы KWin ОТДАЛ DRM-master
echo "$1" > /proc/driver/nvidia/suspend   # и СРАЗУ усыпить GPU
chvt 63 лишь запрашивает переключение VT. Реальное переключение и drmDropMaster у KWin происходят асинхронно. Скрипт не ждёт — он немедленно усыпляет GPU, а спустя десятки миллисекунд systemd замораживает пользовательскую сессию (SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=true). В итоге KWin замораживается, не успев отдать master, и держит его «замороженным». На резюме NVIDIA не может переинициализировать GPU через удержанный master → жёсткий ханг.
Экран входа SDDM не зависает, потому что его компоновщик отдаёт master чисто/быстро и в гонку не попадает.
Почему «вдруг»: ядро и драйвер у нас не менялись — менялся KWin (Plasma 6.6 → 6.7). Отдача master в новом KWin стала медленнее, и гонка, которую раньше выигрывали, стала проигрываться стабильно. Сама гонка от версий не зависит — просто некоторые версии KWin проигрывают её надёжнее.
Решение (этот репозиторий)
Дать KWin время завершить переключение VT и отдать master до усыпления GPU. В nvidia-sleep.sh, в ветке suspend|hibernate, вставляется одна строка:
bash        chvt 63
        if [[ $? -ne 0 ]]; then
            exit $?
        fi
        sleep 3                                   # дать Wayland-композитору отдать DRM-master
        echo "$1" > /proc/driver/nvidia/suspend
Важные свойства:

sleep стоит после проверки $? от chvt (проверка остаётся валидной) и до записи в /proc/... (GPU усыпляется на 3 сек позже). RET_VAL=$? ниже по-прежнему ловит результат записи, не sleep.
В ветку resume ничего не добавляется — там задержка не нужна.
Ребут и daemon-reload не нужны — скрипт вызывается заново при каждом усыплении, правка активна сразу.

Применение и тест:
bashsudo cp -a /usr/bin/nvidia-sleep.sh /usr/bin/nvidia-sleep.sh.bak   # бэкап
# внести правку (или скопировать скрипт из репозитория)
Тестировать при активной сессии Plasma (залогиньтесь локально — иначе условие не воспроизвести): systemctl suspend, подождать пару секунд, разбудить. Чистый resume = готово.
Откат: sudo cp -a /usr/bin/nvidia-sleep.sh.bak /usr/bin/nvidia-sleep.sh или просто удалить строку sleep 3. Пустой /proc/driver/nvidia/suspend-файл не трогаем. Систему правка не роняет — она бьёт только resume.
⚠️ Это файл из пакета драйвера. Обновление драйвера его перезапишет — после каждого обновления правку нужно наносить заново (или автоматизировать через скрипт/systemd path-юнит, следящий за файлом; пакетно-чистого способа вставить задержку между chvt и /proc-записью нет, т.к. это происходит внутри одного скрипта).
Значение sleep 3 подобрано с запасом; если на вашей машине KWin отдаёт master быстрее — можно снизить до 1–2 сек; если резюме всё ещё ловит ханг — поднять до 5.
Почему НЕ NVreg_UseKernelSuspendNotifiers=1
Логичная мысль — перейти на «современный» путь kernel suspend-notifiers и выкинуть legacy-скрипт. На Fedora с проприетарным драйвером — не делайте этого:

По README самого NVIDIA для 610, авто-обработка через suspend-notifiers — это про открытые модули. Для проприетарного драйвера штатный путь — /proc/driver/nvidia/suspend + NVreg_PreserveVideoMemoryAllocations=1.
На Fedora 43/44 + ядро 6.19+ путь UseKernelSuspendNotifiers=1 без сервисов сам зависает на засыпании (последняя строка лога — вход в сон), и рабочий обход у людей — вернуть notifiers=0 + сервисы (negativo17/nvidia-driver #196).
Плюс на Fedora запись temp-файла VRAM в этом пути душит SELinux (systemd_sleep_t).

Вывод: на проприетарном Fedora остаёмся на /proc-пути (notifiers=0, Preserve=1, сервисы включены) и лечим именно гонку chvt.
Сопутствующие грабли (что вы можете встретить ДО этого бага)
Гибрид NVIDIA + сон на Linux — слоёный пирог. Прежде чем гонка chvt вообще проявится, обычно надо пройти эти слои. Проверьте их по порядку.
1. GSP off из-за nvidia.ko в initramfs
Симптом: s2idle входит и виснет; nvidia-smi -q | grep -i gsp показывает N/A.

Корень: проприетарный драйвер кладёт /usr/lib/dracut/dracut.conf.d/99-nvidia.conf с omit_drivers ... nvidia ... (замысел — грузить модуль поздно из rootfs, где лежит прошивка GSP). Если initramfs собран вопреки и nvidia.ko в нём ЕСТЬ — модуль грузится рано, прошивки GSP в initramfs нет → Direct firmware load … error -2 → GSP off → кривой s0ix.

Диагностика: sudo lsinitrd | grep -i nvidia — должны быть только прошивки (usr/lib/firmware/nvidia/...), без nvidia.ko/nvidia_drm/nvidia_modeset/nvidia_uvm.

Фикс: пересобрать initramfs, чтобы omit применился: sudo dracut --force, ребут. Без хардкода версий и install_items. Гейт после: вывод lsinitrd | grep -i nvidia чистый, nvidia-smi -q | grep -i gsp показывает версию.
2. KWin дёргает GPU при усыплении (FREEZE_USER_SESSIONS)
Корень: пакет драйвера кладёт drop-in /usr/lib/systemd/system-sleep/... / systemd-suspend.service.d/nvidia-suspend-nofreeze.conf с SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false (NVIDIA хочет живые процессы для своего механизма VRAM). На KDE Wayland живой KWin лезет к GPU в момент усыпления → труп.

Фикс: замаскировать файлом с тем же именем в /etc (версия из /etc побеждает по приоритету):
bashsudo tee /etc/systemd/system/systemd-suspend.service.d/nvidia-suspend-nofreeze.conf >/dev/null <<'EOF'
[Service]
Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=true
EOF
sudo systemctl daemon-reload
systemctl show systemd-suspend.service -p Environment   # должно показать ...=true
Грабля: имя файла критично. Имя из /etc должно точно совпадать с пакетным (узнать через systemctl cat systemd-suspend.service) — иначе по алфавиту победит пакетный =false. Не угадывайте имя.

Замечание: с фиксом chvt-гонки (sleep 3) KWin отдаёт master до заморозки, так что фриз становится безвредным; нужен ли он строго — мы отдельно не проверяли, оставили как есть.
3. Не ставьте nvidia-drm.modeset=1 / nvidia_drm.fbdev=1 в cmdline руками
На Fedora 44 драйвер сам включает modeset (а в 590+ и fbdev). Ручная установка этих параметров в kernel cmdline сама ломает сон (у людей удаление nvidia_drm.fbdev=1 из cmdline чинило suspend). Проверка: cat /sys/module/nvidia_drm/parameters/modeset → Y (само по себе), а в cat /proc/cmdline нет nvidia-drm/nvidia_drm-параметров (кроме rd.driver.blacklist=nouveau/nova-core).
4. nvidia-powerd в гонке (если сон всё ещё ломается)
Если базовые слои в порядке, а сон всё равно нестабилен — встречается гонка с демоном Dynamic Boost:
bashsudo systemctl mask nvidia-powerd.service
Цена — отключение Dynamic Boost. Держите как запасной рычаг.
5. Труп vs «зомби-экран» — различать кнопкой Caps Lock
Два РАЗНЫХ отказа:

Caps Lock мёртв → жёсткий ханг ядра (этот README). Нужен хард-ресет.
Caps Lock реагирует, сеть жива, мёртв только дисплей → зомби-экран: апстримный баг nvidia-drm (Flip event timeout on head 0 / kwin «Pageflip timed out»), бьёт чаще на длинном сне. Хард-ресет не нужен — VT-свитч Ctrl+Alt+F3 → Ctrl+Alt+F2 (или F1) форсит modeset и возвращает сессию целиком.

6. Только s2idle (нет deep)
Многие гибридные ноутбуки умеют лишь s2idle (cat /sys/power/mem_sleep → [s2idle], без deep). Это нормально; именно s0ix-путь и чувствителен ко всему вышеперечисленному.
Шпаргалка диагностики
bash# GSP жив? initramfs чистый?
nvidia-smi -q | grep -i gsp
sudo lsinitrd | grep -i nvidia          # только прошивки, без *.ko

# Фриз сессии активен?
systemctl show systemd-suspend.service -p Environment

# Путь питания/режим
cat /proc/driver/nvidia/params | grep -iE 'Notifier|Preserve|S0ix|TemporaryFile'
cat /sys/power/mem_sleep
cat /proc/cmdline

# Что было перед смертью (поймать сигнатуру трупа)
journalctl --list-boots
journalctl -b -1 -o short-precise | tail -50

# Раскладка DRM-карт (гибрид)
ls -l /dev/dri/by-path/
Рекомендуемые модульные опции (проприетарный + s2idle)
/etc/modprobe.d/nvidia-power.conf (после правки — sudo dracut --force + ребут):
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp NVreg_EnableS0ixPowerManagement=1
Источники

NVIDIA, Chapter 20: Configuring Power Management (610.43.02 README) — proprietary vs open paths, /proc/driver/nvidia/suspend, PreserveVideoMemoryAllocations.
NVIDIA Developer Forums: «Nvidia-sleep.sh changes VT … is it still needed under Wayland?» — VT-свитч ломает Wayland-сессии; в r595+ скрипт делают ненужным.
KDE Discuss / Fedora Discussion — kwin_wayland не может заново захватить DRM-master после резюме; sleep после chvt.
GitHub negativo17/nvidia-driver #196 — UseKernelSuspendNotifiers=1 без сервисов виснет на Fedora 43/44 + ядро 6.19.
Fedora Discussion (F44 KDE + NVIDIA) — nvidia_drm.fbdev=1 в cmdline ломает сон; маскирование nvidia-powerd.

Дисклеймер
Это коммюнити-траблшутинг конкретной связки, не официальный фикс NVIDIA. Сон-баги умеют жёстко вешать машину — держите физический доступ к устройству и делайте бэкап/снапшот перед правками системных файлов.

🇬🇧 README (English)
NVIDIA Suspend Hard-Hang Fix — KDE Plasma 6 Wayland on hybrid (Optimus) laptops
A one-line fix for a hard hang on suspend with the proprietary NVIDIA driver inside a KDE Plasma 6 Wayland session. It fixes a race in nvidia-sleep.sh where the compositor (KWin) doesn't release the DRM master before the GPU is suspended.
TL;DR

Symptom: suspend from a logged-in Plasma 6 (Wayland) session enters s2idle and never returns — a hard hang, Caps Lock unresponsive, only a forced power-off recovers it. The last log line is PM: suspend entry (s2idle), with no resume.
Root cause: /usr/bin/nvidia-sleep.sh runs chvt 63 so KWin releases the DRM master, but it doesn't wait for the switch to complete before suspending the GPU. KWin 6.7 loses the race, gets frozen by systemd while still holding the master → on resume NVIDIA can't reinitialize through the held master → hang.
Fix: a single sleep 3 in nvidia-sleep.sh, between chvt 63 and the write to /proc/driver/nvidia/suspend.

Tested environment

ASUS TUF A15 (Ryzen 7 6800H + Radeon 680M iGPU + RTX 3060 Laptop dGPU), hybrid (Optimus).
Fedora 44, KDE Plasma 6.7, Wayland, SDDM.
NVIDIA proprietary driver 610.43.02 (DKMS), GSP active.
Sleep: s2idle only (no deep on this hardware).

The bug is generic to hybrid NVIDIA Optimus + proprietary driver + KDE Plasma 6 Wayland; the versions above are simply where it was reproduced and the fix verified.
Is this your bug? (symptoms)

Suspend from the Plasma session = hang; suspend from the SDDM greeter (before login) = fine. This is the key tell.
journalctl -b -1 ends at PM: suspend entry (s2idle), with no resume lines (PM: suspend exit, nvidia-resume).
Caps Lock is unresponsive (if it responds but the screen is black, that's a different bug — see "Hard hang vs zombie screen").
nvidia-smi -q | grep -i gsp shows a version (GSP active) and the initramfs is clean — i.e. the base layers are already correct, yet the hang persists.

Root cause (detailed)
On the proprietary driver, VRAM save/restore across sleep goes through the /proc/driver/nvidia/suspend interface, driven by nvidia-sleep.sh (invoked by nvidia-suspend.service). In the suspend path the script runs:
bashfgconsole > "${XORG_VT_FILE}"   # remember the current VT
chvt 63                          # switch to an empty VT — so KWin RELEASES the DRM master
echo "$1" > /proc/driver/nvidia/suspend   # and IMMEDIATELY suspend the GPU
chvt 63 only requests a VT switch. The actual switch and KWin's drmDropMaster happen asynchronously. The script doesn't wait — it suspends the GPU immediately, and tens of milliseconds later systemd freezes the user session (SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=true). KWin ends up frozen before it released the master, holding it "frozen". On resume, NVIDIA can't reinitialize the GPU through the held master → hard hang.
The SDDM greeter doesn't hang because its compositor releases the master cleanly/quickly and never enters the race.
Why "all of a sudden": our kernel and driver were unchanged — KWin changed (Plasma 6.6 → 6.7). Master release in the newer KWin became slower, and a race that used to be won is now lost consistently. The race itself is version-independent; some KWin versions just lose it more reliably.
The fix (this repository)
Give KWin time to finish the VT switch and release the master before the GPU is suspended. In nvidia-sleep.sh, in the suspend|hibernate case, add one line:
bash        chvt 63
        if [[ $? -ne 0 ]]; then
            exit $?
        fi
        sleep 3                                   # let the Wayland compositor drop the DRM master
        echo "$1" > /proc/driver/nvidia/suspend
Important properties:

sleep is placed after the $? check of chvt (the check stays valid) and before the /proc/... write (the GPU suspends 3 s later). RET_VAL=$? below still captures the write result, not sleep.
Nothing is added to the resume case — no delay is needed there.
No reboot or daemon-reload needed — the script is re-executed on every suspend, so the change is live immediately.

Apply and test:
bashsudo cp -a /usr/bin/nvidia-sleep.sh /usr/bin/nvidia-sleep.sh.bak   # backup
# apply the edit (or copy the script from this repo)
Test with an active Plasma session (log in locally — otherwise you can't reproduce the condition): systemctl suspend, wait a few seconds, wake. A clean resume means it's fixed.
Rollback: sudo cp -a /usr/bin/nvidia-sleep.sh.bak /usr/bin/nvidia-sleep.sh, or just delete the sleep 3 line. The change does not break the system — it only affects resume.
⚠️ This is a driver-package file. A driver update will overwrite it — you must re-apply the change after each update (or automate it with a script / a systemd path unit watching the file; there's no package-clean way to insert the delay between chvt and the /proc write, since both happen inside the one script).
The sleep 3 value is generous; if your KWin releases the master faster, you can lower it to 1–2 s; if resume still hangs, raise it to 5.
Why NOT NVreg_UseKernelSuspendNotifiers=1
The obvious idea is to move to the "modern" kernel-suspend-notifier path and drop the legacy script. On Fedora with the proprietary driver — don't:

Per NVIDIA's own 610 README, automatic handling via suspend notifiers is for the open kernel modules. The proprietary driver's supported path is /proc/driver/nvidia/suspend + NVreg_PreserveVideoMemoryAllocations=1.
On Fedora 43/44 + kernel 6.19+, the UseKernelSuspendNotifiers=1 path without the services hangs on suspend itself (last log line = entering sleep); the working fix people use is to go back to notifiers=0 + services (negativo17/nvidia-driver #196).
Also, on Fedora the VRAM temp-file write in that path is blocked by SELinux (systemd_sleep_t).

Conclusion: on proprietary Fedora, stay on the /proc path (notifiers=0, Preserve=1, services enabled) and fix the chvt race instead.
Adjacent pitfalls (things you may hit BEFORE this bug)
Hybrid NVIDIA + Linux sleep is a layered cake. Usually you must clear these layers before the chvt race even surfaces. Check them in order.
1. GSP off because nvidia.ko is in the initramfs
Symptom: s2idle enters and hangs; nvidia-smi -q | grep -i gsp shows N/A.

Cause: the proprietary driver ships /usr/lib/dracut/dracut.conf.d/99-nvidia.conf with omit_drivers ... nvidia ... (intent: load the module late from rootfs, where the GSP firmware lives). If the initramfs was built with nvidia.ko IN it, the module loads early, the GSP firmware isn't in the initramfs → Direct firmware load … error -2 → GSP off → broken s0ix.

Diagnostic: sudo lsinitrd | grep -i nvidia — should show only firmware (usr/lib/firmware/nvidia/...), no nvidia.ko/nvidia_drm/nvidia_modeset/nvidia_uvm.

Fix: rebuild the initramfs so omit applies: sudo dracut --force, reboot. No hardcoded versions, no install_items. Gate afterwards: lsinitrd | grep -i nvidia is clean and nvidia-smi -q | grep -i gsp shows a version.
2. KWin pokes the GPU during suspend (FREEZE_USER_SESSIONS)
Cause: the driver package ships a drop-in (.../systemd-suspend.service.d/nvidia-suspend-nofreeze.conf) with SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false (NVIDIA wants live processes for its VRAM mechanism). On KDE Wayland a live KWin touches the GPU during suspend → hang.

Fix: mask it with a file of the same name in /etc (the /etc version wins by priority):
bashsudo tee /etc/systemd/system/systemd-suspend.service.d/nvidia-suspend-nofreeze.conf >/dev/null <<'EOF'
[Service]
Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=true
EOF
sudo systemctl daemon-reload
systemctl show systemd-suspend.service -p Environment   # must show ...=true
Gotcha: the filename matters. Your /etc file must exactly match the package's name (find it via systemctl cat systemd-suspend.service) — otherwise the package's =false wins alphabetically. Don't guess the name.

Note: with the chvt race fix (sleep 3), KWin releases the master before the freeze, so the freeze becomes harmless; whether it's strictly required alongside the fix we didn't separately test, so we left it in place.
3. Don't set nvidia-drm.modeset=1 / nvidia_drm.fbdev=1 manually in cmdline
On Fedora 44 the driver enables modeset on its own (and fbdev on 590+). Setting these in the kernel cmdline manually breaks sleep by itself (removing nvidia_drm.fbdev=1 from cmdline has fixed suspend for people). Check: cat /sys/module/nvidia_drm/parameters/modeset → Y (on its own), and cat /proc/cmdline has no nvidia-drm/nvidia_drm params (other than rd.driver.blacklist=nouveau/nova-core).
4. nvidia-powerd race (if sleep is still broken)
If the base layers are clean but sleep is still unstable, there's a known race with the Dynamic Boost daemon:
bashsudo systemctl mask nvidia-powerd.service
Cost: Dynamic Boost disabled. Keep it as a fallback lever.
5. Hard hang vs "zombie screen" — tell them apart with Caps Lock
Two DIFFERENT failures:

Caps Lock dead → kernel hard hang (this README). Requires a hard reset.
Caps Lock responds, network alive, only the display dead → zombie screen: an upstream nvidia-drm bug (Flip event timeout on head 0 / kwin "Pageflip timed out"), more common on long sleeps. No hard reset needed — a VT switch Ctrl+Alt+F3 → Ctrl+Alt+F2 (or F1) forces a modeset and brings the whole session back.

6. s2idle only (no deep)
Many hybrid laptops only support s2idle (cat /sys/power/mem_sleep → [s2idle], no deep). That's normal; the s0ix path is exactly what's sensitive to everything above.
Diagnostic cheat sheet
bash# GSP alive? initramfs clean?
nvidia-smi -q | grep -i gsp
sudo lsinitrd | grep -i nvidia          # firmware only, no *.ko

# Session freeze active?
systemctl show systemd-suspend.service -p Environment

# Power path / sleep mode
cat /proc/driver/nvidia/params | grep -iE 'Notifier|Preserve|S0ix|TemporaryFile'
cat /sys/power/mem_sleep
cat /proc/cmdline

# What happened just before death (catch the hang signature)
journalctl --list-boots
journalctl -b -1 -o short-precise | tail -50

# DRM card layout (hybrid)
ls -l /dev/dri/by-path/
Recommended module options (proprietary + s2idle)
/etc/modprobe.d/nvidia-power.conf (after editing: sudo dracut --force + reboot):
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp NVreg_EnableS0ixPowerManagement=1
Sources

NVIDIA, Chapter 20: Configuring Power Management (610.43.02 README) — proprietary vs open paths, /proc/driver/nvidia/suspend, PreserveVideoMemoryAllocations.
NVIDIA Developer Forums: "Nvidia-sleep.sh changes VT … is it still needed under Wayland?" — the VT switch breaks Wayland sessions; the script is being made unnecessary in r595+.
KDE Discuss / Fedora Discussion — kwin_wayland failing to re-acquire the DRM master after resume; sleep after chvt.
GitHub negativo17/nvidia-driver #196 — UseKernelSuspendNotifiers=1 without the services hangs on Fedora 43/44 + kernel 6.19.
Fedora Discussion (F44 KDE + NVIDIA) — nvidia_drm.fbdev=1 in cmdline breaks sleep; masking nvidia-powerd.

Disclaimer
This is community troubleshooting for a specific stack, not an official NVIDIA fix. Sleep bugs can hard-hang a machine — keep physical access to the device and back up / snapshot before editing system files.
