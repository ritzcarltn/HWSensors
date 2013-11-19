//
//  HWMEngine.m
//  HWMonitor
//
//  Created by Kozlek on 15/11/13.
//  Copyright (c) 2013 kozlek. All rights reserved.
//

#import "HWMEngine.h"
#import "HWMIcon.h"
#import "HWMGroup.h"
#import "HWMSmcSensor.h"
#import "HWMSmcFanSensor.h"
#import "HWMAtaSmartSensor.h"
#import "HWMBatterySensor.h"
#import "HWMConfiguration.h"

#import "smc.h"
#import "Localizer.h"

#import "HWMonitorDefinitions.h"
#import "FakeSMCDefinitions.h"


@implementation HWMEngine

#pragma mark
#pragma mark Global methods

+(HWMEngine*)engineWithBundle:(NSBundle*)bundle;
{
    HWMEngine *me = [[HWMEngine alloc] init];

    if (me) {
        me.bundle = bundle;
    }

    return me;
}

#pragma mark
#pragma mark Properties

-(NSManagedObjectModel *)managedObjectModel
{
    if (!_managedObjectModel) {
        _managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:[self.bundle pathForResource:@"HWMEngine" ofType:@"momd"]]];
    }

    return _managedObjectModel;
}

-(NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (!_persistentStoreCoordinator && self.managedObjectModel) {

        _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.managedObjectModel];

        NSError *error = nil;

        NSString *path = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) lastObject];
        NSURL *url= [NSURL fileURLWithPath:[path stringByAppendingPathComponent: @"HWMonitor/Configuration.xml"]];

        if (![_persistentStoreCoordinator addPersistentStoreWithType:NSXMLStoreType configuration:nil URL:url options:@{ @YES : NSMigratePersistentStoresAutomaticallyOption, @YES : NSInferMappingModelAutomaticallyOption } error:&error]) {

            NSLog(@"incompatible managed model, deleting database %@...", url.path);

            // try to delete incompatible store
            if (![[NSFileManager defaultManager] removeItemAtURL:url error:&error]) {
                NSLog(@"deleting incompatible database error %@", error);
            }

            if (![_persistentStoreCoordinator addPersistentStoreWithType:NSXMLStoreType configuration:nil URL:url options:nil error:&error]) {
                NSLog(@"adding new persistent store error %@", error);
            }
        }
    }

    return _persistentStoreCoordinator;
}

-(NSManagedObjectContext*)managedObjectContext
{
    if (!_managedObjectContext) {
        _managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        _managedObjectContext.persistentStoreCoordinator = self.persistentStoreCoordinator;
    }
    
    return _managedObjectContext;
}

-(void)setEngineState:(HWMEngineState)engineState
{
    switch (engineState) {
        case kHWMEngineIdle:
            if (_engineState == kHWMEngineActive) {
                [self internalStopEngine];
            }
            break;

        case kHWMEngineActive:
            if (_engineState == kHWMEngineIdle) {
                [self internalStartEngine];
            }
            break;

        default:
            break;
    }

    _engineState = engineState;
}

-(NSArray *)arrangedItems
{
    if (!_arrangedItems) {
        [self willChangeValueForKey:@"arrangedItems"];

        _arrangedItems = [NSMutableArray array];

        // Icons
        NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Icon"];

        NSError *error;

        NSArray *icons = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];

        if (error) {
            NSLog(@"fetch icons in arrangedItems error %@", error);
        }
        else {
            NSSortDescriptor *titleDescriptor = [[NSSortDescriptor alloc] initWithKey:@"title" ascending:YES];
            [_arrangedItems addObjectsFromArray:[icons sortedArrayUsingDescriptors:@[titleDescriptor]]];
        }

        // Sensors and groups
        fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Group"];

        NSArray *groups = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];

        if (error) {
            NSLog(@"fetch groups in arrangedItems error %@", error);
        }
        else {
            NSSortDescriptor *orderDescriptor = [[NSSortDescriptor alloc] initWithKey:@"order" ascending:YES];

            groups = [groups sortedArrayUsingDescriptors:@[orderDescriptor]];

            for (HWMGroup *group in groups) {

                fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Sensor"];

                [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"hidden == 0 AND group == %@", group]];

                NSArray *sensors = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];

                if (error) {
                    NSLog(@"fetch sensors in arrangedItems error %@", error);
                }
                else if (sensors.count) {
                    [_arrangedItems addObject:group];
                    [_arrangedItems addObjectsFromArray:[sensors sortedArrayUsingDescriptors:@[orderDescriptor]]];
                }
            }
        }

        [self didChangeValueForKey:@"arrangedItems"];
    }

    return _arrangedItems;
}

-(NSArray *)favoriteItems
{
    if (!_favoriteItems) {
        [self willChangeValueForKey:@"favoriteItems"];

        NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Favorite"];

        NSError *error;

        NSArray *favorites = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];

        if (error) {
            NSLog(@"fetch favorite items in favoriteItems error %@", error);
        }
        else {
            NSSortDescriptor *orderDescriptor = [[NSSortDescriptor alloc] initWithKey:@"order" ascending:YES];
            [_arrangedItems addObjectsFromArray:[favorites sortedArrayUsingDescriptors:@[orderDescriptor]]];
        }

        [self didChangeValueForKey:@"favoriteItems"];
    }

    return _favoriteItems;
}

#pragma mark
#pragma mark Overriden Methods

- (id)init;
{
    self = [super init];

    if (self) {
        _bundle = [NSBundle mainBundle];
    }

    return self;
}

#pragma mark
#pragma mark Private Methods

- (void)initialize
{
    // Create or load configuration entity
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Configuration"];

    NSError *error;

    _configuration = [[self.managedObjectContext executeFetchRequest:fetchRequest error:&error] lastObject];

    if (error) {
        NSLog(@"failed to retrieve configuration %@", error);
    }

    if (!_configuration) {
        _configuration = [NSEntityDescription insertNewObjectForEntityForName:@"Configuration" inManagedObjectContext:self.managedObjectContext];
    }

    [self assignPlatformProfile];

    [self loadIconNamed:kHWMonitorIconDefault];
    [self loadIconNamed:kHWMonitorIconThermometer];
    [self loadIconNamed:kHWMonitorIconScale];
    [self loadIconNamed:kHWMonitorIconDevice];
    [self loadIconNamed:kHWMonitorIconTemperatures];
    [self loadIconNamed:kHWMonitorIconHddTemperatures];
    [self loadIconNamed:kHWMonitorIconSsdLife];
    [self loadIconNamed:kHWMonitorIconMultipliers];
    [self loadIconNamed:kHWMonitorIconFrequencies];
    [self loadIconNamed:kHWMonitorIconTachometers];
    [self loadIconNamed:kHWMonitorIconVoltages];
    [self loadIconNamed:kHWMonitorIconBattery];

    NSUInteger nextGroupOrder = 0;

    [self insertGroupWithSelector:kHWMGroupTemperature name:@"TEMPERATURES" icon:[self getIconByName:kHWMonitorIconTemperatures] nextOrder:&nextGroupOrder];
    [self insertGroupWithSelector:kHWMGroupSmartTemperature name:@"TEMPERATURES" icon:[self getIconByName:kHWMonitorIconTemperatures] nextOrder:&nextGroupOrder];
    [self insertGroupWithSelector:kHWMGroupSmartRemainingLife name:@"SSD REMAINING LIFE" icon:[self getIconByName:kHWMonitorIconSsdLife] nextOrder:&nextGroupOrder];
    [self insertGroupWithSelector:kHWMGroupSmartRemainingBlocks name:@"SSD REMAINING BLOCKS" icon:[self getIconByName:kHWMonitorIconSsdLife] nextOrder:&nextGroupOrder];
    [self insertGroupWithSelector:kHWMGroupFrequency name:@"FREQUENCIES" icon:[self getIconByName:kHWMonitorIconFrequencies] nextOrder:&nextGroupOrder];
    [self insertGroupWithSelector:kHWMGroupTachometer name:@"FANS & PUMPS" icon:[self getIconByName:kHWMonitorIconTachometers] nextOrder:&nextGroupOrder];
    [self insertGroupWithSelector:kHWMGroupVoltage name:@"VOLTAGES" icon:[self getIconByName:kHWMonitorIconVoltages] nextOrder:&nextGroupOrder];
    [self insertGroupWithSelector:kHWMGroupCurrent name:@"CURRENTS" icon:[self getIconByName:kHWMonitorIconVoltages] nextOrder:&nextGroupOrder];
    [self insertGroupWithSelector:kHWMGroupPower name:@"POWER CONSUMPTION" icon:[self getIconByName:kHWMonitorIconVoltages] nextOrder:&nextGroupOrder];
    [self insertGroupWithSelector:kHWMGroupBattery name:@"BATTERIES" icon:[self getIconByName:kHWMonitorIconBattery] nextOrder:&nextGroupOrder];

    [self rebuildSensorsList];

    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver: self selector: @selector(workspaceDidMountOrUnmount:) name:NSWorkspaceDidMountNotification object:nil];
	[[[NSWorkspace sharedWorkspace] notificationCenter] addObserver: self selector: @selector(workspaceDidMountOrUnmount:) name:NSWorkspaceDidUnmountNotification object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(workspaceWillSleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(workspaceDidWake:) name:NSWorkspaceDidWakeNotification object:nil];


    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willTerminate:) name:NSApplicationWillTerminateNotification object:nil];

    [self addObserver:self forKeyPath:@"configuration.smcSensorsUpdateRate" options:NSKeyValueObservingOptionNew context:nil];
    [self addObserver:self forKeyPath:@"configuration.smartSensorsUpdateRate" options:NSKeyValueObservingOptionNew context:nil];
}

- (void)assignPlatformProfile
{
    NSString *model = nil;

    CFDictionaryRef matching = MACH_PORT_NULL;

    if (MACH_PORT_NULL != (matching = IOServiceMatching("FakeSMC"))) {
        io_iterator_t iterator = IO_OBJECT_NULL;

        if (kIOReturnSuccess == IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator)) {
            if (IO_OBJECT_NULL != iterator) {

                io_service_t service = MACH_PORT_NULL;

                if (MACH_PORT_NULL != (service = IOIteratorNext(iterator))) {
                    model = @"Hackintosh";

                    IOObjectRelease(service);
                }

                IOObjectRelease(iterator);
            }
        }
    }

    if (!model) {
        if (MACH_PORT_NULL != (matching = IOServiceMatching("IOPlatformExpertDevice"))) {
            io_iterator_t iterator = IO_OBJECT_NULL;

            if (kIOReturnSuccess == IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator)) {
                if (IO_OBJECT_NULL != iterator) {

                    io_service_t service = MACH_PORT_NULL;

                    if (MACH_PORT_NULL != (service = IOIteratorNext(iterator))) {
                        model = [[NSString alloc] initWithData:(__bridge_transfer NSData *)IORegistryEntryCreateCFProperty(service, CFSTR("model"), kCFAllocatorDefault, 0) encoding:NSASCIIStringEncoding];

                        IOObjectRelease(service);
                    }

                    IOObjectRelease(iterator);
                }
            }
        }
    }

    NSString *config;

    if (model) {
        config = [[NSBundle mainBundle] pathForResource:model ofType:@"plist" inDirectory:@"Profiles"];
    }

    if (!config) {
        config = [[NSBundle mainBundle] pathForResource:@"Default" ofType:@"plist" inDirectory:@"Profiles"];
    }

    if (config) {

        NSLog(@"Loading profile from %@", [config lastPathComponent]);

        NSArray *rawProfile = [[NSArray alloc] initWithContentsOfFile:config];

        if (rawProfile) {

            NSMutableArray *adoptedProfile = [[NSMutableArray alloc] init];

            [rawProfile enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                NSArray *entries = [obj componentsSeparatedByString:@"|"];

                [adoptedProfile addObject:[NSArray arrayWithObjects:[entries objectAtIndex:0], [entries objectAtIndex:entries.count - 1], nil]];
            }];

            _platformProfile = [NSArray arrayWithArray:adoptedProfile];
        }
    }
    
    if (!_platformProfile) {
        NSLog(@"No suitible profile found");
    }
}

-(HWMIcon*)getIconByName:(NSString*)name
{
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Icon"];

    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"name = %@", name]];

    NSError *error;

    HWMIcon *icon = [[self.managedObjectContext executeFetchRequest:fetchRequest error:&error] lastObject];

    if (error) {
        NSLog(@"getIconByName error %@", error);
    }

    return icon;
}

-(HWMGroup*)getGroupBySelector:(NSUInteger)selector
{
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Group"];

    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"selector = %d", selector]];

    NSError *error;

    HWMGroup *group = [[self.managedObjectContext executeFetchRequest:fetchRequest error:&error] lastObject];

    if (error) {
        NSLog(@"getGroupBySelector error %@", error);
    }

    return group;
}

-(HWMSensor*)getSensorByName:(NSString*)name
{
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Sensor"];

    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"name = %@", name]];

    NSError *error;

    HWMSensor *sensor = [[self.managedObjectContext executeFetchRequest:fetchRequest error:&error] lastObject];

    if (error) {
        NSLog(@"getSensorByName error %@", error);
    }

    return sensor;
}

-(HWMIcon*)loadIconNamed:(NSString*)name
{
    HWMIcon *icon = [self getIconByName:name];

    if (!icon) {
        icon = [NSEntityDescription insertNewObjectForEntityForName:@"Icon" inManagedObjectContext:self.managedObjectContext];
    }

    NSImage *image = [[NSImage alloc] initWithContentsOfFile:[self.bundle pathForResource:name ofType:@"png"]];
    NSImage *alternate = [[NSImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:[name stringByAppendingString:@"_template"] ofType:@"png"]];

    if (image)
        [image setTemplate:YES];

    if (alternate)
        [alternate setTemplate:YES];

    [icon setName:name];
    [icon setImage:image];
    [icon setAlternate:alternate];
    [icon setTitle:GetLocalizedString(name)];

    return icon;
}

-(HWMGroup*)insertGroupWithSelector:(NSUInteger)selector name:(NSString*)name icon:(HWMIcon*)icon nextOrder:(NSUInteger*)nextOrder
{
    HWMGroup *group = [self getGroupBySelector:selector];

    if (!group) {
        group = [NSEntityDescription insertNewObjectForEntityForName:@"Group" inManagedObjectContext:self.managedObjectContext];

        [group setOrder:[NSNumber numberWithInteger:*nextOrder]];

        *nextOrder += 1;
    }

    [group setName:name];
    [group setTitle:GetLocalizedString(group.name)];
    [group setIcon:icon];
    [group setSelector:[NSNumber numberWithInteger:selector]];
    [group setIdentifier:@"Group"];

    //[group setEngine:self];

    return group;
}

-(NSUInteger)getNextOrderValueForSensorsInGroup:(HWMGroup*)group
{
    __block NSUInteger nextOrderValue = 0;

    [group.sensors enumerateObjectsUsingBlock:^(id obj, BOOL *stop) {
        if ([[obj order] unsignedIntegerValue] > nextOrderValue) {
            nextOrderValue = [[obj order] unsignedIntegerValue];
        }
    }];

    return nextOrderValue + 1;
}

- (void)initSmcAndDevicesTimer
{
    if (_smcAndDevicesSensorsUpdateLoopTimer) {
        [_smcAndDevicesSensorsUpdateLoopTimer invalidate];
    }

    _smcAndDevicesSensorsUpdateLoopTimer = [NSTimer timerWithTimeInterval:self.configuration.smcSensorsUpdateRate.floatValue target:self selector:@selector(updateSmcAndDevicesSensors) userInfo:nil repeats:YES];

    [[NSRunLoop mainRunLoop] addTimer:_smcAndDevicesSensorsUpdateLoopTimer forMode:NSRunLoopCommonModes];
}

- (void)initAtaSmartTimer
{
    if (_ataSmartSensorsUpdateLoopTimer) {
        [_ataSmartSensorsUpdateLoopTimer invalidate];
    }

    _ataSmartSensorsUpdateLoopTimer = [NSTimer timerWithTimeInterval:self.configuration.smartSensorsUpdateRate.floatValue * 60.0f target:self selector:@selector(updateAtaSmartSensors) userInfo:nil repeats:YES];

    [[NSRunLoop mainRunLoop] addTimer:_ataSmartSensorsUpdateLoopTimer forMode:NSRunLoopCommonModes];
}

-(void)internalStartEngine
{
    if (_engineState != kHWMEngineActive) {
        if (!_smcAndDevicesSensorsUpdateLoopTimer || ![_smcAndDevicesSensorsUpdateLoopTimer isValid]) {
            [self initSmcAndDevicesTimer];
        }

        if (!_ataSmartSensorsUpdateLoopTimer || ![_ataSmartSensorsUpdateLoopTimer isValid]) {
            [self initAtaSmartTimer];
        }
    }
}

-(void)internalStopEngine
{
    if (_engineState != kHWMEngineIdle) {
        if (_smcAndDevicesSensorsUpdateLoopTimer) {
            [_smcAndDevicesSensorsUpdateLoopTimer invalidate];
            _smcAndDevicesSensorsUpdateLoopTimer = 0;
        }

        if (_ataSmartSensorsUpdateLoopTimer) {
            [_ataSmartSensorsUpdateLoopTimer invalidate];
            _ataSmartSensorsUpdateLoopTimer = 0;
        }
    }
}

#pragma mark
#pragma mark Public Methods

-(void)saveContext
{
    NSError *error;

    if (![self.managedObjectContext save:&error])
        NSLog(@"failed to save context %@", error);
}

-(void)updateSmcAndDevicesSensors
{
    if (!_smcAndDevicesSensors) {

        NSMutableArray *sensors = [NSMutableArray array];

        NSError *error;
        NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Sensor"];

        NSArray *objects = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];

        if (error) {
            NSLog(@"fetching sensors in updateSmcAndDevicesSensors error %@", error);
        }
        else {
            for (HWMSensor *sensor in objects) {
                if (![sensor isKindOfClass:[HWMAtaSmartSensor class]]) {
                    [sensors addObject:sensor];
                }
            }
        }

        _smcAndDevicesSensors = [sensors copy];
    }

    for (id sensor in _smcAndDevicesSensors) {
        BOOL doUpdate = FALSE;

        switch (_updateLoopStrategy) {
            case kHWMSensorsUpdateLoopForced:
                doUpdate = YES;
                break;

            case kHWMSensorsUpdateLoopOnlyFavorites:
                doUpdate = [[sensor favorite] boolValue];
                break;

            case kHWMSensorsUpdateLoopRegular:
            default:
                doUpdate = ![[sensor hidden] boolValue] || [[sensor favorite] boolValue];
                break;
        }

        if (doUpdate) {
            [sensor doUpdateValue];
        }
    }
}

-(void)updateAtaSmartSensors
{
    if (!_ataSmartSensors) {

        NSError *error;
        NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"AtaSmartSensor"];

        _ataSmartSensors = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];

        if (error) {
            NSLog(@"fetching sensors in updateAtaSmartSensors error %@", error);
        }
    }

    for (HWMAtaSmartSensor *sensor in _ataSmartSensors) {

        BOOL doUpdate = FALSE;

        switch (_updateLoopStrategy) {
            case kHWMSensorsUpdateLoopForced:
                doUpdate = YES;
                break;

            case kHWMSensorsUpdateLoopOnlyFavorites:
                doUpdate = sensor.favorite.boolValue;
                break;

            case kHWMSensorsUpdateLoopRegular:
            default:
                doUpdate = !sensor.hidden.boolValue || sensor.favorite.boolValue;
                break;
        }

        if (doUpdate) {
            [sensor doUpdateValue];
        }

    }
}

-(void)rebuildSensorsList
{
    if (_engineState == kHWMEngineActive) {
        [self internalStopEngine];
    }

    NSError *error;

    _smcAndDevicesSensors = nil;

    // SMC

    // Reset "connection" attribute for all SMC sensors
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"SmcSensor"];
    NSArray *objects = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];

    for (HWMSmcSensor *sensor in objects) {
        [sensor setConnection:nil];
    }

    // FakeSMCKeyStore is prioritized key source
    SMCOpen(&_fakeSmcConnection, "FakeSMCKeyStore");
    NSArray *fakeSmcKeys = [self getSmcKeysFromConnection:_fakeSmcConnection excludedList:nil];
    if (!fakeSmcKeys || !fakeSmcKeys.count) SMCClose(_fakeSmcConnection);

    SMCOpen(&_smcConnection, "AppleSMC");
    NSArray *smcKeys = [self getSmcKeysFromConnection:_smcConnection excludedList:fakeSmcKeys];
    if (!smcKeys || !smcKeys.count) SMCClose(_smcConnection);

    [self insertSmcSensorsWithKeys:fakeSmcKeys connection:_fakeSmcConnection];
    [self insertSmcSensorsWithKeys:smcKeys connection:_smcConnection];

    // SMART

    _ataSmartSensors = nil;

    [self insertAtaSmartSensors];

    // FANS

    // Reset "connection" attribute for all fan sensors
    fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"SmcFanSensor"];
    objects = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];

    for (HWMSmcSensor *sensor in objects) {
        [sensor setConnection:nil];
    }

    [self insertSmcFansWithConnection:_fakeSmcConnection keys:fakeSmcKeys];
    [self insertSmcFansWithConnection:_smcConnection keys:smcKeys];

    // Insert additional GPU fans from FakeSMCKeyStore
    [self insertSmcGpuFansWithConnection:_fakeSmcConnection keys:fakeSmcKeys];

    // BATTERIES
    [self insertBatterySensors];

    if (![self.managedObjectContext save:&error])
        NSLog(@"saving context on rebuildSensorsList error %@", error);

    [self willChangeValueForKey:@"arrangedItems"];
    _arrangedItems = nil;
    [self didChangeValueForKey:@"arrangedItems"];

    [self willChangeValueForKey:@"favoriteItems"];
    _favoriteItems = nil;
    [self willChangeValueForKey:@"favoriteItems"];

    if (_engineState == kHWMEngineActive) {
        [self internalStartEngine];
    }
}

-(void)startEngine
{
    [self internalStartEngine];

    _engineState = kHWMEngineActive;
}

-(void)stopEngine
{
    [self internalStopEngine];

    _engineState = kHWMEngineIdle;
}

#pragma mark
#pragma mark SMC Sensors

- (NSArray*)getSmcKeysFromConnection:(io_connect_t)connection excludedList:(NSArray*)excluded
{
    if (!connection)
        return nil;

    SMCVal_t val;

    SMCReadKey(connection, "#KEY", &val);

    UInt32 count = [HWMSmcSensor decodeNumericValueFromBuffer:val.bytes length:val.dataSize type:val.dataType];

    NSMutableArray *array = [[NSMutableArray alloc] init];

    for (UInt32 index = 0; index < count; index++) {
        SMCKeyData_t  inputStructure;
        SMCKeyData_t  outputStructure;

        memset(&inputStructure, 0, sizeof(SMCKeyData_t));
        memset(&outputStructure, 0, sizeof(SMCKeyData_t));
        memset(&val, 0, sizeof(SMCVal_t));

        inputStructure.data8 = SMC_CMD_READ_INDEX;
        inputStructure.data32 = index;

        if (kIOReturnSuccess == SMCCall(connection, KERNEL_INDEX_SMC, &inputStructure, &outputStructure)) {
            NSString *key = [NSString stringWithFormat:@"%c%c%c%c",
                             (unsigned int) outputStructure.key >> 24,
                             (unsigned int) outputStructure.key >> 16,
                             (unsigned int) outputStructure.key >> 8,
                             (unsigned int) outputStructure.key];


            if (!excluded || NSNotFound == [excluded indexOfObject:key]) {
                [array addObject:key];
            }
        }
    }
    
    return array;
}

-(HWMSmcSensor*)getSmcSensorByName:(NSString*)name
{
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"SmcSensor"];

    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"name = %@", name]];

    NSError *error;

    HWMSmcSensor *sensor = [[self.managedObjectContext executeFetchRequest:fetchRequest error:&error] lastObject];

    if (error) {
        NSLog(@"getSmcSensorByName error %@", error);
    }

    return sensor;
}

-(HWMSmcSensor*)insertSmcSensorWithConnection:(io_connect_t)connection name:(NSString*)name type:(NSString*)type title:(NSString*)title selector:(NSUInteger)selector group:(HWMGroup*)group nextOrder:(NSUInteger*)nextOrder
{
    HWMSmcSensor *sensor = [self getSmcSensorByName:name];

    if (!sensor) {
        sensor = [NSEntityDescription insertNewObjectForEntityForName:@"SmcSensor" inManagedObjectContext:self.managedObjectContext];

        [sensor setOrder:[NSNumber numberWithInteger:*nextOrder]];

        *nextOrder += 1;
    }

    [sensor setConnection:[NSNumber numberWithLongLong:connection]];
    [sensor setName:name];
    [sensor setType:type];
    [sensor setSelector:[NSNumber numberWithUnsignedInteger:selector]];

    [sensor setTitle:GetLocalizedString(title)];
    [sensor setIdentifier:@"Sensor"];

    if (![group.sensors containsObject:sensor]) {
        [group addSensorsObject:sensor];
    }

    [sensor setEngine:self];

    return sensor;
}

-(void)insertSmcSensorsWithKeys:(NSArray*)keys connection:(io_connect_t)connection selector:(NSUInteger)selector
{
    if (!connection || !selector)
        return;

    NSString *prefix = nil;
    HWMGroup *group = nil;

    switch (selector) {
        case kHWMGroupTemperature:
            prefix = @"T";
            group = [self getGroupBySelector:kHWMGroupTemperature];
            break;

        case kHWMGroupMultiplier:
            prefix = @"M";
            group = [self getGroupBySelector:kHWMGroupFrequency];
            break;

        case kHWMGroupFrequency:
            prefix = @"C";
            group = [self getGroupBySelector:kHWMGroupFrequency];
            break;

        case kHWMGroupVoltage:
            prefix = @"V";
            group = [self getGroupBySelector:kHWMGroupVoltage];
            break;

        case kHWMGroupCurrent:
            prefix = @"I";
            group = [self getGroupBySelector:kHWMGroupCurrent];
            break;

        case kHWMGroupPower:
            prefix = @"P";
            group = [self getGroupBySelector:kHWMGroupPower];
            break;

        default:
            return;
    }

    __block NSUInteger nextOrderValue = [self getNextOrderValueForSensorsInGroup:group];

    // Excluding all existing keys
    //    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"SmcSensor"];
    //
    //    [fetchRequest setResultType:NSDictionaryResultType];
    //    [fetchRequest setReturnsDistinctResults:YES];
    //    [fetchRequest setPropertiesToFetch:@[@"name"]];
    //
    //    NSError *error;
    //
    //    NSArray *objects = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];
    //
    //    NSArray *excludedKeys = [objects valueForKey:@"name"];

    [_platformProfile enumerateObjectsUsingBlock:^(id item, NSUInteger index, BOOL *stop) {

        NSString *key = [item objectAtIndex:0];

        if ([key hasPrefix:prefix]) {
            NSString *title = [item objectAtIndex:1];

            NSRange formater = [key rangeOfString:@":"];

            if (formater.length) {
                // key and title should be formatted by index
                unsigned int start = 0;
                [[NSScanner scannerWithString:[key substringWithRange:NSMakeRange(formater.location + 1, 1)]] scanHexInt:&start];
                unsigned int count = 0;
                [[NSScanner scannerWithString:[key substringWithRange:NSMakeRange(formater.location + 2, 1)]] scanHexInt:&count];
                unsigned int shift = 0;
                [[NSScanner scannerWithString:[key substringWithRange:NSMakeRange(formater.location + 3, 1)]] scanHexInt:&shift];

                NSString *keyFormat = [NSString stringWithFormat:@"%@%%X%@", [key substringToIndex:formater.location], [key substringFromIndex:formater.location + formater.length + 3]];

                for (NSUInteger index = 0; index < count; index++) {

                    NSString *formattedKey = [NSString stringWithFormat:keyFormat, start + index];

                    if ([keys indexOfObject:formattedKey] != NSNotFound /*&& [excludedKeys indexOfObject:formattedKey] == NSNotFound*/) {

                        SMCVal_t info;

                        if (kIOReturnSuccess == SMCReadKey(connection, [formattedKey cStringUsingEncoding:NSASCIIStringEncoding], &info)) {

                            [self insertSmcSensorWithConnection:connection name:formattedKey type:[NSString stringWithCString:info.dataType encoding:NSASCIIStringEncoding] title:[NSString stringWithFormat:title, shift + index] selector:selector group:group nextOrder:&nextOrderValue];

                        }
                    }
                }
            }
            else if ([keys indexOfObject:key] != NSNotFound /*&& [excludedKeys indexOfObject:key] == NSNotFound*/) {

                SMCVal_t info;

                if (kIOReturnSuccess == SMCReadKey(connection, [key cStringUsingEncoding:NSASCIIStringEncoding], &info)) {
                    [self insertSmcSensorWithConnection:connection name:key type:[NSString stringWithCString:info.dataType encoding:NSASCIIStringEncoding] title:title selector:selector group:group nextOrder:&nextOrderValue];

                }
            }
        }

    }];
}

-(void)insertSmcSensorsWithKeys:(NSArray*)keys connection:(io_connect_t)connection
{
    [self insertSmcSensorsWithKeys:keys connection:connection selector:kHWMGroupTemperature];
    [self insertSmcSensorsWithKeys:keys connection:connection selector:kHWMGroupMultiplier];
    [self insertSmcSensorsWithKeys:keys connection:connection selector:kHWMGroupFrequency];
    [self insertSmcSensorsWithKeys:keys connection:connection selector:kHWMGroupVoltage];
    [self insertSmcSensorsWithKeys:keys connection:connection selector:kHWMGroupCurrent];
    [self insertSmcSensorsWithKeys:keys connection:connection selector:kHWMGroupPower];
}

#pragma mark
#pragma mark ATA SMART Sensors

-(HWMAtaSmartSensor*)getAtaSmartSensorByName:(NSString*)name
{
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"AtaSmartSensor"];

    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"name = %@", name]];

    NSError *error;

    HWMAtaSmartSensor *sensor = [[self.managedObjectContext executeFetchRequest:fetchRequest error:&error] lastObject];

    if (error) {
        NSLog(@"getAtaSmartSensorByName error %@", error);
    }

    return sensor;
}

-(HWMAtaSmartSensor*)insertAtaSmartSensorFromDictionary:(NSDictionary*)attributes group:(HWMGroup*)group
{
    NSString *name = [NSString stringWithFormat:@"%@%@", [attributes objectForKey:@"serialNumber"], group.selector];

    HWMAtaSmartSensor *sensor = [self getAtaSmartSensorByName:name];

    if (!sensor) {
        sensor = [NSEntityDescription insertNewObjectForEntityForName:@"AtaSmartSensor" inManagedObjectContext:self.managedObjectContext];

        NSUInteger nextOrderValue = [self getNextOrderValueForSensorsInGroup:group];

        [sensor setOrder:[NSNumber numberWithInteger:nextOrderValue]];
    }

    [sensor setService:[attributes objectForKey:@"service"]];
    [sensor setSelector:group.selector];

    [sensor doUpdateValue];

    if (sensor.value) {
        [sensor setName:name];
        [sensor setProductName:[attributes objectForKey:@"productName"]];
        [sensor setBsdName:[attributes objectForKey:@"bsdName"]];
        [sensor setVolumeNames:[attributes objectForKey:@"volumesNames"]];
        [sensor setSerialNumber:[attributes objectForKey:@"serialNumber"]];
        [sensor setRotational:[attributes objectForKey:@"rotational"]];
        [sensor setIdentifier:@"Sensor"];

        [sensor setEngine:self];

        if (![group.sensors containsObject:sensor]) {
            [group addSensorsObject:sensor];
        }
    }
    else {
        [self.managedObjectContext deleteObject:sensor];
    }

    return sensor;
}

-(void)insertAtaSmartSensors
{
    NSError *error;

    // Reset "service" attribute for all smart sensors
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"AtaSmartSensor"];
    NSArray *objects = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];

    for (HWMAtaSmartSensor *sensor in objects) {
        [sensor setService:nil];
    }

    HWMGroup *smartTemperatures = [self getGroupBySelector:kHWMGroupSmartTemperature];
    HWMGroup *smartLife = [self getGroupBySelector:kHWMGroupSmartRemainingLife];
    HWMGroup *smartBlocks = [self getGroupBySelector:kHWMGroupSmartRemainingBlocks];

    NSArray *drives = [HWMAtaSmartSensor discoverDrives];

    for (id drive in drives) {
        [self insertAtaSmartSensorFromDictionary:drive group:smartTemperatures];
        [self insertAtaSmartSensorFromDictionary:drive group:smartLife];
        [self insertAtaSmartSensorFromDictionary:drive group:smartBlocks];
    }
}

#pragma mark
#pragma mark SMC Fan Sensors

-(HWMSmcFanSensor*)insertSmcFanWithConnection:(io_connect_t)connection name:(NSString*)name type:(NSString*)type title:(NSString*)title selector:(NSUInteger)selector group:(HWMGroup*)group nextOrder:(NSUInteger*)nextOrder
{
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"SmcFanSensor"];

    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"unique = %@", title]];

    NSError *error;

    HWMSmcFanSensor *fan = [[self.managedObjectContext executeFetchRequest:fetchRequest error:&error] lastObject];

    if (error) {
        NSLog(@"get sensor by title error in insertSmcFanWithConnection %@", error);
    }


    if (!fan) {
        fan = [NSEntityDescription insertNewObjectForEntityForName:@"SmcFanSensor" inManagedObjectContext:self.managedObjectContext];

        [fan setOrder:[NSNumber numberWithInteger:*nextOrder]];

        *nextOrder += 1;
    }

    [fan setConnection:[NSNumber numberWithLongLong:connection]];
    [fan setName:name];
    [fan setType:type];
    [fan setSelector:[NSNumber numberWithUnsignedInteger:selector]];

    [fan setTitle:GetLocalizedString(title)];
    // Uniqie is the same as title, but not transient and not localized
    [fan setUnique:title];
    [fan setIdentifier:@"Sensor"];

    if (![group.sensors containsObject:fan]) {
        [group addSensorsObject:fan];
    }
    
    [fan setEngine:self];

    return fan;
}

- (void)insertSmcFansWithConnection:(io_connect_t)connection keys:(NSArray*)keys
{
    HWMGroup *group = [self getGroupBySelector:kHWMGroupTachometer];
    NSUInteger nextOrderValue = [self getNextOrderValueForSensorsInGroup:group];

    for (int i=0; i<0xf; i++) {
        NSString *key = [NSString stringWithFormat:@KEY_FORMAT_FAN_ID,i];

        if ([keys indexOfObject:key] != NSNotFound) {

            SMCVal_t info;

            if (kIOReturnSuccess == SMCReadKey(connection, [key cStringUsingEncoding:NSASCIIStringEncoding], &info)) {

                NSString *type = [NSString stringWithCString:info.dataType encoding:NSASCIIStringEncoding];
                NSData *value = [NSData dataWithBytes:info.bytes length:info.dataSize];

                if ([type isEqualToString:@TYPE_CH8]) {
                    NSString * caption = [[NSString alloc] initWithData:value encoding: NSUTF8StringEncoding];

                    if ([caption length] == 0)
                        caption = [[NSString alloc] initWithFormat:GetLocalizedString(@"Fan %X"),i + 1];

                    if (![caption hasPrefix:@"GPU "])
                        [self insertSmcFanWithConnection:connection name:[[NSString alloc] initWithFormat:@KEY_FORMAT_FAN_SPEED,i] type:type title:caption selector:group.selector.unsignedIntegerValue group:group nextOrder:&nextOrderValue];
                }
                else if ([type isEqualToString:@TYPE_FDS]) {
                    FanTypeDescStruct *fds = (FanTypeDescStruct*)[value bytes];

                    if (fds) {
                        NSString *caption = [[NSString stringWithCString:fds->strFunction encoding:NSASCIIStringEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

                        if ([caption length] == 0)
                            caption = [[NSString alloc] initWithFormat:@"Fan %X", i + 1];

                        switch (fds->type) {
                            case GPU_FAN_RPM:
                            case GPU_FAN_PWM_CYCLE:
                                // Add it later as GPU sensors
                                break;

                            default:
                                [self insertSmcFanWithConnection:connection name:[[NSString alloc] initWithFormat:@KEY_FORMAT_FAN_SPEED,i] type:type title:caption selector:group.selector.unsignedIntegerValue group:group nextOrder:&nextOrderValue];
                                break;
                        }
                    }
                }
            }
        }
    }

    }

- (void)insertSmcGpuFansWithConnection:(io_connect_t)connection keys:(NSArray*)keys
{
    HWMGroup *group = [self getGroupBySelector:kHWMGroupTachometer];
    NSUInteger nextOrderValue = [self getNextOrderValueForSensorsInGroup:group];

    // GPU Fans
    for (int i=0; i < 0xf; i++) {
        NSString *key = [NSString stringWithFormat:@KEY_FORMAT_FAN_ID,i];

        if ([keys indexOfObject:key] != NSNotFound) {
            SMCVal_t info;

            if (kIOReturnSuccess == SMCReadKey(connection, [key cStringUsingEncoding:NSASCIIStringEncoding], &info)) {

                NSString *type = [NSString stringWithCString:info.dataType encoding:NSASCIIStringEncoding];
                NSData *value = [NSData dataWithBytes:info.bytes length:info.dataSize];

                if ([type isEqualToString:@TYPE_CH8]) {
                    NSString * caption = [[NSString alloc] initWithData:value encoding: NSUTF8StringEncoding];

                    if ([caption hasPrefix:@"GPU "]) {
                        UInt8 cardIndex = [[caption substringFromIndex:4] intValue] - 1;
                        NSString *title = cardIndex == 0 ? GetLocalizedString(@"GPU Fan") : [NSString stringWithFormat:GetLocalizedString(@"GPU %X Fan"), cardIndex + 1];
                        [self insertSmcFanWithConnection:connection name:[[NSString alloc] initWithFormat:@KEY_FORMAT_FAN_SPEED,i] type:type title:title selector:group.selector.unsignedIntegerValue group:group nextOrder:&nextOrderValue];
                    }
                }
                else if ([type isEqualToString:@TYPE_FDS]) {
                    FanTypeDescStruct *fds = (FanTypeDescStruct*)[value bytes];

                    switch (fds->type) {
                        case GPU_FAN_RPM: {
                            NSString *title = fds->ui8Zone == 0 ? GetLocalizedString(@"GPU Fan") : [NSString stringWithFormat:GetLocalizedString(@"GPU %X Fan"), fds->ui8Zone + 1];
                            [self insertSmcFanWithConnection:connection name:[[NSString alloc] initWithFormat:@KEY_FORMAT_FAN_SPEED,i] type:type title:title selector:group.selector.unsignedIntegerValue group:group nextOrder:&nextOrderValue];
                            break;
                        }

                        case GPU_FAN_PWM_CYCLE: {
                            NSString *title = fds->ui8Zone == 0 ? GetLocalizedString(@"GPU PWM") : [NSString stringWithFormat:GetLocalizedString(@"GPU %X PWM"), fds->ui8Zone + 1];
                            [self insertSmcFanWithConnection:connection name:[[NSString alloc] initWithFormat:@KEY_FORMAT_FAN_SPEED,i] type:type title:title selector:kHWMGroupPWM group:group nextOrder:&nextOrderValue];
                            break;
                        }
                    }
                }
            }
        }
    }
}

#pragma mark
#pragma mark Battery Sensors

-(HWMBatterySensor*)getBatterySensorByName:(NSString*)name
{
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"BatterySensor"];

    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"name = %@", name]];

    NSError *error;

    HWMBatterySensor *sensor = [[self.managedObjectContext executeFetchRequest:fetchRequest error:&error] lastObject];

    if (error) {
        NSLog(@"getBatterySensorByName error %@", error);
    }

    return sensor;
}

-(HWMBatterySensor*)insertBatterySensorFromDictionary:(NSDictionary*)attributes group:(HWMGroup*)group
{
    NSString *name = [attributes objectForKey:@"serialNumber"];

    if (!name || name.length == 0) {
        name = [attributes objectForKey:@"productName"];
    }

    HWMBatterySensor *sensor = [self getBatterySensorByName:name];

    if (!sensor) {
        sensor = [NSEntityDescription insertNewObjectForEntityForName:@"BatterySensor" inManagedObjectContext:self.managedObjectContext];

        NSUInteger nextOrderValue = [self getNextOrderValueForSensorsInGroup:group];

        [sensor setOrder:[NSNumber numberWithInteger:nextOrderValue]];
    }

    [sensor setService:[attributes objectForKey:@"service"]];
    [sensor setSelector:[attributes objectForKey:@"selector"]];

    [sensor doUpdateValue];

    if (sensor.value) {
        [sensor setName:name];
        [sensor setProductName:[attributes objectForKey:@"productName"]];
        [sensor setSerialNumber:[attributes objectForKey:@"serialNumber"]];

        [sensor setEngine:self];

        if (![group.sensors containsObject:sensor]) {
            [group addSensorsObject:sensor];
        }
    }
    else {
        [self.managedObjectContext deleteObject:sensor];
    }
    
    return sensor;
}

-(void)insertBatterySensors
{
    NSError *error;

    // Reset "service" attribute for all battery sensors
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"BatterySensor"];
    NSArray *objects = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];

    for (HWMBatterySensor *sensor in objects) {
        [sensor setService:nil];
    }

    HWMGroup *group = [self getGroupBySelector:kHWMGroupBattery];

    NSArray *devices = [HWMBatterySensor discoverDevices];

    for (id device in devices) {
        [self insertBatterySensorFromDictionary:device group:group];
    }
}

#pragma mark
#pragma mark Events

-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqual:@"configuration.smcSensorsUpdateRate"])
    {
        [self initSmcAndDevicesTimer];
    }
    else if ([keyPath isEqual:@"configuration.smartSensorsUpdateRate"])
    {
        [self initAtaSmartTimer];
    }
    else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

-(void)awakeFromNib
{
    [self initialize];
    //[self startEngine];
}

-(void)workspaceDidMountOrUnmount:(id)sender
{
    [self insertAtaSmartSensors];

    _ataSmartSensors = nil;

    [self willChangeValueForKey:@"arrangedItems"];
    _arrangedItems = nil;
    [self didChangeValueForKey:@"arrangedItems"];

    [self willChangeValueForKey:@"favoriteItems"];
    _favoriteItems = nil;
    [self didChangeValueForKey:@"favoriteItems"];
}

-(void)workspaceWillSleep:(id)sender
{
    if (_engineState == kHWMEngineActive) {
        [self internalStopEngine];
    }
}

-(void)workspaceDidWake:(id)sender
{
    if (_engineState == kHWMEngineActive) {
        [self internalStartEngine];
    }
}

- (void)willTerminate:(id)sender
{
    [self internalStopEngine];
    [self saveContext];

    if (_smcConnection)
        SMCClose(_smcConnection);

    if (_fakeSmcConnection)
        SMCClose(_fakeSmcConnection);
}

@end