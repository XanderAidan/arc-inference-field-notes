#!/usr/bin/env bash
# Reproduces F-4: both Arc cards report PCIe Gen1 x1 in sysfs and lspci, which is
# an ASPM/driver reporting artifact rather than a real link state.
#
# Run on any Linux host with an Intel Arc card. Needs no model and no GPU work.
# Read-only: touches nothing but sysfs and lspci output.
set -euo pipefail

echo "PCIe link report for Intel display/compute devices"
echo "=================================================="
echo

found=0
for dev in /sys/bus/pci/devices/*; do
    vendor=$(cat "$dev/vendor" 2>/dev/null || echo "")
    class=$(cat "$dev/class" 2>/dev/null || echo "")

    # 0x8086 = Intel. Class 0x0300xx = VGA, 0x038000 = other display.
    [[ "$vendor" == "0x8086" ]] || continue
    [[ "$class" == 0x03* ]] || continue

    slot=$(basename "$dev")
    cur_speed=$(cat "$dev/current_link_speed" 2>/dev/null || echo "n/a")
    cur_width=$(cat "$dev/current_link_width" 2>/dev/null || echo "n/a")
    max_speed=$(cat "$dev/max_link_speed" 2>/dev/null || echo "n/a")
    max_width=$(cat "$dev/max_link_width" 2>/dev/null || echo "n/a")

    name=$(lspci -s "$slot" 2>/dev/null | cut -d' ' -f2- || echo "unknown")

    echo "  device   : $slot"
    echo "  name     : $name"
    echo "  reported : $cur_speed  x$cur_width"
    echo "  capable  : $max_speed  x$max_width"

    if [[ "$cur_width" == "1" && "$max_width" == "1" ]]; then
        echo "  >> BOTH current and max report x1. No Arc card is manufactured as"
        echo "     a Gen1 x1 device, so the capability register is misreporting"
        echo "     too. This is the F-4 artifact and it needs no bandwidth test"
        echo "     to disprove: the stated capability is not a real product."
    elif [[ "$cur_width" == "1" ]]; then
        echo "  >> Current reports x1 but capability reports x$max_width. Either a"
        echo "     genuinely degraded link or a reporting artifact. Measure"
        echo "     host-to-device bandwidth before concluding the slot is bad."
    fi
    echo
    found=1
done

if [[ "$found" == "0" ]]; then
    echo "  No Intel display-class PCI device found."
    exit 1
fi

echo "Cross-check with the negotiated link as the device itself reports it:"
echo "  sudo lspci -vv | grep -A2 'LnkSta'"
echo
echo "A real Gen1 x1 link caps at roughly 250 MB/s. If host-to-device copies"
echo "exceed that, the sysfs figure above is a reporting artifact."
