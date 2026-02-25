use "cli"
use "net"
use "term"
use "files"
use "process"
use "promises"
use "collections"
use "backpressure"

class NCTCPServer is TCPConnectionNotify
  let _out: OutStream
  let _main: Main

  new create(out: OutStream, main: Main) =>
    _out = out
    _main = main

  fun ref accepted(conn: TCPConnection ref) =>
    _main._conn_opened(conn)

  fun ref received(conn: TCPConnection ref, data: Array[U8] iso, times: USize): Bool =>
    let str = String.from_array(consume data)
    _out.print(str)
    _main._conn_received(str)
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

class TCPScanner is TCPConnectionNotify
  let _out: OutStream

  new create(out: OutStream) =>
    _out = out

  fun ref connected(conn: TCPConnection ref) =>
    try
      let addr = conn.remote_address()
      (let host, let service) = addr.name()?

      _out.print(
        "Connection to " + host + " port " + service + " [tcp] succeeded!"
      )
    end

    conn.dispose()

  fun ref connect_failed(conn: TCPConnection ref) =>
    None

class Handler is ReadlineNotify
  let _main: Main

  new create(main: Main) =>
    _main = main

  fun ref apply(line: String, prompt: Promise[String]) =>
    prompt("")
    _main._send_data(line)

class ProcessClient is ProcessNotify
  let _main: Main

  new create(main: Main) =>
    _main = main

  fun ref stdout(process: ProcessMonitor ref, data: Array[U8] iso) =>
    _main._send_data(String.from_array(consume data))

actor Main
  var _tcp_conn: (TCPConnection tag | None) = None
  var _udp_sock: (UDPSocket tag | None) = None
  var _term: (ANSITerm tag | None) = None
  var _udp_from: (NetAddress | None) = None
  var _env: Env
  var _pm: (ProcessMonitor | None) = None
  var _exec: String = ""

  new create(env: Env) =>
    _env = env

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
        OptionSpec.bool(
          "zero",
          "zero-I/O mode (used for scanning)"
          where short' = 'z',
          default' = false
        )
        OptionSpec.string(
          "exec",
          "program to exec after connect"
          where short' = 'e',
          default' = ""
        )
      ], [
           ArgSpec.string("host", "target host" where default' = "")
           ArgSpec.string("port", "port or port range" where default' = "")
        ])? .> add_help()?
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
    let zero_io_mode = cmd.option("zero").bool()
    _exec = cmd.option("exec").string()

    if listen and (local_port != 0) then
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

  if zero_io_mode then
    let host = cmd.arg("host").string()
    let port = cmd.arg("port").string()

    if (host == "") or (port == "") then
      env.out.print("-z requires host and port/port range")
      env.exitcode(1)
    else
      let parts = port.split("-")
      match parts.size()
        | 1 =>  TCPConnection(TCPConnectAuth(env.root), recover TCPScanner(env.out) end, host, port)
        | 2 =>
          try
            let start_port = parts(0)?.u64()?
            let end_port = parts(1)?.u64()?

            for p in Range[U64](start_port, end_port + 1) do
              TCPConnection(TCPConnectAuth(env.root), recover TCPScanner(env.out) end, host, p.string())
            end
          end
        end
    end
  end

  be _conn_opened(conn: TCPConnection tag) =>
    _tcp_conn = conn
    _start_process()

  be _udp_connected(sock: UDPSocket tag, from: NetAddress) =>
    _udp_sock = sock
    _udp_from = from
    _start_process()

  be _conn_closed(conn: TCPConnection tag) =>
    _tcp_conn = None
    match _term
      | let t: ANSITerm => t.dispose()
    end

  be _start_process() =>
    if _exec != "" then
      let client = recover ProcessClient(this) end

      let notifier: ProcessNotify iso = consume client
      let path = FilePath(FileAuth(_env.root), _exec)
      let args: String = Path.base(_exec)
      let sp_auth = StartProcessAuth(_env.root)
      let bp_auth = ApplyReleaseBackpressureAuth(_env.root)

      _pm = ProcessMonitor(sp_auth, bp_auth, consume notifier, path, [args], _env.vars)
    end

  be _send_data(data: String val) =>
    match _tcp_conn
      | let conn: TCPConnection tag => conn.write(data + "\n")
    end

    match (_udp_sock, _udp_from)
      | (let sock: UDPSocket tag, let addr: NetAddress) => sock.write(data + "\n", addr)
    end

  be _conn_received(data: String val) =>
    match _pm
      | let pm: ProcessMonitor => pm.write(data)
    end
