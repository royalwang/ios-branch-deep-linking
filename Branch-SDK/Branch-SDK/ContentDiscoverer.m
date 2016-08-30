//
//  ContentDiscoverer.m
//  Branch-TestBed
//
//  Created by Sojan P.R. on 8/17/16.
//  Copyright © 2016 Branch Metrics. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "ContentDiscoverer.h"
#import "ContentDiscoveryManifest.h"
#import "ContentPathProperties.h"
#import "BNCPreferenceHelper.h"
#import "BranchConstants.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>

@interface ContentDiscoverer ()

@property (nonatomic, strong) UIViewController *lastViewController;
@property (nonatomic, strong) NSTimer *contentDiscoveryTimer;
@property (nonatomic, strong) ContentDiscoveryManifest *cdManifest;
@property (nonatomic) NSInteger numOfViewsDiscovered;

@end


@implementation ContentDiscoverer

static ContentDiscoverer *contentViewHandler;
static NSInteger const CONTENT_DISCOVERY_INTERVAL = 5;


+ (ContentDiscoverer *)getInstance:(ContentDiscoveryManifest *)manifest {
    if (!contentViewHandler) {
        contentViewHandler = [[ContentDiscoverer alloc] init];
    }
    [contentViewHandler initInstance:manifest];
    return contentViewHandler;
}

+ (ContentDiscoverer *)getInstance {
    return contentViewHandler;
}

- (void)initInstance:(ContentDiscoveryManifest *)manifest {
    _numOfViewsDiscovered = 0;
    _cdManifest = manifest;
    
}

- (void)startContentDiscoveryTask {
    _contentDiscoveryTimer = [NSTimer scheduledTimerWithTimeInterval:CONTENT_DISCOVERY_INTERVAL
                                                              target:self
                                                            selector:@selector(readContentDataIfNeeded)
                                                            userInfo:nil
                                                             repeats:YES];
}

- (void)stopContentDiscoveryTask {
    _lastViewController = nil;
    if (_contentDiscoveryTimer) {
        [_contentDiscoveryTimer invalidate];
    }
}

- (void)readContentDataIfNeeded {
    if (_numOfViewsDiscovered < _cdManifest.maxViewHistoryLength) {
        UIViewController *presentingViewController = [self getActiveViewController];
        if (_lastViewController == nil || (_lastViewController.class != presentingViewController.class)) {
            _lastViewController = presentingViewController;
            [self readContentData];
        }
    } else {
        [self stopContentDiscoveryTask];
    }
}

- (void)readContentData {
    UIViewController *viewController = _lastViewController;
    if (viewController) {
        UIView *rootView = [viewController view];
        if ([viewController isKindOfClass:UITableViewController.class]) {
            rootView = ((UITableViewController *)viewController).tableView;
        } else if ([viewController isKindOfClass:UICollectionViewController.class]) {
            rootView = ((UICollectionViewController *)viewController).collectionView;
        }
        
        NSMutableArray *contentDataArray = [[NSMutableArray alloc] init];
        NSMutableArray *contentKeysArray = [[NSMutableArray alloc] init];
        BOOL isClearText = YES;
        
        if (rootView) {
            ContentPathProperties *pathProperties = [_cdManifest getContentPathProperties:viewController];
            // Check for any existing path properties for this ViewController
            if (pathProperties) {
                isClearText = pathProperties.isClearText;
                if (!pathProperties.isSkipContentDiscovery) {
                    NSArray *filteredKeys = [pathProperties getFilteredElements];
                    if (filteredKeys == nil || filteredKeys.count == 0) {
                        [self discoverViewContents:rootView contentData:nil contentKeys:contentKeysArray clearText:isClearText ID:@""];
                    } else {
                        contentKeysArray = filteredKeys.mutableCopy;
                        [self discoverFilteredViewContents:contentDataArray contentKeys:contentKeysArray clearText:isClearText];
                    }
                }
            } else if (_cdManifest.referredLink) { // else discover content if this session is started by a link click
                [self discoverViewContents:rootView contentData:nil contentKeys:contentKeysArray clearText:YES ID:@""];
            }
            if (contentKeysArray && contentKeysArray.count > 0) {
                NSMutableDictionary *contentEventObj = [[NSMutableDictionary alloc] init];
                [contentEventObj setObject:[NSString stringWithFormat:@"%f", [[NSDate date] timeIntervalSince1970]] forKey:BRANCH_TIME_STAMP_KEY];
                if (_cdManifest.referredLink) {
                    [contentEventObj setObject:_cdManifest.referredLink forKey:BRANCH_REFERRAL_LINK_KEY];
                }
                
                [contentEventObj setObject:[NSString stringWithFormat:@"/%@", _lastViewController.class] forKey:BRANCH_VIEW_KEY];
                [contentEventObj setObject:!isClearText? @"true" : @"false" forKey:BRANCH_HASH_MODE_KEY];
                [contentEventObj setObject:contentKeysArray forKey:BRANCH_CONTENT_KEYS_KEY];
                if (contentDataArray && contentDataArray.count > 0) {
                    [contentEventObj setObject:contentDataArray forKey:BRANCH_CONTENT_DATA_KEY];
                }
                
                [[BNCPreferenceHelper preferenceHelper]saveBranchAnalyticsData:contentEventObj];
            }
        }
    }
}


- (void)discoverViewContents:(UIView *)rootView contentData:(NSMutableArray *)contentDataArray contentKeys:(NSMutableArray *)contentKeysArray clearText:(BOOL)isClearText ID:(NSString *)viewId {
    if ([rootView isKindOfClass:UITableView.class] || [rootView isKindOfClass:UICollectionView.class]) {
        NSArray *cells = [rootView performSelector:@selector(visibleCells) withObject:nil];
        NSInteger cellCnt = -1;
        for (UIView *cell in cells) {
            cellCnt++;
            NSString *format;
            if (viewId.length > 0 ) {
                format = @"-%d";
            } else {
                format = @"%d";
            }
            NSString *cellViewId = [viewId stringByAppendingFormat:format, cellCnt];
            [self discoverViewContents:cell contentData:contentDataArray contentKeys:contentKeysArray clearText:isClearText ID:cellViewId];
        }
    } else {
        NSString *contentData = [self getContentText:rootView];
        if (contentData) {
            NSString *viewFriendlyName = [NSString stringWithFormat:@"%@:%@", [rootView class], viewId];
            [contentKeysArray addObject:viewFriendlyName];
            if (contentDataArray) {
                [self addFormatedContentData:contentDataArray withText:contentData clearText:isClearText];
            }
        }
        NSArray *subViews = [rootView subviews];
        if (subViews.count > 0) {
            NSInteger childCount = -1;
            for (UIView *view in subViews) {
                childCount++;
                NSString *subViewId = [viewId stringByAppendingFormat:@"-%ld", (long)childCount];
                [self discoverViewContents:view contentData:contentDataArray contentKeys:contentKeysArray clearText:isClearText ID:subViewId];
            }
        }
    }
}


- (void)discoverFilteredViewContents:(NSMutableArray *)contentDataArray contentKeys:(NSMutableArray *)contentKeysArray clearText:(BOOL)isClearText {
    for (NSString *contentKey in contentKeysArray) {
        NSString *contentData = [self getViewText:contentKey forController:_lastViewController];
        if (contentData == nil) {
            contentData = @"";
        }
        if (contentDataArray) {
            [self addFormatedContentData:contentDataArray withText:contentData clearText:isClearText];
        }
    }
}


- (NSString *)getViewText:(NSString *)viewId forController:(UIViewController *)viewController {
    NSString *viewTxt = @"";
    if (viewController) {
        UIView *rootView = [viewController view];
        NSArray *viewIDsplitArray = [viewId componentsSeparatedByString:@":"];
        if (viewIDsplitArray.count > 0) {
            viewId = [[viewId componentsSeparatedByString:@":"] objectAtIndex:1];
        }
        NSArray *viewIds = [viewId componentsSeparatedByString:@"-"];
        BOOL foundView = YES;
        for (NSString *subViewIdStr in viewIds) {
            NSInteger subviewId = [subViewIdStr intValue];
            if ([rootView isKindOfClass:UITableView.class] || [rootView isKindOfClass:UICollectionView.class]) {
                NSArray *cells = [rootView performSelector:@selector(visibleCells) withObject:nil];
                if (cells.count > subviewId) {
                    rootView = [cells objectAtIndex:subviewId];
                } else {
                    foundView = NO;
                    break;
                }
            } else {
                if ([rootView subviews].count > subviewId) {
                    rootView = [[rootView subviews] objectAtIndex:subviewId];
                } else {
                    foundView = NO;
                    break;
                }
            }
        }
        if (foundView) {
            NSString *contentVal = [self getContentText:rootView];
            if (contentVal) {
                viewTxt = contentVal;
            }
        }
    }
    return viewTxt;
}

- (UIViewController *)getActiveViewController {
    UIViewController *rootViewController = [UIApplication sharedApplication].keyWindow.rootViewController;
    return [self getActiveViewController:rootViewController];
    
}

- (UIViewController *)getActiveViewController:(UIViewController *)rootViewController {
    UIViewController *activeController;
    if ([rootViewController isKindOfClass:[UINavigationController class]]) {
        activeController = ((UINavigationController *)rootViewController).topViewController;
    } else if ([rootViewController isKindOfClass:[UITabBarController class]]) {
        activeController = ((UITabBarController *)rootViewController).selectedViewController;
    } else {
        activeController = rootViewController;
    }
    return activeController;
}

- (void)addFormatedContentData:(NSMutableArray *)contentDataArray withText:(NSString *)contentData clearText:(BOOL)isClearText {
    if (contentData && contentData.length > _cdManifest.maxTextLen) {
        contentData = [contentData substringToIndex:_cdManifest.maxTextLen];
    }
    if (!isClearText) {
        contentData = [self hashContent:contentData];
    }
    [contentDataArray addObject:contentData];
}

- (NSString*)hashContent:(NSString *)content {
    const char *ptr = [content UTF8String];
    unsigned char md5Buffer[CC_MD5_DIGEST_LENGTH];
    CC_MD5(ptr, (CC_LONG)strlen(ptr), md5Buffer);
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (NSInteger i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x",md5Buffer[i]];
    }
    return output;
}

- (NSString *)getContentText:(UIView *)view {
    NSString *contentData = nil;
    if ([view respondsToSelector:@selector(text)]) {
        contentData = [view performSelector:@selector(text) withObject:nil];
    }
    if (contentData == nil || contentData.length == 0) {
        if ([view respondsToSelector:@selector(attributedText)]) {
            contentData = [view performSelector:@selector(attributedText) withObject:nil];
        }
    }
    
    if (contentData == nil || contentData.length == 0) {
        if ([view isKindOfClass:UIButton.class]) {
            contentData = [view performSelector:@selector(titleLabel) withObject:nil];
            if (contentData) {
                contentData = [(UILabel *) contentData text];
            }
        } else if ([view isKindOfClass:UITextField.class]) {
            contentData = [view performSelector:@selector(attributedPlaceholder) withObject:nil];
            if (contentData) {
                contentData = [(NSAttributedString *) contentData string];
            }
        }
    }
    return contentData;
}

@end



