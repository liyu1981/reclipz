# reclipz container image (musl/Alpine flavour).
#
# The engine payloads (yt-dlp + ffmpeg/ffprobe) are compiled into the binary. Build the binary
# first, for a musl target (the Alpine base provides the musl loader that the official
# `yt-dlp_musllinux` payload needs):
#
#   tools/fetch_payloads.sh --asset yt-dlp_musllinux --out payload
#   tools/make_ffmpeg.sh --target x86_64-linux-musl --out payload
#   zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall
#   docker build -t reclipz .
#
# For a glibc flavour use `debian:stable-slim` (or distroless/cc) with `x86_64-linux-gnu`
# and the `yt-dlp_linux` payload instead.
FROM alpine:3

# Run as an unprivileged user so bind-mounted download/cache dirs are not owned by root.
RUN adduser -D -u 1000 -h /home/reclipz reclipz \
 && mkdir -p /downloads /cache \
 && chown -R reclipz:reclipz /downloads /cache /home/reclipz

COPY zig-out/bin/reclipz /usr/local/bin/reclipz

# Fail the image build early if the binary cannot run on this base image (libc mismatch).
RUN /usr/local/bin/reclipz --help >/dev/null

# The engine (a PyInstaller binary) needs a writable TMPDIR; we point it at the cache volume.
# HOME is set so yt-dlp's config/cache lookups stay inside the volume too.
ENV HOST=0.0.0.0 \
    PORT=8899 \
    RECLIPZ_DOWNLOAD_DIR=/downloads \
    RECLIPZ_CACHE_DIR=/cache \
    HOME=/cache \
    RECLIPZ_LOG=info

USER reclipz

VOLUME ["/downloads", "/cache"]
EXPOSE 8899

ENTRYPOINT ["/usr/local/bin/reclipz"]
CMD ["serve"]
