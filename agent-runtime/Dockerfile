# Multi-stage build for vibe-agent-runtime (Elixir). Build context is the repo root
# (contracts/ is a sibling path dependency) — see docs/vps-deployment.md.

FROM hexpm/elixir:1.15.7-erlang-26.2.1-alpine-3.18.4 AS build

RUN apk add --no-cache build-base git

WORKDIR /app
RUN for i in 1 2 3 4 5; do \
  mix local.hex --force && mix local.rebar --force && break || sleep 5; \
  done

ENV MIX_ENV="prod"

COPY contracts/ /contracts/
COPY agent-runtime/mix.exs ./
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

COPY agent-runtime/config/ config/
COPY agent-runtime/lib/ lib/
COPY agent-runtime/priv/ priv/
RUN mix compile

COPY agent-runtime/config/runtime.exs config/
RUN mix release

FROM alpine:3.18

RUN apk add --no-cache libstdc++ openssl ncurses-libs curl

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV="prod"

COPY --from=build --chown=nobody:root /app/_build/prod/rel/vibe_agents ./
COPY --chmod=755 agent-runtime/start.sh /app/start.sh

USER nobody

EXPOSE 4100

CMD ["/app/start.sh"]
