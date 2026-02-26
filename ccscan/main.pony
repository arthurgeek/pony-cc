use "cli"
use "net"
use "collections"

use @pony_schedulers[U32]()

class Scanner is TCPConnectionNotify
  let _out: OutStream
  let _coordinator: ScannerCoordinator tag

  new create(out: OutStream, coordinator: ScannerCoordinator tag) =>
    _out = out
    _coordinator = coordinator

  fun ref connected(conn: TCPConnection ref) =>
    try
      let addr = conn.remote_address()
      (let host, let service) = addr.name()?

      _out.print(
        host + ":" + service + " is open"
      )
    end

    conn.dispose()
    _coordinator.done()

  fun ref connect_failed(conn: TCPConnection ref) =>
    _coordinator.done()
    None

actor ScannerCoordinator
  let _out: OutStream
  let _auth: TCPConnectAuth
  let _host: String
  var _next_port: U64
  let _end_port: U64
  let _pool: ConnectionPool tag

  new create(
    out: OutStream,
    auth: TCPConnectAuth,
    host: String,
    start_port: U64,
    end_port: U64,
    pool: ConnectionPool tag,
    batch_size: U64
  ) =>
    _out = out
    _auth = auth
    _host = host
    _pool = pool
    _next_port = start_port
    _end_port = end_port

    let ports_to_scan = (_end_port - _next_port) + 1
    for _ in Range[U64](1, ports_to_scan.min(batch_size) + 1) do
      _pool.acquire(this)
    end

  be granted() =>
    let scanner = recover Scanner(_out, this) end
    TCPConnection(_auth, consume scanner, _host, _next_port.string())
    _next_port = _next_port + 1

  be done() =>
    _pool.release(this)

    if _next_port <= _end_port then
      _pool.acquire(this)
    end

actor ConnectionPool
  var _in_flight: U64 = 0
  let _max_conns: U64
  let _coordinator_queue: Array[ScannerCoordinator tag] = Array[ScannerCoordinator tag]()

  new create(max_conns: U64 = 500) =>
    _max_conns = max_conns

  be acquire(coordinator: ScannerCoordinator tag) =>
    if _in_flight < _max_conns then
      _in_flight = _in_flight + 1
      coordinator.granted()
    else
      _coordinator_queue.push(coordinator)
    end

  be release(coordinator: ScannerCoordinator tag) =>
    if _coordinator_queue.size() > 0 then
      try _coordinator_queue.pop()?.granted() end
    else
      _in_flight = _in_flight - 1
    end

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
        OptionSpec.u64(
          "max-conns",
          "maximum concurrent connections"
          where short' = 'c',
          default' = 500
        )
        OptionSpec.u64(
          "workers",
          "number of parallel workers (0 = number of cores)"
          where short' = 'w',
          default' = 0
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

    let max_conns: U64 = cmd.option("max-conns").u64()
    let workers_opt: U64 = cmd.option("workers").u64()
    let workers: U64 = if workers_opt == 0 then
      @pony_schedulers[U32]().u64()
    else
      workers_opt
    end

    let pool: ConnectionPool = ConnectionPool(max_conns)
    let batch_size: U64 = max_conns / workers

    if port != "" then
      env.out.print("Scanning host: " + host + " port:" + port)

      try
        let p = port.u64()?
        ScannerCoordinator(env.out, TCPConnectAuth(env.root), host,
          p, p, pool, max_conns)
      end
    else
      env.out.print("Scanning host: " + host)

      let ports_per_worker: U64 = 65535 / workers

      for i in Range[U64](0, workers) do
        let start_port = (i * ports_per_worker) + 1
        let end_port = if i == (workers - 1) then
          65535
        else
          (i + 1) * ports_per_worker
        end

        ScannerCoordinator(
          env.out,
          TCPConnectAuth(env.root),
          host,
          start_port,
          end_port,
          pool,
          batch_size
        )
      end
    end
