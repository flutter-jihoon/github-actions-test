#!/usr/bin/env bash

set -e

# gh CLI 체크
if ! command -v gh &> /dev/null; then
    echo "❌ gh CLI가 설치되어 있지 않습니다." >&2
    echo "   macOS: brew install gh" >&2
    exit 1
fi

if ! gh auth status &> /dev/null; then
    echo "❌ gh CLI 로그인이 필요합니다: gh auth login" >&2
    exit 1
fi

# 인자 체크
if [ $# -ne 1 ]; then
    echo "Usage: $0 [version]" >&2
    exit 1
fi

version="$1"
REPO="cashwalk/Add-To-App-Flutter"

# version 처리
if [ "$version" = "latest" ]; then
    version="cw.latest"
elif [ "$version" = "fixed" ]; then
    version=$(cat .flutter-sdk-version)
fi

# 다운로드 및 압축 해제
echo "Downloading SDKs.zip..." >&2
gh release download "$version" --repo "$REPO" --pattern "SDKs.zip"

echo "Unzip SDKs.zip..." >&2
unzip -qq -o SDKs.zip -d Packages/CashwalkFlutterShare

rm -f SDKs.zip

echo "🎉 Install $version Flutter SDKs done." >&2
