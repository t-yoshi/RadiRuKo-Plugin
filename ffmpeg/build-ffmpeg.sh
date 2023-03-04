#!/usr/bin/env bash
set -e

# WORKSPACE_DIR: 
# INSTALL_DIR: ffmpeg_binのインストール先
# CC: クロスコンパイラ

SCRIPT_DIR=$(cd $(dirname $0); pwd)
WORKSPACE_DIR=${WORKSPACE_DIR:-$HOME/ffbuild}
BUILD_DIR=$WORKSPACE_DIR/build
SOURCE_DIR=$WORKSPACE_DIR/src
PATCH_DIR=$SCRIPT_DIR/patch

[ -d $BUILD_DIR ] || mkdir -p $BUILD_DIR
[ -d $SOURCE_DIR ] || mkdir $SOURCE_DIR

export MAKEFLAGS=-j$(nproc 2>/dev/null || echo 2)


ff_enable_encoder=pcm_s16le
ff_enable_decoder=wmav1,wmav2,aac,mp3,wav,opus,pcm_s16le
ff_enable_parser=aac,mpegaudio,opus 
ff_enable_demuxer=dash,xwma,rtsp,mpegts,aac,mp3,wav,pcm_s16le,hls,ogg
ff_enable_protocol=http,https,mmsh,mmst,hls,file,pipe,crypto
ff_enable_filter=aresample
ff_enable_muxer=mpegts,adts,wav,pcm_s16le 
ff_options="--disable-everything --disable-iconv --disable-xlib --disable-bzlib --enable-mbedtls --enable-libxml2 "


function _die(){
  echo $*
  exit 255
}

function _fetch_source() {
  local u=$1
  local d=${u##*/}; d=${d%.git}
  echo "url=$u, dir=$d"

  cd $SOURCE_DIR

  [ -d $d ] || git clone $u
  cd $d
  local r=$2
  [ "$r" = "" ] && r="HEAD"

  git fetch origin
  git checkout $r
  git clean -dfX
  git checkout .
}

function _mk_and_enter_dir {
  local d=$1
  [ -n "$d" ] || _die empty dirname
  [ -d $d ] || mkdir -p $d  
  cd $d
}

function build_zlib () {
  _mk_and_enter_dir $TARGET_BUILD_DIR/zlib

  $SOURCE_DIR/zlib/configure --static --prefix=$TARGET_LIB_PREFIX  
  make install 
}

function build_libxml2 () {
  _mk_and_enter_dir $TARGET_BUILD_DIR/libxml2

  cmake --fresh -S $SOURCE_DIR/libxml2 -B . \
    -D BUILD_SHARED_LIBS=OFF \
    -D CMAKE_BUILD_TYPE=Release \
    -D CMAKE_INSTALL_PREFIX=$TARGET_LIB_PREFIX \
    -D LIBXML2_WITH_ICONV=OFF \
    -D LIBXML2_WITH_LZMA=OFF \
    -D LIBXML2_WITH_PYTHON=OFF \
    -D LIBXML2_WITH_ZLIB=ON \
    -D LIBXML2_WITH_PROGRAMS=OFF -D LIBXML2_WITH_TESTS=OFF 
  cmake --build .
  cmake --install . 
  
  if [[ $TARGET_TRIPLE == *mingw* ]]; then
    perl -p -i.bak -e '
s/^Libs.private:/Libs.private: -lws2_32 -lwsock32/;
'  $TARGET_LIB_PREFIX/lib/pkgconfig/libxml-2.0.pc
   cat $TARGET_LIB_PREFIX/lib/pkgconfig/libxml-2.0.pc  
  fi

#  $SOURCE_DIR/libxml2/autogen.sh \
#    --prefix=$TARGET_LIB_PREFIX --host $TARGET_TRIPLE \
#     --without-python --without-zlib --disable-shared
#  make V=1 install 
}


function build_mbedtls () {
	cd $SOURCE_DIR/mbedtls

  local ldflags
  [[ $TARGET_TRIPLE == *mingw* ]] && ldflags="-lws2_32"

  _mk_and_enter_dir $TARGET_BUILD_DIR/mbedtls   
  #clear cmake cache
  #find . -iname '*cmake*' -not -name CMakeLists.txt -exec rm -rf {} +

  cmake --fresh -DENABLE_TESTING=Off -DENABLE_PROGRAMS=Off \
         -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
         -DCMAKE_INSTALL_PREFIX=$TARGET_LIB_PREFIX \
     $SOURCE_DIR/mbedtls 

  cmake --build . --target install 

  local pkgconfig_dir=$TARGET_LIB_PREFIX/lib/pkgconfig
  [ -d $pkgconfig_dir ] || mkdir -p $pkgconfig_dir
  echo "
prefix=$TARGET_LIB_PREFIX 
Name: mbedtls
Description: The mbedtls library
Version: 2.28.0
Cflags: -I\${prefix}/include
Libs: -L\${prefix}/lib -lmbedx509 -lmbedtls -lmbedcrypto
" > $pkgconfig_dir/mbedtls.pc
}

function build_ffmpeg (){
  _mk_and_enter_dir $TARGET_BUILD_DIR/ffmpeg

  local ffopts="--prefix=/ --enable-gpl --enable-version3 \
    --enable-nonfree $ff_options \
    --enable-encoder=$ff_enable_encoder \
    --enable-decoder=$ff_enable_decoder \
    --enable-parser=$ff_enable_parser --enable-demuxer=$ff_enable_demuxer \
    --enable-protocol=$ff_enable_protocol --enable-filter=$ff_enable_filter \
    --enable-muxer=$ff_enable_muxer --disable-doc \
     "
  
  if [ $BUILD_TYPE = native ]; then
    if [ $(uname) = Darwin ]; then
      ffopts+="--disable-appkit --disable-avfoundation --disable-coreimage \
        --disable-audiotoolbox --disable-videotoolbox --disable-metal \
        --pkg-config-flags=--static "
      local no_apple_foundations=1
    fi
  else
    ffopts+="--extra-ldflags=-static --pkg-config-flags=--static --enable-cross-compile --cross-prefix=$TARGET_TRIPLE- "

    if [[ $TARGET_TRIPLE == *mingw* ]]; then
        ffopts+="--target-os=win32 --enable-w32threads "
      else 
        ffopts+="--target-os=linux "
    fi

    case $TARGET_TRIPLE in 
        x86_64-*)
          ffopts+="--arch=x86_64 ";;
        i686-*)  
          ffopts+="--arch=x86 ";;
        arm-*eabi)
          ffopts+="--arch=arm --disable-vfp --disable-armv6 --disable-armv6t2 ";;  
        arm-*eabihf)
          ffopts+="--arch=arm ";;  
        aarch64-*linux-*)
          ffopts+="--arch=aarch64 ";;  
    esac  

    ffopts+="--cc=$CC "
    pkg-config libxml-2.0 --cflags #--list-all
  fi

  echo ffopts: $ffopts

  $SOURCE_DIR/FFmpeg/configure $ffopts || (
      tail -100 ffbuild/config.log
      _die "== Dumped ffbuild/config.log =="
    )

  if [ "$no_apple_foundations" = 1 ]; then
    perl -p -i.bak -e '
s/-framework Core\w+//g if (/^EXTRALIBS/);
'  ffbuild/config.mak
  fi

  make DESTDIR=$TARGET_LIB_PREFIX all install

  if [ -d "$INSTALL_DIR" ]; then
    cd $TARGET_LIB_PREFIX/bin/
    local src dest
    src=$(find . -name ffmpeg -o -name ffmpeg.exe)
    dest=$INSTALL_DIR/${src/ffmpeg/ffmpeg_bin}
    echo "Install $src to $dest"
    cp $src $dest || _die "Install failed."
  fi
}

function fetch_sources () {
  _fetch_source https://github.com/ARMmbed/mbedtls.git v3.2.1 
  _fetch_source https://github.com/FFmpeg/FFmpeg.git n5.1.2 
  _fetch_source https://github.com/madler/zlib.git     
  _fetch_source https://github.com/GNOME/libxml2.git

  cd $SOURCE_DIR/FFmpeg
  cat $PATCH_DIR/hls-retry.patch | patch -u -p0
  cd -
}


if [ "$CC" = "" ]; then
  export CC=cc LD=ld AR=ar STRIP=strip
  BUILD_TYPE=native
  TARGET_TRIPLE=$($CC -dumpmachine)
else
  BUILD_TYPE=cross
  TARGET_TRIPLE=$($CC -dumpmachine)
  export CC LD=$TARGET_TRIPLE-ld \
    AR=$TARGET_TRIPLE-ar \
    STRIP=$TARGET_TRIPLE-strip
fi

for c in $CC $LD $AR $STRIP nasm pkg-config cmake; do
  whereis $c >/dev/null
done

TARGET_LIB_PREFIX=$WORKSPACE_DIR/$TARGET_TRIPLE
TARGET_BUILD_DIR=$WORKSPACE_DIR/build/$TARGET_TRIPLE

if [ $BUILD_TYPE = native ]; then
  export PKG_CONFIG_PATH=$TARGET_LIB_PREFIX/lib/pkgconfig  
else
  _mk_and_enter_dir $TARGET_LIB_PREFIX/bin/
  (
    echo "PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1 \\"
    echo "PKG_CONFIG_ALLOW_SYSTEM_LIBS=1 \\"
    echo "PKG_CONFIG_PATH=$TARGET_LIB_PREFIX/lib/pkgconfig \\"
    echo "exec /usr/bin/pkg-config \$*"
  ) > $TARGET_TRIPLE-pkg-config
  chmod +x $TARGET_TRIPLE-pkg-config
  ln -sf $TARGET_TRIPLE-pkg-config pkg-config
  cd -
  export PATH=$TARGET_LIB_PREFIX/bin:$PATH
fi

echo "Build for $TARGET_TRIPLE ($BUILD_TYPE)"

fetch_sources
build_zlib
build_libxml2
build_mbedtls
build_ffmpeg
