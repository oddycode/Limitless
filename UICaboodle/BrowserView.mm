#include <UIKit/UIKit.h>
#include "iPhonePrivate.h"

#include "UCPlatform.h"

#include <UICaboodle/BrowserView.h>
#include <UICaboodle/UCLocalize.h>

//#include <QuartzCore/CALayer.h>
// XXX: fix the minimum requirement
extern NSString * const kCAFilterNearest;

#include <WebCore/WebCoreThread.h>

#include <WebKit/WebPolicyDelegate.h>
#include <WebKit/WebPreferences.h>

#include <WebKit/DOMCSSPrimitiveValue.h>
#include <WebKit/DOMCSSStyleDeclaration.h>
#include <WebKit/DOMDocument.h>
#include <WebKit/DOMHTMLBodyElement.h>
#include <WebKit/DOMRGBColor.h>

//#include <WebCore/Page.h>
//#include <WebCore/Settings.h>

#include "substrate.h"

#define ForSaurik 0

template <typename Type_>
static inline void CYRelease(Type_ &value) {
    if (value != nil) {
        [value release];
        value = nil;
    }
}

@interface WebView (Apple)
- (void) _setLayoutInterval:(float)interval;
@end

@interface WebPreferences (Apple)
+ (void) _setInitialDefaultTextEncodingToSystemEncoding;
- (void) _setLayoutInterval:(NSInteger)interval;
- (void) setOfflineWebApplicationCacheEnabled:(BOOL)enabled;
@end

/* Indirect Delegate {{{ */
@interface IndirectDelegate : NSObject <
    HookProtocol
> {
    _transient volatile id delegate_;
}

- (void) setDelegate:(id)delegate;
- (id) initWithDelegate:(id)delegate;
@end

@implementation IndirectDelegate

- (void) setDelegate:(id)delegate {
    delegate_ = delegate;
}

- (id) initWithDelegate:(id)delegate {
    delegate_ = delegate;
    return self;
}

- (void) didDismissModalViewController {
    if (delegate_ != nil)
        return [delegate_ didDismissModalViewController];
}

- (IMP) methodForSelector:(SEL)sel {
    if (IMP method = [super methodForSelector:sel])
        return method;
    fprintf(stderr, "methodForSelector:[%s] == NULL\n", sel_getName(sel));
    return NULL;
}

- (BOOL) respondsToSelector:(SEL)sel {
    if ([super respondsToSelector:sel])
        return YES;
    // XXX: WebThreadCreateNSInvocation returns nil
    //fprintf(stderr, "[%s]R?%s\n", class_getName(self->isa), sel_getName(sel));
    return delegate_ == nil ? NO : [delegate_ respondsToSelector:sel];
}

- (NSMethodSignature *) methodSignatureForSelector:(SEL)sel {
    if (NSMethodSignature *method = [super methodSignatureForSelector:sel])
        return method;
    //fprintf(stderr, "[%s]S?%s\n", class_getName(self->isa), sel_getName(sel));
    if (delegate_ != nil)
        if (NSMethodSignature *sig = [delegate_ methodSignatureForSelector:sel])
            return sig;
    // XXX: I fucking hate Apple so very very bad
    return [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void) forwardInvocation:(NSInvocation *)inv {
    SEL sel = [inv selector];
    if (delegate_ != nil && [delegate_ respondsToSelector:sel])
        [inv invokeWithTarget:delegate_];
}

@end
/* }}} */

@implementation WebScriptObject (UICaboodle)

- (NSUInteger) count {
    id length([self valueForKey:@"length"]);
    if ([length respondsToSelector:@selector(intValue)])
        return [length intValue];
    else
        return 0;
}

- (id) objectAtIndex:(unsigned)index {
    return [self webScriptValueAtIndex:index];
}

@end

// CYWebPolicyDecision* {{{
enum CYWebPolicyDecision {
    CYWebPolicyDecisionUnknown,
    CYWebPolicyDecisionDownload,
    CYWebPolicyDecisionIgnore,
    CYWebPolicyDecisionUse,
};

@interface CYWebPolicyDecisionMediator : NSObject <
    WebPolicyDecisionListener
> {
    id<WebPolicyDecisionListener> listener_;
    CYWebPolicyDecision decision_;
}

- (id) initWithListener:(id<WebPolicyDecisionListener>)listener;

- (CYWebPolicyDecision) decision;
- (bool) decided;
- (bool) decide;

@end

@implementation CYWebPolicyDecisionMediator

- (id) initWithListener:(id<WebPolicyDecisionListener>)listener {
    if ((self = [super init]) != nil) {
        listener_ = listener;
    } return self;
}

- (CYWebPolicyDecision) decision {
    return decision_;
}

- (bool) decided {
    return decision_ != CYWebPolicyDecisionUnknown;
}

- (bool) decide {
    switch (decision_) {
        case CYWebPolicyDecisionUnknown:
        default:
            return false;

        case CYWebPolicyDecisionDownload: [listener_ download]; break;
        case CYWebPolicyDecisionIgnore: [listener_ ignore]; break;
        case CYWebPolicyDecisionUse: [listener_ use]; break;
    }

    return true;
}

- (void) download {
    decision_ = CYWebPolicyDecisionDownload;
}

- (void) ignore {
    decision_ = CYWebPolicyDecisionIgnore;
}

- (void) use {
    decision_ = CYWebPolicyDecisionUse;
}

@end
// }}}

@implementation CYWebView : UIWebView

- (id) initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame]) != nil) {
    } return self;
}

- (void) dealloc {
    [super dealloc];
}

- (id<CYWebViewDelegate>) delegate {
    return (id<CYWebViewDelegate>) [super delegate];
}

/*- (WebView *) webView:(WebView *)view createWebViewWithRequest:(NSURLRequest *)request {
    NSLog(@"createWebViewWithRequest:%@", request);
    WebView *created(nil); // XXX
    if (created == nil && [super respondsToSelector:@selector(webView:createWebViewWithRequest:)])
        return [super webView:view createWebViewWithRequest:request];
    else
        return created;
}*/

- (void) webView:(WebView *)view decidePolicyForNavigationAction:(NSDictionary *)action request:(NSURLRequest *)request frame:(WebFrame *)frame decisionListener:(id<WebPolicyDecisionListener>)listener {
    CYWebPolicyDecisionMediator *mediator([[[CYWebPolicyDecisionMediator alloc] initWithListener:listener] autorelease]);
    [[self delegate] webView:view decidePolicyForNavigationAction:action request:request frame:frame decisionListener:mediator];
    if (![mediator decided] && [super respondsToSelector:@selector(webView:decidePolicyForNavigationAction:request:frame:decisionListener:)])
        [super webView:view decidePolicyForNavigationAction:action request:request frame:frame decisionListener:mediator];
    [mediator decide];
}

- (void) webView:(WebView *)view decidePolicyForNewWindowAction:(NSDictionary *)action request:(NSURLRequest *)request newFrameName:(NSString *)frame decisionListener:(id<WebPolicyDecisionListener>)listener {
    CYWebPolicyDecisionMediator *mediator([[[CYWebPolicyDecisionMediator alloc] initWithListener:listener] autorelease]);
    [[self delegate] webView:view decidePolicyForNewWindowAction:action request:request newFrameName:frame decisionListener:mediator];
    if (![mediator decided] && [super respondsToSelector:@selector(webView:decidePolicyForNewWindowAction:request:newFrameName:decisionListener:)])
        [super webView:view decidePolicyForNewWindowAction:action request:request newFrameName:frame decisionListener:mediator];
    [mediator decide];
}

- (void) webView:(WebView *)view didClearWindowObject:(WebScriptObject *)window forFrame:(WebFrame *)frame {
    [[self delegate] webView:view didClearWindowObject:window forFrame:frame];
    if ([super respondsToSelector:@selector(webView:didClearWindowObject:forFrame:)])
        [super webView:view didClearWindowObject:window forFrame:frame];
}

- (void) webView:(WebView *)view didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame {
    [[self delegate] webView:view didFailLoadWithError:error forFrame:frame];
    if ([super respondsToSelector:@selector(webView:didFailLoadWithError:forFrame:)])
        [super webView:view didFailLoadWithError:error forFrame:frame];
}

- (void) webView:(WebView *)view didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame {
    [[self delegate] webView:view didFailProvisionalLoadWithError:error forFrame:frame];
    if ([super respondsToSelector:@selector(webView:didFailProvisionalLoadWithError:forFrame:)])
        [super webView:view didFailProvisionalLoadWithError:error forFrame:frame];
}

- (void) webView:(WebView *)view didFinishLoadForFrame:(WebFrame *)frame {
    [[self delegate] webView:view didFinishLoadForFrame:frame];
    if ([super respondsToSelector:@selector(webView:didFinishLoadForFrame:)])
        [super webView:view didFinishLoadForFrame:frame];
}

- (void) webView:(WebView *)view didReceiveTitle:(NSString *)title forFrame:(WebFrame *)frame {
    [[self delegate] webView:view didReceiveTitle:title forFrame:frame];
    if ([super respondsToSelector:@selector(webView:didReceiveTitle:forFrame:)])
        [super webView:view didReceiveTitle:title forFrame:frame];
}

- (void) webView:(WebView *)view didStartProvisionalLoadForFrame:(WebFrame *)frame {
    [[self delegate] webView:view didStartProvisionalLoadForFrame:frame];
    if ([super respondsToSelector:@selector(webView:didStartProvisionalLoadForFrame:)])
        [super webView:view didStartProvisionalLoadForFrame:frame];
}

- (NSURLRequest *) webView:(WebView *)view resource:(id)identifier willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response fromDataSource:(WebDataSource *)source {
    if ([super respondsToSelector:@selector(webView:resource:willSendRequest:redirectResponse:)])
        request = [super webView:view resource:identifier willSendRequest:request redirectResponse:response fromDataSource:source];
    return [[self delegate] webView:view resource:identifier willSendRequest:request redirectResponse:response fromDataSource:source];
}

- (void) webView:(WebView *)view runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WebFrame *)frame {
    if ([super respondsToSelector:@selector(webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:)])
        if ([[self delegate] webView:view shouldRunJavaScriptAlertPanelWithMessage:message initiatedByFrame:frame])
            [super webView:view runJavaScriptAlertPanelWithMessage:message initiatedByFrame:frame];
}

- (BOOL) webView:(WebView *)view runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WebFrame *)frame {
    if ([super respondsToSelector:@selector(webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:)])
        if ([[self delegate] webView:view shouldRunJavaScriptConfirmPanelWithMessage:message initiatedByFrame:frame])
            return [super webView:view runJavaScriptConfirmPanelWithMessage:message initiatedByFrame:frame];
    return NO;
}

- (NSString *) webView:(WebView *)view runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)text initiatedByFrame:(WebFrame *)frame {
    if ([super respondsToSelector:@selector(webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:)])
        if ([[self delegate] webView:view shouldRunJavaScriptTextInputPanelWithPrompt:prompt defaultText:text initiatedByFrame:frame])
            return [super webView:view runJavaScriptTextInputPanelWithPrompt:prompt defaultText:text initiatedByFrame:frame];
    return nil;
}

- (void) webViewClose:(WebView *)view {
    [[self delegate] webViewClose:view];
    if ([super respondsToSelector:@selector(webViewClose:)])
        [super webViewClose:view];
}

@end

#define ShowInternals 0
#define LogBrowser 1

#define lprintf(args...) fprintf(stderr, args)

@implementation BrowserController

#if ShowInternals
#include "UICaboodle/UCInternal.h"
#endif

+ (void) _initialize {
    [WebPreferences _setInitialDefaultTextEncodingToSystemEncoding];
}

- (void) dealloc {
#if LogBrowser
    NSLog(@"[BrowserController dealloc]");
#endif

    [webview_ setDelegate:nil];

    [indirect_ setDelegate:nil];
    [indirect_ release];

    if (challenge_ != nil)
        [challenge_ release];

    //NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    if (custom_ != nil)
        [custom_ release];
    if (style_ != nil)
        [style_ release];

    if (function_ != nil)
        [function_ release];
    if (closer_ != nil)
        [closer_ release];

    if (sensitive_ != nil)
        [sensitive_ release];
    if (title_ != nil)
        [title_ release];

    [reloaditem_ release];
    [loadingitem_ release];

    [indicator_ release];

    [super dealloc];
}

- (void) loadURL:(NSURL *)url cachePolicy:(NSURLRequestCachePolicy)policy {
    [self loadRequest:[NSURLRequest
        requestWithURL:url
        cachePolicy:policy
        timeoutInterval:120.0
    ]];
}

- (void) loadURL:(NSURL *)url {
    [self loadURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy];
}

- (void) loadRequest:(NSURLRequest *)request {
    error_ = false;

    WebThreadLock();
    [webview_ loadRequest:request];
    WebThreadUnlock();
}

- (void) reloadURL {
    if (request_ == nil)
        return;

    if ([request_ HTTPBody] == nil && [request_ HTTPBodyStream] == nil)
        [self loadRequest:request_];
    else {
        UIAlertView *alert = [[[UIAlertView alloc]
            initWithTitle:UCLocalize("RESUBMIT_FORM")
            message:nil
            delegate:self
            cancelButtonTitle:UCLocalize("CANCEL")
            otherButtonTitles:UCLocalize("SUBMIT"), nil
        ] autorelease];

        [alert setContext:@"submit"];
        [alert show];
    }
}

- (void) setButtonImage:(NSString *)button withStyle:(NSString *)style toFunction:(id)function {
    if (custom_ != nil)
        [custom_ autorelease];
    custom_ = button == nil ? nil : [[UIImage imageWithData:[NSData dataWithContentsOfURL:[NSURL URLWithString:button]]] retain];

    if (style_ != nil)
        [style_ autorelease];
    style_ = style == nil ? nil : [style retain];

    if (function_ != nil)
        [function_ autorelease];
    function_ = function == nil ? nil : [function retain];

    [self applyRightButton];
}

- (void) setButtonTitle:(NSString *)button withStyle:(NSString *)style toFunction:(id)function {
    if (custom_ != nil)
        [custom_ autorelease];
    custom_ = button == nil ? nil : [button retain];

    if (style_ != nil)
        [style_ autorelease];
    style_ = style == nil ? nil : [style retain];

    if (function_ != nil)
        [function_ autorelease];
    function_ = function == nil ? nil : [function retain];

    [self applyRightButton];
}

- (void) setPopupHook:(id)function {
    if (closer_ != nil)
        [closer_ autorelease];
    closer_ = function == nil ? nil : [function retain];
}

- (void) setViewportWidth:(float)width {
    width_ = width != 0 ? width : [[self class] defaultWidth];
    [[webview_ _documentView] setViewportSize:CGSizeMake(width_, UIWebViewGrowsAndShrinksToFitHeight) forDocumentTypes:0x10];
}

- (void) _openMailToURL:(NSURL *)url {
    [[UIApplication sharedApplication] openURL:url];// asPanel:YES];
}

- (bool) _allowJavaScriptPanel {
    return true;
}

- (void) _didFailWithError:(NSError *)error forFrame:(WebFrame *)frame {
    [loading_ removeObject:[NSValue valueWithNonretainedObject:frame]];
    [self _didFinishLoading];

    if ([error code] == NSURLErrorCancelled)
        return;

    if ([frame parentFrame] == nil) {
        [self loadURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@?%@",
            [[NSURL fileURLWithPath:[[NSBundle mainBundle] pathForResource:@"error" ofType:@"html"]] absoluteString],
            [[error localizedDescription] stringByAddingPercentEscapes]
        ]]];

        error_ = true;
    }
}

// CYWebViewDelegate {{{
- (void) webView:(WebView *)view decidePolicyForNavigationAction:(NSDictionary *)action request:(NSURLRequest *)request frame:(WebFrame *)frame decisionListener:(id<WebPolicyDecisionListener>)listener {
#if LogBrowser
    NSLog(@"decidePolicyForNavigationAction:%@ request:%@ frame:%@", action, request, frame);
#endif

    if (!error_ && [frame parentFrame] == nil) {
        if (request_ != nil)
            [request_ autorelease];
        if (request == nil)
            request_ = nil;
        else
            request_ = [request retain];
    }
}

- (void) webView:(WebView *)view decidePolicyForNewWindowAction:(NSDictionary *)action request:(NSURLRequest *)request newFrameName:(NSString *)frame decisionListener:(id<WebPolicyDecisionListener>)listener {
#if LogBrowser
    NSLog(@"decidePolicyForNewWindowAction:%@ request:%@ newFrameName:%@", action, request, frame);
#endif

    NSURL *url([request URL]);
    if (url == nil)
        return;

    if ([frame isEqualToString:@"_open"])
        [delegate_ openURL:url];

    NSString *scheme([[url scheme] lowercaseString]);
    if ([scheme isEqualToString:@"mailto"])
        [self _openMailToURL:url];

    CYViewController *page([delegate_ pageForURL:url hasTag:NULL]);

    if (page == nil) {
        BrowserController *browser([[[class_ alloc] init] autorelease]);
        [browser loadRequest:request];
        page = browser;
    }

    [page setDelegate:delegate_];

    if (![frame isEqualToString:@"_popup"]) {
        [[self navigationItem] setTitle:title_];

        [[self navigationController] pushViewController:page animated:YES];
    } else {
        UCNavigationController *navigation([[[UCNavigationController alloc] init] autorelease]);

        [navigation setHook:indirect_];
        [navigation setDelegate:delegate_];

        [navigation setViewControllers:[NSArray arrayWithObject:page]];

        [[page navigationItem] setLeftBarButtonItem:[[[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("CLOSE")
            style:UIBarButtonItemStylePlain
            target:page
            action:@selector(close)
        ] autorelease]];

        [[self navigationController] presentModalViewController:navigation animated:YES];
    }

    [listener ignore];
}

- (void) webView:(WebView *)view didClearWindowObject:(WebScriptObject *)window forFrame:(WebFrame *)frame {
}

- (void) webView:(WebView *)view didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame {
#if LogBrowser
    NSLog(@"didFailLoadWithError:%@ forFrame:%@", error, frame);
#endif

    [self _didFailWithError:error forFrame:frame];
}

- (void) webView:(WebView *)view didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame {
#if LogBrowser
    NSLog(@"didFailProvisionalLoadWithError:%@ forFrame:%@", error, frame);
#endif

    [self _didFailWithError:error forFrame:frame];
}

- (void) webView:(WebView *)view didFinishLoadForFrame:(WebFrame *)frame {
    [loading_ removeObject:[NSValue valueWithNonretainedObject:frame]];

    if ([frame parentFrame] == nil) {
        if (DOMDocument *document = [frame DOMDocument])
            if (DOMNodeList<NSFastEnumeration> *bodies = [document getElementsByTagName:@"body"])
                for (DOMHTMLBodyElement *body in (id) bodies) {
                    DOMCSSStyleDeclaration *style([document getComputedStyle:body pseudoElement:nil]);

                    bool colored(false);

                    if (DOMCSSPrimitiveValue *color = static_cast<DOMCSSPrimitiveValue *>([style getPropertyCSSValue:@"background-color"])) {
                        if ([color primitiveType] == DOM_CSS_RGBCOLOR) {
                            DOMRGBColor *rgb([color getRGBColorValue]);

                            float red([[rgb red] getFloatValue:DOM_CSS_NUMBER]);
                            float green([[rgb green] getFloatValue:DOM_CSS_NUMBER]);
                            float blue([[rgb blue] getFloatValue:DOM_CSS_NUMBER]);
                            float alpha([[rgb alpha] getFloatValue:DOM_CSS_NUMBER]);

                            UIColor *uic(nil);

                            if (red == 0xc7 && green == 0xce && blue == 0xd5)
                                uic = [UIColor groupTableViewBackgroundColor];
                            else if (alpha != 0)
                                uic = [UIColor
                                    colorWithRed:(red / 255)
                                    green:(green / 255)
                                    blue:(blue / 255)
                                    alpha:alpha
                                ];

                            if (uic != nil) {
                                colored = true;
                                [scroller_ setBackgroundColor:uic];
                            }
                        }
                    }

                    if (!colored)
                        [scroller_ setBackgroundColor:[UIColor groupTableViewBackgroundColor]];
                    break;
                }
    }

    [self _didFinishLoading];
}

- (void) webView:(WebView *)view didReceiveTitle:(NSString *)title forFrame:(WebFrame *)frame {
    if ([frame parentFrame] != nil)
        return;

    title_ = [title retain];
    [[self navigationItem] setTitle:title_];
}

- (void) webView:(WebView *)view didStartProvisionalLoadForFrame:(WebFrame *)frame {
    [loading_ addObject:[NSValue valueWithNonretainedObject:frame]];

    if ([frame parentFrame] == nil) {
        CYRelease(title_);
        CYRelease(custom_);
        CYRelease(style_);
        CYRelease(function_);
        CYRelease(closer_);

        // XXX: do we still need to do this?
        [[self navigationItem] setTitle:nil];
    }

    [self _didStartLoading];
}

- (NSURLRequest *) webView:(WebView *)view resource:(id)identifier willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response fromDataSource:(WebDataSource *)source {
    return request;
}

- (bool) webView:(WebView *)view shouldRunJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WebFrame *)frame {
    return [self _allowJavaScriptPanel];
}

- (bool) webView:(WebView *)view shouldRunJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WebFrame *)frame {
    return [self _allowJavaScriptPanel];
}

- (bool) webView:(WebView *)view shouldRunJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)text initiatedByFrame:(WebFrame *)frame {
    return [self _allowJavaScriptPanel];
}

- (void) webViewClose:(WebView *)view {
    [self close];
}
// }}}

- (void) close {
    [[self navigationController] dismissModalViewControllerAnimated:YES];
}

- (void) alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)button {
    NSString *context([alert context]);

    if ([context isEqualToString:@"sensitive"]) {
        switch (button) {
            case 1:
                sensitive_ = [NSNumber numberWithBool:YES];
            break;

            case 2:
                sensitive_ = [NSNumber numberWithBool:NO];
            break;
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else if ([context isEqualToString:@"challenge"]) {
        id<NSURLAuthenticationChallengeSender> sender([challenge_ sender]);

        switch (button) {
            case 1: {
                NSString *username([[alert textFieldAtIndex:0] text]);
                NSString *password([[alert textFieldAtIndex:1] text]);

                NSURLCredential *credential([NSURLCredential credentialWithUser:username password:password persistence:NSURLCredentialPersistenceForSession]);

                [sender useCredential:credential forAuthenticationChallenge:challenge_];
            } break;

            case 2:
                [sender cancelAuthenticationChallenge:challenge_];
            break;

            _nodefault
        }

        [challenge_ release];
        challenge_ = nil;

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else if ([context isEqualToString:@"submit"]) {
        switch (button) {
            case 1:
            break;

            case 2:
                if (request_ != nil) {
                    WebThreadLock();
                    [webview_ loadRequest:request_];
                    WebThreadUnlock();
                }
            break;

            _nodefault
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    }
}

- (UIBarButtonItemStyle) rightButtonStyle {
    if (style_ == nil) normal:
        return UIBarButtonItemStylePlain;
    else if ([style_ isEqualToString:@"Normal"])
        return UIBarButtonItemStylePlain;
    else if ([style_ isEqualToString:@"Highlighted"])
        return UIBarButtonItemStyleDone;
    else goto normal;
}

- (UIBarButtonItem *) customButton {
    return [[[UIBarButtonItem alloc]
        initWithTitle:custom_
        style:[self rightButtonStyle]
        target:self
        action:@selector(customButtonClicked)
    ] autorelease];
}

- (UIBarButtonItem *) rightButton {
    return reloaditem_;
}

- (void) applyLoadingTitle {
    [[self navigationItem] setTitle:UCLocalize("LOADING")];
}

- (void) applyRightButton {
    if ([self isLoading]) {
        [[self navigationItem] setRightBarButtonItem:loadingitem_ animated:YES];
        // XXX: why do we do this again here?
        [[loadingitem_ view] addSubview:indicator_];
        [self applyLoadingTitle];
    } else if (custom_ != nil) {
        [[self navigationItem] setRightBarButtonItem:[self customButton] animated:YES];
    } else {
        [[self navigationItem] setRightBarButtonItem:[self rightButton] animated:YES];
    }
}

- (void) _didStartLoading {
    [self applyRightButton];
}

- (void) _didFinishLoading {
    if ([loading_ count] != 0)
        return;

    [self applyRightButton];

    // XXX: wtf?
    if (![self isLoading])
        [[self navigationItem] setTitle:title_];
}

- (bool) isLoading {
    return [loading_ count] != 0;
}

- (id) initWithWidth:(float)width ofClass:(Class)_class {
    if ((self = [super init]) != nil) {
        class_ = _class;
        loading_ = [[NSMutableSet alloc] initWithCapacity:5];

        indirect_ = [[IndirectDelegate alloc] initWithDelegate:self];

        webview_ = [[[CYWebView alloc] initWithFrame:[[self view] bounds]] autorelease];
        [webview_ setDelegate:self];
        [self setView:webview_];

        if ([webview_ respondsToSelector:@selector(setDataDetectorTypes:)])
            [webview_ setDataDetectorTypes:UIDataDetectorTypeAutomatic];
        else
            [webview_ setDetectsPhoneNumbers:NO];

        [webview_ setScalesPageToFit:YES];

        UIWebDocumentView *document([webview_ _documentView]);

        // XXX: I think this improves scrolling; the hardcoded-ness sucks
        [document setTileSize:CGSizeMake(320, 500)];

        [document setBackgroundColor:[UIColor clearColor]];
        [document setDrawsBackground:NO];

        WebView *webview([document webView]);
        WebPreferences *preferences([webview preferences]);

        // XXX: I have no clue if I actually /want/ this modification
        if ([webview respondsToSelector:@selector(_setLayoutInterval:)])
            [webview _setLayoutInterval:0];
        else if ([preferences respondsToSelector:@selector(_setLayoutInterval:)])
            [preferences _setLayoutInterval:0];

        [preferences setCacheModel:WebCacheModelDocumentBrowser];
        [preferences setOfflineWebApplicationCacheEnabled:YES];

        if ([webview_ respondsToSelector:@selector(_scrollView)]) {
            scroller_ = [webview_ _scrollView];

            [scroller_ setDirectionalLockEnabled:YES];
            [scroller_ setDecelerationRate:UIScrollViewDecelerationRateNormal];
            [scroller_ setDelaysContentTouches:NO];

            [scroller_ setCanCancelContentTouches:YES];
        } else if ([webview_ respondsToSelector:@selector(_scroller)]) {
            UIScroller *scroller([webview_ _scroller]);
            scroller_ = (UIScrollView *) scroller;

            [scroller setDirectionalScrolling:YES];
            [scroller setScrollDecelerationFactor:UIScrollViewDecelerationRateNormal]; /* 0.989324 */
            [scroller setScrollHysteresis:0]; /* 8 */

            [scroller setThumbDetectionEnabled:NO];

            // use NO with UIApplicationUseLegacyEvents(YES)
            [scroller setEventMode:YES];

            // XXX: this is handled by setBounces, right?
            //[scroller setAllowsRubberBanding:YES];
        }

        [scroller_ setFixedBackgroundPattern:YES];
        [scroller_ setBackgroundColor:[UIColor groupTableViewBackgroundColor]];
        [scroller_ setClipsSubviews:YES];

        [scroller_ setBounces:YES];
        [scroller_ setScrollingEnabled:YES];
        [scroller_ setShowBackgroundShadow:NO];

        [self setViewportWidth:width];

        reloaditem_ = [[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("RELOAD")
            style:[self rightButtonStyle]
            target:self
            action:@selector(reloadButtonClicked)
        ];

        loadingitem_ = [[UIBarButtonItem alloc]
            initWithTitle:@" "
            style:UIBarButtonItemStylePlain
            target:self
            action:@selector(reloadButtonClicked)
        ];

        CGSize indsize = [UIProgressIndicator defaultSizeForStyle:UIProgressIndicatorStyleMediumWhite];
        indicator_ = [[UIProgressIndicator alloc] initWithFrame:CGRectMake(15, 5, indsize.width, indsize.height)];
        [indicator_ setStyle:UIProgressIndicatorStyleMediumWhite];
        [indicator_ startAnimation];
        [[loadingitem_ view] addSubview:indicator_];

        [webview_ setAutoresizingMask:(UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight)];
        [indicator_ setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin];
    } return self;
}

- (id) initWithWidth:(float)width {
    return [self initWithWidth:width ofClass:[self class]];
}

- (id) init {
    return [self initWithWidth:0];
}

- (void) didDismissModalViewController {
    if (closer_ != nil)
        [self callFunction:closer_];
}

- (void) callFunction:(WebScriptObject *)function {
    WebThreadLock();

    WebView *webview([[webview_ _documentView] webView]);
    WebFrame *frame([webview mainFrame]);
    WebPreferences *preferences([webview preferences]);

    bool maybe([preferences javaScriptCanOpenWindowsAutomatically]);
    [preferences setJavaScriptCanOpenWindowsAutomatically:NO];

    /*id _private(MSHookIvar<id>(webview, "_private"));
    WebCore::Page *page(_private == nil ? NULL : MSHookIvar<WebCore::Page *>(_private, "page"));
    WebCore::Settings *settings(page == NULL ? NULL : page->settings());

    bool no;
    if (settings == NULL)
        no = 0;
    else {
        no = settings->JavaScriptCanOpenWindowsAutomatically();
        settings->setJavaScriptCanOpenWindowsAutomatically(true);
    }*/

    if (UIWindow *window = [[self view] window])
        if (UIResponder *responder = [window firstResponder])
            [responder resignFirstResponder];

    JSObjectRef object([function JSObject]);
    JSGlobalContextRef context([frame globalContext]);
    JSObjectCallAsFunction(context, object, NULL, 0, NULL, NULL);

    /*if (settings != NULL)
        settings->setJavaScriptCanOpenWindowsAutomatically(no);*/

    [preferences setJavaScriptCanOpenWindowsAutomatically:maybe];

    WebThreadUnlock();
}

- (void) reloadButtonClicked {
    [self reloadURL];
}

- (void) _customButtonClicked {
    [self reloadButtonClicked];
}

- (void) customButtonClicked {
#if !AlwaysReload
    if (function_ != nil)
        [self callFunction:function_];
    else
#endif
    [self _customButtonClicked];
}

+ (float) defaultWidth {
    return 980;
}

@end
