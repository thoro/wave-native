// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveCore unit tests — encode the GUARDS.md invariants that live at the type
// layer (§A transport framing, §B object-store merge rule, §P ESTART parse,
// §T terminal base64 + termsize, §L layout node defaults) and verify the
// PROTOCOL.md §2 ORef contract. These run without a live wavesrv.

import XCTest
@testable import WaveCore

final class WaveCoreTests: XCTestCase {

    // MARK: Client decode — null/missing windowids must not crash

    func testClientDecodesNullWindowids() throws {
        // The backend sends `"windowids": null` for a client with no windows; a plain
        // [String] would crash the decode (the reported startup error).
        let json = #"{"oid":"client:1","version":1,"windowids":null,"meta":{}}"#.data(using: .utf8)!
        let client = try JSONDecoder().decode(Client.self, from: json)
        XCTAssertEqual(client.windowids, [])
    }

    func testClientDecodesMissingWindowids() throws {
        let json = #"{"oid":"client:1","version":1,"meta":{}}"#.data(using: .utf8)!
        let client = try JSONDecoder().decode(Client.self, from: json)
        XCTAssertEqual(client.windowids, [])
    }

    func testClientDecodesPresentWindowids() throws {
        let json = #"{"oid":"client:1","version":1,"windowids":["window:a","window:b"],"meta":{}}"#.data(using: .utf8)!
        let client = try JSONDecoder().decode(Client.self, from: json)
        XCTAssertEqual(client.windowids, ["window:a", "window:b"])
    }

    func testTabDecodesNullBlockids() throws {
        // An empty tab (no blocks yet) comes back with blockids:null.
        let json = #"{"oid":"tab:1","version":1,"name":"T","layoutstate":"layout:1","blockids":null,"meta":{}}"#.data(using: .utf8)!
        let tab = try JSONDecoder().decode(Tab.self, from: json)
        XCTAssertEqual(tab.blockids, [])
    }

    func testWorkspaceDecodesNullTabids() throws {
        let json = #"{"oid":"workspace:1","version":1,"tabids":null,"activetabid":"","meta":{}}"#.data(using: .utf8)!
        let ws = try JSONDecoder().decode(Workspace.self, from: json)
        XCTAssertEqual(ws.tabids, [])
    }

    // MARK: PROTOCOL §2 — ORef parsing/serialization

    func testORefRoundTrip() throws {
        let oref = try ORef.parse("tab:abc123")
        XCTAssertEqual(oref.otype, "tab")
        XCTAssertEqual(oref.oid, "abc123")
        XCTAssertEqual(oref.string, "tab:abc123")
        XCTAssertFalse(oref.isEmpty)
    }

    func testORefRejectsBadInput() {
        XCTAssertThrowsError(try ORef.parse("noseparator"))   // wrong field count
        XCTAssertThrowsError(try ORef.parse("a:b:c"))         // too many fields
        XCTAssertThrowsError(try ORef.parse("Tab:x"))         // not ^[a-z]+$
        XCTAssertThrowsError(try ORef.parse("bogus:x"))       // unknown otype
    }

    func testORefCodableAsString() throws {
        let oref = ORef.block("blk")
        let data = try JSONEncoder().encode(oref)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"block:blk\"")
        let back = try JSONDecoder().decode(ORef.self, from: data)
        XCTAssertEqual(back, oref)
    }

    func testEmptyORefSerializesToEmptyString() throws {
        let empty = ORef(otype: "", oid: "")
        XCTAssertTrue(empty.isEmpty)
        let data = try JSONEncoder().encode(empty)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\"")
        let back = try JSONDecoder().decode(ORef.self, from: data)
        XCTAssertTrue(back.isEmpty)
    }

    // MARK: GUARDS §T — base64 is std in both directions

    func testBase64StdRoundTrip() {
        let raw = Data([0xFB, 0xFF, 0x3E, 0x00, 0x7E])  // forces '+' and '/' in std b64
        let encoded = WaveBase64.encode(raw)
        XCTAssertFalse(encoded.contains("-"))
        XCTAssertFalse(encoded.contains("_"))
        XCTAssertEqual(WaveBase64.decode(encoded), raw)
    }

    func testBase64DecodesKnownStdString() {
        XCTAssertEqual(WaveBase64.decode("aGVsbG8="), Data("hello".utf8))
    }

    // MARK: GUARDS §P — WAVESRV-ESTART parsing

    func testEStartParse() throws {
        let line = "WAVESRV-ESTART ws:127.0.0.1:1234 web:127.0.0.1:5678 version:0.1"
        let addrs = try ServerAddrs.parseEStart(line)
        XCTAssertEqual(addrs.wsAddr, "127.0.0.1:1234")
        XCTAssertEqual(addrs.webAddr, "127.0.0.1:5678")
        XCTAssertEqual(addrs.httpBaseURL, "http://127.0.0.1:5678")
        XCTAssertTrue(addrs.wsURL(stableId: "window:w1").hasPrefix("ws://127.0.0.1:1234/ws?stableid="))
    }

    func testEStartParseUnixAddrs() throws {
        // Socket paths ride percent-encoded (space-delimited ESTART line vs
        // "Application Support" in real data dirs).
        let line = "WAVESRV-ESTART ws:unix:/Users/x/Application%20Support/wn/ws.sock web:unix:/Users/x/Application%20Support/wn/web.sock version:0.1"
        let addrs = try ServerAddrs.parseEStart(line)
        XCTAssertEqual(ServerAddrs.unixPath(addrs.wsAddr), "/Users/x/Application Support/wn/ws.sock")
        XCTAssertEqual(ServerAddrs.unixPath(addrs.webAddr), "/Users/x/Application Support/wn/web.sock")
        XCTAssertEqual(addrs.httpBaseURL, "http://wavesrv")
        let wsURL = addrs.wsURL(stableId: "window:w1")
        XCTAssertTrue(wsURL.hasPrefix("ws+unix:/Users/x/Application%20Support/wn/ws.sock?stableid="))
        let url = try XCTUnwrap(URL(string: wsURL))
        XCTAssertEqual(url.scheme, "ws+unix")
        XCTAssertEqual(url.path, "/Users/x/Application Support/wn/ws.sock")
        XCTAssertNil(ServerAddrs.unixPath("127.0.0.1:1234"))
    }

    func testEStartParseFailsFast() {
        XCTAssertThrowsError(try ServerAddrs.parseEStart("garbage line"))
        XCTAssertThrowsError(try ServerAddrs.parseEStart("WAVESRV-ESTART web:127.0.0.1:5678"))
    }

    // MARK: GUARDS §A — WS framing is ASYMMETRIC

    func testOutboundFrameIsWscommand() throws {
        let msg = RpcMessage(command: "test", reqid: "r1")
        let frame = WSRpcCommand(message: msg)
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(frame)) as! [String: Any]
        XCTAssertEqual(json["wscommand"] as? String, "rpc")
        XCTAssertNotNil(json["message"])
        XCTAssertNil(json["eventtype"])
    }

    func testInboundFrameIsEventtype() throws {
        let inbound = #"{"eventtype":"rpc","data":{"resid":"r1","data":{"ok":true}}}"#
        let evt = try JSONDecoder().decode(WSRpcEvent.self, from: Data(inbound.utf8))
        XCTAssertEqual(evt.eventtype, "rpc")
        XCTAssertEqual(evt.data.resid, "r1")
    }

    func testPingPong() throws {
        let ping = try JSONDecoder().decode(WSPing.self, from: Data(#"{"type":"ping","stime":99}"#.utf8))
        XCTAssertEqual(ping.type, "ping")
        XCTAssertEqual(ping.stime, 99)
        let pong = try JSONEncoder().encode(WSPong())
        let obj = try JSONSerialization.jsonObject(with: pong) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "pong")
    }

    // MARK: RpcMessage omitempty + request/response semantics

    func testRpcMessageOmitsEmptyFields() throws {
        let msg = RpcMessage(command: "ping")
        let obj = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(msg)) as! [String: Any]
        XCTAssertEqual(obj["command"] as? String, "ping")
        XCTAssertNil(obj["reqid"])
        XCTAssertNil(obj["cont"])
        XCTAssertNil(obj["data"])
    }

    func testRpcMessageSemantics() {
        XCTAssertTrue(RpcMessage(command: "x").isRequest)
        XCTAssertFalse(RpcMessage(command: "x").wantsResponse)            // no reqid
        XCTAssertTrue(RpcMessage(command: "x", reqid: "r").wantsResponse)
        XCTAssertTrue(RpcMessage(resid: "r", cont: true).isContinuation)
    }

    // MARK: JSONValue + meta round-trip

    func testJSONValueRoundTrip() throws {
        let meta: MetaMapType = [
            "view": .string("term"),
            "web:zoom": .double(1.5),
            "count": .int(3),
            "flag": .bool(true),
            "nested": .object(["a": .array([.int(1), .int(2)])]),
        ]
        let data = try JSONEncoder().encode(meta)
        let back = try JSONDecoder().decode(MetaMapType.self, from: data)
        XCTAssertEqual(back["view"]?.stringValue, "term")
        XCTAssertEqual(back["web:zoom"]?.doubleValue, 1.5)
        XCTAssertEqual(back["count"]?.intValue, 3)
        XCTAssertEqual(back["flag"]?.boolValue, true)
        XCTAssertEqual(back["nested"]?["a"]?.arrayValue?.count, 2)
    }

    // MARK: GUARDS §B — version-guarded merge rule + AnyWaveObj dispatch

    func testWaveObjUpdateDecodeAndVersion() throws {
        let payload = #"""
        {"updatetype":"update","otype":"tab","oid":"t1",
         "obj":{"oid":"t1","version":7,"name":"main","layoutstate":"layout:l1",
                "blockids":["b1","b2"],"meta":{}}}
        """#
        let update = try JSONDecoder().decode(WaveObjUpdate.self, from: Data(payload.utf8))
        XCTAssertEqual(update.oref.string, "tab:t1")
        let obj = try XCTUnwrap(update.decodedObj())
        XCTAssertEqual(obj.otype, "tab")
        XCTAssertEqual(obj.oid, "t1")
        XCTAssertEqual(obj.version, 7)
        XCTAssertEqual(obj.asTab?.blockORefs.map(\.string), ["block:b1", "block:b2"])
        XCTAssertEqual(obj.asTab?.layoutStateORef?.string, "layout:l1")
    }

    /// GUARDS §B: "drop any update whose obj.version <= cached.version".
    func testVersionGuardRule() {
        func shouldApply(cached: Int, incoming: Int) -> Bool { incoming > cached }
        XCTAssertTrue(shouldApply(cached: 1, incoming: 2))
        XCTAssertFalse(shouldApply(cached: 5, incoming: 5))  // equal -> drop
        XCTAssertFalse(shouldApply(cached: 5, incoming: 4))  // older -> drop
    }

    // MARK: GUARDS §T — TermSize default {25,80}

    func testTermSizeDefault() {
        XCTAssertEqual(TermSize.default.rows, 25)
        XCTAssertEqual(TermSize.default.cols, 80)
    }

    // MARK: GUARDS §L — LayoutNode defaults + camelCase wire keys

    func testLayoutNodeDecodeDefaults() throws {
        let json = #"{"id":"n1","data":{"blockId":"b1"},"flexDirection":"column"}"#
        let node = try JSONDecoder().decode(LayoutNode.self, from: Data(json.utf8))
        XCTAssertEqual(node.id, "n1")
        XCTAssertEqual(node.data?.blockId, "b1")
        XCTAssertEqual(node.flexDirection, .column)
        XCTAssertEqual(node.size, 10)  // default
    }

    func testLayoutStateRootNodeRoundTrip() throws {
        var ls = LayoutState(oid: "l1", version: 1)
        let root = LayoutNode(
            id: "root",
            children: [LayoutNode(id: "leaf", data: TabLayoutData(blockId: "b1"))],
            flexDirection: .row)
        try ls.setRootLayoutNode(root)
        let decoded = try XCTUnwrap(ls.rootLayoutNode)
        XCTAssertEqual(decoded.children?.first?.data?.blockId, "b1")
    }

    // MARK: GUARDS §T — WaveFile circular clamp (DataStartIdx)

    func testWaveFileCircularClamp() {
        let max: Int64 = 2 * 1024 * 1024
        let f = WaveFile(
            zoneid: "b1", name: "term",
            opts: FileOpts(maxsize: max, circular: true),
            createdts: 0, size: max + 100, modts: 0)
        XCTAssertEqual(f.dataLength, max)
        XCTAssertEqual(f.dataStartIdx, 100)  // size - maxsize
    }

    // MARK: WebReturnType.updates present for GUARDS §B application

    func testWebReturnTypeUpdates() throws {
        let json = #"""
        {"success":true,"data":{"x":1},
         "updates":[{"updatetype":"update","otype":"block","oid":"b1",
                     "obj":{"oid":"b1","version":2,"meta":{"view":"web"}}}]}
        """#
        let ret = try JSONDecoder().decode(WebReturnType.self, from: Data(json.utf8))
        XCTAssertEqual(ret.success, true)
        XCTAssertEqual(ret.updates?.count, 1)
        let obj = try XCTUnwrap(ret.updates?.first?.decodedObj())
        XCTAssertEqual(obj.asBlock?.view, "web")
    }

    // MARK: termgetrunningcommands wire types (close confirmations)

    func testTermGetRunningCommandsWire() throws {
        let scope = CommandTermGetRunningCommandsData(tabid: "t1")
        let encoded = String(decoding: try JSONEncoder().encode(scope), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""tabid":"t1""#))
        XCTAssertFalse(encoded.contains("workspaceid"), "nil scope fields must be omitted")

        let json = #"[{"blockid":"b1","pid":123,"command":"vi"}]"#
        let cmds = try JSONDecoder().decode([TermRunningCommand].self, from: Data(json.utf8))
        XCTAssertEqual(cmds, [TermRunningCommand(blockid: "b1", pid: 123, command: "vi")])
    }
}
