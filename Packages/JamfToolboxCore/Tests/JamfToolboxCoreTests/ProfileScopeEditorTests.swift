import XCTest
@testable import JamfToolboxCore

/// The scope editor must produce exactly what the original macOS-only
/// (XMLDocument) version produced. Golden/scope-editor.json was recorded from
/// that version, for every change on each fixture below.
final class ProfileScopeEditorTests: XCTestCase {
    private static func device(_ i: Int) -> String {
        "<mobile_device><id>\(i)</id><name>iPad-\(i)</name><udid>U-\(i)</udid><wifi_mac_address/></mobile_device>"
    }

    static let fixtures: [(String, GroupKind, String)] = [
        ("full", .mobile, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><configuration_profile><scope><all_mobile_devices>false</all_mobile_devices><all_jss_users>false</all_jss_users><mobile_devices>\(device(101))\(device(102))</mobile_devices><buildings/><departments/><mobile_device_groups><mobile_device_group><id>7</id><name>G7 &amp; Friends</name></mobile_device_group></mobile_device_groups><jss_users><user><id>5</id><name>JDoe</name></user><user><id>6</id><name>other</name></user></jss_users><jss_user_groups/><limitations><users><user><name>ldap&lt;bob&gt;</name></user></users><user_groups/><network_segments><network_segment><id>3</id><name>Lab</name></network_segment></network_segments><ibeacons/></limitations><exclusions><mobile_devices/><buildings/><departments/><mobile_device_groups><mobile_device_group><id>9</id><name>G9</name></mobile_device_group></mobile_device_groups><users/><user_groups/><network_segments/><ibeacons/><jss_users><user><id>5</id><name>jdoe</name></user></jss_users><jss_user_groups/></exclusions></scope></configuration_profile>"),
        ("sized", .computer, "<os_x_configuration_profile><scope><all_computers>false</all_computers><computers><size>2</size><computer><id>1</id><name>MBP-1</name></computer><computer><id>2</id><name>MBP-2</name></computer></computers><computer_groups><size>0</size></computer_groups><exclusions><computers><size>0</size></computers></exclusions></scope></os_x_configuration_profile>"),
        ("bare", .mobile, "<configuration_profile><scope><all_mobile_devices>true</all_mobile_devices></scope></configuration_profile>"),
        ("whitespace", .mobile, "<configuration_profile>\n  <scope>\n    <mobile_devices>\n      <mobile_device>\n        <id> 101 </id>\n      </mobile_device>\n    </mobile_devices>\n  </scope>\n</configuration_profile>"),
    ]

    private func golden() throws -> [String: [String: Any]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "scope-editor", withExtension: "json", subdirectory: "Golden"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: cases.map { ($0["case"] as! String, $0) })
    }

    private func sorted(_ fp: [String: Set<String>]) -> [String: [String]] { fp.mapValues { $0.sorted() } }

    func testMatchesTheOriginalEditor() throws {
        let golden = try golden()
        for (name, kind, xml) in Self.fixtures {
            for change in ScopeChange.allCases {
                let label = "\(name)/\(change.rawValue)"
                let expected = try XCTUnwrap(golden[label], label)
                let edit = try ProfileScopeEditor.apply(change, to: Data(xml.utf8), kind: kind,
                                                        deviceID: kind == .computer ? "1" : "101", username: "jdoe")
                XCTAssertEqual(String(decoding: edit.body, as: UTF8.self), expected["body"] as? String, "\(label): body")
                XCTAssertEqual(edit.changes, expected["changes"] as? [String], "\(label): changes")
                XCTAssertEqual(sorted(edit.expected), expected["expected"] as? [String: [String]], "\(label): expected scope")
                XCTAssertEqual(sorted(try XCTUnwrap(ProfileScopeEditor.fingerprint(of: edit.body))),
                               expected["bodyFingerprint"] as? [String: [String]], "\(label): body reads back")
            }
            XCTAssertEqual(sorted(try XCTUnwrap(ProfileScopeEditor.fingerprint(of: Data(xml.utf8)))),
                           golden["\(name)/fingerprint"]?["fp"] as? [String: [String]], "\(name): fingerprint")
        }
    }

    func testRefusesAProfileWithoutAScope() {
        XCTAssertThrowsError(try ProfileScopeEditor.apply(.exclude, to: Data("<x><y/></x>".utf8), kind: .mobile,
                                                         deviceID: "1", username: "")) { error in
            XCTAssertEqual((error as? ServiceError)?.message,
                           "Jamf Pro returned a profile without a scope, so nothing was changed.")
        }
        XCTAssertNil(ProfileScopeEditor.fingerprint(of: Data("not xml".utf8)))
    }

    func testRepeatingAChangeSendsNothing() throws {
        let xml = Data(Self.fixtures[0].2.utf8)
        let excluded = try ProfileScopeEditor.apply(.exclude, to: xml, kind: .mobile, deviceID: "101", username: "jdoe")
        let again = try ProfileScopeEditor.apply(.exclude, to: excluded.body, kind: .mobile, deviceID: "101", username: "jdoe")
        XCTAssertTrue(again.changes.isEmpty)
    }

    func testXMLRoundTripKeepsTextAndEscapes() throws {
        let source = #"<r a="1 &quot;x&quot;"><t> a &amp; b &lt;c&gt; </t><e/><n><![CDATA[x < y]]></n></r>"#
        let root = try XCTUnwrap(ScopeXML.parse(Data(source.utf8)))
        XCTAssertEqual(root.first("t")?.value, " a & b <c> ")
        XCTAssertEqual(root.text("t"), "a & b <c>")
        XCTAssertEqual(root.first("n")?.value, "x < y")
        XCTAssertEqual(root.serialized,
                       #"<r a="1 &quot;x&quot;"><t> a &amp; b &lt;c&gt; </t><e></e><n>x &lt; y</n></r>"#)
    }
}
