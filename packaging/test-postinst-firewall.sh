#!/bin/sh
# Exercise ONLY the firewall block of the postinst. The range is "from the marker to the line before the
# systemd block", taken by line number: a sed/awk range ending at /^esac$/ stops at the FIRST esac, which is
# the port sanity check — that mistake made the first version of this harness print five empty results and
# look like a working test of nothing.
D=$(mktemp -d); export FWLOG="$D/log"; : > "$FWLOG"
printf 'listen: "%s"\n' "$LISTEN_UNDER_TEST" > "$D/config.yaml"
FROM=$(grep -n -- "---- the inbound firewall rule" "$POSTINST" | cut -d: -f1)
TO=$(( $(grep -n "^if command -v systemctl" "$POSTINST" | cut -d: -f1) - 1 ))
sed -n "${FROM},${TO}p" "$POSTINST" > "$D/block.sh"
CONF_FILE="$D/config.yaml" PATH="$STUBS:/usr/sbin:/usr/bin:/bin" sh "$D/block.sh"
echo "  -> commands: $(tr '\n' ';' < "$FWLOG")"
rm -rf "$D"
