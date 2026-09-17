"""The host half of the worker's one way out.

Listens on a unix socket and forwards every byte to one address and port. That
is the whole program, and the smallness is the point: it is the only thing
standing between a container with no routes and the rest of the machine, so
there is deliberately nothing in it that could be talked into a second
destination -- no routing, no headers parsed, no configuration read at runtime.

It is started by model-gateway.sh under `runcon -t container_t`, because SELinux
checks a unix socket connection against the peer process's context rather than
the socket file's label: a container may not connect to a socket held by an
ordinary user process, however the file is labelled.
"""
import os
import socket
import sys
import threading


def pump(src: socket.socket, dst: socket.socket) -> None:
    """Copy until one side closes, then half-close the other.

    Half-close rather than destroy: an HTTP client that has finished its request
    still expects to read the response, and closing both directions at once
    turns a completed call into a truncated one.
    """
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def serve(client: socket.socket, host: str, port: int) -> None:
    try:
        upstream = socket.create_connection((host, port))
    except OSError as exc:
        # The worker sees a closed connection. Saying why here is what makes the
        # difference between "the model is down" and "the model said something
        # strange" when the log is read afterwards.
        print(f"model-bridge: cannot reach {host}:{port}: {exc}", flush=True)
        client.close()
        return
    threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
    pump(upstream, client)
    client.close()
    upstream.close()


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: model-bridge.py <socket-path> <upstream-host> <upstream-port>", file=sys.stderr)
        return 2
    sock_path, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])

    if len(sock_path) >= 100:
        print(f"model-bridge: socket path is {len(sock_path)} bytes and will not fit in a unix address", file=sys.stderr)
        return 2
    if os.path.exists(sock_path):
        os.unlink(sock_path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    # The container runs as the invoking user under --userns=keep-id, so 0600
    # would be enough today. 0666 is here because the userns mapping is a
    # property of how the worker happens to be launched, and a socket that stops
    # working when that changes would fail in a way that looks like the model.
    os.chmod(sock_path, 0o666)
    server.listen(16)
    print(f"model-bridge: {sock_path} -> {host}:{port}", flush=True)

    while True:
        client, _ = server.accept()
        threading.Thread(target=serve, args=(client, host, port), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main())
