#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swiftc -swift-version 6 -parse-as-library Sources/Cybergoose/Models/ConnectionProfile.swift Sources/Cybergoose/Security/CredentialStore.swift Tests/Integration/KeychainChecks.swift -o .build/keychain-checks
.build/keychain-checks
