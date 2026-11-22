#include "JIT26Protocol.h"
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
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
struct iSteamAOTExecutableRegion { void *execute_address; void *write_address; size_t mapped_size; bool split_mapping; bool finalized; };
_Static_assert(offsetof(KenranButoAOTGuestState,gpr)==8,"AOT ABI v1 gpr offset changed");
_Static_assert(sizeof(KenranButoAOTGuestState)==96,"AOT ABI v1 state size changed");
_Static_assert(sizeof(KenranButoAOTMemoryCallbacks)==32,"AOT ABI v1 callback size changed");
static void set_error(char *b,size_t n,const char *m){if(b&&n)(void)snprintf(b,n,"%s",m);}
static size_t mapped_size_for(size_t n){long p=sysconf(_SC_PAGESIZE);size_t page=p>0?(size_t)p:4096u;size_t r=n%page;if(!n)return 0;if(!r)return n;if(n>SIZE_MAX-(page-r))return 0;return n+page-r;}
#if defined(__APPLE__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
static void deallocate_mach_address(vm_address_t a,size_t n){if(a&&n)(void)vm_deallocate(mach_task_self(),a,(vm_size_t)n);}
#endif
bool iSteamAOTExecutableMemoryIsAvailable(void){
#if defined(__APPLE__) && defined(__arm64__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
 if(!iSteamJITIsReady())return false;int mode=iSteamJITGetProtocolMode();return mode==0||mode==1;
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
 if(iSteamJITGetProtocolMode()==1){
  void *exec=iSteamJITPrepareRegion(NULL,mapped);vm_address_t write=0;vm_prot_t current=VM_PROT_READ;vm_prot_t maximum=VM_PROT_READ|VM_PROT_WRITE;
  if(!exec){free(r);set_error(error,capacity,"StikDebug executable region unavailable.");return NULL;}
  kern_return_t status=vm_remap(mach_task_self(),&write,(vm_size_t)mapped,0,VM_FLAGS_ANYWHERE,mach_task_self(),(vm_address_t)exec,FALSE,&current,&maximum,VM_INHERIT_NONE);
  if(status!=KERN_SUCCESS||(maximum&VM_PROT_WRITE)==0){
   /* A failed max-protection check can still leave a mapped writable alias. */
   deallocate_mach_address(write,mapped);deallocate_mach_address((vm_address_t)exec,mapped);free(r);
   set_error(error,capacity,"StikDebug writable alias remap/protection failed.");return NULL;
  }
  status=vm_protect(mach_task_self(),write,(vm_size_t)mapped,FALSE,VM_PROT_READ|VM_PROT_WRITE);
  if(status!=KERN_SUCCESS){deallocate_mach_address(write,mapped);deallocate_mach_address((vm_address_t)exec,mapped);free(r);set_error(error,capacity,"StikDebug writable alias could not be protected.");return NULL;}
  r->execute_address=exec;r->write_address=(void *)write;r->split_mapping=true;
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
bool iSteamAOTExecutableMemoryInvoke(iSteamAOTExecutableRegion *r,KenranButoAOTGuestState *s){
 typedef void(*Entry)(KenranButoAOTGuestState *);if(!r||!r->finalized||!r->execute_address||!iSteamAOTGuestStateIsValid(s))return false;
 s->instructions_executed=0;s->exit_reason=KENRAN_BUTO_AOT_EXIT_NONE;s->exit_address=0;s->exit_rip=s->rip;Entry entry=(Entry)r->execute_address;entry(s);return true;
}
void iSteamAOTExecutableMemoryDestroy(iSteamAOTExecutableRegion *r){
 if(!r)return;
#if defined(__APPLE__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
 if(r->split_mapping){if(r->write_address)(void)vm_deallocate(mach_task_self(),(vm_address_t)r->write_address,(vm_size_t)r->mapped_size);if(r->execute_address)(void)vm_deallocate(mach_task_self(),(vm_address_t)r->execute_address,(vm_size_t)r->mapped_size);}
 else if(r->execute_address)(void)munmap(r->execute_address,r->mapped_size);
#else
 if(r->execute_address)(void)munmap(r->execute_address,r->mapped_size);
#endif
 free(r);
}
