#!/usr/bin/env bash

# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

basepath=$(
  cd $(dirname $0)
  pwd
)
declare down_dir="${basepath}/tmp_down_dir"
declare build_dir="${basepath}/tmp_build_dir"
declare packet_dir="${basepath}/tmp_packet_dir"
declare install_lib_dir="${basepath}/bin"
declare static_package_dir="${basepath}/tmp_static_package_dir"
declare fname_openssl="openssl*.tar.gz"

declare fname_libevent="libevent*.zip"
declare fname_jsoncpp="jsoncpp*.zip"
declare fname_boost="boost*.tar.gz"
declare fname_openssl_down="openssl-1.1.1d.tar.gz"
declare fname_libevent_down="release-2.1.11-stable.zip"
declare fname_jsoncpp_down="0.10.7.zip"
declare fname_boost_down="1.78.0/boost_1_78_0.tar.gz"

# ===== Performance Tuning =====
declare ARCH=$(uname -m)
declare BUILD_JOBS=0
declare MAX_PARALLEL_JOBS=0

# Auto-detect CPU cores with safety limits for ARM64
if test "$(uname)" = "Linux"; then
  BUILD_JOBS=$(cat /proc/cpuinfo | grep "processor" | wc -l)
  # Limit parallel jobs to prevent memory exhaustion on ARM64
  if [ "$ARCH" = "aarch64" ]; then
    # ARM64 in containers often has memory constraints
    MAX_PARALLEL_JOBS=$((BUILD_JOBS / 2))
    if [ $MAX_PARALLEL_JOBS -lt 1 ]; then
      MAX_PARALLEL_JOBS=1
    fi
  else
    MAX_PARALLEL_JOBS=$BUILD_JOBS
  fi
elif test "$(uname)" = "Darwin" ; then
  BUILD_JOBS=$(sysctl -n machdep.cpu.thread_count)
  MAX_PARALLEL_JOBS=$BUILD_JOBS
else
  BUILD_JOBS=2
  MAX_PARALLEL_JOBS=1
fi

echo "Build environment: Arch=$ARCH, CPU_CORES=$BUILD_JOBS, MAX_PARALLEL=$MAX_PARALLEL_JOBS"

PrintParams() {
  echo "=========================================one key build help============================================"
  echo "sh build.sh [no build libevent:noEvent] [no build json:noJson] [no build boost:noBoost] [ execution test:test]"
  echo "usage: sh build.sh noJson noEvent noBoost test"
  echo "=========================================one key build help============================================"
  echo ""
}

declare need_build_openssl=1
declare need_build_libevent=1
declare need_build_jsoncpp=1
declare need_build_boost=1
declare enable_asan=0
declare enable_lsan=0
declare verbose=1
declare codecov=0
declare debug=0
declare test=0

parse_arguments() {
  for var in "$@"; do
    case "$var" in
    noOpenSSL)
      need_build_openssl=0
      ;;
    noEvent)
      need_build_libevent=0
      ;;
    noJson)
      need_build_jsoncpp=0
      ;;
    noBoost)
      need_build_boost=0
      ;;
    asan)
      enable_asan=1
      ;;
    lsan)
      enable_lsan=1
      ;;
    noVerbose)
      verbose=0
      ;;
    codecov)
      codecov=1
      ;;
    debug)
      debug=1
      ;;
    test)
      test=1
      ;;
    esac
  done
}
parse_arguments $@

PrintParams() {
  echo "###########################################################################"
  if [ $need_build_openssl -eq 0 ]; then
    echo "no need build openssl lib"
  else
    echo "need build openssl lib"
  fi
  if [ $need_build_jsoncpp -eq 0 ]; then
    echo "no need build jsoncpp lib"
  else
    echo "need build jsoncpp lib"
  fi
  if [ $need_build_libevent -eq 0 ]; then
    echo "no need build libevent lib"
  else
    echo "need build libevent lib"
  fi
  if [ $need_build_boost -eq 0 ]; then
    echo "no need build boost lib"
  else
    echo "need build boost lib"
  fi
  if [ $enable_asan -eq 1 ]; then
    echo "enable asan reporting"
  else
    echo "disable asan reporting"
  fi
  if [ $enable_lsan -eq 1 ]; then
    echo "enable lsan reporting"
  else
    echo "disable lsan reporting"
  fi
  if [ $verbose -eq 0 ]; then
    echo "no need print detail logs"
  else
    echo "need print detail logs"
  fi
  if [ $codecov -eq 1 ]; then
    echo "run unit tests with code coverage"
  else
    echo "run unit tests without code coverage"
  fi
  if [ $debug -eq 1 ]; then
    echo "enable debug"
  else
    echo "disable debug"
  fi
  if [ $test -eq 1 ]; then
    echo "build unit tests"
  else
    echo "without build unit tests"
  fi

  echo "###########################################################################"
  echo ""
}

Prepare() {
  if [ -e ${down_dir} ]; then
    echo "${down_dir} exists"
  else
    mkdir -p ${down_dir}
  fi

  cd ${basepath}
  if [ -e ${fname_openssl} ]; then
    mv -f ${basepath}/${fname_openssl} ${down_dir}
  fi

  if [ -e ${fname_libevent} ]; then
    mv -f ${basepath}/${fname_libevent} ${down_dir}
  fi

  if [ -e ${fname_jsoncpp} ]; then
    mv -f ${basepath}/${fname_jsoncpp} ${down_dir}
  fi

  if [ -e ${fname_boost} ]; then
    mv -f ${basepath}/${fname_boost} ${down_dir}
  fi

  if [ -e ${build_dir} ]; then
    echo "${build_dir} exists"
  else
    mkdir -p ${build_dir}
  fi

  if [ -e ${packet_dir} ]; then
    echo "${packet_dir} exists"
  else
    mkdir -p ${packet_dir}
  fi

  if [ -e ${install_lib_dir} ]; then
    echo "${install_lib_dir} exists"
  else
    mkdir -p ${install_lib_dir}
  fi
}

# ===== Retry logic for downloads =====
download_with_retry() {
  local url=$1
  local output=$2
  local max_attempts=3
  local attempt=1

  while [ $attempt -le $max_attempts ]; do
    echo "Download attempt $attempt/$max_attempts: $url"
    if wget --timeout=30 -q "$url" -O "$output" 2>/dev/null; then
      echo "Download successful: $output"
      return 0
    fi
    attempt=$((attempt + 1))
    if [ $attempt -le $max_attempts ]; then
      sleep 5
    fi
  done
  return 1
}

BuildOpenSSL() {
  if [ $need_build_openssl -eq 0 ]; then
    echo "no need build openssl lib"
    return 0
  fi

  cd ${down_dir}
  if [ -e ${fname_openssl} ]; then
    echo "${fname_openssl} exists"
  else
    echo "Downloading OpenSSL..."
    if ! download_with_retry \
      "https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1d/${fname_openssl_down}" \
      "${fname_openssl_down}"; then
      echo "Failed to download from GitHub, trying mirror..."
      download_with_retry \
        "https://www.openssl.org/source/old/1.1.1/${fname_openssl_down}" \
        "${fname_openssl_down}" || exit 1
    fi
  fi

  tar -zxf ${fname_openssl} 2>/dev/null || exit 1

  openssl_dir=$(ls -d openssl-* 2>/dev/null | head -1)
  if [ -z "$openssl_dir" ]; then
    echo "Failed to extract OpenSSL"
    exit 1
  fi

  cd ${openssl_dir}
  echo "Building OpenSSL (this may take a while on ARM64)..."
  
  # Optimize for ARM64 compilation
  local openssl_config_opts="shared CFLAGS=-fPIC CPPFLAGS=-fPIC"
  if [ "$ARCH" = "aarch64" ]; then
    openssl_config_opts="$openssl_config_opts -march=native"
  fi
  
  if [ $verbose -eq 0 ]; then
    ./config $openssl_config_opts --prefix=${install_lib_dir} --openssldir=${install_lib_dir} &> opensslconfig.txt || exit 1
    echo "Compiling OpenSSL without verbose output..."
    make depend &> opensslbuild.txt || exit 1
    make -j $MAX_PARALLEL_JOBS &>> opensslbuild.txt || exit 1
  else
    ./config $openssl_config_opts --prefix=${install_lib_dir} --openssldir=${install_lib_dir} || exit 1
    make depend || exit 1
    make -j $MAX_PARALLEL_JOBS || exit 1
  fi

  make install 2>/dev/null || exit 1
  echo "OpenSSL build complete."
}

BuildLibevent() {
  if [ $need_build_libevent -eq 0 ]; then
    echo "no need build libevent lib"
    return 0
  fi

  cd ${down_dir}
  if [ -e ${fname_libevent} ]; then
    echo "${fname_libevent} exists"
  else
    echo "Downloading libevent..."
    download_with_retry \
      "https://github.com/libevent/libevent/archive/${fname_libevent_down}" \
      "libevent-${fname_libevent_down}" || exit 1
  fi

  unzip -q -o ${fname_libevent} 2>/dev/null || exit 1

  libevent_dir=$(ls -d libevent-* 2>/dev/null | grep -v zip | head -1)
  if [ -z "$libevent_dir" ]; then
    echo "Failed to extract libevent"
    exit 1
  fi

  cd ${libevent_dir}
  ./autogen.sh 2>/dev/null || exit 1

  echo "Building libevent..."
  if [ $verbose -eq 0 ]; then
    ./configure --enable-static=yes --enable-shared=no \
      CFLAGS="-fPIC -I${install_lib_dir}/include" \
      CPPFLAGS="-fPIC -I${install_lib_dir}/include" \
      LDFLAGS="-L${install_lib_dir}/lib" \
      --prefix=${install_lib_dir} &> libeve_config.txt || exit 1
    echo "Compiling libevent without verbose output..."
    make -j $MAX_PARALLEL_JOBS &> libeventbuild.txt || exit 1
  else
    ./configure --enable-static=yes --enable-shared=no \
      CFLAGS="-fPIC -I${install_lib_dir}/include" \
      CPPFLAGS="-fPIC -I${install_lib_dir}/include" \
      LDFLAGS="-L${install_lib_dir}/lib" \
      --prefix=${install_lib_dir} || exit 1
    make -j $MAX_PARALLEL_JOBS || exit 1
  fi

  make install 2>/dev/null || exit 1
  echo "libevent build complete."
}

BuildJsonCPP() {
  if [ $need_build_jsoncpp -eq 0 ]; then
    echo "no need build jsoncpp lib"
    return 0
  fi

  cd ${down_dir}

  if [ -e ${fname_jsoncpp} ]; then
    echo "${fname_jsoncpp} exists"
  else
    echo "Downloading jsoncpp..."
    download_with_retry \
      "https://github.com/open-source-parsers/jsoncpp/archive/${fname_jsoncpp_down}" \
      "jsoncpp-${fname_jsoncpp_down}" || exit 1
  fi

  unzip -q -o ${fname_jsoncpp} 2>/dev/null || exit 1

  jsoncpp_dir=$(ls -d jsoncpp-* 2>/dev/null | grep -v zip | head -1)
  if [ -z "$jsoncpp_dir" ]; then
    echo "Failed to extract jsoncpp"
    exit 1
  fi

  cd ${jsoncpp_dir}
  mkdir -p build
  cd build

  echo "Building jsoncpp..."
  if [ $verbose -eq 0 ]; then
    echo "Compiling jsoncpp without verbose output..."
    cmake .. -DCMAKE_CXX_FLAGS=-fPIC -DBUILD_STATIC_LIBS=ON \
      -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX=${install_lib_dir} &> jsoncppbuild.txt || exit 1
    make -j $MAX_PARALLEL_JOBS &>> jsoncppbuild.txt || exit 1
  else
    cmake .. -DCMAKE_CXX_FLAGS=-fPIC -DBUILD_STATIC_LIBS=ON \
      -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX=${install_lib_dir} || exit 1
    make -j $MAX_PARALLEL_JOBS || exit 1
  fi

  make install 2>/dev/null || exit 1
  echo "jsoncpp build complete."

  if [ ! -f ${install_lib_dir}/lib/libjsoncpp.a ]; then
    echo "Relocating jsoncpp library..."
    if [ -f ${install_lib_dir}/lib/x86_64-linux-gnu/libjsoncpp.a ]; then
      cp ${install_lib_dir}/lib/x86_64-linux-gnu/libjsoncpp.a ${install_lib_dir}/lib/
    elif [ -f ${install_lib_dir}/lib/aarch64-linux-gnu/libjsoncpp.a ]; then
      cp ${install_lib_dir}/lib/aarch64-linux-gnu/libjsoncpp.a ${install_lib_dir}/lib/
    fi
  fi
}

BuildBoost() {
  if [ $need_build_boost -eq 0 ]; then
    echo "no need build boost lib"
    return 0
  fi

  cd ${down_dir}
  if [ -e ${fname_boost} ]; then
    echo "${fname_boost} exists"
  else
    echo "Downloading Boost (this may take a while)..."
    download_with_retry \
      "https://sourceforge.net/projects/boost/files/boost/${fname_boost_down}" \
      "$(basename ${fname_boost_down})" || exit 1
  fi

  tar -zxf ${fname_boost} 2>/dev/null || exit 1

  boost_dir=$(ls -d boost_* 2>/dev/null | head -1)
  if [ -z "$boost_dir" ]; then
    echo "Failed to extract Boost"
    exit 1
  fi

  cd ${boost_dir}
  ./bootstrap.sh 2>/dev/null || exit 1

  echo "Building Boost (this will take considerable time on ARM64)..."
  
  # ARM64 memory-constrained build strategy
  local boost_jobs=$MAX_PARALLEL_JOBS
  if [ "$ARCH" = "aarch64" ] && [ $boost_jobs -gt 2 ]; then
    # Further limit for Boost which is memory-heavy
    boost_jobs=2
  fi

  if [ $verbose -eq 0 ]; then
    echo "Compiling Boost with $boost_jobs parallel jobs..."
    ./b2 -j${boost_jobs} cflags=-fPIC cxxflags=-fPIC \
      --with-atomic --with-thread --with-system --with-chrono \
      --with-date_time --with-log --with-regex --with-serialization \
      --with-filesystem --with-locale --with-iostreams link=static \
      threading=multi variant=release 2>/dev/null || exit 1
  else
    ./b2 -j${boost_jobs} cflags=-fPIC cxxflags=-fPIC \
      --with-atomic --with-thread --with-system --with-chrono \
      --with-date_time --with-log --with-regex --with-serialization \
      --with-filesystem --with-locale --with-iostreams link=static \
      threading=multi variant=release || exit 1
  fi

  echo "Boost build complete."
}

BuildRocketMQClient() {
  cd ${build_dir}
  echo "============start to build rocketmq client cpp.========="

  local ROCKETMQ_CMAKE_FLAG=""

  if [ $test -eq 1 ]; then
    if [ $codecov -eq 1 ]; then
      ROCKETMQ_CMAKE_FLAG=$ROCKETMQ_CMAKE_FLAG" -DRUN_UNIT_TEST=ON -DCODE_COVERAGE=ON"
    else
      ROCKETMQ_CMAKE_FLAG=$ROCKETMQ_CMAKE_FLAG" -DRUN_UNIT_TEST=ON -DCODE_COVERAGE=OFF"
    fi
  else
    ROCKETMQ_CMAKE_FLAG=$ROCKETMQ_CMAKE_FLAG" -DRUN_UNIT_TEST=OFF -DCODE_COVERAGE=OFF"
  fi

  if [ $enable_asan -eq 1 ]; then
    ROCKETMQ_CMAKE_FLAG=$ROCKETMQ_CMAKE_FLAG" -DENABLE_ASAN=ON"
  else
    ROCKETMQ_CMAKE_FLAG=$ROCKETMQ_CMAKE_FLAG" -DENABLE_ASAN=OFF"
  fi

  if [ $enable_lsan -eq 1 ]; then
    ROCKETMQ_CMAKE_FLAG=$ROCKETMQ_CMAKE_FLAG" -DENABLE_LSAN=ON"
  else
    ROCKETMQ_CMAKE_FLAG=$ROCKETMQ_CMAKE_FLAG" -DENABLE_LSAN=OFF"
  fi

  if [ $debug -eq 1 ]; then
    ROCKETMQ_CMAKE_FLAG=$ROCKETMQ_CMAKE_FLAG" -DCMAKE_BUILD_TYPE=Debug"
  else
    ROCKETMQ_CMAKE_FLAG=$ROCKETMQ_CMAKE_FLAG" -DCMAKE_BUILD_TYPE=Release"
  fi

  cmake .. $ROCKETMQ_CMAKE_FLAG || exit 1

  if [ $verbose -eq 0 ]; then
    echo "Building RocketMQ without verbose output..."
    make -j $MAX_PARALLEL_JOBS &> buildclient.txt || exit 1
  else
    make -j $MAX_PARALLEL_JOBS || exit 1
  fi

  echo "RocketMQ client build complete."
  PackageRocketMQStatic
}

BuildGoogleTest() {
  if [ $test -eq 0 ]; then
    echo "no need build google test lib"
    return 0
  fi

  if [ -f ./bin/lib/libgtest.a ]; then
    echo "GTest already exists, no need build"
    return 0
  fi

  cd ${down_dir}
  if [ -e release-1.8.1.tar.gz ]; then
    echo "GTest archive exists"
  else
    echo "Downloading googletest..."
    download_with_retry \
      "https://github.com/abseil/googletest/archive/release-1.8.1.tar.gz" \
      "release-1.8.1.tar.gz" || exit 1
  fi

  if [ ! -d "googletest-release-1.8.1" ]; then
    tar -zxf release-1.8.1.tar.gz 2>/dev/null || exit 1
  fi

  cd googletest-release-1.8.1
  mkdir -p build
  cd build

  echo "Building googletest..."
  if [ $verbose -eq 0 ]; then
    echo "Compiling googletest without verbose output..."
    cmake .. -DCMAKE_CXX_FLAGS=-fPIC -DBUILD_STATIC_LIBS=ON \
      -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX=${install_lib_dir} &> googletestbuild.txt || exit 1
    make -j $MAX_PARALLEL_JOBS &>> googletestbuild.txt || exit 1
  else
    cmake .. -DCMAKE_CXX_FLAGS=-fPIC -DBUILD_STATIC_LIBS=ON \
      -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX=${install_lib_dir} || exit 1
    make -j $MAX_PARALLEL_JOBS || exit 1
  fi

  make install 2>/dev/null || exit 1

  if [ ! -f ${install_lib_dir}/lib/libgtest.a ]; then
    if [ -f ${install_lib_dir}/lib64/libgtest.a ]; then
      cp ${install_lib_dir}/lib64/lib* ${install_lib_dir}/lib/ 2>/dev/null || true
    fi
  fi
  echo "googletest build complete."
}

ExecutionTesting() {
  if [ $test -eq 0 ]; then
    echo "Build success without executing unit tests."
    return 0
  fi

  echo "############# unit test  start  ###########"
  cd ${build_dir}

  if [ $verbose -eq 0 ]; then
    ctest -j $MAX_PARALLEL_JOBS --timeout 300 || exit 1
  else
    ctest -V -j $MAX_PARALLEL_JOBS --timeout 300 || exit 1
  fi

  echo "############# unit test  finish  ###########"
}

PackageRocketMQStatic() {
  echo "############# Start package static rocketmq library. #############"

  if test "$(uname)" = "Linux"; then
    if [ -f ${basepath}/libs/signature/lib/libSignature.a ]; then
      cp -f ${basepath}/libs/signature/lib/libSignature.a ${install_lib_dir}/lib
      ar -M <${basepath}/package_rocketmq.mri 2>/dev/null || true
      if [ -f librocketmq.a ]; then
        cp -f librocketmq.a ${install_lib_dir}
      fi
    fi
  elif test "$(uname)" = "Darwin"; then
    mkdir -p ${static_package_dir}
    cd ${static_package_dir}
    cp -f ${basepath}/libs/signature/lib/libSignature.a . 2>/dev/null || true
    cp -f ${install_lib_dir}/lib/lib*.a . 2>/dev/null || true
    cp -f ${install_lib_dir}/librocketmq.a . 2>/dev/null || true

    echo "Md5 Hash RocketMQ Before:"
    md5sum librocketmq.a 2>/dev/null || true

    local dir=$(ls *.a 2>/dev/null | grep -E 'gtest|gmock' || true)
    for i in $dir; do
      rm -rf "$i"
    done

    libtool -no_warning_for_no_symbols -static -o librocketmq.a *.a 2>/dev/null || true
    echo "Md5 Hash RocketMQ After:"
    md5sum librocketmq.a 2>/dev/null || true

    echo "Try to copy $(pwd)/librocketmq.a to ${install_lib_dir}/"
    cp -f librocketmq.a ${install_lib_dir}/ 2>/dev/null || true
    cd ${basepath}
    rm -rf ${static_package_dir}
  fi

  echo "############# Package static rocketmq library success.#############"
}

# ===== Main execution =====
PrintParams
Prepare
BuildOpenSSL
BuildLibevent
BuildJsonCPP
BuildBoost
BuildGoogleTest
BuildRocketMQClient
ExecutionTesting

echo "========== Build succeeded! =========="
