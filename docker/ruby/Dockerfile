FROM ruby:3.4.10-slim-bookworm AS base

RUN apt update && apt --fix-missing install -y build-essential pkg-config libpq-dev curl cmake libssl-dev libengine-gost-openssl file libvips42 libyaml-dev libpng-dev \
     && rm -rf /var/lib/apt/lists/*

# Build LERC from source (v4.0.0)
ARG LERC_SHA256=91431c2b16d0e3de6cbaea188603359f87caed08259a645fd5a3805784ee30a0
RUN curl -fsSL https://github.com/Esri/lerc/archive/refs/tags/v4.0.0.tar.gz -o lerc.tar.gz && \
    echo "${LERC_SHA256}  lerc.tar.gz" | sha256sum -c - && \
    tar -xz --strip-components=1 -C /tmp -f lerc.tar.gz && \
    cd /tmp && cmake . -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DCMAKE_INSTALL_PREFIX=/usr/local && \
    make -j$(nproc) && make install && \
    ldconfig && rm -rf /tmp/* lerc.tar.gz

RUN echo 'gem: --no-document' >> ~/.gemrc

WORKDIR /app

COPY Gemfile* /app/

RUN bundle install --jobs $(nproc) --retry=3 && \
    bundle clean --force && rm -rf /usr/local/bundle/cache/*

COPY . /app

RUN cd /app/ext && ruby extconf.rb && make && \
    ruby terrain_downsample_extconf.rb && make

RUN mkdir -p /etc/ssl/openssl.cnf.d && cp /app/gost.conf /etc/ssl/openssl.cnf.d/gost.conf

ENV RACK_ENV=production NODE_ENV=production OPENSSL_CONF=/etc/ssl/openssl.cnf.d/gost.conf
RUN rake -T | grep 'rake build' && rake build || echo 'no build task'

# used in .gitlab-ci.yml Tests.
FROM base AS tests
CMD bundle exec rspec

FROM ruby:3.4.10-slim-bookworm AS deploy
RUN apt update && apt install --fix-missing -y bash curl libssl-dev libengine-gost-openssl wget libpq-dev file libvips42 libyaml-0-2 libpng16-16 \
     && rm -rf /var/lib/apt/lists/*

ARG RESOLV_VERSION=0.7.2
RUN default_gem_dir="$(ruby -e 'print Gem.default_dir')" && \
    GEM_HOME="${default_gem_dir}" GEM_PATH="${default_gem_dir}" gem install resolv -v "${RESOLV_VERSION}" --default --no-document && \
    rm -f "${default_gem_dir}/specifications/default/resolv-0.7.1.gemspec" && \
    ruby -rresolv -e "abort 'resolv version is outdated' if Gem.loaded_specs.fetch('resolv').version < Gem::Version.new('${RESOLV_VERSION}')"

COPY --from=base /usr/local/bundle /usr/local/bundle
COPY --from=base /usr/local/lib/libLerc.so* /usr/local/lib/

COPY --from=base /app/ext/ /app/ext/

# Force start & wait test Stage
# COPY --from=tests /app/src/spec/results /app/src/spec/results

COPY --from=base /app /app

RUN mkdir -p /etc/ssl/openssl.cnf.d && cp /app/gost.conf /etc/ssl/openssl.cnf.d/gost.conf

ENV RUBY_YJIT_ENABLE=1 \
    SERVER_ENV=production \
    RACK_ENV=production \
    PORT=7000 \
    OPENSSL_CONF=/etc/ssl/openssl.cnf.d/gost.conf

WORKDIR /app

# --start_period=5s (Unknown flag: start_period)
#HEALTHCHECK --interval=15s --timeout=2s --retries=3 CMD curl --fail http://127.0.0.1:$PORT/healthcheck || exit 1
CMD bundle exec rackup -o 0.0.0.0 -p $PORT -s falcon
# docker-compose build --progress plain
