//
//  Corellium.h
//  USBFlux
//
//  Created by Nikias Bassen on 26.09.18.
//  Copyright © 2018 Corellium. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface Corellium : NSObject <NSURLConnectionDelegate>
@property (nonatomic, copy) NSString *domain;
@property (assign) NSString *username;
@property (assign) NSString *password;
@property (assign) NSString *endpoint;
@property (assign) id token;
-(id)initWithDomain:(NSString*)domain username:(NSString*)username password:(NSString*)password;
-(BOOL)login:(NSError**)error;
-(id)projects:(NSError**)error;
-(id)instances:(NSError**)error;
-(id)instances:(NSError**)error withQuery:(NSString*)query;
@end
