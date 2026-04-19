import Foundation

#if canImport(Sentry)
import Sentry
#endif

enum SentryBootstrapper {
    static func bootstrap(config: AppConfig) {
        #if canImport(Sentry)
        guard let dsn = config.sentryDSN, !dsn.isEmpty else {
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn
            options.sendDefaultPii = false
        }
        #endif
    }
}
