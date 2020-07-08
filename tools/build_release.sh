#!/bin/bash

set -ex

function build {
  dub build -b release --verror
  strip "$target_path"
}

function version {
  "$target_path" --version
}

function archive {
  tar Jcf "$app_name-$(version)-macos.tar.xz" -C "$target_dir" "$app_name"
}

app_name="$(dub describe --verror --data target-name --data-list | head -n 1)"
target_dir="."
target_path="$target_dir/$app_name"

build
archive
