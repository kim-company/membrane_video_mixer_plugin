#!/usr/bin/env bash

ffmpeg_root="$(mise where ffmpeg 2>/dev/null || true)"
if [ -n "$ffmpeg_root" ]; then
  pkgconfig_path="$ffmpeg_root/lib/pkgconfig"
  if [ -n "${PKG_CONFIG_PATH:-}" ]; then
    export PKG_CONFIG_PATH="$pkgconfig_path:$PKG_CONFIG_PATH"
  else
    export PKG_CONFIG_PATH="$pkgconfig_path"
  fi
fi
