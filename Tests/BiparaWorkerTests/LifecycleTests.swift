import BiparaCore
@testable import BiparaWorker
import Foundation
import Testing

/// Files are inter-process barriers, never timing guesses about dispatch.
private struct GatedWorker {
    let directory:URL
    let executable:URL
    init(_ mode:String)throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("bipara-gate-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        executable=directory.appendingPathComponent("worker.py")
        let interpreter=PythonModelGatewayTests.repoRoot.appendingPathComponent("Worker/.venv/bin/python").path
        let script = #"""
        #!\#(interpreter)
        import os,sys,json,time,threading,signal
        from pathlib import Path
        ROOT=Path(__file__).parent
        MODE="\#(mode)"
        counter=ROOT/'launches'
        n=int(counter.read_text())+1 if counter.exists() else 1
        counter.write_text(str(n))
        (ROOT/('pid_'+str(n))).write_text(str(os.getpid()))
        def mark(name): (ROOT/name).touch()
        def wait(name):
            while not (ROOT/name).exists():time.sleep(.002)
        def send(x):
            body=json.dumps(x,ensure_ascii=False,separators=(',',':')).encode()+b'\n'
            if MODE=='fragmented':
                for byte in body:os.write(1,bytes([byte]))
            else:os.write(1,body)
        def term(*_):
            mark('term');sys.exit(0)
        signal.signal(signal.SIGTERM,term)
        if MODE=='poison' and n==1:signal.signal(signal.SIGTERM,signal.SIG_IGN)
        if MODE=='poison' and n>1:
            try:os.kill(int((ROOT/'pid_1').read_text()),0);overlap=True
            except ProcessLookupError:overlap=False
            (ROOT/'overlap').write_text(str(overlap))
        sys.stdin.readline();mark('hello')
        if MODE=='delayedReady':wait('allow-ready')
        ready={'v':True if MODE=='boolVersion' else 2,'type':'ready','worker_version':'gate','max_inflight':4,'prompt_versions':['translation.v1','translation.v2','alignment.v1']}
        if MODE=='overlong':
            ready['padding']='';ready['padding']='x'*(1048576-len(json.dumps(ready,separators=(',',':'))))
        send(ready)
        lock=threading.Lock();count=0;cancelled=set();workers=[]
        def handle(req,k):
            if MODE=='gated' or MODE.startswith('rate:'):wait('release_'+str(k))
            if req['id'] in cancelled:send({'v':2,'type':'cancelled','id':req['id']});return
            if MODE=='poison' and n==1:
                send({'v':2,'type':'fatal','code':'worker_failed'})
                while True:time.sleep(.1)
            c=req['config']
            if MODE.startswith('rate:') and k==1:
                _,code,delay=MODE.split(':')
                with lock:send({'v':2,'type':'error','id':req['id'],'code':'rate_limited','retry_after_ms':int(delay),'http_status':429,'provider_code':code})
                return
            meta={'provider':c['provider'],'requested_model':c['model'],'requested_effort':c['effort'],'returned_model':None,'prompt_version':req['prompt_version'],'input_tokens':None,'output_tokens':None}
            text='译文'
            if MODE=='invalid':text='';meta.update(provider='glm',requested_model='wrong',prompt_version='wrong',input_tokens=-1)
            data={'translations':[{'unit_id':u['unit_id'],'text':text} for u in req['input']['units']]}
            with lock:send({'v':2,'type':'result','id':req['id'],'data':data,'meta':meta})
        for line in sys.stdin:
            req=json.loads(line);kind=req['type']
            if kind=='shutdown':
                mark('shutdown')
                if MODE=='cooperative':wait('allow-cleanup')
                mark('clean');send({'v':2,'type':'stopped'});break
            if kind=='cancel':cancelled.add(req['id']);mark('cancel');continue
            if kind!='request':continue
            count+=1;(ROOT/'received').write_text(str(count))
            if MODE.startswith('rate:'):
                (ROOT/('request_'+str(count))).write_text(req['input']['units'][0]['unit_id'])
            mark('received_'+str(count))
            if MODE=='pending' or MODE=='cooperative':continue
            t=threading.Thread(target=handle,args=(req,count),daemon=True);t.start();workers.append(t)
        """#
        try script.write(to:executable,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
    }
    func wait(_ name:String)async throws{try await WorkerDoubles.waitUntil{FileManager.default.fileExists(atPath:directory.appendingPathComponent(name).path)}}
    func release(_ name:String)throws{try Data().write(to:directory.appendingPathComponent(name))}
    func exists(_ name:String)->Bool{FileManager.default.fileExists(atPath:directory.appendingPathComponent(name).path)}
    func text(_ name:String)throws->String{try String(contentsOf:directory.appendingPathComponent(name),encoding:.utf8)}
    func cleanup(){try? FileManager.default.removeItem(at:directory)}
    func gateway()->PythonModelGateway{.init(executableURL:executable,timeouts:.init(startup:4,watchdog:4,shutdownTerm:0.3,shutdownKill:0.2))}
}

@Suite("Gateway lifecycle regressions")
struct LifecycleTests {
    let request=PythonModelGatewayTests.t01Request
    let config=PythonModelGatewayTests.configuration()

    @Test func cancelledHandshakeNeverDispatchesAndOtherWaiterSurvives()async throws{
        let worker=try GatedWorker("delayedReady");defer{worker.cleanup()};let g=worker.gateway()
        let cancelled=Task{try await g.translateBatch(request,configuration:config)}
        try await worker.wait("hello")
        let healthy=Task{try await g.translateBatch(request,configuration:config)}
        cancelled.cancel()
        do{_ = try await cancelled.value;Issue.record("cancelled caller succeeded")}catch is CancellationError{}
        #expect(!worker.exists("received_1"))
        try worker.release("allow-ready");_ = try await healthy.value
        #expect(try worker.text("received")=="1");#expect(try worker.text("launches")=="1")
        await g.shutdown()
    }
    @Test func shutdownResolvesStartupWaiters()async throws{
        let w=try GatedWorker("delayedReady");defer{w.cleanup()};let g=w.gateway()
        let task=Task{try await g.translateBatch(request,configuration:config)}
        try await w.wait("hello");await g.shutdown()
        do{_ = try await task.value;Issue.record("expected shutdown")}catch let e as GatewayError{#expect(e.code == .shuttingDown)}
    }
    @Test func gracefulShutdownWaitsForCleanupAndResolvesPendingCaller()async throws{
        let w=try GatedWorker("cooperative");defer{w.cleanup()};let g=w.gateway()
        let task=Task{try await g.translateBatch(request,configuration:config)}
        try await w.wait("received_1")
        let shutdown=Task{await g.shutdown()}
        try await w.wait("shutdown")
        #expect(!w.exists("term"));#expect(!w.exists("clean"))
        try w.release("allow-cleanup");await shutdown.value
        #expect(w.exists("clean"));#expect(!w.exists("term"))
        do{_ = try await task.value;Issue.record("expected shutdown")}catch let e as GatewayError{#expect(e.code == .shuttingDown)}
    }
    @Test func drainingEntryRetainsSlotUntilTerminal()async throws{
        let w=try GatedWorker("gated");defer{w.cleanup()};let g=w.gateway()
        // One owner session: the per-session window admits two concurrent
        // batches; the third waits even though physical slots remain.
        let session=UUID()
        func owned()->TranslateBatchRequest{
            TranslateBatchRequest(sourceLanguage:request.sourceLanguage,targetLanguage:request.targetLanguage,
                                  contextBefore:request.contextBefore,contextAfter:request.contextAfter,
                                  units:request.units,ownerSessionID:session)
        }
        let a=Task{try await g.translateBatch(owned(),configuration:config)}
        try await w.wait("received_1")
        let b=Task{try await g.translateBatch(owned(),configuration:config)}
        try await w.wait("received_2");a.cancel()
        do{_ = try await a.value;Issue.record("expected cancellation")}catch is CancellationError{}
        try await w.wait("cancel")
        let c=Task{try await g.translateBatch(owned(),configuration:config)}
        try await WorkerDoubles.waitUntil{await g.diagnostics().waiting==1}
        #expect(await g.diagnostics().slots==2);#expect(!w.exists("received_3"))
        try w.release("release_1");try await w.wait("received_3")
        try w.release("release_2");try w.release("release_3")
        _ = try await b.value;_ = try await c.value
        await g.shutdown()
    }
    @Test func perOwnerWindowQueuesWhileOwnerlessRequestAdmits()async throws{
        let w=try GatedWorker("gated");defer{w.cleanup()};let g=w.gateway()
        let session=UUID()
        func owned()->TranslateBatchRequest{
            TranslateBatchRequest(sourceLanguage:request.sourceLanguage,targetLanguage:request.targetLanguage,
                                  contextBefore:request.contextBefore,contextAfter:request.contextAfter,
                                  units:request.units,ownerSessionID:session)
        }
        let a=Task{try await g.translateBatch(owned(),configuration:config)}
        try await w.wait("received_1")
        let b=Task{try await g.translateBatch(owned(),configuration:config)}
        try await w.wait("received_2")
        // Third request of the same session queues behind the per-owner
        // window even though physical slots remain free.
        let c=Task{try await g.translateBatch(owned(),configuration:config)}
        try await WorkerDoubles.waitUntil{await g.diagnostics().waiting==1}
        #expect(!w.exists("received_3"))
        // An ownerless request (alignment-style) admits into a free slot.
        let d=Task{try await g.translateBatch(request,configuration:config)}
        try await w.wait("received_3")
        #expect(await g.diagnostics().slots==3)
        try w.release("release_1");try await w.wait("received_4")
        try w.release("release_2");try w.release("release_3");try w.release("release_4")
        _ = try await a.value;_ = try await b.value;_ = try await c.value;_ = try await d.value
        await g.shutdown()
    }
    @Test func admissionAlternatesTranslationAndOwnerless()async throws{
        let w=try GatedWorker("gated");defer{w.cleanup()};let g=w.gateway()
        let session=UUID()
        func owned()->TranslateBatchRequest{
            TranslateBatchRequest(sourceLanguage:request.sourceLanguage,targetLanguage:request.targetLanguage,
                                  contextBefore:request.contextBefore,contextAfter:request.contextAfter,
                                  units:request.units,ownerSessionID:session)
        }
        var tasks:[Task<Void,Never>]=[]
        for _ in 0..<4{tasks.append(Task{do{_ = try await g.translateBatch(request,configuration:config)}catch{}})}
        try await w.wait("received_4")
        let translation=Task{do{_ = try await g.translateBatch(owned(),configuration:config)}catch{}}
        try await WorkerDoubles.waitUntil{await g.diagnostics().waiting==1}
        let ownerless=Task{do{_ = try await g.translateBatch(request,configuration:config)}catch{}}
        try await WorkerDoubles.waitUntil{await g.diagnostics().waiting==2}
        #expect(!w.exists("received_5") && !w.exists("received_6"))
        try w.release("release_1")
        // Both classes wait; after four ownerless admissions the alternation
        // prefers the queued translation batch.
        try await w.wait("received_5");#expect(!w.exists("received_6"))
        try w.release("release_2")
        try await w.wait("received_6")
        for n in 3...6{try w.release("release_\(n)")}
        for t in tasks{_ = await t.value}
        _ = await translation.value;_ = await ownerless.value
        await g.shutdown()
    }
    @Test func replacementWaitsForOldProcessReap()async throws{
        let w=try GatedWorker("poison");defer{w.cleanup()};let g=w.gateway()
        do{_ = try await g.translateBatch(request,configuration:config);Issue.record("expected worker failure")}catch let e as GatewayError{#expect(e.code == .workerDied)}
        _ = try await g.translateBatch(request,configuration:config)
        #expect(try w.text("overlap")=="False");await g.shutdown()
    }

    @Test func glmCooldownLetsOtherRoutesRunAndSerializesSameRouteWithReplayFirst() async throws {
        let worker = try GatedWorker("rate:1302:1200")
        defer { worker.cleanup() }
        let gateway = worker.gateway()
        let glm = ModelConfiguration(provider: "glm", model: "glm-5.3-flash", profile: "glm-json-v2",
                                     baseURL: WorkerContract.glmStandardBaseURL, effort: .low,
                                     apiKey: "test", configurationID: UUID())
        let firstOwner = UUID(), secondOwner = UUID()
        func batch(owner: UUID) -> TranslateBatchRequest {
            var batch = request
            batch.ownerSessionID = owner
            batch.units[0].unitID = UUID()
            return batch
        }
        func launch(_ batch: TranslateBatchRequest, _ configuration: ModelConfiguration) -> Task<TranslateBatchResult, Error> {
            Task { try await gateway.translateBatch(batch, configuration: configuration) }
        }
        let failed = batch(owner: firstOwner)
        let initial = launch(failed, glm)
        try await worker.wait("received_1")
        let sibling = launch(batch(owner: firstOwner), glm)
        try await worker.wait("received_2")
        let beforeLimit = ContinuousClock.now
        try worker.release("release_1")
        await #expect(throws: GatewayError(code: .rateLimited, retryAfterMS: 1200, httpStatus: 429, providerCode: "1302")) {
            try await initial.value
        }

        let unsent = batch(owner: secondOwner)
        let sameRoute = launch(unsent, glm)
        try await WorkerDoubles.waitUntil { await gateway.diagnostics().waiting == 1 }
        var replay = failed
        replay.rateLimitReplayDeadline = ContinuousClock.now + .seconds(3)
        let recovery = launch(replay, glm)
        try await WorkerDoubles.waitUntil { await gateway.diagnostics().waiting == 2 }
        var alternate = glm
        alternate.configurationID = UUID()
        let otherConfiguration = batch(owner: UUID())
        let otherGLM = launch(otherConfiguration, alternate)
        try await worker.wait("received_3")
        let otherProvider = batch(owner: UUID())
        let openAI = launch(otherProvider, config)
        try await worker.wait("received_4")
        #expect(try worker.text("request_3") == otherConfiguration.units[0].unitID.uuidString.lowercased())
        #expect(try worker.text("request_4") == otherProvider.units[0].unitID.uuidString.lowercased())
        #expect(await gateway.diagnostics().slots == 3)
        for index in 2...4 { try worker.release("release_\(index)") }
        for task in [sibling, otherGLM, openAI] { _ = try await task.value }
        try await worker.wait("received_5")
        #expect(ContinuousClock.now >= beforeLimit + .milliseconds(1200))
        #expect(try worker.text("request_5") == failed.units[0].unitID.uuidString.lowercased())
        #expect(await gateway.diagnostics().slots == 1)
        #expect(!worker.exists("received_6"))
        try worker.release("release_5")
        try await worker.wait("received_6")
        #expect(try worker.text("request_6") == unsent.units[0].unitID.uuidString.lowercased())
        try worker.release("release_6")
        _ = try await recovery.value
        _ = try await sameRoute.value
        await gateway.shutdown()
    }

    @Test func cancelledGLMReplayNeverDispatches() async throws {
        let worker = try GatedWorker("rate:1305:700")
        defer { worker.cleanup() }
        let gateway = worker.gateway()
        let glm = ModelConfiguration(provider: "glm", model: "glm-5.3-flash", profile: "glm-json-v2",
                                     baseURL: WorkerContract.glmStandardBaseURL, effort: .low, apiKey: "test")
        let initial = Task { try await gateway.translateBatch(request, configuration: glm) }
        try await worker.wait("received_1")
        try worker.release("release_1")
        await #expect(throws: GatewayError.self) { try await initial.value }

        var retry = request
        retry.rateLimitReplayDeadline = ContinuousClock.now + .milliseconds(50)
        await #expect(throws: GatewayError(code: .rateLimited, retryAfterMS: 700, isLocal: true,
                                          httpStatus: 429, providerCode: "1305")) {
            try await gateway.translateBatch(retry, configuration: glm)
        }
        #expect(!worker.exists("received_2"))
        retry.rateLimitReplayDeadline = ContinuousClock.now + .seconds(3)
        let replay = Task { [retry] in try await gateway.translateBatch(retry, configuration: glm) }
        try await WorkerDoubles.waitUntil { await gateway.diagnostics().waiting == 1 }
        replay.cancel()
        await #expect(throws: CancellationError.self) { try await replay.value }
        let next = Task { try await gateway.translateBatch(request, configuration: glm) }
        try await worker.wait("received_2")
        try worker.release("release_2")
        _ = try await next.value
        #expect(!worker.exists("received_3"))
        #expect(!worker.exists("cancel"))
        await gateway.shutdown()
    }
    @Test(arguments:["boolVersion","overlong","invalid"])
    func malformedOutputNeverSucceeds(mode:String)async throws{
        let w=try GatedWorker(mode);defer{w.cleanup()};let g=w.gateway()
        do{_ = try await g.translateBatch(request,configuration:config);Issue.record("invalid output succeeded")}
        catch let e as GatewayError{#expect(e.code == (mode=="invalid" ? .invalidOutput:.workerDied))}
        if mode != "invalid"{#expect(!w.exists("received_1"))}
        await g.shutdown()
    }
    @Test func byteFragmentedFramesRemainOrdered()async throws{
        let w=try GatedWorker("fragmented");defer{w.cleanup()};let g=w.gateway()
        try await withThrowingTaskGroup(of:Void.self){group in
            for _ in 0..<20{group.addTask{let r=try await g.translateBatch(request,configuration:config);#expect(r.translations[0].text=="译文")}}
            try await group.waitForAll()
        }
        #expect(try w.text("launches")=="1");await g.shutdown()
    }
    @Test func inclusiveFrameLimit(){
        let accumulator=FrameAccumulator()
        #expect(accumulator.append(Data(repeating:0x20,count:WorkerContract.maxFrameBytes-1)) != nil)
        #expect(accumulator.append(Data([0x0A]))?.count==1)
        #expect(FrameAccumulator().append(Data(repeating:0x20,count:WorkerContract.maxFrameBytes))==nil)
    }
}
