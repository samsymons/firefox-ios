#!/usr/bin/env sh
carthage checkout --no-use-binaries

# WORKAROUND - SDWebImage has issues decoding images at the moment. Override the decoder with a version that fixes the issue.
# Github issue: https://github.com/rs/SDWebImage/issues/1203
echo "Temporarily patch SDWebImage checkout to resolve Issue 1203 - Decoding image issues"
echo "See https://bugzilla.mozilla.org/show_bug.cgi?id=1187161"
cp patches/SDWebImageDecoder.m.1203fix Carthage/Checkouts/SDWebImage/SDWebImage/SDWebImageDecoder.m
