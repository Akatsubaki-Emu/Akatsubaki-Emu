#if os(iOS)
import BackgroundTasks
import Foundation
import Network
import UIKit
import AkatsubakiPairingFFI

@MainActor final class StikPairingCoordinator {
    static let shared=StikPairingCoordinator();private init(){}
    var canGeneratePairingFile:Bool {
        #if !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if #available(iOS 27.0,*) { return ProcessInfo.processInfo.environment["LC_HOME_PATH"] == nil }
        #endif
        return false
    }
    func registerBackgroundTask(){guard canGeneratePairingFile else{return};if #available(iOS 26.0,*){StikPairingTaskRunner.shared.register()}}
    func startPairing(from controller:UIViewController,completion:(()->Void)?=nil){
        guard canGeneratePairingFile else{let a=UIAlertController(title:"On-device pairing unavailable",message:"Pairing generation requires iOS 27+ on a physical device outside LiveContainer. Import an existing file on older setups.",preferredStyle:.alert);a.addAction(UIAlertAction(title:"OK",style:.default));controller.present(a,animated:true);return}
        if #available(iOS 26.0,*){StikPairingTaskRunner.shared.start(from:controller,completion:completion)}
    }
    func applicationDidBecomeActive(){if #available(iOS 26.0,*){StikPairingTaskRunner.shared.applicationDidBecomeActive()}}
}
@available(iOS 26.0,*)
@MainActor private final class StikPairingTaskRunner:NSObject,NetServiceDelegate {
    static let shared=StikPairingTaskRunner()
    private var prefix:String{(Bundle.main.bundleIdentifier ?? "com.xthrx.isteam")+".pairing"}
    private var requestID:String?
    private var task:BGContinuedProcessingTask?
    private var session:OpaquePointer?
    private var service:NetService?
    private weak var controller:UIViewController?
    private var completion:(()->Void)?
    private var pending:(String,String)?
    private var cancelled=false
    private var registered=false
    private var failure:String?
    private override init(){super.init()}
    func register(){guard !registered else{return};registered=BGTaskScheduler.shared.register(forTaskWithIdentifier:prefix+".*",using:.main){[weak self] task in guard let self,let t=task as? BGContinuedProcessingTask else{task.setTaskCompleted(success:false);return};Task{@MainActor in self.handle(t)}}}
    func start(from c:UIViewController,completion:(()->Void)?){
        guard task == nil,session == nil,requestID == nil else{show("A pairing session is already running.","Pairing in progress");return}
        if !registered{register()};guard registered else{show("iOS could not register the pairing background task.","Pairing unavailable");return}
        controller=c;self.completion=completion;cancelled=false;failure=nil
        Task{@MainActor in
            guard await LocalPairingPermission.request() else{show("Allow Local Network access for Akatsubaki Emu in Settings, then retry.","Local Network access required");return}
            let id=prefix+"."+UUID().uuidString;requestID=id
            let r=BGContinuedProcessingTaskRequest(identifier:id,title:"Pair with Akatsubaki Emu",subtitle:"Starting Remote Pairing");r.strategy = .fail
            do{try BGTaskScheduler.shared.submit(r);showInstructions()}catch{requestID=nil;show(error.localizedDescription,"Could not start pairing")}
        }
    }
    func applicationDidBecomeActive(){if let p=pending{pending=nil;show(p.1,p.0)}}
    private func handle(_ t:BGContinuedProcessingTask){guard task == nil else{t.setTaskCompleted(success:false);return};task=t;t.progress.totalUnitCount=100;t.progress.completedUnitCount=5;t.expirationHandler={[weak self] in Task{@MainActor in self?.expire()}};t.updateTitle("Pair with Akatsubaki Emu",subtitle:"Preparing pairing service");begin()}
    private func begin(){
        do{
            let c=try StikJITPairingFileStore.prepare()
            guard let handle=akatsubaki_pairing_session_new() else{throw NSError(domain:"AkatsubakiPairing",code:1,userInfo:[NSLocalizedDescriptionKey:"Could not allocate pairing session"])}
            session=handle
            let id=c.hostID,name=Bundle.main.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? "Akatsubaki Emu",model="Mac17,7",udid=c.hostID,out=c.pending.path,existing=c.existing?.path ?? "",irk=c.hostIRK ?? ""
            let context=Unmanaged.passUnretained(self).toOpaque()
            DispatchQueue.global(qos:.userInitiated).async{[weak self] in
                var result=AkatsubakiPairingResult(error_message:nil,host_alt_irk_hex:nil)
                let status=id.withCString{a in name.withCString{b in model.withCString{d in udid.withCString{e in out.withCString{g in existing.withCString{h in irk.withCString{i in akatsubaki_pairing_run(handle,a,b,d,e,g,h,i,readyCallback,pinCallback,context,&result)}}}}}}}
                let message=result.error_message.map{String(cString:$0)},hostIRK=result.host_alt_irk_hex.map{String(cString:$0)}
                akatsubaki_pairing_result_free(&result);akatsubaki_pairing_session_free(handle)
                DispatchQueue.main.async{guard let self else{return};self.session=nil;self.finish(status,message,hostIRK,c)}
            }
        }catch{failPairing(error.localizedDescription)}
    }
    fileprivate func advertise(_ id:String,_ port:UInt16,_ json:String){
        guard task != nil,!cancelled,let data=json.data(using:.utf8),let values=try? JSONSerialization.jsonObject(with:data) as? [String:String] else{failPairing("Invalid Remote Pairing TXT record");return}
        let txt=values.reduce(into:[String:Data]()){$0[$1.key]=$1.value.data(using:.utf8)}
        let s=NetService(domain:"local.",type:"_remotepairing-pairable-host._tcp.",name:id,port:Int32(port));s.delegate=self;s.setTXTRecord(NetService.data(fromTXTRecord:txt));service=s;s.publish()
    }
    func netServiceDidPublish(_ sender:NetService){task?.progress.completedUnitCount=20;task?.updateTitle("Pair with Akatsubaki Emu",subtitle:"Open Settings → Privacy & Security → Developer Mode")}
    func netService(_ sender:NetService,didNotPublish e:[String:NSNumber]){failPairing("Bonjour publish failed: "+e.description)}
    fileprivate func showPIN(_ pin:String){task?.progress.completedUnitCount=55;task?.updateTitle("Pair with Akatsubaki Emu",subtitle:"Enter PIN "+pin+" in Developer Mode settings")}
    private func finish(_ status:Int32,_ message:String?,_ hostIRK:String?,_ c:StikJITPairingFileStore.Session){
        if cancelled{StikJITPairingFileStore.cleanPending(c.pending);finishTask(false);completion=nil;if let failure{show(failure,"Pairing failed")};return}
        guard status==0,let hostIRK else{failPairing(message ?? "Remote Pairing did not complete");return}
        do{try StikJITPairingFileStore.save(c.pending,id:c.hostID,irk:hostIRK);task?.progress.completedUnitCount=100;task?.updateTitle("Pairing complete",subtitle:"Pairing file saved");finishTask(true);JITCoordinator.shared.selectedMethod = .builtInStikJIT;completion?();completion=nil;show("Akatsubaki generated its own pairing file at Documents/StikJIT/pairingFile.plist.","Pairing complete")}
        catch{failPairing(error.localizedDescription)}
    }
    private func failPairing(_ message:String){if let session{failure=message;cancelled=true;akatsubaki_pairing_session_cancel(session);service?.stop();service=nil;return};finishTask(false);completion=nil;show(message,"Pairing failed")}
    private func expire(){cancelled=true;if let session{akatsubaki_pairing_session_cancel(session)};service?.stop();service=nil;task?.setTaskCompleted(success:false);task=nil;requestID=nil;pending=("Pairing cancelled","iOS ended the pairing task. Start a new session from Settings.")}
    private func finishTask(_ ok:Bool){service?.stop();service=nil;task?.setTaskCompleted(success:ok);task=nil;requestID=nil;cancelled=false;failure=nil}
    private func showInstructions(){let a=UIAlertController(title:"Pair this iPad",message:"Open Settings → Privacy & Security → Developer Mode → Pair with Akatsubaki Emu. Enter the PIN shown in the pairing Live Activity, then return here.",preferredStyle:.alert);a.addAction(UIAlertAction(title:"Cancel pairing",style:.cancel){[weak self] _ in self?.cancelPairing()});a.addAction(UIAlertAction(title:"OK",style:.default));controller?.present(a,animated:true)}
    private func cancelPairing(){cancelled=true;service?.stop();service=nil;if let session{akatsubaki_pairing_session_cancel(session)}else{if let requestID{BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:requestID)};finishTask(false);completion=nil}}
    private func show(_ message:String,_ title:String){guard let controller,controller.viewIfLoaded?.window != nil else{pending=(title,message);return};let a=UIAlertController(title:title,message:message,preferredStyle:.alert);a.addAction(UIAlertAction(title:"OK",style:.default));controller.present(a,animated:true)}
}
private let readyCallback:AkatsubakiPairingReadyCallback={ctx,id,port,txt in guard let ctx,let id,let txt else{return};let r=Unmanaged<StikPairingTaskRunner>.fromOpaque(ctx).takeUnretainedValue();let n=String(cString:id),j=String(cString:txt);Task{@MainActor in r.advertise(n,port,j)}}
private let pinCallback:AkatsubakiPairingPinCallback={ctx,pin in guard let ctx,let pin else{return};let r=Unmanaged<StikPairingTaskRunner>.fromOpaque(ctx).takeUnretainedValue();let p=String(cString:pin);Task{@MainActor in r.showPIN(p)}}
@MainActor private enum LocalPairingPermission {
    static func request() async -> Bool {
        await withCheckedContinuation{c in
            let b=NWBrowser(for:.bonjour(type:"_remotepairing-pairable-host._tcp",domain:nil),using:.tcp);var done=false
            let finish:(Bool)->Void={v in guard !done else{return};done=true;b.cancel();c.resume(returning:v)}
            b.stateUpdateHandler={s in switch s{case .ready:finish(true);case .failed:finish(false);default:break}}
            b.start(queue:.main);DispatchQueue.main.asyncAfter(deadline:.now()+30){finish(false)}
        }
    }
}
#else
import UIKit
@MainActor final class StikPairingCoordinator {
    static let shared=StikPairingCoordinator();private init(){}
    var canGeneratePairingFile:Bool{false}
    func registerBackgroundTask(){}
    func applicationDidBecomeActive(){}
    func startPairing(from:UIViewController,completion:(()->Void)?=nil){}
}
#endif
