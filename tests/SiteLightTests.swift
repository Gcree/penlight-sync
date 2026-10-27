import Foundation
import Network

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    if !condition() {
        fatalError("\(file):\(line): \(message)")
    }
}

@main
struct SiteLightTests {
    static func main() {
        testMovieTimeCalculation()
        testBeatCadenceAndBarStart()
        testColorChangeEveryTwoBeats()
        testHypeCueAcceleratesColorChange()
        testContinuousDrumRollRapidSwitching()
        testColorChangeEveryFourSecondsWithoutBeat()
        testListenCueDoesNotBeat()
        testClimaxEightBeats()
        testOlderSeqDiscarded()
        testFiveSecondsTimeoutWaiting()
        testMalformedJsonAndSizeLimitAndVersion()
        testSiteLinkOriginRejection()

        print("SiteLight self-tests passed")
    }

    // 1. 時間推算（播放、暫停、0.5 倍速）
    static func testMovieTimeCalculation() {
        let now = Date()
        let receivedAt = now.addingTimeInterval(-2.0) // 2 seconds ago

        let playingState = SiteState(
            seq: 1, song: "odo", title: "踊", playing: true, t: 10.0, rate: 1.0, colors: ["#ff4a5a"]
        )
        let t1 = SiteLightEvaluator.calculateMovieTime(state: playingState, receivedAt: receivedAt, now: now)
        expect(abs(t1 - 12.0) < 0.001, "Playing at 1.0x should advance movie time by elapsed seconds: \(t1)")

        let pausedState = SiteState(
            seq: 2, song: "odo", title: "踊", playing: false, t: 10.0, rate: 1.0, colors: ["#ff4a5a"]
        )
        let t2 = SiteLightEvaluator.calculateMovieTime(state: pausedState, receivedAt: receivedAt, now: now)
        expect(abs(t2 - 10.0) < 0.001, "Paused state must keep movie time at t: \(t2)")

        let halfSpeedState = SiteState(
            seq: 3, song: "odo", title: "踊", playing: true, t: 10.0, rate: 0.5, colors: ["#ff4a5a"]
        )
        let t3 = SiteLightEvaluator.calculateMovieTime(state: halfSpeedState, receivedAt: receivedAt, now: now)
        expect(abs(t3 - 11.0) < 0.001, "0.5x speed should advance movie time at half rate: \(t3)")
    }

    // 2. 128 BPM 下 10 秒內送出的拍數和小節第一拍
    static func testBeatCadenceAndBarStart() {
        let evaluator = SiteLightEvaluator()
        let beat = SiteBeat(bpm: 128.0, offset: 0.0, barKnown: true)
        let baseDate = Date()
        var seq = 1
        evaluator.updateState(
            SiteState(seq: seq, song: "odo", title: "踊", playing: true, t: 0.0, rate: 1.0,
                      colors: ["#ff4a5a", "#5d9dfe"], beat: beat),
            receivedAt: baseDate
        )

        // Step at 60 Hz for 10 seconds, refreshing state every 1 second (per protocol)
        var beatCount = 0
        var barStartCount = 0
        let dt = 1.0 / 60.0
        let totalSteps = Int(10.0 / dt)

        for i in 0...totalSteps {
            let now = baseDate.addingTimeInterval(Double(i) * dt)
            if i > 0 && i % 60 == 0 {
                seq += 1
                evaluator.updateState(
                    SiteState(seq: seq, song: "odo", title: "踊", playing: true, t: Double(i) * dt, rate: 1.0,
                              colors: ["#ff4a5a", "#5d9dfe"], beat: beat),
                    receivedAt: now
                )
            }
            let frame = evaluator.evaluate(now: now)
            if frame.shouldBeat {
                beatCount += 1
                if frame.isBarStart {
                    barStartCount += 1
                    expect(frame.beatStrength == 1.0, "Bar start with barKnown should have strength 1.0: \(frame.beatStrength)")
                } else {
                    expect(frame.beatStrength == 0.6, "Normal beat should have strength 0.6: \(frame.beatStrength)")
                }
            }
        }

        // At 128 BPM, interval is 60/128 = 0.46875 s. 10.0 / 0.46875 = 21.33 beats.
        expect(beatCount == 21, "128 BPM over 10s should trigger 21 beats, got: \(beatCount)")
        expect(barStartCount == 5, "Should have 5 bar starts within 21 beats, got: \(barStartCount)")
    }

    // 3. 正常段落 1～2 拍換色（每 2 拍換下一個顏色）
    static func testColorChangeEveryTwoBeats() {
        let evaluator = SiteLightEvaluator()
        let beat = SiteBeat(bpm: 120.0, offset: 0.0, barKnown: true) // 0.5s per beat, 1.0s per 2 beats
        let red = ScreenRGB.fromHex("#ff4a5a")!
        let blue = ScreenRGB.fromHex("#5d9dfe")!
        let baseDate = Date()
        let state = SiteState(
            seq: 1, song: "odo", title: "踊", playing: true, t: 0.0, rate: 1.0,
            colors: ["#ff4a5a", "#5d9dfe"], beat: beat
        )
        evaluator.updateState(state, receivedAt: baseDate)

        // 0.0s .. 0.9s (Beat 0~1) -> Red
        let frame0 = evaluator.evaluate(now: baseDate.addingTimeInterval(0.5))
        expect(frame0.targetColor == red, "Beat 0-1 must be red, got \(frame0.targetColor)")

        // 1.0s .. 1.9s (Beat 2~3) -> Blue
        let frame1 = evaluator.evaluate(now: baseDate.addingTimeInterval(1.5))
        expect(frame1.targetColor == blue, "Beat 2-3 must switch to blue, got \(frame1.targetColor)")

        // 2.0s .. 2.9s (Beat 4~5) -> Red
        let frame2 = evaluator.evaluate(now: baseDate.addingTimeInterval(2.5))
        expect(frame2.targetColor == red, "Beat 4-5 must cycle back to red, got \(frame2.targetColor)")
    }

    // 3b. 嗨歌動作（jump、call、clap）每 1 拍換色加速
    static func testHypeCueAcceleratesColorChange() {
        let evaluator = SiteLightEvaluator()
        let beat = SiteBeat(bpm: 120.0, offset: 0.0, barKnown: true) // 0.5s per beat
        let red = ScreenRGB.fromHex("#ff4a5a")!
        let blue = ScreenRGB.fromHex("#5d9dfe")!
        let baseDate = Date()
        let state = SiteState(
            seq: 1, song: "odo", title: "踊", playing: true, t: 0.0, rate: 1.0,
            colors: ["#ff4a5a", "#5d9dfe"], beat: beat, cue: "jump"
        )
        evaluator.updateState(state, receivedAt: baseDate)

        // Beat 0 (0.0s .. 0.49s) -> Red
        let f0 = evaluator.evaluate(now: baseDate.addingTimeInterval(0.2))
        expect(f0.targetColor == red, "Hype cue beat 0 must be red, got \(f0.targetColor)")

        // Beat 1 (0.5s .. 0.99s) -> Blue (每 1 拍換色)
        let f1 = evaluator.evaluate(now: baseDate.addingTimeInterval(0.7))
        expect(f1.targetColor == blue, "Hype cue beat 1 must switch to blue, got \(f1.targetColor)")

        // Beat 2 (1.0s .. 1.49s) -> Red
        let f2 = evaluator.evaluate(now: baseDate.addingTimeInterval(1.2))
        expect(f2.targetColor == red, "Hype cue beat 2 must cycle back to red, got \(f2.targetColor)")
    }

    // 3c. 連續鼓聲／副歌高潮（climax）每 0.5 拍極速切換
    static func testContinuousDrumRollRapidSwitching() {
        let evaluator = SiteLightEvaluator()
        let beat = SiteBeat(bpm: 120.0, offset: 0.0, barKnown: true) // 0.5s per beat, 0.25s per half-beat
        let red = ScreenRGB.fromHex("#ff4a5a")!
        let blue = ScreenRGB.fromHex("#5d9dfe")!
        let baseDate = Date()
        let state = SiteState(
            seq: 1, song: "odo", title: "踊", playing: true, t: 100.0, rate: 1.0,
            colors: ["#ff4a5a", "#5d9dfe"], beat: beat, climax: 100.0
        )
        evaluator.updateState(state, receivedAt: baseDate)

        // 0.0s .. 0.24s (Sub-beat 0) -> Red
        let f0 = evaluator.evaluate(now: baseDate.addingTimeInterval(0.1))
        expect(f0.targetColor == red, "Sub-beat 0 must be red, got \(f0.targetColor)")

        // 0.25s .. 0.49s (Sub-beat 1) -> Blue
        let f1 = evaluator.evaluate(now: baseDate.addingTimeInterval(0.35))
        expect(f1.targetColor == blue, "Sub-beat 1 must switch to blue, got \(f1.targetColor)")

        // 0.50s .. 0.74s (Sub-beat 2) -> Red
        let f2 = evaluator.evaluate(now: baseDate.addingTimeInterval(0.6))
        expect(f2.targetColor == red, "Sub-beat 2 must cycle back to red, got \(f2.targetColor)")
    }

    // 4. 沒有拍點時每 4 秒換色
    static func testColorChangeEveryFourSecondsWithoutBeat() {
        let evaluator = SiteLightEvaluator()
        let red = ScreenRGB.fromHex("#ff4a5a")!
        let blue = ScreenRGB.fromHex("#5d9dfe")!
        let baseDate = Date()
        let state = SiteState(
            seq: 1, song: "value", title: "Value", playing: true, t: 0.0, rate: 1.0,
            colors: ["#ff4a5a", "#5d9dfe"], beat: nil
        )
        evaluator.updateState(state, receivedAt: baseDate)

        // 0s .. 3.9s -> Red
        let frame0 = evaluator.evaluate(now: baseDate.addingTimeInterval(2.0))
        expect(frame0.targetColor == red, "0-4s should be red, got \(frame0.targetColor)")
        expect(!frame0.shouldBeat, "Without beat data, shouldBeat must be false")

        // 4s .. 7.9s -> Blue
        let frame1 = evaluator.evaluate(now: baseDate.addingTimeInterval(4.5))
        expect(frame1.targetColor == blue, "4-8s should be blue, got \(frame1.targetColor)")

        // Keep state fresh at 5.0s per 1s protocol update
        evaluator.updateState(
            SiteState(seq: 2, song: "value", title: "Value", playing: true, t: 5.0, rate: 1.0,
                      colors: ["#ff4a5a", "#5d9dfe"], beat: nil),
            receivedAt: baseDate.addingTimeInterval(5.0)
        )

        // 8s .. 11.9s -> Red
        let frame2 = evaluator.evaluate(now: baseDate.addingTimeInterval(8.5))
        expect(frame2.targetColor == red, "8-12s should cycle back to red, got \(frame2.targetColor)")
    }

    // 5. listen 不送拍子，亮度降到大約一半
    static func testListenCueDoesNotBeat() {
        let evaluator = SiteLightEvaluator()
        let beat = SiteBeat(bpm: 120.0, offset: 0.0, barKnown: true)
        let baseDate = Date()
        let state = SiteState(
            seq: 1, song: "test", title: "Test", playing: true, t: 0.0, rate: 1.0,
            colors: ["#ff4a5a"], beat: beat, cue: "listen"
        )
        evaluator.updateState(state, receivedAt: baseDate)

        _ = evaluator.evaluate(now: baseDate)
        // Advance past beat 1 (0.5s)
        let frame = evaluator.evaluate(now: baseDate.addingTimeInterval(0.6))
        expect(!frame.shouldBeat, "cue='listen' must not trigger beats")
        expect(frame.brightnessMultiplier == 0.5, "cue='listen' must scale brightness to ~0.5: \(frame.brightnessMultiplier)")
    }

    // 6. 高潮 8 拍
    static func testClimaxEightBeats() {
        let evaluator = SiteLightEvaluator()
        let beat = SiteBeat(bpm: 120.0, offset: 0.0, barKnown: true) // 0.5s per beat; 8 beats = 4.0s
        let baseDate = Date()
        let state = SiteState(
            seq: 1, song: "odo", title: "踊", playing: true, t: 50.0, rate: 1.0,
            colors: ["#ff4a5a"], beat: beat, climax: 50.0
        )
        evaluator.updateState(state, receivedAt: baseDate)

        // At t = 50.0 (climax start)
        let frameStart = evaluator.evaluate(now: baseDate)
        expect(frameStart.isClimax, "t=50 should be in climax")
        expect(frameStart.brightnessMultiplier == 1.0, "Climax must be full brightness")

        // At t = 53.5 (still in 8 beats duration = 4.0s)
        let frameMid = evaluator.evaluate(now: baseDate.addingTimeInterval(3.5))
        expect(frameMid.isClimax, "t=53.5 should still be in climax")

        // At t = 54.1 (after 8 beats)
        let frameAfter = evaluator.evaluate(now: baseDate.addingTimeInterval(4.1))
        expect(!frameAfter.isClimax, "t=54.1 must exit climax")
    }

    // 7. 舊的 seq 被丟掉
    static func testOlderSeqDiscarded() {
        let evaluator = SiteLightEvaluator()
        let state1 = SiteState(
            seq: 42, song: "odo", title: "踊", playing: true, t: 10.0, rate: 1.0, colors: ["#ff4a5a"]
        )
        let accepted1 = evaluator.updateState(state1)
        expect(accepted1, "New seq 42 must be accepted")

        let stateOlder = SiteState(
            seq: 41, song: "odo", title: "踊", playing: true, t: 12.0, rate: 1.0, colors: ["#5d9dfe"]
        )
        let acceptedOlder = evaluator.updateState(stateOlder)
        expect(!acceptedOlder, "Older seq 41 must be rejected")
        expect(evaluator.latestState?.seq == 42, "Current state must remain seq 42")

        let stateDuplicate = SiteState(
            seq: 42, song: "odo", title: "踊", playing: true, t: 13.0, rate: 1.0, colors: ["#5d9dfe"]
        )
        let acceptedDup = evaluator.updateState(stateDuplicate)
        expect(!acceptedDup, "Duplicate seq 42 must be rejected")
    }

    // 8. 5 秒沒收到訊息進入等待
    static func testFiveSecondsTimeoutWaiting() {
        let evaluator = SiteLightEvaluator()
        let baseDate = Date()
        let red = ScreenRGB.fromHex("#ff4a5a")!
        let state = SiteState(
            seq: 1, song: "odo", title: "踊", playing: true, t: 10.0, rate: 1.0, colors: ["#ff4a5a"]
        )
        evaluator.updateState(state, receivedAt: baseDate)

        // 4 seconds later: still active
        let frameActive = evaluator.evaluate(now: baseDate.addingTimeInterval(4.0))
        expect(!frameActive.isWaiting, "At 4.0s should not be waiting")
        expect(frameActive.brightnessMultiplier == 1.0, "Active brightness should be 1.0")
        expect(frameActive.targetColor == red, "Target color must be red")

        // 5.1 seconds later: entering waiting
        let frameWaiting = evaluator.evaluate(now: baseDate.addingTimeInterval(5.1))
        expect(frameWaiting.isWaiting, "At 5.1s should enter waiting state")
        expect(frameWaiting.brightnessMultiplier == 0.3, "Waiting brightness must drop to 30%: \(frameWaiting.brightnessMultiplier)")
        expect(frameWaiting.targetColor == red, "Waiting state must maintain the last color: \(frameWaiting.targetColor)")
        expect(!frameWaiting.shouldBeat, "Waiting state must not beat")

        // New state arrives: recovers from waiting
        let state2 = SiteState(
            seq: 2, song: "odo", title: "踊", playing: true, t: 15.0, rate: 1.0, colors: ["#ff4a5a"]
        )
        evaluator.updateState(state2, receivedAt: baseDate.addingTimeInterval(5.5))
        let frameRecovered = evaluator.evaluate(now: baseDate.addingTimeInterval(5.6))
        expect(!frameRecovered.isWaiting, "New state should restore active state")
        expect(frameRecovered.brightnessMultiplier == 1.0, "Restored brightness should be 1.0")
    }

    // 9. 壞掉的 JSON、超過 4 KB、v: 2 都被忽略
    static func testMalformedJsonAndSizeLimitAndVersion() {
        // Corrupted JSON
        let malformedData = "{ this is not json }".data(using: .utf8)!
        let res1 = SiteLinkMessageParser.parse(data: malformedData)
        expect(res1 == .ignored, "Malformed JSON must be ignored")

        // Over 4 KB
        let largeString = "{\"v\":1,\"type\":\"state\",\"seq\":1,\"song\":\"\(String(repeating: "a", count: 5000))\"}"
        let largeData = largeString.data(using: .utf8)!
        expect(largeData.count > 4096, "Data must exceed 4096 bytes")
        let res2 = SiteLinkMessageParser.parse(data: largeData)
        expect(res2 == .ignored, "Messages exceeding 4 KB must be ignored")

        // v: 2 (unsupported version)
        let v2String = "{\"v\":2,\"type\":\"state\",\"seq\":1,\"song\":\"odo\",\"title\":\"踊\",\"playing\":true,\"t\":0,\"rate\":1,\"colors\":[\"#ff4a5a\"]}"
        let v2Data = v2String.data(using: .utf8)!
        let res3 = SiteLinkMessageParser.parse(data: v2Data)
        expect(res3 == .ignored, "v: 2 must be ignored")

        // Valid state
        let validString = "{\"v\":1,\"type\":\"state\",\"seq\":10,\"song\":\"odo\",\"title\":\"踊\",\"playing\":true,\"t\":1.5,\"rate\":1,\"colors\":[\"#ff4a5a\"],\"beat\":{\"bpm\":120,\"offset\":0.5,\"barKnown\":true}}"
        let validData = validString.data(using: .utf8)!
        let res4 = SiteLinkMessageParser.parse(data: validData)
        if case .state(let parsedState) = res4 {
            expect(parsedState.seq == 10, "Valid state should be parsed")
            expect(parsedState.beat?.bpm == 120, "Beat bpm should match")
        } else {
            fatalError("Valid state was not parsed")
        }

        // Valid stop
        let stopString = "{\"v\":1,\"type\":\"stop\"}"
        let stopData = stopString.data(using: .utf8)!
        let res5 = SiteLinkMessageParser.parse(data: stopData)
        expect(res5 == .stop, "Stop message should be parsed as .stop")
    }

    // SiteLink: 不在白名單的 Origin 被拒絕
    static func testSiteLinkOriginRejection() {
        let link = SiteLink()
        link.start()

        // Wait for listener to be ready or detect port in use
        var ready = false
        for _ in 0..<40 {
            if link.isListening { ready = true; break }
            if link.portInUse { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if link.portInUse {
            print("Notice: Port 51730 is in use by another process, skipping live socket test")
            return
        }
        expect(ready, "SiteLink should be listening")

        // 1. Connect with rejected origin
        let session = URLSession(configuration: .default)
        var badReq = URLRequest(url: URL(string: "ws://127.0.0.1:51730/ado")!)
        badReq.setValue("https://evil.com", forHTTPHeaderField: "Origin")

        let badTask = session.webSocketTask(with: badReq)
        badTask.resume()

        let badSemaphore = DispatchSemaphore(value: 0)
        var badError: Error?
        badTask.receive { result in
            switch result {
            case .success(let msg):
                fatalError("Rejected origin should not receive success: \(msg)")
            case .failure(let err):
                badError = err
                badSemaphore.signal()
            }
        }

        let badWait = badSemaphore.wait(timeout: .now() + 3.0)
        expect(badWait == .success, "Rejection handshake should complete within 3s")
        expect(badError != nil, "Connection from unauthorized Origin must fail with error")

        // 2. Connect with valid origin
        var goodReq = URLRequest(url: URL(string: "ws://127.0.0.1:51730/ado")!)
        goodReq.setValue("https://gcree.github.io", forHTTPHeaderField: "Origin")

        let goodTask = session.webSocketTask(with: goodReq)
        let acceptedSemaphore = DispatchSemaphore(value: 0)
        var goodError: Error?

        goodTask.resume()
        goodTask.send(.string("{\"v\":1,\"type\":\"stop\"}")) { error in
            goodError = error
            acceptedSemaphore.signal()
        }

        let goodWait = acceptedSemaphore.wait(timeout: .now() + 3.0)
        expect(goodWait == .success, "Accepted handshake should complete within 3s")
        expect(goodError == nil, "Connection from authorized Origin should succeed: \(String(describing: goodError))")

        goodTask.cancel()
        badTask.cancel()
        link.stop()
    }
}
