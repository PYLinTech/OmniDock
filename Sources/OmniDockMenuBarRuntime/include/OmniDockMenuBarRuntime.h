#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT id _Nullable ODMenuBarBeginVisibility(
    NSArray<NSString *> *visibleApplications,
    void (^completion)(id _Nullable activatedSession, BOOL succeeded)
);
FOUNDATION_EXPORT void ODMenuBarEndVisibility(id _Nullable session);

NS_ASSUME_NONNULL_END
