# Show the OpenMux install menu on the physical console only, once per login.
# /dev/serial0 is a symlink to whichever UART device is the active serial console
# (ttyAMA0, ttyS0, ...); resolve it so this works regardless of the underlying device name.
if [[ -z "${OPENMUX_MENU_SHOWN:-}" ]]; then
  current_tty="$(tty)"
  serial_tty="$(readlink -f /dev/serial0 2>/dev/null || true)"
  if [[ "$current_tty" == "/dev/tty1" ]] || { [[ -n "$serial_tty" ]] && [[ "$current_tty" == "$serial_tty" ]]; }; then
    export OPENMUX_MENU_SHOWN=1
    exec /usr/local/sbin/openmux-menu.sh
  fi
fi
