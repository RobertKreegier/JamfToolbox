import Foundation

/// CSV and Excel (.xlsx) rendering of a device list. No third-party libraries.
enum ListExport {
    /// CSV with a header row, using the same quoting rules and `\r\n` line
    /// endings as Python's `csv.writer`, so pasted output is unchanged.
    /// One CSV line (no line ending), quoted like Python's `csv.writer`.
    static func csvLine(_ fields: [String]) -> String {
        fields.map { text in
            guard text.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",")
    }

    static func csv(entries: [DeviceEntry], columns: [ColumnField]) -> String {
        func field(_ text: String) -> String {
            // Scan scalars, not Characters: "\r\n" is one Character and would slip past a "\n" check.
            guard text.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var rows = [columns.map { field($0.heading) }.joined(separator: ",")]
        for entry in entries {
            rows.append(columns.map { field(entry.value($0)) }.joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// UTF-8 with a byte-order mark, so Excel reads accented names correctly.
    static func csvFileData(entries: [DeviceEntry], columns: [ColumnField]) -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(csv(entries: entries, columns: columns).utf8)
    }

    // MARK: XLSX

    static func xlsxData(entries: [DeviceEntry], columns: [ColumnField]) -> Data {
        var rows: [[String]] = [columns.map(\.heading)]
        rows += entries.map { entry in columns.map { entry.value($0) } }

        func columnLetter(_ index: Int) -> String {
            var n = index
            var letters = ""
            while n >= 0 {
                letters = String(UnicodeScalar(UInt8(n % 26 + 65))) + letters
                n = n / 26 - 1
            }
            return letters
        }

        var sheetRows = ""
        for (r, row) in rows.enumerated() {
            var cells = ""
            for (c, value) in row.enumerated() {
                cells += "<c r=\"\(columnLetter(c))\(r + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">"
                    + XMLEscape.text(value) + "</t></is></c>"
            }
            sheetRows += "<row r=\"\(r + 1)\">\(cells)</row>"
        }

        let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        let files: [(String, String)] = [
            ("[Content_Types].xml", xmlHeader
                + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
                + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
                + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
                + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
                + "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
                + "</Types>"),
            ("_rels/.rels", xmlHeader
                + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
                + "</Relationships>"),
            ("xl/workbook.xml", xmlHeader
                + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
                + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
                + "<sheets><sheet name=\"Devices\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", xmlHeader
                + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
                + "</Relationships>"),
            ("xl/worksheets/sheet1.xml", xmlHeader
                + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
                + "<sheetData>\(sheetRows)</sheetData></worksheet>"),
        ]
        return ZipWriter.archive(files.map { ($0.0, Data($0.1.utf8)) })
    }
}

/// Writes an uncompressed ("stored") ZIP archive. Foundation has no public ZIP
/// API, and a spreadsheet of device names is small enough that compression
/// buys nothing.
enum ZipWriter {
    static func archive(_ files: [(name: String, data: Data)]) -> Data {
        var output = Data()
        var central = Data()
        // Fixed DOS timestamp (1980-01-01 00:00) keeps the output reproducible.
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = 0x0021

        for file in files {
            let name = Data(file.name.utf8)
            let crc = crc32(file.data)
            let offset = UInt32(output.count)

            output.append(le32(0x04034b50))
            output.append(le16(20))            // version needed
            output.append(le16(0x0800))        // flags: UTF-8 names
            output.append(le16(0))             // method: stored
            output.append(le16(dosTime))
            output.append(le16(dosDate))
            output.append(le32(crc))
            output.append(le32(UInt32(file.data.count)))
            output.append(le32(UInt32(file.data.count)))
            output.append(le16(UInt16(name.count)))
            output.append(le16(0))             // extra length
            output.append(name)
            output.append(file.data)

            central.append(le32(0x02014b50))
            central.append(le16(20))           // version made by
            central.append(le16(20))           // version needed
            central.append(le16(0x0800))
            central.append(le16(0))
            central.append(le16(dosTime))
            central.append(le16(dosDate))
            central.append(le32(crc))
            central.append(le32(UInt32(file.data.count)))
            central.append(le32(UInt32(file.data.count)))
            central.append(le16(UInt16(name.count)))
            central.append(le16(0))            // extra
            central.append(le16(0))            // comment
            central.append(le16(0))            // disk number
            central.append(le16(0))            // internal attrs
            central.append(le32(0))            // external attrs
            central.append(le32(offset))
            central.append(name)
        }

        let centralOffset = UInt32(output.count)
        output.append(central)
        output.append(le32(0x06054b50))
        output.append(le16(0))
        output.append(le16(0))
        output.append(le16(UInt16(files.count)))
        output.append(le16(UInt16(files.count)))
        output.append(le32(UInt32(central.count)))
        output.append(le32(centralOffset))
        output.append(le16(0))
        return output
    }

    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}
