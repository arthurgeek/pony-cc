use "net"

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

  fun ref received(conn: TCPConnection ref, data: Array[U8] iso, times: USize): Bool =>
    conn.write(String.from_array(consume data))
    true

  fun ref closed(conn: TCPConnection ref) =>
    _out.print("Client disconnected")

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

actor Main
  let _listener: TCPListener

  new create(env: Env) =>
    _listener = TCPListener(
      TCPListenAuth(env.root),
      recover iso EchoServerListener(env.out, this) end,
      "0.0.0.0",
      "7"
    )

  be dispose() =>
    _listener.dispose()
