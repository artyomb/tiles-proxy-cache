FROM ruby:3.4.4-slim-bookworm AS base

RUN apt update && apt --fix-missing install -y build-essential pkg-config libpq-dev curl cmake libssl-dev libengine-gost-openssl file \
     && rm -rf /var/lib/apt/lists/*

RUN echo 'gem: --no-document' >> ~/.gemrc

WORKDIR /app

COPY Gemfile* /app/

RUN bundle install --jobs $(nproc) --retry=3 && \
    bundle clean --force && rm -rf /usr/local/bundle/cache/*

COPY . /app

RUN cd /app/ext && ruby extconf.rb

RUN mkdir -p /etc/ssl/openssl.cnf.d && cp /app/gost.conf /etc/ssl/openssl.cnf.d/gost.conf

ENV RACK_ENV=production NODE_ENV=production OPENSSL_CONF=/etc/ssl/openssl.cnf.d/gost.conf
RUN rake -T | grep 'rake build' && rake build || echo 'no build task'

# used in .gitlab-ci.yml Tests.
FROM base AS tests
RUN bundle exec rspec

FROM ruby:3.4.4-slim-bookworm AS deploy
RUN apt update && apt install --fix-missing -y bash curl libssl-dev libengine-gost-openssl bash curl wget libpq-dev file \
     && rm -rf /var/lib/apt/lists/*

COPY --from=base /usr/local/bundle /usr/local/bundle

COPY --from=base /app/ext/ /app/ext/

# Force start & wait test Stage
# COPY --from=tests /app/src/spec/results /app/src/spec/results

COPY . /app

RUN mkdir -p /etc/ssl/openssl.cnf.d && cp /app/gost.conf /etc/ssl/openssl.cnf.d/gost.conf

ENV RUBY_YJIT_ENABLE=1 \
    SERVER_ENV=production \
    RACK_ENV=production \
    PORT=7000 \
    OPENSSL_CONF=/etc/ssl/openssl.cnf.d/gost.conf

WORKDIR /app

# --start_period=5s (Unknown flag: start_period)
# HEALTHCHECK --interval=15s --timeout=2s --retries=3 CMD curl --fail http://127.0.0.1:$PORT/healthcheck || exit 1
CMD bundle exec rackup -o 0.0.0.0 -p $PORT -s falcon
# docker-compose build --progress plain