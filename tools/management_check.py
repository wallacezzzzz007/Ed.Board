"""User-run protocol integration tests; temporary runtime override, no config write or flashing.

Use tools/logging/run.py monitor -- python3 tools/management_check.py --port PORT.
Close Ed.Board App and Monitor before running. Only Python standard library is used.
"""
import argparse
import copy
import fcntl
import json
import os
from pathlib import Path
import select
import termios
import time
import tty

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = json.loads((ROOT / "protocol/fixtures/management-v6.json").read_text())


def run(port):
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
                    if len(pending) > 65536:
                        raise RuntimeError("oversized serial stream")
            raise RuntimeError("request timeout: " + method)

        info = rpc("device.info", {})["result"]
        assert info["device"] == "Ed.Board" and info["schemaVersion"] == 6, info
        assert info.get("runtimeVersion") == 2, info
        baseline = rpc("config.get", {}, fragmented=True)["result"]
        assert baseline["writable"], baseline
        revision = baseline["revision"]
        assert rpc("device.info", {}, protocol=2)["error"]["code"] == "unsupported_protocol"
        assert rpc("not.a.method", {})["error"]["code"] == "unknown_method_or_params"
        for case in FIXTURES["invalidConfigs"]:
            print("CASE: " + case["name"], flush=True)
            reply = rpc("config.set", {"baseRevision": revision, "config": case["config"]}, fragmented=True)
            assert reply["error"]["code"] == "invalid_config", reply
        for nested in (False, True):
            config = copy.deepcopy(FIXTURES["validConfig"])
            target = config["layers"][0]["bindings"][0] if nested else config
            target["unknown"] = True
            reply = rpc("config.set", {"baseRevision": revision, "config": config})
            assert reply["error"]["code"] == "invalid_config", reply
        wrong_revision = revision - 1 if revision else 1
        reply = rpc("config.set", {"baseRevision": wrong_revision, "config": FIXTURES["maximumConfig"]})
        assert reply["error"]["code"] == "revision_conflict", reply
        if info.get("runtimeVersion") == 2:
            # Runtime-only checks: all controls must be released. No NVS writes.
            state = rpc("runtime.get", {})["result"]
            manual = state["manualLayer"]
            session = rpc("runtime.begin", {})["result"]["session"]
            candidate = next((l["id"] for l in baseline["config"]["layers"] if l["id"] != manual), manual)
            params = {"session": session, "sequence": 1, "layer": candidate, "baseRevision": revision}
            applied = rpc("runtime.auto", params)["result"]
            assert applied["activeLayer"] == candidate and applied["manualLayer"] == manual and not applied["pending"], applied
            assert rpc("runtime.auto", params)["error"]["code"] == "stale_auto_session"
            bad = dict(params, sequence=2, baseRevision=wrong_revision)
            assert rpc("runtime.auto", bad)["error"]["code"] == "revision_conflict"
            bad = dict(params, sequence=2, layer=0, unknown=True)
            assert rpc("runtime.auto", bad)["error"]["code"] == "invalid_auto"
            # Wait without renewals, observing expiry even while CDC diagnostics continue.
            deadline = time.monotonic() + 11
            while time.monotonic() < deadline:
                state = rpc("runtime.get", {})["result"]
                if state["autoLayer"] == 0 and state["activeLayer"] == manual:
                    break
                time.sleep(0.5)
            else:
                raise AssertionError("automatic lease did not expire")
            new_session = rpc("runtime.begin", {})["result"]["session"]
            assert new_session != session
            assert rpc("runtime.auto", dict(params, sequence=2))["error"]["code"] == "stale_auto_session"
            print("PASS: automatic priority, replay/revision/field/session rejection and lease expiry; manual layer preserved.", flush=True)
        final = rpc("config.get", {})["result"]
        assert final == baseline, (baseline, final)
        print("PASS: v3 fragmented read, layer/field/cycle rejection and maximum-config revision conflict; configuration unchanged.", flush=True)
    finally:
        os.close(fd)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    args = parser.parse_args()
    run(args.port)
