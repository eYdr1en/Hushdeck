import Foundation
import Testing
@testable import HeadsetControlKit

@Suite("Client (canned output)")
struct ClientTests {
    let binary = URL(fileURLWithPath: "/usr/bin/false")

    @Test func statusArgumentsIncludeTestDevice() async throws {
        let runner = MockRunner([CommandResult(exitCode: 0, stdout: try Fixture.data("status_full"), stderr: Data())])
        let client = HeadsetControlClient(configuration: .init(binary: binary, testDevice: .on(profile: nil)), runner: runner)
        let output = try await client.status()
        #expect(output.devices.count == 1)
        #expect(runner.recordedCalls == [["--test-device", "-o", "json"]])
    }

    @Test func profileIsPassedWithEquals() async throws {
        let runner = MockRunner([CommandResult(exitCode: 0, stdout: try Fixture.data("status_charging"), stderr: Data())])
        let client = HeadsetControlClient(configuration: .init(binary: binary, testDevice: .on(profile: 2)), runner: runner)
        _ = try await client.status()
        #expect(runner.recordedCalls.first?.first == "--test-device=2")
    }

    @Test func noDeviceExitCodeOneIsNotAnError() async throws {
        let runner = MockRunner([CommandResult(exitCode: 1, stdout: try Fixture.data("status_no_device"), stderr: Data())])
        let client = HeadsetControlClient(configuration: .init(binary: binary), runner: runner)
        let output = try await client.status()
        #expect(output.devices.isEmpty)
        #expect(runner.recordedCalls == [["-o", "json"]])
    }

    @Test func applyBuildsOneCallWithDeviceFilter() async throws {
        let runner = MockRunner([CommandResult(exitCode: 0, stdout: try Fixture.data("action_multiple"), stderr: Data())])
        let client = HeadsetControlClient(configuration: .init(binary: binary, testDevice: .on(profile: nil)), runner: runner)
        let results = try await client.apply([.sidetone(50), .lights(true), .inactiveTime(minutes: 30)], to: .testDevice)
        #expect(results.count == 3)
        #expect(runner.recordedCalls == [[
            "--test-device", "-o", "json", "--device=f00b:a00c", "--sidetone=50", "--light=1", "--inactive-time=30",
        ]])
    }

    @Test func applyNothingDoesNotSpawn() async throws {
        let runner = MockRunner([])
        let client = HeadsetControlClient(configuration: .init(binary: binary), runner: runner)
        #expect(try await client.apply([]).isEmpty)
        #expect(runner.recordedCalls.isEmpty)
    }

    @Test func partialFailureReturnsResults() async throws {
        let runner = MockRunner([CommandResult(exitCode: 0, stdout: try Fixture.data("action_partial_failure"), stderr: Data())])
        let client = HeadsetControlClient(configuration: .init(binary: binary), runner: runner)
        let results = try await client.apply([.sidetone(5), .lights(true)])
        #expect(results.filter { !$0.succeeded }.map(\.capability) == [.sidetone])
    }

    @Test func totalFailureThrows() async throws {
        let json = #"{"actions":[{"capability":"CAP_SIDETONE","device":"X","status":"failure","error_message":"HID communication error"}],"device_count":1,"devices":[{"device":"X","capabilities":["CAP_SIDETONE"]}]}"#
        let runner = MockRunner([CommandResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())])
        let client = HeadsetControlClient(configuration: .init(binary: binary), runner: runner)
        await #expect(throws: HeadsetControlError.self) {
            try await client.apply([.sidetone(5)])
        }
        do {
            try await client.apply([.sidetone(5)])
        } catch let error as HeadsetControlError {
            // Second call has no canned output left.
            #expect(error == .launchFailed("no canned result"))
        }
    }

    @Test func applyWithNoDeviceThrowsNoDevice() async throws {
        let runner = MockRunner([CommandResult(exitCode: 1, stdout: try Fixture.data("status_no_device"), stderr: Data())])
        let client = HeadsetControlClient(configuration: .init(binary: binary), runner: runner)
        await #expect(throws: HeadsetControlError.noDevice) {
            try await client.apply([.sidetone(5)])
        }
    }

    @Test func argumentErrorsSurfaceStderr() async throws {
        let runner = MockRunner([CommandResult(exitCode: 1, stdout: Data(), stderr: Data("Error: sidetone: value 200 out of range [0, 128]\n".utf8))])
        let client = HeadsetControlClient(configuration: .init(binary: binary), runner: runner)
        await #expect(throws: HeadsetControlError.commandFailed(exitCode: 1, message: "sidetone: value 200 out of range [0, 128]")) {
            try await client.status()
        }
    }

    @Test func garbageOutputIsInvalid() {
        #expect(throws: HeadsetControlError.self) {
            try HeadsetControlClient.interpret(CommandResult(exitCode: 0, stdout: Data("{ nope".utf8), stderr: Data()))
        }
    }

    @Test func errorMessagesAreReadable() {
        let failure = HeadsetControlError.actionsFailed([ActionResult(capability: .sidetone, status: .failure, errorMessage: "HID communication error")])
        #expect(failure.localizedDescription == "Sidetone: HID communication error.")
        #expect(HeadsetControlError.binaryNotFound.localizedDescription.contains("HeadsetControl"))
    }
}

@Suite("Process runner")
struct ProcessRunnerTests {
    @Test func capturesOutputAndExitCode() async throws {
        let result = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: .seconds(5))
        #expect(result.exitCode == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
        #expect(result.stderrText == "err")
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let result = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "head -c 300000 /dev/zero; head -c 300000 /dev/zero >&2"], timeout: .seconds(10))
        #expect(result.stdout.count == 300_000)
        #expect(result.stderr.count == 300_000)
    }

    @Test func timesOut() async throws {
        let start = ContinuousClock.now
        await #expect(throws: HeadsetControlError.self) {
            try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func missingExecutable() async {
        await #expect(throws: HeadsetControlError.self) {
            try await ProcessRunner().run(URL(fileURLWithPath: "/nonexistent/headsetcontrol"), arguments: [], timeout: .seconds(1))
        }
    }
}
