#!/bin/bash
set -e
set -x

VERSION=`git rev-parse --short HEAD`
NAME=`basename ${PWD}`

TAG="${NAME}:${VERSION}"
if [ -n "${DOCKER_REPO}" ]; then
    TAG="${DOCKER_REPO}/${TAG}"
fi
docker build -t ${TAG} .

if [ -n "${DOCKER_REPO}" ]; then
    docker push ${TAG}
fi
