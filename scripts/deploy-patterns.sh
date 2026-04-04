#!/usr/bin/env bash
#
# deploy-patterns.sh -- Deployment trigger patterns (shared by finish.sh and deploy.sh)
#
# Usage: source scripts/deploy-patterns.sh
#        classify_file "server/src/index.ts"  -> returns "server"
#        classify_file "CLAUDE.md"            -> returns "none"
#

# Classify a single file path, returns: server / client / none
# Customize these patterns to match your project structure.
classify_file() {
  case "$1" in
    server/src/*|shared/*)                                       echo "server" ;;
    package.json|package-lock.json|server/package.json)          echo "server" ;;
    server/tsconfig*|tsconfig.json)                              echo "server" ;;
    client/src/*|client/public/*|client/index.html)              echo "client" ;;
    client/package.json|client/tsconfig*)                        echo "client" ;;
    client/vite.config*|client/tailwind*|client/postcss*)        echo "client" ;;
    *)                                                           echo "none"   ;;
  esac
}

# Classify a set of files (newline-separated), returns highest level: full / client / none
# full = has server changes (server changes imply a full rebuild including client)
classify_changes() {
  local files="$1"
  local _has_server=false
  local _has_client=false

  while IFS= read -r _f; do
    [ -z "$_f" ] && continue
    case "$(classify_file "$_f")" in
      server) _has_server=true; break ;;
      client) _has_client=true ;;
    esac
  done <<< "$files"

  if [ "$_has_server" = true ]; then
    echo "full"
  elif [ "$_has_client" = true ]; then
    echo "client"
  else
    echo "none"
  fi
}
