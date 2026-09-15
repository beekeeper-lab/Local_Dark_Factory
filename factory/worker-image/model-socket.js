// The container's only way out, and the reason --network=none is honest.
//
// pi speaks HTTP over TCP and has no notion of a unix socket, so the socket that
// is mounted in has to be presented as an address it can use. This listens on
// 127.0.0.1 inside the container — an interface that exists even with no routes
// — and forwards every byte to /run/model/ollama.sock, which the host bridges to
// exactly one upstream address and port.
//
// It forwards bytes and nothing else. No routing, no rewriting, no second
// destination: the only thing a worker can reach by talking to it is the model
// the host chose. If the socket is not mounted, this exits rather than listening
// on a port that silently goes nowhere — a worker that cannot reach the model
// should fail loudly at startup, not halfway through a task.
const net = require("net");
const fs = require("fs");

const SOCK = process.env.MODEL_SOCKET || "/run/model/ollama.sock";
const PORT = Number(process.env.MODEL_PORT || 11434);

if (!fs.existsSync(SOCK)) {
  console.error(`model-socket: ${SOCK} is not mounted — there is no model to reach`);
  process.exit(1);
}

const server = net.createServer((client) => {
  const upstream = net.createConnection(SOCK);
  client.pipe(upstream);
  upstream.pipe(client);
  const drop = () => { client.destroy(); upstream.destroy(); };
  client.on("error", drop);
  upstream.on("error", drop);
});

server.listen(PORT, "127.0.0.1", () => {
  if (process.env.MODEL_SOCKET_QUIET !== "1") {
    console.error(`model-socket: 127.0.0.1:${PORT} -> ${SOCK}`);
  }
});
server.on("error", (e) => {
  console.error(`model-socket: cannot listen on ${PORT}: ${e.message}`);
  process.exit(1);
});
