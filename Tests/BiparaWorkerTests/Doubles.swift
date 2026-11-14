import Foundation

/// Test doubles: small Python scripts written to temp directories at test
/// time. They are protocol-level fakes with controlled timing/behavior —
/// NOT part of the product runtime and never the packaged worker.
enum WorkerDoubles {
    /// A double whose behavior depends on its launch number (tracked via a
    /// marker file) and mode flags:
    /// - "hang": answer requests after a long sleep (watchdog/busy tests)
    /// - "dieAfterReady": ready then exit immediately (crash test)
    /// - "echo": full loopback worker answering translate requests
    /// - "slowEcho": echo with a per-request delay (busy/cancel tests)
    /// - "neverExit": ignore stdin EOF and shutdown (escalation test)
    /// - "badHandshake": ready with a wrong max_inflight
    /// - "protocolOne": ready with protocol version 1 (must be rejected
    ///   before any credential-bearing request is sent)
    /// - "fragmented": emit the result line in two writes
    /// - "envEcho": report the child environment keys inside the result
    static func write(mode: String, directory: URL) -> URL {
        let source = """
        #!\(PythonModelGatewayTests.repoRoot.appendingPathComponent("Worker/.venv/bin/python").path)
        import json, os, sys, time

        MODE = \(rawMode(mode))
        MARKER = os.path.join(\(rawPath(directory.path)), "launches")
        launches = 0
        try:
            with open(MARKER) as fh:
                launches = int(fh.read().strip() or "0")
        except OSError:
            pass
        launches += 1
        with open(MARKER, "w") as fh:
            fh.write(str(launches))

        def received(req):
            countfile = os.path.join(\(rawPath(directory.path)), "received")
            count = int(open(countfile).read()) + 1 if os.path.exists(countfile) else 1
            with open(countfile, "w") as fh:
                fh.write(str(count))

        def send(obj):
            sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\\n")
            sys.stdout.flush()

        def read():
            line = sys.stdin.readline()
            if not line:
                return None
            return json.loads(line)

        if MODE == "envEcho":
            keys = sorted(os.environ.keys())
            text = "ENVKEYS:" + ",".join(keys)
        elif launches >= 2 and MODE in ("dieAfterReady",):
            text = "second-launch"
        else:
            text = "你好，世界。"

        def op_result(req):
            if req.get("op") == "align":
                return {"v": 2, "type": "result", "id": req["id"],
                        "data": {"status": "matched",
                                 "matches": [{"quote": "装罐", "occurrence": 1}],
                                 "reason": "none"},
                        "meta": {"provider": req["config"]["provider"],
                                 "requested_model": req["config"]["model"],
                                 "requested_effort": req["config"].get("effort"),
                                 "returned_model": None,
                                 "prompt_version": req["prompt_version"],
                                 "input_tokens": None, "output_tokens": None}}
            units = req["input"]["units"]
            return {"v": 2, "type": "result", "id": req["id"],
                    "data": {"translations": [{"unit_id": u["unit_id"], "text": text + str(i)}
                                              for i, u in enumerate(units)]},
                    "meta": {"provider": req["config"]["provider"],
                             "requested_model": req["config"]["model"],
                             "requested_effort": req["config"].get("effort"),
                             "returned_model": None,
                             "prompt_version": req["prompt_version"],
                             "input_tokens": None, "output_tokens": None}}

        if MODE == "protocolOne":
            send({"v": 1, "type": "ready", "worker_version": "double",
                  "max_inflight": 4, "prompt_versions": ["translation.v1", "translation.v2", "translation.markdown.v1", "alignment.v1"]})
            sys.stdin.read()
            sys.exit(0)

        if MODE == "neverExit":
            import signal, threading
            signal.signal(signal.SIGTERM, signal.SIG_IGN)  # force the KILL rung
            def drain():
                while True:
                    line = sys.stdin.readline()
                    if not line:
                        return
                    req = json.loads(line)
                    if req.get("type") == "request":
                        received(req)
            threading.Thread(target=drain, daemon=True).start()
            send({"v": 2, "type": "ready", "worker_version": "double",
                  "max_inflight": 4, "prompt_versions": ["translation.v1", "translation.v2", "translation.markdown.v1", "alignment.v1"]})
            while True:
                time.sleep(1)

        send({"v": 2, "type": "ready", "worker_version": "double",
              "max_inflight": 1 if MODE == "badHandshake" else 4,
              "prompt_versions": ["translation.v1", "translation.v2", "translation.markdown.v1", "alignment.v1"]})

        if MODE == "dieAfterReady" and launches == 1:
            sys.exit(1)

        if MODE == "fragmented":
            req = read()
            while req is not None and req.get("type") != "request":
                req = read()
            body = json.dumps(op_result(req), separators=(",", ":"))
            half = len(body) // 2
            sys.stdout.write(body[:half])
            sys.stdout.flush()
            time.sleep(0.15)
            sys.stdout.write(body[half:] + "\\n")
            sys.stdout.flush()
            sys.stdin.read()
            sys.exit(0)

        if MODE == "slowEcho":
            import threading
            slots = threading.Semaphore(4)
            stdout_lock = threading.Lock()

            def locked_send(obj):
                with stdout_lock:
                    send(obj)

            def handle(req):
                acquired = slots.acquire(blocking=False)
                if not acquired:
                    locked_send({"v": 2, "type": "error", "id": req["id"],
                                 "code": "busy", "retry_after_ms": None})
                    return
                try:
                    time.sleep(1.5)
                    locked_send(op_result(req))
                finally:
                    slots.release()

            workers = []
            while True:
                req = read()
                if req is None:
                    for t in workers:
                        t.join()
                    sys.exit(0)
                if req.get("type") in ("hello", "cancel"):
                    continue
                received(req)
                t = threading.Thread(target=handle, args=(req,), daemon=True)
                t.start()
                workers.append(t)

        while True:
            req = read()
            if req is None:
                sys.exit(0)
            if req.get("type") == "shutdown":
                send({"v": 2, "type": "stopped"})
                sys.exit(0)
            if req.get("type") in ("hello", "cancel"):
                continue
            received(req)
            if MODE in ("hang",):
                time.sleep(300)
                continue
            send(op_result(req))
        """
        let url = directory.appendingPathComponent("double_\(mode)_\(UUID().uuidString.prefix(6)).py")
        try! source.data(using: .utf8)!.write(to: url)
        // Executable bit + shebang: the gateway launches its executable
        // URL directly with no shell or interpreter arguments.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private static func rawMode(_ mode: String) -> String {
        return "\"" + mode + "\""
    }

    private static func rawPath(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func waitForRequests(_ count: Int, directory: URL) async throws {
        try await waitUntil {
            let text = try? String(contentsOf: directory.appendingPathComponent("received"), encoding: .utf8)
            return (Int(text ?? "") ?? 0) >= count
        }
    }

    /// Requests observed by the double so far.
    static func requestsReceived(directory: URL) -> Int {
        let text = try? String(contentsOf: directory.appendingPathComponent("received"), encoding: .utf8)
        return Int(text ?? "") ?? 0
    }

    static func waitUntil(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while try await !condition() {
            if ContinuousClock.now >= deadline { throw NSError(domain: "fixture barrier timeout", code: 1) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Launch count observed by the double so far.
    static func launches(directory: URL) -> Int {
        let marker = directory.appendingPathComponent("launches")
        guard let content = try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return 0
        }
        return Int(content) ?? 0
    }
}
