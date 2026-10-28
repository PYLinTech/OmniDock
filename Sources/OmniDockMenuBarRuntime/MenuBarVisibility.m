#import "include/OmniDockMenuBarRuntime.h"
#import <dlfcn.h>

@interface NSObject (ODMenuBarRuntime)
- (id)initWithAllowedSystemItems:(NSArray<NSNumber *> *)items allowedBundleIdentifiers:(NSArray<NSString *> *)bundles;
- (void)activateWithConfiguration:(id)configuration completionHandler:(void (^)(NSError *))completion;
- (void)invalidate;
@end

id ODMenuBarBeginVisibility(NSArray<NSString *> *visibleApplications, void (^completion)(id, BOOL)) {
    // Resolve only when used: older systems and changed runtime contracts remain expanded.
    static void *runtime;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        runtime = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_LOCAL | RTLD_LAZY);
    });
    Class configurationType = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class sessionType = NSClassFromString(@"MBAssessmentModeAssertion");
    if (!runtime || ![configurationType instancesRespondToSelector:@selector(initWithAllowedSystemItems:allowedBundleIdentifiers:)] ||
        ![sessionType instancesRespondToSelector:@selector(activateWithConfiguration:completionHandler:)] ||
        ![sessionType instancesRespondToSelector:@selector(invalidate)]) {
        completion(nil, NO);
        return nil;
    }

    @try {
        NSMutableArray<NSNumber *> *systemItems = [NSMutableArray array];
        for (NSInteger item = 0; item < 64; item++) {
            [systemItems addObject:@(item)];
        }
        id configuration = [[configurationType alloc] initWithAllowedSystemItems:systemItems allowedBundleIdentifiers:visibleApplications];
        id session = [[sessionType alloc] init];
        if (!configuration || !session) {
            completion(nil, NO);
            return nil;
        }
        [session activateWithConfiguration:configuration completionHandler:^(NSError *error) {
            completion(session, error == nil);
        }];
        return session;
    } @catch (NSException *exception) {
        NSLog(@"Menu bar visibility could not start: %@", exception.name);
        completion(nil, NO);
        return nil;
    }
}

void ODMenuBarEndVisibility(id session) {
    @try {
        if ([session respondsToSelector:@selector(invalidate)]) {
            [session invalidate];
        }
    } @catch (NSException *exception) {
        NSLog(@"Menu bar visibility could not end: %@", exception.name);
    }
}
