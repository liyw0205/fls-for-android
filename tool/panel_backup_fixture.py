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
import time
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
        from fls_manager.routes.backup import native_api as native
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
        dependency_path = inputs / "dependencies.zip"
        with zipfile.ZipFile(dependency_path, "w") as archive:
            for name, content in members.items():
                archive.writestr(name, content)
            archive.writestr("fls/requirements.txt", b"# no external packages in fixture\n")

        unsafe_paths = []
        for suffix in ("tar.gz", "zip"):
            path = inputs / ("unsafe." + suffix)
            if suffix == "tar.gz":
                with tarfile.open(path, "w:gz") as archive:
                    info = tarfile.TarInfo("../../pair-escape.txt")
                    info.size = 6
                    archive.addfile(info, io.BytesIO(b"escape"))
            else:
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr("../../pair-escape.txt", b"escape")
            unsafe_paths.append(str(path))

        protected = [DATA_DIR / "pair-protected.txt", SCRIPT_DIR / "pair_protected.py"]
        for path in protected:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"unchanged by preflight\n")

        fault_lock = threading.Lock()
        faults = {}
        inspect_archive = native._inspect_preflight_archive

        def inspect_with_fault(archive_path, suffix, work_dir, cancel_event=None):
            inspected = inspect_archive(archive_path, suffix, work_dir, cancel_event)
            with fault_lock:
                fault = faults.get(archive_path.stem)
                if fault is not None:
                    fault["entered"] = True
                    mode = fault["mode"]
            if fault is None:
                return inspected
            if mode == "cancel":
                if not cancel_event.wait(15):
                    with fault_lock:
                        fault["timed_out"] = True
                    raise RuntimeError("fixture cancellation barrier timed out")
                return inspected
            raise native.PreflightStorageError("fixture exhausted staging storage")

        stack.enter_context(patch.object(native, "_inspect_preflight_archive", inspect_with_fault))

        dependency_runs = []
        if hasattr(native, "DependencyProcess"):
            real_process = native.DependencyProcess
            real_cleanup = native._cleanup_dependency_resources

            def failed_dependency_command(command, **options):
                if command[:4] != [sys.executable, "-m", "pip", "install"]:
                    raise AssertionError("unexpected dependency command")
                process = real_process([
                    sys.executable, "-c",
                    "import sys; print('paired dependency failure', flush=True); sys.exit(1)",
                ], **options)
                with fault_lock:
                    dependency_runs.append({"process": process, "workspace": options["workspace"],
                                            "cleanup_attempts": 0, "reader": None})
                return process

            def fail_first_dependency_cleanup(entry):
                with fault_lock:
                    run = next((value for value in dependency_runs
                                if value["process"] is entry.get("process")), None)
                    if run is not None:
                        run["cleanup_attempts"] += 1
                        run["reader"] = entry.get("reader")
                        first = run["cleanup_attempts"] == 1
                    else:
                        first = False
                if first:
                    raise PermissionError("fixture dependency cleanup temporarily unavailable")
                return real_cleanup(entry)

            stack.enter_context(patch.object(native, "DependencyProcess", failed_dependency_command))
            stack.enter_context(patch.object(native, "_cleanup_dependency_resources", fail_first_dependency_cleanup))

        requests = []

        @app.after_request
        def observe(response):
            requests.append({"method": request.method, "path": request.path,
                             "status": response.status_code})
            return response

        control = Flask("pair_control")

        @control.post("/age-preflight")
        def age_preflight():
            payload = request.get_json(silent=True)
            if (not isinstance(payload, dict) or set(payload) != {"request_id", "terminal"}
                or not isinstance(payload["request_id"], str)
                or not native.PREFLIGHT_ID_RE.fullmatch(payload["request_id"])
                or type(payload["terminal"]) is not bool):
                return jsonify({"ok": False}), 400
            with native.PREFLIGHT_LOCK:
                request_id = payload["request_id"]
                record = native._read_preflight_record(request_id)
                if record is None or request_id in native.PREFLIGHT_ACTIVE:
                    return jsonify({"ok": False}), 409
                if payload["terminal"]:
                    if record["state"] not in ("expired", "cancelled", "failed"):
                        return jsonify({"ok": False}), 409
                    record["retention_until"] = int(time.time()) - 1
                else:
                    if record["state"] != "ready":
                        return jsonify({"ok": False}), 409
                    record["expires_at"] = int(time.time()) - 1
                native._write_preflight_record(request_id, record)
            return jsonify({"ok": True})

        @control.post("/preflight-fault")
        def arm_preflight_fault():
            payload = request.get_json(silent=True)
            if (not isinstance(payload, dict) or set(payload) != {"request_id", "mode"}
                or not isinstance(payload["request_id"], str)
                or not native.PREFLIGHT_ID_RE.fullmatch(payload["request_id"])
                or payload["mode"] not in ("cancel", "storage")):
                return jsonify({"ok": False}), 400
            with native.PREFLIGHT_LOCK, fault_lock:
                request_id = payload["request_id"]
                if request_id in faults or native._preflight_record_path(request_id).exists():
                    return jsonify({"ok": False}), 409
                faults[request_id] = {"mode": payload["mode"], "entered": False, "timed_out": False}
            return jsonify({"ok": True})

        @control.get("/evidence")
        def evidence():
            records = {}
            with native.PREFLIGHT_LOCK:
                for name in (".backup_native_preflights", ".backup_native_restores",
                             ".backup_native_delete_requests"):
                    for path in sorted((base / name).glob("*.json")):
                        records[str(path.relative_to(base))] = hashlib.sha256(path.read_bytes()).hexdigest()
                active = sorted(native.PREFLIGHT_ACTIVE)
                cancel_events = sorted(native.PREFLIGHT_CANCEL_EVENTS)
                staged = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in native.PREFLIGHT_ARCHIVE_DIR.glob("*.archive")}
            with fault_lock:
                fault_evidence = {key: dict(value) for key, value in faults.items()}
                runs = [{"cleanup_attempts": value["cleanup_attempts"],
                         "process_stopped": value["process"]._stopped,
                         "stdout_closed": value["process"].stdout.closed,
                         "reader_alive": value["reader"].is_alive() if value["reader"] else None,
                         "workspace_exists": value["workspace"].exists()}
                        for value in dependency_runs]
            dependency_states = []
            lease_held = False
            if hasattr(native, "dependency_evidence"):
                dependency_states = [native.dependency_evidence.read(base, root, operation)["state"]
                                     for root, operation in native.dependency_evidence.ids(base)]
                lease_held = native._process_lease_held(native.RESTORE_PROCESS_LOCK_PATH, shared=True)
            return jsonify({
                "requests": requests,
                "records": records,
                "preflight_active": active,
                "preflight_cancel_events": cancel_events,
                "preflight_faults": fault_evidence,
                "dependency_runs": runs,
                "dependency_evidence_states": dependency_states,
                "restore_lease_held": lease_held,
                "staged_archives": staged,
                "preflight_workspaces": sorted(path.name for path in native.PREFLIGHT_WORK_DIR.glob("*")),
                "preflight_work_files": sorted(str(path.relative_to(native.PREFLIGHT_WORK_DIR))
                                               for path in native.PREFLIGHT_WORK_DIR.rglob("*") if path.is_file()),
                "protected_files": {str(path.relative_to(base)): hashlib.sha256(path.read_bytes()).hexdigest()
                                    if path.is_file() else None for path in protected},
                "escaped_files": sorted(str(path.relative_to(base)) for path in base.rglob("pair-escape.txt")),
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
            "fault_url": f"http://127.0.0.1:{server.server_port}/preflight-fault",
            "age_url": f"http://127.0.0.1:{server.server_port}/age-preflight",
            "base_dir": str(base),
            "archives": [str(tar_path), str(zip_path)],
            "unsafe_archives": unsafe_paths,
            "dependency_archive": str(dependency_path),
            "revision": actual,
        }), flush=True)
        try:
            sys.stdin.readline()
        finally:
            with native.PREFLIGHT_LOCK:
                for cancel_event in native.PREFLIGHT_CANCEL_EVENTS.values():
                    cancel_event.set()
            server.shutdown()
            server.server_close()
            worker.join(5)
            if worker.is_alive():
                raise RuntimeError("paired HTTP server did not stop")
            if hasattr(native, "RESTORE_DEPENDENCY_CLEANUP"):
                with native.RESTORE_LOCK:
                    pending = list(native.RESTORE_DEPENDENCY_CLEANUP.items())
                for request_id, entry in pending:
                    native._complete_dependency_cleanup(request_id, entry)
            for background in threading.enumerate():
                if background.name.startswith(("backup-", "fls-backup-")):
                    background.join(10)
                    if background.is_alive():
                        raise RuntimeError("backup worker outlived fixture data")


if __name__ == "__main__":
    main()
