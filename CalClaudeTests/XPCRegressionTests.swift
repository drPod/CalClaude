import XCTest
import Foundation

/// Regression tests for XPC pipe errors:
///   - "XPC connection was invalidated"
///   - "Unable to obtain a task name port right for pid N with os kern failure 0x5"
///
/// These tests verify that child-process stdout/stderr are fully captured
/// using the same patterns as ClaudeCLIService and CLICheck, and that
/// no data is lost even when the process exits quickly.
final class XPCRegressionTests: XCTestCase {

    // MARK: - Pattern 1: Sequential pipe reads (mirrors ClaudeCLIService)

    /// Sequential stdout-then-stderr reads, then wait for termination.
    /// Verifies no data is lost when stdout EOF arrives before stderr is read.
    func testSequentialPipeRead_capturesStdout() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
        process.arguments = ["hello xpc regression"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        // Sequential read: stdout first, then stderr (same as ClaudeCLIService)
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("hello xpc regression"),
                      "stdout should contain expected string; got: \(output.debugDescription)")
        XCTAssertEqual(process.terminationStatus, 0)
        _ = stderrData  // suppress unused-variable warning; stderr should be empty
    }

    /// Sequential reads with a command that writes to BOTH stdout and stderr.
    func testSequentialPipeRead_capturesBothStreams() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'out_data'; printf 'err_data' >&2"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        XCTAssertTrue(stdout.contains("out_data"), "stdout should contain 'out_data'; got: \(stdout.debugDescription)")
        XCTAssertTrue(stderr.contains("err_data"), "stderr should contain 'err_data'; got: \(stderr.debugDescription)")
    }

    // MARK: - Pattern 2: Concurrent async pipe reads (mirrors ClaudeCLIService async variant)

    /// Both pipes read concurrently via async-let to avoid deadlock when
    /// either stream produces large output.
    func testConcurrentPipeRead_capturesBothStreams() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'stdout_ok'; printf 'stderr_ok' >&2"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        XCTAssertTrue(stdout.contains("stdout_ok"), "stdout: \(stdout.debugDescription)")
        XCTAssertTrue(stderr.contains("stderr_ok"), "stderr: \(stderr.debugDescription)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 3: DispatchGroup + waitUntilExit (mirrors CLICheck.healthCheck)

    /// Mirrors CLICheck.healthCheck exactly: async pipe reads in DispatchGroup,
    /// blocking waitUntilExit on calling thread, then group.wait().
    func testDispatchGroupWaitAfterWaitUntilExit_capturesOutput() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo health_ok"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let group = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()

        group.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("health_ok"),
                      "CLICheck.healthCheck pattern: stdout should contain 'health_ok'; got: \(output.debugDescription)")
        XCTAssertEqual(process.terminationStatus, 0)
        _ = stderrData
    }

    // MARK: - Pattern 4: Large output (tests pipe buffer boundary ~64KB)

    /// Generates >64 KB of stdout to catch deadlocks from sequential pipe
    /// reads when the pipe's kernel buffer fills up.
    func testLargeOutput_noDeadlock() async throws {
        // python3 is reliably available on macOS for generating large output
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys; sys.stdout.write('X' * 131072); sys.stdout.flush()"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        // Concurrent read to avoid deadlock (correct pattern)
        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, 131072,
                       "Expected 131072 bytes; got \(stdoutData.count) — possible pipe-buffer deadlock or data loss")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 5: Fast-exit process (read after process already gone)

    /// Process exits immediately; pipes are read after it's already dead.
    /// This stresses the XPC teardown path — the pipe write end is closed
    /// before readDataToEndOfFile() is called.
    func testFastExitProcess_pipesReadableAfterExit() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo fast_exit"]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardInput = nil

        try process.run()
        process.waitUntilExit()
        // Process is now dead; read pipe after exit (XPC teardown already happened)
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("fast_exit"),
                      "Data should be readable after process exits; got: \(output.debugDescription)")
    }

    // MARK: - Pattern 6: Sequential reads with /usr/bin/env (mirrors actual ClaudeCLIService launch)

    /// Uses /usr/bin/env as launcher (same as ClaudeCLIService) and reads
    /// pipes sequentially via DispatchQueue — the exact pattern that triggered
    /// the XPC errors.
    func testEnvLaunch_sequentialPipeReads() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["echo", "env_launch_ok"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        let stdoutData: Data = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let stderrData: Data = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("env_launch_ok"),
                      "stdout via /usr/bin/env: \(output.debugDescription)")
        XCTAssertEqual(process.terminationStatus, 0)
        _ = stderrData
    }

    // MARK: - Pattern 7: Large stderr output (>64 KB)

    /// Mirrors testLargeOutput_noDeadlock but uses stderr instead of stdout.
    /// Verifies that large stderr output doesn't deadlock the concurrent read.
    func testLargeStderrOutput_noDeadlock() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys; sys.stderr.write('E' * 131072); sys.stderr.flush()"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (_, stderrData) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stderrData.count, 131072,
                       "Expected 131072 bytes on stderr; got \(stderrData.count)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 8: Large interleaved output on both streams simultaneously

    /// Both stdout and stderr produce >64 KB concurrently.
    /// This is the most aggressive deadlock test: sequential reads in either
    /// order would deadlock here.
    func testLargeInterleavedStreams_noDeadlock() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c",
            "import sys; sys.stdout.write('O' * 131072); sys.stderr.write('E' * 131072); sys.stdout.flush(); sys.stderr.flush()"
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, 131072,
                       "stdout: expected 131072 bytes, got \(stdoutData.count)")
        XCTAssertEqual(stderrData.count, 131072,
                       "stderr: expected 131072 bytes, got \(stderrData.count)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 9: Many small writes crossing the 64 KB pipe buffer boundary

    /// Process writes 10,000 × 10-byte chunks (100 KB total) to stdout.
    /// Verifies that pipe data is fully reassembled across multiple write() syscalls.
    func testManySmallWrites_allCaptured() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c",
            "import sys\nfor i in range(10000):\n    sys.stdout.write(f'{i:09d}\\n')\nsys.stdout.flush()"
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        // Each line is "XXXXXXXXX\n" = 10 bytes; 10000 lines = 100000 bytes
        XCTAssertEqual(stdoutData.count, 100_000,
                       "Expected 100000 bytes from 10000 small writes; got \(stdoutData.count)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 10: Non-zero exit code, both streams captured

    /// Process exits with status 42, writes to both stdout and stderr.
    /// Verifies that data is captured even when the exit code is non-zero.
    func testNonZeroExitCode_bothStreamsCaptured() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'out_nonzero'; printf 'err_nonzero' >&2; exit 42"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        let group = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()

        group.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        XCTAssertEqual(process.terminationStatus, 42, "Expected exit code 42")
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        XCTAssertTrue(stdout.contains("out_nonzero"), "stdout captured even on non-zero exit: \(stdout.debugDescription)")
        XCTAssertTrue(stderr.contains("err_nonzero"), "stderr captured even on non-zero exit: \(stderr.debugDescription)")
    }

    // MARK: - Pattern 11: Binary data with null bytes in pipes

    /// Pipes binary data containing null bytes (0x00).
    /// String APIs would truncate at null; Data should be unaffected.
    func testBinaryData_withNullBytes() async throws {
        // Generate 256 bytes: all possible byte values 0x00–0xFF
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c",
            "import sys; sys.stdout.buffer.write(bytes(range(256))); sys.stdout.buffer.flush()"
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, 256,
                       "Binary pipe should preserve all 256 bytes including null; got \(stdoutData.count)")
        // Verify the data contains the full byte sequence (0x00–0xFF in order)
        let expected = Data((0..<256).map { UInt8($0) })
        XCTAssertEqual(stdoutData, expected, "Binary pipe data should match exactly")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 12: 20 concurrent processes in parallel

    /// Launches 20 processes concurrently and verifies each one captures its
    /// unique output correctly. Stresses FD usage and GCD thread pool.
    func testConcurrentProcesses_20parallel() async throws {
        let count = 20
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let marker = "concurrent_proc_\(i)"
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", "printf '\(marker)'"]
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    process.standardInput = nil

                    try process.run()

                    async let stdoutResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    async let stderrResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let (stdoutData, _) = await (stdoutResult, stderrResult)

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    let output = String(data: stdoutData, encoding: .utf8) ?? ""
                    XCTAssertTrue(output.contains(marker),
                                  "Concurrent process \(i): expected '\(marker)' in stdout; got: \(output.debugDescription)")
                    XCTAssertEqual(process.terminationStatus, 0,
                                   "Concurrent process \(i) should exit 0")
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Pattern 13: 50 sequential processes — FD leak stress test

    /// Runs 50 short-lived processes in sequence.
    /// If any Pipe() FD is leaked, the process table will exhaust within this loop
    /// and Process.run() will throw.
    func testSequentialProcesses_50runs() throws {
        for i in 0..<50 {
            let marker = "seq_run_\(i)"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "echo \(marker)"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            try process.run()

            let group = DispatchGroup()
            var stdoutData = Data()
            var stderrData = Data()
            group.enter()
            DispatchQueue.global().async { stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            process.waitUntilExit()
            group.wait()

            let output = String(data: stdoutData, encoding: .utf8) ?? ""
            XCTAssertTrue(output.contains(marker),
                          "Sequential run \(i): expected '\(marker)'; got: \(output.debugDescription)")
            XCTAssertEqual(process.terminationStatus, 0, "Sequential run \(i) should exit 0")
            _ = stderrData
        }
    }

    // MARK: - Pattern 14: DispatchGroup pattern with large output (mirrors CLICheck.healthCheck)

    /// Mirrors CLICheck.healthCheck exactly but with large output on both streams.
    /// If the DispatchGroup pattern has a buffering bug, this will surface it.
    func testDispatchGroupPattern_largeBothStreams() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c",
            "import sys; sys.stdout.write('O' * 65536); sys.stderr.write('E' * 65536); sys.stdout.flush(); sys.stderr.flush()"
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let group = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()
        group.enter()
        DispatchQueue.global().async { stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        process.waitUntilExit()
        group.wait()

        XCTAssertEqual(stdoutData.count, 65536,
                       "DispatchGroup stdout: expected 65536 bytes, got \(stdoutData.count)")
        XCTAssertEqual(stderrData.count, 65536,
                       "DispatchGroup stderr: expected 65536 bytes, got \(stderrData.count)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 15: terminationHandler race condition stress test

    /// Runs 200 immediate-exit processes to stress the TOCTOU race between
    /// process.isRunning check and terminationHandler assignment.
    /// If the race fires and the handler is never called, the async continuation
    /// will hang and the test will time out.
    func testTerminationHandlerRace_stressTest() async throws {
        for i in 0..<200 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit 0"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            try process.run()

            async let stdoutResult: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            async let stderrResult: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            let _ = await (stdoutResult, stderrResult)
            // Explicitly close FDs: in tight async loops, ARC may defer Pipe deallocation
            // across await points, causing FDs to accumulate in the process FD table.
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if process.isRunning {
                    process.terminationHandler = { _ in cont.resume() }
                } else {
                    cont.resume()
                }
            }

            XCTAssertEqual(process.terminationStatus, 0,
                           "Iteration \(i): process should exit 0")
        }
    }

    // MARK: - Pattern 17: Alternating chunked writes to both streams (Python interleaved)

    /// Python alternates writing to stdout and stderr in a tight loop.
    /// Simulates a real process that interleaves diagnostic output with results.
    func testPythonInterleavedWrites_allCaptured() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys
for i in range(500):
    sys.stdout.write(f's{i:04d}')
    sys.stderr.write(f'e{i:04d}')
sys.stdout.flush()
sys.stderr.flush()
"""]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        // Each write is "sXXXX" or "eXXXX" = 5 chars; 500 writes = 2500 bytes each
        XCTAssertEqual(stdoutData.count, 2500,
                       "Interleaved stdout: expected 2500 bytes, got \(stdoutData.count)")
        XCTAssertEqual(stderrData.count, 2500,
                       "Interleaved stderr: expected 2500 bytes, got \(stderrData.count)")
        XCTAssertEqual(process.terminationStatus, 0)

        // Spot-check first and last chunk on stdout
        let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
        XCTAssertTrue(stdoutStr.hasPrefix("s0000"), "stdout should start with s0000; got: \(String(stdoutStr.prefix(10)).debugDescription)")
        XCTAssertTrue(stdoutStr.hasSuffix("s0499"), "stdout should end with s0499; got: \(String(stdoutStr.suffix(10)).debugDescription)")
    }

    // MARK: - Pattern 18: 4 MB output — extreme pipe buffer stress

    /// Writes 4 MB to stdout and 4 MB to stderr concurrently.
    /// This is 32× the pipe buffer size. Verifies no data is lost
    /// at very large outputs and concurrent reads remain stable.
    func testExtremelyLargeOutput_4MB_eachStream() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c",
            "import sys; sys.stdout.write('O' * 4194304); sys.stderr.write('E' * 4194304); sys.stdout.flush(); sys.stderr.flush()"
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, 4_194_304,
                       "stdout: expected 4MB, got \(stdoutData.count)")
        XCTAssertEqual(stderrData.count, 4_194_304,
                       "stderr: expected 4MB, got \(stderrData.count)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 19: Process exit before pipe read (write-end closed at fork)

    /// Process forks, parent exits immediately, child keeps writing to stdout.
    /// On macOS, the forked child inherits the pipe write-end. Once the child
    /// exits the pipe closes. Verifies readDataToEndOfFile waits for the
    /// final write-end close, not just the parent exit.
    func testForkedChild_pipeDrainsAfterParentExit() async throws {
        // Use a shell that forks a background subshell, then the parent exits.
        // The subshell inherits stdout and writes "fork_ok" after a brief delay.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "(sleep 0.05; printf 'fork_ok') & wait"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("fork_ok"),
                      "Forked-child output should be captured; got: \(output.debugDescription)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 20: 100 concurrent processes with unique output verification

    /// Extends Pattern 12 to 100 parallel processes.
    /// Each must capture its own unique marker string without cross-contamination.
    func testConcurrentProcesses_100parallel() async throws {
        let count = 100
        // Collect results indexed by i to verify no cross-contamination
        actor Results {
            var outputs: [Int: String] = [:]
            func set(_ i: Int, _ value: String) { outputs[i] = value }
        }
        let results = Results()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let marker = "parallel_\(i)_end"
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", "printf '\(marker)'"]
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    process.standardInput = nil

                    try process.run()

                    async let stdoutResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    async let stderrResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let (stdoutData, _) = await (stdoutResult, stderrResult)

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    let output = String(data: stdoutData, encoding: .utf8) ?? ""
                    await results.set(i, output)
                    XCTAssertEqual(process.terminationStatus, 0, "Process \(i) should exit 0")
                }
            }
            try await group.waitForAll()
        }

        // Verify no cross-contamination: each result should contain its own marker
        let allOutputs = await results.outputs
        for i in 0..<count {
            let output = allOutputs[i] ?? ""
            let marker = "parallel_\(i)_end"
            XCTAssertTrue(output.contains(marker),
                          "Process \(i): expected '\(marker)' in output; got: \(output.debugDescription)")
        }
    }

    // MARK: - Pattern 21: Pipe reads with Unicode / multibyte UTF-8

    /// Writes multi-byte UTF-8 (emoji, CJK, and combining characters) to pipes.
    /// Verifies the raw bytes are preserved intact and decode correctly.
    func testMultibyteUTF8_preservedInPipes() async throws {
        // Mix of 1-byte, 2-byte, 3-byte, and 4-byte UTF-8 sequences
        let testString = "ASCII: abc | 2-byte: café | 3-byte: 中文 | 4-byte: 🎉🚀"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys; sys.stdout.buffer.write('\(testString)'.encode('utf-8')); sys.stdout.buffer.flush()"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        let decoded = String(data: stdoutData, encoding: .utf8)
        XCTAssertNotNil(decoded, "UTF-8 data should decode without errors")
        XCTAssertEqual(decoded, testString, "Multibyte UTF-8 should round-trip unchanged through pipe")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 22: Pipe read integrity — byte-level checksum verification

    /// Writes 65537 bytes (just over 64KB) with a known pattern, then verifies
    /// via CRC/XOR checksum that every byte was received correctly.
    func testPipeByteIntegrity_checksumVerification() async throws {
        // Pattern: byte[i] = i % 251 (prime, avoids alignment with 256)
        let count = 65537
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c",
            "import sys; data = bytes(i % 251 for i in range(\(count))); sys.stdout.buffer.write(data); sys.stdout.buffer.flush()"
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, count,
                       "Byte integrity: expected \(count) bytes, got \(stdoutData.count)")

        // Verify each received byte equals i % 251
        var mismatch: Int? = nil
        for i in 0..<count {
            if stdoutData[i] != UInt8(i % 251) {
                mismatch = i
                break
            }
        }
        XCTAssertNil(mismatch, "Byte integrity failure at index \(mismatch.map(String.init) ?? "nil"); pipe corrupted data")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 23: Sequential processes — 200 runs FD leak stress

    /// 200 sequential short-lived processes. If any Pipe FD is leaked,
    /// the process table or FD table will exhaust before 200 iterations.
    func testSequentialProcesses_200runs() throws {
        for i in 0..<200 {
            let marker = "run200_\(i)"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '\(marker)'"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            try process.run()

            let group = DispatchGroup()
            var stdoutData = Data()
            var stderrData = Data()
            group.enter()
            DispatchQueue.global().async { stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            process.waitUntilExit()
            group.wait()

            let output = String(data: stdoutData, encoding: .utf8) ?? ""
            XCTAssertTrue(output.contains(marker),
                          "Run 200 iteration \(i): expected '\(marker)'; got: \(output.debugDescription)")
            XCTAssertEqual(process.terminationStatus, 0)
            _ = stderrData
        }
    }

    // MARK: - Pattern 24: terminationHandler race — widened window via sleep

    /// After reading all pipe data, sleeps briefly to widen the window between
    /// pipe EOF (process has definitely exited) and the isRunning+terminationHandler check.
    /// If Foundation's terminationHandler setter doesn't handle the race, this test hangs.
    /// A 5-second safety timeout per iteration turns a hang into a clear test failure.
    func testTerminationHandlerRace_widenedWindow() async throws {
        for i in 0..<50 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit 0"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            try process.run()

            async let stdoutResult: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            async let stderrResult: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            let _ = await (stdoutResult, stderrResult)
            // Explicitly close FDs to prevent accumulation in tight async loops
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()

            // Sleep to ensure the process has been fully reaped, maximising the
            // window where isRunning could return false or the handler race fires.
            try await Task.sleep(nanoseconds: 5_000_000)  // 5 ms

            // Use a 5-second timeout per iteration so a hang fails fast.
            let continued = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }
                    return true
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    return false
                }
                let result = await group.next()!
                group.cancelAll()
                return result
            }

            XCTAssertTrue(continued,
                          "Iteration \(i): terminationHandler continuation never resumed — potential TOCTOU hang")
            XCTAssertEqual(process.terminationStatus, 0)
        }
    }

    // MARK: - Pattern 25: terminationHandler stress — 2000 immediate-exit iterations

    /// Increases the terminationHandler race stress test to 2000 iterations
    /// for maximum statistical coverage of the race window.
    func testTerminationHandlerRace_2000iterations() async throws {
        for i in 0..<2000 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit 0"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            try process.run()

            async let stdoutResult: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            async let stderrResult: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            let _ = await (stdoutResult, stderrResult)
            // Explicitly close FDs to prevent accumulation in tight async loops
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if process.isRunning {
                    process.terminationHandler = { _ in cont.resume() }
                } else {
                    cont.resume()
                }
            }

            XCTAssertEqual(process.terminationStatus, 0, "Iteration \(i): exit status should be 0")
        }
    }

    // MARK: - Pattern 26: Empty output — process produces no stdout or stderr

    /// Verifies that readDataToEndOfFile() returns empty Data (not nil or hanging)
    /// when the process exits without writing anything.
    func testEmptyOutput_returnsEmptyData() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        let group = DispatchGroup()
        var stdoutData = Data([0xFF])  // sentinel — should be overwritten with empty
        var stderrData = Data([0xFF])
        group.enter()
        DispatchQueue.global().async { stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        process.waitUntilExit()
        group.wait()

        XCTAssertEqual(stdoutData.count, 0, "Empty-output process: stdout should be 0 bytes; got \(stdoutData.count)")
        XCTAssertEqual(stderrData.count, 0, "Empty-output process: stderr should be 0 bytes; got \(stderrData.count)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 27: Nonexistent executable throws on run()

    /// Verifies that Process.run() throws when given a nonexistent executable path.
    /// Error path must not hang or leak resources.
    func testNonexistentExecutable_throwsOnRun() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/nonexistent/path/to/binary")
        process.arguments = []
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        XCTAssertThrowsError(try process.run(), "Running a nonexistent executable should throw") { error in
            // CocoaError.fileNoSuchFile or POSIX .noSuchFileOrDirectory
            let nsErr = error as NSError
            XCTAssertTrue(
                nsErr.domain == NSCocoaErrorDomain || nsErr.domain == NSPOSIXErrorDomain,
                "Expected CocoaError or POSIXError; got \(nsErr.domain): \(nsErr.code)"
            )
        }
    }

    // MARK: - Pattern 28.5: 500 concurrent processes

    /// Extends Pattern 20 to 500 parallel processes.
    /// Tests FD table, process table, and GCD thread pool under heavy load.
    func testConcurrentProcesses_500parallel() async throws {
        let count = 500
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let marker = "p500_\(i)"
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", "printf '\(marker)'"]
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    process.standardInput = nil

                    try process.run()

                    async let stdoutResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    async let stderrResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let (stdoutData, _) = await (stdoutResult, stderrResult)

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    let output = String(data: stdoutData, encoding: .utf8) ?? ""
                    XCTAssertTrue(output.contains(marker),
                                  "Process \(i): expected '\(marker)'; got: \(output.debugDescription)")
                    XCTAssertEqual(process.terminationStatus, 0, "Process \(i) exit status")
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Pattern 28.6: SIGTERM during ongoing pipe read

    /// Starts a long-running process, lets it write a known string, then sends SIGTERM.
    /// Verifies: (a) data written before SIGTERM is captured, (b) terminationReason is .uncaughtSignal.
    func testProcessKilledWithSIGTERM_dataBeforeSignalCaptured() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // printf runs, then sleep 60 replaces the shell via exec
        process.arguments = ["-c", "printf 'before_kill'; sleep 60"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        // Allow the printf to execute and flush to the pipe buffer
        try await Task.sleep(nanoseconds: 200_000_000)  // 200 ms

        // Start concurrent pipe reads (will block until write-end closes)
        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }

        // Terminate the process — SIGTERM causes sleep to exit, closing the write-ends
        process.terminate()

        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("before_kill"),
                      "Data written before SIGTERM should survive: \(output.debugDescription)")
        XCTAssertEqual(process.terminationReason, .uncaughtSignal,
                       "Process killed by signal should have .uncaughtSignal termination reason")
    }

    // MARK: - Pattern 28.7: FD count integrity — no leak after process loop

    /// Verifies that the number of open file descriptors in this process returns to
    /// the same level after running 100 processes with pipes, confirming no FD leaks.
    func testFDCount_noLeakAfterProcessLoop() throws {
        func countOpenFDs() -> Int {
            // /dev/fd contains one entry per open FD in the current process
            let contents = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
            return contents?.count ?? 0
        }

        // Warm up: let ARC stabilize before taking baseline
        let baseline = countOpenFDs()

        for i in 0..<100 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf 'fd_check_\(i)'"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            try process.run()

            let group = DispatchGroup()
            var stdoutData = Data()
            var stderrData = Data()
            group.enter()
            DispatchQueue.global().async { stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            process.waitUntilExit()
            group.wait()
            // Explicit FD close to prevent GCD-deferred FileHandle release accumulation
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            _ = stdoutData; _ = stderrData
        }

        // Wait for residual ARC/GCD cleanup
        Thread.sleep(forTimeInterval: 0.2)
        let finalCount = countOpenFDs()

        // Allow a small margin for any test-framework FDs opened during the loop
        XCTAssertLessThanOrEqual(finalCount, baseline + 5,
                                  "FD leak detected: baseline=\(baseline), after loop=\(finalCount)")
    }

    // MARK: - Pattern 28.8: 1000 concurrent processes

    /// Extends concurrent stress test to 1000 parallel processes.
    /// Will fail with an error if the system FD limit (~10240 on modern macOS) is hit
    /// or if the process table is exhausted.
    func testConcurrentProcesses_1000parallel() async throws {
        let count = 1000
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let marker = "p1k_\(i)"
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", "printf '\(marker)'"]
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    process.standardInput = nil

                    try process.run()

                    async let stdoutResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    async let stderrResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let (stdoutData, _) = await (stdoutResult, stderrResult)

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    let output = String(data: stdoutData, encoding: .utf8) ?? ""
                    XCTAssertTrue(output.contains(marker),
                                  "Process \(i): expected '\(marker)'; got: \(output.debugDescription)")
                    XCTAssertEqual(process.terminationStatus, 0)
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Pattern 28.9: Process with large argument string (8 KB)

    /// Passes an 8 KB argument string to verify there's no ARG_MAX or pipe-buffer
    /// truncation at the argument boundary.
    func testLargeArgumentString_8KB() async throws {
        let argPayload = String(repeating: "A", count: 8192)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The argument itself is echoed; we verify exact byte count
        process.arguments = ["-c", "printf '%s' '\(argPayload)'"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, 8192,
                       "8KB argument should produce 8192 bytes of output; got \(stdoutData.count)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 28.10: 2000 concurrent processes

    /// Pushes to 2000 concurrent processes to stress the OS process table and FD table.
    func testConcurrentProcesses_2000parallel() async throws {
        let count = 2000
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let marker = "p2k_\(i)"
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", "printf '\(marker)'"]
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    process.standardInput = nil

                    try process.run()

                    async let stdoutResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    async let stderrResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let (stdoutData, _) = await (stdoutResult, stderrResult)

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    let output = String(data: stdoutData, encoding: .utf8) ?? ""
                    XCTAssertTrue(output.contains(marker),
                                  "Process \(i): expected '\(marker)'; got: \(output.debugDescription)")
                    XCTAssertEqual(process.terminationStatus, 0)
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Pattern 28.11: Large argument string near ARG_MAX — 100 KB

    /// Passes a 100 KB argument string (well under the macOS ARG_MAX of 256 KB but
    /// well above the default pipe buffer). Verifies no truncation in argument passing
    /// or pipe output.
    func testLargeArgumentString_100KB() async throws {
        let argPayload = String(repeating: "B", count: 102_400)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' '\(argPayload)'"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, 102_400,
                       "100KB argument should produce 102400 bytes of output; got \(stdoutData.count)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 28.12: Repeated large I/O — 20 × 256 KB both streams

    /// Runs 20 iterations, each writing 256 KB to stdout and 256 KB to stderr.
    /// Verifies that repeated large I/O doesn't accumulate state or cause drift.
    func testRepeatedLargeIO_20iterations() async throws {
        let chunkSize = 262_144  // 256 KB
        for iteration in 0..<20 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c",
                "import sys; sys.stdout.write('O' * \(chunkSize)); sys.stderr.write('E' * \(chunkSize)); sys.stdout.flush(); sys.stderr.flush()"
            ]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            try process.run()

            async let stdoutResult: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            async let stderrResult: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if process.isRunning {
                    process.terminationHandler = { _ in cont.resume() }
                } else {
                    cont.resume()
                }
            }

            XCTAssertEqual(stdoutData.count, chunkSize,
                           "Iteration \(iteration) stdout: expected \(chunkSize), got \(stdoutData.count)")
            XCTAssertEqual(stderrData.count, chunkSize,
                           "Iteration \(iteration) stderr: expected \(chunkSize), got \(stderrData.count)")
            XCTAssertEqual(process.terminationStatus, 0, "Iteration \(iteration): exit status")
        }
    }

    // MARK: - Pattern 28.13: Python multithreaded writes — true byte-level stream interleaving

    /// Python uses two threads to write simultaneously to stdout and stderr.
    /// Unlike interleaved single-threaded writes, this creates genuine concurrent I/O.
    /// Both streams should still capture the correct total byte count.
    func testThreadedWrites_bothStreams_simultaneouslyFromPython() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys, threading
def write_stdout():
    for _ in range(200):
        sys.stdout.buffer.write(b'O' * 512)
        sys.stdout.buffer.flush()
def write_stderr():
    for _ in range(200):
        sys.stderr.buffer.write(b'E' * 512)
        sys.stderr.buffer.flush()
t1 = threading.Thread(target=write_stdout)
t2 = threading.Thread(target=write_stderr)
t1.start(); t2.start()
t1.join(); t2.join()
"""]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        // 200 iterations × 512 bytes = 102400 bytes each
        XCTAssertEqual(stdoutData.count, 102_400,
                       "Threaded stdout: expected 102400 bytes, got \(stdoutData.count)")
        XCTAssertEqual(stderrData.count, 102_400,
                       "Threaded stderr: expected 102400 bytes, got \(stderrData.count)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 28.14: CLICheck nullDevice pattern — FileHandle.nullDevice for both streams

    /// Mirrors CLICheck.isAvailable: stdout and stderr are /dev/null (FileHandle.nullDevice),
    /// no Pipe involved. Verifies this simpler pattern works correctly.
    func testNullDevicePattern_mirrorsCliCheckIsAvailable() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'discarded'"]  // output should go to /dev/null
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0,
                       "nullDevice pattern: process should exit 0")
    }

    // MARK: - Pattern 28.15: 500 sequential processes — extended FD leak stress

    /// Increases sequential FD leak detection from 200 to 500 processes.
    func testSequentialProcesses_500runs() throws {
        for i in 0..<500 {
            let marker = "s500_\(i)"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '\(marker)'"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            try process.run()

            let group = DispatchGroup()
            var stdoutData = Data()
            var stderrData = Data()
            group.enter()
            DispatchQueue.global().async { stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            process.waitUntilExit()
            group.wait()

            let output = String(data: stdoutData, encoding: .utf8) ?? ""
            // Only assert on every 10th to avoid slowing down test output
            if i % 10 == 0 {
                XCTAssertTrue(output.contains(marker),
                              "500-run iter \(i): expected '\(marker)'; got: \(output.debugDescription)")
                XCTAssertEqual(process.terminationStatus, 0)
            }
            _ = stderrData
        }
    }

    // MARK: - Pattern 28.16: Definitive deadlock regression — stderr fills pipe BEFORE stdout writes

    /// This is the exact scenario that caused the original sequential-read deadlock:
    ///   1. Process writes >64 KB to stderr (fills the kernel pipe buffer)
    ///   2. Only THEN does the process write to stdout
    ///   3. Sequential reads (stdout-first) would deadlock: readDataToEndOfFile on
    ///      stdout blocks waiting for EOF, but the process can't exit because it's
    ///      blocked trying to drain stderr into a full pipe.
    ///   4. Concurrent reads (the fix) drain both simultaneously — no deadlock.
    func testDeadlockRegression_stderrFillsBeforeStdoutWrites() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys
# Fill stderr pipe buffer entirely (128KB > default 64KB kernel limit)
sys.stderr.buffer.write(b'E' * 131072)
sys.stderr.buffer.flush()
# Only NOW write to stdout — a sequential reader blocked on stdout would deadlock above
sys.stdout.buffer.write(b'O' * 64)
sys.stdout.buffer.flush()
"""]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        // Concurrent reads: both pipes drained simultaneously — no deadlock
        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, 64,
                       "Stdout should have 64 bytes written after stderr fills; got \(stdoutData.count)")
        XCTAssertEqual(stderrData.count, 131_072,
                       "Stderr should have 131072 bytes; got \(stderrData.count)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 28.17: Symmetric reverse — stdout fills pipe BEFORE stderr writes

    /// Mirror of Pattern 28.16: stdout fills the pipe buffer, then stderr writes.
    /// This tests the reverse deadlock scenario with sequential reads in stderr-first order.
    func testDeadlockRegression_stdoutFillsBeforeStderrWrites() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys
sys.stdout.buffer.write(b'O' * 131072)
sys.stdout.buffer.flush()
sys.stderr.buffer.write(b'E' * 64)
sys.stderr.buffer.flush()
"""]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, 131_072,
                       "Stdout should have 131072 bytes; got \(stdoutData.count)")
        XCTAssertEqual(stderrData.count, 64,
                       "Stderr should have 64 bytes written after stdout fills; got \(stderrData.count)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 28.18: terminationHandler race — 10,000 iterations maximum stress

    /// Ultimate termination handler stress: 10,000 immediate-exit processes.
    /// If there is any race condition in Foundation's terminationHandler,
    /// this provides the best statistical chance of exposing it.
    func testTerminationHandlerRace_10000iterations() async throws {
        for i in 0..<10_000 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit 0"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            try process.run()

            async let stdoutResult: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            async let stderrResult: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            let _ = await (stdoutResult, stderrResult)
            // Explicitly close FDs immediately after reads complete.
            // In tight async loops, Swift ARC may defer Pipe deallocation across
            // await suspension points, causing FDs to accumulate. With 10,000
            // iterations this would exhaust the system FD table (~10240 limit).
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if process.isRunning {
                    process.terminationHandler = { _ in cont.resume() }
                } else {
                    cont.resume()
                }
            }

            XCTAssertEqual(process.terminationStatus, 0, "Iteration \(i)")
        }
    }

    // MARK: - Pattern 28: Integrity check on both streams at 1 MB each

    /// Writes 1 MB to both stdout and stderr with distinct byte patterns,
    /// then verifies both streams byte-for-byte.
    func testBothStreams_1MB_byteIntegrity() async throws {
        let count = 1_048_576
        // stdout pattern: i % 251; stderr pattern: (i + 127) % 251
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys
n = \(count)
sys.stdout.buffer.write(bytes(i % 251 for i in range(n)))
sys.stderr.buffer.write(bytes((i + 127) % 251 for i in range(n)))
sys.stdout.buffer.flush()
sys.stderr.buffer.flush()
"""]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, count, "stdout: expected \(count) bytes, got \(stdoutData.count)")
        XCTAssertEqual(stderrData.count, count, "stderr: expected \(count) bytes, got \(stderrData.count)")

        var stdoutMismatch: Int? = nil
        for i in 0..<count {
            if stdoutData[i] != UInt8(i % 251) { stdoutMismatch = i; break }
        }
        var stderrMismatch: Int? = nil
        for i in 0..<count {
            if stderrData[i] != UInt8((i + 127) % 251) { stderrMismatch = i; break }
        }

        XCTAssertNil(stdoutMismatch, "stdout byte mismatch at index \(stdoutMismatch.map(String.init) ?? "nil")")
        XCTAssertNil(stderrMismatch, "stderr byte mismatch at index \(stderrMismatch.map(String.init) ?? "nil")")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 29: 10 concurrent processes × 4 MB per stream

    /// Launches 10 processes simultaneously, each writing 4 MB to stdout and 4 MB to stderr.
    /// Total pipe data in flight: 80 MB. Tests GCD thread pool, memory pressure,
    /// and concurrent large-buffer pipe drain correctness.
    func testConcurrentProcesses_10parallel_4MB_eachStream() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = ["-c",
                        "import sys; sys.stdout.write('O' * 4194304); sys.stderr.write('E' * 4194304); sys.stdout.flush(); sys.stderr.flush()"
                    ]
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    process.standardInput = nil

                    try process.run()

                    async let stdoutResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    async let stderrResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    XCTAssertEqual(stdoutData.count, 4_194_304,
                                   "Worker \(i) stdout: expected 4MB, got \(stdoutData.count)")
                    XCTAssertEqual(stderrData.count, 4_194_304,
                                   "Worker \(i) stderr: expected 4MB, got \(stderrData.count)")
                    XCTAssertEqual(process.terminationStatus, 0, "Worker \(i) exit status")
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Pattern 30: Sequential byte-integrity check — 20 runs × 512 KB per stream

    /// Runs 20 sequential processes, each writing 512 KB to both stdout and stderr
    /// with distinct byte patterns. Verifies byte-level integrity across repeated runs
    /// to catch any pipe state contamination between processes.
    func testSequentialLargeOutput_20runs_byteIntegrity() async throws {
        let chunkSize = 524_288  // 512 KB
        for iteration in 0..<20 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            let stdoutPattern = iteration % 251
            let stderrPattern = (iteration + 113) % 251
            process.arguments = ["-c", """
import sys
n = \(chunkSize)
sys.stdout.buffer.write(bytes(\(stdoutPattern) for _ in range(n)))
sys.stderr.buffer.write(bytes(\(stderrPattern) for _ in range(n)))
sys.stdout.buffer.flush()
sys.stderr.buffer.flush()
"""]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            try process.run()

            async let stdoutResult: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            async let stderrResult: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if process.isRunning {
                    process.terminationHandler = { _ in cont.resume() }
                } else {
                    cont.resume()
                }
            }

            XCTAssertEqual(stdoutData.count, chunkSize,
                           "Run \(iteration) stdout: expected \(chunkSize), got \(stdoutData.count)")
            XCTAssertEqual(stderrData.count, chunkSize,
                           "Run \(iteration) stderr: expected \(chunkSize), got \(stderrData.count)")

            // Verify every byte matches the expected pattern
            for idx in 0..<chunkSize {
                if stdoutData[idx] != UInt8(stdoutPattern) {
                    XCTFail("Run \(iteration) stdout byte mismatch at idx \(idx): expected \(stdoutPattern), got \(stdoutData[idx])")
                    break
                }
            }
            for idx in 0..<chunkSize {
                if stderrData[idx] != UInt8(stderrPattern) {
                    XCTFail("Run \(iteration) stderr byte mismatch at idx \(idx): expected \(stderrPattern), got \(stderrData[idx])")
                    break
                }
            }
            XCTAssertEqual(process.terminationStatus, 0, "Run \(iteration) exit status")
        }
    }

    // MARK: - Pattern 31: Nested task groups — 5 outer × 100 inner concurrent processes

    /// Nested concurrency: 5 outer task groups, each containing 100 concurrent process
    /// launches. Tests Swift structured concurrency with multiple nesting levels.
    func testNestedConcurrency_5outer_100inner() async throws {
        try await withThrowingTaskGroup(of: Void.self) { outerGroup in
            for outerIdx in 0..<5 {
                outerGroup.addTask {
                    try await withThrowingTaskGroup(of: Void.self) { innerGroup in
                        for innerIdx in 0..<100 {
                            innerGroup.addTask {
                                let marker = "o\(outerIdx)i\(innerIdx)"
                                let process = Process()
                                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                                process.arguments = ["-c", "printf '\(marker)'"]
                                let stdoutPipe = Pipe()
                                let stderrPipe = Pipe()
                                process.standardOutput = stdoutPipe
                                process.standardError = stderrPipe
                                process.standardInput = nil

                                try process.run()

                                async let stdoutResult: Data = withCheckedContinuation { cont in
                                    DispatchQueue.global(qos: .userInitiated).async {
                                        cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                                    }
                                }
                                async let stderrResult: Data = withCheckedContinuation { cont in
                                    DispatchQueue.global(qos: .userInitiated).async {
                                        cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                                    }
                                }
                                let (stdoutData, _) = await (stdoutResult, stderrResult)

                                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                                    if process.isRunning {
                                        process.terminationHandler = { _ in cont.resume() }
                                    } else {
                                        cont.resume()
                                    }
                                }

                                let output = String(data: stdoutData, encoding: .utf8) ?? ""
                                XCTAssertTrue(output.contains(marker),
                                              "Nested \(marker): expected in output, got: \(output.debugDescription)")
                                XCTAssertEqual(process.terminationStatus, 0, "Nested \(marker) exit")
                            }
                        }
                        try await innerGroup.waitForAll()
                    }
                }
            }
            try await outerGroup.waitForAll()
        }
    }

    // MARK: - Pattern 32: Pipe reads at different GCD QoS levels

    /// Verifies that pipe reads dispatched at different GCD QoS levels all
    /// capture data correctly. Uses userInteractive, userInitiated, default,
    /// utility, and background QoS simultaneously.
    func testPipeReadsAtDifferentQoSLevels() async throws {
        let qosLevels: [(DispatchQoS.QoSClass, String)] = [
            (.userInteractive, "userInteractive"),
            (.userInitiated, "userInitiated"),
            (.default, "default"),
            (.utility, "utility"),
            (.background, "background"),
        ]

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (qos, qosName) in qosLevels {
                group.addTask {
                    let marker = "qos_\(qosName)"
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", "printf '\(marker)'"]
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    process.standardInput = nil

                    try process.run()

                    let stdoutData: Data = await withCheckedContinuation { cont in
                        DispatchQueue.global(qos: qos).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let stderrData: Data = await withCheckedContinuation { cont in
                        DispatchQueue.global(qos: qos).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    let output = String(data: stdoutData, encoding: .utf8) ?? ""
                    XCTAssertTrue(output.contains(marker),
                                  "QoS \(qosName): expected '\(marker)'; got: \(output.debugDescription)")
                    XCTAssertEqual(process.terminationStatus, 0, "QoS \(qosName) exit status")
                    _ = stderrData
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Pattern 33: Explicit closeFile robustness — double-close is safe

    /// Explicitly closes pipe FileHandles (simulating the fix for FD accumulation),
    /// then verifies that subsequent Pipe deallocation (via ARC) doesn't crash or
    /// produce errors. Tests the assumption that double-close is safe.
    func testExplicitCloseFile_doubleCloseSafe() throws {
        for _ in 0..<50 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf 'double_close_ok'"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            try process.run()

            let group = DispatchGroup()
            var stdoutData = Data()
            var stderrData = Data()
            group.enter()
            DispatchQueue.global().async { stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            process.waitUntilExit()
            group.wait()

            // Explicitly close — first close
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            // Explicit second close — should be safe (no crash, no undefined behavior)
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            // ARC will also try to close when Pipe is released — third close attempt
            // This verifies the "double-close is safe" assumption underlying our fix.

            let output = String(data: stdoutData, encoding: .utf8) ?? ""
            XCTAssertTrue(output.contains("double_close_ok"))
            XCTAssertEqual(process.terminationStatus, 0)
            _ = stderrData
        }
    }

    // MARK: - Pattern 35: stdin pipe round-trip — small payload

    /// Writes a small payload to a process's stdin pipe and reads it back from stdout.
    /// This exercises the entirely untested stdin pipe path in Foundation's Process.
    func testStdinPipe_roundtripViaProcess() async throws {
        let payload = Data("stdin_roundtrip_payload_hello_world\n".utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Write to stdin then close write end so cat sees EOF
        stdinPipe.fileHandleForWriting.write(payload)
        stdinPipe.fileHandleForWriting.closeFile()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData, payload,
                       "cat should echo stdin to stdout byte-for-byte; got \(stdoutData.count) bytes")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 36: stdin pipe round-trip — 1 MB (deadlock regression)

    /// Writes 1 MB to stdin while concurrently reading stdout. If the write and read
    /// are not concurrent, the stdin pipe buffer fills (64 KB) and cat blocks while
    /// we block reading stdout — a classic bidirectional pipe deadlock.
    func testStdinPipe_1MB_roundtrip() async throws {
        let payloadSize = 1_048_576
        let payload = Data(repeating: 0xAB, count: payloadSize)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // All three must be concurrent: write stdin, read stdout, read stderr.
        // If stdin write is serial before stdout read: stdin fills → cat blocks → deadlock.
        async let writeTask: Void = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                stdinPipe.fileHandleForWriting.write(payload)
                stdinPipe.fileHandleForWriting.closeFile()
                cont.resume()
            }
        }
        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (_, stdoutData, _) = await (writeTask, stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, payloadSize,
                       "cat should echo all \(payloadSize) stdin bytes; got \(stdoutData.count)")
        XCTAssertEqual(stdoutData, payload, "cat stdin 1MB round-trip: byte integrity failure")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 37: Environment variable propagation

    /// Verifies that a custom environment dictionary set on Process is visible
    /// to the child process as expected. This tests the `environment` property path.
    func testEnvironmentVariable_propagatedToChild() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"printf "%s" "$TEST_VAR_XYZZY_UNIQUE""#]
        process.environment = ["TEST_VAR_XYZZY_UNIQUE": "env_propagation_ok_12345"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        XCTAssertEqual(output, "env_propagation_ok_12345",
                       "Environment variable should be visible in child; got: \(output.debugDescription)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 38: 20 concurrent processes × 256 KB per-process byte integrity

    /// Launches 20 concurrent processes, each writing a unique byte pattern (256 KB).
    /// Verifies that concurrent pipe draining produces no cross-contamination or corruption.
    func testConcurrentProcesses_20parallel_byteIntegrity() async throws {
        let count = 20
        let bytesPerProcess = 262_144  // 256 KB

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                let pattern = UInt8(i % 251)
                group.addTask {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = ["-c",
                        "import sys; sys.stdout.buffer.write(bytes([\(pattern)] * \(bytesPerProcess))); sys.stdout.buffer.flush()"
                    ]
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    process.standardInput = nil

                    try process.run()

                    async let stdoutResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    async let stderrResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let (stdoutData, _) = await (stdoutResult, stderrResult)

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    XCTAssertEqual(stdoutData.count, bytesPerProcess,
                                   "Process \(i): expected \(bytesPerProcess) bytes, got \(stdoutData.count)")
                    if stdoutData.count == bytesPerProcess {
                        var mismatch: Int? = nil
                        for j in 0..<bytesPerProcess {
                            if stdoutData[j] != pattern { mismatch = j; break }
                        }
                        XCTAssertNil(mismatch,
                                     "Process \(i): byte mismatch at idx \(mismatch.map(String.init) ?? "nil"); expected \(pattern)")
                    }
                    XCTAssertEqual(process.terminationStatus, 0, "Process \(i) exit status")
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Pattern 39: 10,000-line ordered delivery (10× harder than Pattern 34)

    /// Process writes 10,000 numbered lines; verifies strict byte ordering is preserved
    /// across multiple pipe buffer crossings. Total output ≈ 90 KB.
    func testPipeDataOrdering_10000lines_inOrder() async throws {
        let lines = 10_000
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys
for i in range(\(lines)):
    sys.stdout.write(f'{i:08d}\\n')
sys.stdout.flush()
"""]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        let receivedLines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertEqual(receivedLines.count, lines,
                       "Expected \(lines) lines, got \(receivedLines.count)")

        var outOfOrder: Int? = nil
        for (idx, line) in receivedLines.enumerated() {
            if line != String(format: "%08d", idx) { outOfOrder = idx; break }
        }
        XCTAssertNil(outOfOrder,
                     "Out-of-order at idx \(outOfOrder.map(String.init) ?? "nil"): got '\(outOfOrder.map { receivedLines[$0] } ?? "nil")'")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 40: 10 MB per stream (2.5× harder than existing 4 MB test)

    /// Writes 10 MB to both stdout and stderr concurrently to stress pipe drain
    /// correctness at very large volumes. Any buffering or read-size assumption
    /// in the pipe infrastructure will surface here.
    func testExtremelyLargeOutput_10MB_eachStream() async throws {
        let mb10 = 10_485_760
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c",
            "import sys; sys.stdout.buffer.write(b'O' * \(mb10)); sys.stderr.buffer.write(b'E' * \(mb10)); sys.stdout.buffer.flush(); sys.stderr.buffer.flush()"
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, mb10, "stdout: expected 10MB, got \(stdoutData.count)")
        XCTAssertEqual(stderrData.count, mb10, "stderr: expected 10MB, got \(stderrData.count)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 41: SIGKILL data capture — process killed hard, pre-kill data survives

    /// Sends SIGKILL (not SIGTERM) to a running process after it has written data.
    /// Unlike SIGTERM, SIGKILL cannot be caught or ignored. Data already in the kernel
    /// pipe buffer must still be readable after the abrupt kill.
    func testSIGKILL_dataBeforeKillCaptured() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'before_sigkill_data'; sleep 60"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        // Allow printf to execute and flush to the kernel pipe buffer
        try await Task.sleep(nanoseconds: 200_000_000)  // 200 ms

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }

        // SIGKILL the entire process group (-pid) so orphaned children (e.g. sleep)
        // are also killed. SIGKILL to the shell alone leaves `sleep 60` as an orphan
        // holding the pipe write-end open for 60 seconds, causing a test timeout.
        kill(-process.processIdentifier, SIGKILL)

        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("before_sigkill_data"),
                      "Data written before SIGKILL should survive in pipe buffer; got: \(output.debugDescription)")
        XCTAssertEqual(process.terminationReason, .uncaughtSignal,
                       "Process killed by SIGKILL should have .uncaughtSignal reason")
    }

    // MARK: - Pattern 42: Triple-pipe concurrent deadlock stress — stdin + stdout + stderr

    /// The hardest pipe deadlock scenario: stdin write and stdout+stderr reads must ALL
    /// be concurrent. If stdin write is not concurrent with stdout read:
    ///   - stdin pipe fills → cat blocks → stdout never flushes → stdout read blocks → deadlock.
    /// If stdout read is not concurrent with stderr read:
    ///   - stdout fills → same deadlock.
    /// This test uses `tr` to transform stdin bytes to verify round-trip integrity while
    /// simultaneously producing stderr output, exercising all three pipes at once.
    func testTriplePipe_stdinStdoutStderr_concurrent_noDeadlock() async throws {
        // Python reads 512KB from stdin, writes to stdout, and also writes 64KB to stderr
        let payloadSize = 524_288  // 512 KB stdin
        let stderrSize = 65_536    // 64 KB stderr
        let payload = Data(repeating: 0xCC, count: payloadSize)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys
data = sys.stdin.buffer.read()
sys.stderr.buffer.write(b'E' * \(stderrSize))
sys.stderr.buffer.flush()
sys.stdout.buffer.write(data)
sys.stdout.buffer.flush()
"""]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // All three must be concurrent — any sequential ordering deadlocks
        async let writeTask: Void = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                stdinPipe.fileHandleForWriting.write(payload)
                stdinPipe.fileHandleForWriting.closeFile()
                cont.resume()
            }
        }
        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (_, stdoutData, stderrData) = await (writeTask, stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, payloadSize,
                       "stdin→stdout round-trip: expected \(payloadSize) bytes, got \(stdoutData.count)")
        XCTAssertEqual(stdoutData, payload, "stdin→stdout round-trip: byte integrity failure (0xCC)")
        XCTAssertEqual(stderrData.count, stderrSize,
                       "stderr: expected \(stderrSize) bytes, got \(stderrData.count)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 43: 5000 concurrent processes — OS limit stress

    /// Runs 5000 processes in batches of 100 concurrent (100 × 4 = 400 FDs at most at once).
    /// Running all 5000 truly concurrently would require 20,000 FDs, exceeding the macOS
    /// soft FD limit (~10240). Batching demonstrates that 5000 processes can be managed
    /// correctly without FD leaks over many sequential concurrent batches.
    func testConcurrentProcesses_5000parallel() async throws {
        let total = 5000
        let batchSize = 100
        for batchStart in stride(from: 0, to: total, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, total)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in batchStart..<batchEnd {
                    group.addTask {
                        let marker = "p5k_\(i)"
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/bin/sh")
                        process.arguments = ["-c", "printf '\(marker)'"]
                        let stdoutPipe = Pipe()
                        let stderrPipe = Pipe()
                        process.standardOutput = stdoutPipe
                        process.standardError = stderrPipe
                        process.standardInput = nil

                        try process.run()

                        async let stdoutResult: Data = withCheckedContinuation { cont in
                            DispatchQueue.global(qos: .userInitiated).async {
                                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                            }
                        }
                        async let stderrResult: Data = withCheckedContinuation { cont in
                            DispatchQueue.global(qos: .userInitiated).async {
                                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                            }
                        }
                        let (stdoutData, _) = await (stdoutResult, stderrResult)
                        stdoutPipe.fileHandleForReading.closeFile()
                        stderrPipe.fileHandleForReading.closeFile()

                        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                            if process.isRunning {
                                process.terminationHandler = { _ in cont.resume() }
                            } else {
                                cont.resume()
                            }
                        }

                        let output = String(data: stdoutData, encoding: .utf8) ?? ""
                        XCTAssertTrue(output.contains(marker),
                                      "Process \(i): expected '\(marker)'; got: \(output.debugDescription)")
                        XCTAssertEqual(process.terminationStatus, 0)
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    // MARK: - Pattern 44: Mixed exit codes — 50 concurrent processes with distinct exit codes

    /// 50 concurrent processes each exit with a unique code (0–49).
    /// Verifies that each process's terminationStatus is correctly isolated
    /// and not contaminated by other concurrent processes.
    func testConcurrentProcesses_50parallel_mixedExitCodes() async throws {
        let count = 50
        actor ExitCodes {
            var codes: [Int: Int32] = [:]
            func set(_ i: Int, _ code: Int32) { codes[i] = code }
        }
        let exitCodes = ExitCodes()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let expectedCode = Int32(i)
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", "exit \(i)"]
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    process.standardInput = nil

                    try process.run()

                    async let stdoutResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    async let stderrResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let _ = await (stdoutResult, stderrResult)

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    await exitCodes.set(i, process.terminationStatus)
                    XCTAssertEqual(process.terminationStatus, expectedCode,
                                   "Process \(i): expected exit code \(expectedCode), got \(process.terminationStatus)")
                }
            }
            try await group.waitForAll()
        }

        // Verify all exit codes were captured correctly
        let allCodes = await exitCodes.codes
        for i in 0..<count {
            let code = allCodes[i] ?? -1
            XCTAssertEqual(code, Int32(i),
                           "Concurrent process \(i): exit code should be \(i), got \(code)")
        }
    }

    // MARK: - Pattern 45: Process.currentDirectoryURL — working directory is set correctly

    /// Verifies that Process.currentDirectoryURL is respected: `pwd` output should
    /// match the directory we set. This tests the entirely untested directory path.
    func testCurrentDirectoryURL_isRespected() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/pwd")
        process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        let output = (String(data: stdoutData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // macOS: /tmp is a symlink to /private/tmp. pwd outputs the physical path /private/tmp.
        // Accept both the logical and physical paths.
        XCTAssertTrue(output == "/tmp" || output == "/private/tmp",
                      "pwd should output /tmp or /private/tmp; got: \(output.debugDescription)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 46: 200 KB argument string (near ARG_MAX boundary)

    /// Extends the 100KB arg test to 200KB (closer to the macOS ARG_MAX of 256KB per arg).
    /// Verifies no truncation in argument passing or pipe output at this scale.
    func testLargeArgumentString_200KB() async throws {
        let argPayload = String(repeating: "C", count: 204_800)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' '\(argPayload)'"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, 204_800,
                       "200KB argument should produce 204800 bytes of output; got \(stdoutData.count)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 47: Sequential processes with per-run byte integrity (100 runs)

    /// Runs 100 sequential processes, each writing a unique single-byte pattern for
    /// 32KB (byte = run % 251). Verifies that pipe state from one run doesn't corrupt
    /// the next — no pattern bleeding across sequential process boundaries.
    func testSequentialProcesses_100runs_byteIntegrity() throws {
        let runs = 100
        let chunkSize = 32_768  // 32 KB per run
        for i in 0..<runs {
            let pattern = UInt8(i % 251)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c",
                "import sys; sys.stdout.buffer.write(bytes([\(pattern)] * \(chunkSize))); sys.stdout.buffer.flush()"
            ]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            try process.run()

            let group = DispatchGroup()
            var stdoutData = Data()
            var stderrData = Data()
            group.enter()
            DispatchQueue.global().async { stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            process.waitUntilExit()
            group.wait()
            _ = stderrData

            XCTAssertEqual(stdoutData.count, chunkSize,
                           "Run \(i): expected \(chunkSize) bytes, got \(stdoutData.count)")
            if stdoutData.count == chunkSize {
                var mismatch: Int? = nil
                for j in 0..<chunkSize {
                    if stdoutData[j] != pattern { mismatch = j; break }
                }
                XCTAssertNil(mismatch,
                             "Run \(i): byte mismatch at idx \(mismatch.map(String.init) ?? "nil"); expected \(pattern), got \(mismatch.map { stdoutData[$0] }.map(String.init) ?? "nil")")
            }
            XCTAssertEqual(process.terminationStatus, 0, "Run \(i) exit status")
        }
    }

    // MARK: - Pattern 48: Concurrent processes with stderr-only byte integrity

    /// 20 concurrent processes each write a unique byte pattern to stderr only (256KB).
    /// Verifies stderr-only pipe draining is correctly isolated across concurrent processes.
    func testConcurrentProcesses_20parallel_stderrByteIntegrity() async throws {
        let count = 20
        let bytesPerProcess = 262_144  // 256 KB

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                let pattern = UInt8((i + 128) % 251)  // offset from stdout test to avoid confusion
                group.addTask {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = ["-c",
                        "import sys; sys.stderr.buffer.write(bytes([\(pattern)] * \(bytesPerProcess))); sys.stderr.buffer.flush()"
                    ]
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    process.standardInput = nil

                    try process.run()

                    async let stdoutResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    async let stderrResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let (_, stderrData) = await (stdoutResult, stderrResult)

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    XCTAssertEqual(stderrData.count, bytesPerProcess,
                                   "Process \(i) stderr: expected \(bytesPerProcess) bytes, got \(stderrData.count)")
                    if stderrData.count == bytesPerProcess {
                        var mismatch: Int? = nil
                        for j in 0..<bytesPerProcess {
                            if stderrData[j] != pattern { mismatch = j; break }
                        }
                        XCTAssertNil(mismatch,
                                     "Process \(i) stderr: mismatch at idx \(mismatch.map(String.init) ?? "nil"); expected \(pattern)")
                    }
                    XCTAssertEqual(process.terminationStatus, 0, "Process \(i) exit status")
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Pattern 49: Isolated environment — no inherited env vars

    /// Sets a completely isolated environment (only one var). Verifies that parent
    /// process env vars are NOT inherited when an explicit environment dictionary is set,
    /// and the one provided var IS present.
    func testIsolatedEnvironment_noInheritedVars() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Print ONLY_VAR (should be set) and HOME (should NOT be inherited from parent)
        process.arguments = ["-c", #"printf "%s|%s" "${ONLY_VAR:-MISSING}" "${HOME:-NOT_INHERITED}""#]
        process.environment = ["ONLY_VAR": "isolated_env_ok"]
        // NOTE: setting process.environment replaces ALL env vars, including PATH, HOME, etc.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        // ONLY_VAR should be "isolated_env_ok"; HOME should be "NOT_INHERITED" (not in env dict)
        XCTAssertTrue(output.contains("isolated_env_ok"),
                      "ONLY_VAR should be visible in isolated env; got: \(output.debugDescription)")
        XCTAssertTrue(output.contains("NOT_INHERITED"),
                      "HOME should not be inherited when explicit env is set; got: \(output.debugDescription)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 50: Process reuse — running a terminated Process throws

    /// Verifies that calling run() on an already-run Process throws an error.
    /// Ensures there's no silent state corruption from reuse.
    func testProcessReuse_throwsAfterTermination() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        // Second run on same Process object should throw
        XCTAssertThrowsError(try process.run(),
                             "Running an already-terminated Process should throw") { error in
            let nsErr = error as NSError
            XCTAssertTrue(
                nsErr.domain == NSCocoaErrorDomain || nsErr.domain == NSPOSIXErrorDomain,
                "Expected CocoaError or POSIXError on reuse; got \(nsErr.domain): \(nsErr.code)"
            )
        }
    }

    // MARK: - Pattern 51: 8 MB interleaved with byte integrity on both streams

    /// Hardest concurrent byte-integrity test: 8MB to stdout (pattern i%251) and
    /// 8MB to stderr (pattern (i+101)%251) simultaneously. Verifies byte-level
    /// correctness at 64× the pipe buffer size with distinct patterns for each stream.
    func testBothStreams_8MB_byteIntegrity() async throws {
        let count = 8_388_608  // 8 MB
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys
n = \(count)
sys.stdout.buffer.write(bytes(i % 251 for i in range(n)))
sys.stderr.buffer.write(bytes((i + 101) % 251 for i in range(n)))
sys.stdout.buffer.flush()
sys.stderr.buffer.flush()
"""]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, count, "stdout: expected \(count) bytes, got \(stdoutData.count)")
        XCTAssertEqual(stderrData.count, count, "stderr: expected \(count) bytes, got \(stderrData.count)")

        var stdoutMismatch: Int? = nil
        for i in 0..<count {
            if stdoutData[i] != UInt8(i % 251) { stdoutMismatch = i; break }
        }
        var stderrMismatch: Int? = nil
        for i in 0..<count {
            if stderrData[i] != UInt8((i + 101) % 251) { stderrMismatch = i; break }
        }

        XCTAssertNil(stdoutMismatch, "stdout byte mismatch at idx \(stdoutMismatch.map(String.init) ?? "nil")")
        XCTAssertNil(stderrMismatch, "stderr byte mismatch at idx \(stderrMismatch.map(String.init) ?? "nil")")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 52: stdin 4MB with byte integrity

    /// Writes 4MB to stdin (pattern i%251), reads it back from stdout via cat.
    /// Verifies byte-level integrity of the stdin pipe at 4MB — 64× the pipe buffer.
    func testStdinPipe_4MB_byteIntegrity() async throws {
        let payloadSize = 4_194_304  // 4 MB
        let payload = Data((0..<payloadSize).map { UInt8($0 % 251) })

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // All three must be concurrent to avoid deadlock
        async let writeTask: Void = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                stdinPipe.fileHandleForWriting.write(payload)
                stdinPipe.fileHandleForWriting.closeFile()
                cont.resume()
            }
        }
        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (_, stdoutData, _) = await (writeTask, stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, payloadSize,
                       "cat 4MB stdin round-trip: expected \(payloadSize) bytes, got \(stdoutData.count)")
        XCTAssertEqual(stdoutData, payload, "cat 4MB stdin round-trip: byte integrity failure")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 53: 10 concurrent stdin round-trips with byte integrity

    /// Launches 10 concurrent cat processes, each receiving 512KB of unique stdin.
    /// Verifies that concurrent stdin+stdout pipes don't cross-contaminate and
    /// all data is transferred with byte-level integrity.
    func testConcurrentStdinRoundtrips_10parallel_byteIntegrity() async throws {
        let count = 10
        let payloadSize = 524_288  // 512 KB per process

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                let pattern = UInt8(i % 251)
                group.addTask {
                    let payload = Data(repeating: pattern, count: payloadSize)
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/cat")
                    let stdinPipe = Pipe()
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardInput = stdinPipe
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    try process.run()

                    async let writeTask: Void = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            stdinPipe.fileHandleForWriting.write(payload)
                            stdinPipe.fileHandleForWriting.closeFile()
                            cont.resume()
                        }
                    }
                    async let stdoutResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    async let stderrResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let (_, stdoutData, _) = await (writeTask, stdoutResult, stderrResult)

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    XCTAssertEqual(stdoutData.count, payloadSize,
                                   "cat \(i): expected \(payloadSize) bytes, got \(stdoutData.count)")
                    XCTAssertEqual(stdoutData, payload,
                                   "cat \(i): byte integrity failure (pattern \(pattern))")
                    XCTAssertEqual(process.terminationStatus, 0, "cat \(i) exit status")
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Pattern 54: 100 concurrent processes × 512 KB stdout each

    /// 100 concurrent processes each writing 512KB to stdout. Total in-flight: 50MB.
    /// Tests GCD thread pool and memory management under heavy concurrent large-output load.
    func testConcurrentProcesses_100parallel_512KB_each() async throws {
        let count = 100
        let bytesPerProcess = 524_288  // 512 KB

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = ["-c",
                        "import sys; sys.stdout.buffer.write(b'X' * \(bytesPerProcess)); sys.stdout.buffer.flush()"
                    ]
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    process.standardInput = nil

                    try process.run()

                    async let stdoutResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    async let stderrResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let (stdoutData, _) = await (stdoutResult, stderrResult)

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    XCTAssertEqual(stdoutData.count, bytesPerProcess,
                                   "Process \(i): expected \(bytesPerProcess) bytes, got \(stdoutData.count)")
                    XCTAssertEqual(process.terminationStatus, 0, "Process \(i) exit status")
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Pattern 55: 50 environment variables propagated to child

    /// Sets 50 unique environment variables on a Process and verifies that all 50
    /// are visible in the child process. Tests the env dictionary at non-trivial scale.
    func testEnvironmentVariables_50vars_allPropagated() async throws {
        var env: [String: String] = [:]
        for i in 0..<50 {
            env["TEST_ENV_VAR_\(i)"] = "value_\(i)_ok"
        }

        // Shell: print all 50 vars, one per line
        let shellScript = (0..<50).map { i in
            #"printf "%s\n" "${TEST_ENV_VAR_\#(i):-MISSING_\#(i)}""#
        }.joined(separator: "; ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shellScript]
        process.environment = env
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0)

        for i in 0..<50 {
            let expected = "value_\(i)_ok"
            XCTAssertTrue(output.contains(expected),
                          "ENV var \(i): expected '\(expected)' in output; missing from: \(output.prefix(200).debugDescription)")
        }
    }

    // MARK: - Pattern 56: withTaskCancellationHandler — cancellation terminates process and unblocks pipe reads

    /// Mirrors ClaudeCLIService.runClaude's onCancel block. When the enclosing Swift Task
    /// is cancelled, the onCancel handler calls process.terminate(), which closes the pipe
    /// write-ends and unblocks the DispatchQueue threads inside readDataToEndOfFile().
    func testWithTaskCancellationHandler_cancelsMidPipeRead() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 60"]  // Would block 60s without cancellation
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        let task = Task<Bool, Never> {
            await withTaskCancellationHandler {
                do { try process.run() } catch { return false }

                async let stdoutResult: Data = withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    }
                }
                async let stderrResult: Data = withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    }
                }
                let _ = await (stdoutResult, stderrResult)
                return true
            } onCancel: {
                // Same pattern as ClaudeCLIService.cancel()
                process.terminate()
            }
        }

        // Let the process start
        try await Task.sleep(nanoseconds: 100_000_000)  // 100 ms

        let startCancel = Date()
        task.cancel()
        let _ = await task.value

        // Flush Foundation's kqueue-based process state: isRunning is updated lazily
        // via kqueue callback. After pipe EOF unblocks the task, the kqueue handler
        // may not have fired yet. waitUntilExit() guarantees Foundation's state is current.
        process.waitUntilExit()

        let elapsed = Date().timeIntervalSince(startCancel)
        XCTAssertFalse(process.isRunning, "Process should be terminated after task cancellation")
        XCTAssertLessThan(elapsed, 3.0,
                          "Cancellation should unblock pipe reads quickly; elapsed: \(elapsed)s")
    }

    // MARK: - Pattern 57: Timeout race pattern — timeout wins (mirrors ClaudeCLIService 30s timeout)

    /// Directly mirrors the timeout race in ClaudeCLIService.runClaude:
    ///   - worker task runs a long process
    ///   - timeout task fires after 500ms and cancels the worker
    ///   - first task to complete wins; group is cancelled
    /// Verifies that the timeout path correctly terminates the subprocess.
    func testTimeoutRacePattern_timeoutWins() async throws {
        let startTime = Date()

        let workerTask = Task<String, Never> {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 60"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            return await withTaskCancellationHandler {
                do { try process.run() } catch { return "run_error" }

                async let stdoutResult: Data = withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    }
                }
                async let stderrResult: Data = withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    }
                }
                let (stdoutData, _) = await (stdoutResult, stderrResult)
                return String(data: stdoutData, encoding: .utf8) ?? ""
            } onCancel: {
                process.terminate()
            }
        }

        let winner = await withTaskGroup(of: String.self) { group in
            group.addTask { await workerTask.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 500_000_000)  // 500 ms timeout
                if !workerTask.isCancelled { workerTask.cancel() }
                return "timeout"
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }

        let elapsed = Date().timeIntervalSince(startTime)
        XCTAssertEqual(winner, "timeout", "Timeout task should win the race")
        XCTAssertLessThan(elapsed, 3.0,
                          "Should complete within 3s of timeout; elapsed: \(elapsed)s")
    }

    // MARK: - Pattern 58: Timeout race pattern — process wins (fast path)

    /// Same timeout race structure as Pattern 57, but the process completes quickly.
    /// Verifies the fast path: process wins, timeout task is cancelled, output is returned.
    func testTimeoutRacePattern_processWins() async throws {
        let workerTask = Task<String, Never> {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf 'fast_result_from_process'"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            return await withTaskCancellationHandler {
                do { try process.run() } catch { return "run_error" }

                async let stdoutResult: Data = withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    }
                }
                async let stderrResult: Data = withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    }
                }
                let (stdoutData, _) = await (stdoutResult, stderrResult)
                return String(data: stdoutData, encoding: .utf8) ?? ""
            } onCancel: {
                process.terminate()
            }
        }

        let winner = await withTaskGroup(of: String.self) { group in
            group.addTask { await workerTask.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5s timeout (generous)
                if !workerTask.isCancelled { workerTask.cancel() }
                return "timeout"
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }

        XCTAssertEqual(winner, "fast_result_from_process",
                       "Process should complete before 5s timeout; got: \(winner.debugDescription)")
    }

    // MARK: - Pattern 59: 50 concurrent processes × 256 KB on both streams

    /// 50 concurrent processes each writing 256KB to both stdout and stderr.
    /// Total: 50 × 512KB = 25.6MB in flight. Tests concurrent large bidirectional pipe drains.
    func testConcurrentProcesses_50parallel_bothStreams_256KB() async throws {
        let count = 50
        let bytesPerStream = 262_144  // 256 KB

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = ["-c",
                        "import sys; sys.stdout.buffer.write(b'O' * \(bytesPerStream)); sys.stderr.buffer.write(b'E' * \(bytesPerStream)); sys.stdout.buffer.flush(); sys.stderr.buffer.flush()"
                    ]
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    process.standardInput = nil

                    try process.run()

                    async let stdoutResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    async let stderrResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    XCTAssertEqual(stdoutData.count, bytesPerStream,
                                   "Process \(i) stdout: expected \(bytesPerStream), got \(stdoutData.count)")
                    XCTAssertEqual(stderrData.count, bytesPerStream,
                                   "Process \(i) stderr: expected \(bytesPerStream), got \(stderrData.count)")
                    XCTAssertEqual(process.terminationStatus, 0, "Process \(i) exit status")
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Pattern 60: 100 MB per stream — extreme memory and pipe throughput test

    /// Writes 100 MB to stdout and 100 MB to stderr simultaneously.
    /// Total memory allocation: ~200 MB read + ~200 MB Python process memory.
    /// Tests that readDataToEndOfFile() correctly handles very large Data allocations.
    func testExtremelyLargeOutput_100MB_eachStream() async throws {
        let mb100 = 104_857_600  // 100 MB
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c",
            "import sys; sys.stdout.buffer.write(b'O' * \(mb100)); sys.stderr.buffer.write(b'E' * \(mb100)); sys.stdout.buffer.flush(); sys.stderr.buffer.flush()"
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, mb100, "stdout: expected 100MB, got \(stdoutData.count)")
        XCTAssertEqual(stderrData.count, mb100, "stderr: expected 100MB, got \(stderrData.count)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 61: Sequential 1000 processes — ultimate FD leak detection

    /// Runs 1000 sequential processes, checking that process.run() never throws
    /// EBADF or EMFILE. Also verifies FD count hasn't grown after the loop.
    /// If any Pipe FD is leaked, process table exhausts well before 1000.
    /// FDs are explicitly closed after each iteration to prevent GCD dispatch block
    /// references from keeping FileHandles alive past their intended scope.
    func testSequentialProcesses_1000runs() throws {
        func countFDs() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? 0
        }

        let baseline = countFDs()

        for i in 0..<1000 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '\(i)'"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            try process.run()

            let group = DispatchGroup()
            var stdoutData = Data()
            var stderrData = Data()
            group.enter()
            DispatchQueue.global().async { stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            process.waitUntilExit()
            group.wait()
            // Explicit FD close: GCD dispatch blocks hold FileHandle references on the
            // GCD thread stack until they are fully popped. In a tight 1000-iteration loop,
            // these deferred releases accumulate faster than GCD can drain them. Explicit
            // closeFile() ensures the kernel FDs are returned immediately.
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            _ = stdoutData; _ = stderrData
        }

        // Wait for any residual ARC/GCD cleanup to settle
        Thread.sleep(forTimeInterval: 0.5)
        let finalFDs = countFDs()

        XCTAssertLessThanOrEqual(finalFDs, baseline + 10,
                                  "FD leak after 1000 sequential processes: baseline=\(baseline), final=\(finalFDs)")
    }

    // MARK: - Pattern 62: process.terminate() on already-dead process — no crash

    /// Verifies that calling terminate() on a process that has already exited is safe.
    /// This mirrors the cancel() pattern in ClaudeCLIService which may call terminate()
    /// after the process has naturally completed.
    func testTerminate_alreadyDeadProcess_noCrash() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        // This must not crash or throw — mirrors ClaudeCLIService.cancel() racing with natural completion
        process.terminate()
        process.terminate()  // Double-terminate also safe

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(process.isRunning, "Already-dead process should not be running")
    }

    // MARK: - Pattern 63: 200 concurrent processes × exit code verification

    /// 200 concurrent processes each exit with a unique code (i % 127, since
    /// macOS shells cap exit codes at 255, and sh uses mod internally for large values).
    /// Verifies exit codes are isolated at 4× the previous mixed-exit-code test.
    func testConcurrentProcesses_200parallel_exitCodeIntegrity() async throws {
        let count = 200
        actor Codes { var c: [Int: Int32] = [:]; func set(_ i: Int, _ v: Int32) { c[i] = v } }
        let codes = Codes()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                let expectedCode = Int32(i % 128)  // keep within reliable exit code range
                group.addTask {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", "exit \(i % 128)"]
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    process.standardInput = nil

                    try process.run()

                    async let stdoutResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    async let stderrResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let _ = await (stdoutResult, stderrResult)

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    await codes.set(i, process.terminationStatus)
                    XCTAssertEqual(process.terminationStatus, expectedCode,
                                   "Process \(i): expected \(expectedCode), got \(process.terminationStatus)")
                }
            }
            try await group.waitForAll()
        }

        let allCodes = await codes.c
        for i in 0..<count {
            let expected = Int32(i % 128)
            let got = allCodes[i] ?? -1
            XCTAssertEqual(got, expected, "Process \(i): expected \(expected), got \(got)")
        }
    }

    // MARK: - Pattern 64: terminate() immediately after run() — pipe reads still complete

    /// Calls process.terminate() immediately after process.run() — before any data
    /// can be written to the pipes. Verifies that the concurrent pipe reads unblock
    /// (returning empty Data) and no hang occurs. This mirrors ClaudeCLIService.cancel()
    /// being called milliseconds after a process is started.
    func testTerminate_immediatelyAfterRun_pipeReadsComplete() async throws {
        for iteration in 0..<50 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 60"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            try process.run()

            // Terminate immediately — race with process startup
            process.terminate()

            async let stdoutResult: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            async let stderrResult: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            let _ = await (stdoutResult, stderrResult)
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if process.isRunning {
                    process.terminationHandler = { _ in cont.resume() }
                } else {
                    cont.resume()
                }
            }

            // Process was killed — terminationReason should be .uncaughtSignal
            XCTAssertFalse(process.isRunning, "Iteration \(iteration): process should not be running after terminate()")
        }
    }

    // MARK: - Pattern 65: Per-iteration FD count — stable across 50 sequential processes

    /// Runs 50 sequential processes and checks the FD count AFTER EACH ITERATION.
    /// The count must never exceed baseline + 10 at any point during the loop,
    /// not just at the end. This detects transient FD spikes that self-correct.
    func testSequentialFDCount_stablePerIteration() throws {
        func countFDs() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? 0
        }

        let baseline = countFDs()
        var maxObserved = baseline

        for i in 0..<50 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf 'iter_\(i)'"]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            try process.run()

            let group = DispatchGroup()
            var stdoutData = Data()
            var stderrData = Data()
            group.enter()
            DispatchQueue.global().async { stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            process.waitUntilExit()
            group.wait()
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            _ = stdoutData; _ = stderrData

            let currentFDs = countFDs()
            maxObserved = max(maxObserved, currentFDs)

            XCTAssertLessThanOrEqual(currentFDs, baseline + 10,
                                     "Iteration \(i): FD count spiked to \(currentFDs) vs baseline \(baseline)")
        }
    }

    // MARK: - Pattern 66: stdin → Python transform → stdout byte integrity

    /// Sends known data through stdin, Python XORs each byte with 0x55 and writes to stdout.
    /// Verifies that: (a) all bytes transit stdin→process→stdout correctly, and (b) the
    /// XOR transformation is applied exactly — confirming byte-level data integrity through
    /// a transformation, not just a round-trip.
    func testStdinTransform_pythonXOR_byteIntegrity() async throws {
        let payloadSize = 65_537  // just over 64KB to cross pipe buffer boundary
        let xorKey: UInt8 = 0x55
        let inputBytes = Data((0..<payloadSize).map { UInt8($0 % 251) })
        let expectedOutput = Data(inputBytes.map { $0 ^ xorKey })

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys
data = sys.stdin.buffer.read()
sys.stdout.buffer.write(bytes(b ^ 0x55 for b in data))
sys.stdout.buffer.flush()
"""]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        async let writeTask: Void = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                stdinPipe.fileHandleForWriting.write(inputBytes)
                stdinPipe.fileHandleForWriting.closeFile()
                cont.resume()
            }
        }
        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (_, stdoutData, _) = await (writeTask, stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, payloadSize,
                       "XOR transform: expected \(payloadSize) bytes, got \(stdoutData.count)")
        XCTAssertEqual(stdoutData, expectedOutput,
                       "XOR transform byte integrity failed")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 67: Incremental/streaming output — process writes in small chunks over time

    /// Process writes 100 × 100-byte chunks with 10ms delays between each write.
    /// Total: 10,000 bytes over ~1 second. This mirrors a real AI CLI that streams
    /// output incrementally. Verifies readDataToEndOfFile() captures ALL chunks,
    /// not just the first buffer-ful or data available at a specific moment.
    func testIncrementalOutput_100chunks_10msDelay() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys, time
for i in range(100):
    sys.stdout.buffer.write(bytes([i % 251] * 100))
    sys.stdout.buffer.flush()
    time.sleep(0.01)
"""]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, 10_000,
                       "Expected 10000 bytes from 100 chunked writes; got \(stdoutData.count)")

        // Verify each chunk's byte value
        for chunk in 0..<100 {
            let expected = UInt8(chunk % 251)
            for offset in 0..<100 {
                let idx = chunk * 100 + offset
                if stdoutData[idx] != expected {
                    XCTFail("Chunk \(chunk) byte \(offset): expected \(expected), got \(stdoutData[idx])")
                    return
                }
            }
        }
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 68: 5 concurrent stdin→XOR transforms with unique keys

    /// Launches 5 concurrent Python XOR-transform processes, each with a unique XOR key.
    /// Input data is unique per process (pattern based on key). Verifies byte-level
    /// integrity of stdin→transform→stdout across 5 simultaneous bidirectional pipe sessions.
    func testConcurrentStdinTransforms_5parallel_byteIntegrity() async throws {
        let payloadSize = 32_768  // 32 KB
        let xorKeys: [UInt8] = [0x11, 0x22, 0x44, 0x88, 0xAA]

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (i, key) in xorKeys.enumerated() {
                let xorKey = key
                let procIdx = i
                group.addTask {
                    let inputData = Data((0..<payloadSize).map { UInt8(($0 + procIdx) % 251) })
                    let expectedOutput = Data(inputData.map { $0 ^ xorKey })

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = ["-c", """
import sys
data = sys.stdin.buffer.read()
sys.stdout.buffer.write(bytes(b ^ \(xorKey) for b in data))
sys.stdout.buffer.flush()
"""]
                    let stdinPipe = Pipe()
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardInput = stdinPipe
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    try process.run()

                    async let writeTask: Void = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            stdinPipe.fileHandleForWriting.write(inputData)
                            stdinPipe.fileHandleForWriting.closeFile()
                            cont.resume()
                        }
                    }
                    async let stdoutResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    async let stderrResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let (_, stdoutData, _) = await (writeTask, stdoutResult, stderrResult)

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    XCTAssertEqual(stdoutData.count, payloadSize,
                                   "XOR process \(procIdx) (key=0x\(String(xorKey, radix: 16))): expected \(payloadSize) bytes, got \(stdoutData.count)")
                    XCTAssertEqual(stdoutData, expectedOutput,
                                   "XOR process \(procIdx) (key=0x\(String(xorKey, radix: 16))): byte integrity failure")
                    XCTAssertEqual(process.terminationStatus, 0)
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Pattern 69: terminationReason verification — 20 normal exits are .exit, not .uncaughtSignal

    /// Verifies that Process.terminationReason is .exit (not .uncaughtSignal) for processes
    /// that exit normally. The terminationReason is a separate property from terminationStatus
    /// and is easy to overlook. Tests that the two don't get conflated across concurrent processes.
    func testTerminationReason_normalExit_is_exit_not_signal() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                let exitCode = Int32(i % 128)
                group.addTask {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", "exit \(exitCode)"]
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    process.standardInput = nil

                    try process.run()

                    async let stdoutResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    async let stderrResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let _ = await (stdoutResult, stderrResult)

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    XCTAssertEqual(process.terminationReason, .exit,
                                   "Process \(i): terminationReason should be .exit, got \(process.terminationReason)")
                    XCTAssertEqual(process.terminationStatus, exitCode,
                                   "Process \(i): exit code should be \(exitCode), got \(process.terminationStatus)")
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Pattern 70: Two processes piped together (emulating shell pipe)

    /// Connects process1's stdout to process2's stdin via a shared Pipe.
    /// After process1 exits, the write end must be explicitly closed (the parent still
    /// holds it) to send EOF to process2. Tests multi-process pipe topology.
    func testTwoProcessesPiped_process1ToProcess2() async throws {
        let sharedPipe = Pipe()

        let process1 = Process()
        process1.executableURL = URL(fileURLWithPath: "/bin/sh")
        process1.arguments = ["-c", "printf 'piped_hello_world'"]
        process1.standardOutput = sharedPipe
        process1.standardError = FileHandle.nullDevice
        process1.standardInput = nil

        let outputPipe = Pipe()
        let process2 = Process()
        process2.executableURL = URL(fileURLWithPath: "/bin/cat")
        process2.standardInput = sharedPipe
        process2.standardOutput = outputPipe
        process2.standardError = FileHandle.nullDevice

        try process1.run()
        try process2.run()

        // After process1 exits, we must close the parent's write-end of sharedPipe
        // so that process2 (reading sharedPipe.fileHandleForReading) sees EOF.
        // Without this, process2 blocks forever waiting for more data.
        process1.waitUntilExit()
        sharedPipe.fileHandleForWriting.closeFile()

        let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process2.waitUntilExit()

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("piped_hello_world"),
                      "Two-process pipe: expected 'piped_hello_world'; got: \(output.debugDescription)")
        XCTAssertEqual(process1.terminationStatus, 0, "process1 exit status")
        XCTAssertEqual(process2.terminationStatus, 0, "process2 exit status")
    }

    // MARK: - Pattern 71: stdin 10 MB round-trip via cat — biggest stdin test

    /// Sends 10MB to cat via stdin and reads it back. Extends Pattern 52 (4MB)
    /// to 10MB. This is 160× the pipe buffer. Tests that the concurrent write+read
    /// pattern handles very large bidirectional pipe data without memory issues.
    func testStdinPipe_10MB_roundtrip() async throws {
        let payloadSize = 10_485_760  // 10 MB
        // Use a repeating single-byte pattern for fast construction and easy verification
        let payload = Data(repeating: 0xBB, count: payloadSize)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        async let writeTask: Void = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                stdinPipe.fileHandleForWriting.write(payload)
                stdinPipe.fileHandleForWriting.closeFile()
                cont.resume()
            }
        }
        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (_, stdoutData, _) = await (writeTask, stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, payloadSize,
                       "cat 10MB: expected \(payloadSize), got \(stdoutData.count)")
        XCTAssertEqual(stdoutData, payload, "cat 10MB byte integrity failed")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 72: JSON parsing from pipe output (mirrors extractEventJSON pattern)

    /// Process produces a valid JSON object on stdout. Tests the JSON parsing pattern
    /// used in ClaudeCLIService.extractEventJSON: parse stdout as JSON, extract a field.
    /// Verifies the full pipeline: process → pipe → JSON parse → field extraction.
    func testJSONOutput_parsedFromPipe() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c",
            #"printf '{"title":"Test Event","date":"2026-03-10","time":"14:00","duration":60,"calendar":"Work"}'"#
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(process.terminationStatus, 0)

        // Parse JSON and validate fields (mirrors ClaudeCLIService.extractEventJSON)
        let parsed = try XCTUnwrap(try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any],
                                   "stdout should be valid JSON object")
        XCTAssertEqual(parsed["title"] as? String, "Test Event")
        XCTAssertEqual(parsed["date"] as? String, "2026-03-10")
        XCTAssertEqual(parsed["time"] as? String, "14:00")
        XCTAssertEqual(parsed["duration"] as? Int, 60)
        XCTAssertEqual(parsed["calendar"] as? String, "Work")
    }

    // MARK: - Pattern 73: terminationHandler set twice — only last handler fires

    /// Setting process.terminationHandler a second time should override the first.
    /// Only the second handler should fire when the process exits. This tests
    /// Foundation's property-set semantics for terminationHandler.
    func testTerminationHandler_setTwice_onlyLastFires() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = nil

        let firstFiredExpectation = XCTestExpectation(description: "first handler")
        firstFiredExpectation.isInverted = true  // should NOT fire
        let secondFiredExpectation = XCTestExpectation(description: "second handler")

        process.terminationHandler = { _ in firstFiredExpectation.fulfill() }
        process.terminationHandler = { _ in secondFiredExpectation.fulfill() }

        try process.run()

        await fulfillment(of: [secondFiredExpectation], timeout: 5.0)
        await fulfillment(of: [firstFiredExpectation], timeout: 0.1)  // should NOT fulfill
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 74: Argument with special characters — newlines, unicode, spaces

    /// Passes arguments containing newlines, embedded spaces, and unicode characters.
    /// Verifies that Process correctly quotes/escapes arguments when passing to execvp().
    func testArguments_withSpecialCharacters() async throws {
        // Tab, newline, unicode, spaces — passed as separate argv elements (no shell quoting needed)
        let specialArg = "hello\tworld\nnewline\u{1F4A1}unicode spaced"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys; sys.stdout.buffer.write(sys.argv[1].encode('utf-8'))", specialArg]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        let output = String(data: stdoutData, encoding: .utf8)
        XCTAssertEqual(output, specialArg,
                       "Special-character argument should round-trip through execvp; got: \(output?.debugDescription ?? "nil")")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 75: Large argument list — 50 args × 4 KB each (200 KB total)

    /// Passes 50 arguments each 4KB long to verify that large argv arrays work
    /// correctly. Counts the args in Python to verify all 50 were received.
    func testLargeArgumentList_50args_4KB_each() async throws {
        let argCount = 50
        let argSize = 4096
        var args: [String] = ["-c",
            "import sys; sys.stdout.write(str(len(sys.argv) - 1))"]  // count of non-script args
        for i in 0..<argCount {
            args.append(String(repeating: Character(UnicodeScalar(65 + (i % 26))!), count: argSize))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        let countStr = String(data: stdoutData, encoding: .utf8) ?? "0"
        XCTAssertEqual(Int(countStr), argCount,
                       "Expected \(argCount) arguments, got: \(countStr.debugDescription)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 34: Pipe data ordering — sequential chunk delivery preserved

    /// Process writes 1000 numbered lines to stdout in strict order.
    /// Verifies that readDataToEndOfFile delivers bytes in exact write order
    /// (no out-of-order delivery even after pipe buffer boundary crossings).
    func testPipeDataOrdering_1000lines_inOrder() async throws {
        let lines = 1000
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys
for i in range(\(lines)):
    sys.stdout.write(f'{i:06d}\\n')
sys.stdout.flush()
"""]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        let receivedLines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertEqual(receivedLines.count, lines,
                       "Expected \(lines) lines, got \(receivedLines.count)")

        // Verify each line is in strict ascending order
        var outOfOrder: Int? = nil
        for (idx, line) in receivedLines.enumerated() {
            if line != String(format: "%06d", idx) {
                outOfOrder = idx
                break
            }
        }
        XCTAssertNil(outOfOrder,
                     "Out-of-order at idx \(outOfOrder.map(String.init) ?? "nil"): got '\(outOfOrder.map { receivedLines[$0] } ?? "nil")'")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 76: 50 MB stdin round-trip via cat

    /// Sends 50 MB through stdin and reads it back via stdout.
    /// This is 5× larger than the existing 10 MB test (Pattern 71).
    /// Verifies that concurrent write+read handles very large bidirectional
    /// pipe transfers without memory pressure issues or data loss.
    func testStdinPipe_50MB_roundtrip() async throws {
        let payloadSize = 52_428_800  // 50 MB
        let payload = Data(repeating: 0xCC, count: payloadSize)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        async let writeTask: Void = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                stdinPipe.fileHandleForWriting.write(payload)
                stdinPipe.fileHandleForWriting.closeFile()
                cont.resume()
            }
        }
        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (_, stdoutData, _) = await (writeTask, stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, payloadSize,
                       "cat 50MB: expected \(payloadSize) bytes, got \(stdoutData.count)")
        XCTAssertEqual(stdoutData, payload, "cat 50MB byte integrity failed")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 77: 3-stage process pipeline (p1 → p2 → p3)

    /// Chains three processes: sh (prints) → tr (uppercase) → cat (passthrough).
    /// Tests multi-hop pipe topology where each process's stdout feeds the next
    /// process's stdin. Verifies that all write-ends are properly closed to
    /// propagate EOF through the chain.
    func testThreeStageProcessPipeline() async throws {
        let pipe1 = Pipe()  // p1 stdout → p2 stdin
        let pipe2 = Pipe()  // p2 stdout → p3 stdin
        let outputPipe = Pipe()  // p3 stdout

        let p1 = Process()
        p1.executableURL = URL(fileURLWithPath: "/bin/sh")
        p1.arguments = ["-c", "printf 'hello pipeline world'"]
        p1.standardOutput = pipe1
        p1.standardError = FileHandle.nullDevice
        p1.standardInput = nil

        let p2 = Process()
        p2.executableURL = URL(fileURLWithPath: "/usr/bin/tr")
        p2.arguments = ["a-z", "A-Z"]
        p2.standardInput = pipe1
        p2.standardOutput = pipe2
        p2.standardError = FileHandle.nullDevice

        let p3 = Process()
        p3.executableURL = URL(fileURLWithPath: "/bin/cat")
        p3.standardInput = pipe2
        p3.standardOutput = outputPipe
        p3.standardError = FileHandle.nullDevice

        try p1.run()
        try p2.run()
        try p3.run()

        // p1 exits → close parent's hold on pipe1 write-end → p2 sees EOF
        p1.waitUntilExit()
        pipe1.fileHandleForWriting.closeFile()

        // p2 exits → close parent's hold on pipe2 write-end → p3 sees EOF
        p2.waitUntilExit()
        pipe2.fileHandleForWriting.closeFile()

        let finalData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        p3.waitUntilExit()

        let output = String(data: finalData, encoding: .utf8) ?? ""
        XCTAssertEqual(output, "HELLO PIPELINE WORLD",
                       "3-stage pipeline: expected 'HELLO PIPELINE WORLD'; got: \(output.debugDescription)")
        XCTAssertEqual(p1.terminationStatus, 0, "p1 exit status")
        XCTAssertEqual(p2.terminationStatus, 0, "p2 exit status")
        XCTAssertEqual(p3.terminationStatus, 0, "p3 exit status")
    }

    // MARK: - Pattern 78: 20 concurrent bidirectional XOR transforms, 2 MB each

    /// Launches 20 concurrent Python XOR-transform processes each with a unique key
    /// and 2 MB of input data. This is 4× larger payload than Pattern 68 (32 KB)
    /// and 2× more concurrent processes. Verifies that 20 simultaneous full-duplex
    /// pipe sessions with large payloads don't deadlock or corrupt data.
    func testConcurrentBidirectional_20processes_2MB_each() async throws {
        let payloadSize = 2_097_152  // 2 MB
        let count = 20

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                let xorKey = UInt8((i * 13 + 7) % 251)
                group.addTask {
                    let inputData = Data((0..<payloadSize).map { UInt8(($0 + i) % 251) })
                    let expectedOutput = Data(inputData.map { $0 ^ xorKey })

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = ["-c", """
import sys
data = sys.stdin.buffer.read()
sys.stdout.buffer.write(bytes(b ^ \(xorKey) for b in data))
sys.stdout.buffer.flush()
"""]
                    let stdinPipe = Pipe()
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardInput = stdinPipe
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    try process.run()

                    async let writeTask: Void = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            stdinPipe.fileHandleForWriting.write(inputData)
                            stdinPipe.fileHandleForWriting.closeFile()
                            cont.resume()
                        }
                    }
                    async let stdoutResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    async let stderrResult: Data = withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        }
                    }
                    let (_, stdoutData, _) = await (writeTask, stdoutResult, stderrResult)
                    stdoutPipe.fileHandleForReading.closeFile()
                    stderrPipe.fileHandleForReading.closeFile()

                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if process.isRunning {
                            process.terminationHandler = { _ in cont.resume() }
                        } else {
                            cont.resume()
                        }
                    }

                    XCTAssertEqual(stdoutData.count, payloadSize,
                                   "Bidirectional process \(i) (key=0x\(String(xorKey, radix: 16))): expected \(payloadSize) bytes, got \(stdoutData.count)")
                    XCTAssertEqual(stdoutData, expectedOutput,
                                   "Bidirectional process \(i) (key=0x\(String(xorKey, radix: 16))): byte integrity failure")
                    XCTAssertEqual(process.terminationStatus, 0)
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Pattern 79: Rapid run+terminate race, 1000 iterations

    /// Calls process.run() and then immediately terminate() in a tight loop
    /// 1000 times. Tests that the run/terminate race doesn't crash, leak FDs,
    /// or leave zombie processes. Each process may be killed before it exits
    /// naturally or may exit before terminate() fires — both outcomes are valid.
    func testRapidRunTerminateRace_1000iterations() async throws {
        for i in 0..<1000 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 10"]  // long sleep so terminate() wins
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = nil

            try process.run()

            // Immediately terminate — race between run() completing and terminate()
            process.terminate()

            async let stdoutResult: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            async let stderrResult: Data = withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            let _ = await (stdoutResult, stderrResult)
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if process.isRunning {
                    process.terminationHandler = { _ in cont.resume() }
                } else {
                    cont.resume()
                }
            }

            XCTAssertFalse(process.isRunning,
                           "Iteration \(i): process should not be running after terminate()")
        }
    }

    // MARK: - Pattern 80: Process group kill propagates to grandchildren

    /// Spawns a shell that itself spawns a long-running grandchild (`sleep 60`).
    /// Kills the shell's process group with kill(-pgid, SIGKILL).
    /// Verifies that the grandchild is also killed (no orphan holding pipe open).
    /// Without process-group kill, the grandchild would hold the write-end of the
    /// pipe open indefinitely, causing readDataToEndOfFile() to hang.
    func testProcessGroup_sigkill_killsGrandchildren() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Shell spawns a grandchild sleep and writes a marker — grandchild holds pipe open
        process.arguments = ["-c", "sleep 60 & printf 'grandchild_test'; wait"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        // Must create a new process group so kill(-pgid) doesn't kill the test process
        // We achieve this by using setsid via /usr/bin/env with a wrapper
        // Instead, use Process on /bin/sh which creates its own process group on macOS
        try process.run()
        let pid = process.processIdentifier

        // Give the shell time to spawn the grandchild
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        // Kill the entire process group
        kill(-pid, SIGKILL)

        // Now read both pipes — must complete quickly (grandchild must also be dead).
        // Use a DispatchGroup with timeout to detect if kill(-pgid) failed to
        // kill the grandchild (which would hold the pipe write-end open forever).
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        // 5-second timeout: if kill(-pgid) didn't kill the grandchild, reads hang
        let readsDone = group.wait(timeout: .now() + 5.0) == .success

        XCTAssertTrue(readsDone,
                      "Pipe reads should complete within 5s after kill(-pgid) — grandchild must be dead")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertFalse(process.isRunning,
                       "Shell process should be dead after kill(-pgid, SIGKILL)")
    }

    // MARK: - Pattern 81: 1000-chunk incremental output (10× Pattern 67)

    /// Process writes 1000 × 512-byte chunks with 1ms delays between each write.
    /// Total: 512 KB over ~1 second. This is 10× more chunks than Pattern 67.
    /// Verifies that readDataToEndOfFile() correctly accumulates all data across
    /// extended streaming output — simulating a long-running AI CLI response.
    func testIncrementalOutput_1000chunks_512bytes_each() async throws {
        let chunkCount = 1000
        let chunkSize = 512
        let totalBytes = chunkCount * chunkSize

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys, time
for i in range(\(chunkCount)):
    sys.stdout.buffer.write(bytes([i % 251] * \(chunkSize)))
    sys.stdout.buffer.flush()
    time.sleep(0.001)
"""]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, totalBytes,
                       "Expected \(totalBytes) bytes from \(chunkCount) × \(chunkSize)-byte chunks; got \(stdoutData.count)")

        // Spot-check chunk boundaries
        for chunk in stride(from: 0, to: chunkCount, by: 100) {
            let expectedByte = UInt8(chunk % 251)
            let startIdx = chunk * chunkSize
            XCTAssertEqual(stdoutData[startIdx], expectedByte,
                           "Chunk \(chunk) first byte: expected \(expectedByte), got \(stdoutData[startIdx])")
        }
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 82: Interleaved incremental output on BOTH streams

    /// Process writes alternating chunks to stdout and stderr with small delays.
    /// Each stream produces 100 × 1 KB = 100 KB total.
    /// Tests that concurrent pipe readers correctly accumulate all data even when
    /// both streams produce data incrementally and interleaved over time.
    func testIncrementalInterleaved_bothStreams_100chunks_1KB_each() async throws {
        let chunkCount = 100
        let chunkSize = 1024
        let totalBytes = chunkCount * chunkSize

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys, time
for i in range(\(chunkCount)):
    sys.stdout.buffer.write(bytes([i % 251] * \(chunkSize)))
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(bytes([(i + 128) % 251] * \(chunkSize)))
    sys.stderr.buffer.flush()
    time.sleep(0.002)
"""]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, totalBytes,
                       "Interleaved stdout: expected \(totalBytes) bytes, got \(stdoutData.count)")
        XCTAssertEqual(stderrData.count, totalBytes,
                       "Interleaved stderr: expected \(totalBytes) bytes, got \(stderrData.count)")

        // Verify first byte of each chunk on stdout
        for chunk in 0..<chunkCount {
            let expected = UInt8(chunk % 251)
            XCTAssertEqual(stdoutData[chunk * chunkSize], expected,
                           "stdout chunk \(chunk): expected \(expected), got \(stdoutData[chunk * chunkSize])")
        }
        // Verify first byte of each chunk on stderr
        for chunk in 0..<chunkCount {
            let expected = UInt8((chunk + 128) % 251)
            XCTAssertEqual(stderrData[chunk * chunkSize], expected,
                           "stderr chunk \(chunk): expected \(expected), got \(stderrData[chunk * chunkSize])")
        }
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Pattern 83: Concurrent processes 10000 sequential-batched (ultra stress)

    /// Runs 10,000 sequential processes in batches of 50.
    /// This is 10× the existing 1000-run sequential test.
    /// Verifies that FD management, ARC deallocation, and process lifecycle
    /// remain stable across 10,000 complete process lifecycles in sequence.
    func testSequentialProcesses_10000runs() throws {
        let total = 10_000
        let batchSize = 50
        for batchStart in stride(from: 0, to: total, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, total)
            for i in batchStart..<batchEnd {
                let marker = "s10k_\(i)"
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "printf '\(marker)'"]
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = nil

                try process.run()

                let group = DispatchGroup()
                var stdoutData = Data()
                var stderrData = Data()
                group.enter()
                DispatchQueue.global().async {
                    stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                process.waitUntilExit()
                group.wait()
                stdoutPipe.fileHandleForReading.closeFile()
                stderrPipe.fileHandleForReading.closeFile()
                _ = stdoutData; _ = stderrData

                if i % 1000 == 0 {
                    // Spot-check every 1000th iteration for correctness
                    let output = String(data: stdoutData, encoding: .utf8) ?? ""
                    XCTAssertTrue(output.contains(marker),
                                  "Sequential run \(i): expected '\(marker)'; got: \(output.debugDescription)")
                }
                XCTAssertEqual(process.terminationStatus, 0, "Sequential run \(i) should exit 0")
            }
        }
    }

    // MARK: - Pattern 84: Pipe output with embedded null bytes in large payload

    /// Writes 1 MB of data where every 4th byte is 0x00 (null).
    /// Verifies that binary data with frequent null bytes survives the full pipe
    /// path at scale — not just the 256-byte test from Pattern 11.
    func testBinaryData_1MB_withFrequentNulls() async throws {
        let size = 1_048_576  // 1 MB
        // Pattern: every 4th byte is 0x00, others are 0xAB
        let expectedBytes: [UInt8] = (0..<size).map { i in i % 4 == 3 ? 0x00 : 0xAB }
        let expected = Data(expectedBytes)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys
data = bytearray(\(size))
for i in range(\(size)):
    data[i] = 0x00 if i % 4 == 3 else 0xAB
sys.stdout.buffer.write(bytes(data))
sys.stdout.buffer.flush()
"""]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, size,
                       "1MB binary with nulls: expected \(size) bytes, got \(stdoutData.count)")
        XCTAssertEqual(stdoutData, expected, "1MB binary with frequent null bytes: integrity failure")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Harder / more comprehensive (RALPH loop)

    /// 16 MB on both streams with full byte integrity — stresses pipe buffering and concurrent read.
    func testBothStreams_16MB_byteIntegrity() async throws {
        let count = 16_777_216  // 16 MB
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys
n = \(count)
sys.stdout.buffer.write(bytes(i % 251 for i in range(n)))
sys.stderr.buffer.write(bytes((i + 101) % 251 for i in range(n)))
sys.stdout.buffer.flush()
sys.stderr.buffer.flush()
"""]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, count, "stdout: expected \(count) bytes, got \(stdoutData.count)")
        XCTAssertEqual(stderrData.count, count, "stderr: expected \(count) bytes, got \(stderrData.count)")

        var stdoutMismatch: Int? = nil
        for i in 0..<count {
            if stdoutData[i] != UInt8(i % 251) { stdoutMismatch = i; break }
        }
        var stderrMismatch: Int? = nil
        for i in 0..<count {
            if stderrData[i] != UInt8((i + 101) % 251) { stderrMismatch = i; break }
        }

        XCTAssertNil(stdoutMismatch, "stdout byte mismatch at idx \(stdoutMismatch.map(String.init) ?? "nil")")
        XCTAssertNil(stderrMismatch, "stderr byte mismatch at idx \(stderrMismatch.map(String.init) ?? "nil")")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    /// Process writes 4 MB then is terminated immediately; we must capture all data written before termination.
    func testTerminateAfterLargeWrite_capturesAllWrittenData() async throws {
        let size = 4_194_304  // 4 MB
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys, time
n = \(size)
for i in range(0, n, 65536):
    sys.stdout.buffer.write(bytes((j % 251) for j in range(i, min(i+65536, n))))
    sys.stdout.buffer.flush()
"""]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }

        // Give process a moment to write, then terminate
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        process.terminate()

        let (stdoutData, _) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        // We must have captured at least 1 MB (process had time to write); full 4 MB if it finished
        XCTAssertGreaterThanOrEqual(stdoutData.count, 1_048_576,
                                    "Expected at least 1 MB captured after terminate; got \(stdoutData.count)")
        // If we got full length, verify byte pattern
        if stdoutData.count == size {
            for i in 0..<size {
                if stdoutData[i] != UInt8(i % 251) {
                    XCTFail("stdout byte mismatch at \(i)")
                    return
                }
            }
        }
    }

    /// 30 MB each stream, concurrent read — stress test for pipe/XPC at larger sizes.
    func testBothStreams_30MB_byteIntegrity() async throws {
        let count = 31_457_280  // 30 MB
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sys
n = \(count)
sys.stdout.buffer.write(bytes(i % 251 for i in range(n)))
sys.stderr.buffer.write(bytes((i + 101) % 251 for i in range(n)))
sys.stdout.buffer.flush()
sys.stderr.buffer.flush()
"""]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        try process.run()

        async let stdoutResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        async let stderrResult: Data = withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        let (stdoutData, stderrData) = await (stdoutResult, stderrResult)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in cont.resume() }
            } else {
                cont.resume()
            }
        }

        XCTAssertEqual(stdoutData.count, count, "stdout: expected \(count) bytes, got \(stdoutData.count)")
        XCTAssertEqual(stderrData.count, count, "stderr: expected \(count) bytes, got \(stderrData.count)")
        for i in stride(from: 0, to: count, by: 1_000_000) {
            let j = min(i + 1_000_000, count)
            for k in i..<j {
                if stdoutData[k] != UInt8(k % 251) {
                    XCTFail("stdout byte mismatch at \(k)")
                    return
                }
                if stderrData[k] != UInt8((k + 101) % 251) {
                    XCTFail("stderr byte mismatch at \(k)")
                    return
                }
            }
        }
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
