#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=./container-entrypoint.sh
source /usr/local/bin/container-entrypoint.sh

if [ "$#" -eq 0 ] || [ "$1" != 'postgres' ]; then
    set -- postgres "$@"
fi

docker_setup_env
docker_create_db_directories
if [ "$(id -u)" = '0' ]; then
    exec gosu postgres "${BASH_SOURCE[@]}" "$@"
fi

if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
    docker_verify_minimum_env
    docker_error_old_databases

    ls /docker-entrypoint-initdb.d/ >/dev/null

    docker_init_database_dir
    pg_setup_hba_conf "$@"

    export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"
    docker_temp_server_start "$@"

    docker_setup_db
    docker_process_init_files /docker-entrypoint-initdb.d/*

    docker_temp_server_stop
    unset PGPASSWORD
else
    self="$(basename "$0")"
    case "$self" in
        docker-ensure-initdb.sh)
            echo >&2 "$self: note: database already initialized in '$PGDATA'!"
            exit 0
            ;;

        docker-enforce-initdb.sh)
            echo >&2 "$self: error: (unexpected) database found in '$PGDATA'!"
            exit 1
            ;;

        *)
            echo >&2 "$self: error: unknown file name: $self"
            exit 99
            ;;
    esac
fi
