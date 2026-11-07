class WorkerError(Exception):
    def __init__(self, code, status=409, retryable=False):
        self.code, self.status, self.retryable = code, status, retryable
        super().__init__(code)


def check(condition, code, status=409):
    if not condition:
        raise WorkerError(code, status)
