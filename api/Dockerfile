FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# deps
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# приложение
COPY main.py ./
COPY app ./app

# запуск
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8000"]
