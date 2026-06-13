#!/usr/bin/env python3
import os
import subprocess
import sys
import time

import usb.core
import usb.util

V, P = 0x05AC, 0x12A8
CONFIG = 5
VERBOSE = os.environ.get("VERBOSE", "0") == "1"


def log(msg: str) -> None:
    if VERBOSE:
        print(f"[usb-setup] {msg}", file=sys.stderr, flush=True)


def main() -> int:
    log("starting")
    subprocess.run(["pkill", "-x", "usbmuxd"], stderr=subprocess.DEVNULL)
    time.sleep(1)

    dev = usb.core.find(idVendor=V, idProduct=P)
    if dev is None:
        print("iPhone not found", file=sys.stderr)
        return 1

    try:
        cfg = dev.get_active_configuration().bConfigurationValue
    except usb.core.USBError:
        cfg = 0

    if cfg != CONFIG:
        log(f"config {cfg} -> mode 3 -> config {CONFIG}")
        try:
            dev.ctrl_transfer(0x40, 0x52, 0, 3, None, timeout=2000)
        except usb.core.USBError:
            pass
        time.sleep(3)
        dev = usb.core.find(idVendor=V, idProduct=P)
        if dev is None:
            return 1
        try:
            if dev.get_active_configuration().bConfigurationValue != CONFIG:
                dev.set_configuration(CONFIG)
        except usb.core.USBError as exc:
            print(f"set_configuration: {exc}", file=sys.stderr)
            return 1

    log("released for kernel cdc_ncm")
    usb.util.dispose_resources(dev)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
