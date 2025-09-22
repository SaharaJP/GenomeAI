# --- stage: взять docker-cli ---
FROM docker:24 AS dockercli

# --- stage: runner ---
FROM python:3.11-slim

# системные утилиты + Java для Nextflow
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openjdk-21-jre-headless curl bash ca-certificates procps docker.io git \
 && rm -rf /var/lib/apt/lists/*

# docker-cli из предыдущего стейджа
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker

# Nextflow
RUN curl -fsSL https://get.nextflow.io | bash \
 && mv nextflow /usr/local/bin/nextflow \
 && chmod +x /usr/local/bin/nextflow

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# код раннера + пайплайны
COPY app.py .
COPY s3client.py .
COPY pipelines ./pipelines

ENV WORK_DIR=/work
EXPOSE 8000
CMD ["uvicorn","app:app","--host","0.0.0.0","--port","8000"]
