#import "ZsignBridge.h"

#include "common.h"
#include "openssl.h"
#include "macho.h"
#include "bundle.h"
#include "timer.h"

#include <openssl/asn1.h>
#include <openssl/bio.h>
#include <openssl/cms.h>
#include <openssl/err.h>
#include <openssl/ocsp.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <openssl/provider.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include <set>
#include <string>
#include <vector>

using namespace std;

namespace {

static string ToString(NSString *value)
{
    if (value == nil) {
        return string();
    }
    const char *utf8 = [value UTF8String];
    return utf8 ? string(utf8) : string();
}

static void EnsureOpenSSLProviders()
{
    // OpenSSL 3 needs the legacy provider for a number of older PKCS#12 files.
    // Provider handles intentionally live for the process lifetime.
    OSSL_PROVIDER_load(NULL, "default");
    OSSL_PROVIDER_load(NULL, "legacy");
}

static NSDate * _Nullable DateFromASN1Time(const ASN1_TIME *time)
{
    if (time == NULL) {
        return nil;
    }

    struct tm value = {};
    if (ASN1_TIME_to_tm(time, &value) != 1) {
        return nil;
    }

    NSDateComponents *components = [[NSDateComponents alloc] init];
    components.year = value.tm_year + 1900;
    components.month = value.tm_mon + 1;
    components.day = value.tm_mday;
    components.hour = value.tm_hour;
    components.minute = value.tm_min;
    components.second = value.tm_sec;
    components.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];

    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = components.timeZone;
    return [calendar dateFromComponents:components];
}

static X509 * _Nullable LoadP12Certificate(NSString *path, NSString *password)
{
    EnsureOpenSSLProviders();

    const string file = ToString(path);
    const string pass = ToString(password);
    BIO *bio = BIO_new_file(file.c_str(), "rb");
    if (bio == NULL) {
        return NULL;
    }

    PKCS12 *p12 = d2i_PKCS12_bio(bio, NULL);
    BIO_free(bio);
    if (p12 == NULL) {
        return NULL;
    }

    EVP_PKEY *privateKey = NULL;
    X509 *certificate = NULL;
    STACK_OF(X509) *chain = NULL;

    int parsed = PKCS12_parse(p12, pass.c_str(), &privateKey, &certificate, &chain);
    if (parsed != 1 && pass.empty()) {
        ERR_clear_error();
        parsed = PKCS12_parse(p12, NULL, &privateKey, &certificate, &chain);
    }

    PKCS12_free(p12);
    if (privateKey != NULL) {
        EVP_PKEY_free(privateKey);
    }
    if (chain != NULL) {
        sk_X509_pop_free(chain, X509_free);
    }

    if (parsed != 1) {
        if (certificate != NULL) {
            X509_free(certificate);
        }
        return NULL;
    }
    return certificate;
}

static void FinishOCSP(
    void (^completionHandler)(int, NSDate * _Nullable, NSString * _Nullable),
    OCSP_CERTID * _Nullable certID,
    int status,
    NSDate * _Nullable expirationDate,
    NSString * _Nullable error
) {
    if (certID != NULL) {
        OCSP_CERTID_free(certID);
    }
    completionHandler(status, expirationDate, error);
}

} // namespace

extern "C" {

bool CheckIfSigned(NSString *filePath)
{
    @autoreleasepool {
        const string file = ToString(filePath);
        ZMachO macho;
        if (!macho.Init(file.c_str())) {
            return false;
        }
        const bool signedFile = macho.CheckSignature();
        macho.Free();
        return signedFile;
    }
}

bool InjectDyLib(NSString *filePath, NSString *dylibPath, bool weakInject)
{
    @autoreleasepool {
        const string file = ToString(filePath);
        const string dylib = ToString(dylibPath);
        ZMachO macho;
        if (!macho.Init(file.c_str())) {
            return false;
        }
        const bool success = macho.InjectDylib(weakInject, dylib.c_str());
        macho.Free();
        return success;
    }
}

bool UninstallDylibs(NSString *filePath, NSArray<NSString *> *dylibPathsArray)
{
    @autoreleasepool {
        const string file = ToString(filePath);
        set<string> dylibs;
        for (NSString *path in dylibPathsArray) {
            dylibs.insert(ToString(path));
        }

        ZMachO macho;
        if (!macho.Init(file.c_str())) {
            return false;
        }
        macho.RemoveDylibs(dylibs);
        macho.Free();
        return true;
    }
}

NSArray<NSString *> *ListDylibs(NSString *filePath)
{
    @autoreleasepool {
        const string file = ToString(filePath);
        ZMachO macho;
        if (!macho.Init(file.c_str())) {
            return @[];
        }

        const vector<string> dylibs = macho.ListDylibs();
        NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:dylibs.size()];
        for (const string &dylib : dylibs) {
            NSString *value = [NSString stringWithUTF8String:dylib.c_str()];
            if (value != nil) {
                [result addObject:value];
            }
        }
        macho.Free();
        return [result copy];
    }
}

bool ChangeDylibPath(NSString *filePath, NSString *oldPath, NSString *newPath)
{
    @autoreleasepool {
        const string file = ToString(filePath);
        const string oldDylib = ToString(oldPath);
        const string newDylib = ToString(newPath);
        ZMachO macho;
        if (!macho.Init(file.c_str())) {
            return false;
        }
        const bool success = macho.ChangeDylibPath(oldDylib.c_str(), newDylib.c_str());
        macho.Free();
        return success;
    }
}

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
) {
    @autoreleasepool {
        const string appPath = ToString(app);
        if (!ZFile::IsFileExists(appPath.c_str())) {
            ZLog::ErrorV(">>> Invalid path! %s\n", appPath.c_str());
            if (completionHandler != nil) {
                completionHandler(NO);
            }
            return -1;
        }

        ZSignAsset asset;
        const string certFile;
        const string keyFile = ToString(key);
        const string provisionFile = ToString(prov);
        const string entitlementsFile = ToString(entitlement);
        const string password = ToString(pass);
        const string bundleID = ToString(bundleid);
        const string displayName = ToString(displayname);
        const string bundleVersion = ToString(bundleversion);

        if (!asset.Init(
            certFile,
            keyFile,
            provisionFile,
            entitlementsFile,
            password,
            adhoc,
            false,
            false
        )) {
            if (completionHandler != nil) {
                completionHandler(NO);
            }
            return -1;
        }

        vector<string> injectDylibs;
        vector<string> removeDylibs;
        ZBundle bundle;
        const bool success = bundle.SignFolder(
            &asset,
            appPath,
            bundleID,
            bundleVersion,
            displayName,
            injectDylibs,
            removeDylibs,
            true,   // force sign
            false,  // weak inject
            true,   // enable cache
            dontGenerateEmbeddedMobileProvision
        );

        ZLog::PrintV(">>> Signing:\t%s %s\n", appPath.c_str(), adhoc ? " (Ad-hoc)" : "");
        if (completionHandler != nil) {
            completionHandler(success ? YES : NO);
        }
        return success ? 0 : -1;
    }
}

int checkCert(
    NSString *prov,
    NSString *key,
    NSString *pass,
    void (^completionHandler)(int status, NSDate * _Nullable expirationDate, NSString * _Nullable error)
) {
    (void)prov;

    if (key.length == 0) {
        completionHandler(2, nil, @"Certificate path is missing.");
        return -1;
    }

    X509 *certificate = LoadP12Certificate(key, pass);
    if (certificate == NULL) {
        completionHandler(2, nil, @"Unable to initialize certificate. Please check your password.");
        return -1;
    }

    const char *issuerPEM = ZSignAsset::WWDRIntermediatePEM(X509_issuer_name_hash(certificate));
    if (issuerPEM == NULL) {
        X509_free(certificate);
        completionHandler(2, nil, @"Unable to determine the Apple certificate issuer.");
        return -2;
    }

    BIO *issuerBIO = BIO_new_mem_buf(issuerPEM, -1);
    X509 *issuer = issuerBIO ? PEM_read_bio_X509(issuerBIO, NULL, NULL, NULL) : NULL;
    if (issuerBIO != NULL) {
        BIO_free(issuerBIO);
    }
    if (issuer == NULL) {
        X509_free(certificate);
        completionHandler(2, nil, @"Unable to initialize the Apple certificate issuer.");
        return -3;
    }

    STACK_OF(OPENSSL_STRING) *ocspURLs = X509_get1_ocsp(certificate);
    if (ocspURLs == NULL || sk_OPENSSL_STRING_num(ocspURLs) == 0) {
        if (ocspURLs != NULL) {
            X509_email_free(ocspURLs);
        }
        X509_free(issuer);
        X509_free(certificate);
        completionHandler(2, nil, @"No OCSP URL found in certificate.");
        return -4;
    }

    const char *ocspCString = sk_OPENSSL_STRING_value(ocspURLs, 0);
    NSString *ocspString = ocspCString ? [NSString stringWithUTF8String:ocspCString] : nil;
    X509_email_free(ocspURLs);
    NSURL *ocspURL = ocspString ? [NSURL URLWithString:ocspString] : nil;
    if (ocspURL == nil) {
        X509_free(issuer);
        X509_free(certificate);
        completionHandler(2, nil, @"Invalid OCSP URL in certificate.");
        return -5;
    }

    OCSP_REQUEST *request = OCSP_REQUEST_new();
    OCSP_CERTID *requestID = OCSP_cert_to_id(NULL, certificate, issuer);
    OCSP_CERTID *lookupID = OCSP_cert_to_id(NULL, certificate, issuer);
    if (request == NULL || requestID == NULL || lookupID == NULL) {
        if (request != NULL) OCSP_REQUEST_free(request);
        if (requestID != NULL) OCSP_CERTID_free(requestID);
        if (lookupID != NULL) OCSP_CERTID_free(lookupID);
        X509_free(issuer);
        X509_free(certificate);
        completionHandler(2, nil, @"Unable to create OCSP request.");
        return -6;
    }

    // OCSP_request_add0_id takes ownership of requestID.
    OCSP_request_add0_id(request, requestID);
    unsigned char *der = NULL;
    const int derLength = i2d_OCSP_REQUEST(request, &der);
    OCSP_REQUEST_free(request);

    NSDate *expirationDate = DateFromASN1Time(X509_get0_notAfter(certificate));
    X509_free(issuer);
    X509_free(certificate);

    if (derLength <= 0 || der == NULL) {
        if (der != NULL) OPENSSL_free(der);
        FinishOCSP(completionHandler, lookupID, 2, expirationDate, @"Unable to encode OCSP request.");
        return -7;
    }

    NSData *body = [NSData dataWithBytes:der length:(NSUInteger)derLength];
    OPENSSL_free(der);

    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:ocspURL];
    urlRequest.HTTPMethod = @"POST";
    urlRequest.HTTPBody = body;
    [urlRequest setValue:@"application/ocsp-request" forHTTPHeaderField:@"Content-Type"];
    [urlRequest setValue:@"application/ocsp-response" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:urlRequest
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            if (error != nil) {
                FinishOCSP(completionHandler, lookupID, 2, expirationDate, error.localizedDescription);
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode != 200 || data.length == 0) {
                FinishOCSP(completionHandler, lookupID, 2, expirationDate, @"Invalid OCSP response or no data.");
                return;
            }

            const unsigned char *bytes = (const unsigned char *)data.bytes;
            OCSP_RESPONSE *ocspResponse = d2i_OCSP_RESPONSE(NULL, &bytes, (long)data.length);
            if (ocspResponse == NULL || OCSP_response_status(ocspResponse) != OCSP_RESPONSE_STATUS_SUCCESSFUL) {
                if (ocspResponse != NULL) OCSP_RESPONSE_free(ocspResponse);
                FinishOCSP(completionHandler, lookupID, 2, expirationDate, @"Unable to decode OCSP response.");
                return;
            }

            OCSP_BASICRESP *basicResponse = OCSP_response_get1_basic(ocspResponse);
            if (basicResponse == NULL) {
                OCSP_RESPONSE_free(ocspResponse);
                FinishOCSP(completionHandler, lookupID, 2, expirationDate, @"OCSP response has no basic response.");
                return;
            }

            int status = V_OCSP_CERTSTATUS_UNKNOWN;
            int reason = 0;
            ASN1_GENERALIZEDTIME *revocationTime = NULL;
            ASN1_GENERALIZEDTIME *thisUpdate = NULL;
            ASN1_GENERALIZEDTIME *nextUpdate = NULL;
            const int found = OCSP_resp_find_status(
                basicResponse,
                lookupID,
                &status,
                &reason,
                &revocationTime,
                &thisUpdate,
                &nextUpdate
            );

            OCSP_BASICRESP_free(basicResponse);
            OCSP_RESPONSE_free(ocspResponse);
            FinishOCSP(completionHandler, lookupID, found == 1 ? status : 2, expirationDate, nil);
        }];

    [task resume];
    return 1;
}

bool p12_password_check(NSString *file, NSString *pass)
{
    EnsureOpenSSLProviders();
    const string path = ToString(file);
    const string password = ToString(pass);

    BIO *bio = BIO_new_file(path.c_str(), "rb");
    if (bio == NULL) {
        return false;
    }
    PKCS12 *p12 = d2i_PKCS12_bio(bio, NULL);
    BIO_free(bio);
    if (p12 == NULL) {
        return false;
    }

    bool valid = PKCS12_verify_mac(p12, NULL, 0) == 1;
    if (!valid) {
        ERR_clear_error();
        valid = PKCS12_verify_mac(p12, password.c_str(), -1) == 1;
    }
    PKCS12_free(p12);
    return valid;
}

void password_check_fix(NSString *path)
{
    EnsureOpenSSLProviders();

    string provisionData;
    const string provisionPath = ToString(path);
    if (!ZFile::ReadFile(provisionPath.c_str(), provisionData)) {
        return;
    }

    BIO *bio = BIO_new_mem_buf(provisionData.data(), (int)provisionData.size());
    if (bio == NULL) {
        return;
    }
    CMS_ContentInfo *cms = d2i_CMS_bio(bio, NULL);
    if (cms != NULL) {
        CMS_ContentInfo_free(cms);
    }
    BIO_free(bio);
}

void password_check_fix_free(NSString *path)
{
    // Kept for source compatibility with ASign. password_check_fix now owns and
    // releases its temporary CMS/BIO state instead of leaking it across calls.
    (void)path;
}

} // extern "C"
