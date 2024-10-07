#!/bin/bash

set -e

. /usr/lib/wb-utils/wb_env.sh
wb_source "of"

# FIXME: wirenboard,wirenboard-720 is obsolete, use wirenboard,wirenboard-7xx instead.
# It requires wirenboard-7xx entries in older DTS.
# See https://wirenboard.bitrix24.ru/workgroups/group/218/tasks/task/view/61070/
if of_machine_match "wirenboard,wirenboard-7xx" || of_machine_match "wirenboard,wirenboard-720"; then
    # replace broken factoryreset FITs
    FACTORYRESET_FIT="/mnt/data/.wb-restore/factoryreset.fit"

    # do not fail during rootfs build
    if [ -e "$FACTORYRESET_FIT" ]; then
        FACTORYRESET_SHA256="$(sha256sum "$FACTORYRESET_FIT" | awk '{print $1}')"

        BROKEN_STABLE_FITS=(
            "7ca056ba02c24f882283d16a0c0ee4cc2c0a92cd509fabb89021cb5305b61a3a"
            "9ef0b4ac68d0c839a6ee59788a6230a3a21988472b006a6e37f4f1b6cfe73cc7"
            "82618e593e59fa571c298d64e596188df5877ead0207a9611eee1a5c4f5036d9"
            "b5e21070b69a0a258471c12f199f5f52c4d455b0cc5fbed7c4d2b055b21beccb"
        )

        BROKEN_TESTING_FITS=(
            "edd8d2735dbd3d7b616eea64fab6ff4acf7c3729e27a4085576d60c843b280b1"
        )

        download_fixed_fit() {
            URL="$1"
            shift
            for broken in "$@"; do
                if [[ "$FACTORYRESET_SHA256" == "$broken" ]]; then
                    echo "Broken factory FIT found, downloading a working one"
                    wget -O "${FACTORYRESET_FIT}.new" "${URL}?broken&from=${FACTORYRESET_SHA256}&serial=$(wb-gen-serial -s)"
                    local was_immutable=$(lsattr -l $FACTORYRESET_FIT | grep "Immutable" || true)
                    chattr -i $FACTORYRESET_FIT
                    mv "${FACTORYRESET_FIT}.new" "$FACTORYRESET_FIT"
                    sync
                    [[ -n "$was_immutable" ]] && chattr +i $FACTORYRESET_FIT
                    break
                fi
            done
        }

        STABLE_FIT_URL="https://fw-releases.wirenboard.com/fit_image/stable/7x/latest.fit"
        download_fixed_fit "$STABLE_FIT_URL" "${BROKEN_STABLE_FITS[@]}"

        TESTING_FIT_URL="https://fw-releases.wirenboard.com/fit_image/testing/7x/latest.fit"
        download_fixed_fit "$TESTING_FIT_URL" "${BROKEN_TESTING_FITS[@]}"
    fi
fi
