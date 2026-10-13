import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum SSML {
    static func validate(_ text: String) throws {
        guard text.utf8.count <= 16_000 else { throw CLIError("SSML must fit one native request (at most 16000 UTF-8 bytes); split it into complete speak documents", code: .usage) }
        guard !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw CLIError("SSML document types and entity declarations are unsupported", code: .usage) }
        let parser = XMLParser(data: Data(text.utf8))
        let delegate = RootValidator(); parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.root == "speak" else { throw CLIError("SSML must be well-formed XML with a speak root", code: .usage) }
    }
    private final class RootValidator: NSObject, XMLParserDelegate {
        var root: String?
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
            if root == nil { root = elementName }
        }
    }
}
