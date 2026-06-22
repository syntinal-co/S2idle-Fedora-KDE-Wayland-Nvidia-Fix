# NVIDIA Suspend Hard-Hang Fix — KDE Plasma 6 Wayland (hybrid / Optimus)

<div align="center">
<a href="#english"><b>🇬🇧 English</b></a> &nbsp;·&nbsp; <a href="#russian"><b>🇷🇺 Русский</b></a>
</div>

<a id="english"></a>

## English

A one-line fix for a **hard hang on suspend** with the proprietary NVIDIA driver inside a **KDE Plasma 6 Wayland** session on a hybrid (Optimus) laptop. It fixes a race in `nvidia-sleep.sh` where the compositor (KWin) doesn't release the DRM master before the GPU is suspended.

It also documents two **related fixes** that surfaced on the same hardware — a hang on any power-transition from a *blanked* screen (RTD3/DIFR deadlock) and a KDE lock-screen crash from a timer race. See *[Related fixes on this stack](#related-fixes-on-this-stack)*.

### What this fixes (TL;DR)
- **Symptom:** `suspend` from a logged-in Plasma 6 (Wayland) session enters s2idle and **never returns** — hard hang, Caps Lock unresponsive, only a forced power-off recovers it. Last log line is `PM: suspend entry (s2idle)`, no resume.
- **Root cause:** `/usr/bin/nvidia-sleep.sh` runs `chvt 63` so KWin releases the DRM master, but **doesn't wait** for the switch before suspending the GPU. KWin loses the race, gets frozen by systemd still holding the master → on resume NVIDIA can't reinitialize → hang.
- **Fix:** a single `sleep 3` in `nvidia-sleep.sh`, between `chvt 63` and the write to `/proc/driver/nvidia/suspend`.

### Tested on
ASUS TUF A15 (Ryzen 7 6800H + Radeon 680M iGPU + RTX 3060 Laptop dGPU) · Fedora 44 · KDE Plasma 6.7 Wayland · SDDM · NVIDIA proprietary 610.43.02 (DKMS) · s2idle only.
Generic to **hybrid NVIDIA Optimus + proprietary driver + KDE Plasma 6 Wayland**; the versions are just where it was reproduced and verified.

### Is this your bug?
- Suspend **from the Plasma session** = hang; suspend **from the SDDM greeter** (before login) = fine. This is the key tell.
- `journalctl -b -1` ends at `PM: suspend entry (s2idle)`, no `PM: suspend exit` / `nvidia-resume`.
- Caps Lock **unresponsive** (if it responds but the screen is black, that's a different bug — see *Other gotchas → hard hang vs zombie screen*).

### Root cause (detailed)
On the proprietary driver, VRAM save/restore across sleep goes through `/proc/driver/nvidia/suspend`, driven by `nvidia-sleep.sh` (invoked by `nvidia-suspend.service`). In the suspend path it runs:

```bash
fgconsole > "${XORG_VT_FILE}"   # remember the current VT
chvt 63                          # switch to an empty VT — so KWin RELEASES the DRM master
echo "$1" > /proc/driver/nvidia/suspend   # and IMMEDIATELY suspend the GPU
```

`chvt 63` only **requests** a VT switch; the switch and KWin's `drmDropMaster` happen **asynchronously**. The script doesn't wait — it suspends the GPU immediately, and tens of milliseconds later systemd freezes the user session (`SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=true`). KWin ends up frozen **before releasing the master**, holding it. On resume, NVIDIA can't reinitialize through the held master → hard hang. The greeter doesn't hang because its compositor releases the master cleanly/quickly.

Why "all of a sudden": our kernel and driver were unchanged — **KWin changed (Plasma 6.6 → 6.7)**. Master release in the newer KWin is slower, so a race that used to be won is now lost consistently. The race itself is version-independent.

### The fix (this repo)
This repo ships a patched `nvidia-sleep.sh` with the one line below added to the `suspend|hibernate` case:

```bash
        chvt 63
        if [[ $? -ne 0 ]]; then
            exit $?
        fi
        sleep 3                                   # let the Wayland compositor drop the DRM master
        echo "$1" > /proc/driver/nvidia/suspend
```

- `sleep` is **after** the `$?` check of `chvt` (the check stays valid) and **before** the `/proc` write. `RET_VAL=$?` below still captures the write result.
- Nothing is added to the `resume` case — no delay needed there.
- **No reboot or `daemon-reload`** — the script is re-executed on every suspend, so it's live immediately.

**Install:**
```bash
sudo cp -a /usr/bin/nvidia-sleep.sh /usr/bin/nvidia-sleep.sh.bak   # backup original
sudo install -m 0755 nvidia-sleep.sh /usr/bin/nvidia-sleep.sh      # copy patched script from this repo
# (or just add the single `sleep 3` line shown above to the existing file)
```
**Test** with an **active Plasma session** (log in locally — otherwise you can't reproduce the condition): `systemctl suspend`, wait a few seconds, wake. A clean resume means it's fixed.
**Rollback:** `sudo cp -a /usr/bin/nvidia-sleep.sh.bak /usr/bin/nvidia-sleep.sh`, or delete the `sleep 3` line. It only affects resume; it won't break boot.

> ⚠️ This is a driver-package file — a driver update **overwrites it**. Re-apply after each update, or automate it (e.g. a `systemd path` unit watching the file). There's no package-clean way to insert the delay between `chvt` and the `/proc` write, since both happen inside the one script.

`sleep 3` is generous; lower to 1–2 s if your KWin releases the master faster, raise to 5 if resume still hangs.

### The complete working stack
Three layers must **all** be in place for clean suspend on this hardware — confirmed stable together:
1. **GSP active** — `nvidia.ko` kept **out** of the initramfs (loads late from rootfs, where the GSP firmware lives).
2. **User session frozen during suspend** — `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=true`.
3. **VT-switch race fixed** — the `sleep 3` in `nvidia-sleep.sh` (this repo).

Setup for layers 1 and 2:

```bash
# Layer 1 — GSP: ensure nvidia.ko is omitted from initramfs (loads late from rootfs)
sudo lsinitrd | grep -i nvidia        # must show ONLY firmware (usr/lib/firmware/nvidia/...), no *.ko
sudo dracut --force                   # rebuild if needed, then reboot
nvidia-smi -q | grep -i gsp           # must show a version, NOT "N/A"

# Layer 2 — freeze: mask NVIDIA's nofreeze drop-in with the SAME filename under /etc
sudo tee /etc/systemd/system/systemd-suspend.service.d/nvidia-suspend-nofreeze.conf >/dev/null <<'EOF'
[Service]
Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=true
EOF
sudo systemctl daemon-reload
systemctl show systemd-suspend.service -p Environment   # must show ...=true
```
> The `/etc` file must **exactly match** the package's filename (find it via `systemctl cat systemd-suspend.service`) — otherwise the package's `=false` wins alphabetically. Don't guess the name.

### Why NOT `NVreg_UseKernelSuspendNotifiers=1`
The "modern" idea is to switch to kernel suspend notifiers and drop the legacy script. **On Fedora with the proprietary driver — don't:**
- NVIDIA's own 610 README: automatic handling via suspend notifiers is for the **open** kernel modules. The **proprietary** driver's supported path is `/proc/driver/nvidia/suspend` + `NVreg_PreserveVideoMemoryAllocations=1`.
- On Fedora 43/44 + kernel 6.19+, `UseKernelSuspendNotifiers=1` without the services **hangs on suspend** (last log line = entering sleep); the working fix people use is to go back to `notifiers=0` + services (negativo17/nvidia-driver #196).
- The VRAM temp-file write in that path is also blocked by SELinux (`systemd_sleep_t`) on Fedora.

So on proprietary Fedora: stay on the `/proc` path (`notifiers=0`, `Preserve=1`, services enabled) and fix the `chvt` race instead.

### Other gotchas you may hit
- **Don't set `nvidia-drm.modeset=1` / `nvidia_drm.fbdev=1` in the kernel cmdline manually.** On Fedora 44 the driver enables them on its own; setting them by hand can break sleep by itself. Verify `cat /sys/module/nvidia_drm/parameters/modeset` → `Y` and that `/proc/cmdline` has no `nvidia_drm` params (other than `rd.driver.blacklist=nouveau`/`nova-core`).
- **`nvidia-powerd` race.** If sleep is still unstable after the layers above: `sudo systemctl mask nvidia-powerd.service` (cost: Dynamic Boost disabled). Keep as a fallback lever.
- **Hard hang vs "zombie screen" — tell them apart with Caps Lock.** Caps dead → kernel hard hang (this README). Caps responds, only display black → **zombie screen** (upstream `nvidia-drm` flip-timeout, more common on long sleeps); **no reboot needed** — VT switch `Ctrl+Alt+F3` → `Ctrl+Alt+F2` (or `F1`) forces a modeset and restores the session. A **third** signature — Caps Lock still *blinks* but the whole machine is frozen (SSH dead, processes in D-state), triggered by a power-transition from a *blanked* screen — is a separate bug; see *[Related fixes → A](#a--hang-on-a-power-transition-from-a-blanked-screen-rtd3--difr-deadlock)*.
- **`s2idle` only.** Many hybrid laptops support only `s2idle` (`cat /sys/power/mem_sleep` → `[s2idle]`, no `deep`). Normal; the s0ix path is what's sensitive to all of the above.

### Related fixes on this stack
Two more bugs surfaced on this exact hardware after a reinstall. They share a *root condition* with the suspend hang — the internal panel is driven by the **discrete NVIDIA GPU** (`gpu_mux_mode=1` / Ultimate), so every display transition (dim, DPMS-off, modeset) goes through the fragile NVIDIA path (`nv_drm_reset_input_colorspace failed -35`, `atomic commit failed: EACCES`). But they are **distinct bugs with distinct fixes** — proven separate by testing, not assumed.

#### A — Hang on a power-transition from a blanked screen (RTD3 / DIFR deadlock)
- **Symptom:** full-system *zombie* — the kernel is alive (Caps Lock still **blinks**) but SSH is dead, `Ctrl+Alt+F<n>` won't switch VT, and processes are stuck in **D-state** (unkillable even by SIGKILL) → only a hard power-off recovers. Distinct from the suspend hard-hang above (there Caps Lock is fully **dead**) and from the *zombie screen* (there only the display is black and Caps responds).
- **Trigger:** `reboot` / `shutdown` / `suspend` initiated **while the display is blanked** (DPMS-off). With the display on — clean.
- **Root cause:** on NVIDIA 610.43.02 the `nvidia_modeset` thread deadlocks in the **DIFR** (Display Idle Frame Refresh) prefetch path — `nvDIFRPrefetchSurfaces → PrefetchHelperSurfaceEvo → nvWriteGpEntry` — where `nvWriteGpEntry` waits **unbounded** for GPFIFO space. When the GPU is idle / in D3cold it never drains the FIFO, so the wait never returns; the thread holds `nvkms_lock` forever, and every later modeset (suspend/reboot/shutdown) blocks in D-state.
- **Proof of mechanism:** force the dGPU awake and hold it in D0, then reboot from a blanked screen — it's **clean**. An awake GPU = no deadlock:
  ```bash
  echo on | sudo tee /sys/bus/pci/devices/0000:01:00.0/power/control   # hold dGPU in D0
  cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status           # -> active
  sudo reboot                                                          # from a blanked screen -> clean
  ```
- **Fix — disable runtime power management (RTD3 off; the dGPU stays awake):**
  ```bash
  # snapshot first (Btrfs/snapper example — use whatever you have)
  sudo snapper -c root create -d "pre RTD3-off (NVreg_DynamicPowerManagement=0x00)" --cleanup-algorithm number --print-number

  # override in /etc — do NOT edit the package file /usr/lib/modprobe.d/nvidia.conf.
  # the /etc override wins and survives driver updates.
  echo 'options nvidia NVreg_DynamicPowerManagement=0x00' | sudo tee /etc/modprobe.d/nvidia-rtd3-off.conf

  sudo dracut --force   # nvidia loads from initramfs with early KMS, so rebuild it
  # reboot — keep physical access
  ```
- **Check (PASS):**
  ```bash
  grep -i DynamicPowerManagement /proc/driver/nvidia/params          # -> 0
  cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status         # -> active (always)
  # then: reboot from a blanked screen is clean
  ```
- **Cost:** the dGPU stays in D0, **~6–10 W constant**. Fine on a desktop / always-on AC machine; on battery you'll feel it (consider the ASUS root path below, or only apply this when plugged in).
- **Upstream:** NVIDIA/open-gpu-kernel-modules [#1167](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1167) (exact match — 610.43.02, DPMS trigger, same stack, D-state, hard-reset-only) and [#1177](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1177) (same DIFR stack); fix in [PR #1192](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1192) ("bound the GPFIFO-space wait") — **not** yet in 610.43.02.

#### B — KDE lock screen crashes on idle-lock (timer race)
- **Symptom:** idle → the screen **dims** (~80% brightness, not black) → idle-timeout → the lock screen appears → 1–2 s later it crashes through a black flicker and drops you back into the session **unlocked** (**fail-open** — you are *not* locked). No crash dump.
- **Not caused by bug A:** with RTD3-off applied (dGPU `active`, never sleeping) the locker **still** died → separate bug, separate mechanism (confirmed by test, not assumed).
- **Root cause:** a race between **two timers set to the same value** — display dimming (PowerDevil `DimDisplay`, 5 min) and auto-lock (KScreenLocker `Timeout`, 5 min). They fire in the same second; the dimming/KWin operation collides with the locker's surface setup, and on the NVIDIA panel (fragile atomic commits) the locker surface dies → `kscreenlocker_greet: The Wayland connection broke`. No dump because it's a Wayland-socket break, not a segfault.
- **Proof:** the journal shows `backlighthelper` (dimming) firing in the **same second** as the lock. A manual lock (`loginctl lock-session`, no dim transition) is always clean.
- **Fix — stagger the timers** so dimming and auto-lock are **not** at the same time:
  - Dimming: `~/.config/powerdevilrc` → `[AC][Display]` → `DimDisplayIdleTimeoutSec` (seconds) and the `DimDisplayWhenIdle` toggle.
  - Auto-lock: `~/.config/kscreenlockerrc` → `[Daemon]` → `Timeout` (minutes).
  - Or via GUI: **System Settings → Power Management** (dimming) and **Screen Locking** (lock timer) — set them a couple of minutes apart.
- **Check (PASS):** dimming runs, the locker then appears **without** crashing (socket intact), and a later reboot is clean.
- **KDE context:** locker-vs-display-operation is a known class of bug — KDE [481308](https://bugs.kde.org/show_bug.cgi?id=481308) / 482077 (spurious screen-off on lock activation), [517912](https://bugs.kde.org/show_bug.cgi?id=517912) (Wayland greeter dies on screen removal/reinit). Cosmetic for most; **lethal on an NVIDIA-driven panel**.

#### ASUS-specific root path (this test hardware) — optional
This laptop is an ASUS, so it ships `asusctl` / `supergfxctl`. Switching the MUX to **Hybrid** routes the internal panel to the **AMD iGPU** instead of the NVIDIA dGPU:

```bash
asusctl armoury set gpu_mux_mode 0   # or: supergfxctl -m Hybrid
# reboot
```

That moves every display transition onto the rock-solid `amdgpu` path, which **closes both bug classes above at once** and lets you revert the RTD3-off workaround (the dGPU can sleep again, so you get battery life back). Cost: a reboot, and slightly lower gaming FPS in direct output compared to Ultimate/MUX mode.

> ⚠️ `asusctl` / `gpu_mux_mode` is **ASUS-specific tooling** — this exact command does not exist on other vendors. The *principle* is vendor-agnostic: **route the internal panel to the iGPU**. On a non-ASUS hybrid laptop, look for the equivalent MUX / "Discrete vs Hybrid" toggle in your BIOS or vendor utility. If your panel is already driven by the iGPU, you most likely won't hit either bug.

### Diagnostic cheat sheet
```bash
# GSP alive? initramfs clean?
nvidia-smi -q | grep -i gsp
sudo lsinitrd | grep -i nvidia          # firmware only, no *.ko

# Session freeze active?
systemctl show systemd-suspend.service -p Environment

# Power path / sleep mode
cat /proc/driver/nvidia/params | grep -iE 'Notifier|Preserve|S0ix|TemporaryFile|DynamicPower'
cat /sys/power/mem_sleep
cat /proc/cmdline

# RTD3 / dGPU runtime state (for the power-transition deadlock)
grep -i DynamicPowerManagement /proc/driver/nvidia/params
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status

# What happened just before death (the hang signature)
journalctl --list-boots
journalctl -b -1 -o short-precise | tail -50

# DRM card layout (hybrid)
ls -l /dev/dri/by-path/
```

### Recommended module options (proprietary + s2idle)
`/etc/modprobe.d/nvidia-power.conf` (after editing: `sudo dracut --force` + reboot):
```
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp NVreg_EnableS0ixPowerManagement=1
```
> If you also hit the **power-transition deadlock** (*[Related fixes → A](#a--hang-on-a-power-transition-from-a-blanked-screen-rtd3--difr-deadlock)*), add `NVreg_DynamicPowerManagement=0x00` in a **separate** file (`/etc/modprobe.d/nvidia-rtd3-off.conf`) — but only if affected; it pins the dGPU awake (~6–10 W).

### Sources
- NVIDIA — *Chapter 20: Configuring Power Management* (610.43.02 README): proprietary vs open paths, `/proc/driver/nvidia/suspend`, `PreserveVideoMemoryAllocations`.
- NVIDIA Developer Forums — *"Nvidia-sleep.sh changes VT … is it still needed under Wayland?"*: the VT switch breaks Wayland sessions; the script is being made unnecessary in r595+.
- KDE Discuss / Fedora Discussion — `kwin_wayland` failing to re-acquire the DRM master after resume; `sleep` after `chvt`.
- GitHub `negativo17/nvidia-driver` #196 — `UseKernelSuspendNotifiers=1` without the services hangs on Fedora 43/44 + kernel 6.19.
- Fedora Discussion (F44 KDE + NVIDIA) — `nvidia_drm.fbdev=1` in cmdline breaks sleep; masking `nvidia-powerd`.
- NVIDIA/open-gpu-kernel-modules [#1167](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1167) / [#1177](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1177) / [PR #1192](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1192) — DIFR/GPFIFO deadlock on power-transition (Related fix A).
- KDE bugs [481308](https://bugs.kde.org/show_bug.cgi?id=481308) / [517912](https://bugs.kde.org/show_bug.cgi?id=517912) — locker vs display-operation, Wayland greeter on NVIDIA (Related fix B).

### Disclaimer
Community troubleshooting for a specific stack, not an official NVIDIA fix. Sleep bugs can hard-hang a machine — keep physical access to the device and back up / snapshot before editing system files.

---

<a id="russian"></a>

## Русский

Однострочный фикс **жёсткого зависания при усыплении** на проприетарном драйвере NVIDIA в сессии **KDE Plasma 6 Wayland** на гибридном (Optimus) ноутбуке. Лечит гонку в `nvidia-sleep.sh`, из-за которой композитор (KWin) не успевает отдать DRM-master до усыпления GPU.

Здесь же задокументированы два **связанных фикса** с того же железа — вис любого power-перехода из *погашенного* экрана (RTD3/DIFR-дедлок) и краш KDE-локера из-за гонки таймеров. См. *[Связанные фиксы на этом стеке](#связанные-фиксы-на-этом-стеке)*.

### Что чинит (коротко)
- **Симптом:** `suspend` из залогиненной сессии Plasma 6 (Wayland) уходит в s2idle и **не возвращается** — жёсткий ханг, Caps Lock не реагирует, спасает только хард-ребут. Последняя строка лога — `PM: suspend entry (s2idle)`, резюме нет.
- **Корень:** `/usr/bin/nvidia-sleep.sh` делает `chvt 63`, чтобы KWin отдал DRM-master, но **не ждёт** завершения переключения и сразу усыпляет GPU. KWin не успевает отдать master, его замораживает systemd → на резюме NVIDIA не может переинициализироваться → ханг.
- **Фикс:** одна строка `sleep 3` в `nvidia-sleep.sh` между `chvt 63` и записью в `/proc/driver/nvidia/suspend`.

### Проверено на
ASUS TUF A15 (Ryzen 7 6800H + Radeon 680M iGPU + RTX 3060 Laptop dGPU) · Fedora 44 · KDE Plasma 6.7 Wayland · SDDM · NVIDIA проприетарный 610.43.02 (DKMS) · только s2idle.
Баг универсален для связки **гибридный NVIDIA Optimus + проприетарный драйвер + KDE Plasma 6 Wayland**; версии — это то, на чём воспроизведено и проверено.

### Это ваш баг?
- Усыпление **из сессии Plasma** = труп; усыпление **с экрана входа SDDM** (до логина) = всё хорошо. Главный различитель.
- `journalctl -b -1` обрывается на `PM: suspend entry (s2idle)`, без `PM: suspend exit` / `nvidia-resume`.
- Caps Lock **не реагирует** (если реагирует, а экран чёрный — это другой баг, см. *Прочие грабли → труп vs зомби-экран*).

### Корневая причина (подробно)
На проприетарном драйвере сохранение/восстановление VRAM при сне идёт через `/proc/driver/nvidia/suspend`, который дёргает `nvidia-sleep.sh` (его вызывает `nvidia-suspend.service`). В пути засыпания:

```bash
fgconsole > "${XORG_VT_FILE}"   # запомнить текущий VT
chvt 63                          # уйти на пустой VT — чтобы KWin ОТДАЛ DRM-master
echo "$1" > /proc/driver/nvidia/suspend   # и СРАЗУ усыпить GPU
```

`chvt 63` лишь **запрашивает** переключение VT; само переключение и `drmDropMaster` у KWin происходят **асинхронно**. Скрипт не ждёт — немедленно усыпляет GPU, а спустя десятки миллисекунд systemd замораживает сессию (`SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=true`). KWin замораживается, **не успев отдать master**, и держит его. На резюме NVIDIA не может переинициализироваться через удержанный master → жёсткий ханг. Экран входа не виснет, потому что его компоновщик отдаёт master чисто/быстро.

Почему «вдруг»: ядро и драйвер не менялись — менялся **KWin (Plasma 6.6 → 6.7)**. Отдача master в новом KWin медленнее, и гонка, которую раньше выигрывали, стала проигрываться стабильно. Сама гонка от версий не зависит.

### Решение (этот репозиторий)
В репозитории лежит патченый `nvidia-sleep.sh` с одной добавленной строкой в ветке `suspend|hibernate`:

```bash
        chvt 63
        if [[ $? -ne 0 ]]; then
            exit $?
        fi
        sleep 3                                   # дать Wayland-композитору отдать DRM-master
        echo "$1" > /proc/driver/nvidia/suspend
```

- `sleep` стоит **после** проверки `$?` от `chvt` (проверка валидна) и **до** записи в `/proc`. `RET_VAL=$?` ниже по-прежнему ловит результат записи.
- В ветку `resume` ничего не добавляется — там задержка не нужна.
- **Ребут и `daemon-reload` не нужны** — скрипт вызывается заново при каждом усыплении, правка активна сразу.

**Установка:**
```bash
sudo cp -a /usr/bin/nvidia-sleep.sh /usr/bin/nvidia-sleep.sh.bak   # бэкап оригинала
sudo install -m 0755 nvidia-sleep.sh /usr/bin/nvidia-sleep.sh      # скопировать патченый скрипт из репозитория
# (или просто добавить одну строку `sleep 3`, как показано выше)
```
**Тест** при **активной сессии Plasma** (залогиньтесь локально — иначе условие не воспроизвести): `systemctl suspend`, подождать пару секунд, разбудить. Чистый resume = готово.
**Откат:** `sudo cp -a /usr/bin/nvidia-sleep.sh.bak /usr/bin/nvidia-sleep.sh` или удалить строку `sleep 3`. Бьёт только resume, загрузку не ломает.

> ⚠️ Это файл из пакета драйвера — обновление драйвера его **перезапишет**. Наносите правку заново после каждого обновления или автоматизируйте (например, `systemd path`-юнит, следящий за файлом). Пакетно-чистого способа вставить задержку между `chvt` и `/proc`-записью нет — это внутри одного скрипта.

`sleep 3` — с запасом; снизьте до 1–2 с, если KWin отдаёт master быстрее, поднимите до 5, если резюме всё ещё виснет.

### Полный рабочий стек
Для чистого сна на этом железе должны быть на месте **все три** слоя — подтверждено рабочими вместе:
1. **GSP active** — `nvidia.ko` держим **вне** initramfs (грузится поздно из rootfs, где лежит прошивка GSP).
2. **Сессия заморожена при усыплении** — `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=true`.
3. **Гонка VT-свитча устранена** — `sleep 3` в `nvidia-sleep.sh` (этот репозиторий).

Настройка слоёв 1 и 2:

```bash
# Слой 1 — GSP: убедиться, что nvidia.ko НЕ в initramfs (грузится поздно из rootfs)
sudo lsinitrd | grep -i nvidia        # только прошивки (usr/lib/firmware/nvidia/...), без *.ko
sudo dracut --force                   # пересобрать при необходимости, затем ребут
nvidia-smi -q | grep -i gsp           # должна быть версия, НЕ "N/A"

# Слой 2 — фриз: замаскировать nofreeze-дропин NVIDIA файлом с ТЕМ ЖЕ именем в /etc
sudo tee /etc/systemd/system/systemd-suspend.service.d/nvidia-suspend-nofreeze.conf >/dev/null <<'EOF'
[Service]
Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=true
EOF
sudo systemctl daemon-reload
systemctl show systemd-suspend.service -p Environment   # должно показать ...=true
```
> Имя файла в `/etc` должно **точно совпадать** с пакетным (узнать через `systemctl cat systemd-suspend.service`) — иначе по алфавиту победит пакетный `=false`. Не угадывайте имя.

### Почему НЕ `NVreg_UseKernelSuspendNotifiers=1`
Логично перейти на «современный» путь kernel suspend-notifiers и выкинуть legacy-скрипт. **На Fedora с проприетарным драйвером — не делайте этого:**
- README самого NVIDIA для 610: авто-обработка через suspend-notifiers — это про **открытые** модули. Для **проприетарного** штатный путь — `/proc/driver/nvidia/suspend` + `NVreg_PreserveVideoMemoryAllocations=1`.
- На Fedora 43/44 + ядро 6.19+ путь `UseKernelSuspendNotifiers=1` без сервисов **сам виснет на засыпании** (последняя строка лога — вход в сон); рабочий обход у людей — вернуть `notifiers=0` + сервисы (negativo17/nvidia-driver #196).
- Плюс запись temp-файла VRAM в этом пути душит SELinux (`systemd_sleep_t`).

Вывод: на проприетарном Fedora остаёмся на `/proc`-пути (`notifiers=0`, `Preserve=1`, сервисы включены) и лечим именно гонку `chvt`.

### Прочие грабли
- **Не ставьте `nvidia-drm.modeset=1` / `nvidia_drm.fbdev=1` в cmdline руками.** На Fedora 44 драйвер включает их сам; ручная установка сама ломает сон. Проверка: `cat /sys/module/nvidia_drm/parameters/modeset` → `Y`, и в `/proc/cmdline` нет `nvidia_drm`-параметров (кроме `rd.driver.blacklist=nouveau`/`nova-core`).
- **Гонка `nvidia-powerd`.** Если сон всё ещё нестабилен после слоёв выше: `sudo systemctl mask nvidia-powerd.service` (цена — отключение Dynamic Boost). Запасной рычаг.
- **Труп vs «зомби-экран» — различать кнопкой Caps Lock.** Caps мёртв → жёсткий ханг ядра (этот README). Caps реагирует, мёртв только дисплей → **зомби-экран** (апстримный `nvidia-drm` flip-timeout, чаще на длинном сне); **ребут не нужен** — VT-свитч `Ctrl+Alt+F3` → `Ctrl+Alt+F2` (или `F1`) форсит modeset и возвращает сессию. Есть и **третья** сигнатура — Caps Lock **мигает**, но вся машина заморожена (SSH мёртв, процессы в D-state), триггер — power-переход из *погашенного* экрана — это отдельный баг; см. *[Связанные фиксы → A](#a--вис-power-перехода-из-погашенного-экрана-rtd3--difr-дедлок)*.
- **Только `s2idle`.** Многие гибриды умеют лишь `s2idle` (`cat /sys/power/mem_sleep` → `[s2idle]`, без `deep`). Это норма; s0ix-путь и чувствителен ко всему вышеперечисленному.

### Связанные фиксы на этом стеке
На том же железе после переустановки всплыли ещё два бага. У них общий *фон* с зависанием при усыплении — внутренняя панель работает на **дискретной NVIDIA** (`gpu_mux_mode=1` / Ultimate), поэтому каждый дисплейный переход (затемнение, DPMS-off, модесет) идёт через хрупкий NVIDIA-путь (`nv_drm_reset_input_colorspace failed -35`, `atomic commit failed: EACCES`). Но это **раздельные баги с раздельными фиксами** — доказано тестом, а не принято на веру.

#### A — вис power-перехода из погашенного экрана (RTD3 / DIFR-дедлок)
- **Симптом:** полносистемный *зомби* — ядро живо (Caps Lock **мигает**), но SSH мёртв, `Ctrl+Alt+F<n>` не переключает VT, процессы в **D-state** (неубиваемы даже SIGKILL) → спасает только хард-ресет. Отличается от хард-ханга при усыплении выше (там Caps Lock **мёртв** полностью) и от *зомби-экрана* (там чёрный только дисплей, а Caps реагирует).
- **Триггер:** `reboot` / `shutdown` / `suspend`, запущенный **когда дисплей погашен** (DPMS-off). С включённым дисплеем — чисто.
- **Корень:** на NVIDIA 610.43.02 поток `nvidia_modeset` дедлочит в **DIFR** (Display Idle Frame Refresh) prefetch-пути — `nvDIFRPrefetchSurfaces → PrefetchHelperSurfaceEvo → nvWriteGpEntry` — где `nvWriteGpEntry` ждёт **неограниченно** места в GPFIFO. GPU простаивает / в D3cold и не дренирует FIFO → ожидание не завершается → поток держит `nvkms_lock` навечно → все последующие модесеты (suspend/reboot/shutdown) блокируются в D-state.
- **Доказательство механизма:** разбудить dGPU в D0 и держать, затем ребут из погашенного — **чисто**. Бодрый GPU = нет дедлока:
  ```bash
  echo on | sudo tee /sys/bus/pci/devices/0000:01:00.0/power/control   # держать dGPU в D0
  cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status           # -> active
  sudo reboot                                                          # из погашенного -> чисто
  ```
- **Фикс — выключить runtime-управление питанием (RTD3 off; dGPU всегда бодрый):**
  ```bash
  # сначала снапшот (пример Btrfs/snapper — используй что есть)
  sudo snapper -c root create -d "pre RTD3-off (NVreg_DynamicPowerManagement=0x00)" --cleanup-algorithm number --print-number

  # override в /etc — пакетный /usr/lib/modprobe.d/nvidia.conf НЕ трогаем.
  # override в /etc побеждает и переживёт обновления драйвера.
  echo 'options nvidia NVreg_DynamicPowerManagement=0x00' | sudo tee /etc/modprobe.d/nvidia-rtd3-off.conf

  sudo dracut --force   # nvidia грузится из initramfs с ранним KMS — пересобрать
  # ребут — держи физический доступ
  ```
- **Проверка (PASS):**
  ```bash
  grep -i DynamicPowerManagement /proc/driver/nvidia/params          # -> 0
  cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status         # -> active (всегда)
  # затем: ребут из погашенного — чисто
  ```
- **Цена:** dGPU постоянно в D0, **~6–10 Вт**. Норм для стационара / always-on AC; на батарее почувствуешь (см. ASUS-путь ниже, либо применяй только от сети).
- **Апстрим:** NVIDIA/open-gpu-kernel-modules [#1167](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1167) (точное совпадение — 610.43.02, DPMS-триггер, тот же стек, D-state, only-hard-reset) и [#1177](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1177) (тот же DIFR-стек); фикс в [PR #1192](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1192) («bound the GPFIFO-space wait») — **ещё не** в 610.43.02.

#### B — KDE Lock Screen падает на idle-локе (гонка таймеров)
- **Симптом:** idle → экран **затемняется** (~80% яркости, не чёрный) → idle-timeout → появляется локер → через 1–2 с краш через чёрное мерцание → возврат в сессию **разблокированной** (**fail-open** — ты *не* заблокирован). Дампа нет.
- **Не следствие бага A:** с применённым RTD3-off (dGPU `active`, не спит) локер **всё равно** умирал → раздельный баг, иной механизм (подтверждено тестом, не на веру).
- **Корень:** гонка **двух таймеров на одном значении** — затемнение (PowerDevil `DimDisplay`, 5 мин) и автоблокировка (KScreenLocker `Timeout`, 5 мин). Срабатывают в одну секунду; операция затемнения/KWin сталкивается с настройкой поверхности локера, и на NVIDIA-панели (хрупкие atomic-commit) поверхность локера падает → `kscreenlocker_greet: The Wayland connection broke`. Дампа нет — это обрыв Wayland-сокета, не segfault.
- **Доказательство:** журнал — `backlighthelper` (затемнение) сработал в **ту же секунду**, что лок. Ручной лок (`loginctl lock-session`, без перехода) — всегда чист.
- **Фикс — разнести таймеры (стаггер)**, чтобы затемнение и автоблокировка были **не** на одно время:
  - Затемнение: `~/.config/powerdevilrc` → `[AC][Display]` → `DimDisplayIdleTimeoutSec` (секунды) и тумблер `DimDisplayWhenIdle`.
  - Автоблокировка: `~/.config/kscreenlockerrc` → `[Daemon]` → `Timeout` (минуты).
  - Или ГУЙ: **Параметры системы → Электропитание** (затемнение) и **Блокировка экрана** (таймер) — разведи на пару минут.
- **Проверка (PASS):** затемнение отрабатывает, локер затем появляется **без** краша (сокет цел), последующий ребут чист.
- **Контекст KDE:** связка «локер ↔ операция дисплея» — известный класс багов — KDE [481308](https://bugs.kde.org/show_bug.cgi?id=481308) / 482077 (самопроизвольный screen-off при активации локера), [517912](https://bugs.kde.org/show_bug.cgi?id=517912) (Wayland-гриттер падает на удалении/реинициализации экрана). У большинства косметика; **на NVIDIA-панели летально**.

#### Корневой путь для ASUS (это тестовое железо) — опционально
Этот ноут — ASUS, так что есть `asusctl` / `supergfxctl`. Переключение MUX в **Hybrid** уводит внутреннюю панель на **AMD iGPU** вместо NVIDIA dGPU:

```bash
asusctl armoury set gpu_mux_mode 0   # или: supergfxctl -m Hybrid
# ребут
```

Это переводит все дисплейные переходы на железобетонный `amdgpu`, что **закрывает оба класса багов выше разом** и позволяет откатить RTD3-off (dGPU снова может спать — возвращается батарея). Цена: ребут и чуть меньше игрового FPS в прямом выводе против Ultimate/MUX.

> ⚠️ `asusctl` / `gpu_mux_mode` — **ASUS-специфичный тулинг**, этой команды на других вендорах нет. *Принцип* vendor-agnostic: **увести внутреннюю панель на iGPU**. На не-ASUS гибриде ищи аналог MUX / «Discrete vs Hybrid» в BIOS или вендор-утилите. Если панель уже на iGPU — оба бага, скорее всего, тебя не коснутся.

### Шпаргалка диагностики
```bash
# GSP жив? initramfs чистый?
nvidia-smi -q | grep -i gsp
sudo lsinitrd | grep -i nvidia          # только прошивки, без *.ko

# Фриз сессии активен?
systemctl show systemd-suspend.service -p Environment

# Путь питания / режим сна
cat /proc/driver/nvidia/params | grep -iE 'Notifier|Preserve|S0ix|TemporaryFile|DynamicPower'
cat /sys/power/mem_sleep
cat /proc/cmdline

# RTD3 / runtime-состояние dGPU (для виса power-перехода)
grep -i DynamicPowerManagement /proc/driver/nvidia/params
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status

# Что было перед смертью (сигнатура трупа)
journalctl --list-boots
journalctl -b -1 -o short-precise | tail -50

# Раскладка DRM-карт (гибрид)
ls -l /dev/dri/by-path/
```

### Рекомендуемые модульные опции (проприетарный + s2idle)
`/etc/modprobe.d/nvidia-power.conf` (после правки: `sudo dracut --force` + ребут):
```
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp NVreg_EnableS0ixPowerManagement=1
```
> Если ловишь и **вис power-перехода** (*[Связанные фиксы → A](#a--вис-power-перехода-из-погашенного-экрана-rtd3--difr-дедлок)*), добавь `NVreg_DynamicPowerManagement=0x00` **отдельным** файлом (`/etc/modprobe.d/nvidia-rtd3-off.conf`) — но только если затронут; он пинит dGPU бодрым (~6–10 Вт).

### Источники
- NVIDIA — *Chapter 20: Configuring Power Management* (610.43.02 README): proprietary vs open пути, `/proc/driver/nvidia/suspend`, `PreserveVideoMemoryAllocations`.
- NVIDIA Developer Forums — *«Nvidia-sleep.sh changes VT … is it still needed under Wayland?»*: VT-свитч ломает Wayland-сессии; в r595+ скрипт делают ненужным.
- KDE Discuss / Fedora Discussion — `kwin_wayland` не может заново захватить DRM-master после резюме; `sleep` после `chvt`.
- GitHub `negativo17/nvidia-driver` #196 — `UseKernelSuspendNotifiers=1` без сервисов виснет на Fedora 43/44 + ядро 6.19.
- Fedora Discussion (F44 KDE + NVIDIA) — `nvidia_drm.fbdev=1` в cmdline ломает сон; маскирование `nvidia-powerd`.
- NVIDIA/open-gpu-kernel-modules [#1167](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1167) / [#1177](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1177) / [PR #1192](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1192) — DIFR/GPFIFO-дедлок на power-переходе (Связанный фикс A).
- KDE bugs [481308](https://bugs.kde.org/show_bug.cgi?id=481308) / [517912](https://bugs.kde.org/show_bug.cgi?id=517912) — локер vs операция дисплея, Wayland-гриттер на NVIDIA (Связанный фикс B).

### Дисклеймер
Коммюнити-траблшутинг конкретной связки, не официальный фикс NVIDIA. Сон-баги умеют жёстко вешать машину — держите физический доступ к устройству и делайте бэкап/снапшот перед правками системных файлов.
