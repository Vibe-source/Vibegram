# Vibe core — VPS variant of the root Dockerfile: same build, minus the Python
# doc-renderer (its own container now, see deploy/doc-renderer/Dockerfile).
# Root Dockerfile/start.sh are untouched; Railway still builds from those.
# Build context is the repo root (..) — needs client/, contracts/, server/.

FROM node:20-alpine AS client-build

WORKDIR /app/client

COPY client/package.json client/package-lock.json ./
RUN npm ci

COPY client/ ./
RUN npm run build

FROM hexpm/elixir:1.15.7-erlang-26.2.1-alpine-3.18.4 AS elixir-build

RUN apk add --no-cache build-base git

WORKDIR /app

RUN for i in 1 2 3 4 5; do \
  mix local.hex --force && mix local.rebar --force && break || sleep 5; \
  done

ENV MIX_ENV="prod"

COPY contracts/ /contracts/
COPY server/mix.exs ./
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

COPY server/config/ config/

COPY server/lib/ lib/
COPY server/priv/ priv/
COPY --from=client-build /app/client/dist/ priv/static/

RUN mix compile

COPY server/config/runtime.exs config/

RUN mix release

FROM alpine:3.18

# yt-dlp + ffmpeg for music extraction (SoundCloud/YouTube) — the doc-renderer's
# pango/cairo/weasyprint deps are gone: that renderer now runs in its own container.
RUN apk add --no-cache libstdc++ openssl ncurses-libs python3 py3-pip ffmpeg curl \
  && pip3 install --break-system-packages "yt-dlp>=2024.1.0" \
  && YT_BIN=$(command -v yt-dlp || true) \
  && if [ -z "$YT_BIN" ]; then YT_BIN=$(python3 -c "import shutil; print(shutil.which('yt-dlp') or '')"); fi \
  && if [ -n "$YT_BIN" ]; then ln -sf "$YT_BIN" /usr/local/bin/yt-dlp; fi \
  && ln -sf /usr/bin/python3 /usr/local/bin/python3 \
  && /usr/local/bin/yt-dlp --version \
  && python3 -m yt_dlp --version

# bash and ripgrep are not optional: the CLI's own tools shell out to them.
RUN apk add --no-cache nodejs npm git bash ripgrep \
  && npm install -g --no-fund --no-audit @anthropic-ai/claude-code \
  && (npm install -g --no-fund --no-audit @openai/codex || echo "codex: no musl build, skipped") \
  && claude --version

WORKDIR /app
RUN chown nobody /app && mkdir -p /tmp/.cache && chown nobody /tmp/.cache \
  && mkdir -p /home/agent && chown nobody /home/agent

ENV MIX_ENV="prod"
ENV XDG_CACHE_HOME=/tmp/.cache
ENV PATH="/usr/local/bin:/usr/bin:/bin:${PATH}"
ENV YTDLP_PATH="/usr/local/bin/yt-dlp"
ENV HOME=/home/agent

COPY --from=elixir-build --chown=nobody:root /app/_build/prod/rel/vibe ./
COPY --chmod=755 deploy/core/start.sh /app/start.sh

USER nobody

EXPOSE 4000

CMD ["/app/start.sh"]
