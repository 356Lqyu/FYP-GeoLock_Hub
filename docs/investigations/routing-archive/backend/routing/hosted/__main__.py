"""Render entry point. Defaults DISABLED; never uses Windows launchers."""
import argparse
from http.server import ThreadingHTTPServer
import json
import signal
import threading

from .config import Settings
from .runtime import Runtime
from ..worker_service.errors import WorkerError
from ..worker_service.server import make_handler

RECOVERY = frozenset(('/v1/authorization-result', '/v1/planning-result'))


def handler_for(runtime):
    base = make_handler(runtime.app, origins=runtime.settings.origins)
    class Handler(base):
        def do_GET(self):
            if self.path == '/live':
                self._send(200, {'status': 'ALIVE'})
            elif self.path == '/health':
                self._send(200 if runtime.ready and not runtime.closing else 503, runtime.health())
            else:
                self._send(404, {'error': {'code': 'NOT_FOUND'}})

        def _ingress(self):
            if not runtime.settings.trusted_https(self.client_address[0], self.headers):
                self._send(403, {'error': {'code': 'TRUSTED_HTTPS_PROXY_REQUIRED'}})
                return False
            if runtime.closing or (not runtime.ready and self.path not in RECOVERY):
                self._send(503, {'error': {'code': 'HOSTED_NOT_READY', 'retryable': True},
                                 'dispatch_authority_issued': False})
                return False
            return True

        def do_POST(self):
            if self._ingress():
                # Runtime installs the real dispatcher after startup. Preserve
                # every parser/auth/status/receipt branch in the original handler.
                make_handler(runtime.app, origins=runtime.settings.origins).do_POST(self)

        def do_OPTIONS(self):
            if self._ingress():
                super().do_OPTIONS()
    return Handler


class BoundedServer(ThreadingHTTPServer):
    daemon_threads = False
    block_on_close = True
    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(8)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                body = b'{"error":{"code":"HTTP_CAPACITY_RETRY_SAME_REQUEST","retryable":true}}'
                request.sendall(b'HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: ' +
                                str(len(body)).encode() + b'\r\n\r\n' + body)
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        request.settimeout(150)
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        # Base socketserver traceback output must not expose request diagnostics.
        print('{"event":"hosted_http_handler_failed"}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', required=True, choices=('planner', 'validator'))
    parser.add_argument('--check-config', action='store_true')
    args = parser.parse_args()
    try:
        settings = Settings.from_env(args.mode)
        if args.check_config:
            print(json.dumps(dict(mode=args.mode, active=settings.active, port=settings.port, connected=False)))
            return 0
        runtime = Runtime(settings)
        server = BoundedServer(('0.0.0.0', settings.port), handler_for(runtime))
        thread = threading.Thread(target=runtime.prepare, name='read-only-prewarm', daemon=True)
        thread.start()
        def drain(*_):
            runtime.closing = True
            runtime.ready = False
            runtime.reason = 'DRAINING'
            threading.Thread(target=server.shutdown, daemon=True).start()
        signal.signal(signal.SIGTERM, drain)
        signal.signal(signal.SIGINT, drain)
        try:
            server.serve_forever()
        finally:
            server.server_close()  # Drain accepted handlers before releasing lock.
            runtime.close()
        return 0
    except WorkerError as error:
        print(json.dumps({'status': 'DISABLED', 'error': error.code}))
        return 2
    except Exception:
        print(json.dumps({'status': 'DISABLED', 'error': 'HOSTED_CONFIGURATION_OR_BIND_FAILED'}))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
