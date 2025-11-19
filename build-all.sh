set -e

CMAKE_GENERATOR=Ninja ./build x86_64-freebsd-none baseline

CMAKE_GENERATOR=Ninja ./build aarch64-linux-musl baseline
CMAKE_GENERATOR=Ninja ./build loongarch64-linux-musl baseline
CMAKE_GENERATOR=Ninja ./build riscv64-linux-musl baseline
CMAKE_GENERATOR=Ninja ./build s390x-linux-musl baseline
CMAKE_GENERATOR=Ninja ./build x86_64-linux-musl baseline

CMAKE_GENERATOR=Ninja ./build aarch64-macos-none baseline

CMAKE_GENERATOR=Ninja ./build aarch64-windows-gnu baseline
CMAKE_GENERATOR=Ninja ./build x86_64-windows-gnu baseline
