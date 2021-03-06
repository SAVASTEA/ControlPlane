//
//  IPAddrEvidenceSource.m
//  ControlPlane
//
//  Created by Vladimir Beloborodov on 18 Apr 2013.
//

#import <arpa/inet.h>
#import <SystemConfiguration/SystemConfiguration.h>

#import "IPAddrEvidenceSource.h"
#import "IPv4RuleType.h"
#import "IPv6RuleType.h"


#pragma mark Packed IP Addresses

@implementation PackedIPv4Address {
    struct in_addr ipAddr;
}

- (id)initWithString:(NSString *)description {
    self = [super init];
    if (self) {
        if (inet_pton(AF_INET, [description UTF8String], &ipAddr) != 1) {
            [self release];
            return nil;
        }
    }
    return self;
}

- (const struct in_addr *)inAddr {
    return &ipAddr;
}

@end

@implementation PackedIPv6Address {
    struct in6_addr ipAddr;
}

- (id)initWithString:(NSString *)description {
    self = [super init];
    if (self) {
        if (inet_pton(AF_INET6, [description UTF8String], &ipAddr) != 1) {
            [self release];
            return nil;
        }
    }
    return self;
}

- (const struct in6_addr *)inAddr {
    return &ipAddr;
}

@end


#pragma mark IP Address Evidence Source

static char * const queueIsStopped = "queueIsStopped";


@interface IPAddrEvidenceSource ()

@property (atomic, retain, readwrite) NSArray *stringIPv4Addresses;
@property (atomic, retain, readwrite) NSArray *packedIPv4Addresses;

@property (atomic, retain, readwrite) NSArray *stringIPv6Addresses;
@property (atomic, retain, readwrite) NSArray *packedIPv6Addresses;

- (void)enumerate;

@end


#pragma mark C callbacks

static void ipAddrChange(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info) {
    if (dispatch_get_specific(queueIsStopped) != queueIsStopped) {
        @autoreleasepool {
#ifdef DEBUG_MODE
            NSLog(@"ipAddrChange called with changedKeys:\n%@", changedKeys);
#endif
            [(IPAddrEvidenceSource *) info enumerate];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"evidenceSourceDataDidChange" object:nil];
        }
    }
}


@implementation IPAddrEvidenceSource {
    // for SystemConfiguration asynchronous notifications
    SCDynamicStoreRef store;
    dispatch_queue_t serialQueue;
}

@synthesize stringIPv4Addresses = _stringIPv4Addresses;
@synthesize packedIPv4Addresses = _packedIPv4Addresses;

@synthesize stringIPv6Addresses = _stringIPv6Addresses;
@synthesize packedIPv6Addresses = _packedIPv6Addresses;

- (id)init {
    self = [super initWithRules:@[ [IPv4RuleType class], [IPv6RuleType class] ]];
    if (!self) {
        return nil;
    }

	return self;
}

- (void)dealloc {
    [self doStop];

    [_stringIPv4Addresses release];
    [_packedIPv4Addresses release];
    
    [_stringIPv6Addresses release];
    [_packedIPv6Addresses release];
    
	[super dealloc];
}


- (NSString *) description {
    return NSLocalizedString(@"Create rules based on the IPv4 or IPv6 address assigned to your Mac.", @"");
}

- (void)removeAllDataCollected {
    self.stringIPv4Addresses = nil;
    self.packedIPv4Addresses = nil;
    self.stringIPv6Addresses = nil;
    self.packedIPv6Addresses = nil;
    [self setDataCollected:NO];
}

static BOOL isAllowedIPv4Address(PackedIPv4Address *ipv4) {
    const in_addr_t addr = ntohl([ipv4 inAddr]->s_addr);
    if (IN_LOOPBACK(addr) || IN_LINKLOCAL(addr) || IN_MULTICAST(addr)) {
        return NO;
    }
    return YES;
}

static BOOL isAllowedIPv6Address(PackedIPv6Address *ipv6) {
    const struct in6_addr *addr = [ipv6 inAddr];
    if (IN6_IS_ADDR_LOOPBACK(addr) || IN6_IS_ADDR_LINKLOCAL(addr) || IN6_IS_ADDR_MULTICAST(addr)) {
        return NO;
    }
    return YES;
}

- (void)enumerateIPv4Addresses:(NSArray *)addresses
                    usingBlock:(void (^)(NSString *strIPAddr, PackedIPv4Address *ipAddr))block {
    for (NSString *addr in addresses) {
        PackedIPv4Address *packedAddr = [[PackedIPv4Address alloc] initWithString:addr];
        if (packedAddr) {
            if (isAllowedIPv4Address(packedAddr)) {
                block(addr, packedAddr);
            }
            [packedAddr release];
        }
    }
}

- (void)enumerateIPv6Addresses:(NSArray *)addresses
                    usingBlock:(void (^)(NSString *strIPAddr, PackedIPv6Address *ipAddr))block {
    for (NSString *addr in addresses) {
        PackedIPv6Address *packedAddr = [[PackedIPv6Address alloc] initWithString:addr];
        if (packedAddr) {
            if (isAllowedIPv6Address(packedAddr)) {
                block(addr, packedAddr);
            }
            [packedAddr release];
        }
    }
}

static NSComparator descendingSorter = ^NSComparisonResult(id obj1, id obj2) {
    return [(NSString * )obj2 compare:obj1]; // descending
};

- (void)enumerate {
    NSArray *ipKeyPatterns = @[ @"State:/Network/Interface/[^/]+/IPv." ];
    NSDictionary *dict = (NSDictionary *) SCDynamicStoreCopyMultiple(store, NULL, (CFArrayRef) ipKeyPatterns);
    if (!dict) {
        [self removeAllDataCollected];
        return;
    }

    NSMutableArray *stringIPv4Addresses = [NSMutableArray array], *packedIPv4Addresses = [NSMutableArray array];
    NSMutableArray *stringIPv6Addresses = [NSMutableArray array], *packedIPv6Addresses = [NSMutableArray array];

    [dict enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *ipParams, BOOL *stop) {
        NSArray *addresses = ipParams[@"Addresses"];

        if ([key hasSuffix:@"4"]) { // IPv4
            [self enumerateIPv4Addresses:addresses usingBlock:^(NSString *strIPAddr, PackedIPv4Address *ipAddr) {
                [stringIPv4Addresses addObject:strIPAddr];
                [packedIPv4Addresses addObject:ipAddr];
            }];
        } else { // IPv6
            [self enumerateIPv6Addresses:addresses usingBlock:^(NSString *strIPAddr, PackedIPv6Address *ipAddr) {
                [stringIPv6Addresses addObject:strIPAddr];
                [packedIPv6Addresses addObject:ipAddr];
            }];
        }
    }];

    CFRelease((CFDictionaryRef) dict);

    [stringIPv4Addresses sortUsingComparator:descendingSorter];
    [stringIPv6Addresses sortUsingComparator:descendingSorter];

    self.stringIPv4Addresses = stringIPv4Addresses;
    self.packedIPv4Addresses = packedIPv4Addresses;
    self.stringIPv6Addresses = stringIPv6Addresses;
    self.packedIPv6Addresses = packedIPv6Addresses;
    [self setDataCollected:(([packedIPv4Addresses count] > 0) || ([packedIPv6Addresses count] > 0))];
}

- (void)start {
	if (running) {
		return;
    }

    serialQueue = dispatch_queue_create("com.dustinrue.ControlPlane.IPAddrEvidenceSource",
                                        DISPATCH_QUEUE_SERIAL);
    if (!serialQueue) {
        [self doStop];
        return;
    }

	// Register for asynchronous notifications
	SCDynamicStoreContext ctxt = {0, self, NULL, NULL, NULL}; // {version, info, retain, release, copyDescription}
	store = SCDynamicStoreCreate(NULL, CFSTR("ControlPlane"), ipAddrChange, &ctxt);
    if (!store) {
        [self doStop];
        return;
    }
    
    if (!SCDynamicStoreSetDispatchQueue(store, serialQueue)) {
        [self doStop];
        return;
    }

    NSArray *ipKeyPatterns = @[ @"State:/Network/Interface/[^/]+/IPv." ];
	if (!SCDynamicStoreSetNotificationKeys(store, NULL, (CFArrayRef) ipKeyPatterns)) {
        [self doStop];
        return;
    }

    dispatch_async(serialQueue, ^{
        if (dispatch_get_specific(queueIsStopped) != queueIsStopped) {
            @autoreleasepool {
                [self enumerate];
            }
        }
    });

	running = YES;
}

- (void)stop {
	if (running) {
        [self doStop];
    }
}

- (void)doStop {
    if (serialQueue) {
        if (store) {
            dispatch_suspend(serialQueue);

            SCDynamicStoreSetDispatchQueue(store, NULL);

            dispatch_queue_set_specific(serialQueue, queueIsStopped, queueIsStopped, NULL);
            dispatch_resume(serialQueue);
        }

        dispatch_release(serialQueue);
        serialQueue = NULL;
    }

    if (store) {
        CFRelease(store);
        store = NULL;
    }

    [self removeAllDataCollected];

	running = NO;
}

- (NSString *)name {
	return @"IPAddr";
}

- (NSString *)friendlyName {
    return NSLocalizedString(@"Assigned IP Address", @"");
}

@end
