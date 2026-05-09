FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn httpx
COPY . .
USER 1001
ENTRYPOINT ["python", "backend.py"]
