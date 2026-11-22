use idevice::remote_pairing::{PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket, PAIRABLE_HOST_SERVICE_TYPE};
use std::{collections::BTreeMap, ffi::{c_char,c_void,CStr,CString}, panic::{catch_unwind,AssertUnwindSafe}, path::Path, sync::atomic::{AtomicBool,Ordering}, time::Duration};
use tokio::{net::TcpListener,runtime::Builder,time::sleep};

pub struct AkatsubakiPairingSession { cancelled: AtomicBool }
#[repr(C)]
pub struct AkatsubakiPairingResult { pub error_message:*mut c_char, pub host_alt_irk_hex:*mut c_char }
impl Default for AkatsubakiPairingResult { fn default()->Self { Self{error_message:std::ptr::null_mut(),host_alt_irk_hex:std::ptr::null_mut()} } }
pub type Ready=Option<unsafe extern "C" fn(*mut c_void,*const c_char,u16,*const c_char)>;
pub type Pin=Option<unsafe extern "C" fn(*mut c_void,*const c_char)>;

#[no_mangle] pub extern "C" fn akatsubaki_pairing_session_new()->*mut AkatsubakiPairingSession { Box::into_raw(Box::new(AkatsubakiPairingSession{cancelled:AtomicBool::new(false)})) }
#[no_mangle] pub unsafe extern "C" fn akatsubaki_pairing_session_cancel(p:*mut AkatsubakiPairingSession){if let Some(s)=unsafe{p.as_ref()}{s.cancelled.store(true,Ordering::Release)}}
#[no_mangle] pub unsafe extern "C" fn akatsubaki_pairing_session_free(p:*mut AkatsubakiPairingSession){if !p.is_null(){drop(unsafe{Box::from_raw(p)})}}
#[no_mangle] pub unsafe extern "C" fn akatsubaki_pairing_result_free(p:*mut AkatsubakiPairingResult){let Some(r)=(unsafe{p.as_mut()})else{return};if !r.error_message.is_null(){drop(unsafe{CString::from_raw(r.error_message)})}if !r.host_alt_irk_hex.is_null(){drop(unsafe{CString::from_raw(r.host_alt_irk_hex)})}*r=Default::default()}

fn err(r:&mut AkatsubakiPairingResult,s:impl Into<String>){if let Ok(c)=CString::new(s.into()){r.error_message=c.into_raw()}}
unsafe fn read(p:*const c_char)->Result<String,String>{if p.is_null(){return Err("Missing pairing argument".into())}unsafe{CStr::from_ptr(p)}.to_str().map(str::to_owned).map_err(|e|e.to_string())}
unsafe fn optional(p:*const c_char)->Result<Option<String>,String>{if p.is_null(){return Ok(None)}let s=unsafe{CStr::from_ptr(p)}.to_str().map_err(|e|e.to_string())?;Ok((!s.is_empty()).then(||s.to_owned()))}
fn irk(s:&str)->Result<[u8;16],String>{let bytes=s.as_bytes();if bytes.len()!=32||!bytes.iter().all(u8::is_ascii_hexdigit){return Err("Invalid host altIRK".into())}let mut out=[0;16];for(i,pair)in bytes.chunks_exact(2).enumerate(){let pair=std::str::from_utf8(pair).map_err(|e|e.to_string())?;out[i]=u8::from_str_radix(pair,16).map_err(|e|e.to_string())?}Ok(out)}
fn hex(a:&[u8;16])->String{a.iter().map(|b|format!("{b:02x}")).collect()}
async fn cancelled(flag:&AtomicBool){while !flag.load(Ordering::Acquire){sleep(Duration::from_millis(100)).await}}

async fn run(s:&AtomicBool,id:String,name:String,model:String,udid:String,out:String,existing:Option<String>,alt:Option<String>,ready:Ready,pin:Pin,ctx:*mut c_void)->Result<String,String>{
 let listener=TcpListener::bind(("0.0.0.0",0)).await.map_err(|e|e.to_string())?;
 let port=listener.local_addr().map_err(|e|e.to_string())?.port();
 let mut pairing=if let Some(p)=existing{if !Path::new(&p).is_file(){return Err("Existing pairing file disappeared".into())}RpPairingFile::read_from_file(&p).await.map_err(|e|e.to_string())?}else{RpPairingFile::generate(&id)};
 let service_id=pairing.identifier.clone();
 let mut host=PairableHostInfo::generate(name,model);
 if let Some(a)=alt{host.alt_irk=irk(&a)?}
 host.identifier=service_id.clone();host.udid=udid;
 let host_irk=host.alt_irk;
 let txt:BTreeMap<String,String>=host.mdns_txt_records(&service_id).into_iter().collect();
 let sid=CString::new(service_id).map_err(|e|e.to_string())?;
 let txt=CString::new(serde_json::to_string(&txt).map_err(|e|e.to_string())?).map_err(|e|e.to_string())?;
 unsafe{ready.ok_or("Missing advertisement callback")?(ctx,sid.as_ptr(),port,txt.as_ptr())};
 let (stream,_)=tokio::select!{_=cancelled(s)=>return Err("Pairing cancelled".into()),r=listener.accept()=>r.map_err(|e|e.to_string())?};
 let mut host=PairableHost::new(RpPairingSocket::new_device(stream),host);
 let pin_callback=pin.ok_or("Missing pairing PIN callback")?;
 let callback_context = ctx as usize;
 let pin_cb = move |pin: String| {
  let callback_context = callback_context;
  async move {
   if let Ok(p) = CString::new(pin) {
    unsafe { pin_callback(callback_context as *mut c_void, p.as_ptr()) }
   }
  }
 };
 tokio::select!{_=cancelled(s)=>return Err("Pairing cancelled".into()),r=host.accept(&mut pairing,pin_cb)=>r.map_err(|e|e.to_string())?}
 pairing.write_to_file(&out).await.map_err(|e|e.to_string())?;
 debug_assert!(PAIRABLE_HOST_SERVICE_TYPE.ends_with(".local."));
 Ok(hex(&host_irk))
}

#[no_mangle]
pub unsafe extern "C" fn akatsubaki_pairing_run(p:*mut AkatsubakiPairingSession,id:*const c_char,name:*const c_char,model:*const c_char,udid:*const c_char,out:*const c_char,existing:*const c_char,alt:*const c_char,ready:Ready,pin:Pin,ctx:*mut c_void,result:*mut AkatsubakiPairingResult)->i32{
 let Some(r)=(unsafe{result.as_mut()})else{return -1};*r=Default::default();
 let Some(s)=(unsafe{p.as_ref()})else{err(r,"Invalid pairing session");return -1};
 let args=(||Ok::<_,String>((unsafe{read(id)?},unsafe{read(name)?},unsafe{read(model)?},unsafe{read(udid)?},unsafe{read(out)?},unsafe{optional(existing)?},unsafe{optional(alt)?})))();
 let(id,name,model,udid,out,existing,alt)=match args{Ok(v)=>v,Err(e)=>{err(r,e);return -1}};
 let rt=match Builder::new_multi_thread().worker_threads(2).enable_all().build(){Ok(v)=>v,Err(e)=>{err(r,e.to_string());return -1}};
 match catch_unwind(AssertUnwindSafe(||rt.block_on(run(&s.cancelled,id,name,model,udid,out,existing,alt,ready,pin,ctx)))){
  Ok(Ok(v))=>{if let Ok(v)=CString::new(v){r.host_alt_irk_hex=v.into_raw();0}else{err(r,"Invalid host altIRK result");-1}},
  Ok(Err(e))=>{let c=s.cancelled.load(Ordering::Acquire);err(r,e);if c{1}else{-1}},
  Err(_)=>{err(r,"Pairing helper panicked");-1}
 }
}

#[cfg(test)] mod tests{use super::*;#[test]fn altirk_roundtrip(){let v="00112233445566778899aabbccddeeff";assert_eq!(hex(&irk(v).unwrap()),v)}#[test]fn bad_altirk_rejected(){assert!(irk("bad").is_err())}#[test]fn correct_service(){assert_eq!(PAIRABLE_HOST_SERVICE_TYPE,"_remotepairing-pairable-host._tcp.local.")}}
