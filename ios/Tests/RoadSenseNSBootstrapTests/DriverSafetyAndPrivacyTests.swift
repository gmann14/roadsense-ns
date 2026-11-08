import Foundation
import Testing

@testable import RoadSenseNSBootstrap

@Suite("Driver safety policy")
struct DriverSafetyPolicyTests {
    @Test("pothole tap needs passenger confirmation only above 10 km/h")
    func manualMarkGate() {
        #expect(DriverSafetyPolicy.manualMarkRequiresPassengerConfirmation(speedKmh: Double?.none) == false)
        #expect(DriverSafetyPolicy.manualMarkRequiresPassengerConfirmation(speedKmh: -1) == false)
        #expect(DriverSafetyPolicy.manualMarkRequiresPassengerConfirmation(speedKmh: 0) == false)
        #expect(DriverSafetyPolicy.manualMarkRequiresPassengerConfirmation(speedKmh: 10) == false)
        #expect(DriverSafetyPolicy.manualMarkRequiresPassengerConfirmation(speedKmh: 10.5))
        #expect(DriverSafetyPolicy.manualMarkRequiresPassengerConfirmation(speedKmh: 90))
    }

    @Test("camera is blocked above walking speed")
    func cameraGate() {
        #expect(DriverSafetyPolicy.isPhotoCaptureAllowed(speedKmh: Double?.none))
        #expect(DriverSafetyPolicy.isPhotoCaptureAllowed(speedKmh: 0))
        #expect(DriverSafetyPolicy.isPhotoCaptureAllowed(speedKmh: 8))
        #expect(DriverSafetyPolicy.isPhotoCaptureAllowed(speedKmh: 8.1) == false)
        #expect(DriverSafetyPolicy.isPhotoCaptureAllowed(speedKmh: 60) == false)
    }
}

@Suite("App links")
struct AppLinksTests {
    @Test("legal and support links point at nsroadsense.ca over https")
    func legalLinks() {
        #expect(AppLinks.privacyPolicy.absoluteString == "https://nsroadsense.ca/privacy")
        #expect(AppLinks.termsOfUse.absoluteString == "https://nsroadsense.ca/terms")
        #expect(AppLinks.support.absoluteString == "https://nsroadsense.ca/support")
        #expect(AppLinks.legalAndSupport.map(\.title) == ["Privacy Policy", "Terms of Use", "Support"])
        for link in AppLinks.legalAndSupport {
            #expect(link.url.scheme == "https")
            #expect(link.url.host == "nsroadsense.ca")
        }
    }
}

@Suite("Privacy redactor")
struct PrivacyRedactorTests {
    @Test("drops http breadcrumbs")
    func dropsHTTPBreadcrumbs() {
        #expect(PrivacyRedactor.shouldDropBreadcrumb(category: "http", type: "http"))
        #expect(PrivacyRedactor.shouldDropBreadcrumb(category: "HTTP", type: nil))
        #expect(PrivacyRedactor.shouldDropBreadcrumb(category: "ui.lifecycle", type: "navigation") == false)
    }

    @Test("redacts coordinate-precision decimals")
    func redactsCoordinates() {
        let text = "static/-63.57520,44.64880,13.0,0,0/320x100 failed at 44.6488,-63.5752"
        let redacted = PrivacyRedactor.redactCoordinates(in: text)
        #expect(redacted.contains("44.648") == false)
        #expect(redacted.contains("63.575") == false)
        #expect(redacted.contains("13.0"))
        #expect(PrivacyRedactor.redactCoordinates(in: "") == "")
    }

    @Test("reduces URLs to scheme and host")
    func redactsURL() {
        #expect(
            PrivacyRedactor.redactURL("https://api.mapbox.com/styles/v1/mapbox/light-v11/static/-63.57520,44.64880,13.0/320x100@2x?access_token=pk.abc")
                == "https://api.mapbox.com"
        )
        #expect(PrivacyRedactor.redactURL("not a url") == PrivacyRedactor.redactionMarker)
    }
}
