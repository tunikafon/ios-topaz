#!/usr/bin/env python3
"""List or extract single members of a remote zip (e.g. an IPSW) via HTTP range requests.

  remotezip.py URL                      list members
  remotezip.py URL PATTERN OUTDIR       extract members whose name contains PATTERN

Differences from tools/remotezip.py (the upstream copy):

  * --http1.1: Apple's CDN delivers the same range roughly twice as fast over
    HTTP/1.1 as over HTTP/2 from this host.
  * stalled transfers are detected (--speed-limit/--speed-time) and retried,
    the CDN regularly stops sending for a minute.
  * deflated members are downloaded as the raw deflate stream into a .raw file
    (resumable) and inflated afterwards, so a broken connection does not throw
    away gigabytes of already downloaded data.
  * the members are CRC-32 checked before the file gets its final name.
"""
import os, struct, subprocess, sys, time, zlib

CHUNK = 16 << 20


def curl(*args):
    return subprocess.run(['curl', '-sfL', '--http1.1', '--speed-limit', '50000',
                           '--speed-time', '20', '--max-time', '600', *args],
                          check=True, capture_output=True).stdout


def get(url, start, end, tries=30):
    """Fetch a byte range, retrying while the CDN stalls."""
    last = None
    for attempt in range(tries):
        try:
            data = curl('-r', f'{start}-{end}', url)
        except subprocess.CalledProcessError as e:
            last = e
            time.sleep(min(2 + attempt, 15))
            continue
        if len(data) != end - start + 1:
            last = RuntimeError('bad range reply (%d bytes)' % len(data))
            time.sleep(min(2 + attempt, 15))
            continue
        return data
    raise last if last else RuntimeError('range %d-%d failed' % (start, end))


def size_of(url):
    for line in curl('-I', url).decode().splitlines():
        if line.lower().startswith('content-length:'):
            return int(line.split(':')[1])
    raise RuntimeError('no Content-Length')


def central_dir(url):
    total = size_of(url)
    tail = get(url, max(0, total - 65536 - 22), total - 1)
    eocd = tail.rfind(b'PK\x05\x06')
    assert eocd >= 0, 'no EOCD'
    cd_size, cd_off = struct.unpack_from('<II', tail, eocd + 12)
    loc = tail.rfind(b'PK\x06\x06')	# zip64 EOCD record (IPSWs are >4GB)
    if loc >= 0:
        cd_size, cd_off = struct.unpack_from('<QQ', tail, loc + 40)
    cd = get(url, cd_off, cd_off + cd_size - 1)
    i, out = 0, []
    while i < len(cd) and cd[i:i + 4] == b'PK\x01\x02':
        method, = struct.unpack_from('<H', cd, i + 10)
        crc, csize, usize = struct.unpack_from('<III', cd, i + 16)
        nlen, xlen, clen = struct.unpack_from('<HHH', cd, i + 28)
        lho, = struct.unpack_from('<I', cd, i + 42)
        name = cd[i + 46:i + 46 + nlen].decode()
        extra = cd[i + 46 + nlen:i + 46 + nlen + xlen]
        j = 0
        while j < len(extra):	# zip64 extended info
            hid, hlen = struct.unpack_from('<HH', extra, j)
            if hid == 1:
                vals = list(struct.unpack_from('<%dQ' % (hlen // 8), extra, j + 4))
                if usize == 0xffffffff: usize = vals.pop(0)
                if csize == 0xffffffff: csize = vals.pop(0)
                if lho == 0xffffffff: lho = vals.pop(0)
            j += 4 + hlen
        out.append((name, method, csize, usize, lho, crc))
        i += 46 + nlen + xlen + clen
    return out


def entry_start(url, entry):
    """Byte offset of the member's data inside the zip and its local header."""
    name, method, csize, usize, lho, crc = entry
    hdr = get(url, lho, lho + 29)
    nlen, xlen = struct.unpack_from('<HH', hdr, 26)
    return lho + 30 + nlen + xlen


def crc32_of(path):
    got = 0
    with open(path, 'rb') as f:
        while chunk := f.read(CHUNK):
            got = zlib.crc32(chunk, got)
    return got


def download_stored(url, entry, outdir):
    """Stored member: the range bytes are the file bytes, so it resumes."""
    name, method, csize, usize, lho, crc = entry
    path = os.path.join(outdir, name)
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    if os.path.exists(path) and os.path.getsize(path) == usize:
        print(f'{name}: already complete')
        return path
    start = entry_start(url, entry)
    part = path + '.part'
    done = os.path.getsize(part) if os.path.exists(part) else 0
    with open(part, 'ab' if done else 'wb') as out:
        while done < csize:
            n = min(CHUNK, csize - done)
            data = get(url, start + done, start + done + n - 1)
            out.write(data)
            done += n
            print(f'{name}: {done * 100 // csize}% ({done >> 20} MiB)', flush=True)
    assert os.path.getsize(part) == usize, (name, os.path.getsize(part), usize)
    got = crc32_of(part)
    assert got == crc, f'{name}: CRC-32 {got:08x} != {crc:08x}'
    os.replace(part, path)
    print(f'{name}: {usize} bytes, CRC-32 ok')
    return path


def download_deflated(url, entry, outdir):
    """Deflated member: keep the raw deflate stream (resumable), then inflate."""
    name, method, csize, usize, lho, crc = entry
    path = os.path.join(outdir, name)
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    if os.path.exists(path) and os.path.getsize(path) == usize:
        print(f'{name}: already complete')
        return path
    start = entry_start(url, entry)
    raw = path + '.raw'
    part = raw + '.part'
    done = os.path.getsize(part) if os.path.exists(part) else 0
    with open(part, 'ab' if done else 'wb') as out:
        while done < csize:
            n = min(CHUNK, csize - done)
            data = get(url, start + done, start + done + n - 1)
            out.write(data)
            done += n
            print(f'{name}: {done * 100 // csize}% compressed ({done >> 20} MiB)',
                  flush=True)
    os.replace(part, raw)

    inflate = zlib.decompressobj(-15)
    with open(raw, 'rb') as inp, open(path + '.part', 'wb') as out:
        while chunk := inp.read(CHUNK):
            out.write(inflate.decompress(chunk))
        out.write(inflate.flush())
    assert os.path.getsize(path + '.part') == usize, name
    got = crc32_of(path + '.part')
    assert got == crc, f'{name}: CRC-32 {got:08x} != {crc:08x}'
    os.replace(path + '.part', path)
    os.remove(raw)                      # the compressed copy is not needed any more
    print(f'{name}: {usize} bytes, CRC-32 ok')
    return path


def extract(url, entry, outdir):
    name, method = entry[0], entry[1]
    if method == 0:
        return download_stored(url, entry, outdir)
    if method == 8:
        return download_deflated(url, entry, outdir)
    raise RuntimeError('%s: unsupported compression method %d' % (name, method))


if __name__ == '__main__':
    url = sys.argv[1]
    entries = central_dir(url)
    if len(sys.argv) == 2:
        for e in entries:
            print(f'{e[3]:>12} {e[0]}')
    else:
        for e in entries:
            if sys.argv[2] in e[0]:
                extract(url, e, sys.argv[3])
