#!/usr/bin/env bash
# Copy only public module download archives into a private cache before patching.
# Never share extracted/patched modules or compiled native output.
ci_seed_go_download_cache() {
  if [ -n "${CI_GO_DOWNLOAD_CACHE:-}" ] && [ -d "$CI_GO_DOWNLOAD_CACHE" ]; then
    mkdir -p "$GOMODCACHE/cache/download"
    cp -R "$CI_GO_DOWNLOAD_CACHE/." "$GOMODCACHE/cache/download/"
  fi
}
ci_save_go_download_cache() {
  if [ -n "${CI_GO_DOWNLOAD_CACHE:-}" ]; then
    mkdir -p "$CI_GO_DOWNLOAD_CACHE"
    cp -R "$GOMODCACHE/cache/download/." "$CI_GO_DOWNLOAD_CACHE/"
  fi
}
