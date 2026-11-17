#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
if [[ -d /opt/homebrew/opt/libssh2 ]]; then DEFAULT_PREFIX=/opt/homebrew/opt/libssh2; else DEFAULT_PREFIX=/usr/local/opt/libssh2; fi
SSH_PREFIX="${CYBERGOOSE_SSH2_PREFIX:-$DEFAULT_PREFIX}"
mkdir -p .build/check-bridge
clang -I "$SSH_PREFIX/include" -I Sources/CSSHBridge/include -c Sources/CSSHBridge/SSHBridge.c -o .build/check-bridge/SSHBridge.o
cat > .build/check-bridge/module.modulemap <<EOF_MAP
module CSSHBridge {
    header "$PWD/Sources/CSSHBridge/include/CSSHBridge.h"
    export *
}
EOF_MAP
CHECK_SOURCE=Tests/Integration/SFTPCoreChecks.swift
if [[ "${1:-}" == --server ]]; then CHECK_SOURCE=Tests/Integration/SFTPServerChecks.swift; fi
swiftc -swift-version 6 -parse-as-library -I .build/check-bridge -L "$SSH_PREFIX/lib" -lssh2 \
    Sources/Cybergoose/Models/FileEntry.swift \
    Sources/Cybergoose/Models/ConnectionProfile.swift \
    Sources/Cybergoose/Models/FileMetadata.swift \
    Sources/Cybergoose/Operations/CancellationFlag.swift \
    Sources/Cybergoose/Persistence/BookmarkStore.swift \
    Sources/Cybergoose/Security/KnownHostsStore.swift \
    Sources/Cybergoose/FileSystems/LocalFileSystem.swift \
    Sources/Cybergoose/Connections/RemoteConnection.swift \
    Sources/Cybergoose/Connections/SSHConnection.swift \
    .build/check-bridge/SSHBridge.o "$CHECK_SOURCE" -o .build/sftp-core-checks
.build/sftp-core-checks
