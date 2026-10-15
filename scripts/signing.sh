# Sourced by build-app.sh.
#
# macOS keychain trusts an app by its code signature. An ad-hoc signature changes with every
# build, so macOS asks once after each rebuild before the new build can read the saved sign-in.
# An Apple-issued certificate (a free "Apple Development" one from Xcode > Settings > Accounts,
# or "Developer ID Application") keeps the signature stable, and macOS stops asking after updates.
# MCC_SIGNING_IDENTITY picks one explicitly ("-" forces ad-hoc).
mcc_signing_identity() {
    if [ -n "${MCC_SIGNING_IDENTITY:-}" ]; then echo "$MCC_SIGNING_IDENTITY"; return; fi
    local found
    found=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/"Developer ID Application: / { print $2; exit }')
    [ -n "$found" ] || found=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/"Apple Development: / { print $2; exit }')
    echo "${found:--}"
}

mcc_sign_app() {
    local identity
    identity=$(mcc_signing_identity)
    # Hardened runtime blocks code injection into the process that holds the sign-in.
    codesign --force --options runtime --sign "$identity" --identifier org.mjolnir.MCCForgePublisher "$1"
    codesign --verify --deep --strict "$1"
    echo "Signed with: $([ "$identity" = - ] && echo 'ad-hoc (macOS asks once after each rebuild)' || echo "$identity")" >&2
}
