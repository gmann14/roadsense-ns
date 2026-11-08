import Foundation

#if canImport(Sentry)
import Sentry
#endif

enum SentryBootstrapper {
    static func bootstrap(config: AppConfig) {
        #if canImport(Sentry)
        guard config.enableSentry,
              let dsn = config.sentryDSN,
              !dsn.isEmpty else {
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn
            options.sendDefaultPii = false
            // Network breadcrumbs and failed-request capture would record
            // request URLs, and Mapbox static-image URLs carry coordinates.
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            options.enableNetworkTracking = false
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.beforeBreadcrumb = { breadcrumb in
                SentryEventScrubber.scrub(breadcrumb)
            }
            options.beforeSend = { event in
                SentryEventScrubber.scrub(event)
            }
        }
        #endif
    }
}

#if canImport(Sentry)
/// Keeps coordinates and request URLs out of crash reports.
enum SentryEventScrubber {
    static func scrub(_ breadcrumb: Breadcrumb) -> Breadcrumb? {
        if PrivacyRedactor.shouldDropBreadcrumb(category: breadcrumb.category, type: breadcrumb.type) {
            return nil
        }
        if let message = breadcrumb.message {
            breadcrumb.message = PrivacyRedactor.redactCoordinates(in: message)
        }
        breadcrumb.data = nil
        return breadcrumb
    }

    static func scrub(_ event: Event) -> Event? {
        if let message = event.message?.formatted {
            event.message = SentryMessage(formatted: PrivacyRedactor.redactCoordinates(in: message))
        }
        event.exceptions?.forEach { exception in
            exception.value = PrivacyRedactor.redactCoordinates(in: exception.value)
        }
        if let request = event.request {
            if let url = request.url {
                request.url = PrivacyRedactor.redactURL(url)
            }
            request.queryString = nil
            request.cookies = nil
            request.headers = nil
        }
        event.breadcrumbs = event.breadcrumbs?.compactMap { scrub($0) }
        event.extra = nil
        event.user = nil
        return event
    }
}
#endif
