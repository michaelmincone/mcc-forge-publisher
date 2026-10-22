#!/bin/bash
set -euo pipefail
mcc_library_root=$(cd "$(dirname "$0")/.." && pwd)
mcc_library_build="$mcc_library_root/.build/selftests"
mkdir -p "$mcc_library_build"
mcc_library_run=$(mktemp -d "$mcc_library_build/library.XXXXXX")
trap 'rm -rf -- "$mcc_library_run"' EXIT
swiftc -emit-library -emit-module -module-name MCCPublisherCore -I "$mcc_library_root/Sources/CZlib" \
    "$mcc_library_root"/Sources/MCCPublisherCore/*.swift \
    -emit-module-path "$mcc_library_run/MCCPublisherCore.swiftmodule" \
    -o "$mcc_library_run/libMCCPublisherCore.dylib"
swiftc -parse-as-library -I "$mcc_library_run" -I "$mcc_library_root/Sources/CZlib" -L "$mcc_library_run" -lMCCPublisherCore \
    "$mcc_library_root/Sources/MCCPublisherApp/PublisherAppModel.swift" \
    "$mcc_library_root/Sources/MCCPublisherApp/LibraryModels.swift" \
    "$mcc_library_root/Sources/MCCPublisherApp/PublicationHistory.swift" \
    "$mcc_library_root/Sources/MCCPublisherApp/PendingFileShareDeletions.swift" \
    "$mcc_library_root/Sources/MCCPublisherApp/PendingSharedUploads.swift" \
    "$mcc_library_root/Sources/MCCPublisherApp/MicrosoftLoginWindow.swift" \
    "$mcc_library_root/Tests/MCCPublisherAppTests/LibraryModelTests.swift" \
    -o "$mcc_library_run/library-model-tests"
DYLD_LIBRARY_PATH="$mcc_library_run" "$mcc_library_run/library-model-tests" --preview-library
swiftc -parse-as-library -I "$mcc_library_run" -I "$mcc_library_root/Sources/CZlib" -L "$mcc_library_run" -lMCCPublisherCore \
    "$mcc_library_root/Sources/MCCPublisherApp/PendingSharedUploads.swift" \
    "$mcc_library_root/Tests/MCCPublisherAppTests/PendingSharedUploadsTests.swift" \
    -o "$mcc_library_run/shared-upload-journal-tests"
DYLD_LIBRARY_PATH="$mcc_library_run" "$mcc_library_run/shared-upload-journal-tests"
