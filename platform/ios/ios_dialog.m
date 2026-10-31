/* Native alerts, action sheets and text prompts.
 *
 * frontend/ui/nativedialogs.lua shows KOReader's dialog widgets through these.
 * As in ios_menu.m, Lua is never called from here: what the user does is
 * queued and read with ko_ios_dialog_poll(). */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <stdbool.h>

UIViewController *ko_ios_top_view_controller(void);

@interface KOSheetNavigationController : UINavigationController
@end

bool ko_ios_menu_transitioning(void);

static NSMutableArray<NSDictionary *> *g_dialog_events = nil;
static NSMutableDictionary<NSNumber *, UIViewController *> *g_alerts = nil;
static NSMutableArray *g_ops = nil;
static BOOL g_op_running = NO;

static void ko_dialog_next_op(void);

static volatile bool g_dictionary_open = false;

/* Waits for whatever is on screen to settle, then presents. */
static void ko_present_when_ready(UIViewController *controller, dispatch_block_t done) {
    UIViewController *presenter = ko_ios_top_view_controller();
    if (!presenter || presenter.isBeingDismissed || presenter.isBeingPresented || ko_ios_menu_transitioning()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            ko_present_when_ready(controller, done);
        });
        return;
    }
    [presenter presentViewController:controller animated:YES completion:done];
}

@interface KODictionaryController : UIReferenceLibraryViewController
@end

@implementation KODictionaryController

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed) {
        g_dictionary_open = false;
    }
}

@end

@protocol KODialogValues
- (NSArray<NSString *> *)dialogValues;
@end

static void ko_dialog_post(int dialog_id, int button, UIViewController *dialog) {
    NSMutableArray *texts = [NSMutableArray array];
    if ([dialog conformsToProtocol:@protocol(KODialogValues)]) {
        [texts addObjectsFromArray:[(id<KODialogValues>)dialog dialogValues]];
    } else if ([dialog isKindOfClass:[UIAlertController class]]) {
        for (UITextField *field in ((UIAlertController *)dialog).textFields) {
            [texts addObject:field.text ?: @""];
        }
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

static void ko_dialog_present(UIViewController *alert, int dialog_id, dispatch_block_t done) {
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

/* iOS's own dictionary sheet, which also offers to download dictionaries. */
void ko_ios_dictionary_show(const char *term) {
    NSString *word = [NSString stringWithUTF8String:term];
    g_dictionary_open = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        KODictionaryController *controller = [[KODictionaryController alloc] initWithTerm:word];
        ko_dialog_enqueue(^(dispatch_block_t done) {
            ko_present_when_ready(controller, done);
        });
    });
}

bool ko_ios_dictionary_is_open(void) {
    return g_dictionary_open;
}

/* A number with a typed value, a stepper and a slider, or a choice from a list
 * of labels, which works the same on the index. */
@interface KONumberControl : NSObject <UITextFieldDelegate>
@property (nonatomic, strong) UIStackView *view;
- (instancetype)initWithSpec:(NSDictionary *)spec;
- (NSString *)value;
@end

@implementation KONumberControl {
    double _min, _max, _step, _value;
    int _decimals;
    NSArray<NSString *> *_labels;
    UITextField *_field;
    UILabel *_choice;
    UIStepper *_stepper;
    UISlider *_slider;
}

- (instancetype)initWithSpec:(NSDictionary *)spec {
    self = [super init];
    _min = [spec[@"min"] doubleValue];
    _max = [spec[@"max"] doubleValue];
    _step = MAX([spec[@"step"] doubleValue], 0.000001);
    _value = [spec[@"value"] doubleValue];
    _decimals = [spec[@"decimals"] intValue];
    _labels = [spec[@"labels"] count] > 0 ? spec[@"labels"] : nil;

    _view = [[UIStackView alloc] init];
    _view.axis = UILayoutConstraintAxisVertical;
    _view.spacing = 8;

    if ([spec[@"label"] length] > 0) {
        UILabel *label = [[UILabel alloc] init];
        label.text = spec[@"label"];
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        label.textColor = UIColor.secondaryLabelColor;
        [_view addArrangedSubview:label];
    }

    UIStackView *row = [[UIStackView alloc] init];
    row.spacing = 24;
    row.alignment = UIStackViewAlignmentCenter;
    if (_labels) {
        _choice = [[UILabel alloc] init];
        _choice.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
        _choice.numberOfLines = 0;
        [_choice setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [row addArrangedSubview:_choice];
    } else {
        _field = [[UITextField alloc] init];
        _field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
        _field.borderStyle = UITextBorderStyleRoundedRect;
        _field.keyboardType = _decimals > 0 ? UIKeyboardTypeDecimalPad : UIKeyboardTypeNumberPad;
        _field.delegate = self;
        [_field addTarget:self action:@selector(fieldEnded) forControlEvents:UIControlEventEditingDidEnd];
        [_field setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [row addArrangedSubview:_field];
        if ([spec[@"unit"] length] > 0) {
            UILabel *unit = [[UILabel alloc] init];
            unit.text = spec[@"unit"];
            unit.textColor = UIColor.secondaryLabelColor;
            [unit setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            [row addArrangedSubview:unit];
        }
    }
    _stepper = [[UIStepper alloc] init];
    _stepper.minimumValue = _min;
    _stepper.maximumValue = _max;
    _stepper.stepValue = _step;
    _stepper.continuous = YES;
    _stepper.wraps = [spec[@"wrap"] boolValue];
    [_stepper addTarget:self action:@selector(stepperChanged) forControlEvents:UIControlEventValueChanged];
    [row addArrangedSubview:_stepper];
    [_view addArrangedSubview:row];

    if (_max > _min && (_max - _min) / _step <= 10000) {
        _slider = [[UISlider alloc] init];
        _slider.minimumValue = _min;
        _slider.maximumValue = _max;
        [_slider addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];
        [_view addArrangedSubview:_slider];
    }
    [self show];
    return self;
}

- (void)show {
    if (_labels) {
        int index = (int)lround(_value) - 1;
        _choice.text = index >= 0 && index < (int)_labels.count ? _labels[index] : @"";
    } else {
        _field.text = [NSString stringWithFormat:@"%.*f", _decimals, _value];
    }
    _stepper.value = _value;
    _slider.value = _value;
}

- (void)setSnappedValue:(double)value {
    value = _min + round((value - _min) / _step) * _step;
    _value = MIN(MAX(value, _min), _max);
    [self show];
}

- (void)stepperChanged {
    _value = _stepper.value;
    [self show];
}

- (void)sliderChanged {
    double value = _min + round((_slider.value - _min) / _step) * _step;
    _value = MIN(MAX(value, _min), _max);
    _stepper.value = _value;
    if (_labels) {
        [self show];
    } else {
        _field.text = [NSString stringWithFormat:@"%.*f", _decimals, _value];
    }
}

/* Typed values aren't snapped to the step: it only applies to the buttons. */
- (void)fieldEnded {
    double typed = [[_field.text stringByReplacingOccurrencesOfString:@"," withString:@"."] doubleValue];
    _value = MIN(MAX(typed, _min), _max);
    [self show];
}

- (NSString *)value {
    if (_field.isFirstResponder) {
        [self fieldEnded];
    }
    return [NSString stringWithFormat:@"%.*f", _decimals, _value];
}

@end

@interface KOFormController : UIViewController <KODialogValues, UIAdaptivePresentationControllerDelegate>
- (instancetype)initWithSpec:(NSDictionary *)spec dialogId:(int)dialog_id;
@end

@implementation KOFormController {
    NSDictionary *_spec;
    int _dialog_id;
    NSMutableArray *_controls;
}

- (instancetype)initWithSpec:(NSDictionary *)spec dialogId:(int)dialog_id {
    self = [super init];
    _spec = spec;
    _dialog_id = dialog_id;
    _controls = [NSMutableArray array];
    return self;
}

- (UIBarButtonItem *)barItem:(NSDictionary *)button {
    __weak KOFormController *weak_self = self;
    int index = [button[@"i"] intValue];
    UIAction *action = [UIAction actionWithTitle:button[@"text"] image:nil identifier:nil handler:^(UIAction *a) {
        [weak_self pressed:index];
    }];
    return [[UIBarButtonItem alloc] initWithPrimaryAction:action];
}

- (void)pressed:(int)button {
    ko_dialog_post(_dialog_id, button, self);
}

- (void)addTextControl:(NSDictionary *)spec toStack:(UIStackView *)stack {
    UITextView *text_view = [[UITextView alloc] init];
    text_view.text = spec[@"text"];
    text_view.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    text_view.editable = ![spec[@"readonly"] boolValue];
    text_view.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    text_view.layer.cornerRadius = 10;
    text_view.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    [text_view.heightAnchor constraintGreaterThanOrEqualToConstant:220].active = YES;
    [text_view setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [stack addArrangedSubview:text_view];
    [_controls addObject:text_view];
    if (text_view.editable) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [text_view becomeFirstResponder];
        });
    }
}

- (void)addDateControl:(NSDictionary *)spec toStack:(UIStackView *)stack {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    BOOL is_time = [spec[@"mode"] isEqual:@"time"];
    formatter.dateFormat = is_time ? @"HH:mm" : @"yyyy-MM-dd";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    UIDatePicker *picker = [[UIDatePicker alloc] init];
    picker.datePickerMode = is_time ? UIDatePickerModeTime : UIDatePickerModeDate;
    picker.preferredDatePickerStyle = UIDatePickerStyleWheels;
    picker.date = [formatter dateFromString:spec[@"value"]] ?: NSDate.date;
    [stack addArrangedSubview:picker];
    [_controls addObject:@[ picker, formatter ]];
}

- (NSArray<NSString *> *)dialogValues {
    NSMutableArray *values = [NSMutableArray array];
    for (id control in _controls) {
        if ([control isKindOfClass:[KONumberControl class]]) {
            [values addObject:[(KONumberControl *)control value]];
        } else if ([control isKindOfClass:[UITextView class]]) {
            [values addObject:((UITextView *)control).text ?: @""];
        } else {
            NSArray *date_control = control;
            [values addObject:[date_control[1] stringFromDate:((UIDatePicker *)date_control[0]).date]];
        }
    }
    return values;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.title = _spec[@"title"];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 20;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor constant:20],
        [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor constant:-40],
    ]];

    if ([_spec[@"message"] length] > 0) {
        UILabel *message = [[UILabel alloc] init];
        message.text = _spec[@"message"];
        message.numberOfLines = 0;
        message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        message.textColor = UIColor.secondaryLabelColor;
        [stack addArrangedSubview:message];
    }
    for (NSDictionary *control in _spec[@"controls"]) {
        if ([control[@"kind"] isEqual:@"text"]) {
            [self addTextControl:control toStack:stack];
        } else if ([control[@"kind"] isEqual:@"date"]) {
            [self addDateControl:control toStack:stack];
        } else {
            KONumberControl *number = [[KONumberControl alloc] initWithSpec:control];
            [_controls addObject:number];
            [stack addArrangedSubview:number.view];
        }
    }
    __weak KOFormController *weak_self = self;
    for (NSDictionary *button in _spec[@"buttons"]) {
        NSString *role = button[@"role"];
        if ([role isEqual:@"cancel"]) {
            self.navigationItem.leftBarButtonItem = [self barItem:button];
        } else if ([role isEqual:@"ok"]) {
            UIBarButtonItem *item = [self barItem:button];
            item.style = UIBarButtonItemStyleDone;
            self.navigationItem.rightBarButtonItem = item;
        } else {
            int index = [button[@"i"] intValue];
            UIButtonConfiguration *configuration = UIButtonConfiguration.tintedButtonConfiguration;
            configuration.title = button[@"text"];
            UIButton *view = [UIButton buttonWithConfiguration:configuration primaryAction:
                [UIAction actionWithHandler:^(UIAction *a) { [weak_self pressed:index]; }]];
            view.enabled = [button[@"enabled"] boolValue];
            [stack addArrangedSubview:view];
        }
    }
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    ko_dialog_post(_dialog_id, 0, self);
}

@end

static UIViewController *ko_form_wrapped(NSDictionary *spec, int dialog_id) {
    KOFormController *form = [[KOFormController alloc] initWithSpec:spec dialogId:dialog_id];
    UINavigationController *nav = [[KOSheetNavigationController alloc] initWithRootViewController:form];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    BOOL has_text = NO;
    for (NSDictionary *control in spec[@"controls"]) {
        has_text = has_text || [control[@"kind"] isEqual:@"text"];
    }
    UISheetPresentationController *sheet = nav.sheetPresentationController;
    sheet.detents = has_text ? @[ UISheetPresentationControllerDetent.largeDetent ]
                             : @[ UISheetPresentationControllerDetent.mediumDetent,
                                  UISheetPresentationControllerDetent.largeDetent ];
    sheet.prefersGrabberVisible = YES;
    nav.presentationController.delegate = form;
    /* Typed text shouldn't go with a stray swipe. */
    nav.modalInPresentation = has_text;
    if ([spec[@"dark"] boolValue]) {
        nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    return nav;
}

static void ko_form_show(NSDictionary *spec) {
    int dialog_id = [spec[@"id"] intValue];
    UIViewController *form = ko_form_wrapped(spec, dialog_id);
    g_alerts[@(dialog_id)] = form;
    ko_dialog_enqueue(^(dispatch_block_t done) {
        ko_dialog_present(form, dialog_id, done);
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
        if ([spec[@"controls"] count] > 0) {
            ko_form_show(spec);
        } else {
            ko_dialog_show(spec);
        }
    });
}

void ko_ios_dialog_close(int dialog_id) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *alert = g_alerts[@(dialog_id)];
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
