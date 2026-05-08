# syntax=docker/dockerfile:1.7
#
# Multi-stage build for ffmpeg with libvmaf_cuda + NVENC/NVDEC.
#
# Licensing: GPL + nonfree. --enable-cuda-nvcc requires --enable-nonfree
# because nvcc is closed-source. The resulting binary may NOT be
# redistributed under GPL terms. Build it yourself or pull from a
# private/personal-use registry.
#
# libfdk-aac is still omitted — audio is always copied in the FileFlows
# pipeline, so we don't need an additional nonfree audio encoder.

ARG CUDA_VERSION=12.6.0
ARG UBUNTU_VERSION=24.04

############################################################
# Stage 1: build
############################################################
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS build

ARG FFMPEG_VERSION=n7.1.1
ARG VMAF_VERSION=v3.0.0
ARG NV_CODEC_VERSION=n12.2.72.0
# Single PTX-virtual gencode: ffmpeg's configure runs `nvcc -ptx ...` to test
# cuda_nvcc support, and -ptx is incompatible with multiple gencode targets
# ("nvcc fatal: '--ptx' is not allowed when compiling for multiple GPU architectures").
# compute_75 PTX JIT-compiles at runtime to any GPU >= Turing — covers RTX 4060
# (sm_89) and beyond.
ARG NVCC_GENCODE="-gencode arch=compute_75,code=compute_75"

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/usr/local/cuda/bin:${PATH}"
ENV PKG_CONFIG_PATH="/usr/local/lib/pkgconfig"

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates curl pkg-config build-essential \
        nasm yasm cmake meson ninja-build python3 python3-pip xxd \
        libx264-dev libx265-dev libsvtav1-dev libsvtav1enc-dev \
        libopus-dev libdav1d-dev libnuma-dev libssl-dev \
        libtool autoconf automake \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# The CUDA stubs dir ships libcuda.so but not the libcuda.so.1 soname that
# downstream libraries (libvmaf with CUDA backend) record in DT_NEEDED.
# Without this symlink, ld can't resolve transitive deps when ffmpeg's
# configure links a test binary against libvmaf -> "undefined reference to
# cuModuleLoadData" etc., which surfaces as a misleading
# "libvmaf >= 2.0.0 not found using pkg-config" error.
#
# The stub satisfies the link only — at runtime the host driver provides
# the real libcuda.so.1 via the NVIDIA Container Runtime.
#
# Companion change: ffmpeg's --extra-ldflags also needs
# `-Wl,-rpath-link,/usr/local/cuda/lib64/stubs`. Plain `-L` paths are NOT
# searched by ld for DT_NEEDED transitive lookup — only -rpath-link is.
RUN ln -sf libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1

# NVENC/NVDEC headers
RUN git clone --depth 1 --branch ${NV_CODEC_VERSION} \
        https://github.com/FFmpeg/nv-codec-headers.git \
    && make -C nv-codec-headers PREFIX=/usr/local install

# libvmaf with CUDA backend
RUN git clone --depth 1 --branch ${VMAF_VERSION} \
        https://github.com/Netflix/vmaf.git \
    && cd vmaf/libvmaf \
    && meson setup build \
            --buildtype=release \
            --prefix=/usr/local \
            --libdir=lib \
            -Denable_cuda=true \
            -Denable_avx512=true \
            -Denable_float=true \
            -Dbuilt_in_models=true \
    && ninja -vC build \
    && ninja -C build install \
    && ldconfig

# Ship VMAF models on disk too (libvmaf has built-in models, but path-loaded
# variants are useful for benchmarking custom models).
RUN mkdir -p /usr/local/share/vmaf/model \
    && cp -r /src/vmaf/model/* /usr/local/share/vmaf/model/

# ffmpeg
#
# Diagnostic: pkg-config sanity-check libvmaf BEFORE ffmpeg configure.
# Then on configure failure we dump the relevant tail of ffbuild/config.log
# so CI logs show the actual link error instead of the misleading
# "libvmaf >= 2.0.0 not found using pkg-config".
RUN git clone --depth 1 --branch ${FFMPEG_VERSION} \
        https://github.com/FFmpeg/FFmpeg.git ffmpeg \
    && cd ffmpeg \
    && echo "=== pkg-config probe ===" \
    && pkg-config --exists --print-errors 'libvmaf >= 2.0.0' \
    && echo "libvmaf cflags: $(pkg-config --cflags libvmaf)" \
    && echo "libvmaf libs:   $(pkg-config --libs libvmaf)" \
    && echo "libvmaf libs.private: $(pkg-config --libs --static libvmaf)" \
    && ls -l /usr/local/cuda/lib64/stubs/ \
    && (./configure \
            --prefix=/opt/ffmpeg \
            --extra-cflags="-I/usr/local/cuda/include -I/usr/local/include" \
            --extra-ldflags="-L/usr/local/cuda/lib64 -L/usr/local/cuda/lib64/stubs -L/usr/local/lib -Wl,-rpath-link,/usr/local/cuda/lib64/stubs -Wl,-rpath,/opt/ffmpeg/lib:/usr/local/lib" \
            --enable-gpl \
            --enable-version3 \
            --enable-nonfree \
            --enable-libvmaf \
            --enable-cuda-nvcc \
            --enable-cuvid \
            --enable-nvenc \
            --enable-nvdec \
            --enable-libx264 \
            --enable-libx265 \
            --enable-libsvtav1 \
            --enable-libdav1d \
            --enable-libopus \
            --nvccflags="${NVCC_GENCODE}" \
        || (echo "=== ffbuild/config.log (last 250 lines) ==="; \
            tail -n 250 ffbuild/config.log; \
            exit 1)) \
    && make -j"$(nproc)" \
    && make install

# Sanity checks inside build stage — fail the build if features missing.
RUN set -eux; \
    /opt/ffmpeg/bin/ffmpeg -hide_banner -filters | grep -E '\blibvmaf\b'; \
    /opt/ffmpeg/bin/ffmpeg -hide_banner -filters | grep -E '\blibvmaf_cuda\b'; \
    /opt/ffmpeg/bin/ffmpeg -hide_banner -encoders | grep -q av1_nvenc; \
    /opt/ffmpeg/bin/ffmpeg -hide_banner -encoders | grep -q hevc_nvenc

############################################################
# Stage 2: runtime
############################################################
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION} AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility,video

# Install runtime variants of the codec libs ffmpeg was linked against.
# Using -dev packages here keeps the image robust across Ubuntu point releases
# (runtime soname suffixes change between LTS revisions). ~40MB overhead is fine.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libx264-dev libx265-dev libsvtav1-dev libsvtav1enc-dev \
        libdav1d-dev libopus-dev libnuma1 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ffmpeg/ffprobe binaries
COPY --from=build /opt/ffmpeg/bin/ffmpeg  /usr/local/bin/ffmpeg
COPY --from=build /opt/ffmpeg/bin/ffprobe /usr/local/bin/ffprobe

# libvmaf shared library + VMAF models on disk
COPY --from=build /usr/local/lib/libvmaf.so* /usr/local/lib/
COPY --from=build /usr/local/share/vmaf /usr/local/share/vmaf

RUN ldconfig

ENV PATH="/usr/local/bin:${PATH}"
# libcuda.so / libnvidia-* come from the host driver via the NVIDIA Container Runtime.

LABEL org.opencontainers.image.source="https://github.com/feldjaeger/ffmpeg-vmaf-cuda"
LABEL org.opencontainers.image.description="ffmpeg with libvmaf_cuda + NVENC, GPL build"
LABEL org.opencontainers.image.licenses="GPL-3.0-or-later AND LicenseRef-ffmpeg-nonfree"

ENTRYPOINT ["/usr/local/bin/ffmpeg"]
CMD ["-version"]
