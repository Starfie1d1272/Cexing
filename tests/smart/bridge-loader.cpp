#include "bridge.h"
#include <cassert>
#include <cstring>
#include <cstdlib>
#include <iostream>
#include <pthread.h>
static const char *missing;
static int opens = 0, closes = 0, calls = 0;
static pthread_t caller;
static char *init(const char *) { assert(!pthread_equal(caller, pthread_self())); ++calls; return nullptr; }
static char *start(int, const char *, const char *) { return nullptr; }
static void stop() {}
static void freeResult(char *) {}
extern "C" void *__wrap_dlopen(const char *, int) { ++opens; return reinterpret_cast<void *>(1); }
extern "C" int __wrap_dlclose(void *) { ++closes; return 0; }
extern "C" void *__wrap_dlsym(void *, const char *name) {
 if (std::strcmp(name, missing) == 0) return nullptr;
 if (std::strcmp(name,"mihomoInit")==0) return reinterpret_cast<void *>(init);
 if (std::strcmp(name,"mihomoStartTun")==0) return reinterpret_cast<void *>(start);
 if (std::strcmp(name,"mihomoStop")==0) return reinterpret_cast<void *>(stop);
 return reinterpret_cast<void *>(freeResult);
}
int main(int argc,char **argv) {
 assert(argc==2); missing=argv[1]; caller=pthread_self();
 bool complete=std::strcmp(missing,"complete")==0;
 for(int i=0;i<2;i++) {
  std::string err=bridge::Init("host-test");
  assert(err.empty()==complete);
  assert(bridge::GetStatus().loaded==complete);
 }
 assert(opens==1 && closes==0 && calls==(complete?2:0));
 std::cout << "PASS loader " << missing << ": dlopen=1 dlclose=0 workerCalls=" << calls << std::endl;
 // The production worker lives for the process; avoid static CV destruction in this child.
 std::_Exit(0);
}
