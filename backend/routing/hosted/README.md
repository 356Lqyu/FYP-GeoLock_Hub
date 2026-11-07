# Hosted routing reference implementation — postponed

The owner selected the existing **Windows laptop** workflow on 7 November 2026. Render and other cloud hosting are postponed/not selected. This directory's tested source, Docker definitions and tests are retained for reference; do not deploy or activate them as part of laptop setup.

Use [the Windows setup/start/stop guide](../../../docs/LOCAL_ROUTING_WINDOWS.md). The existing local entrypoint is `backend.routing.worker_service.native_worker`, launched by `worker_service/windows/Start-Worker.ps1`. It does not import the hosted runtime or require Docker. The SQLite recovery journal remains selected; PostgreSQL journal replacement was design-only and is not implemented.

Historical measurements and limitations remain in `docs/investigations/ROUTING_RENDER_IMPLEMENTATION_READINESS.md` and the accompanying evidence folders. No tested sources or experiment evidence were removed.
