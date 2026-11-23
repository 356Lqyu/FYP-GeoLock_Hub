"""Run the donation reader migration and assertions on disposable PostgreSQL."""

import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "supabase/migrations/20261123210000_donation_information_readers.sql"
FIXTURE = Path(__file__).with_suffix(".sql")


def postgres_binary(name):
    path = shutil.which(name)
    if path:
        return path
    installed = Path(r"C:\Program Files\PostgreSQL\17\bin") / (name + ".exe")
    if installed.is_file():
        return str(installed)
    raise SystemExit(f"NOT RUN: PostgreSQL executable {name} is unavailable.")


def main():
    initdb, pg_ctl, psql = map(postgres_binary, ("initdb", "pg_ctl", "psql"))
    env = {key: value for key, value in os.environ.items() if not key.upper().startswith("PG")}
    with tempfile.TemporaryDirectory(prefix="geolock-donation-readers-") as scratch:
        scratch = Path(scratch)
        data = scratch / "data"
        password = scratch / "password"
        password.write_text(secrets.token_hex(24))
        env["PGPASSWORD"] = password.read_text()
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        log = scratch / "postgres.log"

        def run(*args):
            subprocess.run(args, cwd=scratch, env=env, check=True, timeout=75)

        run(initdb, "-D", str(data), "-U", "postgres", "-A", "scram-sha-256",
            "--encoding=UTF8", "--no-locale", "--pwfile", str(password))
        password.unlink()
        try:
            run(pg_ctl, "-D", str(data), "-l", str(log), "-w", "-t", "25",
                "-o", f"-h 127.0.0.1 -p {port}", "start")
            run(psql, "-X", "-w", "-h", "127.0.0.1", "-p", str(port),
                "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1",
                "-v", "migration=" + MIGRATION.as_posix(), "-f", str(FIXTURE))
        finally:
            status = subprocess.run([pg_ctl, "-D", str(data), "status"],
                                    cwd=scratch, env=env, timeout=15)
            if status.returncode == 0:
                run(pg_ctl, "-D", str(data), "-m", "fast", "-w", "stop")


if __name__ == "__main__":
    main()
