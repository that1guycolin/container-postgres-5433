#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=./container-entrypoint.sh
source /usr/local/bin/container-entrypoint.sh

if [ "$#" -eq 0 ] || [ "$1" != 'postgres' ]; then
    set -- postgres "$@"
fi

container_setup_env
container_create_db_directories
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
else
    self="$(basename "$0")"
    case "$self" in
        ensure-initdb.sh)
            echo >&2 "$self: note: database already initialized in '$PGDATA'!"
            exit 0
            ;;

        enforce-initdb.sh)
            echo >&2 "$self: error: (unexpected) database found in '$PGDATA'!"
            exit 1
            ;;

        *)
            echo >&2 "$self: error: unknown file name: $self"
            exit 99
            ;;
    esac
fi
