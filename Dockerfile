FROM levischuck/janet-sdk as builder

COPY project.janet /image-processor/
WORKDIR /image-processor/
RUN jpm deps
COPY . /image-processor/
RUN jpm build

FROM cendyne/image-converting as app
RUN apk add --no-cache curl
COPY --from=builder /image-processor/build/image-processor /usr/local/bin/
WORKDIR /opt/
CMD ["image-processor"]
