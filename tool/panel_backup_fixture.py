"""Run the pinned FLS backend against disposable data for APP HTTP tests."""

import argparse
import contextlib
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import threading
import zipfile
from unittest.mock import patch


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    backend = args.backend.resolve(strict=True)
    actual = subprocess.check_output(
        ["git", "-C", str(backend), "rev-parse", "HEAD"], text=True,
    ).strip()
    if actual != args.revision:
        raise RuntimeError("FLS fixture revision does not match the pinned pair")
    subprocess.run(
        ["git", "-C", str(backend), "diff", "--exit-code", "HEAD", "--", "fls_manager", "tests"],
        check=True, stdout=subprocess.DEVNULL,
    )
    sys.path.insert(0, str(backend))
    sys.dont_write_bytecode = True
    from apscheduler.schedulers.base import STATE_PAUSED
    from flask import Flask, jsonify, request
    from werkzeug.middleware.dispatcher import DispatcherMiddleware
    from werkzeug.serving import WSGIRequestHandler, make_server
    from tests.test_bulk_workflows import isolated_app

    class QuietHandler(WSGIRequestHandler):
        def log(self, kind, message, *values):
            pass

    with contextlib.ExitStack() as stack:
        app, base = stack.enter_context(isolated_app())
        from fls_manager.paths import DATA_DIR, SCRIPT_DIR
        from fls_manager.routes.backup import _common as backup
        from fls_manager.state import scheduler

        # Keep real job registration without executing scheduled fixture work.
        scheduler.pause()

        # Package metadata is deterministic; this fixture never launches pip.
        stack.enter_context(patch.object(backup, "write_dependencies_file",
            side_effect=lambda path, cancel_event=None: Path(path).write_text(
                "# paired fixture metadata\n", encoding="utf-8")))

        members = {
            "fls/data/paired.txt": b"paired data\n",
            "fls/scripts/paired.py": b"# paired fixture only\n",
        }
        inputs = base / "pair-inputs"
        inputs.mkdir()
        tar_path = inputs / "full.tar.gz"
        with tarfile.open(tar_path, "w:gz") as archive:
            for name, content in members.items():
                info = tarfile.TarInfo(name)
                info.size = len(content)
                archive.addfile(info, io.BytesIO(content))
        zip_path = inputs / "full.zip"
        with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, content in members.items():
                archive.writestr(name, content)

        requests = []

        @app.after_request
        def observe(response):
            requests.append({"method": request.method, "path": request.path,
                             "status": response.status_code})
            return response

        control = Flask("pair_control")

        @control.get("/evidence")
        def evidence():
            records = {}
            for name in (".backup_native_preflights", ".backup_native_restores",
                         ".backup_native_delete_requests"):
                for path in sorted((base / name).glob("*.json")):
                    records[str(path.relative_to(base))] = hashlib.sha256(path.read_bytes()).hexdigest()
            return jsonify({
                "requests": requests,
                "records": records,
                "data_restored": (DATA_DIR / "paired.txt").read_bytes() == members["fls/data/paired.txt"]
                if (DATA_DIR / "paired.txt").exists() else False,
                "scripts_restored": (SCRIPT_DIR / "paired.py").read_bytes() == members["fls/scripts/paired.py"]
                if (SCRIPT_DIR / "paired.py").exists() else False,
                "scheduled_jobs": sorted(job.id for job in scheduler.get_jobs()),
                "scheduler_running": scheduler.running,
                "scheduler_paused": scheduler.state == STATE_PAUSED,
                "backups": {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                            for path in backup.BACKUP_DIR.glob("*.tar.gz")},
            })

        application = DispatcherMiddleware(control, {"/fls-pair": app})
        server = make_server("127.0.0.1", 0, application, request_handler=QuietHandler)
        worker = threading.Thread(target=server.serve_forever, name="fls-pair-http", daemon=True)
        worker.start()
        print(json.dumps({
            "pair_ready": True,
            "base_url": f"http://127.0.0.1:{server.server_port}/fls-pair",
            "evidence_url": f"http://127.0.0.1:{server.server_port}/evidence",
            "base_dir": str(base),
            "archives": [str(tar_path), str(zip_path)],
            "revision": actual,
        }), flush=True)
        try:
            sys.stdin.readline()
        finally:
            server.shutdown()
            server.server_close()
            worker.join(5)
            if worker.is_alive():
                raise RuntimeError("paired HTTP server did not stop")
            for background in threading.enumerate():
                if background.name.startswith(("backup-", "fls-backup-")):
                    background.join(10)
                    if background.is_alive():
                        raise RuntimeError("backup worker outlived fixture data")


if __name__ == "__main__":
    main()
