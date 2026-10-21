#!/usr/bin/env python3
"""Convert a raw image into an Android sparse image (fastboot format).

  raw2simg.py RAW OUT [--no-punch] [--blk-size N]

Why not img2simg: the HFS+ root is 16 GB with ~9 GB of data, and img2simg
needs the raw image and the sparse image on disk at the same time (~18 GB),
which does not fit next to the IPSW pieces on a small disk.  This converter
streams the raw image into the sparse file and punches holes into the raw
image behind itself (fallocate FALLOC_FL_PUNCH_HOLE), so the peak usage stays
at about the size of the raw image.

The output is the same format img2simg writes (RAW chunks for data, FILL
chunks with zeros for empty blocks) and it is verified twice: the sha256 of
the logical image (raw file with its last block zero-padded) is computed while
converting and recomputed from the finished sparse file; the script fails if
they differ.

Sparse format:
  header: magic 0xed26ff3a, major 1, minor 0, file_hdr_sz 28, chunk_hdr_sz 12,
          blk_sz, total_blks, total_chunks, image_checksum
  chunk:  type (0xCAC1 RAW, 0xCAC2 FILL, 0xCAC3 DONT_CARE), reserved,
          chunk_sz (blocks), total_sz (header + data)
"""
import ctypes
import hashlib
import os
import struct
import sys

SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW = 0xCAC1
CHUNK_FILL = 0xCAC2
CHUNK_DONT_CARE = 0xCAC3
FILE_HDR_SZ = 28
CHUNK_HDR_SZ = 12

FALLOC_FL_KEEP_SIZE = 0x01
FALLOC_FL_PUNCH_HOLE = 0x02

MAX_RAW_BLOCKS = 8192          # 32 MB per RAW chunk
MAX_FILL_BLOCKS = 1 << 24      # 64 GB per FILL chunk

libc = ctypes.CDLL("libc.so.6", use_errno=True)


def punch(fd, offset, length):
    """Free the space of a written region in the source file."""
    if length <= 0:
        return
    rc = libc.fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
                        ctypes.c_longlong(offset), ctypes.c_longlong(length))
    if rc != 0:
        err = ctypes.get_errno()
        raise OSError(err, "fallocate(PUNCH_HOLE) failed at %d" % offset)


def convert(raw_path, out_path, punch_source=True, blk_size=4096):
    raw_size = os.path.getsize(raw_path)
    total_blks = (raw_size + blk_size - 1) // blk_size

    src = os.open(raw_path, os.O_RDWR)   # O_RDWR: the holes are punched behind us
    out = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)

    digest = hashlib.sha256()
    chunks = 0
    pos = FILE_HDR_SZ      # the header is written last, the chunks start here

    def write(b):
        nonlocal pos
        os.pwrite(out, b, pos)
        pos += len(b)

    def emit_fill(nblks, value=b"\0\0\0\0"):
        nonlocal chunks
        write(struct.pack("<HHII", CHUNK_FILL, 0, nblks, CHUNK_HDR_SZ + 4))
        write(value)
        chunks += 1

    def emit_raw(buf):
        nonlocal chunks
        write(struct.pack("<HHII", CHUNK_RAW, 0, len(buf) // blk_size,
                          CHUNK_HDR_SZ + len(buf)))
        write(buf)
        chunks += 1

    fill_run = 0           # zero blocks waiting to be flushed
    raw_buf = bytearray()  # non-zero blocks waiting to be flushed

    def flush_fill():
        nonlocal fill_run
        while fill_run:
            n = min(fill_run, MAX_FILL_BLOCKS)
            emit_fill(n)
            fill_run -= n

    def flush_raw():
        nonlocal raw_buf
        while raw_buf:
            nblk = min(len(raw_buf) // blk_size, MAX_RAW_BLOCKS)
            emit_raw(bytes(raw_buf[:nblk * blk_size]))
            del raw_buf[:nblk * blk_size]

    offset = 0
    try:
        while offset < raw_size:
            want = min(blk_size * 1024, raw_size - offset)
            data = os.pread(src, want, offset)
            if not data:
                break
            view = memoryview(data)
            for i in range(0, len(data), blk_size):
                block = view[i:i + blk_size]
                padded = bytes(block) + b"\0" * (blk_size - len(block))
                digest.update(padded)
                if not any(padded):
                    flush_raw()
                    fill_run += 1
                    if fill_run >= MAX_FILL_BLOCKS:
                        flush_fill()
                else:
                    flush_fill()
                    raw_buf += padded
                    if len(raw_buf) >= blk_size * MAX_RAW_BLOCKS:
                        flush_raw()
            offset += len(data)
            # The bytes are in the sparse file now: free them in the source.
            if punch_source:
                os.fsync(out)
                punch(src, offset - len(data), len(data))
        flush_fill()
        flush_raw()

        # Header last: total_chunks is only known now.
        hdr = struct.pack("<IHHHHIIII", SPARSE_MAGIC, 1, 0, FILE_HDR_SZ,
                          CHUNK_HDR_SZ, blk_size, total_blks, chunks, 0)
        os.pwrite(out, hdr, 0)
        os.fsync(out)
    finally:
        os.close(src)
        os.close(out)

    return digest.hexdigest(), total_blks, chunks


def verify(out_path, blk_size=4096):
    """sha256 of the logical image described by a sparse file."""
    digest = hashlib.sha256()
    with open(out_path, "rb") as f:
        hdr = f.read(FILE_HDR_SZ)
        magic, major, minor, fhdr, chdr, blk, total_blks, total_chunks, _ = \
            struct.unpack("<IHHHHIIII", hdr)
        if magic != SPARSE_MAGIC:
            raise RuntimeError("not a sparse image")
        zero = b"\0" * blk
        for _ in range(total_chunks):
            chdr_bytes = f.read(CHUNK_HDR_SZ)
            if len(chdr_bytes) < CHUNK_HDR_SZ:
                raise RuntimeError("truncated sparse image")
            ctype, _res, chunk_sz, total_sz = struct.unpack("<HHII", chdr_bytes)
            if ctype == CHUNK_RAW:
                data = f.read(total_sz - CHUNK_HDR_SZ)
                if len(data) != total_sz - CHUNK_HDR_SZ:
                    raise RuntimeError("truncated RAW chunk")
                digest.update(data)
            elif ctype == CHUNK_FILL:
                value = f.read(4)
                if len(value) != 4:
                    raise RuntimeError("truncated FILL chunk")
                block = value * (blk_size // 4)
                for _ in range(chunk_sz):
                    digest.update(block)
            elif ctype == CHUNK_DONT_CARE:
                for _ in range(chunk_sz):
                    digest.update(zero)
            else:
                raise RuntimeError("unsupported chunk type 0x%x" % ctype)
        if f.read(1):
            raise RuntimeError("trailing data after the last chunk")
    return digest.hexdigest()


def main():
    args = list(sys.argv[1:])
    punch_source = True
    blk_size = 4096
    if "--no-punch" in args:
        args.remove("--no-punch")
        punch_source = False
    if "--blk-size" in args:
        i = args.index("--blk-size")
        blk_size = int(args[i + 1])
        del args[i:i + 2]
    if len(args) != 2:
        print(__doc__)
        return 2
    raw_path, out_path = args

    sha, total_blks, chunks = convert(raw_path, out_path, punch_source, blk_size)
    print("sparse: %d blocks, %d chunks, %s" % (total_blks, chunks, out_path))
    if punch_source:
        print("verifying...")
        sha2 = verify(out_path, blk_size)
        if sha2 != sha:
            print("MISMATCH: raw=%s sparse=%s" % (sha, sha2), file=sys.stderr)
            return 1
        print("sha256 ok: %s" % sha)
    print("logical size: %d bytes" % (total_blks * blk_size))
    return 0


if __name__ == "__main__":
    sys.exit(main())
