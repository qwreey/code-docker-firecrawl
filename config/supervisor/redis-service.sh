#!/bin/sh
set -eu

# Loopback-only, no persistence - see redis.conf's comment for why RDB/AOF durability
# isn't worth it here (nuq's actual job data lives in postgres). `--daemonize no` (the
# default) keeps this in the foreground for supervisord.
exec redis-server --bind 127.0.0.1 --port 6379 --save "" --appendonly no
