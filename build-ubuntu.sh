#!/bin/bash
set -ex

LITE_OPT=false
PGVECTOR_VERSION=0.7.4

while getopts "v:i:g:o:e:l" opt; do
    case $opt in
    v) PG_VERSION=$OPTARG ;;
    o) DOCKER_OPTS=$OPTARG ;;
    e) PGVECTOR_VERSION=$OPTARG ;;
    l) LITE_OPT=true ;;
    \?) exit 1 ;;
    esac
done

if [ -z "$PG_VERSION" ] ; then
  echo "Postgres version parameter is required!" && exit 1;
fi
if echo "$PG_VERSION" | grep -q '^9\.' && [ "$LITE_OPT" = true ] ; then
  echo "Lite option is supported only for PostgreSQL 10 or later!" && exit 1;
fi

ICU_ENABLED=$(echo "$PG_VERSION" | grep -qv '^9\.' && [ "$LITE_OPT" != true ] && echo true || echo false);

TRG_DIR=$PWD/bundle
mkdir -p $TRG_DIR

echo "Starting building postgres binaries"
ln -snf /usr/share/zoneinfo/Etc/UTC /etc/localtime && echo "Etc/UTC" > /etc/timezone
apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    bzip2 \
    xz-utils \
    gcc \
    g++ \
    make \
    curl

wget -O postgresql.tar.bz2 "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2"
mkdir -p /usr/src/postgresql
tar -xf postgresql.tar.bz2 -C /usr/src/postgresql --strip-components 1
cd /usr/src/postgresql
./configure \
    --prefix=/usr/local/pg-build \
    --without-readline \
    --without-zlib
make -j$(nproc) world
make install-world
make -C contrib install

mkdir -p /usr/include/postgresql/internal/
cp -r /usr/src/postgresql/src/include/. /usr/include/postgresql/internal
ls /usr/include/postgresql/internal
find / -name "pg_config_os.h" -print

mkdir -p /usr/src/pgvector
curl -sL "https://github.com/pgvector/pgvector/archive/refs/tags/v$PGVECTOR_VERSION.tar.gz" | tar -xzf - -C /usr/src/pgvector --strip-components 1
cd /usr/src/pgvector
make -j$(nproc)
PG_CONFIG=/usr/local/pg-build/bin/pg_config make install

cd /usr/local/pg-build \
cp /usr/lib/libossp-uuid.so.16 ./lib || cp /usr/lib/*/libossp-uuid.so.16 ./lib
cp /lib/*/libz.so.1 /lib/*/liblzma.so.5 /usr/lib/*/libxml2.so.2 /usr/lib/*/libxslt.so.1 ./lib
cp /lib/*/libssl.so.1* /lib/*/libcrypto.so.1* ./lib || cp /usr/lib/*/libssl.so.1* /usr/lib/*/libcrypto.so.1* ./lib
if [ "$ICU_ENABLED" = true ]; then cp --no-dereference /usr/lib/*/libicudata.so* /usr/lib/*/libicuuc.so* /usr/lib/*/libicui18n.so* ./lib; fi
find ./bin -type f \( -name "initdb" -o -name "pg_ctl" -o -name "postgres" \) -print0 | xargs -0 -n1 patchelf --set-rpath "\$ORIGIN/../lib"
find ./lib -maxdepth 1 -type f -name "*.so*" -print0 | xargs -0 -n1 patchelf --set-rpath "\$ORIGIN"
find ./lib/postgresql -maxdepth 1 -type f -name "*.so*" -print0 | xargs -0 -n1 patchelf --set-rpath "\$ORIGIN/.."
tar -cJvf /usr/local/pg-dist/postgres-linux-debian.txz --hard-dereference \
    share/postgresql \
    lib \
    bin/initdb \
    bin/pg_ctl \
    bin/postgres
