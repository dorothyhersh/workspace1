#!/usr/bin/env bash
set -euo pipefail

MODEL="${1:-Infinix Smart 8 Plus}"
BRAND="${2:-Infinix}"
MANUF="${3:-INFINIX}"

wait_boot() {
  adb wait-for-device
  until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 2; done
}

# Script that runs on the device (avoids quoting problems with spaces)
cat > /tmp/patch.sh <<EOF
for f in /system/build.prop /vendor/build.prop /product/build.prop /system_ext/build.prop /odm/etc/build.prop; do
  [ -f "\$f" ] || continue
  sed -i -E \
    -e 's|^(ro\.product\.([a-z_]+\.)?model)=.*|\1=${MODEL}|' \
    -e 's|^(ro\.product\.([a-z_]+\.)?brand)=.*|\1=${BRAND}|' \
    -e 's|^(ro\.product\.([a-z_]+\.)?manufacturer)=.*|\1=${MANUF}|' \
    "\$f"
done
EOF

adb root; sleep 2
adb disable-verity
adb reboot; wait_boot
adb root; sleep 2
adb remount

adb push /tmp/patch.sh /data/local/tmp/patch.sh
adb shell sh /data/local/tmp/patch.sh

adb reboot; wait_boot
adb shell getprop ro.product.model
adb shell getprop ro.product.manufacturer
