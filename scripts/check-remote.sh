#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
if [[ -d /opt/homebrew/opt/libssh2 ]]; then DEFAULT_PREFIX=/opt/homebrew/opt/libssh2; else DEFAULT_PREFIX=/usr/local/opt/libssh2; fi
SSH_PREFIX="${CYBERGOOSE_SSH2_PREFIX:-$DEFAULT_PREFIX}"
mkdir -p .build/check-remote/ssh .build/check-remote/curl
clang -Wall -Wextra -Werror -I "$SSH_PREFIX/include" -I Sources/CSSHBridge/include -c Sources/CSSHBridge/SSHBridge.c -o .build/check-remote/SSHBridge.o
clang -Wall -Wextra -Werror -I Sources/CCurlBridge/include -c Sources/CCurlBridge/CurlBridge.c -o .build/check-remote/CurlBridge.o
cat > .build/check-remote/ssh/module.modulemap <<EOF_MAP
module CSSHBridge {
    header "$PWD/Sources/CSSHBridge/include/CSSHBridge.h"
    export *
}
EOF_MAP
cat > .build/check-remote/curl/module.modulemap <<EOF_MAP
module CCurlBridge {
    header "$PWD/Sources/CCurlBridge/include/CCurlBridge.h"
    export *
}
EOF_MAP
swiftc -swift-version 6 -parse-as-library -I .build/check-remote/ssh -I .build/check-remote/curl -L "$SSH_PREFIX/lib" -lssh2 -lcurl \
    Sources/Cybergoose/Models/FileEntry.swift \
    Sources/Cybergoose/Models/FileMetadata.swift \
    Sources/Cybergoose/Models/ConnectionProfile.swift \
    Sources/Cybergoose/FileSystems/LocalFileSystem.swift \
    Sources/Cybergoose/Operations/CancellationFlag.swift \
    Sources/Cybergoose/Persistence/BookmarkStore.swift \
    Sources/Cybergoose/Security/KnownHostsStore.swift \
    Sources/Cybergoose/Connections/RemoteConnection.swift \
    Sources/Cybergoose/Connections/SSHConnection.swift \
    Sources/Cybergoose/Connections/CurlTransport.swift \
    Sources/Cybergoose/Connections/FTPConnection.swift \
    Sources/Cybergoose/Connections/S3Connection.swift \
    .build/check-remote/SSHBridge.o .build/check-remote/CurlBridge.o Tests/Integration/RemoteServerChecks.swift -o .build/remote-server-checks
.build/remote-server-checks
