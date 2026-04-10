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
	if [[ $FLUTTER_OS == "linux" ]]
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
cd ${FLUTTER_RUNNER_TOOL_CACHE}/flutter
cp engine/scripts/standard.gclient .gclient
gclient sync -D

# et를 사용하기 위해 engine/src/flutter/bin 경로를 PATH에 추가합니다.
ENGINE_BIN="${FLUTTER_RUNNER_TOOL_CACHE}/flutter/engine/src/flutter/bin"
export PATH="$ENGINE_BIN:$PATH"

# et 내부 ninja 빌드 진행 상태를 표시하지 않습니다.
export NINJA_STATUS=""

# 로컬 엔진을 빌드합니다.
echo "로컬 엔진 빌드를 시작합니다..."
echo "현재 아키텍처: ${ARCH}"

JOBS=${JOBS:-4}

# Runner 아키텍처에 따라 Host 엔진 결정
if [[ $FLUTTER_ARCH == "arm64" ]]; then
    ANDROID_RELEASE="ci/android_release_arm64"
    echo "ARM64 아키텍처 감지: ${ANDROID_RELEASE} 사용"
else
    ANDROID_RELEASE="ci/android_release_arm64"
    echo "x64 아키텍처 감지: ${ANDROID_RELEASE} 사용"
fi

# Host Release 엔진 빌드
echo "Host Release 엔진을 빌드합니다..."
et build --config ${ANDROID_RELEASE} -j ${JOBS}
if [ $? -ne 0 ]; then
    echo "Host Release 엔진 빌드 실패"
    exit 1
fi
echo "Host Release 엔진 빌드 완료"

echo "GITHUB_REF:      $GITHUB_REF"
echo "GITHUB_REF_NAME: $GITHUB_REF_NAME"
echo "GITHUB_REPOSITORY: $GITHUB_REPOSITORY"

# 현재 gh가 바라보는 repo
git remote -v
gh release list --limit 20

# GitHub Releases에 엔진 빌드 결과를 업로드합니다.
if [[ -n "${GH_TOKEN:-}" ]] && [[ -n "${GITHUB_REF_NAME:-}" ]]; then
  echo "GitHub Release(${GITHUB_REF_NAME})에 Host Release 엔진을 업로드합니다..."

  # out은 engine/src/out 아래에 있음
  cd "${FLUTTER_RUNNER_TOOL_CACHE}/flutter/engine/src"

  ENGINE_OUT_DIR="out/${ANDROID_RELEASE}"
  ENGINE_ARCHIVE="${RUNNER_TEMP}/flutter-engine-${ANDROID_RELEASE}.tar.xz"

  if [[ -d "${ENGINE_OUT_DIR}" ]]; then
    tar -C "${ENGINE_OUT_DIR}" -cJf "${ENGINE_ARCHIVE}" .

    if ! gh release view "${GITHUB_REF_NAME}" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1; then
      echo "릴리스(${GITHUB_REF_NAME})가 ${GITHUB_REPOSITORY}에 없습니다. 릴리스 먼저 생성됐는지 확인해주세요."
      exit 1
    fi

    gh release upload \
    "${GITHUB_REF_NAME}" \
    "${ENGINE_ARCHIVE}" \
    --repo "${GITHUB_REPOSITORY}" \
    --clobber
  else
    echo "경고: ${ENGINE_OUT_DIR} 디렉터리가 없어 GitHub Release 업로드를 건너뜁니다."
  fi
else
  echo "GH_TOKEN 또는 GITHUB_REF_NAME이 없어 Release 업로드를 건너뜁니다."
fi

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
