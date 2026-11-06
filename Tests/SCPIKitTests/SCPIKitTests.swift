import Foundation
import Testing
@testable import SCPIKit
import SDLSimulator

@Suite struct PatternTests {
    @Test func shortAndLongForms() {
        let p = SCPIPattern("[:SOURce]:CURRent[:LEVel][:IMMediate]?")
        #expect(p.matches(header: ":SOURce:CURRent:LEVel:IMMediate?"))
        #expect(p.matches(header: ":SOUR:CURR:LEV:IMM?"))
        #expect(p.matches(header: ":CURR?"))
        #expect(p.matches(header: "curr?"))
        #expect(p.matches(header: ":CURR:IMM?"))
        #expect(!p.matches(header: ":CURR"))          // not a query
        #expect(!p.matches(header: ":CURRe?"))        // partial long form is invalid
        #expect(!p.matches(header: ":CURR:IRANG?"))
    }

    @Test func nonStandardShortForms() {
        #expect(SCPIPattern("[:SOURce]:BATTery:DISCHArg:CAPability?").matches(header: ":BATT:DISCHA:CAP?"))
        #expect(!SCPIPattern("[:SOURce]:BATTery:DISCHArg:CAPability?").matches(header: ":BATT:DISCH:CAP?"))
        #expect(SCPIPattern("[:SOURce]:LED:RCOnf").matches(header: ":LED:RCONF"))
        #expect(SCPIPattern("[:SOURce]:LED:RCOnf").matches(header: ":LED:RCO"))
        #expect(SCPIPattern("*IDN?").matches(header: "*idn?"))
        #expect(SCPIPattern("[:SOURce]:VOLTage[:LEVel]:ON?").matches(header: ":VOLT:LEV:ON?"))
        #expect(SCPIPattern("[:SOURce]:VOLTage[:LEVel]:ON?").matches(header: ":VOLT:ON?"))
        #expect(!SCPIPattern("[:SOURce]:VOLTage[:LEVel][:IMMediate]?").matches(header: ":VOLT:LEV:ON?"))
    }

    @Test func messageParsing() {
        let m = SCPIMessage(":LIST:LEVel 3,4.500")
        #expect(m.header == ":LIST:LEVel")
        #expect(m.arguments == ["3", "4.500"])
        // Stray spaces after colons appear throughout the programming guide.
        let m2 = SCPIMessage(":SOURce: OCP:FUNC")
        #expect(m2.header == ":SOURce:OCP:FUNC")
        #expect(m2.arguments.isEmpty)
        let parts = SCPIMessage.split(line: "MEAS:CURR?;:MEAS:VOLT?")
        #expect(parts.map(\.header) == ["MEAS:CURR?", ":MEAS:VOLT?"])
    }
}

@Suite struct ParseTests {
    @Test func doubles() {
        #expect(SCPIParse.double("0.200000") == 0.2)
        #expect(SCPIParse.double("+5.00000000E+00") == 5)
        #expect(SCPIParse.double("8s") == 8)
        #expect(SCPIParse.double("30") == 30)
        #expect(SCPIParse.double("CURRENT") == nil)
    }

    @Test func errors() {
        #expect(SCPIParse.error("+0, No error")?.code == 0)
        let e = SCPIParse.error("-113,Undefined header,:BATT:DISCH:CAP?")
        #expect(e?.code == -113)
        #expect(e?.message == "Undefined header,:BATT:DISCH:CAP?")
        #expect(SCPIParse.error("+0,\"No error\"")?.message == "No error")
    }

    @Test func identity() {
        let id = InstrumentIdentity(idn: "Siglent Technologies,SDL1020X,SDL13GCXA00453,1.1.1.23R4")
        #expect(id?.model == "SDL1020X")
        #expect(id?.isSDL1000X == true)
        let k = InstrumentIdentity(idn: "Keysight Technologies,E36234A,MY61006154,1.1.1-1.0.3-1.01")
        #expect(k?.isSDL1000X == false)
    }
}

@Suite(.serialized) struct TransportTests {
    func withSim(_ body: (SDLSimulator, SCPIConnection) async throws -> Void) async throws {
        let sim = SDLSimulator()
        let port = try await sim.start()
        let conn = SCPIConnection(host: "127.0.0.1", port: port, timeout: .milliseconds(300))
        try await conn.connect()
        try await body(sim, conn)
        await conn.disconnect()
        sim.stop()
    }

    @Test func basicQuery() async throws {
        try await withSim { _, c in
            let idn = try await c.query("*IDN?")
            #expect(idn.hasPrefix("Siglent Technologies,SDL1020X"))
        }
    }

    @Test func silentOnBadCommandThenResyncs() async throws {
        try await withSim { _, c in
            await #expect(throws: SCPIError.timeout(command: ":BATT:DISCH:CAP?")) {
                _ = try await c.query(":BATT:DISCH:CAP?")
            }
            // The session must stay aligned afterwards.
            #expect(try await c.query(":BATT:DISCHA:CAP?") == "0")
            let err = try await c.query("SYST:ERR?")
            #expect(err.hasPrefix("-113"))
            #expect(try await c.query("SYST:ERR?").hasPrefix("+0"))
        }
    }

    @Test func chainedQueriesConcatenate() async throws {
        try await withSim { _, c in
            // Documents the SDL quirk the rest of the stack must avoid.
            let r = try await c.query("MEAS:CURR?;:MEAS:VOLT?")
            #expect(r == "0.0000000.000000")
        }
    }

    @Test func concurrentQueriesStayAligned() async throws {
        try await withSim { sim, c in
            sim.sourceVoltage = 7.5
            try await withThrowingTaskGroup(of: Bool.self) { g in
                for i in 0..<40 {
                    g.addTask {
                        if i % 2 == 0 { return try await c.query("*IDN?").contains("SDL1020X") }
                        return try await c.query("MEAS:VOLT?") == "7.500000"
                    }
                }
                for try await ok in g { #expect(ok) }
            }
        }
    }

    @Test func detectsServerDisconnect() async throws {
        try await withSim { sim, c in
            // Round-trip first so the server has definitely accepted the connection.
            #expect(try await c.query("*IDN?").contains("SDL1020X"))
            sim.dropClients()
            try await Task.sleep(for: .milliseconds(200))
            #expect(await !c.isConnected)
            await #expect(throws: SCPIError.notConnected) { _ = try await c.query("*IDN?") }
            try await c.connect()
            #expect(try await c.query("*IDN?").contains("SDL1020X"))
        }
    }

    @Test func connectFailsFastWhenRefused() async throws {
        let c = SCPIConnection(host: "127.0.0.1", port: 1)
        let t = Date()
        await #expect(throws: SCPIError.self) { try await c.connect(timeout: .seconds(2)) }
        #expect(Date().timeIntervalSince(t) < 1.5)
    }

    @Test func sweepFindsSimulator() async throws {
        let sim = SDLSimulator()
        let port = try await sim.start()
        defer { sim.stop() }
        let found = await Discovery.sweep(hosts: ["127.0.0.1"], port: port)
        #expect(found.count == 1)
        #expect(found.first?.identity?.isSDL1000X == true)
    }

    @Test func secondClientIsReportedBusyAndFirstSurvives() async throws {
        try await withSim { sim, c in
            let before = try await c.query("*IDN?")
            #expect(before.contains("SDL1020X"))
            let probe = await Discovery.probe(host: "127.0.0.1", port: sim.port)
            #expect(probe == .busy)
            let after = try await c.query("*IDN?")
            #expect(after.contains("SDL1020X"))
            let found = await Discovery.sweep(hosts: ["127.0.0.1"], port: sim.port)
            #expect(found.first?.isBusy == true)
        }
    }

    @Test func confirmedWritesPreventBacklog() async throws {
        try await withSim { sim, c in
            sim.sourceVoltage = 7.5
            sim.writeCost = 0.05                       // 20 writes = 1 s of processing
            for _ in 0..<20 { try await c.write(":CURR 0.1") }
            // Query timeout (300 ms) is far shorter than the total write time; must still work.
            let v = try await c.query("MEAS:VOLT?")
            #expect(v == "7.500000")
        }
    }

    @Test func unconfirmedBacklogTimesOutThenResyncsAligned() async throws {
        try await withSim { sim, c in
            sim.sourceVoltage = 7.5
            sim.writeCost = 0.1
            for _ in 0..<8 { try await c.write(":CURR 0.1", confirm: false) }   // 0.8 s backlog
            _ = try? await c.query("*IDN?")            // times out at 300 ms; reply comes later
            let late = try? await c.query(":INP?")     // also likely times out
            _ = late
            // After resync, replies must line up with their queries again.
            let v = try await c.query("MEAS:VOLT?")
            #expect(v == "7.500000")
            let i = try await c.query(":INP?")
            #expect(i == "0")
        }
    }

    @Test func subnetHosts() {
        let s = Discovery.Subnet(interface: "en0", address: 0xC0A8_0111, netmask: 0xFFFF_FF00)
        #expect(s.hosts.count == 253)            // .1–.254 minus our own .17
        #expect(s.hosts.first == "192.168.1.1")
        #expect(!s.hosts.contains("192.168.1.17"))
    }
}
