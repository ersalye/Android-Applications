#include "platform/constants.hpp"
#include "platform/measurement_utils.hpp"
#include "platform/platform.hpp"
#include "platform/platform_unix_impl.hpp"
#include "platform/settings.hpp"

#include "coding/file_reader.hpp"

#include <ifaddrs.h>

#include <mach/mach.h>

#include <net/if.h>
#include <net/if_dl.h>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>

#import "iphone/Maps/Common/MWMCommon.h"

#import "3party/Alohalytics/src/alohalytics_objc.h"

#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSBundle.h>
#import <Foundation/NSPathUtilities.h>
#import <Foundation/NSProcessInfo.h>

#import <UIKit/UIDevice.h>
#import <UIKit/UIScreen.h>
#import <UIKit/UIScreenMode.h>

#import <SystemConfiguration/SystemConfiguration.h>
#import <netinet/in.h>

Platform::Platform()
{
  m_isTablet = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad);

  NSBundle * bundle = [NSBundle mainBundle];
  NSString * path = [bundle resourcePath];
  m_resourcesDir = [path UTF8String];
  m_resourcesDir += "/";

  NSArray * dirPaths =
      NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  NSString * docsDir = [dirPaths firstObject];
  m_writableDir = [docsDir UTF8String];
  m_writableDir += "/";
  m_settingsDir = m_writableDir;

  NSString * tmpDir = NSTemporaryDirectory();
  if (tmpDir)
    m_tmpDir = [tmpDir UTF8String];
  else
  {
    m_tmpDir = [NSHomeDirectory() UTF8String];
    m_tmpDir += "/tmp/";
  }

  UIDevice * device = [UIDevice currentDevice];
  NSLog(@"Device: %@, SystemName: %@, SystemVersion: %@", device.model, device.systemName,
        device.systemVersion);
}

// static
bool Platform::IsCustomTextureAllocatorSupported() { return !isIOS8; }

Platform::EError Platform::MkDir(string const & dirName) const
{
  if (::mkdir(dirName.c_str(), 0755))
    return ErrnoToError();
  return Platform::ERR_OK;
}

void Platform::GetFilesByRegExp(string const & directory, string const & regexp, FilesList & res)
{
  pl::EnumerateFilesByRegExp(directory, regexp, res);
}

bool Platform::GetFileSizeByName(string const & fileName, uint64_t & size) const
{
  try
  {
    return GetFileSizeByFullPath(ReadPathForFile(fileName), size);
  }
  catch (RootException const &)
  {
    return false;
  }
}

unique_ptr<ModelReader> Platform::GetReader(string const & file, string const & searchScope) const
{
  return make_unique<FileReader>(ReadPathForFile(file, searchScope), READER_CHUNK_LOG_SIZE,
                                 READER_CHUNK_LOG_COUNT);
}

int Platform::VideoMemoryLimit() const { return 8 * 1024 * 1024; }
int Platform::PreCachingDepth() const { return 2; }

string Platform::UniqueClientId() const { return [Alohalytics installationId].UTF8String; }
static void PerformImpl(void * obj)
{
  Platform::TFunctor * f = reinterpret_cast<Platform::TFunctor *>(obj);
  (*f)();
  delete f;
}

string Platform::GetMemoryInfo() const
{
  struct task_basic_info info;
  mach_msg_type_number_t size = sizeof(info);
  kern_return_t const kerr =
      task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &size);
  stringstream ss;
  if (kerr == KERN_SUCCESS)
  {
    ss << "Memory info: Resident_size = " << info.resident_size / 1024
       << "KB; virtual_size = " << info.resident_size / 1024
       << "KB; suspend_count = " << info.suspend_count << " policy = " << info.policy;
  }
  else
  {
    ss << "Error with task_info(): " << mach_error_string(kerr);
  }
  return ss.str();
}

void Platform::RunOnGuiThread(TFunctor const & fn)
{
  dispatch_async_f(dispatch_get_main_queue(), new TFunctor(fn), &PerformImpl);
}

void Platform::RunAsync(TFunctor const & fn, Priority p)
{
  int priority = DISPATCH_QUEUE_PRIORITY_DEFAULT;
  switch (p)
  {
  case EPriorityBackground: priority = DISPATCH_QUEUE_PRIORITY_BACKGROUND; break;
  case EPriorityDefault: priority = DISPATCH_QUEUE_PRIORITY_DEFAULT; break;
  case EPriorityHigh: priority = DISPATCH_QUEUE_PRIORITY_HIGH; break;
  case EPriorityLow: priority = DISPATCH_QUEUE_PRIORITY_LOW; break;
  }
  dispatch_async_f(dispatch_get_global_queue(priority, 0), new TFunctor(fn), &PerformImpl);
}

Platform::EConnectionType Platform::ConnectionStatus()
{
  struct sockaddr_in zero;
  bzero(&zero, sizeof(zero));
  zero.sin_len = sizeof(zero);
  zero.sin_family = AF_INET;
  SCNetworkReachabilityRef reachability =
      SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)&zero);
  if (!reachability)
    return EConnectionType::CONNECTION_NONE;
  SCNetworkReachabilityFlags flags;
  bool const gotFlags = SCNetworkReachabilityGetFlags(reachability, &flags);
  CFRelease(reachability);
  if (!gotFlags || ((flags & kSCNetworkReachabilityFlagsReachable) == 0))
    return EConnectionType::CONNECTION_NONE;
  SCNetworkReachabilityFlags userActionRequired = kSCNetworkReachabilityFlagsConnectionRequired |
                                                  kSCNetworkReachabilityFlagsInterventionRequired;
  if ((flags & userActionRequired) == userActionRequired)
    return EConnectionType::CONNECTION_NONE;
  if ((flags & kSCNetworkReachabilityFlagsIsWWAN) == kSCNetworkReachabilityFlagsIsWWAN)
    return EConnectionType::CONNECTION_WWAN;
  else
    return EConnectionType::CONNECTION_WIFI;
}

Platform::ChargingStatus Platform::GetChargingStatus()
{
  switch (UIDevice.currentDevice.batteryState)
  {
  case UIDeviceBatteryStateUnknown: return Platform::ChargingStatus::Unknown;
  case UIDeviceBatteryStateUnplugged: return Platform::ChargingStatus::Unplugged;
  case UIDeviceBatteryStateCharging:
  case UIDeviceBatteryStateFull: return Platform::ChargingStatus::Plugged;
  }
}

void Platform::SetupMeasurementSystem() const
{
  auto units = measurement_utils::Units::Metric;
  if (settings::Get(settings::kMeasurementUnits, units))
    return;
  BOOL const isMetric =
      [[[NSLocale autoupdatingCurrentLocale] objectForKey:NSLocaleUsesMetricSystem] boolValue];
  units = isMetric ? measurement_utils::Units::Metric : measurement_utils::Units::Imperial;
  settings::Set(settings::kMeasurementUnits, units);
}

////////////////////////////////////////////////////////////////////////
extern Platform & GetPlatform()
{
  static Platform platform;
  return platform;
}