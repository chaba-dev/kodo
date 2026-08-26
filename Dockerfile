ARG ELIXIR_IMAGE=elixir:1.20.3-otp-28-slim@sha256:ccf68930224b73871498a55702b6de16b182fac376098ec131b39289feeeb2a8
ARG RUNTIME_IMAGE=debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132

FROM ${ELIXIR_IMAGE} AS builder

RUN apt-get update \
    && apt-get install --yes --no-install-recommends build-essential ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config

RUN mix deps.get --only prod && mix deps.compile

COPY assets assets
COPY lib lib
COPY priv priv
COPY rel rel

RUN mix compile \
    && mix assets.deploy \
    && mix release

FROM ${RUNTIME_IMAGE} AS runtime

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      ca-certificates \
      libncurses6 \
      libstdc++6 \
      locales \
      openssl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1000 kodo \
    && useradd --uid 1000 --gid kodo --create-home --shell /usr/sbin/nologin kodo

ENV LANG=C.UTF-8 \
    PHX_SERVER=true

WORKDIR /app

COPY --from=builder --chown=kodo:kodo /app/_build/prod/rel/kodo ./

USER kodo

CMD ["/app/bin/kodo", "start"]
