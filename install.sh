#!/usr/bin/env bash
#
# install.sh — durable-деплой sleep-fix для NVIDIA suspend на KDE Plasma 6 Wayland.
#
# Подход 1 (переадресация — переживает обновления драйвера):
#   1. кладёт патченый nvidia-sleep.sh (из этого репо: usr/bin/) в /usr/local/sbin/
#      — этот путь пакетный менеджер NVIDIA не трогает;
#   2. ставит systemd drop-in на nvidia-suspend.service и nvidia-hibernate.service,
#      переопределяя ExecStart на нашу копию (resume НЕ трогаем — пауза ему не нужна);
#   3. systemctl daemon-reload + проверка эффективного ExecStart.
#
# Источник копии — usr/bin/nvidia-sleep.sh в этом репо (хранится под своим
# «родным» путём; деплоится в /usr/local/sbin, чтобы апдейты драйвера не затёрли).
#
# Идемпотентно. После МАЖОРНОГО обновления драйвера (610->620):
#   1) обнови usr/bin/nvidia-sleep.sh в репо из нового /usr/bin (сток + sleep после chvt);
#   2) прогони ./install.sh снова.
#
# Откат:  sudo ./install.sh uninstall
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO_DIR/usr/bin/nvidia-sleep.sh"
DEST="/usr/local/sbin/nvidia-sleep.sh"
SUSPEND_DROPIN="/etc/systemd/system/nvidia-suspend.service.d/10-sleep-fix.conf"
HIBERNATE_DROPIN="/etc/systemd/system/nvidia-hibernate.service.d/10-sleep-fix.conf"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Нужны права root. Запусти: sudo $0 ${1:-install}" >&2
    exit 1
  fi
}

uninstall() {
  require_root uninstall
  echo "==> Откат sleep-fix"
  rm -f "$SUSPEND_DROPIN" "$HIBERNATE_DROPIN"
  rmdir /etc/systemd/system/nvidia-suspend.service.d \
        /etc/systemd/system/nvidia-hibernate.service.d 2>/dev/null || true
  rm -f "$DEST"
  systemctl daemon-reload
  echo "    drop-in'ы и копия удалены; юниты вернулись на сток (/usr/bin/nvidia-sleep.sh)."
}

install_fix() {
  require_root install

  # 0) источник на месте и реально пропатчен (есть пауза перед усыплением GPU)
  [[ -f "$SRC" ]] || { echo "ОШИБКА: нет исходника: $SRC" >&2; exit 1; }
  if ! grep -Eq '^[[:space:]]*sleep[[:space:]]+[0-9]' "$SRC"; then
    echo "ОШИБКА: в $SRC нет строки 'sleep N' — это не пропатченная версия." >&2
    echo "        Обнови usr/bin/nvidia-sleep.sh (сток + sleep после chvt) и повтори." >&2
    exit 1
  fi

  # 1) копия в безопасное место
  echo "==> Копия: $DEST"
  install -D -m0755 "$SRC" "$DEST"

  # 2) drop-in'ы: ExecStart= (сброс списка) + логгер + наша копия
  echo "==> drop-in: $SUSPEND_DROPIN"
  install -d "$(dirname "$SUSPEND_DROPIN")"
  cat > "$SUSPEND_DROPIN" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/logger -t suspend -s "nvidia-suspend.service"
ExecStart=/usr/local/sbin/nvidia-sleep.sh "suspend"
EOF

  echo "==> drop-in: $HIBERNATE_DROPIN"
  install -d "$(dirname "$HIBERNATE_DROPIN")"
  cat > "$HIBERNATE_DROPIN" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/logger -t hibernate -s "nvidia-hibernate.service"
ExecStart=/usr/local/sbin/nvidia-sleep.sh "hibernate"
EOF

  # SELinux-контексты (если включён)
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$DEST" "$SUSPEND_DROPIN" "$HIBERNATE_DROPIN" 2>/dev/null || true
  fi

  # 3) перечитать юниты
  echo "==> systemctl daemon-reload"
  systemctl daemon-reload

  # 4) самопроверка: эффективный ExecStart ведёт на нашу копию
  echo
  echo "==> Проверка (эффективный ExecStart):"
  systemctl show -p ExecStart nvidia-suspend.service   | grep -q "$DEST" \
    && echo "    suspend   -> $DEST  OK" \
    || { echo "    suspend   -> НЕ на копию, проверь вручную!" >&2; exit 1; }
  systemctl show -p ExecStart nvidia-hibernate.service | grep -q "$DEST" \
    && echo "    hibernate -> $DEST  OK" \
    || { echo "    hibernate -> НЕ на копию, проверь вручную!" >&2; exit 1; }

  echo
  echo "Готово. Ребут не нужен. Контрольный suspend — при руках у машины."
}

case "${1:-install}" in
  install)   install_fix ;;
  uninstall) uninstall ;;
  *) echo "Использование: sudo $0 [install|uninstall]" >&2; exit 1 ;;
esac
