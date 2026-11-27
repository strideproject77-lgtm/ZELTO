DEFAULT_CHUNK_BYTES = 4 * 1024 * 1024
MAX_CHUNK_BYTES = 5 * 1024 * 1024

def split_log(name, data, chunk_bytes=DEFAULT_CHUNK_BYTES):
    if not name or "/" in name or "\\" in name:
        raise ValueError("name must be a plain filename")
    if not isinstance(data, bytes):
        raise TypeError("data must be bytes")
    if not 1 <= chunk_bytes <= MAX_CHUNK_BYTES:
        raise ValueError("chunk size must be between 1 byte and 5 MiB")
    return [
        (("latest/" + name) if i == 1 else ("latest/" + name + ".part%03d" % i),
         data[offset:offset + chunk_bytes])
        for i, offset in enumerate(range(0, max(len(data), 1), chunk_bytes), 1)
    ]
