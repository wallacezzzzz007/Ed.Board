"""User-run BLE bond recovery. Clears only device BLE bonds with --clear-bonds.
Close Ed.Board and Monitor first. Uses the Python standard library only.
"""
import argparse
import fcntl
import json
import os
import select
import termios
import time
import tty

def run(port, clear_bonds):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    pending = bytearray()
    counter = 100
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.ioctl(fd, termios.TIOCEXCL)
        tty.setraw(fd)
        attrs = termios.tcgetattr(fd)
        attrs[4] = attrs[5] = termios.B115200
        termios.tcsetattr(fd, termios.TCSANOW, attrs)

        def rpc(method, params, protocol=1, fragmented=False):
            nonlocal counter
            counter += 1
            data = b"@edboard " + json.dumps({"protocol": protocol, "id": counter,
                "method": method, "params": params}, separators=(",", ":")).encode() + b"\n"
            deadline = time.monotonic() + 8
            offset = 0
            while offset < len(data):
                if time.monotonic() > deadline:
                    raise RuntimeError("write timeout")
                if select.select([], [fd], [], 0.2)[1]:
                    end = min(len(data), offset + (7 if fragmented else len(data)))
                    try:
                        offset += os.write(fd, data[offset:end])
                    except BlockingIOError:
                        pass
            while time.monotonic() < deadline:
                while b"\n" in pending:
                    raw, _, rest = pending.partition(b"\n")
                    pending[:] = rest
                    line = raw.decode("utf-8", errors="replace").strip()
                    print(line, flush=True)
                    if line.startswith("@edboard "):
                        reply = json.loads(line[9:])
                        if reply.get("id") == counter:
                            assert reply.get("protocol") == 1, reply
                            return reply
                if select.select([fd], [], [], 0.2)[0]:
                    try:
                        chunk = os.read(fd, 2048)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        raise RuntimeError("device disconnected")
                    pending.extend(chunk)
                    if len(pending) > 24576:
                        raise RuntimeError("oversized serial stream")
            raise RuntimeError("request timeout: " + method)

        def result(method, params):
            reply = rpc(method, params)
            if "error" in reply:
                raise RuntimeError(str(reply["error"]))
            return reply["result"]

        info = result("device.info", {})
        if info.get("device") != "Ed.Board" or info.get("schemaVersion") not in (3, 4, 5, 6):
            raise RuntimeError("Unexpected device identity/schema; no changes made")
        baseline = result("config.get", {})
        status = result("bluetooth.status", {})
        if not clear_bonds:
            print("STATUS:", status, flush=True)
            return
        if not status.get("initialized"):
            raise RuntimeError("Bluetooth unavailable; no clear requested")
        # Acceptance is not completion. Poll until the host task confirms storage.
        result("bluetooth.clear", {"confirm": True})
        deadline = time.monotonic() + 10
        while True:
            status = result("bluetooth.status", {})
            if status["clearStatus"] != -1:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("Clear completion timeout; do not assume success")
            time.sleep(0.2)
        if status["clearStatus"] != 0 or status["bonds"] != 0:
            raise RuntimeError("BLE clear failed: " + str(status))
        after = result("config.get", {})
        if after["revision"] != baseline["revision"] or after["config"] != baseline["config"]:
            raise RuntimeError("Configuration changed during BLE recovery")
        print("PASS: BLE bonds cleared; layers and revision unchanged:", after["revision"], flush=True)
    finally:
        os.close(fd)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--clear-bonds", action="store_true", help="Explicitly clear only keyboard BLE bonds")
    args = parser.parse_args()
    run(args.port, args.clear_bonds)
