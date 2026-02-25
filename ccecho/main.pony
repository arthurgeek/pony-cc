use "net"
use "signals"
use "collections"

class EchoServerUDP is UDPNotify
  let _out: OutStream
  let _main: Main

  new create(out: OutStream, main: Main) =>
    _out = out
    _main = main

  fun ref listening(sock: UDPSocket ref) =>
    try
      let addr = sock.local_address()
      (let host, let service) = addr.name()?

      _out.print(
        "UDP Echo server listening on " +
        host + ":" +
        service
      )
    end

  fun ref received(sock: UDPSocket ref, data: Array[U8] iso, from: NetAddress) =>
    sock.write(consume data, from)

  fun ref not_listening(sock: UDPSocket ref) =>
      None

class EchoServer is TCPConnectionNotify
  let _out: OutStream
  let _main: Main

  new create(out: OutStream, main: Main) =>
    _out = out
    _main = main

  fun ref accepted(conn: TCPConnection ref) =>
    try
      let addr = conn.remote_address()
      (let host, let service) = addr.name()?

      _out.print(
        "Accepted connection from " +
        host + ":" +
        service
      )
    end

    _main._conn_opened(conn)

  fun ref received(conn: TCPConnection ref, data: Array[U8] iso, times: USize): Bool =>
    conn.write(String.from_array(consume data))
    true

  fun ref closed(conn: TCPConnection ref) =>
    _out.print("Client disconnected")
    _main._conn_closed(conn)

  fun ref connect_failed(conn: TCPConnection ref) =>
    None

class EchoServerListener is TCPListenNotify
  let _out: OutStream
  let _main: Main

  new create(out: OutStream, main: Main) =>
    _out = out
    _main = main

  fun ref connected(listen: TCPListener ref): TCPConnectionNotify iso^ =>
    recover iso EchoServer(_out, _main) end

  fun ref not_listening(listen: TCPListener ref) =>
    _out.print("Not listening")

class KillHandler is SignalNotify
  let _main: Main

  new create(main: Main) =>
    _main = main

  fun ref apply(count: U32): Bool =>
    _main.dispose()
    false

actor Main
  let _listener: (TCPListener | UDPSocket)
  let _sig: SignalHandler
  var _conns: SetIs[TCPConnection tag]

  new create(env: Env) =>
    var use_udp: Bool = false
    _sig = SignalHandler(recover iso KillHandler(this) end, Sig.int())
    _conns = SetIs[TCPConnection tag]

    try
      use_udp = env.args(1)? == "-udp"
    end

    if use_udp then
      _listener = UDPSocket(
        UDPAuth(env.root),
        recover iso EchoServerUDP(env.out, this) end,
        "0.0.0.0",
        "7"
      )
    else
      _listener = TCPListener(
        TCPListenAuth(env.root),
        recover iso EchoServerListener(env.out, this) end,
        "0.0.0.0",
        "7"
      )
    end

  be _conn_opened(conn: TCPConnection tag) =>
    _conns.set(conn)

  be _conn_closed(conn: TCPConnection tag) =>
    _conns.unset(conn)

  be dispose() =>
    _listener.dispose()

    for conn in _conns.values() do
      conn.dispose()
    end
