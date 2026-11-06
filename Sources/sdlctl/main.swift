import Foundation
import SCPIKit
import SDLKit
import SDLSimulator

let usage = """
sdlctl — Siglent SDL1000X command-line tool

USAGE: sdlctl <command> [options]

  discover                          Sweep local subnets (TCP 5025) + mDNS for instruments
  idn <host>                        Print *IDN?
  send <host> <cmd> [<cmd>...]      Send commands; those ending in '?' (or containing '? ')
                                    print their reply
  monitor <host> [hz] [seconds]     Stream V/I/P/R as CSV (default 4 Hz, until Ctrl-C)
  conformance <host>                Run every documented query once; report any that get
                                    no reply (read-only, safe)
  snapshot <host> <file.json>       Save all user settings
  restore <host> <file.json>        Restore settings saved with snapshot (input forced OFF)
  diff <host> <file.json>           Show settings that differ from a snapshot
  bench <host> [n]                  Query latency benchmark
  sim [port]                        Run the SDL simulator (default port 5025)

<host> may be host or host:port. Default host from $SDL_HOST.
"""

func parseHost(_ s: String?) -> (String, UInt16) {
    let raw = s ?? ProcessInfo.processInfo.environment["SDL_HOST"] ?? ""
    guard !raw.isEmpty else { fail("No host given (and $SDL_HOST unset)") }
    let parts = raw.split(separator: ":")
    if parts.count == 2, let p = UInt16(parts[1]) { return (String(parts[0]), p) }
    return (raw, 5025)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

func connect(_ hostArg: String?) async -> SDL1000X {
    let (h, p) = parseHost(hostArg)
    let sdl = SDL1000X(host: h, port: p)
    do { try await sdl.connection.connect() } catch { fail("\(h):\(p): \(error)") }
    return sdl
}

func isQuery(_ cmd: String) -> Bool {
    let header = cmd.split(separator: " ", maxSplits: 1).first.map(String.init) ?? cmd
    return header.hasSuffix("?")
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print(usage); exit(0) }
args.removeFirst()

switch cmd {
case "discover":
    let subnets = Discovery.localSubnets()
    print("Sweeping: \(subnets.map(\.description).joined(separator: ", "))")
    let t0 = Date()
    let found = await Discovery.discoverAll()
    for d in found {
        guard let id = d.identity else {
            print("\(d.host):\(d.port)\t[\(d.source.rawValue)]\tBUSY: port open but another client is connected")
            continue
        }
        let tag = id.isSDL1000X ? "  ← SDL1000X" : ""
        print("\(d.host):\(d.port)\t[\(d.source.rawValue)]\t\(id.manufacturer) \(id.model) s/n \(id.serial) fw \(id.firmware)\(tag)")
    }
    print(String(format: "%d instrument(s) in %.1fs", found.count, Date().timeIntervalSince(t0)))

case "idn":
    let sdl = await connect(args.first)
    print(try await sdl.query("*IDN?"))

case "send":
    let sdl = await connect(args.first)
    for c in args.dropFirst() {
        do {
            if isQuery(c) { print("\(c) -> \(try await sdl.query(c))") }
            else { try await sdl.write(c); print("\(c) (sent)") }
        } catch { print("\(c) !! \(error)") }
    }
    let errs = try await sdl.drainErrors()
    for e in errs { print("SYST:ERR: \(e.code), \(e.message)") }

case "monitor":
    let sdl = await connect(args.first)
    let hz = args.count > 1 ? Double(args[1]) ?? 4 : 4
    let seconds = args.count > 2 ? Double(args[2]) : nil
    let start = Date()
    print("t_s,voltage_V,current_A,power_W,resistance_Ohm")
    while seconds.map({ Date().timeIntervalSince(start) < $0 }) ?? true {
        let tick = Date()
        let m = hz > 5 ? try await sdl.measureFast() : try await sdl.measureAll()
        print(String(format: "%.3f,%.6f,%.6f,%.6f,%.6f", m.date.timeIntervalSince(start), m.voltage, m.current, m.power, m.resistance))
        let remaining = 1 / hz - Date().timeIntervalSince(tick)
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
    }

case "conformance":
    let sdl = await connect(args.first)
    let queries = SettingsSnapshot.entries.map(\.query) + SettingsSnapshot.readOnlyQueries
    var failures: [String] = []
    for q in queries {
        do {
            let r = try await sdl.query(q)
            print("ok   \(q.padding(toLength: 26, withPad: " ", startingAt: 0)) \(r.prefix(60))")
        } catch {
            failures.append(q)
            print("FAIL \(q.padding(toLength: 26, withPad: " ", startingAt: 0)) \(error)")
        }
    }
    let errs = try await sdl.drainErrors()
    for e in errs { print("SYST:ERR: \(e.code), \(e.message)") }
    print("\(queries.count - failures.count)/\(queries.count) queries answered")
    if !failures.isEmpty { print("No reply: \(failures.joined(separator: "  "))"); exit(2) }

case "snapshot":
    guard args.count >= 2 else { fail("usage: snapshot <host> <file.json>") }
    let sdl = await connect(args[0])
    let snap = try await SettingsSnapshot.take(from: sdl)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
    try enc.encode(snap).write(to: URL(fileURLWithPath: args[1]))
    print("Saved \(snap.values.count) settings (active function: \(snap.activeFunction.rawValue)) to \(args[1])")

case "restore", "diff":
    guard args.count >= 2 else { fail("usage: \(cmd) <host> <file.json>") }
    let sdl = await connect(args[0])
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let snap = try dec.decode(SettingsSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
    if cmd == "restore" {
        try await snap.restore(to: sdl)
        let errs = try await sdl.drainErrors()
        for e in errs { print("SYST:ERR: \(e.code), \(e.message)") }
    }
    let d = try await snap.diff(against: sdl)
    if d.isEmpty { print("All \(snap.values.count) settings match the snapshot.") }
    for (e, old, new) in d { print("DIFF \(e.query): snapshot=\(old) now=\(new)") }
    if !d.isEmpty { exit(2) }

case "bench":
    let sdl = await connect(args.first)
    let n = args.count > 1 ? Int(args[1]) ?? 100 : 100
    var lat: [Double] = []
    for _ in 0..<n {
        let t = Date(); _ = try await sdl.measureVoltage(); lat.append(Date().timeIntervalSince(t) * 1000)
    }
    lat.sort()
    print(String(format: "n=%d  min=%.1fms  median=%.1fms  p95=%.1fms  max=%.1fms  → %.0f queries/s",
                 n, lat.first!, lat[n / 2], lat[Int(Double(n) * 0.95)], lat.last!, 1000 / (lat.reduce(0, +) / Double(n))))

case "sim":
    let port = args.first.flatMap(UInt16.init) ?? 5025
    let sim = SDLSimulator()
    sim.sourceVoltage = 12
    sim.sourceResistance = 0.1
    let bound = try await sim.start(port: port)
    print("SDL simulator listening on 127.0.0.1:\(bound) (source 12 V / 0.1 Ω). Ctrl-C to stop.")
    print("Sim-only commands: SIM:SOURCE:VOLT <v> | SIM:SOURCE:RES <ohm> | SIM:BATTERY <mAh>,<Vfull>,<Vempty> | SIM:BATTERY OFF")
    while true { try await Task.sleep(for: .seconds(3600)) }

case "-h", "--help", "help":
    print(usage)

default:
    fail("unknown command '\(cmd)'\n\n\(usage)")
}
