# ffmpeg-vmaf-cuda

ffmpeg build with `libvmaf_cuda` + NVENC/NVDEC for GPU-accelerated AV1 encoding
and CUDA-accelerated VMAF scoring. Built for the FileFlows AV1/VMAF pipeline at
`feldjaeger/fileflows-av1-vmaf`.

## What's inside

| Component         | Version       |
|-------------------|---------------|
| ffmpeg            | `n7.1.1`      |
| libvmaf           | `v3.1.0`      |
| nv-codec-headers  | `n13.0.19.0`  |
| CUDA base image   | `12.6.0`      |
| Ubuntu base       | `24.04`       |

Encoders/decoders enabled: `av1_nvenc`, `hevc_nvenc`, `h264_nvenc`,
`av1_cuvid`, `hevc_cuvid`, `h264_cuvid`, plus libx264, libx265, libsvtav1,
libdav1d, libopus.

Built with `--enable-gpl --enable-version3 --enable-nonfree`. The nonfree
flag is required because `--enable-cuda-nvcc` (closed-source NVIDIA
compiler) is gated on it — without it ffmpeg's configure refuses. libnpp
and libfdk-aac are still omitted; libfdk-aac in particular is unneeded
because audio is always copy-passthrough in the FileFlows pipeline.

NVCC gencode is a single `compute_75` PTX (virtual). At container-start the
NVIDIA driver JIT-compiles the PTX to whatever physical GPU is present, so
this image runs on every Turing-or-newer GPU (sm_75 / Turing through
sm_90 / Hopper, including the RTX 4060 / sm_89 used by the FileFlows host).
The single-virtual-arch form is required because ffmpeg's `configure`
runs `nvcc -ptx` to test cuda_nvcc support, and `-ptx` rejects multiple
gencode targets.

## Pull

```bash
docker pull ghcr.io/feldjaeger/ffmpeg-vmaf-cuda:latest
```

## Usage

Verify the build has the expected filters/encoders:

```bash
docker run --rm --gpus all ghcr.io/feldjaeger/ffmpeg-vmaf-cuda:latest \
    -hide_banner -filters | grep -E 'libvmaf(_cuda)?'
docker run --rm --gpus all ghcr.io/feldjaeger/ffmpeg-vmaf-cuda:latest \
    -hide_banner -encoders | grep nvenc
```

Quick CUDA VMAF score between two files:

```bash
docker run --rm --gpus all -v $PWD:/work -w /work \
    ghcr.io/feldjaeger/ffmpeg-vmaf-cuda:latest \
    -i ref.mkv -i dist.mkv \
    -filter_complex \
      "[0:v]hwupload_cuda[ref];[1:v]hwupload_cuda[dist];\
       [dist][ref]libvmaf_cuda=log_path=vmaf.json:log_fmt=json:n_threads=8" \
    -f null -
```

## Build locally

```bash
docker build -t ffmpeg-vmaf-cuda:dev .
```

Override versions via build args:

```bash
docker build \
    --build-arg FFMPEG_VERSION=n7.1.1 \
    --build-arg VMAF_VERSION=v3.1.0 \
    --build-arg NV_CODEC_VERSION=n13.0.19.0 \
    -t ffmpeg-vmaf-cuda:dev .
```

The build performs in-stage sanity checks — if `libvmaf_cuda` is missing or
`av1_nvenc` is not available, `docker build` fails before the runtime image is
produced.

## CI

`.github/workflows/build.yml` builds and pushes to GHCR on:

- pushes to `main` → `:latest` and `:sha-<short>` tags
- semver tags `v*` → `:vX.Y.Z`, `:X.Y`, `:latest`
- pull requests → build only, no push
- manual `workflow_dispatch`

Disk space on the GH-hosted runner is freed up before the build because the
CUDA dev image plus build artifacts exceed the default ~14 GB free space.

## Integration with FileFlows

See `feldjaeger/fileflows-av1-vmaf` for the recommended volume-mount pattern
that injects this ffmpeg into the FileFlows worker without rebuilding the
FileFlows image.

## License

GPLv3 (x264/x265 + ffmpeg `--enable-gpl --enable-version3`) **plus
nonfree** (`--enable-cuda-nvcc` → ffmpeg's configure refuses without
`--enable-nonfree`). This combination is **not redistributable** under
GPL terms. In practice that means:

- Build the image yourself, or pull from a registry that's effectively
  for personal use.
- Don't ship this image as part of a product or to third parties.
- The Dockerfile and CI workflow themselves are unencumbered — only the
  resulting binary inherits the nonfree restriction.

If license-clean redistribution matters, swap `--enable-cuda-nvcc` for
`--enable-cuda-llvm` (uses Clang instead of nvcc; needs a clang+CUDA
toolchain matrix that compiles cleanly).
