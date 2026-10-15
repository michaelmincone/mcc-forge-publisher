#!/bin/bash
set -euo pipefail
mcc_test_root=$(cd "$(dirname "$0")/.." && pwd)
mcc_test_build="$mcc_test_root/.build/selftests"
mkdir -p "$mcc_test_build"
mcc_test_run=$(mktemp -d "$mcc_test_build/run.XXXXXX")
trap 'rm -rf -- "$mcc_test_run"' EXIT
mcc_test_sources=("$mcc_test_root"/Sources/MCCPublisherCore/*.swift)

for mcc_test_spec in \
    'REACH_STANDALONE_TESTS:ReachMapTests.swift:reach' \
    'AUTH_STANDALONE_TESTS:AuthTests.swift:auth' \
    'PUBLICATION_STANDALONE_TESTS:PublicationTests.swift:publication'; do
    IFS=: read -r mcc_test_flag mcc_test_file mcc_test_name <<< "$mcc_test_spec"
    swiftc -parse-as-library -D "$mcc_test_flag" -I "$mcc_test_root/Sources/CZlib" \
        "${mcc_test_sources[@]}" "$mcc_test_root/Tests/MCCPublisherCoreTests/$mcc_test_file" \
        -o "$mcc_test_run/$mcc_test_name-tests"
    "$mcc_test_run/$mcc_test_name-tests"
done

swiftc -parse-as-library -D HISTORY_STANDALONE_TESTS -I "$mcc_test_root/Sources/CZlib" \
    "${mcc_test_sources[@]}" "$mcc_test_root/Sources/MCCPublisherApp/PublicationHistory.swift" \
    "$mcc_test_root/Tests/MCCPublisherAppTests/PublicationHistoryTests.swift" \
    -o "$mcc_test_run/history-tests"
"$mcc_test_run/history-tests"
