#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
mkdir -p .build/check-curl
clang -Wall -Wextra -Werror -I Sources/CCurlBridge/include -c Sources/CCurlBridge/CurlBridge.c -o .build/check-curl/CurlBridge.o
cat > .build/check-curl/module.modulemap <<EOF_MAP
module CCurlBridge {
    header "$PWD/Sources/CCurlBridge/include/CCurlBridge.h"
    export *
}
EOF_MAP
swiftc -swift-version 6 -parse-as-library -I .build/check-curl -lcurl \
    Sources/Cybergoose/Models/FileEntry.swift \
    Sources/Cybergoose/Models/FileMetadata.swift \
    Sources/Cybergoose/Models/ConnectionProfile.swift \
    Sources/Cybergoose/FileSystems/LocalFileSystem.swift \
    Sources/Cybergoose/Operations/CancellationFlag.swift \
    Sources/Cybergoose/Connections/RemoteConnection.swift \
    Sources/Cybergoose/Connections/CurlTransport.swift \
    Sources/Cybergoose/Connections/FTPConnection.swift \
    Sources/Cybergoose/Connections/S3Connection.swift \
    .build/check-curl/CurlBridge.o Tests/Integration/ProtocolChecks.swift -o .build/protocol-checks
.build/protocol-checks
