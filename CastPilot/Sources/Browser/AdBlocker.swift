import WebKit

/// A small built-in blocker for the worst ad and pop-up networks found on video sites.
enum AdBlocker {
    static let identifier = "CastPilotAdBlock-v2"

    static let blockedDomains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
        "amazon-adsystem.com", "adnxs.com", "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "popads.net", "popcash.net", "propellerads.com", "propellerclick.com", "adsterra.com",
        "exoclick.com", "exosrv.com", "juicyads.com", "trafficjunky.net", "trafficstars.com",
        "onclickads.net", "onclkds.com", "mgid.com", "revcontent.com", "hilltopads.net", "a-ads.com",
        "adcash.com", "clickadu.com", "admaven.com", "ad-maven.com", "pushhouse.io", "richpush.co",
        "galaksion.com", "zeropark.com", "monetag.com", "highperformanceformat.com", "profitableratecpm.com",
        "yllix.com", "bidvertiser.com", "plugrush.com", "adskeeper.com", "smartadserver.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "moatads.com", "scorecardresearch.com",
        // Pop-under and redirect networks common on free streaming sites.
        "magsrv.com", "realsrv.com", "tsyndicate.com", "clickaine.com", "adspyglass.com", "popmyads.com",
        "pushame.com", "pushnest.com", "notix.io", "evadav.com", "rollerads.com", "kadam.net",
        "adxpremium.com", "dtscout.com", "dtscdn.com", "clksite.com", "adcash.com", "aclib.net",
        "acscdn.com", "adsco.re", "popunder.net", "ero-advertising.com", "trafficforce.com",
    ]

    static var rulesJSON: String {
        let rules = blockedDomains.map { domain -> String in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\\\.")
            return #"{"trigger":{"url-filter":"^[^:]+://+([^:/]+\\.)?\#(escaped)[:/]"},"action":{"type":"block"}}"#
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    @MainActor private static var compiled: WKContentRuleList?

    @MainActor
    static func apply(to controller: WKUserContentController, enabled: Bool) async {
        controller.removeAllContentRuleLists()
        guard enabled else { return }
        if compiled == nil {
            compiled = try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: rulesJSON)
        }
        if let compiled { controller.add(compiled) }
    }
}
