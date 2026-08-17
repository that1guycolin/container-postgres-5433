FROM debian:stable-slim

RUN groupadd -r postgres --gid=999 \
    && useradd -r -g postgres --uid=999 \
    --home-dir=/var/lib/postgresql --shell=/bin/bash postgres \
    && install --verbose --directory --owner postgres --group postgres \
    --mode 1777 /var/lib/postgresql

# hadolint ignore=DL3009
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    ca-certificates=20250419 gnupg=2.4.7-21+deb13u1 less=668-1 \
    libnss-wrapper=1.1.16-1 locales=2.41-12+deb13u3 wget2=2.2.0+ds-1+deb13u1 \
    xz-utils=5.8.1-1+deb13u1 zstd=1.5.7+dfsg-1

ENV GOSU_VERSION 1.19
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
RUN dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')" \
    && wget2 -O /usr/local/bin/gosu \
    "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch" \
    && wget2 -O /usr/local/bin/gosu.asc \
    "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc" \
    && GNUPGHOME="$(mktemp -d)" \
    && export GNUPGHOME \
    && gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys \
    B42F6819007F00F88E364FD4036A9C25BF357DD4 \
    && gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu \
    && mkdir -p /usr/local/share/keyrings/ \
    && gpg --batch --keyserver keyserver.ubuntu.com --recv-keys \
    B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8 \
    && gpg --batch --export --armor B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8 > \
    /usr/local/share/keyrings/postgres.gpg.asc \
    && gpgconf --kill all \
    && rm -rf "$GNUPGHOME" \
    &&	rm -rf /usr/local/bin/gosu.asc

RUN chmod +x /usr/local/bin/gosu \
    && gosu --version \
    && gosu nobody true

# hadolint ignore=DL3009
RUN grep -q '/usr/share/locale' /etc/dpkg/dpkg.cfg.d/docker \
    && sed -ri '/\/usr\/share\/locale/d' /etc/dpkg/dpkg.cfg.d/docker \
    && ! grep -q '/usr/share/locale' /etc/dpkg/dpkg.cfg.d/docker \
    && echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen \
    && locale-gen \
    && locale -a | grep 'en_US.utf8'
ENV LANG en_US.utf8

RUN mkdir /container-entrypoint-initdb.d
    
ENV PG_MAJOR 18
ENV PATH $PATH:/usr/lib/postgresql/$PG_MAJOR/bin
ENV PG_VERSION 18.6-1.pgdg13+2
ENV PYTHONDONTWRITEBYTECODE 1

RUN aptRepo="[ signed-by=/usr/local/share/keyrings/postgres.gpg.asc ] \
    http://apt.postgresql.org/pub/repos/apt trixie-pgdg main $PG_MAJOR" \
    && echo "deb $aptRepo" > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-common=293.pgdg13+1 \
    && sed -ri 's/#(create_main_cluster) .*$/\1 = false/' \
    /etc/postgresql-common/createcluster.conf \
    && apt-get install -y --no-install-recommends \
    "postgresql-$PG_MAJOR=$PG_VERSION" "postgresql-$PG_MAJOR-jit=$PG_VERSION" \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get purge -y --auto-remove \
    && rm -rf /etc/apt/sources.list.d/temp.list \
    && find /usr -name '*.pyc' -type f -exec bash -c \
    'for pyc; do dpkg -S "$pyc" &> /dev/null || rm -vf "$pyc"; done' -- '{}' + \
    && postgres --version

RUN dpkg-divert --add --rename --divert "/usr/share/postgresql/postgresql.conf.sample.dpkg" \
    "/usr/share/postgresql/$PG_MAJOR/postgresql.conf.sample" \
    && cp -v /usr/share/postgresql/postgresql.conf.sample.dpkg \
    /usr/share/postgresql/postgresql.conf.sample \
    && ln -sv ../postgresql.conf.sample "/usr/share/postgresql/$PG_MAJOR/" \
    && sed -ri "s!^#?(listen_addresses)\s*=\s*\S+.*!\1 = '*'!" \
    /usr/share/postgresql/postgresql.conf.sample \
    && grep -F "listen_addresses = '*'" /usr/share/postgresql/postgresql.conf.sample

RUN install --verbose --directory --owner postgres --group postgres --mode 3777 /var/run/postgresql

ENV PGDATA /var/lib/postgresql/18/docker
VOLUME /var/lib/postgresql

COPY container-entrypoint.sh ensure-initdb.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/container-entrypoint.sh \
    && chmod +x /usr/local/bin/ensure-initdb.sh
RUN ln -sT ensure-initdb.sh /usr/local/bin/enforce-initdb.sh
ENTRYPOINT ["/usr/local/bin/container-entrypoint.sh"]

STOPSIGNAL SIGINT

EXPOSE 5433
CMD ["postgres"]

LABEL org.opencontainers.image.source=https://github.com/that1guycolin/container-postgres-5433
LABEL org.opencontainers.image.description="Custom version of postgresSQL that runs on port 5433 \
instead of 5432"
LABEL org.opencontainers.image.licenses=MIT
