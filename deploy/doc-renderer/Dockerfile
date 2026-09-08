# Doc renderer as its own container — same script the root Dockerfile embeds
# in core (server/priv/python/doc_renderer.py), split out so weasyprint's
# native deps don't bloat the core image and a bad render can't take core down.
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      libpango-1.0-0 libpangocairo-1.0-0 libpangoft2-1.0-0 libharfbuzz0b \
      libcairo2 libgdk-pixbuf-2.0-0 fonts-noto-core fonts-noto-extra \
      fontconfig \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
      flask==3.1.* \
      waitress==3.0.* \
      weasyprint==63.* \
      openpyxl==3.1.* \
      pypdfium2==4.*

WORKDIR /app
COPY server/priv/python/doc_renderer.py ./doc_renderer.py

# The script binds 127.0.0.1 (fine when it shared core's netns); it needs the
# container's own interface to be reachable at doc-renderer:5050 from core.
RUN sed -i 's/host="127\.0\.0\.1"/host="0.0.0.0"/g' doc_renderer.py

RUN useradd --uid 1000 --create-home --shell /usr/sbin/nologin renderer \
    && chown -R renderer:renderer /app
USER renderer

EXPOSE 5050

CMD ["python3", "doc_renderer.py", "5050"]
