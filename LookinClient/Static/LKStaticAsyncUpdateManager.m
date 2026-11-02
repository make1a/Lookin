//
//  LKStaticAsyncUpdateManager.m
//  Lookin
//
//  Created by Li Kai on 2019/2/19.
//  https://lookin.work
//

#import "LKStaticAsyncUpdateManager.h"
#import "LookinDisplayItem.h"
#import "LKAppsManager.h"
#import "LKStaticHierarchyDataSource.h"
#import "LookinDisplayItemDetail.h"
#import "LKPreferenceManager.h"
#import "LKProgressIndicatorView.h"
#import "LookinHierarchyInfo.h"
#import "LookinStaticAsyncUpdateTask.h"
#import "LKNavigationManager.h"
#import "LKPerformanceReporter.h"
#import "LookinDisplayItem+LookinClient.h"
#import "LKVersionComparer.h"
#import "LKReloadSingleItemUpdateTaskMaker.h"
#import "LKReloadItemAndChildrenUpdateTaskMaker.h"

@interface LKDetailUpdateRequest : NSObject

@property(nonatomic, copy) NSArray<LookinStaticAsyncUpdateTasksPackage *> *packages;
/// 已经收到回复的 task 的数量（但受限于目前的设计，无法知道具体是哪些 task 收到了回复）
/// detail 有 failureCode 时，也仍然会被算到 finishedTasksCount 里面
@property(nonatomic, assign) NSInteger finishedTasksCount;
@property(nonatomic, assign) NSInteger tasksTotalCount;
@property(nonatomic, assign) NSInteger failedTasksCount;
/// 只有收到成功回包的任务才会进入该集合。取消、超时和服务端失败都不会进入。
@property(nonatomic, strong) NSMutableSet<LookinStaticAsyncUpdateTask *> *succeededTasks;
/// 同一 oid 可能同时有 group / solo 两个任务，按请求顺序消费，得到精确任务签名。
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableArray<LookinStaticAsyncUpdateTask *> *> *pendingTasksByOid;

@end

@interface LKProgressiveDetailUpdateSession : NSObject

@property(nonatomic, assign) NSUInteger generation;
@property(nonatomic, copy) NSArray<LookinStaticAsyncUpdateTask *> *allTasks;
@property(nonatomic, copy) NSArray<LookinStaticAsyncUpdateTask *> *firstScreenTasks;
@property(nonatomic, assign) NSUInteger finishedTasksCount;
@property(nonatomic, strong) NSMutableSet<LookinStaticAsyncUpdateTask *> *succeededTasks;
@property(nonatomic, assign) CFTimeInterval firstScreenStartTime;
@property(nonatomic, assign) CFTimeInterval backgroundStartTime;

@end

@implementation LKProgressiveDetailUpdateSession
@end

@implementation LKDetailUpdateRequest

- (instancetype)init {
    if (self = [super init]) {
        _succeededTasks = [NSMutableSet set];
        _pendingTasksByOid = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)queryIfContainsTask:(LookinStaticAsyncUpdateTask *)task {
    for (LookinStaticAsyncUpdateTasksPackage *pack in self.packages) {
        if ([pack.tasks containsObject:task]) {
            return YES;
        }
    }
    return NO;
}

- (void)removeTaskWithItem:(LookinDisplayItem *)item {
    for (LookinStaticAsyncUpdateTasksPackage *pack in self.packages) {
        pack.tasks = [pack.tasks lookin_filter:^BOOL(LookinStaticAsyncUpdateTask *task) {
            if (task.oid == item.layerObject.oid) {
                return NO;
            } else {
                return YES;
            }
        }];
    }
}

- (LookinStaticAsyncUpdateTask *)consumeTaskForDisplayItemOid:(unsigned long)oid {
    NSMutableArray<LookinStaticAsyncUpdateTask *> *tasks = self.pendingTasksByOid[@(oid)];
    LookinStaticAsyncUpdateTask *task = tasks.firstObject;
    if (task) {
        [tasks removeObjectAtIndex:0];
    }
    return task;
}

- (NSInteger)tasksTotalCount {
    NSInteger count = 0;
    for (LookinStaticAsyncUpdateTasksPackage *pack in self.packages) {
        count += pack.tasks.count;
    }
    return count;
}

@end

@interface LKStaticAsyncUpdateManager ()

/// 已经成功收到了所有回复的 request
@property(nonatomic, strong) NSMutableArray<LKDetailUpdateRequest *> *succeededRequests;
/// 已经发送出去、尚未结束的 request
@property(nonatomic, strong) LKDetailUpdateRequest *ongoingRequest;
/// 当前渐进同步会话。每次重新加载都会创建新代次，旧代次的回调不得继续发送后台任务。
@property(nonatomic, strong) LKProgressiveDetailUpdateSession *progressiveSession;
@property(nonatomic, assign) NSUInteger progressiveGeneration;

@end

@implementation LKStaticAsyncUpdateManager

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static LKStaticAsyncUpdateManager *instance = nil;
    dispatch_once(&onceToken,^{
        instance = [[super allocWithZone:NULL] init];
    });
    return instance;
}

+ (id)allocWithZone:(struct _NSZone *)zone{
    return [self sharedInstance];
}

- (instancetype)init {
    if (self = [super init]) {
        self.succeededRequests = [NSMutableArray array];
        _modifyingUpdateProgressSignal = [RACSubject subject];
        _modifyingUpdateErrorSignal = [RACSubject subject];
        
        @weakify(self);
        [[self dataSource].willReloadHierarchyInfo subscribeNext:^(id  _Nullable x) {
            @strongify(self);
            [self _invalidateProgressiveSession];
            [self.succeededRequests removeAllObjects];
        }];
    }
    return self;
}

- (void)updateAll {
    NSAssert(!LKPreferenceManager.mainManager.fastMode.currentBOOLValue, @"");
    
    LKInspectableApp *app = [LKAppsManager sharedInstance].inspectingApp;
    if (!app || !self.dataSource.flatItems.count) {
        return;
    }
    if (LKPreferenceManager.mainManager.preferFirstScreenSync) {
        [self _startProgressiveUpdate];
        return;
    }

    [self _invalidateProgressiveSession];
    [self _cancelOngoingRequest];
    
    NSArray<LookinStaticAsyncUpdateTask *> *newTasks = [self makeMaximumTasks];
    if (newTasks.count == 0) {
        return;
    }
    [self _sendTasks:newTasks completion:nil];
}

- (void)endUpdating {
    [self _invalidateProgressiveSession];
    [self _cancelOngoingRequest];
}

- (void)_cancelOngoingRequest {
    if (!self.ongoingRequest) {
        return;
    }
    NSLog(@"AsyncUpdate - endUpdating");
    // 这句会触发 sendTasks 方法里的 completed 事件，进而导致 delegate 被通知
    [InspectingApp cancelHierarchyDetailFetching];
}

- (void)_invalidateProgressiveSession {
    self.progressiveGeneration += 1;
    self.progressiveSession = nil;
}

- (void)_startProgressiveUpdate {
    [self _startProgressiveUpdateWithSucceededTasks:nil];
}

- (void)_startProgressiveUpdateWithSucceededTasks:(NSSet<LookinStaticAsyncUpdateTask *> *)succeededTasks {
    [self _invalidateProgressiveSession];
    [self _cancelOngoingRequest];

    NSArray<LookinStaticAsyncUpdateTask *> *allTasks = [self makeMaximumTasks];
    if (allTasks.count == 0) {
        return;
    }

    NSSet<NSNumber *> *visibleOids = [NSSet setWithArray:[self.dataSource.displayingFlatItems lookin_map:^id(NSUInteger idx, LookinDisplayItem *item) {
        return @(item.layerObject.oid);
    }]];
    NSArray<LookinStaticAsyncUpdateTask *> *firstScreenTasks = [allTasks lookin_filter:^BOOL(LookinStaticAsyncUpdateTask *task) {
        return [visibleOids containsObject:@(task.oid)];
    }];
    if (firstScreenTasks.count == 0) {
        firstScreenTasks = allTasks;
    }

    LKProgressiveDetailUpdateSession *session = [LKProgressiveDetailUpdateSession new];
    session.generation = self.progressiveGeneration;
    session.allTasks = allTasks;
    session.succeededTasks = [NSMutableSet setWithSet:succeededTasks ?: [NSSet set]];
    firstScreenTasks = [firstScreenTasks lookin_filter:^BOOL(LookinStaticAsyncUpdateTask *task) {
        return ![session.succeededTasks containsObject:task];
    }];
    session.firstScreenTasks = firstScreenTasks;
    session.firstScreenStartTime = CACurrentMediaTime();
    self.progressiveSession = session;

    NSLog(@"ProgressiveSync - generation:%@ first-screen tasks:%@ total:%@", @(session.generation), @(firstScreenTasks.count), @(allTasks.count));
    if (firstScreenTasks.count == 0) {
        NSArray<LookinStaticAsyncUpdateTask *> *backgroundTasks = [session.allTasks lookin_filter:^BOOL(LookinStaticAsyncUpdateTask *task) {
            return ![session.succeededTasks containsObject:task];
        }];
        if (backgroundTasks.count == 0) {
            [self _finishProgressiveSession:session];
            return;
        }
        session.backgroundStartTime = CACurrentMediaTime();
        NSLog(@"ProgressiveSync - generation:%@ resume background tasks:%@", @(session.generation), @(backgroundTasks.count));
        @weakify(self);
        [self _sendTasks:backgroundTasks completion:^(LKDetailUpdateRequest *backgroundRequest, BOOL backgroundCompleted) {
            @strongify(self);
            if (self.progressiveSession != session || session.generation != self.progressiveGeneration || !backgroundCompleted) {
                return;
            }
            [session.succeededTasks unionSet:backgroundRequest.succeededTasks];
            session.finishedTasksCount = session.succeededTasks.count;
            NSLog(@"ProgressiveSync - generation:%@ resume background complete:%.2fs succeeded:%@ failed:%@", @(session.generation), CACurrentMediaTime() - session.backgroundStartTime, @(backgroundRequest.succeededTasks.count), @(backgroundRequest.failedTasksCount));
            [self _finishProgressiveSession:session];
        }];
        return;
    }

    @weakify(self);
    [self _sendTasks:firstScreenTasks completion:^(LKDetailUpdateRequest *request, BOOL completed) {
        @strongify(self);
        if (self.progressiveSession != session || session.generation != self.progressiveGeneration || !completed) {
            return;
        }

        [session.succeededTasks unionSet:request.succeededTasks];
        session.finishedTasksCount = session.succeededTasks.count;
        NSLog(@"ProgressiveSync - generation:%@ first-screen complete:%.2fs succeeded:%@ failed:%@", @(session.generation), CACurrentMediaTime() - session.firstScreenStartTime, @(request.succeededTasks.count), @(request.failedTasksCount));

        // 只跳过实际成功的任务；失败任务最多会在后台阶段再尝试一次。
        NSArray<LookinStaticAsyncUpdateTask *> *backgroundTasks = [session.allTasks lookin_filter:^BOOL(LookinStaticAsyncUpdateTask *task) {
            return ![session.succeededTasks containsObject:task];
        }];

        if (backgroundTasks.count == 0) {
            [self _finishProgressiveSession:session];
            return;
        }

        session.backgroundStartTime = CACurrentMediaTime();
        NSLog(@"ProgressiveSync - generation:%@ background tasks:%@", @(session.generation), @(backgroundTasks.count));
        [self _sendTasks:backgroundTasks completion:^(LKDetailUpdateRequest *backgroundRequest, BOOL backgroundCompleted) {
            @strongify(self);
            if (self.progressiveSession != session || session.generation != self.progressiveGeneration || !backgroundCompleted) {
                return;
            }
            [session.succeededTasks unionSet:backgroundRequest.succeededTasks];
            session.finishedTasksCount = session.succeededTasks.count;
            NSLog(@"ProgressiveSync - generation:%@ background complete:%.2fs succeeded:%@ failed:%@", @(session.generation), CACurrentMediaTime() - session.backgroundStartTime, @(backgroundRequest.succeededTasks.count), @(backgroundRequest.failedTasksCount));
            [self _finishProgressiveSession:session];
        }];
    }];
}

- (void)_finishProgressiveSession:(LKProgressiveDetailUpdateSession *)session {
    if (self.progressiveSession != session || session.generation != self.progressiveGeneration) {
        return;
    }
    NSLog(@"ProgressiveSync - generation:%@ complete:%.2fs processed tasks:%@", @(session.generation), CACurrentMediaTime() - session.firstScreenStartTime, @(session.finishedTasksCount));
    self.progressiveSession = nil;
    [self notifyTasksCountToDelegate];
    [LKPerformanceReporter.sharedInstance didComplete];
}

- (NSArray<LookinStaticAsyncUpdateTask *> *)makeMaximumTasks {
    // tasks 里的元素顺序很重要：index 更小的 task 会优先被拉取回来展示。所以我们优先把用户可见的图层加进来，这样用户体验更好
    NSMutableArray<LookinStaticAsyncUpdateTask *> *tasks = [(NSArray<LookinDisplayItem *> *)self.dataSource.displayingFlatItems lookin_map:^id(NSUInteger idx, LookinDisplayItem *item) {
        if (item.isUserCustom) {
            return nil;
        }
        if (item.doNotFetchScreenshotReason == LookinFetchScreenshotPermitted) {
            if (item.isExpandable && item.isExpanded) {
                return [self _taskFromDisplayItem:item type:LookinStaticAsyncUpdateTaskTypeSoloScreenshot];
            } else {
                return [self _taskFromDisplayItem:item type:LookinStaticAsyncUpdateTaskTypeGroupScreenshot];
            }
        } else {
            return [self _taskFromDisplayItem:item type:LookinStaticAsyncUpdateTaskTypeNoScreenshot];
        }
    }].mutableCopy;
    
    [self.dataSource.flatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull item, NSUInteger idx, BOOL * _Nonnull stop) {
        if (item.isUserCustom) {
            return;
        }
        if (item.doNotFetchScreenshotReason == LookinFetchScreenshotPermitted) {
            LookinStaticAsyncUpdateTask *task = [self _taskFromDisplayItem:item type:LookinStaticAsyncUpdateTaskTypeGroupScreenshot];
            if (![tasks containsObject:task]) {
                [tasks addObject:task];
            }
            
            if (item.isExpandable) {
                LookinStaticAsyncUpdateTask *task2 = [self _taskFromDisplayItem:item type:LookinStaticAsyncUpdateTaskTypeSoloScreenshot];
                if (![tasks containsObject:task2]) {
                    [tasks addObject:task2];
                }
            }
        } else {
            LookinStaticAsyncUpdateTask *task = [self _taskFromDisplayItem:item type:LookinStaticAsyncUpdateTaskTypeNoScreenshot];
            if (![tasks containsObject:task]) {
                [tasks addObject:task];
            }
        }
    }];    
    return tasks.copy;
}

- (NSArray<LookinStaticAsyncUpdateTasksPackage *> *)_makePackagesFromTasks:(NSArray<LookinStaticAsyncUpdateTask *> *)tasks {
    NSMutableArray<LookinStaticAsyncUpdateTasksPackage *> *packages = [NSMutableArray array];
    NSMutableArray<LookinStaticAsyncUpdateTask *> *bufferTasks = [NSMutableArray array];
    
    __block NSUInteger packageTotalArea = 0;
    NSUInteger packageMaxArea = 2000000;
    NSUInteger packageMaxTasksCount = 100;
    [tasks enumerateObjectsUsingBlock:^(LookinStaticAsyncUpdateTask * _Nonnull task, NSUInteger idx, BOOL * _Nonnull stop) {
        CGFloat currentArea = task.frameSize.width * task.frameSize.height;
        if ((packageTotalArea + currentArea > packageMaxArea) || bufferTasks.count >= packageMaxTasksCount) {
            if (bufferTasks.count > 0) {
                packageTotalArea = 0;
                LookinStaticAsyncUpdateTasksPackage *package = [LookinStaticAsyncUpdateTasksPackage new];
                package.tasks = bufferTasks;
                [packages addObject:package];
                [bufferTasks removeAllObjects];
            }
        }
        
        packageTotalArea += currentArea;
        [bufferTasks addObject:task];
    }];
    
    if (bufferTasks.count) {
        LookinStaticAsyncUpdateTasksPackage *package = [LookinStaticAsyncUpdateTasksPackage new];
        package.tasks = bufferTasks;
        [packages addObject:package];
    }
    return packages.copy;
}

- (LookinStaticAsyncUpdateTask *)_taskFromDisplayItem:(LookinDisplayItem *)item type:(LookinStaticAsyncUpdateTaskType)type {
    LookinStaticAsyncUpdateTask *task = [LookinStaticAsyncUpdateTask new];
    task.oid = item.layerObject.oid;
    task.frameSize = item.frame.size;
    task.taskType = type;
    task.clientReadableVersion = [LKHelper lookinReadableVersion];
    return task;
}

- (void)updateAfterModifyingDisplayItem:(LookinDisplayItem *)displayItem {
    LKInspectableApp *app = [LKAppsManager sharedInstance].inspectingApp;
    if (!app) {
        return;
    }
    if (!displayItem) {
        NSAssert(NO, @"");
        return;
    }
    
    NSMutableArray<LookinStaticAsyncUpdateTask *> *tasks = [NSMutableArray array];
    [displayItem enumerateSelfAndAncestors:^(LookinDisplayItem *item, BOOL *stop) {
        if (item.doNotFetchScreenshotReason != LookinFetchScreenshotPermitted) {
            return;
        }
        if (item == displayItem && item.subitems.count) {
            LookinStaticAsyncUpdateTask *task = [self _taskFromDisplayItem:item type:LookinStaticAsyncUpdateTaskTypeSoloScreenshot];
            [tasks addObject:task];
        }
        LookinStaticAsyncUpdateTask *task2 = [self _taskFromDisplayItem:item type:LookinStaticAsyncUpdateTaskTypeGroupScreenshot];
        [tasks addObject:task2];
    }];
    
    [self.modifyingUpdateProgressSignal sendNext:[RACTwoTuple tupleWithObjectsFromArray:@[@0, @0]]];
    
    @weakify(self);
    NSUInteger screenshotsTotalCount = tasks.count;
    __block NSUInteger receivedScreenshotsCount = 0;
    [[app fetchModificationPatchWithTasks:tasks] subscribeNext:^(LookinDisplayItemDetail *detail) {
        @strongify(self);
        [[LKStaticHierarchyDataSource sharedInstance] modifyWithDisplayItemDetail:detail];
        
        if (detail.groupScreenshot) {
            receivedScreenshotsCount++;
        }
        if (detail.soloScreenshot) {
            receivedScreenshotsCount++;
        }
        [self.modifyingUpdateProgressSignal sendNext:[RACTwoTuple tupleWithObjectsFromArray:@[@(receivedScreenshotsCount), @(screenshotsTotalCount)]]];
        
    } error:^(NSError * _Nullable error) {
        @strongify(self);
        NSAssert(NO, @"");
        [self.modifyingUpdateProgressSignal sendError:error];
        
    } completed:^{
        @strongify(self);
        NSAssert(screenshotsTotalCount == screenshotsTotalCount, @"");
        [self.modifyingUpdateProgressSignal sendNext:[RACTwoTuple tupleWithObjectsFromArray:@[@(screenshotsTotalCount), @(screenshotsTotalCount)]]];
    }];
}

- (LKStaticHierarchyDataSource *)dataSource {
    return [LKStaticHierarchyDataSource sharedInstance];
}

- (NSArray<LookinStaticAsyncUpdateTask *> *)makeMinimumTasksForItems:(NSArray<LookinDisplayItem *> *)items {
    NSArray<LookinStaticAsyncUpdateTask *> *tasks = [items lookin_map:^id(NSUInteger idx, LookinDisplayItem *item) {
        if (item.isUserCustom) {
            return nil;
        }
        if (item.appropriateScreenshot != nil) {
            // 已经有图像了，无需再拉取（而且既然有图像了，那么 attrs 必然也有了）
            return nil;
        }
        
        LookinStaticAsyncUpdateTask *newTask = nil;
        if (item.doNotFetchScreenshotReason == LookinFetchScreenshotPermitted) {
            // 该图层应该有图像（但是现在没有），所以应该拉取图像
            if (item.isExpandable && item.isExpanded) {
                newTask = [self _taskFromDisplayItem:item type:LookinStaticAsyncUpdateTaskTypeSoloScreenshot];
            } else {
                newTask = [self _taskFromDisplayItem:item type:LookinStaticAsyncUpdateTaskTypeGroupScreenshot];
            }
        } else {
            // 该图层确实不应该有图像
            if (item.attributesGroupList.count > 0) {
                // 有 attr 了，说明已经拉取过了，无需再次拉取
                return nil;
            } else {
                // 拉取 attr
                newTask = [self _taskFromDisplayItem:item type:LookinStaticAsyncUpdateTaskTypeNoScreenshot];
            }
        }
        if (!newTask) {
            return nil;
        }
        
        /// Client 1.0.7 & Server 1.2.7 开始支持 attrRequest 这个参数
        if (item.attributesGroupList.count == 0) {
            newTask.attrRequest = LookinDetailUpdateTaskAttrRequest_Need;
        } else {
            newTask.attrRequest = LookinDetailUpdateTaskAttrRequest_NotNeed;
        }
        
        for (LKDetailUpdateRequest *req in self.succeededRequests) {
            if ([req queryIfContainsTask:newTask]) {
                // 该 task 已经请求成功过，不再重复请求
                return nil;
            }
        }
        return newTask;
    }];
    return tasks;
}

- (void)updateForDisplayingItems {
    NSAssert(LKPreferenceManager.mainManager.fastMode.currentValue, @"");

    LKInspectableApp *app = [LKAppsManager sharedInstance].inspectingApp;
    if (!app) {
        return;
    }
    NSArray *items = [LKStaticHierarchyDataSource sharedInstance].displayingFlatItems;
    if (items.count == 0) {
        return;
    }
    NSArray<LookinStaticAsyncUpdateTask *> *newTasks = [self makeMinimumTasksForItems:items];
    if (newTasks.count == 0) {
        return;
    }
    [self sendTasks:newTasks completion:nil];
}

- (void)sendTasks:(NSArray<LookinStaticAsyncUpdateTask *> *)newTasks completion:(void (^)(void))completionBlock {
    [self _invalidateProgressiveSession];
    [self _cancelOngoingRequest];
    [self _sendTasks:newTasks completion:^(LKDetailUpdateRequest *request, BOOL completed) {
        if (completionBlock && completed) {
            completionBlock();
        }
    }];
}

- (void)_sendTasks:(NSArray<LookinStaticAsyncUpdateTask *> *)newTasks completion:(void (^)(LKDetailUpdateRequest *request, BOOL completed))completionBlock {
    LKInspectableApp *app = [LKAppsManager sharedInstance].inspectingApp;
    if (!app || newTasks.count == 0) {
        if (completionBlock) {
            completionBlock(nil, NO);
        }
        return;
    }
    // 同类请求不能并发。渐进同步的后续阶段会直接调用本方法，避免取消当前会话。
    [self _cancelOngoingRequest];
    
    NSArray<LookinStaticAsyncUpdateTasksPackage *> *packages = [self _makePackagesFromTasks:newTasks];
    LKDetailUpdateRequest *request = [LKDetailUpdateRequest new];
    request.packages = packages;
    [newTasks enumerateObjectsUsingBlock:^(LookinStaticAsyncUpdateTask * _Nonnull task, NSUInteger idx, BOOL * _Nonnull stop) {
        NSNumber *key = @(task.oid);
        NSMutableArray<LookinStaticAsyncUpdateTask *> *tasks = request.pendingTasksByOid[key];
        if (!tasks) {
            tasks = [NSMutableArray array];
            request.pendingTasksByOid[key] = tasks;
        }
        [tasks addObject:task];
    }];
    self.ongoingRequest = request;
    
    [self notifyTasksCountToDelegate];
    
    NSLog(@"AsyncUpdate - Will send %@ tasks.", @(newTasks.count));
    
    @weakify(self);
    [[app fetchHierarchyDetailWithTaskPackages:packages] subscribeNext:^(NSArray<LookinDisplayItemDetail *> *details) {
        @strongify(self);
        if (self.ongoingRequest != request) {
            return;
        }
        [details enumerateObjectsUsingBlock:^(LookinDisplayItemDetail * _Nonnull detail, NSUInteger idx, BOOL * _Nonnull stop) {
            LookinStaticAsyncUpdateTask *task = [request consumeTaskForDisplayItemOid:detail.displayItemOid];
            if (detail.failureCode == -1) {
                request.failedTasksCount += 1;
            } else {
                if (task) {
                    [request.succeededTasks addObject:task];
                }
                [[LKStaticHierarchyDataSource sharedInstance] modifyWithDisplayItemDetail:detail];
            }
        }];
        request.finishedTasksCount += details.count;
        [self notifyTasksCountToDelegate];
        
    } error:^(NSError * _Nullable error) {
        @strongify(self);
        if (self.ongoingRequest != request) {
            return;
        }
        self.ongoingRequest = nil;
        [self _invalidateProgressiveSession];
        [self notifyTasksCountToDelegate];
        
        NSString *msgTitle = [NSString stringWithFormat:NSLocalizedString(@"Request timeout, layer data transmission failed.", nil)];
        NSString *msgDetail = NSLocalizedString(@"Perhaps your iOS app is paused with breakpoint in Xcode, blocked by other tasks in main thread, or moved to background state.\nToo large screenshots may also lead to this error.", nil);
        error = LookinErrorMake(msgTitle, msgDetail);
        [[RACScheduler mainThreadScheduler] afterDelay:1 schedule:^{
            // 此时可能 StaticViewController 还没来得及被初始化导致错误 tips 显示不出来，所以稍等一下
            [self.delegate detailUpdateReceivedError:error];
        }];
        if (completionBlock) {
            completionBlock(request, NO);
        }
    } completed:^{
        // 注意，用户手动取消请求后，也会走到这里
        @strongify(self);
        BOOL userCancel = YES;
        if (self.ongoingRequest == request) {
            userCancel = (request.tasksTotalCount > request.finishedTasksCount);
            if (!userCancel) {
                [self.succeededRequests addObject:request];
                if (self.progressiveSession) {
                    [self.progressiveSession.succeededTasks unionSet:request.succeededTasks];
                    self.progressiveSession.finishedTasksCount = self.progressiveSession.succeededTasks.count;
                }
            }
            
            if (request.failedTasksCount > 0) {
                NSError *error = LookinErrorMake(NSLocalizedString(@"Some layer data failed to transmit.", nil), NSLocalizedString(@"It may be due to changes in the layer structure within the iOS app. You can try reloading the entire structure in Lookin.", nil));
                [self.delegate detailUpdateReceivedError:error];
            }
            
            self.ongoingRequest = nil;
        }
        [self notifyTasksCountToDelegate];
        if (!userCancel && !self.progressiveSession) {
            [LKPerformanceReporter.sharedInstance didComplete];
        }
        
        if (completionBlock) {
            completionBlock(request, !userCancel);
        }
    }];
}

- (void)notifyTasksCountToDelegate {
    NSUInteger totalCount;
    NSUInteger finishedCount;
    if (self.progressiveSession) {
        totalCount = self.progressiveSession.allTasks.count;
        finishedCount = self.progressiveSession.succeededTasks.count + self.ongoingRequest.succeededTasks.count;
    } else {
        totalCount = self.ongoingRequest.tasksTotalCount;
        finishedCount = self.ongoingRequest.finishedTasksCount;
    }

    NSLog(@"AsyncUpdate - notify delagate: %@/%@", @(finishedCount), @(totalCount));
    [self.delegate detailUpdateTasksTotalCount:totalCount finishedCount:finishedCount];
}

- (void)reloadSingleDisplayItem:(LookinDisplayItem *)item {
    NSSet<LookinStaticAsyncUpdateTask *> *succeededTasks = self.isBackgroundUpdating ? self.progressiveSession.succeededTasks.copy : nil;
    NSArray *tasks = [LKReloadSingleItemUpdateTaskMaker makeWithItem:item];
    if (tasks.count == 0) {
        return;
    }
    [self sendTasks:tasks completion:^{
        if (succeededTasks) {
            [self _startProgressiveUpdateWithSucceededTasks:succeededTasks];
        }
    }];
}

- (void)reloadDisplayItemAndChildren:(LookinDisplayItem *)rootItem {
    NSSet<LookinStaticAsyncUpdateTask *> *succeededTasks = self.isBackgroundUpdating ? self.progressiveSession.succeededTasks.copy : nil;
    // 先更新 rootItem 的 basis + attr + subitems
    NSArray *tasks = [LKReloadItemAndChildrenUpdateTaskMaker makeWithItem:rootItem];
    if (tasks.count == 0) {
        return;
    }
    [rootItem enumerateSelfAndChildren:^(LookinDisplayItem * _Nonnull item) {
        // 把 screenshots 以及完成的任务记录都删掉，因为稍后我们要重新拉取
        // 虽然待会儿返回的新 children 是新的 displayItem 实例，但新的 displayItem 实例的 oid 很可能没有变化，而 task 的 equal 是根据 oid 来计算的
        item.soloScreenshot = nil;
        item.groupScreenshot = nil;
        [self.succeededRequests enumerateObjectsUsingBlock:^(LKDetailUpdateRequest * _Nonnull req, NSUInteger idx, BOOL * _Nonnull stop) {
            [req removeTaskWithItem:item];
        }];
    }];
    
    [self sendTasks:tasks completion:^{
        // 更新 rootItem 以及 children 的图层详情
        [self updateAfterReloadingItemAndChildren:rootItem completion:^{
            if (succeededTasks) {
                [self _startProgressiveUpdateWithSucceededTasks:succeededTasks];
            }
        }];
    }];
}

- (void)updateAfterReloadingItemAndChildren:(LookinDisplayItem *)rootItem completion:(void (^)(void))completionBlock {
    // 拉取 rootItem 以及 children 的 screenshots + attr
    if (LKPreferenceManager.mainManager.fastMode.currentBOOLValue) {
        [self updateForDisplayingItems];
    } else {
        NSMutableArray<LookinStaticAsyncUpdateTask *> *tasks = [NSMutableArray array];
        [rootItem enumerateSelfAndChildren:^(LookinDisplayItem * _Nonnull item) {
            if (item.isUserCustom) {
                return;
            }
            if (item.doNotFetchScreenshotReason == LookinFetchScreenshotPermitted) {
                [tasks addObject:[self _taskFromDisplayItem:item type:LookinStaticAsyncUpdateTaskTypeGroupScreenshot]];
                if (item.isExpandable) {
                    [tasks addObject:[self _taskFromDisplayItem:item type:LookinStaticAsyncUpdateTaskTypeSoloScreenshot]];
                }
            } else {
                [tasks addObject:[self _taskFromDisplayItem:item type:LookinStaticAsyncUpdateTaskTypeNoScreenshot]];
            }
        }];
        [self sendTasks:tasks completion:completionBlock];
    }
}

- (BOOL)isUpdating {
    return self.ongoingRequest != nil;
}

- (BOOL)isBackgroundUpdating {
    return self.progressiveSession != nil && self.progressiveSession.backgroundStartTime > 0;
}

@end
