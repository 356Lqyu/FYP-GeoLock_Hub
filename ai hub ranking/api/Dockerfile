# Hub-ranking API image. Build from the repository root:
#   docker build -f "ai hub ranking/api/Dockerfile" -t geolock-hub-ranking .
FROM python:3.12-slim

WORKDIR /app/ai_hub_ranking
COPY ["ai hub ranking/requirements.txt", "./requirements.txt"]
COPY ["ai hub ranking/api/requirements.txt", "./api/requirements.txt"]
RUN pip install --no-cache-dir -r api/requirements.txt

COPY ["ai hub ranking/hub_ranking_core.py", "./"]
COPY ["ai hub ranking/model", "./model"]
COPY ["ai hub ranking/api/main.py", "./api/"]

WORKDIR /app/ai_hub_ranking/api
ENV SUPABASE_URL=https://rcgyuwiidqvrgbxswhqj.supabase.co \
    SUPABASE_PUBLISHABLE_KEY=sb_publishable_6nGhMdwaC79KbE-JiX4yPA_f3jFNbvd \
    PORT=8000
# Hosts like Render, Cloud Run and Hugging Face set PORT themselves.
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT}"]
