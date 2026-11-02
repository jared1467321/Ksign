#import "PurchasePatch.h"
#import "MethodHook.h"

typedef void (^PurchaseCompletion)(NSData *, NSURLResponse *, NSError *);
typedef NSURLSessionDataTask *(*RequestTask)(NSURLSession *, SEL, NSURLRequest *, PurchaseCompletion);
typedef NSURLSessionDataTask *(*URLTask)(NSURLSession *, SEL, NSURL *, PurchaseCompletion);
static RequestTask OriginalRequestTask;
static URLTask OriginalURLTask;
static RequestTask NativeRequestTask;
static NSString *const BodyKey = @"AsignLocalPurchaseBody.v1";
static NSString *const ErrorKey = @"AsignLocalPurchaseError.v1";
static char LocalSessionKey;
typedef void (^ConnectionCompletion)(NSURLResponse *, NSData *, NSError *);
static void (*OriginalConnection)(id, SEL, NSURLRequest *, NSOperationQueue *, ConnectionCompletion);

// Use Foundation's native task/cancellation machinery with a private URL
// protocol. Prepared responses never open a connection or submit a receipt.
@interface AsignLocalPurchaseProtocol : NSURLProtocol
@end
@implementation AsignLocalPurchaseProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    // This class is configured only on our private sessions. Fail closed if a
    // request property is lost; never fall through to a real network transfer.
    (void)request;
    return YES;
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSError *error = [NSURLProtocol propertyForKey:ErrorKey inRequest:self.request];
    if (error) { [self.client URLProtocol:self didFailWithError:error]; return; }
    NSData *data = [NSURLProtocol propertyForKey:BodyKey inRequest:self.request];
    if (![data isKindOfClass:NSData.class]) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
            code:NSURLErrorCannotParseResponse userInfo:nil]];
        return;
    }
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200
        HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/json",
        @"Content-Length":[NSString stringWithFormat:@"%lu", (unsigned long)data.length]}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

static NSURLSessionDataTask *LocalTask(NSURLSession *session, NSURLRequest *request,
                                      NSDictionary *body, NSError *error, PurchaseCompletion completion) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    if (!data || !NativeRequestTask) return nil;
    NSURLSession *local;
    @synchronized (session) {
        local = objc_getAssociatedObject(session, &LocalSessionKey);
        if (!local) {
            NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
            configuration.protocolClasses = @[AsignLocalPurchaseProtocol.class];
            local = [NSURLSession sessionWithConfiguration:configuration delegate:nil delegateQueue:session.delegateQueue];
            objc_setAssociatedObject(session, &LocalSessionKey, local, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    NSMutableURLRequest *prepared = [request mutableCopy];
    [NSURLProtocol setProperty:data forKey:BodyKey inRequest:prepared];
    if (error) [NSURLProtocol setProperty:error forKey:ErrorKey inRequest:prepared];
    return NativeRequestTask(local, @selector(dataTaskWithRequest:completionHandler:), prepared, completion);
}

static NSArray *RevenuePath(NSURLRequest *request) {
    NSURL *url = request.URL;
    if (![url.scheme.lowercaseString isEqual:@"https"]) return nil;
    NSString *host = url.host.lowercaseString;
    if (![@[@"api.revenuecat.com", @"api.rc-backup.com", @"api-production.8-lives-cat.io"] containsObject:host]) return nil;
    NSString *path = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].percentEncodedPath;
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    if (parts.count < 3 || ![parts[1] isEqual:@"v1"]) return nil;
    return parts;
}

static NSString *Scope(NSURLRequest *request) {
    NSString *key = [request valueForHTTPHeaderField:@"Authorization"];
    return key.length && key.length <= 1024 ? key : nil;
}

static NSString *Customer(NSArray *path) {
    return path.count == 4 && [path[2] isEqual:@"subscribers"] && [path[3] length] && ![path[3] isEqual:@"identify"]
        ? [path[3] stringByRemovingPercentEncoding] : nil;
}

static BOOL ReceiptVerification(NSURLRequest *request) {
    NSURL *url = request.URL;
    return [url.scheme.lowercaseString isEqual:@"https"] && [url.path isEqual:@"/verifyReceipt"] &&
        [@[@"buy.itunes.apple.com", @"sandbox.itunes.apple.com"] containsObject:url.host.lowercaseString];
}

static void ConnectionRequest(id self, SEL selector, NSURLRequest *request,
                              NSOperationQueue *queue, ConnectionCompletion completion) {
    if (!completion || ![queue isKindOfClass:NSOperationQueue.class] ||
        !ReceiptVerification(request) || !AsignLocalPurchasesActive()) {
        OriginalConnection(self, selector, request, queue, completion);
        return;
    }
    NSData *data = AsignLocalReceipt();
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200
        HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/json"}];
    [queue addOperationWithBlock:^{ completion(response, data, nil); }];
}

static void InstallLegacyConnection(void) {
    Class cls = object_getClass(NSClassFromString(@"NSURLConnection"));
    SEL selector = NSSelectorFromString(@"sendAsynchronousRequest:queue:completionHandler:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 5) return;
    char *type = method_copyReturnType(method);
    BOOL valid = AsignTypeMatches(type, "v");
    free(type);
    const char *arguments[] = {"@", ":", "@", "@", "@?"};
    for (unsigned i = 0; valid && i < 5; ++i) {
        type = method_copyArgumentType(method, i);
        valid = AsignTypeMatches(type, arguments[i]);
        free(type);
    }
    if (!valid) return;
    OriginalConnection = (void *)method_getImplementation(method);
    if (!class_addMethod(cls, selector, (IMP)ConnectionRequest, method_getTypeEncoding(method)))
        OriginalConnection = (void *)method_setImplementation(method, (IMP)ConnectionRequest);
}

static NSDictionary *JSON(NSData *data) {
    if (!data.length || data.length > 8 * 1024 * 1024) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static BOOL Successful(NSURLResponse *response, NSError *error) {
    return !error && [response isKindOfClass:NSHTTPURLResponse.class] &&
        [(NSHTTPURLResponse *)response statusCode] >= 200 && [(NSHTTPURLResponse *)response statusCode] < 300;
}

// Deduplicate an on-demand mapping request. Setup, ordinary traffic and apps
// without RevenueCat never reach this function. Headers stay on the same host.
static void EnsureMapping(NSURLSession *session, NSURLRequest *request, void (^completion)(void)) {
    NSString *scope = Scope(request);
    if (!scope || AsignPurchaseMapping(scope).count) { completion(); return; }
    static NSMutableDictionary *waiting;
    static NSMutableSet *attempted;
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ waiting = [NSMutableDictionary dictionary]; attempted = [NSMutableSet set]; lock = [NSObject new]; });
    @synchronized (lock) {
        NSMutableArray *callbacks = waiting[scope];
        if (callbacks) { [callbacks addObject:[completion copy]]; return; }
        if ([attempted containsObject:scope]) { completion(); return; }
        [attempted addObject:scope];
        waiting[scope] = [NSMutableArray arrayWithObject:[completion copy]];
    }
    NSURLComponents *url = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    url.path = @"/v1/product_entitlement_mapping";
    url.query = nil;
    NSMutableURLRequest *mapping = [request mutableCopy];
    mapping.URL = url.URL;
    mapping.HTTPMethod = @"GET";
    mapping.HTTPBody = nil;
    mapping.HTTPBodyStream = nil;
    [mapping setValue:nil forHTTPHeaderField:@"Content-Length"];
    [mapping setValue:nil forHTTPHeaderField:@"X-RevenueCat-ETag"];
    mapping.timeoutInterval = 10;
    PurchaseCompletion finished = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (Successful(response, error)) AsignRememberPurchaseMapping(scope, JSON(data));
        NSArray *callbacks;
        @synchronized (lock) { callbacks = [waiting[scope] copy]; [waiting removeObjectForKey:scope]; }
        for (void (^callback)(void) in callbacks) callback();
    };
    NSURLSessionDataTask *task = OriginalRequestTask(session, @selector(dataTaskWithRequest:completionHandler:), mapping, finished);
    if (task) [task resume];
    else finished(nil, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnknown userInfo:nil]);
}

static NSURLSessionDataTask *PurchaseRequestTask(NSURLSession *self, SEL selector,
                                               NSURLRequest *request, PurchaseCompletion completion) {
    if (!completion) return OriginalRequestTask(self, selector, request, completion);
    if (ReceiptVerification(request) && AsignLocalPurchasesActive()) {
        NSURLSessionDataTask *task = LocalTask(self, request, AsignLocalReceiptResponse(), nil, completion);
        if (task) return task;
    }
    NSArray *path = RevenuePath(request);
    NSString *scope = path ? Scope(request) : nil;
    if (!scope) return OriginalRequestTask(self, selector, request, completion);
    request = [request copy];
    BOOL get = !request.HTTPMethod || [request.HTTPMethod isEqual:@"GET"];
    NSString *customer = get ? Customer(path) : nil;
    BOOL receipt = path.count == 3 && [path[2] isEqual:@"receipts"] && [request.HTTPMethod isEqual:@"POST"];
    BOOL mapping = get && path.count == 3 && [path[2] isEqual:@"product_entitlement_mapping"];
    if (receipt && AsignLocalPurchasesActive()) {
        id user = JSON(request.HTTPBody)[@"app_user_id"];
        customer = [user isKindOfClass:NSString.class] ? user : nil;
    }
    if ((customer || receipt) && AsignPurchaseMapping(scope).count) {
        NSDictionary *body = AsignLocalSubscriberResponse(scope, customer, nil);
        NSURLSessionDataTask *task = body ? LocalTask(self, request, body, nil, completion) : nil;
        if (task) return task;
    }
    if (receipt && AsignLocalPurchasesActive()) {
        // A local receipt must not be posted as a real transaction. If no exact
        // mapping is available, return an explicit local failure instead.
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotParseResponse
            userInfo:@{NSLocalizedDescriptionKey:@"No local RevenueCat entitlement mapping is available."}];
        NSURLSessionDataTask *task = LocalTask(self, request, @{}, error, completion);
        if (task) return task;
    }
    if (!customer && !mapping) return OriginalRequestTask(self, selector, request, completion);
    return OriginalRequestTask(self, selector, request, ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *body = Successful(response, error) ? JSON(data) : nil;
        if (body) AsignRememberPurchaseMapping(scope, body);
        if (mapping) { completion(data, response, error); return; }
        // Preserve native failures when no mapping is known; never guess an
        // entitlement name or manufacture a remote authorization result.
        EnsureMapping(self, request, ^{
            NSDictionary *local = AsignLocalSubscriberResponse(scope, customer, body);
            NSData *replacement = local ? [NSJSONSerialization dataWithJSONObject:local options:0 error:NULL] : nil;
            if (!replacement) { completion(data, response, error); return; }
            NSHTTPURLResponse *localResponse = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200
                HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/json"}];
            completion(replacement, localResponse, nil);
        });
    });
}

static NSURLSessionDataTask *PurchaseURLTask(NSURLSession *self, SEL selector, NSURL *url, PurchaseCompletion completion) {
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    if (completion && ReceiptVerification(request) && AsignLocalPurchasesActive()) {
        NSURLSessionDataTask *task = LocalTask(self, request, AsignLocalReceiptResponse(), nil, completion);
        if (task) return task;
    }
    return OriginalURLTask(self, selector, url, completion);
}

void AsignInstallRevenueCatPurchasePatch(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        InstallLegacyConnection();
        Method method = class_getInstanceMethod(NSURLSession.class, @selector(dataTaskWithRequest:completionHandler:));
        if (!AsignMethodMatches(method, "@", "@", "@?")) return;
        NativeRequestTask = (RequestTask)method_getImplementation(method);
        AsignHookMethod(NSURLSession.class, @selector(dataTaskWithRequest:completionHandler:),
            (IMP)PurchaseRequestTask, (IMP *)&OriginalRequestTask, "@", "@", "@?");
        AsignHookMethod(NSURLSession.class, @selector(dataTaskWithURL:completionHandler:),
            (IMP)PurchaseURLTask, (IMP *)&OriginalURLTask, "@", "@", "@?");
    });
}

#ifdef ASIGN_PURCHASE_TESTING
void AsignTestPurchaseTransport(RequestTask request, URLTask url) {
    OriginalRequestTask = request;
    OriginalURLTask = url;
}
void AsignTestPurchaseConnection(void (*connection)(id, SEL, NSURLRequest *, NSOperationQueue *, ConnectionCompletion)) {
    OriginalConnection = connection;
}
#endif
