#include <stdint.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import "include/ovoz_objc_api.h"

#if !__has_feature(objc_arc)
#error "This file must be compiled with ARC enabled"
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"

typedef struct {
  int64_t version;
  void* (*newWaiter)(void);
  void (*awaitWaiter)(void*);
  void* (*currentIsolate)(void);
  void (*enterIsolate)(void*);
  void (*exitIsolate)(void);
  int64_t (*getMainPortId)(void);
  bool (*getCurrentThreadOwnsIsolate)(int64_t);
  void (*invokeListenerPortBlock)(int64_t port, void*);
  void (*invokeBlockingPortBlock)(int64_t port, void*, void*);
} DOBJC_Context;

id objc_retainBlock(id);

#define BLOCKING_BLOCK_IMPL(ctx, TYPE, SIG, INVOKE_DIRECT, INVOKE_LISTENER)    \
  assert(ctx->version >= 1);                                                   \
  void* targetIsolate = ctx->currentIsolate();                                 \
  int64_t targetPort = ctx->getMainPortId == NULL ? 0 : ctx->getMainPortId();  \
  __block __weak TYPE weakSelfBlock = nil;                                     \
  TYPE strongSelfBlock = [SIG {                                                \
    void* currentIsolate = ctx->currentIsolate();                              \
    bool mayEnterIsolate =                                                     \
        currentIsolate == NULL &&                                              \
        ctx->getCurrentThreadOwnsIsolate != NULL &&                            \
        ctx->getCurrentThreadOwnsIsolate(targetPort);                          \
    if (currentIsolate == targetIsolate || mayEnterIsolate) {                  \
      if (mayEnterIsolate) {                                                   \
        ctx->enterIsolate(targetIsolate);                                      \
      }                                                                        \
      INVOKE_DIRECT;                                                           \
      if (mayEnterIsolate) {                                                   \
        ctx->exitIsolate();                                                    \
      }                                                                        \
    } else {                                                                   \
      void* waiter = ctx->newWaiter();                                         \
      TYPE selfRetain = [weakSelfBlock copy];                                  \
      INVOKE_LISTENER;                                                         \
      ctx->awaitWaiter(waiter);                                                \
      (void)selfRetain;                                                        \
    }                                                                          \
  } copy];                                                                     \
  weakSelfBlock = strongSelfBlock;                                             \
  return strongSelfBlock;


__attribute__((visibility("default")))
@interface _zs4y1d_BlockArgs_ovsamd : NSObject
@property (copy) id block;
@property void * arg0;
@end
@implementation _zs4y1d_BlockArgs_ovsamd
@end

typedef void  (^_ListenerTrampoline)(void * arg0);
__attribute__((visibility("default"))) __attribute__((used))
_ListenerTrampoline _zs4y1d_wrapListenerBlock_ovsamd(
    int64_t port, DOBJC_Context* ctx) NS_RETURNS_RETAINED {
  __block __weak _ListenerTrampoline weakSelfBlock = nil;
  _ListenerTrampoline strongSelfBlock = [^void(void * arg0) {
    @autoreleasepool {
      _zs4y1d_BlockArgs_ovsamd* args = [[_zs4y1d_BlockArgs_ovsamd alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      ctx->invokeListenerPortBlock(port, (__bridge_retained void*)args);
    }
  } copy];
  weakSelfBlock = strongSelfBlock;
  return strongSelfBlock;
}

typedef void  (^_BlockingTrampoline)(void * waiter, void * arg0);
__attribute__((visibility("default"))) __attribute__((used))
_ListenerTrampoline _zs4y1d_wrapBlockingBlock_ovsamd(int64_t port, DOBJC_Context* ctx,
    void (*directInvoke)(void*)) NS_RETURNS_RETAINED {
  BLOCKING_BLOCK_IMPL(ctx, _ListenerTrampoline, ^void(void * arg0), {
    @autoreleasepool {
      _zs4y1d_BlockArgs_ovsamd* args = [[_zs4y1d_BlockArgs_ovsamd alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      directInvoke((__bridge_retained void*)args);
    }
  }, {
    @autoreleasepool {
      _zs4y1d_BlockArgs_ovsamd* args = [[_zs4y1d_BlockArgs_ovsamd alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      ctx->invokeBlockingPortBlock(port, (__bridge_retained void*)args, waiter);
    }
  });
}

typedef void  (^_ProtocolTrampoline)(void * sel);
__attribute__((visibility("default"))) __attribute__((used))
void  _zs4y1d_protocolTrampoline_ovsamd(id target, void * sel) {
  return ((_ProtocolTrampoline)((id (*)(id, SEL, SEL))objc_msgSend)(target, @selector(getDOBJCDartProtocolMethodForSelector:), sel))(sel);
}

__attribute__((visibility("default")))
@interface _zs4y1d_BlockArgs_19fwfl3 : NSObject
@property (copy) id block;
@property void * arg0;
@property int64_t arg1;
@end
@implementation _zs4y1d_BlockArgs_19fwfl3
@end

typedef void  (^_ListenerTrampoline_1)(void * arg0, int64_t arg1);
__attribute__((visibility("default"))) __attribute__((used))
_ListenerTrampoline_1 _zs4y1d_wrapListenerBlock_19fwfl3(
    int64_t port, DOBJC_Context* ctx) NS_RETURNS_RETAINED {
  __block __weak _ListenerTrampoline_1 weakSelfBlock = nil;
  _ListenerTrampoline_1 strongSelfBlock = [^void(void * arg0, int64_t arg1) {
    @autoreleasepool {
      _zs4y1d_BlockArgs_19fwfl3* args = [[_zs4y1d_BlockArgs_19fwfl3 alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      ctx->invokeListenerPortBlock(port, (__bridge_retained void*)args);
    }
  } copy];
  weakSelfBlock = strongSelfBlock;
  return strongSelfBlock;
}

typedef void  (^_BlockingTrampoline_1)(void * waiter, void * arg0, int64_t arg1);
__attribute__((visibility("default"))) __attribute__((used))
_ListenerTrampoline_1 _zs4y1d_wrapBlockingBlock_19fwfl3(int64_t port, DOBJC_Context* ctx,
    void (*directInvoke)(void*)) NS_RETURNS_RETAINED {
  BLOCKING_BLOCK_IMPL(ctx, _ListenerTrampoline_1, ^void(void * arg0, int64_t arg1), {
    @autoreleasepool {
      _zs4y1d_BlockArgs_19fwfl3* args = [[_zs4y1d_BlockArgs_19fwfl3 alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      directInvoke((__bridge_retained void*)args);
    }
  }, {
    @autoreleasepool {
      _zs4y1d_BlockArgs_19fwfl3* args = [[_zs4y1d_BlockArgs_19fwfl3 alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      ctx->invokeBlockingPortBlock(port, (__bridge_retained void*)args, waiter);
    }
  });
}

typedef void  (^_ProtocolTrampoline_1)(void * sel, int64_t arg1);
__attribute__((visibility("default"))) __attribute__((used))
void  _zs4y1d_protocolTrampoline_19fwfl3(id target, void * sel, int64_t arg1) {
  return ((_ProtocolTrampoline_1)((id (*)(id, SEL, SEL))objc_msgSend)(target, @selector(getDOBJCDartProtocolMethodForSelector:), sel))(sel, arg1);
}

__attribute__((visibility("default")))
@interface _zs4y1d_BlockArgs_qoqpex : NSObject
@property (copy) id block;
@property void * arg0;
@property int64_t arg1;
@property int64_t arg2;
@end
@implementation _zs4y1d_BlockArgs_qoqpex
@end

typedef void  (^_ListenerTrampoline_2)(void * arg0, int64_t arg1, int64_t arg2);
__attribute__((visibility("default"))) __attribute__((used))
_ListenerTrampoline_2 _zs4y1d_wrapListenerBlock_qoqpex(
    int64_t port, DOBJC_Context* ctx) NS_RETURNS_RETAINED {
  __block __weak _ListenerTrampoline_2 weakSelfBlock = nil;
  _ListenerTrampoline_2 strongSelfBlock = [^void(void * arg0, int64_t arg1, int64_t arg2) {
    @autoreleasepool {
      _zs4y1d_BlockArgs_qoqpex* args = [[_zs4y1d_BlockArgs_qoqpex alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      args.arg2 = arg2;
      ctx->invokeListenerPortBlock(port, (__bridge_retained void*)args);
    }
  } copy];
  weakSelfBlock = strongSelfBlock;
  return strongSelfBlock;
}

typedef void  (^_BlockingTrampoline_2)(void * waiter, void * arg0, int64_t arg1, int64_t arg2);
__attribute__((visibility("default"))) __attribute__((used))
_ListenerTrampoline_2 _zs4y1d_wrapBlockingBlock_qoqpex(int64_t port, DOBJC_Context* ctx,
    void (*directInvoke)(void*)) NS_RETURNS_RETAINED {
  BLOCKING_BLOCK_IMPL(ctx, _ListenerTrampoline_2, ^void(void * arg0, int64_t arg1, int64_t arg2), {
    @autoreleasepool {
      _zs4y1d_BlockArgs_qoqpex* args = [[_zs4y1d_BlockArgs_qoqpex alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      args.arg2 = arg2;
      directInvoke((__bridge_retained void*)args);
    }
  }, {
    @autoreleasepool {
      _zs4y1d_BlockArgs_qoqpex* args = [[_zs4y1d_BlockArgs_qoqpex alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      args.arg2 = arg2;
      ctx->invokeBlockingPortBlock(port, (__bridge_retained void*)args, waiter);
    }
  });
}

typedef void  (^_ProtocolTrampoline_2)(void * sel, int64_t arg1, int64_t arg2);
__attribute__((visibility("default"))) __attribute__((used))
void  _zs4y1d_protocolTrampoline_qoqpex(id target, void * sel, int64_t arg1, int64_t arg2) {
  return ((_ProtocolTrampoline_2)((id (*)(id, SEL, SEL))objc_msgSend)(target, @selector(getDOBJCDartProtocolMethodForSelector:), sel))(sel, arg1, arg2);
}

__attribute__((visibility("default")))
@interface _zs4y1d_BlockArgs_vx8uur : NSObject
@property (copy) id block;
@property void * arg0;
@property int64_t arg1;
@property long arg2;
@property (strong) id arg3;
@end
@implementation _zs4y1d_BlockArgs_vx8uur
@end

typedef void  (^_ListenerTrampoline_3)(void * arg0, int64_t arg1, long arg2, id arg3);
__attribute__((visibility("default"))) __attribute__((used))
_ListenerTrampoline_3 _zs4y1d_wrapListenerBlock_vx8uur(
    int64_t port, DOBJC_Context* ctx) NS_RETURNS_RETAINED {
  __block __weak _ListenerTrampoline_3 weakSelfBlock = nil;
  _ListenerTrampoline_3 strongSelfBlock = [^void(void * arg0, int64_t arg1, long arg2, id arg3) {
    @autoreleasepool {
      _zs4y1d_BlockArgs_vx8uur* args = [[_zs4y1d_BlockArgs_vx8uur alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      args.arg2 = arg2;
      args.arg3 = arg3;
      ctx->invokeListenerPortBlock(port, (__bridge_retained void*)args);
    }
  } copy];
  weakSelfBlock = strongSelfBlock;
  return strongSelfBlock;
}

typedef void  (^_BlockingTrampoline_3)(void * waiter, void * arg0, int64_t arg1, long arg2, id arg3);
__attribute__((visibility("default"))) __attribute__((used))
_ListenerTrampoline_3 _zs4y1d_wrapBlockingBlock_vx8uur(int64_t port, DOBJC_Context* ctx,
    void (*directInvoke)(void*)) NS_RETURNS_RETAINED {
  BLOCKING_BLOCK_IMPL(ctx, _ListenerTrampoline_3, ^void(void * arg0, int64_t arg1, long arg2, id arg3), {
    @autoreleasepool {
      _zs4y1d_BlockArgs_vx8uur* args = [[_zs4y1d_BlockArgs_vx8uur alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      args.arg2 = arg2;
      args.arg3 = arg3;
      directInvoke((__bridge_retained void*)args);
    }
  }, {
    @autoreleasepool {
      _zs4y1d_BlockArgs_vx8uur* args = [[_zs4y1d_BlockArgs_vx8uur alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      args.arg2 = arg2;
      args.arg3 = arg3;
      ctx->invokeBlockingPortBlock(port, (__bridge_retained void*)args, waiter);
    }
  });
}

typedef void  (^_ProtocolTrampoline_3)(void * sel, int64_t arg1, long arg2, id arg3);
__attribute__((visibility("default"))) __attribute__((used))
void  _zs4y1d_protocolTrampoline_vx8uur(id target, void * sel, int64_t arg1, long arg2, id arg3) {
  return ((_ProtocolTrampoline_3)((id (*)(id, SEL, SEL))objc_msgSend)(target, @selector(getDOBJCDartProtocolMethodForSelector:), sel))(sel, arg1, arg2, arg3);
}

__attribute__((visibility("default")))
@interface _zs4y1d_BlockArgs_unr2j3 : NSObject
@property (copy) id block;
@property void * arg0;
@property long arg1;
@end
@implementation _zs4y1d_BlockArgs_unr2j3
@end

typedef void  (^_ListenerTrampoline_4)(void * arg0, long arg1);
__attribute__((visibility("default"))) __attribute__((used))
_ListenerTrampoline_4 _zs4y1d_wrapListenerBlock_unr2j3(
    int64_t port, DOBJC_Context* ctx) NS_RETURNS_RETAINED {
  __block __weak _ListenerTrampoline_4 weakSelfBlock = nil;
  _ListenerTrampoline_4 strongSelfBlock = [^void(void * arg0, long arg1) {
    @autoreleasepool {
      _zs4y1d_BlockArgs_unr2j3* args = [[_zs4y1d_BlockArgs_unr2j3 alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      ctx->invokeListenerPortBlock(port, (__bridge_retained void*)args);
    }
  } copy];
  weakSelfBlock = strongSelfBlock;
  return strongSelfBlock;
}

typedef void  (^_BlockingTrampoline_4)(void * waiter, void * arg0, long arg1);
__attribute__((visibility("default"))) __attribute__((used))
_ListenerTrampoline_4 _zs4y1d_wrapBlockingBlock_unr2j3(int64_t port, DOBJC_Context* ctx,
    void (*directInvoke)(void*)) NS_RETURNS_RETAINED {
  BLOCKING_BLOCK_IMPL(ctx, _ListenerTrampoline_4, ^void(void * arg0, long arg1), {
    @autoreleasepool {
      _zs4y1d_BlockArgs_unr2j3* args = [[_zs4y1d_BlockArgs_unr2j3 alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      directInvoke((__bridge_retained void*)args);
    }
  }, {
    @autoreleasepool {
      _zs4y1d_BlockArgs_unr2j3* args = [[_zs4y1d_BlockArgs_unr2j3 alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      ctx->invokeBlockingPortBlock(port, (__bridge_retained void*)args, waiter);
    }
  });
}

typedef void  (^_ProtocolTrampoline_4)(void * sel, long arg1);
__attribute__((visibility("default"))) __attribute__((used))
void  _zs4y1d_protocolTrampoline_unr2j3(id target, void * sel, long arg1) {
  return ((_ProtocolTrampoline_4)((id (*)(id, SEL, SEL))objc_msgSend)(target, @selector(getDOBJCDartProtocolMethodForSelector:), sel))(sel, arg1);
}

__attribute__((visibility("default")))
@interface _zs4y1d_BlockArgs_1vl8g4r : NSObject
@property (copy) id block;
@property void * arg0;
@property long arg1;
@property BOOL arg2;
@end
@implementation _zs4y1d_BlockArgs_1vl8g4r
@end

typedef void  (^_ListenerTrampoline_5)(void * arg0, long arg1, BOOL arg2);
__attribute__((visibility("default"))) __attribute__((used))
_ListenerTrampoline_5 _zs4y1d_wrapListenerBlock_1vl8g4r(
    int64_t port, DOBJC_Context* ctx) NS_RETURNS_RETAINED {
  __block __weak _ListenerTrampoline_5 weakSelfBlock = nil;
  _ListenerTrampoline_5 strongSelfBlock = [^void(void * arg0, long arg1, BOOL arg2) {
    @autoreleasepool {
      _zs4y1d_BlockArgs_1vl8g4r* args = [[_zs4y1d_BlockArgs_1vl8g4r alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      args.arg2 = arg2;
      ctx->invokeListenerPortBlock(port, (__bridge_retained void*)args);
    }
  } copy];
  weakSelfBlock = strongSelfBlock;
  return strongSelfBlock;
}

typedef void  (^_BlockingTrampoline_5)(void * waiter, void * arg0, long arg1, BOOL arg2);
__attribute__((visibility("default"))) __attribute__((used))
_ListenerTrampoline_5 _zs4y1d_wrapBlockingBlock_1vl8g4r(int64_t port, DOBJC_Context* ctx,
    void (*directInvoke)(void*)) NS_RETURNS_RETAINED {
  BLOCKING_BLOCK_IMPL(ctx, _ListenerTrampoline_5, ^void(void * arg0, long arg1, BOOL arg2), {
    @autoreleasepool {
      _zs4y1d_BlockArgs_1vl8g4r* args = [[_zs4y1d_BlockArgs_1vl8g4r alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      args.arg2 = arg2;
      directInvoke((__bridge_retained void*)args);
    }
  }, {
    @autoreleasepool {
      _zs4y1d_BlockArgs_1vl8g4r* args = [[_zs4y1d_BlockArgs_1vl8g4r alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      args.arg2 = arg2;
      ctx->invokeBlockingPortBlock(port, (__bridge_retained void*)args, waiter);
    }
  });
}

typedef void  (^_ProtocolTrampoline_5)(void * sel, long arg1, BOOL arg2);
__attribute__((visibility("default"))) __attribute__((used))
void  _zs4y1d_protocolTrampoline_1vl8g4r(id target, void * sel, long arg1, BOOL arg2) {
  return ((_ProtocolTrampoline_5)((id (*)(id, SEL, SEL))objc_msgSend)(target, @selector(getDOBJCDartProtocolMethodForSelector:), sel))(sel, arg1, arg2);
}

__attribute__((visibility("default")))
@interface _zs4y1d_BlockArgs_107vku4 : NSObject
@property (copy) id block;
@property void * arg0;
@property long arg1;
@property double arg2;
@end
@implementation _zs4y1d_BlockArgs_107vku4
@end

typedef void  (^_ListenerTrampoline_6)(void * arg0, long arg1, double arg2);
__attribute__((visibility("default"))) __attribute__((used))
_ListenerTrampoline_6 _zs4y1d_wrapListenerBlock_107vku4(
    int64_t port, DOBJC_Context* ctx) NS_RETURNS_RETAINED {
  __block __weak _ListenerTrampoline_6 weakSelfBlock = nil;
  _ListenerTrampoline_6 strongSelfBlock = [^void(void * arg0, long arg1, double arg2) {
    @autoreleasepool {
      _zs4y1d_BlockArgs_107vku4* args = [[_zs4y1d_BlockArgs_107vku4 alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      args.arg2 = arg2;
      ctx->invokeListenerPortBlock(port, (__bridge_retained void*)args);
    }
  } copy];
  weakSelfBlock = strongSelfBlock;
  return strongSelfBlock;
}

typedef void  (^_BlockingTrampoline_6)(void * waiter, void * arg0, long arg1, double arg2);
__attribute__((visibility("default"))) __attribute__((used))
_ListenerTrampoline_6 _zs4y1d_wrapBlockingBlock_107vku4(int64_t port, DOBJC_Context* ctx,
    void (*directInvoke)(void*)) NS_RETURNS_RETAINED {
  BLOCKING_BLOCK_IMPL(ctx, _ListenerTrampoline_6, ^void(void * arg0, long arg1, double arg2), {
    @autoreleasepool {
      _zs4y1d_BlockArgs_107vku4* args = [[_zs4y1d_BlockArgs_107vku4 alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      args.arg2 = arg2;
      directInvoke((__bridge_retained void*)args);
    }
  }, {
    @autoreleasepool {
      _zs4y1d_BlockArgs_107vku4* args = [[_zs4y1d_BlockArgs_107vku4 alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      args.arg2 = arg2;
      ctx->invokeBlockingPortBlock(port, (__bridge_retained void*)args, waiter);
    }
  });
}

typedef void  (^_ProtocolTrampoline_6)(void * sel, long arg1, double arg2);
__attribute__((visibility("default"))) __attribute__((used))
void  _zs4y1d_protocolTrampoline_107vku4(id target, void * sel, long arg1, double arg2) {
  return ((_ProtocolTrampoline_6)((id (*)(id, SEL, SEL))objc_msgSend)(target, @selector(getDOBJCDartProtocolMethodForSelector:), sel))(sel, arg1, arg2);
}

__attribute__((visibility("default")))
@interface _zs4y1d_BlockArgs_5si851 : NSObject
@property (copy) id block;
@property void * arg0;
@property BOOL arg1;
@property BOOL arg2;
@end
@implementation _zs4y1d_BlockArgs_5si851
@end

typedef void  (^_ListenerTrampoline_7)(void * arg0, BOOL arg1, BOOL arg2);
__attribute__((visibility("default"))) __attribute__((used))
_ListenerTrampoline_7 _zs4y1d_wrapListenerBlock_5si851(
    int64_t port, DOBJC_Context* ctx) NS_RETURNS_RETAINED {
  __block __weak _ListenerTrampoline_7 weakSelfBlock = nil;
  _ListenerTrampoline_7 strongSelfBlock = [^void(void * arg0, BOOL arg1, BOOL arg2) {
    @autoreleasepool {
      _zs4y1d_BlockArgs_5si851* args = [[_zs4y1d_BlockArgs_5si851 alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      args.arg2 = arg2;
      ctx->invokeListenerPortBlock(port, (__bridge_retained void*)args);
    }
  } copy];
  weakSelfBlock = strongSelfBlock;
  return strongSelfBlock;
}

typedef void  (^_BlockingTrampoline_7)(void * waiter, void * arg0, BOOL arg1, BOOL arg2);
__attribute__((visibility("default"))) __attribute__((used))
_ListenerTrampoline_7 _zs4y1d_wrapBlockingBlock_5si851(int64_t port, DOBJC_Context* ctx,
    void (*directInvoke)(void*)) NS_RETURNS_RETAINED {
  BLOCKING_BLOCK_IMPL(ctx, _ListenerTrampoline_7, ^void(void * arg0, BOOL arg1, BOOL arg2), {
    @autoreleasepool {
      _zs4y1d_BlockArgs_5si851* args = [[_zs4y1d_BlockArgs_5si851 alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      args.arg2 = arg2;
      directInvoke((__bridge_retained void*)args);
    }
  }, {
    @autoreleasepool {
      _zs4y1d_BlockArgs_5si851* args = [[_zs4y1d_BlockArgs_5si851 alloc] init];
      args.block = weakSelfBlock;
      args.arg0 = arg0;
      args.arg1 = arg1;
      args.arg2 = arg2;
      ctx->invokeBlockingPortBlock(port, (__bridge_retained void*)args, waiter);
    }
  });
}

typedef void  (^_ProtocolTrampoline_7)(void * sel, BOOL arg1, BOOL arg2);
__attribute__((visibility("default"))) __attribute__((used))
void  _zs4y1d_protocolTrampoline_5si851(id target, void * sel, BOOL arg1, BOOL arg2) {
  return ((_ProtocolTrampoline_7)((id (*)(id, SEL, SEL))objc_msgSend)(target, @selector(getDOBJCDartProtocolMethodForSelector:), sel))(sel, arg1, arg2);
}

__attribute__((visibility("default"))) __attribute__((used))
Protocol* _zs4y1d_OvozPlayerListener(void) { return @protocol(OvozPlayerListener); }

__attribute__((visibility("default"))) __attribute__((used))
Protocol* _zs4y1d_OvozSessionListener(void) { return @protocol(OvozSessionListener); }
#undef BLOCKING_BLOCK_IMPL

#pragma clang diagnostic pop
