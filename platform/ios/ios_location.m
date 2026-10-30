/* One-shot location request for frontend/device/sdl/device.lua.
 *
 * Like the file picker, this is "start + poll": Lua calls start, then polls
 * from a UIManager timer, so CoreLocation's callbacks never touch Lua. */

#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

typedef enum {
    KO_LOCATION_PENDING = 0,
    KO_LOCATION_OK = 1,
    KO_LOCATION_DENIED = 2,
    KO_LOCATION_ERROR = 3,
} ko_location_state_t;

static volatile ko_location_state_t g_location_state = KO_LOCATION_PENDING;
static double g_latitude, g_longitude, g_altitude;
static bool g_has_altitude = false;
static bool g_requesting = false;
static CLLocationManager *g_manager = nil;
static id g_location_delegate = nil;

static void ko_location_finish(ko_location_state_t state) {
    g_requesting = false;
    g_location_state = state;
}

static void ko_location_proceed(void) {
    if (!g_requesting) {
        return;
    }
    switch (g_manager.authorizationStatus) {
        case kCLAuthorizationStatusNotDetermined:
            [g_manager requestWhenInUseAuthorization];
            break;
        case kCLAuthorizationStatusAuthorizedWhenInUse:
        case kCLAuthorizationStatusAuthorizedAlways:
            [g_manager requestLocation];
            break;
        default:
            ko_location_finish(KO_LOCATION_DENIED);
            break;
    }
}

@interface KOLocationDelegate : NSObject <CLLocationManagerDelegate>
@end

@implementation KOLocationDelegate

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if (manager.authorizationStatus != kCLAuthorizationStatusNotDetermined) {
        ko_location_proceed();
    }
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *location = locations.lastObject;
    g_latitude = location.coordinate.latitude;
    g_longitude = location.coordinate.longitude;
    g_has_altitude = location.verticalAccuracy >= 0;
    g_altitude = location.altitude;
    ko_location_finish(KO_LOCATION_OK);
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    ko_location_finish(error.code == kCLErrorDenied ? KO_LOCATION_DENIED : KO_LOCATION_ERROR);
}

@end

void ko_ios_location_start(void) {
    g_location_state = KO_LOCATION_PENDING;
    dispatch_async(dispatch_get_main_queue(), ^{
        g_requesting = true;
        if (!g_manager) {
            g_location_delegate = [[KOLocationDelegate alloc] init];
            g_manager = [[CLLocationManager alloc] init];
            g_manager.desiredAccuracy = kCLLocationAccuracyKilometer;
            g_manager.delegate = g_location_delegate;
        }
        ko_location_proceed();
    });
}

/* Coordinates are only set for KO_LOCATION_OK; altitude only when has_altitude. */
int ko_ios_location_poll(double *latitude, double *longitude, double *altitude, int *has_altitude) {
    ko_location_state_t state = g_location_state;
    if (state == KO_LOCATION_OK) {
        *latitude = g_latitude;
        *longitude = g_longitude;
        *altitude = g_altitude;
        *has_altitude = g_has_altitude;
    }
    return state;
}
