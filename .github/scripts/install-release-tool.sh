#!/bin/sh
set -eu

tool=${1:?usage: install-release-tool.sh git-cliff|dist}
install_dir=${INSTALL_DIR:-"$HOME/.cargo/bin"}
os=$(uname -s)
arch=$(uname -m)

case "$tool:$os:$arch" in
  git-cliff:Linux:x86_64)
    version=2.13.1
    archive="git-cliff-${version}-x86_64-unknown-linux-gnu.tar.gz"
    checksum=9a1263f24e59a2f508c7b3d3283c9dea94a8bf697f96dbc18cc783cac6284546
    url="https://github.com/orhun/git-cliff/releases/download/v${version}/${archive}"
    binary_path="git-cliff-${version}/git-cliff"
    expected_version="git-cliff ${version}"
    ;;
  dist:Linux:x86_64)
    version=0.31.0
    archive=cargo-dist-x86_64-unknown-linux-gnu.tar.xz
    checksum=cd355dab0b4c02fb59038fef87655550021d07f45f1d82f947a34ef98560abb8
    url="https://github.com/axodotdev/cargo-dist/releases/download/v${version}/${archive}"
    binary_path=cargo-dist-x86_64-unknown-linux-gnu/dist
    expected_version="cargo-dist ${version}"
    ;;
  dist:Linux:aarch64)
    version=0.31.0
    archive=cargo-dist-aarch64-unknown-linux-gnu.tar.xz
    checksum=382cc29ff91ef12a5bf78ad8ee1804661d24e2fbe64b1bdedd6078723b677ae5
    url="https://github.com/axodotdev/cargo-dist/releases/download/v${version}/${archive}"
    binary_path=cargo-dist-aarch64-unknown-linux-gnu/dist
    expected_version="cargo-dist ${version}"
    ;;
  dist:Darwin:arm64)
    version=0.31.0
    archive=cargo-dist-aarch64-apple-darwin.tar.xz
    checksum=decb01c64c12501931c3cac3111b368a7f48adf8d9e65455c08e5757b9a1fd6f
    url="https://github.com/axodotdev/cargo-dist/releases/download/v${version}/${archive}"
    binary_path=cargo-dist-aarch64-apple-darwin/dist
    expected_version="cargo-dist ${version}"
    ;;
  *)
    echo "unsupported release tool platform: $tool $os $arch" >&2
    exit 1
    ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
curl --proto '=https' --tlsv1.2 -LsSf "$url" -o "$tmp/$archive"

if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmp/$archive" | awk '{print $1}')
else
  actual=$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')
fi

if [ "$actual" != "$checksum" ]; then
  echo "checksum mismatch for $archive: got $actual" >&2
  exit 1
fi

case "$archive" in
  *.tar.gz) tar -xzf "$tmp/$archive" -C "$tmp" ;;
  *.tar.xz) tar -xJf "$tmp/$archive" -C "$tmp" ;;
esac

mkdir -p "$install_dir"
cp "$tmp/$binary_path" "$install_dir/$tool"
chmod +x "$install_dir/$tool"

actual_version=$("$install_dir/$tool" --version)
if [ "$actual_version" != "$expected_version" ]; then
  echo "unexpected $tool version: $actual_version" >&2
  exit 1
fi

echo "installed verified $actual_version"
