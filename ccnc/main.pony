use "cli"
use "net"

class Server is TCPConnectionNotify
  let _out: OutStream

  new create(out: OutStream) =>
    _out = out

  fun ref received(conn: TCPConnection ref, data: Array[U8] iso, times: USize): Bool =>
    _out.print(String.from_array(consume data))
    true

  fun ref connect_failed(conn: TCPConnection ref) =>
    None

class Listener is TCPListenNotify
  let _out: OutStream

  new create(out: OutStream) =>
    _out = out

  fun ref connected(listen: TCPListener ref): TCPConnectionNotify iso^ =>
    recover iso Server(_out) end

  fun ref not_listening(listen: TCPListener ref) =>
    _out.print("Not listening")

actor Main
  new create(env: Env) =>
    let cs = try
      CommandSpec.leaf("ccnc", "A netcat clone in Pony", [
        OptionSpec.bool(
          "listen",
          "listen mode, for inbound connects"
          where short' = 'l',
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

    if listen and local_port != 0 then
      TCPListener(
        TCPListenAuth(env.root),
        recover Listener(env.out) end,
        "0.0.0.0",
        local_port.string()
      )
    end
