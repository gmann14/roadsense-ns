package ca.roadsense.ns.api

/**
 * Public web pages the app links to. All live on `nsroadsense.ca`, the
 * project's own domain (same host as the iOS App Store metadata).
 *
 * Never drop the `ns`: the bare `roadsense` .ca domain belongs to an
 * unrelated third party.
 */
object PublicLinks {
    const val WEB_HOST: String = "nsroadsense.ca"
    const val WEB_MAP: String = "https://$WEB_HOST"
    const val PRIVACY_POLICY: String = "https://$WEB_HOST/privacy"
    const val TERMS: String = "https://$WEB_HOST/terms"
    const val SUPPORT: String = "https://$WEB_HOST/support"

    val all: List<String> = listOf(WEB_MAP, PRIVACY_POLICY, TERMS, SUPPORT)
}
