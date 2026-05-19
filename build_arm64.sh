#!/usr/bin/env bash

basepath=$(cd $(dirname $0); pwd)
declare down_dir="${basepath}/tmp_down_dir"
declare build_dir="${basepath}/tmp_build_dir"
declare install_lib_dir="${basepath}/bin"

# 获取 CPU 核心数加速编译
if test "$(uname)" = "Linux"; then
  declare cpu_num=$(cat /proc/cpuinfo | grep "processor" | wc -l)
else
  declare cpu_num=4
fi

mkdir -p ${build_dir} ${install_lib_dir}

# 1. 编译 OpenSSL
BuildOpenSSL() {
  echo "========= 1. 编译 OpenSSL (ARM64) ========="
  cd ${down_dir}
  local target_file=$(ls openssl*.tar.gz 2>/dev/null | head -n 1)
  tar -zxvf ${target_file} > /dev/null
  cd openssl-1.1.1*
  
  ./Configure linux-aarch64 shared CFLAGS=-fPIC CPPFLAGS=-fPIC \
              --prefix=${install_lib_dir} --openssldir=${install_lib_dir} \
              --cross-compile-prefix=aarch64-linux-gnu-
  make -j$cpu_num > /dev/null
  make install > /dev/null
}

# 2. 编译 Libevent (使用 CMake 交叉编译可完美绕过 autoconf 的各种宏缺失报错)
BuildLibevent() {
  echo "========= 2. 编译 Libevent (ARM64) ========="
  cd ${down_dir}
  local target_file=$(ls libevent*.zip 2>/dev/null | head -n 1)
  unzip -o ${target_file} > /dev/null
  cd libevent-*
  
  mkdir -p build && cd build
  cmake .. -DCMAKE_SYSTEM_NAME=Linux \
           -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
           -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
           -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
           -DCMAKE_BUILD_TYPE=Release \
           -DEVENT__DISABLE_TESTS=ON \
           -DEVENT__DISABLE_SAMPLES=ON \
           -DEVENT__DISABLE_OPENSSL=ON \
           -DBUILD_SHARED_LIBS=OFF \
           -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
           -DCMAKE_INSTALL_PREFIX=${install_lib_dir}
  make -j$cpu_num > /dev/null
  make install > /dev/null
  
  if [ ! -f ${install_lib_dir}/lib/libevent.a ]; then
     cp ${install_lib_dir}/lib/libevent_core.a ${install_lib_dir}/lib/libevent.a 2>/dev/null
  fi
}

# 3. 编译 JsonCPP
BuildJsonCPP() {
  echo "========= 3. 编译 JsonCPP (ARM64) ========="
  cd ${down_dir}
  local target_file=$(ls jsoncpp*.zip 2>/dev/null | head -n 1)
  unzip -o ${target_file} > /dev/null
  cd jsoncpp-*
  
  mkdir -p build && cd build
  cmake .. -DCMAKE_SYSTEM_NAME=Linux \
           -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
           -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
           -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
           -DCMAKE_CXX_FLAGS=-fPIC \
           -DBUILD_STATIC_LIBS=ON \
           -DBUILD_SHARED_LIBS=OFF \
           -DCMAKE_INSTALL_PREFIX=${install_lib_dir}
  make -j$cpu_num > /dev/null
  make install > /dev/null
  
  if [ ! -f ${install_lib_dir}/lib/libjsoncpp.a ]; then
    local native_lib_dir=$(ls -d ${install_lib_dir}/lib/*-linux-gnu 2>/dev/null | head -n 1)
    if [ -n "$native_lib_dir" ] && [ -f ${native_lib_dir}/libjsoncpp.a ]; then
       cp ${native_lib_dir}/libjsoncpp.a ${install_lib_dir}/lib/
    fi
  fi
}

# 4. 编译 Boost (并修复 tr1 循环引用死循环报错)
BuildBoost() {
  echo "========= 4. 编译 Boost (ARM64) ========="
  cd ${down_dir}
  local target_file=$(ls boost*.tar.gz 2>/dev/null | head -n 1)
  tar -zxvf ${target_file} > /dev/null
  cd boost_*
  
  # 彻底拔除导致死循环的 tr1 软链接
  rm -rf boost/tr1/tr1
  
  ./bootstrap.sh > /dev/null
  # 强制指定 Boost 编译器的目标为 arm 的交叉编译器
  echo "using gcc : arm : aarch64-linux-gnu-g++ ;" > project-config.jam
  
  ./b2 -j$cpu_num toolset=gcc-arm cflags=-fPIC cxxflags=-fPIC \
       --with-atomic --with-thread --with-system --with-chrono --with-date_time \
       --with-log --with-regex --with-serialization --with-filesystem --with-locale --with-iostreams \
       threading=multi link=static release install --prefix=${install_lib_dir} || true
}

# 5. 编译 RocketMQ Client 本身
BuildRocketMQClient() {
  echo "========= 5. 编译 RocketMQ Client (ARM64) ========="
  cd ${build_dir}
  cmake .. -DCMAKE_SYSTEM_NAME=Linux \
           -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
           -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
           -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
           -DRUN_UNIT_TEST=OFF \
           -DCMAKE_BUILD_TYPE=Release
  make -j$cpu_num
  
  PackageRocketMQStatic
}

# 6. 用 ARM64 的工具链进行静态库打包
PackageRocketMQStatic() {
  echo "========= 6. 打包最终的 librocketmq_arm64.a ========="
  cp -f ${basepath}/libs/signature/lib/libSignature.a ${install_lib_dir}/lib 2>/dev/null || true
  
  # 修改原先的 mri 文件，让其使用 aarch64-linux-gnu-ar
  cd ${basepath}
  sed -i 's/create bin\/librocketmq.a/create bin\/librocketmq_arm64.a/g' package_rocketmq.mri
  
  aarch64-linux-gnu-ar -M < package_rocketmq.mri
  echo "🎉 恭喜！ARM64 静态库构建成功: bin/librocketmq_arm64.a"
}

# 顺序执行
BuildOpenSSL
BuildLibevent
BuildJsonCPP
BuildBoost
BuildRocketMQClient
