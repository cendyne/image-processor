PLATFORMS="linux/amd64,linux/386,linux/arm64,linux/arm/v7,linux/arm/v6"

if [ -z "$GITHUB_SHA" ]; then
echo "Guessing GITHUB_SHA"
GITHUB_SHA=$(git rev-parse HEAD)
fi

if [ -z "$DOCKER_REPO" ]; then
DOCKER_REPO="cendyne/image-processor"
echo "Guessing $DOCKER_REPO"
fi

DATE=$(date '+%Y-%m-%dT%H:%M:%S')

if [ -z "$DOCKER_PASSWORD" ]; then
echo "Assuming docker is logged in, DOCKER_PASSWORD missing"
else
if [ -z "$DOCKER_USER" ]; then
DOCKER_USER="cendyne"
echo "Guessing user is cendyne"
fi
echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USER" --password-stdin
fi

docker buildx build --platform "$PLATFORMS" . \
        --target=app \
        --tag "$DOCKER_REPO:latest" \
        --tag "$DOCKER_REPO:${GITHUB_SHA:0:7}"
        --label "org.opencontainers.image.revision=$GITHUB_SHA" \
        --label "org.opencontainers.image.created=$DATE" \
        --label "org.opencontainers.image.source=https://github.com/cendyne/image-processor" \
        --push
