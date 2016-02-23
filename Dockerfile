FROM debian:jessie

ENV OPENRESTY_VERSION 1.9.7.3
ENV OPENRESTY_PREFIX /opt/openresty
ENV NGINX_PREFIX /opt/openresty/nginx
ENV VAR_PREFIX /var/openresty

RUN apt-get update && \
    apt-get install -y curl bash jq build-essential git-core libpcre3-dev libssl-dev zlib1g-dev

RUN  mkdir -p /root/openresty && \
    cd /root/openresty && \
    git clone https://github.com/zebrafishlabs/nginx-statsd.git && \
    curl -sSL http://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz | tar -xvz

RUN cd /root/openresty/openresty-${OPENRESTY_VERSION} \
 && readonly NPROC=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || 1) \
 && ./configure \
    --prefix=$OPENRESTY_PREFIX \
    --http-client-body-temp-path=$VAR_PREFIX/client_body_temp \
    --http-proxy-temp-path=$VAR_PREFIX/proxy_temp \
    --http-log-path=$VAR_PREFIX/access.log \
    --error-log-path=$VAR_PREFIX/error.log \
    --pid-path=$VAR_PREFIX/nginx.pid \
    --lock-path=$VAR_PREFIX/nginx.lock \
    --with-luajit \
    --with-pcre-jit \
    --with-ipv6 \
    --with-http_ssl_module \
    --with-http_realip_module \
    --with-http_stub_status_module \
    --without-http_ssi_module \
    --without-http_userid_module \
    --without-http_fastcgi_module \
    --without-http_uwsgi_module \
    --without-http_scgi_module \
    --without-http_memcached_module \
    --add-module=/root/openresty/nginx-statsd \
    -j${NPROC} \
 && make -j${NPROC} \
 && make install

RUN cd /tmp && \
    curl -L -O https://storage.googleapis.com/kubernetes-release/release/v1.1.2/bin/linux/amd64/kubectl && \
    mv kubectl /usr/bin/ && \
    chmod 0555 /usr/bin/kubectl && \
    mkdir -p /app/lib/resty

RUN apt-get install -y --no-install-recommends dnsutils

COPY *.lua start nginx.conf /app/
COPY vendor/lua-resty-dns-cache/lib/resty/ vendor/lua-resty-http/lib/resty/ /app/lib/resty/

