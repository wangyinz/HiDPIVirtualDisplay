#import <Foundation/Foundation.h>
#import "../Sources/VirtualDisplayManager.h"
#import "../Sources/CGVirtualDisplayPrivate.h"
#import <math.h>
@interface BudgetSettings : NSObject
@property(nonatomic) double refreshDeadline;
@property(nonatomic) int writes;
@property(nonatomic) BOOL rejectReadback;
@property(nonatomic) BOOL throws;
@end
@implementation BudgetSettings
@synthesize refreshDeadline = _refreshDeadline;
- (void)setRefreshDeadline:(double)value {
    self.writes++;
    if (self.throws) [NSException raise:@"Test" format:@"setter unavailable"];
    _refreshDeadline = value;
}
- (double)refreshDeadline { return self.rejectReadback ? NAN : _refreshDeadline; }
@end
static int checks=0;
static void check(BOOL value, const char *message) {
    checks++; if(!value) { fprintf(stderr,"FAIL: %s\n",message); exit(1); }
}
int main(void) { @autoreleasepool {
    double applied = -1;
    BudgetSettings *settings = [BudgetSettings new];
    check(VDMApplyVirtualCompositionBudget(settings,0,60,&applied),"Default accepted");
    check(settings.writes==0 && applied==0,"Default leaves setter untouched");
    check(VDMApplyVirtualCompositionBudget(settings,4,60,&applied),"4ms supported");
    check(fabs(applied-.004)<1e-9 && settings.writes==1,"Milliseconds convert to seconds");
    check(VDMApplyVirtualCompositionBudget(settings,8,60,&applied),"8ms supported");
    check(fabs(applied-.008)<1e-9,"8ms readback");
    check(VDMApplyVirtualCompositionBudget(settings,8,240,&applied),"High refresh accepted");
    check(fabs(applied-1.0/240)<1e-9,"Budget limited to one frame");
    for(NSNumber *n in @[@(-1),@(NAN),@(INFINITY),@4.5,@16])
        check(!VDMApplyVirtualCompositionBudget(settings,n.doubleValue,60,&applied),"Reject unknown budget");
    for(NSNumber *n in @[@0,@(-60),@(NAN),@(INFINITY)])
        check(!VDMApplyVirtualCompositionBudget(settings,4,n.doubleValue,&applied),"Reject invalid rate");
    check(!VDMApplyVirtualCompositionBudget([NSObject new],4,60,&applied),"Missing optional API falls back");
    settings.rejectReadback=YES;
    check(!VDMApplyVirtualCompositionBudget(settings,4,60,&applied) && applied==0,"Unverifiable result rejected");
    settings.rejectReadback=NO;
    check(settings.refreshDeadline==0,"Failed readback attempts reset");
    settings.throws=YES;
    check(!VDMApplyVirtualCompositionBudget(settings,4,60,&applied),"Throwing optional API contained");
    // Runtime smoke checks touch an unattached settings object only.
    id actual=[[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    if([actual respondsToSelector:@selector(setRefreshDeadline:)] && [actual respondsToSelector:@selector(refreshDeadline)]) {
        check(VDMApplyVirtualCompositionBudget(actual,4,60,&applied),"Real settings accepts 4ms");
        check(fabs(applied-.004)<1e-9,"Real settings round trip");
    }
    printf("%d composition budget checks passed; no displays created.\n",checks);
} return 0; }
