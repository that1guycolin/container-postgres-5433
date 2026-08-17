#!/usr/bin/env bash
set -Eeo pipefail

function file_env {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
        printf >&2 'ERROR: both %s and %s are set (but are exclusive)\n' \
            "$var" "$fileVar"
        exit 1
    fi
    local val="$def"
    if [ "${!var:-}" ]; then
        val="${!var}"
    elif [ "${!fileVar:-}" ]; then
        val="$(<"${!fileVar}")"
    fi
    export "$var"="$val"
    unset "$fileVar"
}

# check to see if this file is being run or sourced from another script
function _is_sourced {
    [ "${#FUNCNAME[@]}" -ge 2 ] &&
        [ "${FUNCNAME[0]}" = '_is_sourced' ] &&
        [ "${FUNCNAME[1]}" = 'source' ]
}

function container_create_db_directories {
    local user
    user="$(id -u)"

    mkdir -p "$PGDATA"
    chmod 00700 "$PGDATA" || true
    mkdir -p /var/run/postgresql || true
    chmod 03775 /var/run/postgresql || true

    if [ -n "${POSTGRES_INITDB_WALDIR:-}" ]; then
        mkdir -p "$POSTGRES_INITDB_WALDIR"
        if [ "$user" = '0' ]; then
            find "$POSTGRES_INITDB_WALDIR" \
                \! -user postgres -exec chown postgres '{}' +
        fi
        chmod 700 "$POSTGRES_INITDB_WALDIR"
    fi

    if [ "$user" = '0' ]; then
        find "$PGDATA" \! -user postgres -exec chown postgres '{}' +
        find /var/run/postgresql \! -user postgres -exec chown postgres '{}' +
    fi
}

function container_init_database_dir {
    local uid
    uid="$(id -u)"
    if ! getent passwd "$uid" &>/dev/null; then
        local wrapper
        for wrapper in {/usr,}/lib{/*,}/libnss_wrapper.so; do
            if [ -s "$wrapper" ]; then
                NSS_WRAPPER_PASSWD="$(mktemp)"
                NSS_WRAPPER_GROUP="$(mktemp)"
                LD_PRELOAD="$wrapper"
                export NSS_WRAPPER_PASSWD
                export NSS_WRAPPER_GROUP
                export LD_PRELOAD
                local gid
                gid="$(id -g)"
                printf 'postgres:x:%s:%s:PostgreSQL:%s:/bin/false\n' \
                    "$uid" "$gid" "$PGDATA" >"$NSS_WRAPPER_PASSWD"
                printf 'postgres:x:%s:\n' "$gid" >"$NSS_WRAPPER_GROUP"
                break
            fi
        done
    fi

    if [ -n "${POSTGRES_INITDB_WALDIR:-}" ]; then
        set -- --waldir "$POSTGRES_INITDB_WALDIR" "$@"
    fi

    eval 'initdb --username="$POSTGRES_USER" --pwfile=<(printf "%s\n" "$POSTGRES_PASSWORD") '"$POSTGRES_INITDB_ARGS"' "$@"'

    if [[ "${LD_PRELOAD:-}" == */libnss_wrapper.so ]]; then
        rm -f "$NSS_WRAPPER_PASSWD" "$NSS_WRAPPER_GROUP"
        unset LD_PRELOAD NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP
    fi
}

function container_verify_minimum_env {
    if [ -z "$POSTGRES_PASSWORD" ] &&
        [ 'trust' != "$POSTGRES_HOST_AUTH_METHOD" ]; then
        cat >&2 <<EOE
Error: Database is uninitialized and superuser password is not specified. You
must specify POSTGRES_PASSWORD to a non-empty value for the superuser. For
example, "-e POSTGRES_PASSWORD=password" on "docker run".

You may also use "POSTGRES_HOST_AUTH_METHOD=trust" to allow all connections without a password. This is *not* recommended.

See PostgreSQL documentation about "trust":
    https://www.postgresql.org/docs/current/auth-trust.html
EOE
        exit 1
    fi
    if [ 'trust' = "$POSTGRES_HOST_AUTH_METHOD" ]; then
        cat >&2 <<EOWARN
********************************************************************************
WARNING: POSTGRES_HOST_AUTH_METHOD has been set to "trust". This will allow
anyone with access to the Postgres port to access your database without a
password, even if POSTGRES_PASSWORD is set. See PostgreSQL documentation about
"trust": https://www.postgresql.org/docs/current/auth-trust.html

In Docker's default configuration, this is effectively any other container on
the same system.

It is not recommended to use POSTGRES_HOST_AUTH_METHOD=trust. Replace it with
"-e POSTGRES_PASSWORD=password" instead to set a password in "docker run".
********************************************************************************
EOWARN
    fi
}

function container_error_old_databases {
    if [ -n "${OLD_DATABASES[0]:-}" ]; then
        cat >&2 <<EOE
Error: in 18+, these Docker images are configured to store database data in a
format which is compatible with "pg_ctlcluster" (specifically, using
major-version-specific directory names).  This better reflects how PostgreSQL
itself works, and how upgrades are to be performed.

See also https://github.com/docker-library/postgres/pull/1259

Counter to that, there appears to be PostgreSQL data in: OLD_DATABASES[*]} This
is usually the result of upgrading the Docker image without upgrading the
underlying database using "pg_upgrade" (which requires both versions).

The suggested container configuration for 18+ is to place a single mount at
/var/lib/postgresql which will then place PostgreSQL data in a subdirectory,
allowing usage of "pg_upgrade --link" without mount point boundary issues.

See https://github.com/docker-library/postgres/issues/37 for a (long) discussion
around this process, and suggestions for how to do so.
EOE
        exit 1
    fi
}

function container_process_init_files {
    printf '\n'
    local f
    for f; do
        case "$f" in
            *.sh)
                if [ -x "$f" ]; then
                    printf '%s: running %s\n' "$0" "$f"
                    "$f"
                else
                    printf '%s: sourcing %s\n' "$0" "$f"
                    # shellcheck disable=SC1090
                    . "$f"
                fi
                ;;
            *.sql)
                printf '%s: running %s\n' "$0" "$f"
                container_process_sql -f "$f"
                printf '\n'
                ;;
            *.sql.gz)
                printf '%s: running %s\n' "$0" "$f"
                gunzip -c "$f" | container_process_sql
                printf '\n'
                ;;
            *.sql.xz)
                printf '%s: running %s\n' "$0" "$f"
                xzcat "$f" | container_process_sql
                printf '\n'
                ;;
            *.sql.zst)
                printf '%s: running %s\n' "$0" "$f"
                zstd -dc "$f" | container_process_sql
                printf '\n'
                ;;
            *) printf '%s: ignoring %s\n' "$0" "$f" ;;
        esac
        printf '\n'
    done
}

function container_process_sql {
    local query_runner=(
        psql -v ON_ERROR_STOP=1 -p 5433
        --username "$POSTGRES_USER"
        --no-password --no-psqlrc
    )
    if [ -n "$POSTGRES_DB" ]; then
        query_runner+=(--dbname "$POSTGRES_DB")
    fi

    "${query_runner[@]}" "$@"
}

function container_setup_db {
    local dbAlreadyExists
    dbAlreadyExists="$(
        container_process_sql --dbname postgres \
            --set db="$POSTGRES_DB" --tuples-only <<EOSQL
SELECT 1 FROM pg_database WHERE datname = :'db' ;
EOSQL
    )"

    if [ -z "$dbAlreadyExists" ]; then
        container_process_sql --dbname postgres --set \
            db="$POSTGRES_DB" <<EOSQL
CREATE DATABASE :"db" ;
EOSQL
        printf '\n'
    fi
}

function container_setup_env {
    file_env 'POSTGRES_PASSWORD'

    file_env 'POSTGRES_USER' 'postgres'
    file_env 'POSTGRES_DB' "$POSTGRES_USER"
    file_env 'POSTGRES_INITDB_ARGS'
    : "${POSTGRES_HOST_AUTH_METHOD:=}"

    declare -g DATABASE_ALREADY_EXISTS
    : "${DATABASE_ALREADY_EXISTS:=}"
    declare -ag OLD_DATABASES=()
    if [ -s "$PGDATA/PG_VERSION" ]; then
        DATABASE_ALREADY_EXISTS='true'
    elif [ "$PGDATA" = "/var/lib/postgresql/$PG_MAJOR/docker" ]; then
        for d in /var/lib/postgresql /var/lib/postgresql/data \
            /var/lib/postgresql/*/docker; do
            if [ -s "$d/PG_VERSION" ]; then
                OLD_DATABASES+=("$d")
            fi
        done
        if [ "${#OLD_DATABASES[@]}" -eq 0 ] && [ "$PG_MAJOR" -ge 18 ] && {
            mountpoint -q /var/lib/postgresql/data ||
                awk '$5 == "/var/lib/postgresql/data" { found = 1 } END \
{ exit !found }' /proc/self/mountinfo
        }; then
            OLD_DATABASES+=('/var/lib/postgresql/data (unused mount/volume)')
        fi
    fi
}

function pg_setup_hba_conf {
    if [ "$1" = 'postgres' ]; then
        shift
    fi
    local auth
    auth="$(postgres -C password_encryption "$@")"
    : "${POSTGRES_HOST_AUTH_METHOD:=$auth}"
    {
        printf '\n'
        if [ 'trust' = "$POSTGRES_HOST_AUTH_METHOD" ]; then
            printf '# warning trust is enabled for all connections\n'
            printf '# see https://www.postgresql.org/docs/17/auth-trust.html\n'
        fi
        printf 'host all all all %s\n' "$POSTGRES_HOST_AUTH_METHOD"
    } >>"$PGDATA/pg_hba.conf"
}

function container_temp_server_start {
    if [ "$1" = 'postgres' ]; then
        shift
    fi

    set -- "$@" -c listen_addresses='' -p 5433

    NOTIFY_SOCKET='' \
        PGUSER="${PGUSER:-$POSTGRES_USER}" \
        pg_ctl -D "$PGDATA" \
        -o "$(printf '%q ' "$@")" \
        -w start
}

function container_temp_server_stop {
    PGUSER="${PGUSER:-postgres}" \
        pg_ctl -D "$PGDATA" -m fast -w stop
}

function _pg_want_help {
    local arg
    for arg; do
        case "$arg" in
            -'?' | --help | --describe-config | -V | --version)
                return 0
                ;;
        esac
    done
    return 1
}

function _main {
    if [ "${1:0:1}" = '-' ]; then
        set -- postgres "$@"
    fi

    if [ "$1" = 'postgres' ] && ! _pg_want_help "$@"; then
        container_setup_env
        if [ "$(id -u)" = '0' ]; then
            exec gosu postgres "${BASH_SOURCE[@]}" "$@"
        fi

        if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
            container_verify_minimum_env
            container_error_old_databases

            ls /container-entrypoint-initdb.d/ >/dev/null

            container_init_database_dir
            pg_setup_hba_conf "$@"

            export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"
            container_temp_server_start "$@"

            container_setup_db
            container_process_init_files /container-entrypoint-initdb.d/*

            container_temp_server_stop
            unset PGPASSWORD

            cat <<EOM
PostgreSQL init process complete; ready for start up.
EOM
        else
            cat <<EOM
PostgreSQL Database directory appears to contain a database; Skipping
initialization
EOM
        fi

        unset "${!POSTGRES_@}"
    fi

    if [ "$1" = 'postgres' ] && ! _pg_want_help "$@"; then
        local arg has_port=false
        for arg in "$@"; do
            case "$arg" in
                -p | --port | -p=* | --port=*)
                    has_port=true
                    break
                    ;;
            esac
        done
        if [[ $has_port == false ]]; then
            set -- "$@" -p 5433
        fi
    fi

    exec "$@"
}

if ! _is_sourced; then
    _main "$@"
fi
