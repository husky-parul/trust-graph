FROM python:3.12-slim
WORKDIR /app
COPY src/model_registry/server.py .
USER 1001
ENTRYPOINT ["python", "server.py"]
