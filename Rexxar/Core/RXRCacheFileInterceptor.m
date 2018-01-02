//
//  RXRCacheFileInterceptor.m
//  Rexxar
//
//  Created by Tony Li on 11/4/15.
//  Copyright © 2015 Douban Inc. All rights reserved.
//

#import "RXRCacheFileInterceptor.h"
#import "NSHTTPURLResponse+Rexxar.h"
#import "RXRURLSessionDemux.h"
#import "RXRRouteFileCache.h"
#import "RXRLogger.h"
#import "NSURL+Rexxar.h"

static NSString * const RXRCacheFileIntercepterHandledKey = @"RXRCacheFileIntercepterHandledKey";
static NSInteger sRegisterInterceptorCounter;

@interface RXRCacheFileInterceptor () <NSURLSessionTaskDelegate, NSURLSessionDataDelegate>

@property (nonatomic, strong) NSURLSessionTask *dataTask;
@property (nonatomic, copy) NSArray *modes;
@property (nonatomic, strong) NSFileHandle *fileHandle;
@property (nonatomic, copy) NSString *responseDataFilePath;

@end


@implementation RXRCacheFileInterceptor

+ (RXRURLSessionDemux *)sharedDemux
{
  static dispatch_once_t onceToken;
  static RXRURLSessionDemux *demux;

  dispatch_once(&onceToken, ^{
    NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
    demux = [[RXRURLSessionDemux alloc] initWithSessionConfiguration:sessionConfiguration];
  });

  return demux;
}

+ (BOOL)registerInterceptor
{
  BOOL result = NO;
  if (sRegisterInterceptorCounter <= 0) {
    result = [NSURLProtocol registerClass:[self class]];
    if (result) {
      sRegisterInterceptorCounter = 1;
    }
  }
  else {
    sRegisterInterceptorCounter++;
    result = YES;
  }
  return result;
}

+ (void)unregisterInterceptor
{
  sRegisterInterceptorCounter--;
  if (sRegisterInterceptorCounter < 0) {
    sRegisterInterceptorCounter = 0;
  }

  if (sRegisterInterceptorCounter == 0) {
    [NSURLProtocol unregisterClass:[self class]];
  }
}


#pragma mark - NSURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
  // 不是 HTTP 请求，不处理
  if (![request.URL rxr_isHttpOrHttps]) {
    return NO;
  }
  // 请求被忽略（被标记为忽略或者已经请求过），不处理
  if ([self isRequestIgnored:request]) {
    return NO;
  }
  // 请求不是来自浏览器，不处理
  if (![request.allHTTPHeaderFields[@"User-Agent"] hasPrefix:@"Mozilla"]) {
    return NO;
  }

  // 如果请求不需要被拦截，不处理
  if (![self shouldInterceptRequest:request]) {
    return NO;
  }

  return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
  return request;
}

- (void)startLoading
{
  NSParameterAssert(self.dataTask == nil);

  RXRDebugLog(@"Intercept <%@> within <%@>", self.request.URL, self.request.mainDocumentURL);

  NSMutableURLRequest *newRequest = nil;
  if ([self.request isKindOfClass:[NSMutableURLRequest class]]) {
    newRequest = (NSMutableURLRequest *)self.request;
  } else {
    newRequest = [self.request mutableCopy];
  }

  NSURL *localURL = [[self class] _rxr_localFileURL:self.request.URL];
  if (localURL) {
    newRequest.URL = localURL;
  }

  [[self class] markRequestAsIgnored:newRequest];

  NSMutableArray *modes = [NSMutableArray array];
  [modes addObject:NSDefaultRunLoopMode];

  NSString *currentMode = [[NSRunLoop currentRunLoop] currentMode];
  if (currentMode != nil && ![currentMode isEqualToString:NSDefaultRunLoopMode]) {
    [modes addObject:currentMode];
  }
  [self setModes:modes];

  NSURLSessionTask *dataTask = [[[self class] sharedDemux] dataTaskWithRequest:newRequest delegate:self modes:self.modes];
  [dataTask resume];
  [self setDataTask:dataTask];
}

- (void)stopLoading
{
  if (self.dataTask != nil) {
    [self.dataTask cancel];
    [self setDataTask:nil];
  }
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(nonnull NSHTTPURLResponse *)response
        newRequest:(nonnull NSURLRequest *)request
 completionHandler:(nonnull void (^)(NSURLRequest * _Nullable))completionHandler
{
  if (self.client != nil && self.dataTask == task) {
    NSMutableURLRequest *mutableRequest = [request mutableCopy];
    [[self class] unmarkRequestAsIgnored:mutableRequest];
    [self.client URLProtocol:self wasRedirectedToRequest:mutableRequest redirectResponse:response];

    NSError *error = [[NSError alloc] initWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
    [self.dataTask cancel];
    [self.client URLProtocol:self didFailWithError:error];
  }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler
{
  NSURLRequest *request = dataTask.currentRequest;

  if (![request.URL isFileURL] &&
      [[self class] shouldInterceptRequest:request] &&
      [[self class] _rxr_isCacheableResponse:response]) {
    self.responseDataFilePath = [self _rxr_temporaryFilePath];
    [[NSFileManager defaultManager] createFileAtPath:self.responseDataFilePath contents:nil attributes:nil];
    self.fileHandle = nil;
    self.fileHandle = [NSFileHandle fileHandleForWritingAtPath:self.responseDataFilePath];
  }

  NSHTTPURLResponse *URLResponse = nil;
  if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
    URLResponse = (NSHTTPURLResponse *)response;
    URLResponse = [NSHTTPURLResponse rxr_responseWithURL:URLResponse.URL
                                              statusCode:URLResponse.statusCode
                                            headerFields:URLResponse.allHeaderFields
                                         noAccessControl:YES];
  }
  [self.client URLProtocol:self
        didReceiveResponse:URLResponse ?: response
        cacheStoragePolicy:NSURLCacheStorageNotAllowed];
  completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
  if ([[self class] shouldInterceptRequest:dataTask.currentRequest] && self.fileHandle) {
    [self.fileHandle writeData:data];
  }
  [self.client URLProtocol:self didLoadData:data];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(nullable NSError *)error
{
  if (self.client != nil && (_dataTask == nil || _dataTask == task)) {
    if (error == nil) {
      if ([[self class] shouldInterceptRequest:task.currentRequest] && self.fileHandle) {
        [self.fileHandle closeFile];
        self.fileHandle = nil;
        NSData *data = [NSData dataWithContentsOfFile:self.responseDataFilePath];
        [[RXRRouteFileCache sharedInstance] saveRouteFileData:data withRemoteURL:task.currentRequest.URL];
      }
      [self.client URLProtocolDidFinishLoading:self];
    } else {
      if ([[self class] shouldInterceptRequest:task.currentRequest] && self.fileHandle) {
        [self.fileHandle closeFile];
        self.fileHandle = nil;
        [[NSFileManager defaultManager] removeItemAtPath:self.responseDataFilePath error:nil];
      }

      if ([error.domain isEqual:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
        // Do nothing.
      } else {
        [self.client URLProtocol:self didFailWithError:error];
      }
    }
  }
}

#pragma mark - Public methods

+ (BOOL)shouldInterceptRequest:(NSURLRequest *)request
{
  NSString *extension = request.URL.pathExtension;
  if ([extension isEqualToString:@"js"] ||
      [extension isEqualToString:@"css"] ||
      [extension isEqualToString:@"html"]) {
    return YES;
  }
  return NO;
}

+ (void)markRequestAsIgnored:(NSMutableURLRequest *)request
{
  [NSURLProtocol setProperty:@YES forKey:RXRCacheFileIntercepterHandledKey inRequest:request];
}

+ (void)unmarkRequestAsIgnored:(NSMutableURLRequest *)request
{
  [NSURLProtocol removePropertyForKey:RXRCacheFileIntercepterHandledKey inRequest:request];
}

+ (BOOL)isRequestIgnored:(NSURLRequest *)request
{
  if ([NSURLProtocol propertyForKey:RXRCacheFileIntercepterHandledKey inRequest:request]) {
    return YES;
  }
  return NO;
}

#pragma mark - Private methods

+ (NSURL *)_rxr_localFileURL:(NSURL *)remoteURL
{
  NSURL *URL = [[NSURL alloc] initWithScheme:[remoteURL scheme]
                                        host:[remoteURL host]
                                        path:[remoteURL path]];
  NSURL *localURL = [[RXRRouteFileCache sharedInstance] routeFileURLForRemoteURL:URL];
  return localURL;
}

+ (BOOL)_rxr_isCacheableResponse:(NSURLResponse *)response
{
  NSSet *cacheableTypes = [NSSet setWithObjects:@"application/javascript", @"application/x-javascript",
                           @"text/javascript", @"text/css", @"text/html", nil];
  return [cacheableTypes containsObject:response.MIMEType];
}

- (NSString *)_rxr_temporaryFilePath
{
  NSString *fileName = [[NSUUID UUID] UUIDString];
  return [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
}

@end
