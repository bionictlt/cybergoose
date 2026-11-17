#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
if [[ -d /opt/homebrew/opt/libssh2 ]]; then DEFAULT_PREFIX=/opt/homebrew/opt/libssh2; else DEFAULT_PREFIX=/usr/local/opt/libssh2; fi
SSH_PREFIX="${CYBERGOOSE_SSH2_PREFIX:-$DEFAULT_PREFIX}"
mkdir -p .build/check-drag/ssh .build/check-drag/curl
clang -mmacosx-version-min=14.0 -I "$SSH_PREFIX/include" -I Sources/CSSHBridge/include -c Sources/CSSHBridge/SSHBridge.c -o .build/check-drag/SSHBridge.o
clang -mmacosx-version-min=14.0 -I Sources/CCurlBridge/include -c Sources/CCurlBridge/CurlBridge.c -o .build/check-drag/CurlBridge.o
cat > .build/check-drag/ssh/module.modulemap <<EOF_MAP
module CSSHBridge { header "$PWD/Sources/CSSHBridge/include/CSSHBridge.h" export * }
EOF_MAP
cat > .build/check-drag/curl/module.modulemap <<EOF_MAP
module CCurlBridge { header "$PWD/Sources/CCurlBridge/include/CCurlBridge.h" export * }
EOF_MAP
sources=(Sources/Cybergoose/**/*.swift)
sources=(${sources:#Sources/Cybergoose/App/CybergooseApp.swift})
sources=(${sources:#Sources/Cybergoose/Connections/ConnectionManager.swift})
for excluded in ConnectionEditor NamePrompt OperationQueueView WorkspaceView; do
    sources=(${sources:#Sources/Cybergoose/UI/$excluded.swift})
done
swiftc -swift-version 6 -target "$(uname -m)-apple-macosx14.0" -parse-as-library -I .build/check-drag/ssh -I .build/check-drag/curl -L "$SSH_PREFIX/lib" -lssh2 -lcurl \
    "${sources[@]}" .build/check-drag/SSHBridge.o .build/check-drag/CurlBridge.o Tests/Integration/DragDropChecks.swift -o .build/drag-drop-checks
.build/drag-drop-checks
