#import <AppKit/AppKit.h>
#include <node_api.h>
#include <stdlib.h>
#include <string.h>

// AppKit delivers Services to the outer app, not to its Swift child process.
// Keep library access in Swift; this adapter only forwards the request's URL.
static napi_threadsafe_function serviceCallback;

@interface SaveNestServicesProvider : NSObject
- (void)addToSaveNest:(NSPasteboard *)pasteboard userData:(NSString *)userData error:(NSString **)error;
@end

@implementation SaveNestServicesProvider
- (void)addToSaveNest:(NSPasteboard *)pasteboard userData:(NSString *)userData error:(NSString **)error {
    NSArray<NSPasteboardItem *> *items = pasteboard.pasteboardItems;
    NSString *text = items.count == 1 ? ([items[0] stringForType:NSPasteboardTypeURL] ?: [items[0] stringForType:NSPasteboardTypeString]) : nil;
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURLComponents *url = text ? [NSURLComponents componentsWithString:text] : nil;
    BOOL webURL = [url.scheme.lowercaseString isEqualToString:@"http"] || [url.scheme.lowercaseString isEqualToString:@"https"];
    if (!text.length || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 8192 ||
        [text rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound ||
        !webURL || !url.host.length || url.user != nil || url.password != nil) {
        if (error) *error = @"Select one complete http:// or https:// web address, then choose Add to SaveNest again.";
        return;
    }
    char *value = strdup(text.UTF8String);
    if (!value || !serviceCallback || napi_call_threadsafe_function(serviceCallback, value, napi_tsfn_nonblocking) != napi_ok) {
        free(value);
        if (error) *error = @"SaveNest is busy starting or closing. Please try again.";
    }
}
@end

static SaveNestServicesProvider *provider;

static void Deliver(napi_env env, napi_value callback, void *context, void *data) {
    char *text = data;
    if (env && callback) {
        napi_value value, receiver;
        if (napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &value) == napi_ok &&
            napi_get_undefined(env, &receiver) == napi_ok) {
            napi_call_function(env, receiver, callback, 1, &value, NULL);
        }
    }
    free(text);
}

static void Cleanup(void *data) {
    if (NSApp.servicesProvider == provider) NSApp.servicesProvider = nil;
    provider = nil;
    if (serviceCallback) {
        napi_release_threadsafe_function(serviceCallback, napi_tsfn_abort);
        serviceCallback = NULL;
    }
}

static napi_value Register(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value callback, resource, result;
    napi_valuetype type;
    if (napi_get_cb_info(env, info, &count, &callback, NULL, NULL) != napi_ok || count != 1 ||
        napi_typeof(env, callback, &type) != napi_ok || type != napi_function) {
        napi_throw_type_error(env, NULL, "Services registration requires a callback.");
        return NULL;
    }
    if (!NSThread.isMainThread || !NSApp || serviceCallback) {
        napi_throw_error(env, NULL, "Register Services once, on the app's main thread after it is ready.");
        return NULL;
    }
    napi_create_string_utf8(env, "SaveNest Services", NAPI_AUTO_LENGTH, &resource);
    if (napi_create_threadsafe_function(env, callback, NULL, resource, 10, 1, NULL, NULL, NULL, Deliver, &serviceCallback) != napi_ok) {
        napi_throw_error(env, NULL, "Could not create the Services callback.");
        return NULL;
    }
    napi_unref_threadsafe_function(env, serviceCallback);
    provider = [SaveNestServicesProvider new];
    NSApp.servicesProvider = provider;
    NSUpdateDynamicServices();
    napi_get_undefined(env, &result);
    return result;
}

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor methods[] = {{"register", NULL, Register, NULL, NULL, NULL, napi_default, NULL}};
    napi_define_properties(env, exports, 1, methods);
    napi_add_env_cleanup_hook(env, Cleanup, NULL);
    return exports;
}

NAPI_MODULE(savenest_services, Init)
