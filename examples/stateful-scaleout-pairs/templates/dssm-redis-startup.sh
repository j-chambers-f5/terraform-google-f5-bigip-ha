#!/bin/sh
# Lightweight Redis-compatible RESP state store (tcp:6379) for cross-pair L2 dSSM session persistence testing.
set -eu

cat <<'EOF' > /usr/local/bin/dssm-redis.py
#!/usr/bin/env python3
"""Minimal Redis RESP server supporting GET, SET [EX], DEL, PING, and QUIT on tcp:6379."""

import asyncio
import time

store: dict[str, tuple[str, float | None]] = {}


async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while not reader.at_eof():
            line = await reader.readline()
            if not line:
                break
            text = line.decode("utf-8", errors="replace").strip()
            if not text:
                continue
            parts = text.split()
            cmd = parts[0].upper()
            now = time.time()
            if cmd == "PING":
                writer.write(b"+PONG\r\n")
            elif cmd == "GET" and len(parts) >= 2:
                key = parts[1]
                entry = store.get(key)
                if entry is not None:
                    val, exp = entry
                    if exp is None or exp > now:
                        encoded = val.encode("utf-8")
                        writer.write(f"${len(encoded)}\r\n".encode("utf-8") + encoded + b"\r\n")
                    else:
                        del store[key]
                        writer.write(b"$-1\r\n")
                else:
                    writer.write(b"$-1\r\n")
            elif cmd == "SET" and len(parts) >= 3:
                key = parts[1]
                val = parts[2]
                exp = None
                if len(parts) >= 5 and parts[3].upper() == "EX":
                    try:
                        exp = now + float(parts[4])
                    except ValueError:
                        exp = None
                store[key] = (val, exp)
                writer.write(b"+OK\r\n")
            elif cmd == "DEL" and len(parts) >= 2:
                removed = 1 if store.pop(parts[1], None) is not None else 0
                writer.write(f":{removed}\r\n".encode("utf-8"))
            elif cmd == "QUIT":
                writer.write(b"+OK\r\n")
                await writer.drain()
                break
            else:
                writer.write(b"+OK\r\n")
            await writer.drain()
    except Exception:
        pass
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass


async def main() -> None:
    server = await asyncio.start_server(handle_client, "0.0.0.0", 6379)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
EOF
chmod 0755 /usr/local/bin/dssm-redis.py

cat <<'EOF' > /etc/systemd/system/dssm-redis.service
[Unit]
Description=Lightweight Redis RESP L2 Session Store (dSSM)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/dssm-redis.py
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now dssm-redis.service
