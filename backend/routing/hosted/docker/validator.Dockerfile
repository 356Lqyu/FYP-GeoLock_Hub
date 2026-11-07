FROM python:3.12-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
# Same pinned validation/solver types, but no graph/planner credentials at runtime.
COPY backend/routing/phase_b/requirements-lock.txt backend/routing/phase_b/requirements-lock.txt
COPY backend/routing/worker_service/requirements.txt backend/routing/worker_service/requirements.txt
RUN pip install --no-cache-dir -r backend/routing/worker_service/requirements.txt && pip check
COPY backend/__init__.py backend/__init__.py
COPY backend/routing/ backend/routing/
RUN groupadd --gid 10001 routing && useradd --uid 10001 --gid routing --no-create-home routing
USER 10001:10001
EXPOSE 10000
CMD ["python", "-m", "backend.routing.hosted", "--mode", "validator"]
