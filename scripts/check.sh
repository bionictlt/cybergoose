#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p .build/clang-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swiftc -swift-version 6 -parse-as-library Sources/Cybergoose/Models/FileEntry.swift Sources/Cybergoose/FileSystems/LocalFileSystem.swift Tests/CybergooseTests/LocalFileSystemTests.swift -o .build/filesystem-checks
.build/filesystem-checks
