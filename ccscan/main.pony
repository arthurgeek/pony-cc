use "cli"
use "net"

class Scanner is TCPConnectionNotify
  let _out: OutStream

  new create(out: OutStream) =>
    _out = out

  fun ref connected(conn: TCPConnection ref) =>
    try
      let addr = conn.remote_address()
      (let host, let service) = addr.name()?

      _out.print(
        "Port: " + service + " is open"
      )
    end

    conn.dispose()

  fun ref connect_failed(conn: TCPConnection ref) =>
    None


actor Main
  new create(env: Env) =>
    let cs = try
      CommandSpec.leaf("ccscan", "A network scanner in Pony", [
        OptionSpec.string(
          "host",
          "host to connect to"
          where short' = 'H',
          default' = ""
        )
        OptionSpec.string(
          "port",
          "port to scan"
          where short' = 'p',
          default' = ""
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

    let host = cmd.option("host").string()
    let port = cmd.option("port").string()

    env.out.print("Scanning host: " + host + " port: " + port)

    TCPConnection(TCPConnectAuth(env.root), recover Scanner(env.out) end, host, port)
