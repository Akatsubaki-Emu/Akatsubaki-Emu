#include "JIT26Protocol.h"
#include "AOTExecutableArena.h"
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#if defined(KENRAN_BUTO_AOT_TESTS)
static int sTestAvailabilityOverride = -1;
void iSteamAOTExecutableMemorySetAvailabilityOverrideForTesting(int available) {
 sTestAvailabilityOverride = available;
}
#endif
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <libkern/OSCacheControl.h>
#endif
#if defined(__APPLE__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
#include <mach/mach.h>
#include <mach/vm_map.h>
#endif
#ifndef MAP_ANON
#define MAP_ANON MAP_ANONYMOUS
#endif
#define AOT_MAX_CODE_BYTES (1024u * 1024u)
struct iSteamAOTExecutableRegion { void *execute_address; void *write_address; size_t mapped_size; size_t arena_offset; bool split_mapping; bool mach_mapping; bool arena_owned; bool finalized; };
_Static_assert(offsetof(KenranButoAOTGuestState,gpr)==8,"AOT ABI v1 gpr offset changed");
_Static_assert(sizeof(KenranButoAOTGuestState)==96,"AOT ABI v1 state size changed");
_Static_assert(sizeof(KenranButoAOTMemoryCallbacks)==32,"AOT ABI v1 callback size changed");
static void set_error(char *b,size_t n,const char *m){if(b&&n)(void)snprintf(b,n,"%s",m);}
static size_t mapped_size_for(size_t n){long p=sysconf(_SC_PAGESIZE);size_t page=p>0?(size_t)p:4096u;size_t r=n%page;if(!n)return 0;if(!r)return n;if(n>SIZE_MAX-(page-r))return 0;return n+page-r;}
#if defined(__APPLE__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
#include <pthread.h>
static void deallocate_mach_address(vm_address_t a,size_t n){if(a&&n)(void)vm_deallocate(mach_task_self(),a,(vm_size_t)n);}
#define AOT_TXM_ARENA_BYTES (32u * 1024u * 1024u)
static pthread_mutex_t sTXMArenaInitLock = PTHREAD_MUTEX_INITIALIZER;
static iSteamAOTExecutableArena *sTXMArena;
static void *sTXMExecuteBase;
static void *sTXMWriteBase;
static bool sTXMArenaFailed;
static bool sTXMArenaReady;
static bool ensure_txm_arena(char *error,size_t capacity){
 if(pthread_mutex_lock(&sTXMArenaInitLock)!=0){set_error(error,capacity,"StikDebug AOT arena lock failed.");return false;}
 if(sTXMArena){bool ready=sTXMArenaReady;pthread_mutex_unlock(&sTXMArenaInitLock);return ready;}
 if(sTXMArenaFailed){pthread_mutex_unlock(&sTXMArenaInitLock);set_error(error,capacity,"StikDebug AOT arena initialization previously failed.");return false;}
 void *exec=iSteamJITPrepareRegion(NULL,AOT_TXM_ARENA_BYTES);
 if(!exec){sTXMArenaFailed=true;pthread_mutex_unlock(&sTXMArenaInitLock);set_error(error,capacity,"StikDebug executable arena unavailable.");return false;}
 vm_address_t write=0;vm_prot_t current=VM_PROT_READ;vm_prot_t maximum=VM_PROT_READ|VM_PROT_WRITE;
 kern_return_t status=vm_remap(mach_task_self(),&write,(vm_size_t)AOT_TXM_ARENA_BYTES,0,VM_FLAGS_ANYWHERE,mach_task_self(),(vm_address_t)exec,FALSE,&current,&maximum,VM_INHERIT_NONE);
 if(status!=KERN_SUCCESS||(maximum&VM_PROT_WRITE)==0){
  deallocate_mach_address(write,AOT_TXM_ARENA_BYTES);deallocate_mach_address((vm_address_t)exec,AOT_TXM_ARENA_BYTES);sTXMArenaFailed=true;
  pthread_mutex_unlock(&sTXMArenaInitLock);set_error(error,capacity,"StikDebug arena writable alias remap/protection failed.");return false;
 }
 status=vm_protect(mach_task_self(),write,(vm_size_t)AOT_TXM_ARENA_BYTES,FALSE,VM_PROT_READ|VM_PROT_WRITE);
 if(status!=KERN_SUCCESS){
  deallocate_mach_address(write,AOT_TXM_ARENA_BYTES);deallocate_mach_address((vm_address_t)exec,AOT_TXM_ARENA_BYTES);sTXMArenaFailed=true;
  pthread_mutex_unlock(&sTXMArenaInitLock);set_error(error,capacity,"StikDebug arena writable alias could not be protected.");return false;
 }
 iSteamAOTExecutableArena *arena=iSteamAOTExecutableArenaCreate(AOT_TXM_ARENA_BYTES);
 if(!arena){
  deallocate_mach_address(write,AOT_TXM_ARENA_BYTES);deallocate_mach_address((vm_address_t)exec,AOT_TXM_ARENA_BYTES);sTXMArenaFailed=true;
  pthread_mutex_unlock(&sTXMArenaInitLock);set_error(error,capacity,"StikDebug AOT arena allocator initialization failed.");return false;
 }
 sTXMArena=arena;sTXMExecuteBase=exec;sTXMWriteBase=(void *)write;
 iSteamJITDetachPreparedArena();
 sTXMArenaReady=true;
 pthread_mutex_unlock(&sTXMArenaInitLock);
 return true;
}
#endif
bool iSteamAOTExecutableMemoryIsAvailable(void){
#if defined(KENRAN_BUTO_AOT_TESTS)
 if(sTestAvailabilityOverride>=0)return sTestAvailabilityOverride!=0;
#endif
#if defined(__APPLE__) && defined(__arm64__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
 int mode=iSteamJITGetProtocolMode();
 if(mode==ISTEAM_JIT_PROTOCOL_STIKDEBUG){char error[256]={0};return ensure_txm_arena(error,sizeof(error));}
 if(mode==ISTEAM_JIT_PROTOCOL_STANDARD)return iSteamJITHasGetTaskAllow()&&iSteamJITIsReady();
 return false;
#elif defined(__APPLE__) && defined(__arm64__) && TARGET_OS_OSX && !TARGET_OS_MACCATALYST
 return true;
#else
 return false;
#endif
}
bool iSteamAOTGuestStateIsValid(const KenranButoAOTGuestState *s){
 if(!s||s->abi_version!=KENRAN_BUTO_AOT_ABI_VERSION||s->struct_size<sizeof(*s)||!s->gpr||!s->instruction_budget||!s->memory)return false;
 const KenranButoAOTMemoryCallbacks *m=s->memory;
 return m->abi_version==KENRAN_BUTO_AOT_ABI_VERSION&&m->struct_size>=sizeof(*m)&&m->read_memory&&m->write_memory;
}
bool iSteamAOTGuestStateInitialize(KenranButoAOTGuestState *s,uint64_t *g,uint64_t rip,uint64_t flags,uint64_t fs,uint64_t gs,const KenranButoAOTMemoryCallbacks *m,uint64_t budget){
 if(!s||!g||!m||!budget)return false;memset(s,0,sizeof(*s));s->abi_version=KENRAN_BUTO_AOT_ABI_VERSION;s->struct_size=(uint32_t)sizeof(*s);s->gpr=g;s->rip=rip;s->rflags=flags;s->fs_base=fs;s->gs_base=gs;s->memory=m;s->instruction_budget=budget;s->exit_rip=rip;return iSteamAOTGuestStateIsValid(s);
}
bool iSteamAOTGuestMemoryRead(KenranButoAOTGuestState *s,uint64_t a,void *d,size_t n){
 if(!n)return true;if(!iSteamAOTGuestStateIsValid(s)||!d||n>UINT64_MAX-a){if(s)s->exit_reason=KENRAN_BUTO_AOT_EXIT_INVALID_STATE;return false;}
 if(!s->memory->read_memory(s->memory->context,a,d,n)){s->exit_reason=KENRAN_BUTO_AOT_EXIT_MEMORY_READ_FAULT;s->exit_address=a;s->exit_rip=s->rip;return false;}return true;
}
bool iSteamAOTGuestMemoryWrite(KenranButoAOTGuestState *s,uint64_t a,const void *p,size_t n){
 if(!n)return true;if(!iSteamAOTGuestStateIsValid(s)||!p||n>UINT64_MAX-a){if(s)s->exit_reason=KENRAN_BUTO_AOT_EXIT_INVALID_STATE;return false;}
 if(!s->memory->write_memory(s->memory->context,a,p,n)){s->exit_reason=KENRAN_BUTO_AOT_EXIT_MEMORY_WRITE_FAULT;s->exit_address=a;s->exit_rip=s->rip;return false;}return true;
}
iSteamAOTExecutableRegion *iSteamAOTExecutableMemoryCreate(const void *code,size_t length,char *error,size_t capacity){
 if(!iSteamAOTExecutableMemoryIsAvailable()){set_error(error,capacity,"AOT executable memory unavailable; enable supported JIT.");return NULL;}
 if(!code||!length||(length%4u)||length>AOT_MAX_CODE_BYTES){set_error(error,capacity,"AOT block size/alignment invalid.");return NULL;}
 size_t mapped=mapped_size_for(length);if(!mapped){set_error(error,capacity,"AOT page-size overflow.");return NULL;}
 iSteamAOTExecutableRegion *r=calloc(1,sizeof(*r));if(!r){set_error(error,capacity,"AOT region allocation failed.");return NULL;}r->mapped_size=mapped;
#if defined(__APPLE__) && defined(__arm64__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
 int mode=iSteamJITGetProtocolMode();
 if(mode==ISTEAM_JIT_PROTOCOL_STIKDEBUG){
  if(!ensure_txm_arena(error,capacity)){free(r);return NULL;}
  long hostPageValue=sysconf(_SC_PAGESIZE);
  size_t hostPage=hostPageValue>0?(size_t)hostPageValue:4096u;
  size_t offset=0;
  if(!iSteamAOTExecutableArenaAllocate(sTXMArena,mapped,hostPage,&offset)){free(r);set_error(error,capacity,"StikDebug AOT executable arena exhausted.");return NULL;}
  r->execute_address=(void *)((uintptr_t)sTXMExecuteBase+offset);
  r->write_address=(void *)((uintptr_t)sTXMWriteBase+offset);
  r->split_mapping=true;r->mach_mapping=true;r->arena_owned=true;r->arena_offset=offset;
 }else if(mode==ISTEAM_JIT_PROTOCOL_STANDARD){
  void *write=mmap(NULL,mapped,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
  if(write==MAP_FAILED){free(r);set_error(error,capacity,"AOT standard JIT writable mapping failed.");return NULL;}
  vm_address_t execute=0;vm_prot_t current=0;vm_prot_t maximum=0;
  kern_return_t status=vm_remap(mach_task_self(),&execute,(vm_size_t)mapped,0,VM_FLAGS_ANYWHERE,mach_task_self(),(vm_address_t)write,FALSE,&current,&maximum,VM_INHERIT_NONE);
  if(status!=KERN_SUCCESS){
   if(execute)(void)munmap((void *)execute,mapped);
   (void)munmap(write,mapped);free(r);
   set_error(error,capacity,"AOT standard JIT executable alias remap failed.");return NULL;
  }
  if(mprotect((void *)execute,mapped,PROT_READ|PROT_EXEC)!=0){
   (void)munmap((void *)execute,mapped);(void)munmap(write,mapped);free(r);
   set_error(error,capacity,"AOT standard JIT executable alias could not be sealed RX.");return NULL;
  }
  r->execute_address=(void *)execute;r->write_address=write;r->split_mapping=true;r->mach_mapping=false;
 }else{
  free(r);set_error(error,capacity,"AOT JIT protocol became unavailable during allocation.");return NULL;
 }
#endif
 if(!r->split_mapping){void *p=mmap(NULL,mapped,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);if(p==MAP_FAILED){free(r);set_error(error,capacity,"AOT writable mapping failed.");return NULL;}r->execute_address=p;r->write_address=p;}
 memcpy(r->write_address,code,length);
#if defined(__APPLE__)
 sys_icache_invalidate(r->execute_address,length);
#else
 __builtin___clear_cache((char *)r->execute_address,(char *)r->execute_address+length);
#endif
 if(!r->split_mapping&&mprotect(r->execute_address,mapped,PROT_READ|PROT_EXEC)!=0){(void)munmap(r->write_address,mapped);free(r);set_error(error,capacity,"AOT mapping could not be sealed RX.");return NULL;}
 r->finalized=true;set_error(error,capacity,"");return r;
}
size_t iSteamAOTExecutableMemoryMappedSize(const iSteamAOTExecutableRegion *r){return r?r->mapped_size:0;}
bool iSteamAOTExecutableMemoryInvoke(iSteamAOTExecutableRegion *r,KenranButoAOTGuestState *s){
 typedef void(*Entry)(KenranButoAOTGuestState *);if(!r||!r->finalized||!r->execute_address||!iSteamAOTExecutableMemoryIsAvailable()||!iSteamAOTGuestStateIsValid(s))return false;
 s->instructions_executed=0;s->exit_reason=KENRAN_BUTO_AOT_EXIT_NONE;s->exit_address=0;s->exit_rip=s->rip;Entry entry=(Entry)r->execute_address;entry(s);return true;
}
void iSteamAOTExecutableMemoryDestroy(iSteamAOTExecutableRegion *r){
 if(!r)return;
#if defined(__APPLE__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
 if(r->arena_owned){
  if(sTXMArena)(void)iSteamAOTExecutableArenaFree(sTXMArena,r->arena_offset,r->mapped_size);
  free(r);
  return;
 }
 if(r->split_mapping&&r->mach_mapping){if(r->write_address)(void)vm_deallocate(mach_task_self(),(vm_address_t)r->write_address,(vm_size_t)r->mapped_size);if(r->execute_address)(void)vm_deallocate(mach_task_self(),(vm_address_t)r->execute_address,(vm_size_t)r->mapped_size);}
 else if(r->split_mapping){if(r->write_address)(void)munmap(r->write_address,r->mapped_size);if(r->execute_address)(void)munmap(r->execute_address,r->mapped_size);}
 else if(r->execute_address)(void)munmap(r->execute_address,r->mapped_size);
#else
 if(r->execute_address)(void)munmap(r->execute_address,r->mapped_size);
#endif
 free(r);
}
