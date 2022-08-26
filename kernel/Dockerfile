FROM library/ubuntu:jammy AS jammy

ARG KERNEL_ARCH=x86_64
ARG KERNEL_VERSION=5.16.60

COPY config /work
COPY scripts /scripts

# Prepare our builder by getting the necessary build dependencies and so on.
ENV DEBIAN_FRONTEND=noninteractive
RUN set -x \
 && apt-get update -y \
 && apt-get install -y wget build-essential fakeroot libelf-dev flex bison bc \
 && rm -f /bin/sh && ln -s /bin/bash /bin/sh

WORKDIR /work

ENV ARCH $KERNEL_ARCH
ENV KERNEL_VERSION $KERNEL_VERSION

CMD ["/scripts/all"]
