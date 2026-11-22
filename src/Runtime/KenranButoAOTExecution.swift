import Foundation

final class KenranButoAOTExecutor: KenranButoAOTExecuting {
    private struct BlockKey: Hashable { let code:Data; let budget:Int; let guestByteBudget:Int; let outputByteBudget:Int; let translatorVersion:String; let abiVersion:UInt32 }
    private let compiler:KenranButoAOTCompiler
    private let lock=NSLock()
    private var blocks:[BlockKey:KenranButoAOTExecutableBlock]=[:]
    private var order:[BlockKey]=[]
    private var executionCount=0
    private var cachedCodeBytes=0
    private let maximumCachedBlocks=64
    private let maximumCachedCodeBytes=16*1024*1024
    private let guestABI="sysv-linux-x86_64"
    init(compiler:KenranButoAOTCompiler=KenranButoAOTCompiler()){self.compiler=compiler}
    var blocksExecuted:Int{lock.lock();defer{lock.unlock()};return executionCount}
    private var isAvailable:Bool{
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        let mode=iSteamJITGetProtocolMode()
        let ready=mode==1 ? JITCoordinator.shared.isQEMUJITReady : JITCoordinator.shared.isJITReady
        return ready && iSteamAOTExecutableMemoryIsAvailable()
        #else
        return iSteamAOTExecutableMemoryIsAvailable()
        #endif
    }
    func invalidateAll(){lock.lock();blocks.removeAll(keepingCapacity:true);order.removeAll(keepingCapacity:true);cachedCodeBytes=0;lock.unlock()}
    static func makeMemoryCallbacks(for memory:GuestMemory)->KenranButoAOTMemoryCallbacks{
        var c=KenranButoAOTMemoryCallbacks();c.abi_version=1;c.struct_size=UInt32(MemoryLayout<KenranButoAOTMemoryCallbacks>.size)
        c.context=Unmanaged.passUnretained(memory).toOpaque();c.read_memory=readCallback;c.write_memory=writeCallback;return c
    }
    private typealias ReadCallback=@convention(c)(UnsafeMutableRawPointer?,UInt64,UnsafeMutableRawPointer?,Int)->Bool
    private typealias WriteCallback=@convention(c)(UnsafeMutableRawPointer?,UInt64,UnsafeRawPointer?,Int)->Bool
    private static let readCallback:ReadCallback={context,address,destination,length in
        guard let context,length>=0 else{return false};if length==0{return true};guard let destination else{return false}
        let memory=Unmanaged<GuestMemory>.fromOpaque(context).takeUnretainedValue()
        guard let data=memory.read(offset:address,length:length) else{return false}
        data.copyBytes(to:destination.assumingMemoryBound(to:UInt8.self),count:length);return true
    }
    private static let writeCallback:WriteCallback={context,address,source,length in
        guard let context,length>=0 else{return false};if length==0{return true};guard let source else{return false}
        let memory=Unmanaged<GuestMemory>.fromOpaque(context).takeUnretainedValue()
        return memory.write(Data(bytes:source,count:length),offset:address)
    }
    func execute(guestCode:Data,registers:inout [UInt64],rip:UInt64,rflags:UInt64,fsBase:UInt64,gsBase:UInt64,memory:GuestMemory,maximumInstructions:Int)->KenranButoAOTExecutionResult?{
        guard isAvailable,registers.count==16,!guestCode.isEmpty,maximumInstructions>0 else{return nil}
        let budget=min(maximumInstructions,4096)
        let key=BlockKey(code:guestCode,budget:budget,guestByteBudget:4096,outputByteBudget:1_048_576,translatorVersion:X86_64AOTTranslator.translatorVersion,abiVersion:1)
        guard let block=executableBlock(for:key) else{return nil}
        let t=block.translation
        guard t.isValid(for:guestCode,maximumOutputBytes:key.outputByteBudget),t.guestBytesConsumed>0,t.instructionCount>0,t.instructionCount<=budget else{return nil}
        return registers.withUnsafeMutableBufferPointer{rb in
            let originalRegisters=Array(rb)
            guard let gpr=rb.baseAddress else{return nil};var callbacks=Self.makeMemoryCallbacks(for:memory)
            return withUnsafePointer(to:&callbacks){cb in
                var state=KenranButoAOTGuestState()
                guard iSteamAOTGuestStateInitialize(&state,gpr,rip,rflags,fsBase,gsBase,cb,UInt64(budget)) else{return nil}
                guard block.invoke(&state) else{return nil}
                guard iSteamAOTGuestStateIsValid(&state),state.rip==rip,
                      state.instructions_executed<=UInt64(budget),state.exit_rip>=rip,
                      state.exit_rip-rip<=UInt64(t.guestBytesConsumed) else {
                    for index in rb.indices { rb[index]=originalRegisters[index] }
                    return nil
                }
                if state.exit_reason==0{
                    let (next,overflow)=rip.addingReportingOverflow(UInt64(t.guestBytesConsumed));guard !overflow else{return nil}
                    state.rip=next;state.exit_rip=next;state.instructions_executed=UInt64(t.instructionCount)
                    state.exit_reason=Self.exitCode(t.stopReason)
                }
                guard let reason=KenranButoAOTExitReason(rawValue:state.exit_reason) else {
                    for index in rb.indices { rb[index]=originalRegisters[index] }
                    return nil
                }
                let count=Int(state.instructions_executed)
                guard count>=0&&count<=budget else {
                    for index in rb.indices { rb[index]=originalRegisters[index] }
                    return nil
                }
                let consumed=(reason == .memoryReadFault || reason == .memoryWriteFault) ? Int(state.exit_rip-rip) : t.guestBytesConsumed
                guard consumed>=0&&consumed<=t.guestBytesConsumed else {
                    for index in rb.indices { rb[index]=originalRegisters[index] }
                    return nil
                }
                lock.lock();executionCount+=1;lock.unlock()
                return KenranButoAOTExecutionResult(guestBytesConsumed:consumed,instructionCount:count,exitReason:reason,exitRip:state.exit_rip,exitAddress:state.exit_address)
            }
        }
    }
    private func executableBlock(for key:BlockKey)->KenranButoAOTExecutableBlock?{
        lock.lock();if let hit=blocks[key]{lock.unlock();return hit};lock.unlock()
        guard let result=try? compiler.compile(key.code,guestABI:guestABI,maximumInstructions:key.budget,
                                               maximumGuestBytes:key.guestByteBudget,
                                               maximumOutputBytes:key.outputByteBudget),
              result.translation.isCacheable,
              result.translation.isValid(for:key.code,maximumOutputBytes:key.outputByteBudget),
              let candidate=try? KenranButoAOTExecutableBlock(translation:result.translation),
              candidate.codeByteCount<=maximumCachedCodeBytes else{return nil}
        lock.lock();if let hit=blocks[key]{lock.unlock();return hit}
        blocks[key]=candidate;order.append(key);cachedCodeBytes+=candidate.codeByteCount
        while order.count>maximumCachedBlocks || cachedCodeBytes>maximumCachedCodeBytes {
            let evicted=order.removeFirst()
            if let removed=blocks.removeValue(forKey:evicted){cachedCodeBytes-=removed.codeByteCount}
        }
        lock.unlock();return candidate
    }
    private static func exitCode(_ reason:X86_64AOTTranslation.StopReason)->UInt32{
        switch reason{case .unsupportedInstruction:return 1;case .truncatedInstruction:return 2;case .inputLimit:return 3;case .instructionLimit:return 4;case .outputLimit:return 5;case .endOfInput:return 6;case .invalidBudget:return 9}
    }
}
private final class KenranButoAOTExecutableBlock{
    let translation:X86_64AOTTranslation
    let codeByteCount:Int
    private let region:OpaquePointer
    init(translation:X86_64AOTTranslation)throws{
        guard !translation.machineCode.isEmpty,translation.machineCode.count.isMultiple(of:4),
              let code=Self.makeCode(translation),code.count<=1_048_576 else{
            throw NSError(domain:"KenranButoAOT",code:1,userInfo:[NSLocalizedDescriptionKey:"Invalid or oversized translated block."])
        }
        var error=[CChar](repeating:0,count:256)
        let created=code.withUnsafeBytes{bytes in error.withUnsafeMutableBufferPointer{message in
            iSteamAOTExecutableMemoryCreate(bytes.baseAddress,bytes.count,message.baseAddress,message.count)
        }}
        guard let created else{
            let detail=error.withUnsafeBufferPointer{$0.baseAddress.map{String(cString:$0)} ?? "AOT executable allocation failed."}
            throw NSError(domain:"KenranButoAOT",code:2,userInfo:[NSLocalizedDescriptionKey:detail])
        }
        region=created;self.translation=translation;codeByteCount=code.count
    }
    deinit{iSteamAOTExecutableMemoryDestroy(region)}
    func invoke(_ state:inout KenranButoAOTGuestState)->Bool{iSteamAOTExecutableMemoryInvoke(region,&state)}
    private static func load64(_ rt:Int,_ rn:Int,_ offset:Int)->UInt32{0xF9400000|(UInt32(offset/8)<<10)|(UInt32(rn)<<5)|UInt32(rt)}
    private static func store64(_ rt:Int,_ rn:Int,_ offset:Int)->UInt32{0xF9000000|(UInt32(offset/8)<<10)|(UInt32(rn)<<5)|UInt32(rt)}
    private static func append(_ words:[UInt32],to data:inout Data){for word in words{var le=word.littleEndian;withUnsafeBytes(of:&le){data.append(contentsOf:$0)}}}
    private static func makeCode(_ t:X86_64AOTTranslation)->Data?{
        var prologue:[UInt32]=[0xD503245F,0xAA0003F1,load64(16,17,8)] // BTI C; mov x17,x0; ldr x16,[x17,#8]
        for r in 0..<16{prologue.append(load64(r,16,r*8))}
        var epilogue:[UInt32]=[];for r in 0..<16{epilogue.append(store64(r,16,r*8))};epilogue.append(0xD65F03C0)
        var data=Data();append(prologue,to:&data);data.append(t.machineCode);append(epilogue,to:&data);return data
    }
}
