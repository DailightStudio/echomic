# Eolmalka Android 빌드 환경
FROM node:20-bullseye

ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    PATH=$PATH:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools

# Java + build tools 설치
RUN apt-get update && apt-get install -y \
    openjdk-17-jdk-headless \
    build-essential \
    git \
    wget \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Android SDK 설치
WORKDIR /opt
RUN wget -q https://dl.google.com/android/repository/commandlinetools-linux-10406996_latest.zip && \
    unzip -q commandlinetools-linux-10406996_latest.zip && \
    mkdir -p android-sdk/cmdline-tools && \
    mv cmdline-tools android-sdk/cmdline-tools/latest && \
    rm commandlinetools-linux-10406996_latest.zip && \
    yes | sdkmanager --sdk_root=$ANDROID_HOME \
      "platforms;android-35" \
      "build-tools;35.0.0" \
      "ndk;27.0.12077973"

WORKDIR /workspace
COPY . .

RUN npm ci --legacy-peer-deps

ENTRYPOINT ["bash", "-c", "npx expo prebuild --clean --platform android --yes && cd android && ./gradlew bundleRelease && ls -lh app/build/outputs/bundle/release/*.aab"]
