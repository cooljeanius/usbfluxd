//
//  STHTTPRequest.m
//  STHTTPRequest
//
//  Created by Nicolas Seriot on 07.11.11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#ifndef __has_feature
# define __has_feature(foo) 0
#endif /* !__has_feature */

#ifndef __has_extension
# define __has_extension(foo) __has_feature(foo) // Compat. w/pre-3.0 clangs
#endif /* !__has_extension */

#if __has_feature(objc_arc)
/* (ok) */
#else
// see http://www.codeography.com/2011/10/10/making-arc-and-non-arc-play-nice.html
#error This file must be compiled with ARC. Either turn on ARC for the project or use -fobjc-arc flag
#include "fake_file_that_does_not_exist_and_should_never_exist_to_terminate_compilation.h"
#endif

#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonDigest.h>
#import "STHTTPRequest.h"

NSUInteger const kSTHTTPRequestCancellationError = 1;
NSUInteger const kSTHTTPRequestDefaultTimeout = 30;

static NSMutableDictionary *localCredentialsStorage = nil;
static NSMutableArray *localCookiesStorage = nil;
static NSMutableDictionary *sessionCompletionHandlersForIdentifier = nil;

static BOOL globalIgnoreCache = NO;
static STHTTPRequestCookiesStorage globalCookiesStoragePolicy = STHTTPRequestCookiesStorageShared;

/**/

@interface STHTTPRequestFileUpload : NSObject
@property (nonatomic, retain) NSString *path;
@property (nonatomic, retain) NSString *parameterName;
@property (nonatomic, retain) NSString *mimeType;

+ (instancetype)fileUploadWithPath:(NSString *)path parameterName:(NSString *)parameterName mimeType:(NSString *)mimeType;
+ (instancetype)fileUploadWithPath:(NSString *)path parameterName:(NSString *)parameterName;
@end

@interface STHTTPRequestDataUpload : NSObject
@property (nonatomic, retain) NSData *data;
@property (nonatomic, retain) NSString *parameterName;
@property (nonatomic, retain) NSString *mimeType; // can be nil
@property (nonatomic, retain) NSString *fileName; // can be nil
+ (instancetype)dataUploadWithData:(NSData *)data parameterName:(NSString *)parameterName mimeType:(NSString *)mimeType fileName:(NSString *)fileName;
@end

/**/

API_AVAILABLE(macos(10.9))
@interface STHTTPRequest ()

@property (nonatomic) NSInteger responseStatus;
@property (nonatomic, strong) NSURLSessionTask *task;
@property (nonatomic, strong) NSMutableData *responseData;
@property (nonatomic, strong) NSString *responseStringEncodingName;
@property (nonatomic, strong) NSDictionary *responseHeaders;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, strong) NSMutableArray *filesToUpload; // STHTTPRequestFileUpload instances
@property (nonatomic, strong) NSMutableArray *dataToUpload; // STHTTPRequestDataUpload instances
@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic, strong) NSURL *HTTPBodyFileURL; // created for NSURLSessionUploadTask, removed on completion
@property (nonatomic, strong) NSMutableArray *ephemeralRequestCookies;

@end

@interface NSData (Base64)
- (NSString *)base64Encoding; // private API
@end

@implementation STHTTPRequest

#pragma mark Initializers

+ (instancetype)requestWithURL:(NSURL *)url {
    if(url == nil) return nil;
    return [(STHTTPRequest *)[self alloc] initWithURL:url];
}

+ (instancetype)requestWithURLString:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    return [self requestWithURL:url];
}

+ (void)setGlobalIgnoreCache:(BOOL)ignoreCache {
    globalIgnoreCache = ignoreCache;
}

+ (void)setGlobalCookiesStoragePolicy:(STHTTPRequestCookiesStorage)cookieStoragePolicy {
    globalCookiesStoragePolicy = cookieStoragePolicy;
}

- (instancetype)initWithURL:(NSURL *)theURL {
    
    if (self = [super init]) {
        self.url = theURL;
        self.responseData = [[NSMutableData alloc] init];
        self.requestHeaders = [NSMutableDictionary dictionary];
        self.POSTDataEncoding = NSUTF8StringEncoding;
        self.encodePOSTDictionary = YES;
        self.encodeGETDictionary = YES;
        self.addCredentialsToURL = NO;
        self.timeoutSeconds = kSTHTTPRequestDefaultTimeout;
        self.filesToUpload = [NSMutableArray array];
        self.dataToUpload = [NSMutableArray array];
        self.HTTPMethod = @"GET"; // default
        self.cookieStoragePolicyForInstance = STHTTPRequestCookiesStorageUndefined; // globalCookiesStoragePolicy will be used
        self.ephemeralRequestCookies = [NSMutableArray array];
    }
    
    return self;
}

+ (void)clearSession {
    [[self class] deleteAllCookiesFromSharedCookieStorage];
    [[self class] deleteAllCookiesFromLocalCookieStorage];
    [[self class] deleteAllCredentials];
}

#pragma mark Credentials

+ (NSMutableDictionary *)sharedCredentialsStorage {
    if(localCredentialsStorage == nil) {
        localCredentialsStorage = [NSMutableDictionary dictionary];
    }
    return localCredentialsStorage;
}

+ (NSURLCredential *)sessionAuthenticationCredentialsForURL:(NSURL *)requestURL {
    return [[[self class] sharedCredentialsStorage] valueForKey:[requestURL host]];
}

+ (void)deleteAllCredentials {
    localCredentialsStorage = [NSMutableDictionary dictionary];
}

- (void)setCredentialForCurrentHost:(NSURLCredential *)c {
#if DEBUG
    NSAssert(_url, @"missing url to set credential");
#endif
    [[[self class] sharedCredentialsStorage] setObject:c forKey:[_url host]];
}

- (NSURLCredential *)credentialForCurrentHost {
    return [[[self class] sharedCredentialsStorage] valueForKey:[_url host]];
}

- (void)setUsername:(NSString *)username password:(NSString *)password {
    NSURLCredential *c = [NSURLCredential credentialWithUser:username
                                                    password:password
                                                 persistence:NSURLCredentialPersistenceNone];
    
    [self setCredentialForCurrentHost:c];
}

- (NSString *)username {
    return [[self credentialForCurrentHost] user];
}

- (NSString *)password {
    return [[self credentialForCurrentHost] password];
}

#pragma mark Cookies

- (STHTTPRequestCookiesStorage)cookieStoragePolicy {
    if(_cookieStoragePolicyForInstance != STHTTPRequestCookiesStorageUndefined) {
        return _cookieStoragePolicyForInstance;
    }
    
    return globalCookiesStoragePolicy;
}

+ (NSMutableArray *)localCookiesStorage {
    if(localCookiesStorage == nil) {
        localCookiesStorage = [NSMutableArray array];
    }
    return localCookiesStorage;
}

+ (NSArray *)sessionCookiesInSharedCookiesStorage {
    NSArray *allCookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
    
    NSArray *sessionCookies = [allCookies filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
        NSHTTPCookie *cookie = (NSHTTPCookie *)evaluatedObject;
        return [cookie isSessionOnly];
    }]];
    
    return sessionCookies;
}

- (NSArray *)sessionCookies {
    
    NSArray *allCookies = nil;
    
    if([self cookieStoragePolicy] == STHTTPRequestCookiesStorageShared) {
        allCookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
    } else if ([self cookieStoragePolicy] == STHTTPRequestCookiesStorageLocal) {
        allCookies = [[self class] localCookiesStorage];
    }
    
    NSArray *sessionCookies = [allCookies filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
        NSHTTPCookie *cookie = (NSHTTPCookie *)evaluatedObject;
        return [cookie isSessionOnly];
    }]];
    
    return sessionCookies;
}

- (void)deleteSessionCookies {
    
    for(NSHTTPCookie *cookie in [self sessionCookies]) {
        if([self cookieStoragePolicy] == STHTTPRequestCookiesStorageShared) {
            [[NSHTTPCookieStorage sharedHTTPCookieStorage] deleteCookie:cookie];
        } else if ([self cookieStoragePolicy] == STHTTPRequestCookiesStorageLocal) {
            [[[self class] localCookiesStorage] removeObject:cookie];
        }
    }
}

+ (void)deleteAllCookiesFromSharedCookieStorage {
    NSHTTPCookieStorage *sharedCookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray *cookies = [sharedCookieStorage cookies];
    for (NSHTTPCookie *cookie in cookies) {
        [sharedCookieStorage deleteCookie:cookie];
    }
}

+ (void)deleteAllCookiesFromLocalCookieStorage {
    localCookiesStorage = nil;
}

- (void)deleteAllCookies {
    if([self cookieStoragePolicy] == STHTTPRequestCookiesStorageShared) {
        [[self class] deleteAllCookiesFromSharedCookieStorage];
    } else if ([self cookieStoragePolicy] == STHTTPRequestCookiesStorageLocal) {
        [[[self class] localCookiesStorage] removeAllObjects];
    }
}

+ (void)addCookieToSharedCookiesStorage:(NSHTTPCookie *)cookie {
    [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookie:cookie];
    
#if defined(DEBUG) && (DEBUG >= 1)
    NSHTTPCookie *readCookie = [[[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies] lastObject];
    NSAssert(readCookie, @"cannot read any cookie after adding one");
#endif /* (DEBUG >= 1) */
}

- (void)addCookie:(NSHTTPCookie *)cookie {
    
    NSParameterAssert(cookie);
    if(cookie == nil) return;
    
    if([self cookieStoragePolicy] == STHTTPRequestCookiesStorageShared) {
        [[self class] addCookieToSharedCookiesStorage:cookie];
    } else if ([self cookieStoragePolicy] == STHTTPRequestCookiesStorageLocal) {
        [[[self class] localCookiesStorage] addObject:cookie];
    } else if ([self cookieStoragePolicy] == STHTTPRequestCookiesStorageNoStorage) { // ephemeral cookie, only for this request
        [_ephemeralRequestCookies addObject:cookie];
    }
}

+ (void)addCookieToSharedCookiesStorageWithName:(NSString *)name value:(NSString *)value url:(NSURL *)url {
    NSHTTPCookie *cookie = [[self class] createCookieWithName:name value:value url:url];
    
    [self addCookieToSharedCookiesStorage:cookie];
}

+ (NSHTTPCookie *)createCookieWithName:(NSString *)name value:(NSString *)value url:(NSURL *)url {
    NSParameterAssert(url);
    if(url == nil) return nil;
    
    NSMutableDictionary *cookieProperties = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                             name, NSHTTPCookieName,
                                             value, NSHTTPCookieValue,
                                             url, NSHTTPCookieOriginURL,
                                             @"FALSE", NSHTTPCookieDiscard,
                                             @"/", NSHTTPCookiePath,
                                             @"0", NSHTTPCookieVersion,
                                             [[NSDate date] dateByAddingTimeInterval:3600 * 24 * 30], NSHTTPCookieExpires,
                                             nil];
    
    NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:cookieProperties];
    
    return cookie;
}

- (void)addCookieWithName:(NSString *)name value:(NSString *)value url:(NSURL *)url {
    NSHTTPCookie *cookie = [[self class] createCookieWithName:name value:value url:url];
    
    [self addCookie:cookie];
}

- (NSArray *)requestCookies {
    
    if([self cookieStoragePolicy] == STHTTPRequestCookiesStorageShared) {
        return [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:[_url absoluteURL]];
    } else if ([self cookieStoragePolicy] == STHTTPRequestCookiesStorageLocal) {
        NSArray *filteredCookies = [[[self class] localCookiesStorage] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
            NSHTTPCookie *cookie = (NSHTTPCookie *)evaluatedObject;
            return [[cookie domain] isEqualToString:[self.url host]];
        }]];
        return filteredCookies;
    } else if ([self cookieStoragePolicy] == STHTTPRequestCookiesStorageNoStorage) {
        return _ephemeralRequestCookies;
    }
    
    return nil;
}

- (void)addCookieWithName:(NSString *)name value:(NSString *)value {
    [self addCookieWithName:name value:value url:_url];
}

#pragma mark Headers

- (void)setHeaderWithName:(NSString *)name value:(NSString *)value {
    if(name == nil || value == nil) return;
    [[self requestHeaders] setObject:value forKey:name];
}

- (void)removeHeaderWithName:(NSString *)name {
    if(name == nil) return;
    [[self requestHeaders] removeObjectForKey:name];
}

+ (NSURL *)urlByAddingCredentials:(NSURLCredential *)credentials toURL:(NSURL *)url {
    
    if(credentials == nil) return nil; // no credentials to add
    
    NSString *scheme = [url scheme];
    NSString *host = [url host];
    
    BOOL hostAlreadyContainsCredentials = [host rangeOfString:@"@"].location != NSNotFound;
    if(hostAlreadyContainsCredentials) return url;
    
    NSMutableString *resourceSpecifier = [[url resourceSpecifier] mutableCopy];
    
    if([resourceSpecifier hasPrefix:@"//"] == NO) return nil;
    
    NSString *userPassword = [NSString stringWithFormat:@"%@:%@@", credentials.user, credentials.password];
    
    [resourceSpecifier insertString:userPassword atIndex:2];
    
    NSString *urlString = [NSString stringWithFormat:@"%@:%@", scheme, resourceSpecifier];
    
    return [NSURL URLWithString:urlString];
}

// {k2:v2, k1:v1} -> [{k1:v1}, {k2:v2}]
+ (NSArray *)dictionariesSortedByKey:(NSDictionary *)dictionary {
    
    NSArray *keys = [dictionary allKeys];
    NSArray *sortedKeys = [keys sortedArrayUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        NSComparisonResult result = [obj1 compare:obj2];
        return result;
    }];
    
    NSMutableArray *sortedDictionaries = [NSMutableArray arrayWithCapacity:[dictionary count]];
    
    for(NSString *key in sortedKeys) {
    	NSDictionary *d;
        if (@available(macOS 10.8, *)) {
            d = @{ key : dictionary[key] };
        } else {
            d = NULL; // Fallback on earlier versions
        }
        if (d != nil) {
        	[sortedDictionaries addObject:d];
        }
    }
    return sortedDictionaries;
}

+ (NSData *)multipartContentWithBoundary:(NSString *)boundary data:(NSData *)someData fileName:(NSString *)fileName parameterName:(NSString *)parameterName mimeType:(NSString *)aMimeType {
    
    NSString *mimeType = aMimeType ? aMimeType : @"application/octet-stream";
    
    NSMutableData *data = [[NSMutableData alloc] init];
    
    [data appendData:[[NSString stringWithFormat:@"\r\n--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    
    NSString *fileNameContentDisposition = fileName ? [NSString stringWithFormat:@"filename=\"%@\"", fileName] : @"";
    NSString *contentDisposition = [NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"; %@\r\n", parameterName, fileNameContentDisposition];
    
    [data appendData:[contentDisposition dataUsingEncoding:NSUTF8StringEncoding]];
    [data appendData:[[NSString stringWithFormat:@"Content-Type: %@\r\n\r\n", mimeType] dataUsingEncoding:NSUTF8StringEncoding]];
    [data appendData:someData];
    
    return data;
}

+ (NSURL *)appendURL:(NSURL *)url withGETParameters:(NSDictionary *)parameters doApplyURLEncoding:(BOOL)doApplyURLEncoding {
    NSMutableString *urlString = [[NSMutableString alloc] initWithString:[url absoluteString]];
    
    NSString *s = [urlString st_stringByAppendingGETParameters:parameters doApplyURLEncoding:doApplyURLEncoding];
    
    return [NSURL URLWithString:s];
}

- (NSURLRequest *)prepareURLRequest {
    
    NSURL *theURL = nil;
    
    if(_addCredentialsToURL) {
        NSURLCredential *credential = [self credentialForCurrentHost];
        if(credential == nil) return nil;
        theURL = [[self class] urlByAddingCredentials:credential toURL:_url];
        if(theURL == nil) return nil;
    } else {
        theURL = _url;
    }
    
    theURL = [[self class] appendURL:theURL withGETParameters:_GETDictionary doApplyURLEncoding:_encodeGETDictionary];
    
    if([_HTTPMethod isEqualToString:@"GET"]) {
        if(_POSTDictionary || _rawPOSTData || [self.filesToUpload count] > 0 || [self.dataToUpload count] > 0) {
            self.HTTPMethod = @"POST";
        }
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:theURL];
    [request setHTTPMethod:_HTTPMethod];
    
    if(globalIgnoreCache || _ignoreCache) {
        request.cachePolicy = NSURLRequestReloadIgnoringCacheData;
    }
    
    if(self.timeoutSeconds != 0.0) {
        request.timeoutInterval = self.timeoutSeconds;
    }
    
    NSArray *cookies = [self requestCookies];
    NSDictionary *d0 = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
    [request setAllHTTPHeaderFields:d0];
    
    // escape POST dictionary keys and values if needed
    if(_encodePOSTDictionary) {
        NSMutableDictionary *escapedPOSTDictionary = _POSTDictionary ? [NSMutableDictionary dictionary] : nil;
        [_POSTDictionary enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            NSString *k = [key st_stringByAddingRFC3986PercentEscapesUsingEncoding:self.POSTDataEncoding];
            NSString *v = [[obj description] st_stringByAddingRFC3986PercentEscapesUsingEncoding:self.POSTDataEncoding];
            [escapedPOSTDictionary setValue:v forKey:k];
        }];
        self.POSTDictionary = escapedPOSTDictionary;
    }
    
    // sort POST parameters in order to get deterministic, unit testable requests
    NSArray *sortedPOSTDictionaries = [[self class] dictionariesSortedByKey:_POSTDictionary];
    
    NSData *bodyData = nil;
    
    if([self.filesToUpload count] > 0 || [self.dataToUpload count] > 0) {
        
        NSString *boundary = @"----------kStHtTpReQuEsTbOuNdArY";
        
        NSString *contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary];
        [request addValue:contentType forHTTPHeaderField:@"Content-Type"];
        
        /**/
        
        NSMutableData *mutableBodyData = [NSMutableData data];
        
        for(STHTTPRequestFileUpload *fileToUpload in self.filesToUpload) {
            
            NSData *data = [NSData dataWithContentsOfFile:fileToUpload.path];
            if(data == nil) continue;
            NSString *fileName = [fileToUpload.path lastPathComponent];
            
            NSData *multipartData = [[self class] multipartContentWithBoundary:boundary
                                                                          data:data
                                                                      fileName:fileName
                                                                 parameterName:fileToUpload.parameterName
                                                                      mimeType:fileToUpload.mimeType];
            [mutableBodyData appendData:multipartData];
        }
        
        /**/
        
        for(STHTTPRequestDataUpload *dataToUpload in self.dataToUpload) {
            NSData *multipartData = [[self class] multipartContentWithBoundary:boundary
                                                                          data:dataToUpload.data
                                                                      fileName:dataToUpload.fileName
                                                                 parameterName:dataToUpload.parameterName
                                                                      mimeType:dataToUpload.mimeType];
            
            [mutableBodyData appendData:multipartData];
        }
        
        /**/
        
        [sortedPOSTDictionaries enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            NSDictionary *d1 = (NSDictionary *)obj;
            NSString *key = [[d1 allKeys] lastObject];
            NSObject *value = [[d1 allValues] lastObject];
            
            [mutableBodyData appendData:[[NSString stringWithFormat:@"\r\n--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
            [mutableBodyData appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", key] dataUsingEncoding:NSUTF8StringEncoding]];
            [mutableBodyData appendData:[[value description] dataUsingEncoding:NSUTF8StringEncoding]];
        }];
        
        /**/
        
        [mutableBodyData appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
        
        [request setValue:[NSString stringWithFormat:@"%u", (unsigned int)[bodyData length]] forHTTPHeaderField:@"Content-Length"];
        
        bodyData = mutableBodyData;
        
    } else if (_rawPOSTData) {
        
        [request setValue:[NSString stringWithFormat:@"%u", (unsigned int)[_rawPOSTData length]] forHTTPHeaderField:@"Content-Length"];
        bodyData = _rawPOSTData;
        
    } else if (_POSTDictionary != nil) { // may be empty (POST request without body)
        
        NSMutableString *contentTypeValue = [NSMutableString stringWithString:@"application/x-www-form-urlencoded"];
        
        if(_encodePOSTDictionary) {
            
            CFStringEncoding cfStringEncoding = CFStringConvertNSStringEncodingToEncoding(_POSTDataEncoding);
            NSString *encodingName = (NSString *)CFStringConvertEncodingToIANACharSetName(cfStringEncoding);
            
            if(encodingName) {
                [contentTypeValue appendFormat:@"; charset=%@", encodingName];
            }
        }
        
        [self setHeaderWithName:@"Content-Type" value:contentTypeValue];
        
        NSMutableArray *ma = [NSMutableArray arrayWithCapacity:[_POSTDictionary count]];
        
        [sortedPOSTDictionaries enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            NSDictionary *d2 = (NSDictionary *)obj;
            NSString *key = [[d2 allKeys] lastObject];
            NSObject *value = [[d2 allValues] lastObject];
            
            NSString *kv = [NSString stringWithFormat:@"%@=%@", key, value];
            [ma addObject:kv];
        }];
        
        NSString *s = [ma componentsJoinedByString:@"&"];
        
        bodyData = [s dataUsingEncoding:_POSTDataEncoding allowLossyConversion:YES];
        
        [request setValue:[NSString stringWithFormat:@"%u", (unsigned int)[bodyData length]] forHTTPHeaderField:@"Content-Length"];
    }
    
    if(bodyData) {
        [request setHTTPBody:bodyData];
    }
    
    [_requestHeaders enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        [request addValue:obj forHTTPHeaderField:key];
    }];
    
    NSURLCredential *credentialForHost = [self credentialForCurrentHost];
    
    if(credentialForHost) {
        NSString *authString = [NSString stringWithFormat:@"%@:%@", credentialForHost.user, credentialForHost.password];
        NSData *authData = [authString dataUsingEncoding:NSASCIIStringEncoding];
        NSString *authValue = [NSString stringWithFormat:@"Basic %@", [authData base64Encoding]];
        [request addValue:authValue forHTTPHeaderField:@"Authorization"];
    }
    
    request.HTTPShouldHandleCookies = ([self cookieStoragePolicy] == STHTTPRequestCookiesStorageShared);
    
    return request;
}

#pragma mark Upload

- (void)addFileToUpload:(NSString *)path parameterName:(NSString *)parameterName {
    
    STHTTPRequestFileUpload *fu = [STHTTPRequestFileUpload fileUploadWithPath:path parameterName:parameterName];
    [self.filesToUpload addObject:fu];
}

- (void)addDataToUpload:(NSData *)data parameterName:(NSString *)param {
    STHTTPRequestDataUpload *du = [STHTTPRequestDataUpload dataUploadWithData:data parameterName:param mimeType:nil fileName:nil];
    [self.dataToUpload addObject:du];
}

- (void)addDataToUpload:(NSData *)data parameterName:(NSString *)param mimeType:(NSString *)mimeType fileName:(NSString *)fileName {
    STHTTPRequestDataUpload *du = [STHTTPRequestDataUpload dataUploadWithData:data parameterName:param mimeType:mimeType fileName:fileName];
    [self.dataToUpload addObject:du];
}

#pragma mark Response

- (NSString *)responseString {
    if(_responseString == nil) {
        self.responseString = [self stringWithData:_responseData encodingName:_responseStringEncodingName];
    }
    return _responseString;
}

- (NSString *)stringWithData:(NSData *)data encodingName:(NSString *)encodingName {
    if(data == nil) return nil;
    
    if(_forcedResponseEncoding > 0) {
        return [[NSString alloc] initWithData:data encoding:_forcedResponseEncoding];
    }
    
    NSStringEncoding encoding = NSUTF8StringEncoding;
    
    /* try to use encoding declared in HTTP response headers */
    
    if(encodingName != nil) {
        
        encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding((CFStringRef)encodingName));
        
        if(encoding == kCFStringEncodingInvalidId) {
            encoding = NSUTF8StringEncoding; // by default
        }
    }
    
    return [[NSString alloc] initWithData:data encoding:encoding];
}

#pragma mark HTTP Error Codes

+ (NSString *)descriptionForHTTPStatus:(NSUInteger)status {
    NSString *s = [NSString stringWithFormat:@"HTTP Status %@", @(status)];
    
    NSString *description = nil;
    // http://www.iana.org/assignments/http-status-codes/http-status-codes.xhtml
    if(status == 400) description = @"Bad Request";
    if(status == 401) description = @"Unauthorized";
    if(status == 402) description = @"Payment Required";
    if(status == 403) description = @"Forbidden";
    if(status == 404) description = @"Not Found";
    if(status == 405) description = @"Method Not Allowed";
    if(status == 406) description = @"Not Acceptable";
    if(status == 407) description = @"Proxy Authentication Required";
    if(status == 408) description = @"Request Timeout";
    if(status == 409) description = @"Conflict";
    if(status == 410) description = @"Gone";
    if(status == 411) description = @"Length Required";
    if(status == 412) description = @"Precondition Failed";
    if(status == 413) description = @"Payload Too Large";
    if(status == 414) description = @"URI Too Long";
    if(status == 415) description = @"Unsupported Media Type";
    if(status == 416) description = @"Requested Range Not Satisfiable";
    if(status == 417) description = @"Expectation Failed";
    if(status == 422) description = @"Unprocessable Entity";
    if(status == 423) description = @"Locked";
    if(status == 424) description = @"Failed Dependency";
    if(status == 425) description = @"Unassigned";
    if(status == 426) description = @"Upgrade Required";
    if(status == 427) description = @"Unassigned";
    if(status == 428) description = @"Precondition Required";
    if(status == 429) description = @"Too Many Requests";
    if(status == 430) description = @"Unassigned";
    if(status == 431) description = @"Request Header Fields Too Large";
    if(status == 432) description = @"Unassigned";
    if(status == 500) description = @"Internal Server Error";
    if(status == 501) description = @"Not Implemented";
    if(status == 502) description = @"Bad Gateway";
    if(status == 503) description = @"Service Unavailable";
    if(status == 504) description = @"Gateway Timeout";
    if(status == 505) description = @"HTTP Version Not Supported";
    if(status == 506) description = @"Variant Also Negotiates";
    if(status == 507) description = @"Insufficient Storage";
    if(status == 508) description = @"Loop Detected";
    if(status == 509) description = @"Unassigned";
    if(status == 510) description = @"Not Extended";
    if(status == 511) description = @"Network Authentication Required";
    
    if(description) {
        s = [s stringByAppendingFormat:@": %@", description];
    }
    
    return s;
}

#pragma mark Descriptions

- (NSString *)curlDescription {
    
    NSMutableArray *ma = [NSMutableArray array];
    [ma addObject:@"\U0001F300 curl -i"];
    
    if([_HTTPMethod isEqualToString:@"GET"] == NO) { // GET is optional in curl
        NSString *s = [NSString stringWithFormat:@"-X %@", _HTTPMethod];
        [ma addObject:s];
    }
    
    // -u username:password
    
    NSURLCredential *credential = [[self class] sessionAuthenticationCredentialsForURL:[self url]];
    if(credential) {
        NSString *s = [NSString stringWithFormat:@"-u \"%@:%@\"", credential.user, credential.password];
        [ma addObject:s];
    }
    
    // -d "k1=v1&k2=v2"                                             // POST, url encoded params
    
    if(_POSTDictionary) {
        NSMutableArray *postParameters = [NSMutableArray array];
        [_POSTDictionary enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            NSString *s = [NSString stringWithFormat:@"%@=%@", key, obj];
            [postParameters addObject:s];
        }];
        NSString *ss = [postParameters componentsJoinedByString:@"&"];
        [ma addObject:[NSString stringWithFormat:@"-d \"%@\"", ss]];
    }
    
    if(_rawPOSTData) {
        // try JSON
        id jsonObject;
        if (@available(macOS 10.7, *)) {
        	jsonObject = [NSJSONSerialization JSONObjectWithData:_rawPOSTData options:NSJSONReadingMutableContainers error:nil];
        } else {
        	jsonObject = nil;
        }
        if(jsonObject) {
            NSString *jsonString = [[NSString alloc] initWithData:_rawPOSTData encoding:NSUTF8StringEncoding];
            //            [ma addObject:@"-X POST"];
            [ma addObject:[NSString stringWithFormat:@"-d \'%@\'", jsonString]];
        }
    }
    
    // -F "coolfiles=@fil1.gif;type=image/gif,fil2.txt,fil3.html"   // file upload
    
    for(STHTTPRequestFileUpload *f in _filesToUpload) {
        NSString *s = [NSString stringWithFormat:@"%@=@%@", f.parameterName, f.path];
        [ma addObject:[NSString stringWithFormat:@"-F \"%@\"", s]];
    }
    
    // -H "X-you-and-me: yes"                                       // extra headers
    
    NSMutableDictionary *headers = [[_request allHTTPHeaderFields] mutableCopy];
    //    [headers removeObjectForKey:@"Cookie"];
    
    NSMutableArray *headersStrings = [NSMutableArray array];
    [headers enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSString *s = [NSString stringWithFormat:@"-H \"%@: %@\"", key, obj];
        [headersStrings addObject:s];
    }];
    
    if([headersStrings count] > 0) {
        [ma addObject:[headersStrings componentsJoinedByString:@" \\\n"]];
    }
    
    // url
    
    NSURL *url = [_request URL] ? [_request URL] : _url;
    [ma addObject:[NSString stringWithFormat:@"\"%@\"", url]];
    
    return [ma componentsJoinedByString:@" \\\n"];
}

- (NSString *)debugDescription {
    
    NSMutableString *ms = [NSMutableString string];
    
    NSString *method = (self.POSTDictionary || [self.filesToUpload count] || [self.dataToUpload count]) ? @"POST" : @"GET";
    
    [ms appendFormat:@"%@ %@\n", method, [_request URL]];
    
    NSMutableDictionary *headers = [[_request allHTTPHeaderFields] mutableCopy];
    
    if([headers count]) [ms appendString:@"HEADERS\n"];
    
    [headers enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        [ms appendFormat:@"\t %@ = %@\n", key, obj];
    }];
    
    NSArray *kvDictionaries = [[self class] dictionariesSortedByKey:_POSTDictionary];
    
    if([kvDictionaries count]) [ms appendString:@"POST DATA\n"];
    
    for(NSDictionary *kv in kvDictionaries) {
        NSString *k = [[kv allKeys] lastObject];
        NSString *v = [[kv allValues] lastObject];
        [ms appendFormat:@"\t %@ = %@\n", k, v];
    }
    
    for(STHTTPRequestFileUpload *f in self.filesToUpload) {
        [ms appendString:@"UPLOAD FILE\n"];
        [ms appendFormat:@"\t %@ = %@\n", f.parameterName, f.path];
    }
    
    for(STHTTPRequestDataUpload *d in self.dataToUpload) {
        [ms appendString:@"UPLOAD DATA\n"];
        [ms appendFormat:@"\t %@ = [%u bytes]\n", d.parameterName, (unsigned int)[d.data length]];
    }
    
    return ms;
}

- (NSError *)errorDescribingRequestNonfulfillment {
    if(_responseStatus < 400) return nil;
    
    NSDictionary *userInfo = @{
                               NSLocalizedDescriptionKey : [[self class] descriptionForHTTPStatus:_responseStatus],
                               @"headers": self.responseHeaders,
                               @"body": self.responseString
                               };
    
    return [NSError errorWithDomain:NSStringFromClass([self class]) code:_responseStatus userInfo:userInfo];
}

#pragma mark Start Request

- (void)startAsynchronous API_AVAILABLE(macos(10.9))
{
    
    NSAssert((self.completionBlock || self.completionDataBlock), @"a completion block is mandatory");
    NSAssert(self.errorBlock, @"the error block is mandatory");
    
    NSURLRequest *request = [self prepareURLRequest];
    
    NSURLSessionConfiguration *sessionConfiguration = nil;
    
    if(_useUploadTaskInBackground) {
        NSString *backgroundSessionIdentifier = [[NSProcessInfo processInfo] globallyUniqueString];
        if ([[NSURLSessionConfiguration class] respondsToSelector:@selector(backgroundSessionConfigurationWithIdentifier:)]) {
            // iOS 8+
            if (@available(macos 10.10, ios 8.0, *)) {
            	sessionConfiguration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:backgroundSessionIdentifier];
            } else {
            	sessionConfiguration = nil;
            }
        } else {
            // iOS 7
            sessionConfiguration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        }
    } else {
        sessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
    }
    
    sessionConfiguration.allowsCellularAccess = YES;
    
    NSString *containerIdentifier;
    if (@available(macos 10.10, *)) {
    	containerIdentifier = (_sharedContainerIdentifier
                               ? _sharedContainerIdentifier
                               : [[NSBundle mainBundle] bundleIdentifier]);
    	sessionConfiguration.sharedContainerIdentifier = containerIdentifier;
    } else {
    	containerIdentifier = NULL;
    }
    
    NSURLSession *session = [NSURLSession sessionWithConfiguration:sessionConfiguration
                                                          delegate:self
                                                     delegateQueue:nil];
    
    if(_useUploadTaskInBackground) {
        NSString *fileName = [[NSProcessInfo processInfo] globallyUniqueString];
        self.HTTPBodyFileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];
        [request.HTTPBody writeToURL:_HTTPBodyFileURL atomically:YES];
        self.task = [session uploadTaskWithRequest:request fromFile:_HTTPBodyFileURL];
    } else {
        self.task = [session dataTaskWithRequest:request];
    }
    
    [_task resume];
    
    self.request = [_task currentRequest];
    
    self.requestHeaders = [[_request allHTTPHeaderFields] mutableCopy];
    
    /**/
    
    BOOL showDebugDescription = [[NSUserDefaults standardUserDefaults] boolForKey:@"STHTTPRequestShowDebugDescription"];
    BOOL showCurlDescription = [[NSUserDefaults standardUserDefaults] boolForKey:@"STHTTPRequestShowCurlDescription"];
    
    NSMutableString *logString = nil;
    
    if(showDebugDescription || showCurlDescription) {
        logString = [NSMutableString stringWithString:@"\n----------\n"];
    }
    
    if(showDebugDescription) {
        [logString appendString:[self debugDescription]];
    }
    
    if(showDebugDescription && showCurlDescription) {
        [logString appendString:@"\n"];
    }
    
    if(showCurlDescription) {
        [logString appendString:[self curlDescription]];
    }
    
    if(showDebugDescription || showCurlDescription) {
        [logString appendString:@"\n----------\n"];
    }
    
    if(logString) NSLog(@"%@", logString);
    
    /**/
    
    if(_task == nil) {
        NSString *s = @"can't create task";
        self.error = [NSError errorWithDomain:NSStringFromClass([self class])
                                         code:0
                                     userInfo:@{NSLocalizedDescriptionKey: s}];
        
        self.errorBlock(self.error);
    }
}

// TODO: rewrite synch requests without NSURLConnection
- (NSString *)startSynchronousWithError:(NSError **)e {
    
    self.responseHeaders = nil;
    self.responseStatus = 0;
    
    NSURLRequest *request = [self prepareURLRequest];
    
    NSURLResponse *urlResponse = nil;
    
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&urlResponse error:e];
    
    self.responseData = [NSMutableData dataWithData:data];
    
    if([urlResponse isKindOfClass:[NSHTTPURLResponse class]]) {
        
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)urlResponse;
        
        self.responseHeaders = [httpResponse allHeaderFields];
        self.responseStatus = [httpResponse statusCode];
        self.responseStringEncodingName = [httpResponse textEncodingName];
    }
    
    self.responseString = [self stringWithData:_responseData encodingName:_responseStringEncodingName];
    
    if(_responseStatus >= 400) {
        if(e) *e = [self errorDescribingRequestNonfulfillment];
    }
    
    return _responseString;
}

- (void)cancel {
    [_task cancel];
    
    NSString *s = @"Connection was cancelled.";
    self.error = [NSError errorWithDomain:NSStringFromClass([self class])
                                     code:kSTHTTPRequestCancellationError
                                 userInfo:@{NSLocalizedDescriptionKey: s}];
    
    self.errorBlock(self.error);
}

+ (void)setBackgroundCompletionHandler:(void(^)(void))completionHandler forSessionIdentifier:(NSString *)sessionIdentifier {
    if(sessionCompletionHandlersForIdentifier == nil) {
        sessionCompletionHandlersForIdentifier = [NSMutableDictionary dictionary];
    }
    
    if (@available(macOS 10.8, *)) {
        sessionCompletionHandlersForIdentifier[sessionIdentifier] = [completionHandler copy];
    } else {
        // Fallback on earlier versions (???)
    }
}


#if __has_extension(blocks)
+ (void(^)(void))backgroundCompletionHandlerForSessionIdentifier:(NSString *)sessionIdentifier {
    if (@available(macOS 10.8, *)) {
        return sessionCompletionHandlersForIdentifier[sessionIdentifier];
    } else {
        return nil; // Fallback on earlier versions
    }
}
#endif

#ifdef OBJC_WEAK
# undef OBJC_WEAK
#endif /* OBJC_WEAK */
#if __has_feature(objc_arc) && __has_feature(objc_arc_weak)
# define OBJC_WEAK __weak
#else
# define OBJC_WEAK /* (nothing) */
#endif /* __has_feature(objc_arc) */

#pragma mark NSURLSessionDelegate

- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error  API_AVAILABLE(macos(10.9))
{
    
    OBJC_WEAK typeof(self) weakSelf = self;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if(strongSelf == nil) return;
        
        if(error == nil) return; // normal session invalidation, no error
        
        if(strongSelf.errorBlock) {
            strongSelf.errorBlock(error);
        }
    });
}

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
API_AVAILABLE(macos(10.9))
{
    // accept self-signed SSL certificates
    if([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        OSStatus err;
        NSURLProtectionSpace *protectionSpace = challenge.protectionSpace;
        SecTrustRef trust = protectionSpace.serverTrust;
        SecTrustResultType trustResult;
        BOOL trusted = NO;
        
        err = SecTrustEvaluate(trust, &trustResult);

        if (err) {
            ; // (???)
        }
        
        if (trustResult == kSecTrustResultProceed || trustResult == kSecTrustResultUnspecified) {
            trusted = YES;
        }
        
        if (!trusted) {
            NSLog(@"Certificate not trusted (yet)");
            if (SecTrustGetCertificateCount(trust) > 0) {
                SecCertificateRef cert = SecTrustGetCertificateAtIndex(trust, 0);
                NSData *certificateData = (NSData *)CFBridgingRelease(SecCertificateCopyData(cert));

                unsigned char result[CC_SHA256_DIGEST_LENGTH];
                CC_SHA256(certificateData.bytes, (CC_LONG)certificateData.length, result);
                
                NSMutableString *fingerprint = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
                for (unsigned int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) {
                    [fingerprint appendFormat:@"%02X", result[i]];
                    if (i != (CC_SHA256_DIGEST_LENGTH - 1))
                        [fingerprint appendString:@":"];
                }
                
                __block NSModalResponse userReturnCode;
                
                dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSAlert *alert = [[NSAlert alloc] init];
                        [alert addButtonWithTitle:@"Cancel"];
                        [alert addButtonWithTitle:@"Trust"];
                        [alert setMessageText:@"Trust this server?"];
                        [alert setInformativeText:[NSString stringWithFormat:@"This server has a self-signed certificate with a SHA-256 fingerprint of %@. Are you sure you wish to trust this server?", fingerprint]];
                        [alert setAlertStyle:NSWarningAlertStyle];
                        [alert beginSheetModalForWindow:[[NSApplication sharedApplication] mainWindow] completionHandler:^(NSModalResponse returnCode) {
                            userReturnCode = returnCode;
                            dispatch_semaphore_signal(sema);
                        }];
                    });
                    
                    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
                });

                if (userReturnCode == NSAlertSecondButtonReturn) {
                    err = SecCertificateAddToKeychain(cert, NULL);
                    NSLog(@"SecCertificateAddToKeychain = %d", err);
                    
                    NSDictionary* settings = nil;
                    err = SecTrustSettingsSetTrustSettings(cert, kSecTrustSettingsDomainUser, (__bridge CFTypeRef)(settings));
                    NSLog(@"SecTrustSettingsSetTrustSettings = %d", err);
                    
                    CFArrayRef trustSettings = nil;
                    err = SecTrustSettingsCopyTrustSettings(cert, kSecTrustSettingsDomainUser, &trustSettings);
                    NSLog(@"SecTrustSettingsCopyTrustSettings = %d %@", err, trustSettings);
                    
                    CFArrayRef certs = CFArrayCreate(kCFAllocatorDefault, (const void**)&cert, 1, &kCFTypeArrayCallBacks);
                    err = SecTrustSetAnchorCertificates(trust, certs);
                    CFRelease(certs);
                    NSLog(@"SecTrustSetAnchorCertificates = %d", err);
                    
                    trusted = YES;
                }
            }
        }
            
        err = SecTrustEvaluate(trust, &trustResult);

        if (err) {
            ; // (???)
        }

        if (trustResult == kSecTrustResultProceed || trustResult == kSecTrustResultUnspecified) {
            NSURLCredential *credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
            completionHandler(NSURLSessionAuthChallengeUseCredential,credential);
            return;
        }

        (void)trusted;
    }
            
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session API_AVAILABLE(macos(10.9), ios(7.0), watchos(2.0), tvos(9.0))
{
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        void (^completionHandler)(void) = sessionCompletionHandlersForIdentifier[session.configuration.identifier];
        
        if(completionHandler) {
            completionHandler();
            [sessionCompletionHandlersForIdentifier removeObjectForKey:session.configuration.identifier];
        }
        
    });
}

#pragma mark NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler API_AVAILABLE(macos(10.9))
 {
    
    OBJC_WEAK typeof(self) weakSelf = self;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        NSURLRequest *actualRequest = weakSelf.preventRedirections ? nil : request;
        
        completionHandler(actualRequest);
        
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend API_AVAILABLE(macos(10.9))
{
    
    OBJC_WEAK typeof(self) weakSelf = self;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if(strongSelf == nil) return;
        
        if(strongSelf.uploadProgressBlock) {
            strongSelf.uploadProgressBlock(bytesSent, totalBytesSent, totalBytesExpectedToSend);
        }
        
    });
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error_in API_AVAILABLE(macos(10.9))
{
    
    OBJC_WEAK typeof(self) weakSelf = self;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if(strongSelf == nil) return;
        
        if (error_in) {
            strongSelf.errorBlock(error_in);
            [session finishTasksAndInvalidate];
            return;
        }
        
        if([task.response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *r = (NSHTTPURLResponse *)[task response];
            strongSelf.responseHeaders = [r allHeaderFields];
            strongSelf.responseStatus = [r statusCode];
            strongSelf.responseStringEncodingName = [r textEncodingName];
            strongSelf.responseExpectedContentLength = [r expectedContentLength];
        } else {
            NSDictionary *userInfo = @{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"bad response class: %@", [task.response class]]};
            NSError *e = [NSError errorWithDomain:NSStringFromClass([strongSelf class]) code:0 userInfo:userInfo];
            strongSelf.errorBlock(e);
            [session finishTasksAndInvalidate];
            return;
        }
        
        if(strongSelf.HTTPBodyFileURL) {
            NSError *error_local = nil;
            BOOL status = [[NSFileManager defaultManager] removeItemAtURL:strongSelf.HTTPBodyFileURL error:&error_local];
            if(status == NO) {
                NSLog(@"-- cannot remove %@, %@", strongSelf.HTTPBodyFileURL, [error_local localizedDescription]);
            }
        }
        
        if(strongSelf.responseStatus >= 400) {
            strongSelf.error = [strongSelf errorDescribingRequestNonfulfillment];
            strongSelf.errorBlock(strongSelf.error);
            [session finishTasksAndInvalidate];
            return;
        }
        
        if(strongSelf.completionDataBlock) {
            strongSelf.completionDataBlock(strongSelf.responseHeaders,strongSelf.responseData);
        }
        
        if(strongSelf.completionBlock) {
            NSString *responseString = [strongSelf stringWithData:strongSelf.responseData encodingName:strongSelf.responseStringEncodingName];
            strongSelf.completionBlock(strongSelf.responseHeaders, responseString);
        }
        
        [session finishTasksAndInvalidate];
    });
}

- (NSString *)startSynchronousSessionWithError:(NSError **)error
{
    NSURLRequest *request = [self prepareURLRequest];
    __block NSURLResponse   *urlResponse = nil;
    dispatch_semaphore_t    sem;
    __block NSData          *result = nil;
    __block NSError         *blkErr = nil;
    
    sem = dispatch_semaphore_create(0);

    NSURLSessionConfiguration *defaultConfigObject;
    if (@available(macOS 10.9, *)) {
    	defaultConfigObject = [NSURLSessionConfiguration defaultSessionConfiguration];
    } else {
    	defaultConfigObject = nil;
    }
    NSURLSession *defaultSession;
    if (@available(macOS 10.9, *)) {
        defaultSession = [NSURLSession sessionWithConfiguration:defaultConfigObject delegate:self delegateQueue:nil];
    } else {
        defaultSession = nil; // Fallback on earlier versions
    }
    
    [[defaultSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *err)
      {
          if (err) {
              blkErr = err;
          }
          
          urlResponse = response;
          
          if (err == nil) {
              result = data;
          }
          
          dispatch_semaphore_signal(sem);
      }] resume];
    
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    
    // If Error, return error
    if (blkErr) {
        if (error != NULL) *error = blkErr;
        return nil;
    }
    
    if (urlResponse)
    {
        if([urlResponse isKindOfClass:[NSHTTPURLResponse class]])
        {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)urlResponse;
            self.responseHeaders = [httpResponse allHeaderFields];
            self.responseStatus = [httpResponse statusCode];
            self.responseStringEncodingName = [httpResponse textEncodingName];
        }
    }
    
    self.responseString = [self stringWithData:result encodingName:_responseStringEncodingName];
    self.responseData = ((result != nil) ? [NSMutableData dataWithData:result] : nil);
    if(self.responseStatus >= 400) {
        if (error != NULL) *error = [self errorDescribingRequestNonfulfillment];
    }
    
    return _responseString;
}

#pragma mark NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler API_AVAILABLE(macos(10.9))
 {
    
    OBJC_WEAK typeof(self) weakSelf = self;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if(strongSelf == nil) return;
        
        if([dataTask.response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *r = (NSHTTPURLResponse *)[dataTask response];
            
            strongSelf.responseHeaders = [r allHeaderFields];
            strongSelf.responseStatus = [r statusCode];
            strongSelf.responseStringEncodingName = [r textEncodingName];
            strongSelf.responseExpectedContentLength = [r expectedContentLength];
            
            NSArray *responseCookies = [NSHTTPCookie cookiesWithResponseHeaderFields:strongSelf.responseHeaders forURL:dataTask.currentRequest.URL];
            for(NSHTTPCookie *cookie in responseCookies) {
                //NSLog(@"-- %@", cookie);
                [strongSelf addCookie:cookie]; // won't store anything when STHTTPRequestCookiesStorageNoStorage
            }
        }
        
        completionHandler(NSURLSessionResponseAllow);
    });
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data API_AVAILABLE(macos(10.9))
{
    
    OBJC_WEAK typeof(self) weakSelf = self;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if(strongSelf == nil) return;
        
        [strongSelf.responseData appendData:data];
        
        if (strongSelf.downloadProgressBlock) {
            strongSelf.downloadProgressBlock(data, [strongSelf.responseData length], strongSelf.responseExpectedContentLength);
        }
        
    });
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler  API_AVAILABLE(macos(10.9))
 {
    
    OBJC_WEAK typeof(self) weakSelf = self;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if(strongSelf == nil) return;
        
        NSCachedURLResponse *actualResponse = (globalIgnoreCache || strongSelf.ignoreCache) ? nil : proposedResponse;
        
        completionHandler(actualResponse);
        
    });
}

@end

@implementation NSError (STHTTPRequest)

- (BOOL)st_isAuthenticationError {
    
    if ([[self domain] isEqualToString:@"STHTTPRequest"] && ([self code] == 401)) return YES;
    
    if ([[self domain] isEqualToString:NSURLErrorDomain] && ([self code] == kCFURLErrorUserCancelledAuthentication || [self code] == kCFURLErrorUserAuthenticationRequired)) return YES;
    
    return NO;
}

- (BOOL)st_isCancellationError {
    return ([[self domain] isEqualToString:@"STHTTPRequest"] && [self code] == kSTHTTPRequestCancellationError);
}

@end

@implementation NSString (RFC3986)
- (NSString *)st_stringByAddingRFC3986PercentEscapesUsingEncoding:(NSStringEncoding)encoding {
    
    NSString *s = (__bridge_transfer NSString *)(CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                                                                         (CFStringRef)self,
                                                                                         NULL,
                                                                                         CFSTR("!*'();:@&=+$,/?%#[]"),
                                                                                         kCFStringEncodingUTF8));
    return s;
}
@end

/**/

@implementation NSString (STUtilities)

- (NSString *)st_stringByAppendingGETParameters:(NSDictionary *)parameters doApplyURLEncoding:(BOOL)doApplyURLEncoding {
    
    NSMutableString *ms = [self mutableCopy];
    
    __block BOOL questionMarkFound = NO;
    
    NSArray *sortedParameters = [STHTTPRequest dictionariesSortedByKey:parameters];
    
    [sortedParameters enumerateObjectsUsingBlock:^(NSDictionary *d, NSUInteger idx, BOOL *stop) {
        
        NSString *key = [[d allKeys] lastObject];
        NSString *value = [[[d allValues] lastObject] description];
        
        if(questionMarkFound == NO) {
            questionMarkFound = [ms rangeOfString:@"?"].location != NSNotFound;
        }
        
        [ms appendString: (questionMarkFound ? @"&" : @"?") ];
        
        if(doApplyURLEncoding) {
            key = [key st_stringByAddingRFC3986PercentEscapesUsingEncoding:NSUTF8StringEncoding];
            value = [value st_stringByAddingRFC3986PercentEscapesUsingEncoding:NSUTF8StringEncoding];
        }
        
        [ms appendFormat:@"%@=%@", key, value];
    }];
    
    return ms;
}

@end

@implementation STHTTPRequestFileUpload

+ (instancetype)fileUploadWithPath:(NSString *)path parameterName:(NSString *)parameterName mimeType:(NSString *)mimeType {
    STHTTPRequestFileUpload *fu = [[self alloc] init];
    fu.path = path;
    fu.parameterName = parameterName;
    fu.mimeType = mimeType;
    return fu;
}

+ (instancetype)fileUploadWithPath:(NSString *)path parameterName:(NSString *)fileName {
    return [self fileUploadWithPath:path parameterName:fileName mimeType:@"application/octet-stream"];
}

@end

@implementation STHTTPRequestDataUpload

+ (instancetype)dataUploadWithData:(NSData *)data parameterName:(NSString *)parameterName mimeType:(NSString *)mimeType fileName:(NSString *)fileName {
    STHTTPRequestDataUpload *du = [[self alloc] init];
    du.data = data;
    du.parameterName = parameterName;
    du.mimeType = mimeType;
    du.fileName = fileName;
    return du;
}

@end
