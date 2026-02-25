use "cli"
use "net"
use "term"
use "promises"

class NCTCPServer is TCPConnectionNotify
  let _out: OutStream
  let _main: Main

  new create(out: OutStream, main: Main) =>
    _out = out
    _main = main

  fun ref accepted(conn: TCPConnection ref) =>
    _main._conn_opened(conn)

  fun ref received(conn: TCPConnection ref, data: Array[U8] iso, times: USize): Bool =>
    _out.print(String.from_array(consume data))
    true

  fun ref connect_failed(conn: TCPConnection ref) =>
    None

  fun ref closed(conn: TCPConnection ref) =>
    _main._conn_closed(conn)

class NCTCPListener is TCPListenNotify
  let _out: OutStream
  let _main: Main

  new create(out: OutStream, main: Main) =>
    _out = out
    _main = main

  fun ref connected(listen: TCPListener ref): TCPConnectionNotify iso^ =>
    listen.dispose()
    recover iso NCTCPServer(_out, _main) end

  fun ref not_listening(listen: TCPListener ref) =>
    _out.print("Not listening")

class NCUDPServer is UDPNotify
  let _out: OutStream
  let _main: Main

  new create(out: OutStream, main: Main) =>
    _out = out
    _main = main

  fun ref received(sock: UDPSocket ref, data: Array[U8] iso, from: NetAddress) =>
    _out.print(String.from_array(consume data))
    _main._udp_connected(sock, from)

  fun ref not_listening(sock: UDPSocket ref) =>
      None

class Handler is ReadlineNotify
  let _main: Main

  new create(main: Main) =>
    _main = main

  fun ref apply(line: String, prompt: Promise[String]) =>
    prompt("")
    _main._stdin_data(line)

actor Main
  var _tcp_conn: (TCPConnection tag | None) = None
  var _udp_sock: (UDPSocket tag | None) = None
  var _term: (ANSITerm tag | None) = None
  var _udp_from: (NetAddress | None) = None

  new create(env: Env) =>
    let cs = try
      CommandSpec.leaf("ccnc", "A netcat clone in Pony", [
        OptionSpec.bool(
          "listen",
          "listen mode, for inbound connects"
          where short' = 'l',
          default' = false
        )
        OptionSpec.bool(
          "udp",
          "UDP mode"
          where short' = 'u',
          default' = false
        )
        OptionSpec.u64(
          "local-port",
          "local port number"
          where short' = 'p',
          default' = U64(0)
        )
      ], [])? .> add_help()?
    else
      env.exitcode(-1)
      return
    end

    let cmd = match CommandParser(cs).parse(env.args, env.vars)
      | let c: Command => c
      | let ch: CommandHelp =>
        ch.print_help(env.out)
        env.exitcode(0)
        return
      | let se: SyntaxError =>
        env.out.print(se.string())
        env.exitcode(1)
        return
    end

    let listen = cmd.option("listen").bool()
    let local_port = cmd.option("local-port").u64()
    let udp = cmd.option("udp").bool()

    if listen and (local_port != 0)then
      if udp then
        UDPSocket(
          UDPAuth(env.root),
          recover NCUDPServer(env.out, this) end,
          "0.0.0.0",
          local_port.string()
        )
      else
        TCPListener(
          TCPListenAuth(env.root),
          recover NCTCPListener(env.out, this) end,
          "0.0.0.0",
          local_port.string()
        )
      end

      let term = ANSITerm(Readline(recover Handler(this) end, env.out), env.input)
      _term = term
      term.prompt("")
      let notify = object iso
        let term: ANSITerm = term
        fun ref apply(data: Array[U8] iso) => term(consume data)
        fun ref dispose() => term.dispose()
      end

      env.input(consume notify)
    end

  be _conn_opened(conn: TCPConnection tag) =>
    _tcp_conn = conn

  be _udp_connected(sock: UDPSocket tag, from: NetAddress) =>
    _udp_sock = sock
    _udp_from = from

  be _conn_closed(conn: TCPConnection tag) =>
    _tcp_conn = None
    match _term
      | let t: ANSITerm => t.dispose()
    end

  be _stdin_data(data: String val) =>
    match _tcp_conn
      | let conn: TCPConnection tag => conn.write(data + "\n")
    end

    match (_udp_sock, _udp_from)
      | (let sock: UDPSocket tag, let addr: NetAddress) => sock.write(data + "\n", addr)
    end
