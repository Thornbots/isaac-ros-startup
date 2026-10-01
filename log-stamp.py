#!/usr/bin/env python3
"""Stamp the stack's output: thornbots-start.sh pipes each run through this.

Usage: ... | log-stamp.py LOG_FILE. Each line goes to stdout (the journal)
and LOG_FILE as `[<uptime> <wall>] line`. Uptime is CLOCK_BOOTTIME, which
NTP never steps; wall time ends in '?' until NTP has synced. A [clock] line
marks the sync and each wall-clock step. LOG_FILE is fsynced every
second, so a power cut loses about 1 s of log.
"""
# see README.md for design rationale
import os
import select
import sys
import time

SYNC_FLAG = '/run/systemd/timesync/synchronized'
STEP_S = 0.5


def boottime():
    return time.clock_gettime(time.CLOCK_BOOTTIME)


def synced():
    return os.path.exists(SYNC_FLAG)


def wall():
    t = time.time()
    return (time.strftime('%H:%M:%S', time.localtime(t)) + f'.{int(t % 1 * 1000):03d}'
            + ('' if synced() else '?'))


def sync(f):
    try:
        f.flush()
        os.fsync(f.fileno())
    except OSError:
        pass


def main():
    out = sys.stdout
    try:
        log = open(sys.argv[1], 'a', encoding='utf-8')
    except OSError as e:
        out.write(f'[log-stamp] cannot open {sys.argv[1]} ({e}); journal only\n')
        log = None

    def emit(line):
        nonlocal log
        s = f'[{boottime():9.3f} {wall()}] {line}\n'
        out.write(s)
        if log:
            try:
                log.write(s)
            except OSError as e:  # disk full: keep the journal, drop the file
                out.write(f'[log-stamp] {sys.argv[1]} write failed ({e}); journal only\n')
                log = None

    was_synced = synced()
    offset = time.time() - boottime()
    emit(f'[clock] NTP synced, wall {time.strftime("%F %T %Z")}' if was_synced
         else '[clock] NTP not synced: wall times marked ? until it is')
    fd = sys.stdin.fileno()
    buf = b''
    last_sync = time.monotonic()
    while True:
        ready, _, _ = select.select([fd], [], [], 1.0)
        now_offset = time.time() - boottime()
        if not was_synced and synced():
            was_synced = True
            emit(f'[clock] NTP synced, wall {time.strftime("%F %T %Z")} '
                 f'(stepped {now_offset - offset:+.1f} s)')
            offset = now_offset
        if abs(now_offset - offset) > STEP_S:
            emit(f'[clock] wall clock stepped {now_offset - offset:+.1f} s')
            offset = now_offset
        if ready:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            buf += chunk
            *lines, buf = buf.split(b'\n')
            for raw in lines:
                emit(raw.decode('utf-8', 'replace').rstrip('\r'))
        out.flush()
        if log and time.monotonic() - last_sync >= 1.0:
            sync(log)
            last_sync = time.monotonic()
    if buf:
        emit(buf.decode('utf-8', 'replace'))
    out.flush()
    if log:
        sync(log)


if __name__ == '__main__':
    main()
