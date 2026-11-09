FROM python:3.12-alpine
WORKDIR /app
COPY retromail_push.py /app/
ENV RETROMAIL_PUSH_CONFIG=/data/config.json \
    RETROMAIL_PUSH_STATE=/data/state.json \
    PYTHONUNBUFFERED=1
VOLUME ["/data"]
CMD ["python3", "/app/retromail_push.py"]
