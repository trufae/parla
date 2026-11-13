#include "platform.h"
#import <Foundation/Foundation.h>

gchar *
parla_get_system_languages (void)
{
	@autoreleasepool {
		NSMutableArray *languages = [NSMutableArray array];
		for (NSString *language in [NSLocale preferredLanguages]) {
			[languages addObject:[language stringByReplacingOccurrencesOfString:@"-" withString:@"_"]];
			if ([language isEqualToString:@"en"] || [language hasPrefix:@"en-"]) {
				/* English is the source language, so it has no catalog. */
				[languages addObject:@"C"];
				break;
			}
		}
		return g_strdup ([[languages componentsJoinedByString:@":"] UTF8String]);
	}
}
