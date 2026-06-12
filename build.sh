#!/bin/bash
# eolmalka Android 빌드 자동화 스크립트

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_TYPE=${1:-release}
PUBLISH=${2:-false}

echo "🚀 eolmalka Android 빌드 시작"
echo "📱 빌드 타입: $BUILD_TYPE"
echo "📦 버전: $(jq -r '.version' package.json)"

# Docker 빌드
echo "🐳 Docker 이미지 빌드 중..."
docker build -t eolmalka-builder:latest .

# Docker 실행
echo "🔨 컨테이너에서 빌드 중..."
docker run --rm \
  -v "$SCRIPT_DIR:/workspace" \
  -e BUILD_TYPE=$BUILD_TYPE \
  eolmalka-builder:latest

APK_PATH="$(find android/app/build/outputs/apk -name '*.apk' -type f | head -1)"

if [ -z "$APK_PATH" ]; then
  echo "❌ APK 파일을 찾을 수 없습니다"
  exit 1
fi

echo "✅ 빌드 완료: $APK_PATH"
echo "📊 파일 크기: $(du -h "$APK_PATH" | cut -f1)"

# Google Play 배포 (선택사항)
if [ "$PUBLISH" = "true" ]; then
  echo "📤 Google Play에 배포 중..."
  # bundletool 또는 fastlane으로 배포
  # TODO: 배포 스크립트 구현
fi

echo "✨ 완료!"
