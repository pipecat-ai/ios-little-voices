#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface PCPythonRuntime : NSObject
- (void)startWithEventHandler:(void (^)(NSString *json))handler;
- (void)sendJSON:(NSString *)json;
#if DEBUG
/// The names of the Python modules imported so far, sorted; empty before the interpreter starts.
- (NSArray<NSString *> *)importedModuleNames;
#endif
@end
NS_ASSUME_NONNULL_END
