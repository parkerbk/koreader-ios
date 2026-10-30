/* Native alerts, action sheets and text prompts.
 *
 * frontend/ui/nativedialogs.lua shows KOReader's dialog widgets through these.
 * As in ios_menu.m, Lua is never called from here: what the user does is
 * queued and read with ko_ios_dialog_poll(). */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <stdbool.h>

UIViewController *ko_ios_top_view_controller(void);
bool ko_ios_menu_transitioning(void);

static NSMutableArray<NSDictionary *> *g_dialog_events = nil;
static NSMutableDictionary<NSNumber *, UIAlertController *> *g_alerts = nil;
static NSMutableArray *g_ops = nil;
static BOOL g_op_running = NO;

static void ko_dialog_next_op(void);

static void ko_dialog_post(int dialog_id, int button, UIAlertController *alert) {
    NSMutableArray *texts = [NSMutableArray array];
    for (UITextField *field in alert.textFields) {
        [texts addObject:field.text ?: @""];
    }
    [g_alerts removeObjectForKey:@(dialog_id)];
    @synchronized (g_dialog_events) {
        [g_dialog_events addObject:@{ @"id": @(dialog_id), @"button": @(button), @"texts": texts }];
    }
}

/* UIKit refuses to present or dismiss during a transition, so one op runs at a
 * time, and a present waits for whatever is on screen to settle. */
static void ko_dialog_enqueue(void (^op)(dispatch_block_t done)) {
    [g_ops addObject:[op copy]];
    ko_dialog_next_op();
}

static void ko_dialog_next_op(void) {
    if (g_op_running || g_ops.count == 0) {
        return;
    }
    g_op_running = YES;
    void (^op)(dispatch_block_t) = g_ops.firstObject;
    [g_ops removeObjectAtIndex:0];
    op(^{
        g_op_running = NO;
        ko_dialog_next_op();
    });
}

static void ko_dialog_present(UIAlertController *alert, int dialog_id, dispatch_block_t done) {
    if (!g_alerts[@(dialog_id)]) { /* closed while waiting */
        done();
        return;
    }
    UIViewController *presenter = ko_ios_top_view_controller();
    if (!presenter || presenter.isBeingDismissed || presenter.isBeingPresented || ko_ios_menu_transitioning()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            ko_dialog_present(alert, dialog_id, done);
        });
        return;
    }
    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover) { /* action sheets on iPad */
        CGRect bounds = presenter.view.bounds;
        popover.sourceView = presenter.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds), 1, 1);
        popover.permittedArrowDirections = 0;
    }
    [presenter presentViewController:alert animated:YES completion:done];
}

static void ko_dialog_show(NSDictionary *spec) {
    int dialog_id = [spec[@"id"] intValue];
    NSString *title = [spec[@"title"] length] > 0 ? spec[@"title"] : nil;
    NSString *message = [spec[@"message"] length] > 0 ? spec[@"message"] : nil;
    BOOL sheet = [spec[@"sheet"] boolValue];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:message
                  preferredStyle:sheet ? UIAlertControllerStyleActionSheet : UIAlertControllerStyleAlert];
    if ([spec[@"dark"] boolValue]) {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }

    for (NSDictionary *field in spec[@"fields"]) {
        [alert addTextFieldWithConfigurationHandler:^(UITextField *text_field) {
            text_field.text = field[@"text"];
            text_field.placeholder = field[@"hint"];
            text_field.secureTextEntry = [field[@"secure"] boolValue];
            text_field.clearButtonMode = UITextFieldViewModeWhileEditing;
            if ([field[@"number"] boolValue]) {
                text_field.keyboardType = UIKeyboardTypeDecimalPad;
            }
        }];
    }

    __weak UIAlertController *weak_alert = alert;
    for (NSDictionary *button in spec[@"buttons"]) {
        int index = [button[@"i"] intValue];
        UIAlertAction *action = [UIAlertAction actionWithTitle:button[@"text"]
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction *a) {
            ko_dialog_post(dialog_id, index, weak_alert);
        }];
        action.enabled = [button[@"enabled"] boolValue];
        [alert addAction:action];
        if ([button[@"preferred"] boolValue]) {
            alert.preferredAction = action;
        }
    }
    if ([spec[@"cancel"] length] > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:spec[@"cancel"]
                                                  style:UIAlertActionStyleCancel
                                                handler:^(UIAlertAction *a) {
            ko_dialog_post(dialog_id, 0, weak_alert);
        }]];
    }

    g_alerts[@(dialog_id)] = alert;
    ko_dialog_enqueue(^(dispatch_block_t done) {
        ko_dialog_present(alert, dialog_id, done);
    });
}

void ko_ios_dialog_show(const char *json) {
    NSData *data = [NSData dataWithBytes:json length:strlen(json)];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error = nil;
        NSDictionary *spec = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (![spec isKindOfClass:[NSDictionary class]]) {
            NSLog(@"ko_ios_dialog_show: bad spec: %@", error);
            return;
        }
        ko_dialog_show(spec);
    });
}

void ko_ios_dialog_close(int dialog_id) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = g_alerts[@(dialog_id)];
        [g_alerts removeObjectForKey:@(dialog_id)];
        if (!alert) {
            return;
        }
        ko_dialog_enqueue(^(dispatch_block_t done) {
            if (alert.presentingViewController) {
                [alert dismissViewControllerAnimated:YES completion:done];
            } else {
                done();
            }
        });
    });
}

/* Returns the dialog's id, or 0 when nothing happened. The entered texts come
 * back as a JSON array in out_texts. */
int ko_ios_dialog_poll(int *button, char *out_texts, int cap) {
    NSDictionary *event = nil;
    @synchronized (g_dialog_events) {
        if (g_dialog_events.count == 0) {
            return 0;
        }
        event = g_dialog_events.firstObject;
        [g_dialog_events removeObjectAtIndex:0];
    }
    *button = [event[@"button"] intValue];
    NSData *json = [NSJSONSerialization dataWithJSONObject:event[@"texts"] options:0 error:nil];
    int length = MIN((int)json.length, cap - 1);
    memcpy(out_texts, json.bytes, length);
    out_texts[length] = 0;
    return [event[@"id"] intValue];
}

__attribute__((constructor)) static void ko_dialog_init(void) {
    g_dialog_events = [NSMutableArray array];
    g_alerts = [NSMutableDictionary dictionary];
    g_ops = [NSMutableArray array];
}
