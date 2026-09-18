#!/usr/bin/env python3
"""efx web interface — a browser front end for the efx build scripts.

Standard library only: no Flask, no npm, no build step. Start it with

    tools/efx/efx gui

and open the URL it prints.

Design notes
------------
Everything the GUI can do is a call to ``tools/efx/efx``; the server never
reimplements build logic. That keeps the browser and the shell in agreement and
means any button here can be reproduced by copying one command.

Only one job runs at a time, matching the flock the shell scripts take. Jobs run
in their own process group so that cancelling kills the whole make(1) tree
instead of orphaning it.

The server executes shell commands, so it binds to loopback, checks Host and
Origin, and accepts only whitelisted component/verb pairs — never a path or a
command line from the client.
"""

from __future__ import annotations

import argparse
import html
import json
import mimetypes
import os
import secrets
import signal
import subprocess
import threading
import time
import urllib.parse
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EFX_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EFX_BIN = os.path.join(EFX_DIR, "efx")
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
STATE_DIR = os.path.join(EFX_DIR, "state")
LOG_DIR = os.path.join(EFX_DIR, "logs")

# What the browser is allowed to ask for. Anything not listed here is rejected
# before it reaches a shell.
ACTIONS: dict[str, list[str]] = {
    "config": ["detect", "configure", "reconfigure", "regen-dt", "reset", "diff"],
    "fsbl": ["build", "rebuild", "clean", "restore"],
    "opensbi": ["build", "rebuild", "clean", "config"],
    "uboot": ["build", "rebuild", "clean", "savedefconfig", "config"],
    "kernel": ["build", "rebuild", "clean", "savedefconfig", "config"],
    "image": ["build", "rebuild", "clean"],
    "fpga": ["check", "memories", "bram-update", "verify-fsbl", "build", "pgm"],
    "flash": ["list", "image"],  # writing to a device is CLI-only, see README
    "clean": ["images", "build", "logs", "workspace", "repo-reset"],
    "preflight": [""],
}

# Verbs that destroy work. The UI double-confirms these; the server records them
# so an accidental fetch() cannot trigger one silently.
DESTRUCTIVE = {
    ("config", "reset"), ("config", "configure"),
    ("clean", "workspace"), ("clean", "images"), ("clean", "build"),
    ("clean", "repo-reset"),
    ("fsbl", "restore"),
}

# Actions that only read. These take no build lock in the shell either, so
# gating them behind a running build would just make the GUI feel broken while a
# long kernel build is in progress.
READ_ONLY = {
    ("preflight", ""),
    ("config", "detect"), ("config", "diff"),
    ("fpga", "check"), ("fpga", "memories"),
    ("flash", "list"),
    ("opensbi", "config"), ("uboot", "config"), ("kernel", "config"),
}

MAX_LINES = 5000


class Job:
    """One running (or finished) efx invocation."""

    _seq = 0
    _seq_lock = threading.Lock()

    def __init__(self, component: str, action: str, argv: list[str]):
        with Job._seq_lock:
            Job._seq += 1
            self.id = f"job{Job._seq}-{int(time.time())}"

        self.component = component
        self.action = action
        self.argv = argv
        self.started = time.time()
        self.finished: float | None = None
        self.returncode: int | None = None
        self.lines: deque[tuple[int, str]] = deque(maxlen=MAX_LINES)
        self.next_seq = 0
        self.proc: subprocess.Popen | None = None
        self.cond = threading.Condition()

    # -- output -----------------------------------------------------------

    def append(self, text: str) -> None:
        with self.cond:
            self.lines.append((self.next_seq, text))
            self.next_seq += 1
            self.cond.notify_all()

    def since(self, after: int) -> list[tuple[int, str]]:
        with self.cond:
            return [(s, t) for s, t in self.lines if s > after]

    @property
    def running(self) -> bool:
        return self.finished is None

    def summary(self) -> dict:
        return {
            "id": self.id,
            "component": self.component,
            "action": self.action,
            "command": " ".join(self.argv),
            "started": self.started,
            "finished": self.finished,
            "returncode": self.returncode,
            "running": self.running,
            "lines": self.next_seq,
        }

    # -- lifecycle --------------------------------------------------------

    def run(self) -> None:
        env = dict(os.environ)
        env["EFX_NO_COLOR"] = "1"   # the browser renders its own styling
        env["PYTHONUNBUFFERED"] = "1"

        try:
            self.proc = subprocess.Popen(
                self.argv,
                cwd=os.path.dirname(EFX_DIR),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                env=env,
                text=True,
                bufsize=1,
                # Own process group: cancelling must take the whole make tree.
                start_new_session=True,
            )
        except OSError as exc:
            self.append(f"failed to start: {exc}")
            self.finished = time.time()
            self.returncode = 127
            with self.cond:
                self.cond.notify_all()
            return

        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            self.append(line.rstrip("\n"))

        self.returncode = self.proc.wait()
        self.finished = time.time()
        self.append(f"— exit {self.returncode} —")
        with self.cond:
            self.cond.notify_all()

    def cancel(self) -> bool:
        if self.proc is None or not self.running:
            return False
        pgid = os.getpgid(self.proc.pid)
        # SIGINT first: make(1) cleans up its current target rather than leaving
        # a half-written one behind.
        for sig, wait in ((signal.SIGINT, 10), (signal.SIGTERM, 5), (signal.SIGKILL, 0)):
            try:
                os.killpg(pgid, sig)
            except ProcessLookupError:
                return True
            for _ in range(wait * 2):
                if not self.running:
                    return True
                time.sleep(0.5)
        return True


def shell_lock_holder() -> str | None:
    """Who holds the build flock, if anyone.

    The scripts take a flock whether they were started from a terminal or from
    here, so a build kicked off in a shell has to block the GUI too. Without this
    the GUI would happily spawn a job that immediately exits 'busy'.
    """
    try:
        with open(os.path.join(STATE_DIR, "lock-pid")) as fh:
            pid = int(fh.read().strip())
    except (OSError, ValueError):
        return None
    try:
        os.kill(pid, 0)
    except OSError:
        return None            # stale lock file, the process is gone
    try:
        with open(os.path.join(STATE_DIR, "lock-holder")) as fh:
            return fh.read().strip() or f"pid {pid}"
    except OSError:
        return f"pid {pid}"


class JobManager:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.jobs: dict[str, Job] = {}
        self.order: deque[str] = deque(maxlen=50)
        self.current: Job | None = None

    def start(self, component: str, action: str) -> tuple[Job | None, str | None]:
        read_only = (component, action) in READ_ONLY

        with self.lock:
            if not read_only:
                if self.current is not None and self.current.running:
                    return None, f"{self.current.component} {self.current.action} is still running"

                holder = shell_lock_holder()
                if holder:
                    return None, f"a build is already running: {holder}"

            argv = [EFX_BIN, component]
            if action:
                argv.append(action)
            if component == "clean":
                argv.append("-y")

            job = Job(component, action, argv)
            self.jobs[job.id] = job
            self.order.append(job.id)
            # Read-only queries must not become "the current job", or a quick
            # `fpga memories` would block the next real build until it finished.
            if not read_only:
                self.current = job

        threading.Thread(target=job.run, daemon=True).start()
        return job, None

    def get(self, job_id: str) -> Job | None:
        with self.lock:
            return self.jobs.get(job_id)

    def recent(self, limit: int = 20) -> list[dict]:
        with self.lock:
            ids = list(self.order)[-limit:][::-1]
            return [self.jobs[i].summary() for i in ids if i in self.jobs]


JOBS = JobManager()
TOKEN = secrets.token_urlsafe(24)


def run_efx(args: list[str], timeout: int = 120) -> tuple[int, str]:
    """Run a read-only efx query and capture its output."""
    env = dict(os.environ)
    env["EFX_NO_COLOR"] = "1"
    try:
        proc = subprocess.run(
            [EFX_BIN] + args,
            cwd=os.path.dirname(EFX_DIR),
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )
        return proc.returncode, (proc.stdout or "") + (proc.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s"


class Handler(BaseHTTPRequestHandler):
    server_version = "efx-gui"
    protocol_version = "HTTP/1.1"

    # Quieten the default one-line-per-request logging; job output is the
    # interesting stream here.
    def log_message(self, fmt: str, *args) -> None:
        if self.server.verbose:            # type: ignore[attr-defined]
            super().log_message(fmt, *args)

    # -- helpers ----------------------------------------------------------

    def _send(self, code: int, body: bytes, ctype: str, extra: dict | None = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, obj, code: int = 200) -> None:
        self._send(code, json.dumps(obj).encode(), "application/json; charset=utf-8")

    def _error(self, code: int, message: str) -> None:
        self._json({"error": message}, code)

    def _origin_ok(self) -> bool:
        """Reject cross-site requests: this server runs shell commands."""
        host = self.headers.get("Host", "")
        hostname = host.rsplit(":", 1)[0].strip("[]")
        if hostname not in ("localhost", "127.0.0.1", "::1"):
            return False
        origin = self.headers.get("Origin")
        if origin:
            parsed = urllib.parse.urlparse(origin)
            if parsed.hostname not in ("localhost", "127.0.0.1", "::1"):
                return False
        return True

    # -- routing ----------------------------------------------------------

    def do_GET(self) -> None:
        if not self._origin_ok():
            return self._error(403, "cross-origin requests are not allowed")

        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        if path == "/" or path == "/index.html":
            return self._static("index.html")
        if path.startswith("/static/"):
            return self._static(path[len("/static/"):])

        if path == "/api/health":
            return self._json({"ok": True, "token": TOKEN, "efx": EFX_BIN})

        if path == "/api/status":
            rc, out = run_efx(["status", "--json"])
            if rc != 0:
                return self._error(500, out.strip() or "efx status failed")
            try:
                return self._json(json.loads(out))
            except json.JSONDecodeError:
                return self._error(500, f"efx status emitted invalid JSON: {out[:400]}")

        if path == "/api/config":
            return self._config_get()

        if path == "/api/actions":
            return self._json({
                "actions": ACTIONS,
                "destructive": [list(x) for x in sorted(DESTRUCTIVE)],
            })

        if path == "/api/jobs":
            return self._json({"jobs": JOBS.recent()})

        if path.startswith("/api/jobs/"):
            job = JOBS.get(path[len("/api/jobs/"):])
            if job is None:
                return self._error(404, "no such job")
            data = job.summary()
            after = int(query.get("after", ["-1"])[0])
            data["output"] = [{"seq": s, "text": t} for s, t in job.since(after)]
            return self._json(data)

        if path.startswith("/api/stream/"):
            return self._stream(path[len("/api/stream/"):])

        if path == "/api/logs":
            return self._logs_list()

        if path.startswith("/api/logs/"):
            return self._log_read(path[len("/api/logs/"):])

        if path == "/api/file":
            return self._file_get(query.get("path", [""])[0])

        return self._error(404, "not found")

    def do_POST(self) -> None:
        if not self._origin_ok():
            return self._error(403, "cross-origin requests are not allowed")

        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return self._error(400, "invalid JSON body")

        if path == "/api/jobs":
            return self._job_start(body)

        if path.startswith("/api/cancel/"):
            job = JOBS.get(path[len("/api/cancel/"):])
            if job is None:
                return self._error(404, "no such job")
            return self._json({"cancelled": job.cancel()})

        if path == "/api/config":
            return self._config_put(body)

        if path == "/api/file":
            return self._file_put(body)

        if path == "/api/shutdown":
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return self._json({"ok": True})

        return self._error(404, "not found")

    def do_PUT(self) -> None:
        self.do_POST()

    # -- endpoints --------------------------------------------------------

    def _static(self, name: str) -> None:
        safe = os.path.normpath(os.path.join(STATIC_DIR, name))
        if not safe.startswith(STATIC_DIR) or not os.path.isfile(safe):
            return self._error(404, "not found")
        ctype, _ = mimetypes.guess_type(safe)
        with open(safe, "rb") as fh:
            self._send(200, fh.read(), ctype or "application/octet-stream")

    def _job_start(self, body: dict) -> None:
        component = str(body.get("component", ""))
        action = str(body.get("action", ""))

        if component not in ACTIONS:
            return self._error(400, f"unknown component: {component}")
        if action not in ACTIONS[component]:
            return self._error(400, f"'{action}' is not allowed for {component}")
        if (component, action) in DESTRUCTIVE and not body.get("confirm"):
            return self._error(409, "this action is destructive and needs confirm: true")

        job, err = JOBS.start(component, action)
        if job is None:
            return self._error(409, err or "busy")
        return self._json(job.summary(), 202)

    def _stream(self, job_id: str) -> None:
        """Server-sent events, resumable through Last-Event-ID."""
        job = JOBS.get(job_id)
        if job is None:
            return self._error(404, "no such job")

        try:
            after = int(self.headers.get("Last-Event-ID", "-1"))
        except ValueError:
            after = -1

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        def emit(event: str, seq: int | None, data: dict) -> bool:
            chunk = ""
            if seq is not None:
                chunk += f"id: {seq}\n"
            chunk += f"event: {event}\ndata: {json.dumps(data)}\n\n"
            try:
                self.wfile.write(chunk.encode())
                self.wfile.flush()
                return True
            except (BrokenPipeError, ConnectionResetError, ValueError):
                return False

        last_ping = time.time()
        while True:
            pending = job.since(after)
            for seq, text in pending:
                if not emit("line", seq, {"text": text}):
                    return
                after = seq

            if not job.running and not job.since(after):
                emit("done", None, job.summary())
                return

            if not pending:
                with job.cond:
                    job.cond.wait(timeout=1.0)
                # A comment line keeps proxies and browsers from timing the
                # connection out during the quiet stretches of a long build.
                if time.time() - last_ping > 15:
                    try:
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError, ValueError):
                        return
                    last_ping = time.time()

    def _config_get(self) -> None:
        rc, out = run_efx(["status", "--json"])
        keys = self._read_schema()
        return self._json({"keys": keys, "conf_path": os.path.join(EFX_DIR, "efx.conf")})

    def _read_schema(self) -> list[dict]:
        """Parse efx.keys plus the current efx.conf into one list for the UI."""
        schema_path = os.path.join(EFX_DIR, "efx.keys")
        conf_path = os.path.join(EFX_DIR, "efx.conf")

        values: dict[str, str] = {}
        if os.path.isfile(conf_path):
            with open(conf_path) as fh:
                for line in fh:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    values[k.strip()] = v.strip().strip('"').strip("'")

        keys = []
        with open(schema_path) as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                parts = line.split("|")
                if len(parts) < 5:
                    continue
                name, ktype, default, group, desc = parts[:5]
                keys.append({
                    "name": name,
                    "type": ktype,
                    "default": default,
                    "group": group,
                    "description": desc,
                    "value": values.get(name, default),
                    "options": ktype[5:].split(",") if ktype.startswith("enum:") else None,
                })
        return keys

    def _config_put(self, body: dict) -> None:
        updates = body.get("values")
        if not isinstance(updates, dict):
            return self._error(400, "expected {\"values\": {...}}")

        known = {k["name"] for k in self._read_schema()}
        unknown = sorted(set(updates) - known)
        if unknown:
            return self._error(400, f"unknown keys: {', '.join(unknown)}")

        conf_path = os.path.join(EFX_DIR, "efx.conf")
        lines: list[str] = []
        seen: set[str] = set()
        if os.path.isfile(conf_path):
            with open(conf_path) as fh:
                for line in fh:
                    stripped = line.strip()
                    if stripped and not stripped.startswith("#") and "=" in stripped:
                        k = stripped.split("=", 1)[0].strip()
                        if k in updates:
                            lines.append(f"{k}={updates[k]}\n")
                            seen.add(k)
                            continue
                    lines.append(line)

        for k, v in updates.items():
            if k not in seen:
                lines.append(f"{k}={v}\n")

        tmp = conf_path + ".tmp"
        with open(tmp, "w") as fh:
            fh.writelines(lines)
        os.replace(tmp, conf_path)

        # Report validation rather than silently accepting a broken config.
        rc, out = run_efx(["status", "--json"])
        return self._json({"ok": rc == 0, "message": "" if rc == 0 else out.strip()})

    def _logs_list(self) -> None:
        entries = []
        if os.path.isdir(LOG_DIR):
            for name in sorted(os.listdir(LOG_DIR), reverse=True):
                full = os.path.join(LOG_DIR, name)
                if os.path.islink(full) or not os.path.isfile(full):
                    continue
                st = os.stat(full)
                entries.append({"name": name, "size": st.st_size, "mtime": st.st_mtime})
        return self._json({"logs": entries[:200]})

    def _log_read(self, name: str) -> None:
        safe = os.path.normpath(os.path.join(LOG_DIR, name))
        if not safe.startswith(LOG_DIR) or not os.path.isfile(safe):
            return self._error(404, "no such log")
        with open(safe, errors="replace") as fh:
            text = fh.read()
        self._send(200, text.encode(), "text/plain; charset=utf-8")

    # Editing configuration fragments is how the GUI replaces menuconfig, which
    # cannot run in a browser. Only files inside the repo or the workspace are
    # reachable, and only ones that look like configuration.
    EDITABLE_SUFFIXES = (".config", ".cfg", ".defconfig", "_defconfig", ".dts", ".dtsi", ".h", ".conf")

    def _editable(self, path: str) -> str | None:
        full = os.path.realpath(path)
        roots = [os.path.realpath(os.path.dirname(EFX_DIR))]   # the repo
        if not any(full.startswith(r + os.sep) for r in roots):
            return None
        if not full.endswith(self.EDITABLE_SUFFIXES):
            return None
        return full

    def _file_get(self, path: str) -> None:
        full = self._editable(path)
        if full is None or not os.path.isfile(full):
            return self._error(403, "not an editable configuration file")
        with open(full, errors="replace") as fh:
            return self._json({"path": full, "content": fh.read()})

    def _file_put(self, body: dict) -> None:
        full = self._editable(str(body.get("path", "")))
        if full is None:
            return self._error(403, "not an editable configuration file")
        content = body.get("content")
        if not isinstance(content, str):
            return self._error(400, "expected a string 'content'")
        with open(full + ".tmp", "w") as fh:
            fh.write(content)
        os.replace(full + ".tmp", full)
        return self._json({"ok": True, "path": full})


def main() -> None:
    parser = argparse.ArgumentParser(description="efx web interface")
    parser.add_argument("--host", default="127.0.0.1",
                        help="bind address (default: loopback; this server runs shell commands)")
    parser.add_argument("--port", type=int, default=8760)
    parser.add_argument("--verbose", action="store_true", help="log every request")
    args = parser.parse_args()

    if args.host not in ("127.0.0.1", "localhost", "::1"):
        print("refusing to bind to a non-loopback address: this server executes build commands")
        raise SystemExit(2)

    os.makedirs(STATE_DIR, exist_ok=True)
    os.makedirs(LOG_DIR, exist_ok=True)

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.verbose = args.verbose        # type: ignore[attr-defined]
    httpd.daemon_threads = True

    print(f"efx gui  →  http://{args.host}:{args.port}")
    print(f"repo     {os.path.dirname(EFX_DIR)}")
    print("Ctrl-C to stop")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
