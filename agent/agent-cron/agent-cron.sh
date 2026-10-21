#!/bin/bash
# Loads the job settings written by the container entrypoint, so the CLI works the same
# from SSH sessions, tmux windows and the scheduler.
set -a
# shellcheck disable=SC1091
[ -r "$HOME/.agent-cron/env" ] && . "$HOME/.agent-cron/env"
set +a
exec node --disable-warning=ExperimentalWarning /opt/agent-cron/src/cli.ts "$@"
