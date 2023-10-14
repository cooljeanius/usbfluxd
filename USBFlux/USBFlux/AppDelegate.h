//
//  AppDelegate.h
//  USBFlux
//
//  Created by Nikias Bassen on 30.05.18.
//  Copyright © 2018 Corellium. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>

extern NSDictionary* usbfluxdQuery(const char* req_xml, uint32_t req_len);

@end

