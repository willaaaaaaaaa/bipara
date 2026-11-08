import BiparaCore
@testable import BiparaWorker
import Foundation
import Testing

@Suite("Swift result validation regressions")
struct ValidationTests {
    let config=PythonModelGatewayTests.configuration()
    let unit=TranslateBatchUnit(unitID:UUID(),kind:.sentence,text:"Hello.")
    func payload()->PythonModelGateway.WirePayload{
        .init(data:["translations":[["unit_id":unit.unitID.uuidString.lowercased(),"text":"A translation."]]],
              meta:["provider":config.provider,"requested_model":config.model,"requested_effort":config.effort.rawValue,"returned_model":NSNull(),"prompt_version":"translation.v1","input_tokens":NSNull(),"output_tokens":NSNull()])
    }
    @Test(arguments:[""," leading","trailing ","line\nbreak",String(repeating:"a",count:8193),"\u{1c}value"])
    func badTranslationIsRejected(text:String){
        var p=payload();p.data=["translations":[["unit_id":unit.unitID.uuidString.lowercased(),"text":text]]]
        #expect(throws:GatewayError.self){try PythonModelGateway.mapTranslate(p,requestedUnits:[unit],configuration:config,promptVersion:"translation.v1")}
    }
    @Test(arguments:["provider","requested_model","requested_effort","prompt_version","input_tokens","output_tokens","returned_model"])
    func attributionAndRequiredNullabilityAreChecked(field:String){
        var p=payload()
        if field=="input_tokens" || field=="output_tokens"{p.meta[field] = -1}
        else if field=="returned_model"{p.meta.removeValue(forKey:field)}
        else{p.meta[field]="wrong"}
        #expect(throws:GatewayError.self){try PythonModelGateway.mapTranslate(p,requestedUnits:[unit],configuration:config,promptVersion:"translation.v1")}
    }
    @Test func validNullMetadataStaysNull()throws{
        let result=try PythonModelGateway.mapTranslate(payload(),requestedUnits:[unit],configuration:config,promptVersion:"translation.v1")
        #expect(result.meta.inputTokens==nil);#expect(result.meta.returnedModel==nil)
    }
    @Test func aLegacyResultCannotSatisfyAV2Request() {
        #expect(throws: GatewayError.self) {
            try PythonModelGateway.mapTranslate(payload(), requestedUnits: [unit],
                configuration: config, promptVersion: "translation.v2")
        }
    }
    @Test func unsupportedPromptIsRejectedBeforeWorkerLaunch() async throws {
        let gateway = PythonModelGateway(executableURL: URL(fileURLWithPath: "/bipara-nonexistent-test-worker"))
        let request = TranslateBatchRequest(sourceLanguage: .en, targetLanguage: .zh,
            contextBefore: "", contextAfter: "", units: [unit], promptVersion: "alignment.v1")
        await #expect(throws: GatewayError(code: .invalidRequest, isLocal: true)) {
            try await gateway.translateBatch(request, configuration: config)
        }
        await gateway.shutdown()
    }
    @Test func alignmentSchemaAndLiteralRangeAreChecked(){
        var p=payload();p.meta["prompt_version"]="alignment.v1"
        for data:[String:Any] in [
            ["status":"no_match","reason":"ambiguous"],
            ["status":"no_match","reason":"invented","matches":[]],
            ["status":"matched","reason":"none","matches":[["quote":"missing","occurrence":1]]],
            ["status":"matched","reason":"none","matches":[["quote":"e","occurrence":1]]]
        ]{
            p.data=data
            #expect(throws:GatewayError.self){try PythonModelGateway.mapAlign(p,configuration:config,counterpart:"e\u{301} test")}
        }
    }
    @Test(arguments:[NSNumber(value:true),NSNumber(value:1.5),NSNumber(value:-1),NSNumber(value:3_600_001)])
    func malformedErrorRetryIsRejected(retry:NSNumber){
        #expect(throws:GatewayError.self){try WorkerManager.mapError(["code":"rate_limited","retry_after_ms":retry])}
    }
    @Test func errorFrameKeepsOnlyRecognizedDiagnostics() throws {
        var frame: [String: Any] = [
            "code": "authentication", "retry_after_ms": NSNull(), "http_status": 401,
            "provider_code": "1001", "message": "synthetic-key and private source"
        ]
        let authentication = try WorkerManager.mapError(frame)
        #expect(authentication.code == .authentication)
        #expect(authentication.httpStatus == 401)
        #expect(authentication.providerCode == "1001")

        frame["http_status"] = true
        frame["provider_code"] = "synthetic_key"
        frame["validation_reason"] = "private_source"
        let untrusted = try WorkerManager.mapError(frame)
        #expect(untrusted == GatewayError(code: .authentication))

        let invalid = try WorkerManager.mapError([
            "code": "invalid_output", "retry_after_ms": NSNull(), "validation_reason": "invalid_json"
        ])
        #expect(invalid.validationFailure == .invalidJSON)
    }

    @Test func inputBoundsRejectBeforeLaunchingWorker() async throws {
        let gateway=PythonModelGateway(executableURL:URL(fileURLWithPath:"/bipara-nonexistent-test-worker"))
        let expanded=TranslateBatchRequest(sourceLanguage:.en,targetLanguage:.zh,contextBefore:"",contextAfter:"",
            units:(0..<6).map{_ in .init(unitID:UUID(),kind:.sentence,text:"a" + String(repeating:"\0",count:1022) + "b")})
        await #expect(throws:GatewayError(code:.invalidRequest,isLocal:true)){
            try await gateway.translateBatch(expanded,configuration:config)
        }
        let reading=String(repeating:"a",count:4097),counterpart=String(repeating:"b",count:4096)
        await #expect(throws:GatewayError(code:.invalidRequest,isLocal:true)){
            try await gateway.alignSelection(.init(readingText:reading,counterpartText:counterpart,before:"",selectedText:"a",after:String(reading.dropFirst())),configuration:config)
        }
        await #expect(throws:GatewayError(code:.executableMissing,isLocal:true)){
            try await gateway.translateBatch(.init(sourceLanguage:.en,targetLanguage:.zh,contextBefore:"",contextAfter:"",units:[unit]),configuration:config)
        }
        await gateway.shutdown()
    }
}
