import Foundation
enum KenranButoAOTExitReason: UInt32 {
 case none=0, unsupportedInstruction=1, truncatedInstruction=2, inputLimit=3
 case instructionLimit=4, outputLimit=5, endOfInput=6, memoryReadFault=7
 case memoryWriteFault=8, invalidState=9
}
struct KenranButoAOTExecutionResult {
 let guestBytesConsumed:Int; let instructionCount:Int; let exitReason:KenranButoAOTExitReason
 let exitRip:UInt64; let exitAddress:UInt64
}
protocol KenranButoAOTExecuting:AnyObject {
 var isAvailable: Bool { get }
 func refreshAvailability() -> Bool
 func execute(guestCode:Data,registers:inout [UInt64],rip:UInt64,rflags:UInt64,
              fsBase:UInt64,gsBase:UInt64,memory:GuestMemory,maximumInstructions:Int)->KenranButoAOTExecutionResult?
 func invalidateAll()
}
final class KenranButoAOTExecutor:KenranButoAOTExecuting {
 static let maximumDispatchInstructions = 256
 private struct BlockKey:Hashable {
  let code:Data;let instructionBudget:Int;let inputBudget:Int;let outputBudget:Int
  let translatorVersion:String;let abiVersion:UInt32
 }
 private let compiler:KenranButoAOTCompiler
 private let lock=NSLock()
 private var blocks:[BlockKey:KenranButoAOTExecutableBlock]=[:]
 private var order:[BlockKey]=[]
 private var executionCount=0
 private var cachedExecutableBytesStorage:UInt64=0
 private let maximumCachedBlocks=64
 private let maximumCachedExecutableBytes:UInt64=16*1024*1024
 private let maximumGuestBytes=4096
 private let maximumOutputBytes=X86_64AOTTranslator.maximumOutputBudget
 private let guestABI="sysv-linux-x86_64"
 init(compiler:KenranButoAOTCompiler=KenranButoAOTCompiler()){self.compiler=compiler}
 var blocksExecuted:Int{lock.lock();defer{lock.unlock()};return executionCount}
 var cachedBlockCount:Int{lock.lock();defer{lock.unlock()};return blocks.count}
 var cachedExecutableBytes:UInt64{lock.lock();defer{lock.unlock()};return cachedExecutableBytesStorage}
 private var availabilitySnapshot=false
 var isAvailable:Bool{lock.lock();defer{lock.unlock()};return availabilitySnapshot}
 func refreshAvailability()->Bool{
  let ready=iSteamAOTExecutableMemoryIsAvailable()
  lock.lock()
  availabilitySnapshot=ready
  if !ready{
   blocks.removeAll(keepingCapacity:true)
   order.removeAll(keepingCapacity:true)
   cachedExecutableBytesStorage=0
  }
  lock.unlock()
  return ready
 }
 func invalidateAll(){lock.lock();blocks.removeAll(keepingCapacity:true);order.removeAll(keepingCapacity:true);cachedExecutableBytesStorage=0;lock.unlock()}
 static func makeMemoryCallbacks(for memory:GuestMemory)->KenranButoAOTMemoryCallbacks{
  var c=KenranButoAOTMemoryCallbacks();c.abi_version=KENRAN_BUTO_AOT_ABI_VERSION
  c.struct_size=UInt32(MemoryLayout<KenranButoAOTMemoryCallbacks>.size)
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
 func execute(guestCode:Data,registers:inout [UInt64],rip:UInt64,rflags:UInt64,
              fsBase:UInt64,gsBase:UInt64,memory:GuestMemory,maximumInstructions:Int)->KenranButoAOTExecutionResult?{
  guard isAvailable,registers.count==16,!guestCode.isEmpty,guestCode.count<=maximumGuestBytes,maximumInstructions>0 else{return nil}
  let budget=min(maximumInstructions,Self.maximumDispatchInstructions)
  let key=BlockKey(code:guestCode,instructionBudget:budget,inputBudget:maximumGuestBytes,
   outputBudget:maximumOutputBytes,translatorVersion:X86_64AOTTranslator.translatorVersion,
   abiVersion:KENRAN_BUTO_AOT_ABI_VERSION)
  guard let block=executableBlock(for:key) else{return nil}
  let t=block.translation
  guard t.isValid(for:guestCode,maximumOutputBytes:maximumOutputBytes),
        t.guestBytesConsumed>0,t.instructionCount>0,t.instructionCount<=budget else{return nil}
  var candidateRegisters=registers
  let result=candidateRegisters.withUnsafeMutableBufferPointer{rb->KenranButoAOTExecutionResult? in
   guard let gpr=rb.baseAddress else{return nil}
   var callbacks=Self.makeMemoryCallbacks(for:memory)
   return withUnsafePointer(to:&callbacks){cb in
    var state=KenranButoAOTGuestState()
    guard iSteamAOTGuestStateInitialize(&state,gpr,rip,rflags,fsBase,gsBase,cb,UInt64(budget)),
          block.invoke(&state) else{return nil}
    guard state.abi_version==KENRAN_BUTO_AOT_ABI_VERSION,
          state.struct_size>=UInt32(MemoryLayout<KenranButoAOTGuestState>.size),
          state.gpr==gpr,state.memory==cb,state.instruction_budget==UInt64(budget),
          state.rip==rip,state.rflags==rflags,state.fs_base==fsBase,state.gs_base==gsBase else{return nil}
    let reason:KenranButoAOTExitReason
    if state.exit_reason==KENRAN_BUTO_AOT_EXIT_NONE{
     reason=Self.exitReason(t.stopReason)
     let (next,overflow)=rip.addingReportingOverflow(UInt64(t.guestBytesConsumed));guard !overflow else{return nil}
     state.exit_rip=next;state.instructions_executed=UInt64(t.instructionCount);state.exit_reason=reason.rawValue
    }else{
     guard let native=KenranButoAOTExitReason(rawValue:state.exit_reason),
           native == .memoryReadFault || native == .memoryWriteFault else{return nil}
     reason=native
    }
    guard KenranButoAOTExitReason(rawValue:state.exit_reason)==reason,
          state.instructions_executed<=UInt64(budget),
          state.instructions_executed<=UInt64(t.instructionCount) else{return nil}
    let consumed:Int
    if reason == .memoryReadFault || reason == .memoryWriteFault{
     guard state.exit_rip>=rip else{return nil};let delta=state.exit_rip-rip
     guard delta<=UInt64(t.guestBytesConsumed),delta<=UInt64(Int.max) else{return nil};consumed=Int(delta)
    }else{
     let (expected,overflow)=rip.addingReportingOverflow(UInt64(t.guestBytesConsumed))
     guard !overflow,state.exit_rip==expected,state.exit_address==0,
           state.instructions_executed==UInt64(t.instructionCount) else{return nil}
     consumed=t.guestBytesConsumed
    }
    return KenranButoAOTExecutionResult(guestBytesConsumed:consumed,
     instructionCount:Int(state.instructions_executed),exitReason:reason,
     exitRip:state.exit_rip,exitAddress:state.exit_address)
   }
  }
  guard let result else{return nil};registers=candidateRegisters
  lock.lock();executionCount+=1;lock.unlock();return result
 }
 private func executableBlock(for key:BlockKey)->KenranButoAOTExecutableBlock?{
  lock.lock()
  if let hit=blocks[key]{order.removeAll{$0==key};order.append(key);lock.unlock();return hit}
  lock.unlock()
  guard let compiled=try? compiler.compile(key.code,guestABI:guestABI,
    maximumInstructions:key.instructionBudget,maximumOutputBytes:key.outputBudget,maximumGuestBytes:key.inputBudget),
    compiled.translation.isCacheable,
    compiled.translation.isValid(for:key.code,maximumOutputBytes:key.outputBudget),
    let candidate=try? KenranButoAOTExecutableBlock(translation:compiled.translation) else{return nil}
  lock.lock()
  if let hit=blocks[key]{order.removeAll{$0==key};order.append(key);lock.unlock();return hit}
  guard candidate.allocatedBytes<=maximumCachedExecutableBytes else{lock.unlock();return nil}
  while !order.isEmpty && (order.count>=maximumCachedBlocks ||
    cachedExecutableBytesStorage>maximumCachedExecutableBytes-candidate.allocatedBytes){
   let old=order.removeFirst()
   if let removed=blocks.removeValue(forKey:old){
    cachedExecutableBytesStorage=cachedExecutableBytesStorage>=removed.allocatedBytes ? cachedExecutableBytesStorage-removed.allocatedBytes:0
   }
  }
  blocks[key]=candidate;order.append(key);cachedExecutableBytesStorage+=candidate.allocatedBytes
  lock.unlock();return candidate
 }
 private static func exitReason(_ r:X86_64AOTTranslation.StopReason)->KenranButoAOTExitReason{
  switch r{
  case .unsupportedInstruction:return .unsupportedInstruction
  case .truncatedInstruction:return .truncatedInstruction
  case .inputLimit:return .inputLimit
  case .instructionLimit:return .instructionLimit
  case .outputLimit:return .outputLimit
  case .endOfInput:return .endOfInput
  case .invalidBudget:return .invalidState
  }
 }
}
private final class KenranButoAOTExecutableBlock{
 let translation:X86_64AOTTranslation
 let allocatedBytes:UInt64
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
  let size=iSteamAOTExecutableMemorySize(created)
  guard size>0 else{iSteamAOTExecutableMemoryDestroy(created);throw NSError(domain:"KenranButoAOT",code:3,
   userInfo:[NSLocalizedDescriptionKey:"Unable to verify executable allocation size."])}
  region=created;allocatedBytes=UInt64(size);self.translation=translation
 }
 deinit{iSteamAOTExecutableMemoryDestroy(region)}
 func invoke(_ state:inout KenranButoAOTGuestState)->Bool{iSteamAOTExecutableMemoryInvoke(region,&state)}
 private static func load64(_ rt:Int,_ rn:Int,_ offset:Int)->UInt32{0xF9400000|(UInt32(offset/8)<<10)|(UInt32(rn)<<5)|UInt32(rt)}
 private static func store64(_ rt:Int,_ rn:Int,_ offset:Int)->UInt32{0xF9000000|(UInt32(offset/8)<<10)|(UInt32(rn)<<5)|UInt32(rt)}
 private static func append(_ words:[UInt32],to data:inout Data){for word in words{var le=word.littleEndian;withUnsafeBytes(of:&le){data.append(contentsOf:$0)}}}
 private static func makeCode(_ t:X86_64AOTTranslation)->Data?{
  var prologue:[UInt32]=[0xD503245F,0xAA0003F1,load64(16,17,8)]
  for r in 0..<16{prologue.append(load64(r,16,r*8))}
  var epilogue:[UInt32]=[];for r in 0..<16{epilogue.append(store64(r,16,r*8))}
  epilogue.append(0xD65F03C0)
  var data=Data();append(prologue,to:&data);data.append(t.machineCode);append(epilogue,to:&data);return data
 }
}
