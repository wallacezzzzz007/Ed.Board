"""Keep an existing PlatformIO sdkconfig on the 3A private partition table.

IDF defaults only affect missing keys, so an existing usb.3 config needs migration.
This updates partition paths and the bounded CDC RX capacity; no flash operation occurs.
"""
from pathlib import Path
import re

Import("env")
config = Path(env.subst("$PROJECT_DIR")) / ("sdkconfig." + env.subst("$PIOENV"))
if config.is_file():
    original = config.read_text()
    updated = original
    for key in ("CONFIG_PARTITION_TABLE_CUSTOM_FILENAME", "CONFIG_PARTITION_TABLE_FILENAME"):
        updated = re.sub(r"^" + key + r"=.*$", key + '="partitions.csv"', updated, flags=re.MULTILINE)
    key = "CONFIG_TINYUSB_CDC_RX_BUFSIZE"
    if re.search(r"^" + key + r"=", updated, flags=re.MULTILINE):
        updated = re.sub(r"^" + key + r"=.*$", key + "=8192", updated, flags=re.MULTILINE)
    else:
        updated += "\n" + key + "=8192\n"
    # Explicit cached NimBLE settings take precedence over defaults; update them here.
    defaults = (config.parent / "sdkconfig.defaults").read_text()
    for line in defaults.splitlines():
        match = re.match(r"(?:# )?(CONFIG_BT_[A-Z0-9_]+)(?:=| is not set)", line)
        if match:
            key = match.group(1)
            pattern = r"^(?:# )?" + key + r"(?:=.*| is not set)$"
            if re.search(pattern, updated, flags=re.MULTILINE):
                updated = re.sub(pattern, line, updated, flags=re.MULTILINE)
            else:
                updated += "\n" + line + "\n"
    if updated != original:
        config.write_text(updated)
        print("Ed.Board: synchronized private NVS partition and 8 KiB CDC RX buffer")
