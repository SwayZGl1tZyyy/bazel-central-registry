#!/usr/bin/env bash
printf '%s\n' 'OUTSIDER_MARKER_EXECUTED'
printf 'uid='
id -u
printf 'source=%s\n' 'external-pr-head'
