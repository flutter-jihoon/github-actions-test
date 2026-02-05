#!/bin/bash

ORIGINAL_DIR=$(pwd)

OS=${RUNNER_OS:-linux}
ARCH=${RUNNER_ARCH:-x64}

FLUTTER_VERSION=${1:-"latest"}
FLUTTER_CHANNEL=${2:-"stable"}
PATCH_FILE=${3:-"diff.patch"}

FLUTTER_OS=$(echo "${OS}" | awk '{print tolower($0)}')
FLUTTER_ARCH=$(echo "${ARCH}" | awk '{print tolower($0)}')
FLUTTER_RELEASE_URL=${FLUTTER_RELEASE_URL:-"https://storage.googleapis.com/flutter_infra_release/releases"}

# Apple Silicon 대응
FLUTTER_BUILD_OS=$FLUTTER_OS
if [[ $FLUTTER_OS == "macos" && $FLUTTER_ARCH == "arm64" ]]; then
	if [[ $FLUTTER_VERSION < 3.* ]]; then
		echo -e "Flutter SDK 버전 \"${FLUTTER_VERSION}\"은 Apple Silicon을 지원하지 않습니다. 3.0.0 이상 버전을 사용해주세요."
		exit 1
	fi
	FLUTTER_BUILD_OS="macos_arm64"
	echo "Apple Silicon이 감지되었습니다. \"${FLUTTER_BUILD_OS}\" 빌드를 사용합니다."
fi

# OS 아카이브 파일 확장자
EXT="zip"
if [[ $FLUTTER_OS == "linux" ]]
then
	EXT="tar.xz"
fi

FLUTTER_BUILD_ARTIFACT_ID="flutter_${FLUTTER_BUILD_OS}_${FLUTTER_VERSION}-${FLUTTER_CHANNEL}.${EXT}"
FLUTTER_BUILD_ARTIFACT_URL="${FLUTTER_RELEASE_URL}/${FLUTTER_CHANNEL}/${FLUTTER_OS}/${FLUTTER_BUILD_ARTIFACT_ID}"

FLUTTER_RUNNER_TOOL_CACHE="${RUNNER_TOOL_CACHE}/flutter/${FLUTTER_VERSION}/${FLUTTER_CHANNEL}"
FLUTTER_PUB_CACHE="${RUNNER_TEMP}/flutter/pub-cache"

# Flutter SDK가 이미 존재하는지 확인하고, 존재하지 않으면 다운로드합니다.
if [ ! -d "${FLUTTER_RUNNER_TOOL_CACHE}" ]; then
	echo "Flutter SDK ${FLUTTER_VERSION} 버전을 "${FLUTTER_OS}_${FLUTTER_ARCH}"에 설치합니다."

	# Flutter SDK 빌드 아티팩트를 다운로드합니다.
	echo "${FLUTTER_BUILD_ARTIFACT_URL} 다운로드 중"
	FLUTTER_BUILD_ARTIFACT_FILE="${RUNNER_TEMP}/${FLUTTER_BUILD_ARTIFACT_ID}"
	curl --connect-timeout 15 --retry 5 -C - -o "${FLUTTER_BUILD_ARTIFACT_FILE}" "$FLUTTER_BUILD_ARTIFACT_URL"
	if [ $? -ne 0 ]; then
		echo -e "다운로드에 실패했습니다. 전달된 인자를 확인해주세요."
		exit 1
	fi

	# Runner tool 캐시를 준비합니다.
	mkdir -p "${FLUTTER_RUNNER_TOOL_CACHE}"

	# 설치 파일을 압축 해제합니다.
	echo -n "Flutter SDK를 압축 해제합니다."
	if [[ $FLUTTER_OS == linux ]]
	then
		tar -C "${FLUTTER_RUNNER_TOOL_CACHE}" -xf ${FLUTTER_BUILD_ARTIFACT_FILE} >/dev/null
		EXTRACT_ARCHIVE_CODE=$?
	else
		unzip ${FLUTTER_BUILD_ARTIFACT_FILE} -d "${FLUTTER_RUNNER_TOOL_CACHE}" >/dev/null
		EXTRACT_ARCHIVE_CODE=$?
	fi
	if [ $EXTRACT_ARCHIVE_CODE -eq 0 ]; then
		echo "압축 해제를 완료했습니다."
	else
		echo -e "Flutter SDK를 압축 해제하지 못했습니다."
		exit 1
	fi
else
	echo "Flutter SDK ${FLUTTER_VERSION} 버전을 "${FLUTTER_OS}_${FLUTTER_ARCH}"에서 복원했습니다."
fi

# 패치 파일을 통해 Flutter SDK 내부 파일을 수정합니다.
if [[ -n "$PATCH_FILE" && -f "$PATCH_FILE" ]]; then
    echo "패치 파일을 적용합니다: ${PATCH_FILE}"
    patch -d "${FLUTTER_RUNNER_TOOL_CACHE}/flutter" -p1 < "$PATCH_FILE"
    if [ $? -eq 0 ]; then
        echo "패치 적용 완료"
    else
        echo "패치 적용 실패"
        exit 1
    fi
fi

# engine/scripts/ 경로에 있는 standard.gclient 파일을 루트 경로의 .gclient 파일로 복사합니다.
cp ${FLUTTER_RUNNER_TOOL_CACHE}/flutter/engine/scripts/standard.gclient ${FLUTTER_RUNNER_TOOL_CACHE}/flutter/.gclient
gclient sync -D

# et를 사용하기 위해 engine/src/flutter/bin 경로를 PATH에 추가합니다.
echo "${FLUTTER_RUNNER_TOOL_CACHE}/flutter/engine/src/flutter/bin" >> $GITHUB_PATH

# 로컬 엔진을 빌드합니다.
echo "로컬 엔진 빌드를 시작합니다..."
echo "현재 아키텍처: ${ARCH}"

JOBS=${JOBS:-8}

cd "${FLUTTER_RUNNER_TOOL_CACHE}/flutter/engine/src/flutter"

# Runner 아키텍처에 따라 Host 엔진 결정
# ARCH는 대문자일 수 있으므로 대소문자 무관하게 비교
ARCH_LOWER=$(echo "${ARCH}" | awk '{print tolower($0)}')

if [[ $ARCH_LOWER == "arm64" ]]; then
    HOST_RELEASE="host_release_arm64"
    echo "ARM64 아키텍처 감지: ${HOST_RELEASE} 사용"
else
    HOST_RELEASE="host_release"
    echo "x64 아키텍처 감지: ${HOST_RELEASE} 사용"
fi

# Host Release 엔진 빌드
echo "Host Release 엔진을 빌드합니다..."
et build --config ${HOST_RELEASE} -j ${JOBS} //flutter/...
if [ $? -ne 0 ]; then
    echo "Host Release 엔진 빌드 실패"
    exit 1
fi
echo "Host Release 엔진 빌드 완료"

# Android Release 엔진 빌드
echo "Android Release 엔진을 빌드합니다..."
et build --config android_release_arm64 -j ${JOBS} //flutter/...
if [ $? -ne 0 ]; then
    echo "Android Release 엔진 빌드 실패"
    exit 1
fi
echo "Android Release 엔진 빌드 완료"

# iOS Release 엔진 빌드
if [[ $FLUTTER_OS == "macos" ]]; then
    echo "iOS Release 엔진을 빌드합니다..."
    et build --config ios_release -j ${JOBS} //flutter/...
    if [ $? -ne 0 ]; then
        echo "iOS Release 엔진 빌드 실패"
        exit 1
    fi
    echo "iOS Release 엔진 빌드 완료"
fi
echo "로컬 엔진 빌드 완료"
cd "${ORIGINAL_DIR}"

# pub이 사용할 경로를 설정합니다.
echo "PUB_CACHE=${FLUTTER_PUB_CACHE}" >> $GITHUB_ENV
mkdir -p $FLUTTER_PUB_CACHE

# 경로를 업데이트합니다.
echo "${FLUTTER_PUB_CACHE}/bin" >> $GITHUB_PATH
echo "${FLUTTER_RUNNER_TOOL_CACHE}/flutter/bin" >> $GITHUB_PATH

# Flutter SDK를 실행하고 분석을 억제합니다.
${FLUTTER_RUNNER_TOOL_CACHE}/flutter/bin/flutter --version --suppress-analytics 2>&1 >/dev/null

# Google Analytics 및 CLI 애니메이션을 비활성화합니다.
${FLUTTER_RUNNER_TOOL_CACHE}/flutter/bin/flutter config --no-analytics 2>&1 >/dev/null
${FLUTTER_RUNNER_TOOL_CACHE}/flutter/bin/flutter config --no-cli-animations 2>&1 >/dev/null

# 성공적으로 설치되었음을 알리고, 버전을 출력합니다.
echo "Flutter SDK 설치를 완료했습니다."
${FLUTTER_RUNNER_TOOL_CACHE}/flutter/bin/dart --version
${FLUTTER_RUNNER_TOOL_CACHE}/flutter/bin/flutter --version