#pragma once

#import <Foundation/Foundation.h>
#include <stdbool.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

bool CheckIfSigned(NSString *filePath);
bool InjectDyLib(NSString *filePath, NSString *dylibPath, bool weakInject);
bool UninstallDylibs(NSString *filePath, NSArray<NSString *> *dylibPathsArray);
NSArray<NSString *> *ListDylibs(NSString *filePath);
bool ChangeDylibPath(NSString *filePath, NSString *oldPath, NSString *newPath);

int zsign(
    NSString *app,
    NSString *prov,
    NSString *key,
    NSString *pass,
    NSString *entitlement,
    NSString *bundleid,
    NSString *displayname,
    NSString *bundleversion,
    bool adhoc,
    bool dontGenerateEmbeddedMobileProvision,
    void (^ _Nullable completionHandler)(BOOL success)
);

int checkCert(
    NSString *prov,
    NSString *key,
    NSString *pass,
    void (^completionHandler)(int status, NSDate * _Nullable expirationDate, NSString * _Nullable error)
);

bool p12_password_check(NSString *file, NSString *pass);
void password_check_fix(NSString *path);
void password_check_fix_free(NSString *path);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
