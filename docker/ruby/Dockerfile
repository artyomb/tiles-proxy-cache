FROM ruby:3.4.4-slim-bookworm AS base

RUN apt update && apt --fix-missing install -y build-essential pkg-config libpq-dev curl cmake libssl-dev libengine-gost-openssl file \
     && rm -rf /var/lib/apt/lists/*

# Build LERC from source (v4.0.0)
ARG LERC_SHA256=91431c2b16d0e3de6cbaea188603359f87caed08259a645fd5a3805784ee30a0
RUN curl -fsSL https://github.com/Esri/lerc/archive/refs/tags/v4.0.0.tar.gz -o lerc.tar.gz && \
    echo "${LERC_SHA256}  lerc.tar.gz" | sha256sum -c - && \
    tar -xz --strip-components=1 -C /tmp -f lerc.tar.gz && \
    cd /tmp && cmake . -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DCMAKE_INSTALL_PREFIX=/usr/local && \
    make -j$(nproc) && make install && \
    ldconfig && rm -rf /tmp lerc.tar.gz

RUN echo 'gem: --no-document' >> ~/.gemrc

WORKDIR /app

COPY Gemfile* /app/

RUN bundle install --jobs $(nproc) --retry=3 && \
    bundle clean --force && rm -rf /usr/local/bundle/cache/*

COPY . /app

RUN cd /app/ext && ruby extconf.rb && make

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
COPY --from=base /usr/local/lib/libLerc.so* /usr/local/lib/
COPY --from=base /usr/local/include/lerc* /usr/local/include/

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