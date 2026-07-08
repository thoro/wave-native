// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// E2E-4 (keystone) — the RECONCILER UNIT FUZZ that backs the live terminal fuzz
// in TerminalE2ETests.swift. This file is PURE (no wavesrv, no sockets, no pty):
// it drives `TerminalReconciler` directly with thousands of randomized
// subscribe-before-backfill / circular-wrap / truncate / reconnect-catch-up
// sequences and asserts the merged byte stream is the exact contiguous suffix of
// the true output — NO gaps, NO duplicates (PROTOCOL.md §4 "Output + backfill",
// GUARDS §T, the highest-risk guard).
//
// The model deliberately reproduces the lifecycle the reconciler is CONTRACTED
// for (and that the live harness drives): subscribe, then immediately GET from
// the same `requestedOffset` that equals the file tail at subscribe time, so the
// buffered live appends are exactly `file[requestedOffset...]`. Under that
// precondition the reconciler is byte-exact for:
//   * fresh mount         (requestedOffset == 0)
//   * reconnect catch-up  (requestedOffset == last consumed offset)
//   * circular wrap        (Size > maxsize -> DataStartIdx clamp, GUARDS §T)
//   * subscribe/backfill race (the GET captures only the first `k` buffered bytes;
//                              the rest raced in after the server Stat)
//   * partial straddle     (`k` lands in the middle of a buffered chunk)
//   * live truncate        (fileop=truncate -> clear + reset offset)
//
// Each failure prints the seed so the exact case is reproducible.

import XCTest
import WaveCore
@testable import WaveTerminal

// MARK: - Deterministic, reproducible RNG (SplitMix64)

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func randInt(_ g: inout SplitMix64, _ range: ClosedRange<Int>) -> Int {
    Int.random(in: range, using: &g)
}

/// Random non-empty chunk of distinct, position-encoding bytes is unnecessary —
/// the reconciler is byte-agnostic — so we use random bytes; correctness is
/// proven by exact-equality against the model, not by content inspection.
private func randChunk(_ g: inout SplitMix64, maxLen: Int) -> Data {
    let n = randInt(&g, 1...maxLen)
    var d = Data(count: n)
    for i in 0..<n { d[i] = UInt8.random(in: 0...255, using: &g) }
    return d
}

private func waveFile(size: Int64, maxsize: Int64) -> WaveFile {
    WaveFile(
        zoneid: "z", name: WaveProtocolConst.blockFileTerm,
        opts: FileOpts(maxsize: maxsize, circular: true),
        createdts: 0, size: size, modts: 0)
}

final class TerminalReconcilerFuzzTests: XCTestCase {

    /// The core property: one subscribe → buffered-append race → backfill cycle.
    /// Built from a model where `requestedOffset` is the file tail at subscribe,
    /// then asserts the delivered bytes == the file from `max(requested, DataStartIdx)`
    /// to the end of everything appended — exactly once, in order.
    func testFuzzBackfillReconcileNoGapNoDup() throws {
        for iteration in 0..<4000 {
            let seed = UInt64(0xA53C_0000 &+ iteration)
            var g = SplitMix64(seed: seed)

            let maxsize = Int64(randInt(&g, 16...512))
            let requested = Int64(randInt(&g, 0...4096))

            // Buffered appends that race the GET. Their concatenation is exactly
            // the file content from `requested` onward (the contract).
            let chunkCount = randInt(&g, 0...8)
            var chunks: [Data] = []
            var tail = Data()
            for _ in 0..<chunkCount {
                let c = randChunk(&g, maxLen: 40)
                chunks.append(c)
                tail.append(c)
            }
            let bufferedTotal = Int64(tail.count)

            // The GET is serviced after the first `k` buffered bytes were written.
            let k = Int64(randInt(&g, 0...Int(bufferedTotal)))
            let getSize = requested + k
            let dataStartIdx: Int64 = getSize > maxsize ? getSize - maxsize : 0
            let actualStart = Swift.max(requested, dataStartIdx)

            // Backfill bytes = file[actualStart, getSize) == tail[actualStart-requested ..< k].
            let lo = Int(actualStart - requested)
            let hi = Int(k)
            let backfill = tail.subdata(in: lo..<hi)

            var r = TerminalReconciler(startOffset: requested)
            for c in chunks { XCTAssertTrue(r.append(c).isEmpty, "seed=\(seed): buffered append must be queued") }

            let out: Data
            do {
                out = try r.applyBackfill(data: backfill, info: waveFile(size: getSize, maxsize: maxsize))
            } catch {
                return XCTFail("seed=\(seed): applyBackfill threw \(error)")
            }

            // Expected delivered = the contiguous suffix from actualStart to total.
            let expected = tail.subdata(in: lo..<tail.count)
            XCTAssertEqual(out, expected, "seed=\(seed): merged stream mismatch (gap/dup)")
            XCTAssertTrue(r.loaded, "seed=\(seed): must be loaded after backfill")
            XCTAssertEqual(r.absOffset, requested + bufferedTotal, "seed=\(seed): absOffset wrong")

            // A post-load live append must pass straight through, contiguously.
            let live = randChunk(&g, maxLen: 32)
            let liveOut = r.append(live)
            XCTAssertEqual(liveOut, live, "seed=\(seed): post-load append must pass through")
            XCTAssertEqual(r.absOffset, requested + bufferedTotal + Int64(live.count), "seed=\(seed): live offset")
        }
    }

    /// Live phase fuzz: after a load, an arbitrary interleaving of appends and
    /// truncates. Models the on-the-wire live event stream. Asserts the captured
    /// bytes equal the model exactly and the offset tracks (reset to 0 on
    /// truncate, GUARDS §T).
    func testFuzzLiveAppendsAndTruncates() throws {
        for iteration in 0..<3000 {
            let seed = UInt64(0xB711_0000 &+ iteration)
            var g = SplitMix64(seed: seed)

            var r = TerminalReconciler(startOffset: 0)
            _ = try r.applyBackfill(data: Data(), info: waveFile(size: 0, maxsize: 1024))
            XCTAssertEqual(r.absOffset, 0, "seed=\(seed)")

            var captured = Data() // bytes since the last truncate
            var expected = Data()
            var expectedOffset: Int64 = 0

            let ops = randInt(&g, 1...40)
            for _ in 0..<ops {
                if randInt(&g, 0...9) == 0 {
                    // truncate (clear + reset)
                    r.truncate()
                    captured.removeAll()
                    expected.removeAll()
                    expectedOffset = 0
                    XCTAssertEqual(r.absOffset, 0, "seed=\(seed): truncate must reset offset")
                    XCTAssertTrue(r.loaded, "seed=\(seed): truncate keeps loaded")
                } else {
                    let c = randChunk(&g, maxLen: 64)
                    let out = r.append(c)
                    captured.append(out)
                    expected.append(c)
                    expectedOffset += Int64(c.count)
                    XCTAssertEqual(out, c, "seed=\(seed): live append passthrough")
                    XCTAssertEqual(r.absOffset, expectedOffset, "seed=\(seed): offset tracks appends")
                }
            }
            XCTAssertEqual(captured, expected, "seed=\(seed): live stream diverged from model")
        }
    }

    /// Multi-epoch reconnect fuzz: repeatedly tear down and rebuild a reconciler
    /// seeded at the last consumed offset (the controller's `handleReconnect`
    /// pattern), each epoch racing a fresh batch of buffered appends against the
    /// catch-up GET. Asserts the WHOLE-run delivered stream equals the true output
    /// with no gap and no dup across every reconnect boundary.
    func testFuzzReconnectCatchUpAcrossEpochs() throws {
        for iteration in 0..<2000 {
            let seed = UInt64(0xC0DE_0000 &+ iteration)
            var g = SplitMix64(seed: seed)

            let maxsize = Int64(randInt(&g, 64...4096))
            var truth = Data()       // everything ever produced (within the live window)
            var delivered = Data()   // everything the sink has received
            var consumed: Int64 = 0  // absolute offset consumed so far (== truth.count here)

            let epochs = randInt(&g, 1...6)
            for _ in 0..<epochs {
                // Reconnect: subscribe + GET from the last consumed offset. The
                // file tail at subscribe == consumed (== truth.count), so buffered
                // appends are exactly file[consumed...].
                let requested = consumed
                var r = TerminalReconciler(startOffset: requested)

                let chunkCount = randInt(&g, 0...6)
                var tail = Data()
                for _ in 0..<chunkCount {
                    let c = randChunk(&g, maxLen: 48)
                    _ = r.append(c) // buffered (pre-backfill)
                    tail.append(c)
                    truth.append(c)
                }
                let bufferedTotal = Int64(tail.count)
                let k = Int64(randInt(&g, 0...Int(bufferedTotal)))
                let getSize = requested + k
                let dataStartIdx: Int64 = getSize > maxsize ? getSize - maxsize : 0
                let actualStart = Swift.max(requested, dataStartIdx)
                let backfill = tail.subdata(in: Int(actualStart - requested)..<Int(k))

                let out = try r.applyBackfill(data: backfill, info: waveFile(size: getSize, maxsize: maxsize))

                // On reconnect the GET may be clamped past `consumed` only if the
                // file overran maxsize while we were caught up — which cannot
                // happen here because requested == truth tail and we never advance
                // past maxsize within a single epoch's buffered batch unless the
                // batch itself exceeds maxsize. If clamped, the lost span is a real
                // circular drop; account for it in the model so the assertion stays
                // exact rather than masking a true gap.
                if actualStart > consumed {
                    // circular drop of [consumed, actualStart): bytes genuinely gone
                    delivered.append(truth.subdata(in: Int(consumed)..<Int(actualStart)))
                }
                delivered.append(out)
                consumed = r.absOffset

                // Some post-load live appends within the same connection.
                let liveCount = randInt(&g, 0...4)
                for _ in 0..<liveCount {
                    let c = randChunk(&g, maxLen: 32)
                    let lo = r.append(c)
                    delivered.append(lo)
                    truth.append(c)
                    consumed = r.absOffset
                }
            }

            XCTAssertEqual(delivered, truth, "seed=\(seed): multi-epoch stream diverged (gap/dup across reconnect)")
            XCTAssertEqual(consumed, Int64(truth.count), "seed=\(seed): final offset must equal total produced")
        }
    }

    /// G1 regression: output produced DURING an outage. At (re)subscribe the file
    /// tail S0 = requested + outageBytes (outageBytes >= 1), so S0 > requested and
    /// the buffered live appends begin at S0 — strictly past the offset we resumed
    /// from. The old reconciler anchored the buffer at `requestedOffset` and thus
    /// silently DROPPED those raced bytes. Content-overlap anchoring must instead
    /// deliver `file[actualStart...]` exactly and land `absOffset == S0 + buffered`.
    ///
    /// Bytes are partitioned by absolute position (high bit clear for offsets the
    /// backfill can cover, set for buffer-only offsets) so the largest-prefix
    /// content match is unambiguous: a false longer match would have to equate a
    /// buffer-only byte with a covered byte, which the high-bit split forbids.
    func testFuzzReconnectCatchUpWithOutageBytes() throws {
        for iteration in 0..<4000 {
            let seed = UInt64(0xD1A6_0000 &+ iteration)
            var g = SplitMix64(seed: seed)

            let maxsize = Int64(1_048_576) // large: no circular clamp in this property
            let requested = Int64(randInt(&g, 0...4096))
            let outageBytes = randInt(&g, 1...256) // produced during the outage -> S0 > requested
            let bufferedTotal = randInt(&g, 1...320)
            let overlap = randInt(&g, 0...bufferedTotal) // buffered bytes that landed before the GET
            let total = outageBytes + bufferedTotal
            let clearEnd = outageBytes + overlap

            // truth == file[requested, end). Offsets < clearEnd (outage + the
            // overlap the GET captured) carry a clear high bit; buffer-only offsets
            // carry a set high bit.
            var truth = Data(count: total)
            for i in 0..<total {
                truth[i] = i < clearEnd ? UInt8.random(in: 0...127, using: &g)
                    : UInt8.random(in: 128...255, using: &g)
            }

            // Buffered live appends begin at the real tail S0 (== content[outageBytes]).
            var chunks: [Data] = []
            var idx = outageBytes
            while idx < total {
                let n = randInt(&g, 1...Swift.min(40, total - idx))
                chunks.append(truth.subdata(in: idx..<idx + n))
                idx += n
            }

            let s0 = requested + Int64(outageBytes)
            let getSize = s0 + Int64(overlap)
            let backfill = truth.subdata(in: 0..<clearEnd) // file[requested, getSize)

            var r = TerminalReconciler(startOffset: requested)
            for c in chunks { XCTAssertTrue(r.append(c).isEmpty, "seed=\(seed): buffered append must be queued") }

            let out: Data
            do {
                out = try r.applyBackfill(data: backfill, info: waveFile(size: getSize, maxsize: maxsize))
            } catch {
                return XCTFail("seed=\(seed): applyBackfill threw \(error)")
            }

            XCTAssertEqual(out, truth, "seed=\(seed): outage bytes dropped (G1)")
            XCTAssertTrue(r.loaded, "seed=\(seed): must be loaded after backfill")
            XCTAssertEqual(r.absOffset, s0 + Int64(bufferedTotal), "seed=\(seed): absOffset must be S0 + buffered")

            let live = randChunk(&g, maxLen: 32)
            let liveOut = r.append(live)
            XCTAssertEqual(liveOut, live, "seed=\(seed): post-load append must pass through")
            XCTAssertEqual(r.absOffset, s0 + Int64(bufferedTotal) + Int64(live.count), "seed=\(seed): live offset")
        }
    }
}
