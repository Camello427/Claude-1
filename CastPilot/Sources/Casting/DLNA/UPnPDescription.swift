import Foundation

struct UPnPDeviceInfo {
    struct Service {
        var type: String
        var controlURL: String
    }

    var friendlyName = ""
    var manufacturer = ""
    var modelName = ""
    var udn = ""
    var deviceTypes: [String] = []
    var services: [Service] = []
    var urlBase: String?
}

/// Reads a UPnP device description (the XML at an SSDP LOCATION).
final class UPnPDescriptionParser: NSObject, XMLParserDelegate {
    private var info = UPnPDeviceInfo()
    private var text = ""
    private var serviceType: String?
    private var controlURL: String?

    static func parse(_ data: Data) -> UPnPDeviceInfo? {
        let delegate = UPnPDescriptionParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        let ok = parser.parse()
        if !ok && delegate.info.services.isEmpty { return nil }
        return delegate.info
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "service" {
            serviceType = nil
            controlURL = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "friendlyName": if info.friendlyName.isEmpty { info.friendlyName = value }
        case "manufacturer": if info.manufacturer.isEmpty { info.manufacturer = value }
        case "modelName": if info.modelName.isEmpty { info.modelName = value }
        case "UDN": if info.udn.isEmpty { info.udn = value }
        case "deviceType": info.deviceTypes.append(value)
        case "URLBase": info.urlBase = value
        case "serviceType": serviceType = value
        case "controlURL": controlURL = value
        case "service":
            if let serviceType, let controlURL {
                info.services.append(.init(type: serviceType, controlURL: controlURL))
            }
        default: break
        }
        text = ""
    }
}
