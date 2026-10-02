#!/usr/bin/env python3
"""Run a developer command in a PTY, keeping bounded current/previous logs."""
import argparse
from datetime import datetime, timezone
import errno
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import sys
import termios
import tty

ROOT = Path(__file__).resolve().parents[2]
LIMIT = 16 * 1024 * 1024


class Log:
    def __init__(self, directory, kind, limit=LIMIT):
        self.current = directory / f'{kind}.log'
        self.previous = directory / f'{kind}.previous.log'
        self.limit = limit
        self.size = 0
        for path in (self.current, self.previous):
            if path.is_symlink():
                raise ValueError(f'Refusing symlink log: {path}')
        if self.current.exists():
            # Keep only the bounded tail when migrating an older unbounded file.
            with self.current.open('rb') as source, self.previous.open('wb') as target:
                source.seek(max(0, source.seek(0, 2) - limit))
                shutil.copyfileobj(source, target)
        self.file = self.current.open('wb')

    def write(self, data):
        while data:
            if self.size == self.limit:
                self.file.close()
                os.replace(self.current, self.previous)
                self.file = self.current.open('wb')
                self.size = 0
            chunk, data = data[:self.limit - self.size], data[self.limit - self.size:]
            self.file.write(chunk)
            self.file.flush()
            self.size += len(chunk)

    def close(self):
        self.file.close()


def run(command, log):
    pid, master = pty.fork()
    if pid == 0:
        try:
            os.execvp(command[0], command)
        except OSError as error:
            print(error, file=sys.stderr, flush=True)
            os._exit(127)
    interactive = sys.stdin.isatty()
    saved = termios.tcgetattr(0) if interactive else None
    old_handlers = {}

    def resize(*_):
        if interactive:
            try:
                fcntl.ioctl(master, termios.TIOCSWINSZ, fcntl.ioctl(0, termios.TIOCGWINSZ, bytes(8)))
            except OSError:
                pass
        else:
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))

    def forward(number, _):
        try:
            os.killpg(pid, number)
        except ProcessLookupError:
            pass

    try:
        resize()
        for number, handler in ((signal.SIGWINCH, resize), (signal.SIGTERM, forward), (signal.SIGHUP, forward), (signal.SIGINT, forward)):
            old_handlers[number] = signal.signal(number, handler)
        if interactive:
            tty.setraw(0)
        inputs = [master, 0] if interactive else [master]
        if not interactive:
            os.write(master, b'\x04')
        while True:
            ready, _, _ = select.select(inputs, [], [])
            if master in ready:
                try:
                    data = os.read(master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    data = b''
                if not data:
                    break
                log.write(data)
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
            if 0 in ready:
                data = os.read(0, 4096)
                if data:
                    os.write(master, data)
                else:
                    inputs.remove(0)
        _, status = os.waitpid(pid, 0)
        code = os.waitstatus_to_exitcode(status)
        return code if code >= 0 else 128 - code
    except BaseException:
        forward(signal.SIGTERM, None)
        raise
    finally:
        if saved is not None:
            termios.tcsetattr(0, termios.TCSADRAIN, saved)
        for number, handler in old_handlers.items():
            signal.signal(number, handler)
        os.close(master)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kind', choices=['build', 'upload', 'monitor'])
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ['--']:
        command = command[1:]
    if not command:
        parser.error('a command is required after --')
    if shutil.which(command[0]) is None:
        parser.error(f'command not found: {command[0]}')
    directory = ROOT / 'test-results'
    directory.mkdir(exist_ok=True)
    with (directory / f'.{args.kind}.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error(f'another {args.kind} logging session is running')
        log = Log(directory, args.kind)
        try:
            log.write(f'[Ed.Board {args.kind} started {datetime.now(timezone.utc).isoformat()}]\n'.encode())
            code = run(command, log)
            log.write(f'\n[Ed.Board command exit={code} ended {datetime.now(timezone.utc).isoformat()}]\n'.encode())
            return code
        finally:
            log.close()


if __name__ == '__main__':
    sys.exit(main())
