//
//  ViewController.m
//  Twilio Voice Quickstart - Objective-C
//
//  Copyright © 2016-2017 Twilio, Inc. All rights reserved.
//

#import "ViewController.h"

@import AVFoundation;
@import PushKit;
@import TwilioVoice;

static NSString *const kYourServerBaseURLString = <#URL TO YOUR ACCESS TOKEN SERVER#>;
static NSString *const kAccessTokenEndpoint = @"/accessToken";

@interface ViewController () <PKPushRegistryDelegate, TVONotificationDelegate, TVOCallDelegate, AVAudioPlayerDelegate>
@property (nonatomic, strong) NSString *deviceTokenString;

@property (nonatomic, strong) PKPushRegistry *voipRegistry;
@property (nonatomic, strong) TVOCallInvite *callInvite;
@property (nonatomic, strong) TVOCall *call;

@property (nonatomic, weak) IBOutlet UIImageView *iconView;
@property (nonatomic, assign, getter=isSpinning) BOOL spinning;

@property (nonatomic, weak) IBOutlet UIButton *placeCallButton;
@property (nonatomic, strong) UIAlertController* incomingAlertController;

@property (nonatomic, strong) AVAudioPlayer *ringtonePlayer;
typedef void (^RingtonePlaybackCallback)(void);
@property (nonatomic, strong) RingtonePlaybackCallback ringtonePlaybackCallback;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [TwilioVoice setLogLevel:TVOLogLevelVerbose];

    self.voipRegistry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
    self.voipRegistry.delegate = self;
    self.voipRegistry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];

    [self toggleUIState:YES];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}

- (NSString *)fetchAccessToken {
    NSString *accessTokenURLString = [kYourServerBaseURLString stringByAppendingString:kAccessTokenEndpoint];

    NSString *accessToken = [NSString stringWithContentsOfURL:[NSURL URLWithString:accessTokenURLString]
                                                     encoding:NSUTF8StringEncoding
                                                        error:nil];
    return accessToken;
}

- (IBAction)placeCall:(id)sender {
    if (self.call) {
        [self.call disconnect];
        [self toggleUIState:NO];
    } else {
        __weak typeof(self) weakSelf = self;
        [self playOutgoingRingtone:^{
            __strong typeof(self) strongSelf = weakSelf;
            strongSelf.call = [TwilioVoice call:[strongSelf fetchAccessToken]
                                         params:@{}
                                       delegate:strongSelf];
        }];
        
        [self toggleUIState:NO];
        [self startSpin];
    }
}

- (void)toggleUIState:(BOOL)isEnabled {
    self.placeCallButton.enabled = isEnabled;
}

#pragma mark - PKPushRegistryDelegate
- (void)pushRegistry:(PKPushRegistry *)registry didUpdatePushCredentials:(PKPushCredentials *)credentials forType:(NSString *)type {
    NSLog(@"pushRegistry:didUpdatePushCredentials:forType:");

    if ([type isEqualToString:PKPushTypeVoIP]) {
        self.deviceTokenString = [credentials.token description];
        NSString *accessToken = [self fetchAccessToken];

        [TwilioVoice registerWithAccessToken:accessToken
                                 deviceToken:self.deviceTokenString
                                  completion:^(NSError *error) {
             if (error) {
                 NSLog(@"An error occurred while registering: %@", [error localizedDescription]);
             }
             else {
                 NSLog(@"Successfully registered for VoIP push notifications.");
             }
         }];
    }
}

- (void)pushRegistry:(PKPushRegistry *)registry didInvalidatePushTokenForType:(PKPushType)type {
    NSLog(@"pushRegistry:didInvalidatePushTokenForType:");

    if ([type isEqualToString:PKPushTypeVoIP]) {
        NSString *accessToken = [self fetchAccessToken];

        [TwilioVoice unregisterWithAccessToken:accessToken
                                   deviceToken:self.deviceTokenString
                                    completion:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"An error occurred while unregistering: %@", [error localizedDescription]);
            }
            else {
                NSLog(@"Successfully unregistered for VoIP push notifications.");
            }
        }];

        self.deviceTokenString = nil;
    }
}

- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload forType:(NSString *)type {
    NSLog(@"pushRegistry:didReceiveIncomingPushWithPayload:forType:");
    if ([type isEqualToString:PKPushTypeVoIP]) {
        [TwilioVoice handleNotification:payload.dictionaryPayload
                               delegate:self];
    }
}

#pragma mark - TVONotificationDelegate
- (void)callInviteReceived:(TVOCallInvite *)callInvite {
    if (callInvite.state == TVOCallInviteStatePending) {
        [self handleCallInviteReceived:callInvite];
    } else if (callInvite.state == TVOCallInviteStateCanceled) {
        [self handleCallInviteCanceled:callInvite];
    }
}

- (void)handleCallInviteReceived:(TVOCallInvite *)callInvite {
    NSLog(@"callInviteReceived:");
    
    if (self.callInvite && self.callInvite.state == TVOCallInviteStatePending) {
        NSLog(@"Already a pending call invite. Ignoring incoming call invite from %@", callInvite.from);
        return;
    }
    if (self.call && self.call.state == TVOCallStateConnected) {
        NSLog(@"Already an active call. Ignoring incoming call invite from %@", callInvite.from);
        return;
    }
    
    self.callInvite = callInvite;

    NSString *from = callInvite.from;
    NSString *alertMessage = [NSString stringWithFormat:@"From %@", from];
    
    [self playIncomingRingtone];

    self.incomingAlertController = [UIAlertController alertControllerWithTitle:@"Incoming" message:alertMessage preferredStyle:UIAlertControllerStyleAlert];

    typeof(self) __weak weakSelf = self;

    UIAlertAction *reject = [UIAlertAction actionWithTitle:@"Reject" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        typeof(self) __strong strongSelf = weakSelf;
        [strongSelf stopIncomingRingtone];
        [callInvite reject];
        strongSelf.callInvite = nil;

        strongSelf.incomingAlertController = nil;
        [strongSelf toggleUIState:YES];
    }];
    [self.incomingAlertController addAction:reject];

    UIAlertAction *ignore = [UIAlertAction actionWithTitle:@"Ignore" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        /* To ignore the call invite, you don't have to do anything but just literally ignore it */
        typeof(self) __strong strongSelf = weakSelf;
        [strongSelf stopIncomingRingtone];

        strongSelf.callInvite = nil;
        strongSelf.incomingAlertController = nil;
        [strongSelf toggleUIState:YES];
    }];
    [self.incomingAlertController addAction:ignore];

    UIAlertAction *accept = [UIAlertAction actionWithTitle:@"Accept" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        typeof(self) __strong strongSelf = weakSelf;
        [strongSelf stopIncomingRingtone];
        strongSelf.call = [callInvite acceptWithDelegate:strongSelf];
        strongSelf.callInvite = nil;

        strongSelf.incomingAlertController = nil;
        [strongSelf startSpin];
    }];
    [self.incomingAlertController addAction:accept];

    [self toggleUIState:NO];
    [self presentViewController:self.incomingAlertController animated:YES completion:nil];

    // If the application is not in the foreground, post a local notification
    if ([[UIApplication sharedApplication] applicationState] != UIApplicationStateActive) {
        UIApplication* app = [UIApplication sharedApplication];
        UILocalNotification* notification = [[UILocalNotification alloc] init];
        notification.alertBody = [NSString stringWithFormat:@"Incoming Call from %@", callInvite.from];

        [app presentLocalNotificationNow:notification];
    }
}

- (void)handleCallInviteCanceled:(TVOCallInvite *)callInvite {
    NSLog(@"callInviteCanceled:");
    
    if (![callInvite.callSid isEqualToString:self.callInvite.callSid]) {
        NSLog(@"Incoming (but not current) call invite from \"%@\" canceled. Just ignore it.", callInvite.from);
        return;
    }
    
    [self stopIncomingRingtone];
    [self playDisconnectSound];

    if (self.incomingAlertController) {
        typeof(self) __weak weakSelf = self;

        [self dismissViewControllerAnimated:YES completion:^{
            typeof(self) __strong strongSelf = weakSelf;
            strongSelf.incomingAlertController = nil;
            [strongSelf toggleUIState:YES];
        }];
    }
    
    self.callInvite = nil;

    [[UIApplication sharedApplication] cancelAllLocalNotifications];
}

- (void)notificationError:(NSError *)error {
    NSLog(@"notificationError: %@", [error localizedDescription]);
}

#pragma mark - TVOCallDelegate
- (void)callDidConnect:(TVOCall *)call {
    NSLog(@"callDidConnect:");

    self.call = call;
    
    [self.placeCallButton setTitle:@"Hang Up" forState:UIControlStateNormal];
    
    [self toggleUIState:YES];
    [self stopSpin];
    [self routeAudioToSpeaker];
}

- (void)call:(TVOCall *)call didFailToConnectWithError:(NSError *)error {
    NSLog(@"Call failed to connect: %@", error);
    
    [self callDisconnected];
}

- (void)call:(TVOCall *)call didDisconnectWithError:(NSError *)error {
    if (error) {
        NSLog(@"Call failed: %@", error);
    } else {
        NSLog(@"Call disconnected");
    }
    
    [self callDisconnected];
}

- (void)callDisconnected {
    self.call = nil;
    
    [self playDisconnectSound];
    [self.placeCallButton setTitle:@"Place Outgoing Call" forState:UIControlStateNormal];
    [self toggleUIState:YES];
    [self stopSpin];
}

#pragma mark - AVAudioSession
- (void)routeAudioToSpeaker {
    NSError * error;
    if (![[AVAudioSession sharedInstance] overrideOutputAudioPort:kAudioSessionOverrideAudioRoute_Speaker
                                                            error:&error]) {
        NSLog(@"Failed to route audio to speaker: %@", [error localizedDescription]);
    }
}

#pragma mark - Ringtone player & AVAudioPlayerDelegate
- (void)playOutgoingRingtone:(RingtonePlaybackCallback)completion {
    self.ringtonePlaybackCallback = completion;
    
    NSString *ringtonePath = [[NSBundle mainBundle] pathForResource:@"outgoing" ofType:@"wav"];
    if ([ringtonePath length] <= 0) {
        NSLog(@"Can't find outgoing sound file");
        if (self.ringtonePlaybackCallback) {
            self.ringtonePlaybackCallback();
        }
        return;
    }
    
    self.ringtonePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL URLWithString:ringtonePath] error:nil];
    self.ringtonePlayer.delegate = self;
    
    [self playRingtone];
}

- (void)playIncomingRingtone {
    NSString *ringtonePath = [[NSBundle mainBundle] pathForResource:@"incoming" ofType:@"wav"];
    if ([ringtonePath length] <= 0) {
        NSLog(@"Can't find incoming sound file");
        return;
    }
    
    self.ringtonePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL URLWithString:ringtonePath] error:nil];
    self.ringtonePlayer.delegate = self;
    self.ringtonePlayer.numberOfLoops = -1;
    
    [self playRingtone];
}

- (void)stopIncomingRingtone {
    if (!self.ringtonePlayer.isPlaying) {
        return;
    }
    
    [self.ringtonePlayer stop];
    NSError *error = nil;
    if (![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord
                                                error:&error]) {
        NSLog(@"Failed to reset AVAudioSession category: %@", [error localizedDescription]);
    }
}

- (void)playDisconnectSound {
    NSString *ringtonePath = [[NSBundle mainBundle] pathForResource:@"disconnect" ofType:@"wav"];
    if ([ringtonePath length] <= 0) {
        NSLog(@"Can't find disconnect sound file");
        return;
    }
    
    self.ringtonePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL URLWithString:ringtonePath] error:nil];
    self.ringtonePlayer.delegate = self;
    self.ringtonePlaybackCallback = nil;
    
    [self playRingtone];
}

- (void)playRingtone {
    NSError *error = nil;
    if (![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                                error:&error]) {
        NSLog(@"Unable to reroute audio: %@", [error localizedDescription]);
    }
    
    self.ringtonePlayer.volume = 1.0f;
    [self.ringtonePlayer play];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (self.ringtonePlaybackCallback) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            strongSelf.ringtonePlaybackCallback();
        });
        
        NSError *error = nil;
        if (![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord
                                                    error:&error]) {
            NSLog(@"Unable to reroute audio: %@", [error localizedDescription]);
        }
    }
}

#pragma mark - Icon spinning
- (void)startSpin {
    if (!self.isSpinning) {
        self.spinning = YES;
        [self spinWithOptions:UIViewAnimationOptionCurveEaseIn];
    }
}

- (void)stopSpin {
    self.spinning = NO;
}

- (void)spinWithOptions:(UIViewAnimationOptions)options {
    typeof(self) __weak weakSelf = self;

    [UIView animateWithDuration:0.5f
                          delay:0.0f
                        options:options
                     animations:^{
                         typeof(self) __strong strongSelf = weakSelf;
                         strongSelf.iconView.transform = CGAffineTransformRotate(strongSelf.iconView.transform, M_PI / 2);
                     }
                     completion:^(BOOL finished) {
                         typeof(self) __strong strongSelf = weakSelf;
                         if (finished) {
                             if (strongSelf.isSpinning) {
                                 [strongSelf spinWithOptions:UIViewAnimationOptionCurveLinear];
                             } else if (options != UIViewAnimationOptionCurveEaseOut) {
                                 [strongSelf spinWithOptions:UIViewAnimationOptionCurveEaseOut];
                             }
                         }
                     }];
}


@end
