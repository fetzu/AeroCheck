import Foundation
import PDFKit
import UIKit

/// Service for exporting flight plans to various formats
class FlightPlanExportService {

    // MARK: - JSON Export

    /// Export flight plan to JSON data (re-importable)
    static func exportToJSON(_ flightPlan: FlightPlan) -> Data? {
        return flightPlan.toJSON()
    }

    // MARK: - GPX Export (Avionics Compatible)

    /// Export flight plan to GPX format compatible with Dynon SkyView and Garmin G3X
    ///
    /// This creates a minimal GPX 1.1 route file optimized for avionics import:
    /// - Uses `<rte>` with `<rtept>` elements (route format, not track)
    /// - Limits waypoints to 99 (SkyView maximum)
    /// - Keeps waypoint names ≤20 characters (G3X limitation)
    /// - Uses standard elements only (no custom extensions)
    /// - Elevation in meters as per GPX standard
    static func exportToAvionicsGPX(_ flightPlan: FlightPlan) -> Data? {
        let gpx = generateAvionicsGPX(flightPlan)
        return gpx.data(using: .utf8)
    }

    private static func generateAvionicsGPX(_ plan: FlightPlan) -> String {
        // Limit to 99 waypoints (SkyView reads first 99 rtept in first rte)
        let waypoints = Array(plan.waypoints.prefix(99))

        var gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="AéroCheck"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            <name>\(escapeXML(truncateName(plan.name, maxLength: 50)))</name>
            <desc>Flight plan route exported from AéroCheck</desc>
          </metadata>
          <rte>
            <name>\(escapeXML(truncateName(plan.name, maxLength: 50)))</name>

        """

        // Add route points
        for waypoint in waypoints {
            // Truncate waypoint name to 20 chars (G3X limitation)
            let waypointName = truncateName(waypoint.name, maxLength: 20)

            // SEC-C20: `String(format: "%.6f", .nan)` yields the literal "nan", which would be
            // written into a file loaded by a Dynon/Garmin. Skip a waypoint we cannot express
            // rather than emitting a coordinate no avionics can parse.
            guard GeoValidation.isValidLatLon(waypoint.latitude, waypoint.longitude) else {
                AppLog.general.debugLine("Skipped waypoint with invalid coordinates during GPX export")
                continue
            }
            gpx += "    <rtept lat=\"\(String(format: "%.6f", waypoint.latitude))\" lon=\"\(String(format: "%.6f", waypoint.longitude))\">\n"
            gpx += "      <name>\(escapeXML(waypointName))</name>\n"

            // Add elevation if available (convert feet to meters)
            // Note: Some SkyView firmware had issues with <ele> tag, but modern versions handle it
            if let altitudeFeet = waypoint.altitude,
               PlausibleRange.isPlausible(altitudeFeet, in: PlausibleRange.altitudeFeet) {
                let altitudeMeters = altitudeFeet * 0.3048
                gpx += "      <ele>\(String(format: "%.1f", altitudeMeters))</ele>\n"
            }

            // Add description with additional info if available
            var descParts: [String] = []
            if let freq = waypoint.frequency, !freq.isEmpty {
                descParts.append("Freq: \(freq)")
            }
            if let callSign = waypoint.callSign, !callSign.isEmpty {
                descParts.append("C/S: \(callSign)")
            }
            if !descParts.isEmpty {
                gpx += "      <desc>\(escapeXML(descParts.joined(separator: ", ")))</desc>\n"
            }

            gpx += "    </rtept>\n"
        }

        gpx += """
          </rte>
        </gpx>
        """

        return gpx
    }

    /// Truncate a name to a maximum length, preserving whole words where possible
    private static func truncateName(_ name: String, maxLength: Int) -> String {
        guard name.count > maxLength else { return name }

        // Try to break at a space to keep whole words
        let truncated = String(name.prefix(maxLength))
        if let lastSpace = truncated.lastIndex(of: " "), lastSpace > name.index(name.startIndex, offsetBy: maxLength / 2) {
            return String(truncated[..<lastSpace])
        }
        return truncated
    }

    // MARK: - Excel (XLSX) Export

    /// Export flight plan to XLSX format
    /// Creates a simple XML-based Excel file matching the GVMP template. Same rows as the PDF (the leg
    /// ending at each waypoint), every waypoint (a sheet has no page limit), and the radio plan.
    static func exportToXLSX(_ flightPlan: FlightPlan, radio: RouteRadioPlanner.Plan? = nil) -> Data? {
        // Create XML Spreadsheet 2003 format (simpler than full XLSX)
        let plan = recomputed(flightPlan)
        let xml = generateExcelXML(plan, radio: radio ?? RouteRadioPlanner.manualOnly(plan.waypoints))
        return xml.data(using: .utf8)
    }

    private static func generateExcelXML(_ plan: FlightPlan, radio: RouteRadioPlanner.Plan) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd.MM.yyyy"

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        let dateStr = plan.plannedDepartureTime.map { dateFormatter.string(from: $0) } ?? ""
        let announceDateStr = plan.announcementDate.map { dateFormatter.string(from: $0) } ?? ""
        let announceTimeStr = plan.announcementTime.map { timeFormatter.string(from: $0) } ?? ""

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <?mso-application progid="Excel.Sheet"?>
        <Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"
         xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">
        <Styles>
            <Style ss:ID="Default">
                <Borders>
                    <Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Left" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Right" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Top" ss:LineStyle="Continuous" ss:Weight="1"/>
                </Borders>
            </Style>
            <Style ss:ID="Title">
                <Font ss:Bold="1" ss:Size="11"/>
            </Style>
            <Style ss:ID="Label">
                <Font ss:Size="9"/>
                <Alignment ss:Vertical="Center"/>
                <Borders>
                    <Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Left" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Right" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Top" ss:LineStyle="Continuous" ss:Weight="1"/>
                </Borders>
            </Style>
            <Style ss:ID="Data">
                <Font ss:Size="9"/>
                <Alignment ss:Horizontal="Center" ss:Vertical="Center"/>
                <Borders>
                    <Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Left" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Right" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Top" ss:LineStyle="Continuous" ss:Weight="1"/>
                </Borders>
            </Style>
            <Style ss:ID="Header">
                <Font ss:Size="9"/>
                <Alignment ss:Horizontal="Center" ss:Vertical="Center"/>
                <Borders>
                    <Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Left" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Right" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Top" ss:LineStyle="Continuous" ss:Weight="1"/>
                </Borders>
            </Style>
            <Style ss:ID="DottedRight">
                <Font ss:Size="9"/>
                <Alignment ss:Horizontal="Center" ss:Vertical="Center"/>
                <Borders>
                    <Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Left" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Right" ss:LineStyle="Dot" ss:Weight="1"/>
                    <Border ss:Position="Top" ss:LineStyle="Continuous" ss:Weight="1"/>
                </Borders>
            </Style>
            <Style ss:ID="DottedLeft">
                <Font ss:Size="9"/>
                <Alignment ss:Horizontal="Center" ss:Vertical="Center"/>
                <Borders>
                    <Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Left" ss:LineStyle="Dot" ss:Weight="1"/>
                    <Border ss:Position="Right" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Top" ss:LineStyle="Continuous" ss:Weight="1"/>
                </Borders>
            </Style>
        </Styles>
        <Worksheet ss:Name="Plan de Vol">
        <Table ss:DefaultColumnWidth="54">
            <Column ss:Index="1" ss:Width="54"/>
            <Column ss:Index="2" ss:Width="36"/>
            <Column ss:Index="3" ss:Width="72"/>
            <Column ss:Index="4" ss:Width="36"/>
            <Column ss:Index="5" ss:Width="36"/>
            <Column ss:Index="6" ss:Width="36"/>
            <Column ss:Index="7" ss:Width="36"/>
            <Column ss:Index="8" ss:Width="36"/>
            <Column ss:Index="9" ss:Width="36"/>
            <Column ss:Index="10" ss:Width="36"/>
            <Column ss:Index="11" ss:Width="36"/>
            <Column ss:Index="12" ss:Width="72"/>
        """

        // Title row
        xml += """
        <Row ss:Height="18">
            <Cell ss:StyleID="Title" ss:MergeAcross="11"><Data ss:Type="String">AVIS DE VOL - PLAN DE VOL DE NAVIGATION</Data></Cell>
        </Row>
        """

        // Header section - Row 1: Pilote | [value] | Avion | [value] | Date | [value]
        xml += """
        <Row ss:Height="20">
            <Cell ss:StyleID="Label"><Data ss:Type="String">Pilote</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="2"><Data ss:Type="String">\(escapeXML(plan.pilot))</Data></Cell>
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Avion</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="1"><Data ss:Type="String">\(escapeXML(plan.aircraftRegistration))</Data></Cell>
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Date</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="1"><Data ss:Type="String">\(dateStr)</Data></Cell>
        </Row>
        """

        // Header section - Row 2: Durée totale EET | [value] | Autonomie | [value] | Piste en service | [value]
        xml += """
        <Row ss:Height="20">
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Durée totale EET</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="1"><Data ss:Type="String">\(plan.formattedTotalEET)</Data></Cell>
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Autonomie</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="1"><Data ss:Type="String">\(plan.formattedEndurance ?? "--:--")</Data></Cell>
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Piste en service</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="1"><Data ss:Type="String">\(escapeXML(plan.runwayInUse ?? ""))</Data></Cell>
        </Row>
        """

        // Header section - Row 3: Instructeur | [value] | Date de l'annonce | [value] | Heure de l'annonce | [value]
        xml += """
        <Row ss:Height="20">
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Instructeur</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="1"><Data ss:Type="String">\(escapeXML(plan.instructor ?? ""))</Data></Cell>
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Date de l'annonce</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="1"><Data ss:Type="String">\(announceDateStr)</Data></Cell>
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Heure de l'annonce</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="1"><Data ss:Type="String">\(announceTimeStr)</Data></Cell>
        </Row>
        """

        // Route table header - Row 1 with merged cells for Freq, C/S, Waypoint, Wind, Remarks
        xml += """
        <Row ss:Height="16">
            <Cell ss:StyleID="Header" ss:MergeDown="1"><Data ss:Type="String">Freq</Data></Cell>
            <Cell ss:StyleID="Header" ss:MergeDown="1"><Data ss:Type="String">C/S</Data></Cell>
            <Cell ss:StyleID="Header" ss:MergeDown="1"><Data ss:Type="String">Waypoint</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">MC</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">Dist.</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">Alt</Data></Cell>
            <Cell ss:StyleID="Header" ss:MergeDown="1"><Data ss:Type="String">Wind</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">GS</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">EET</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">ETO</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">ATO</Data></Cell>
            <Cell ss:StyleID="Header" ss:MergeDown="1"><Data ss:Type="String">Remarks</Data></Cell>
        </Row>
        <Row ss:Height="16">
            <Cell ss:Index="4" ss:StyleID="Header"><Data ss:Type="String">-</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">-</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">-</Data></Cell>
            <Cell ss:Index="8" ss:StyleID="Header"><Data ss:Type="String">-</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">-</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">-</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">-</Data></Cell>
        </Row>
        """

        // Route rows: every waypoint (SEC-C21: never truncated), padded with blank rows to the form's
        // 15 so a short route still leaves room to write in.
        let rows = navLogRows(plan, radio: radio)
        func dataCell(_ s: String) -> String {
            "<Cell ss:StyleID=\"Data\"><Data ss:Type=\"String\">\(escapeXML(s))</Data></Cell>"
        }
        for i in 0..<max(15, rows.count) {
            guard i < rows.count else {
                xml += "<Row ss:Height=\"16\">" + String(repeating: dataCell(""), count: 12) + "</Row>\n"
                continue
            }
            let row = rows[i]
            var freq = "", callSign = ""
            if let st = row.station {
                freq = row.stationChanged ? st.frequency + (st.inferredFrom != nil ? "†" : "") : "〃"
                callSign = row.stationChanged ? st.callSign : "〃"
            }
            let cells = [freq, callSign, row.name, row.mc, row.dist, row.alt, row.wind, row.gs, row.eet,
                         row.eto, row.ato, row.remarks.joined(separator: " · ")]
            xml += "<Row ss:Height=\"16\">" + cells.map(dataCell).joined() + "</Row>\n"
        }

        // Radio · airspace: the same box as the PDF.
        func radioRow(_ label: String, _ text: String) {
            xml += """
            <Row ss:Height="16">
                <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">\(escapeXML(label))</Data></Cell>
                <Cell ss:StyleID="Data" ss:MergeAcross="9"><Data ss:Type="String">\(escapeXML(text))</Data></Cell>
            </Row>

            """
        }
        radioRow(L10n.PDF.radioStations, radio.stations
            .map { "\($0.label) \($0.frequency)\($0.marker)" }.joined(separator: " · "))
        if !radio.checkAreas.isEmpty {
            radioRow(radio.checkAreaTag == "DABS" ? "DABS · NOTAM" : "NOTAM", radio.checkAreas.joined(separator: " · "))
        }
        let source = radio.notes + [radio.source.map { L10n.Export.radioSource($0) } ?? L10n.Export.noRadioData,
                                    L10n.Export.verifyFrequencies]
        radioRow(L10n.PDF.radioSource, source.joined(separator: " "))

        // Fuel calculation section - matching template layout exactly
        let fuelFlow = plan.fuelFlow ?? FlightPlan.defaultFuelFlow(for: plan.aircraftTypeId)
        let tripFuel = plan.tripFuel ?? 0
        let reserveFuel = plan.reserveFuel ?? 0
        let additionalFuel = plan.additionalFuel ?? (fuelFlow * 0.75)
        let extraFuel = plan.extraFuel ?? 0
        let fuelRequired = tripFuel + reserveFuel + additionalFuel + extraFuel

        let counterStartStr = plan.counterStart.map { String(format: "%.1f", $0) } ?? ""
        let blockOffStr = plan.blockOff.map { timeFormatter.string(from: $0) } ?? ""
        let timeOffStr = plan.timeOff.map { timeFormatter.string(from: $0) } ?? ""
        let timeOnStr = plan.timeOn.map { timeFormatter.string(from: $0) } ?? ""
        let blockOnStr = plan.blockOn.map { timeFormatter.string(from: $0) } ?? ""
        let counterStopStr = plan.counterStop.map { String(format: "%.1f", $0) } ?? ""

        // Fuel header row: Fuel calculation | Fuel flow l/h | Time hh | mm | Fuel liters | (gap) | Compteur START | [value]
        xml += """
        <Row ss:Height="16">
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Fuel calculation</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">Fuel flow</Data></Cell>
            <Cell ss:StyleID="Header" ss:MergeAcross="1"><Data ss:Type="String">Time</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">Fuel</Data></Cell>
            <Cell ss:StyleID="Data"></Cell>
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Compteur START</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="2"><Data ss:Type="String">\(counterStartStr)</Data></Cell>
        </Row>
        """

        // Trip fuel row
        xml += """
        <Row ss:Height="16">
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Trip fuel</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="Number">\(String(format: "%.0f", fuelFlow))</Data></Cell>
            <Cell ss:StyleID="DottedRight"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="DottedLeft"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="Number">\(String(format: "%.1f", tripFuel))</Data></Cell>
            <Cell ss:StyleID="Data"></Cell>
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Block OFF</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="2"><Data ss:Type="String">\(blockOffStr)</Data></Cell>
        </Row>
        """

        // Reserve fuel row
        xml += """
        <Row ss:Height="16">
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Reserve fuel (alt)</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="DottedRight"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="DottedLeft"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="Number">\(String(format: "%.1f", reserveFuel))</Data></Cell>
            <Cell ss:StyleID="Data"></Cell>
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Time OFF</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="2"><Data ss:Type="String">\(timeOffStr)</Data></Cell>
        </Row>
        """

        // Additional fuel row
        xml += """
        <Row ss:Height="16">
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Additional (45')</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="DottedRight"><Data ss:Type="String">0</Data></Cell>
            <Cell ss:StyleID="DottedLeft"><Data ss:Type="String">45</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="Number">\(String(format: "%.1f", additionalFuel))</Data></Cell>
            <Cell ss:StyleID="Data"></Cell>
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Time ON</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="2"><Data ss:Type="String">\(timeOnStr)</Data></Cell>
        </Row>
        """

        // Extra fuel row
        xml += """
        <Row ss:Height="16">
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Extra fuel</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="DottedRight"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="DottedLeft"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="Number">\(String(format: "%.1f", extraFuel))</Data></Cell>
            <Cell ss:StyleID="Data"></Cell>
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Block ON</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="2"><Data ss:Type="String">\(blockOnStr)</Data></Cell>
        </Row>
        """

        // Fuel required row
        xml += """
        <Row ss:Height="16">
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Fuel required</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="DottedRight"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="DottedLeft"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="Number">\(String(format: "%.1f", fuelRequired))</Data></Cell>
            <Cell ss:StyleID="Data"></Cell>
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Compteur STOP</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="2"><Data ss:Type="String">\(counterStopStr)</Data></Cell>
        </Row>
        """

        // Notes row with Atterrissages on the right
        xml += """
        <Row ss:Height="16">
            <Cell ss:StyleID="Label" ss:MergeDown="2"><Data ss:Type="String">Notes</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="4" ss:MergeDown="2"><Data ss:Type="String">\(escapeXML(plan.remarks))</Data></Cell>
            <Cell ss:StyleID="Data"></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Atterrissages</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="3"><Data ss:Type="String">\(plan.landingsAtBase ?? 0) / \(plan.totalLandings ?? 0)</Data></Cell>
        </Row>
        <Row ss:Height="16">
            <Cell ss:Index="7" ss:StyleID="Data"></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">LSZQ / total</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="3"><Data ss:Type="String"></Data></Cell>
        </Row>
        <Row ss:Height="16">
            <Cell ss:Index="7" ss:StyleID="Data" ss:MergeAcross="5"></Cell>
        </Row>
        """

        // Debriefing section
        xml += """
        <Row ss:Height="16">
            <Cell ss:StyleID="Label" ss:MergeDown="2"><Data ss:Type="String">Debriefing</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="10" ss:MergeDown="2"><Data ss:Type="String">\(escapeXML(plan.debriefing))</Data></Cell>
        </Row>
        <Row ss:Height="16"></Row>
        <Row ss:Height="16"></Row>
        """

        xml += """
        </Table>
        </Worksheet>
        </Workbook>
        """

        return xml
    }

    // MARK: - Nav log rows (PDF + Excel)

    /// One printed nav-log row: a waypoint and the leg that ENDS there. Row 0 is the departure, whose
    /// leg columns do not apply.
    ///
    /// This is the in-app Nav view's convention (`FlightPlan.legArriving(at:)`, UX-01). The paper
    /// exports used to print each waypoint's OUTBOUND leg on its own row while greying out the
    /// departure row, so the first leg never appeared and every other leg sat one row early.
    struct NavLogRow: Equatable {
        var name: String
        var isDeparture: Bool
        var station: RouteRadioPlanner.Station?
        /// False when the station repeats the row above (printed as a ditto mark).
        var stationChanged = false
        var mc = "", dist = "", alt = "", wind = "", gs = "", eet = "", eto = "", ato = ""
        var remarks: [String] = []
    }

    /// Rows for the plan as given; the export entry points recompute the route first (see
    /// `recomputed(_:)`), so Wind/GS/EET/ETO all come from one calculation.
    static func navLogRows(_ plan: FlightPlan, radio: RouteRadioPlanner.Plan) -> [NavLogRow] {
        let wps = plan.waypoints
        let last = wps.count - 1
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        return wps.indices.map { i in
            let wp = wps[i]
            let radioRow = i < radio.rows.count ? radio.rows[i] : RouteRadioPlanner.Row()
            var row = NavLogRow(name: RouteRadioPlanner.displayName(wp, index: i), isDeparture: i == 0,
                                station: radioRow.station, stationChanged: radioRow.changed)
            row.alt = wp.altitude.map { String(format: "%.0f", $0) } ?? ""
            row.ato = wp.formattedATO ?? ""
            let userRemark = wp.remarks.trimmingCharacters(in: .whitespacesAndNewlines)
            row.remarks = (userRemark.isEmpty ? [] : [userRemark]) + radioRow.remarks
            guard i > 0 else {
                row.eto = plan.plannedDepartureTime.map { timeFmt.string(from: $0) } ?? ""
                return row
            }
            let from = wps[i - 1]
            row.mc = from.magneticCourse.map { String(format: "%03d°", Int($0)) } ?? ""
            row.dist = from.distance.map { String(format: "%.1f", $0) } ?? ""
            if let leg = plan.legPlanning(from: i - 1) {
                row.gs = "\(leg.groundSpeedKt)"
                row.wind = leg.wind.map(windText) ?? ""
            }
            // The +5 departure and +5 arrival allowances belong to the first and last legs.
            let extra = (i == 1 ? (wps[0].legEETExtra ?? 0) : 0) + (i == last ? (wp.legEETExtra ?? 0) : 0)
            if let t = from.estimatedElapsedTime {
                let minutes = Int((t / 60).rounded())
                row.eet = extra > 0 ? "\(minutes) + \(Int((extra / 60).rounded()))" : "\(minutes)"
            }
            row.eto = (i == last ? wp.formattedETO : from.formattedETO) ?? ""
            return row
        }
    }

    /// "240/15" — direction the wind blows FROM, degrees true, as forecasts give it.
    static func windText(_ wind: FlightPlan.WindAloft) -> String {
        guard wind.speedKt >= 0.5 else { return "calm" }
        var dir = Int(wind.directionDegTrue.rounded()) % 360
        if dir == 0 { dir = 360 }
        return String(format: "%03d/%02d", dir, Int(wind.speedKt.rounded()))
    }

    /// A copy with its route data recomputed, so the printed Wind and GS (read live from
    /// `legPlanning`) and the stored EET/ETO beside them come from the same calculation even if the
    /// wind cache moved since the plan was last edited.
    static func recomputed(_ plan: FlightPlan) -> FlightPlan {
        var copy = plan
        copy.calculateRouteData()
        return copy
    }

    // MARK: - PDF Export

    /// Paper the nav log is rendered onto. (v5.0.0)
    enum PaperSize: String, CaseIterable, Sendable {
        case a4
        case a5

        /// Points, at 72 dpi.
        var bounds: CGRect {
            switch self {
            case .a4: return CGRect(x: 0, y: 0, width: 595, height: 842)
            case .a5: return CGRect(x: 0, y: 0, width: 420, height: 595)
            }
        }

        var label: String {
            switch self {
            case .a4: return "A4"
            case .a5: return "A5"
            }
        }
    }

    /// Export flight plan to PDF format matching GVMP template.
    ///
    /// The route is never truncated: a route that does not fit one sheet continues on the next, with
    /// the column headers repeated. `radio` fills the Freq/C/S columns, the Remarks and the Radio box;
    /// without it only frequencies typed on the waypoints are printed.
    ///
    /// A5 renders the SAME form scaled to fit rather than a reflowed layout, and that is deliberate.
    /// The drawing is width-relative but its type sizes and row heights are fixed, so dropping the A4
    /// geometry into an A5 box would crush the columns. Scaling keeps every column and the
    /// proportions a pilot already knows from the A4 sheet. The cost is smaller type: about 71 % of A4.
    static func exportToPDF(_ flightPlan: FlightPlan, paperSize: PaperSize = .a4,
                            radio: RouteRadioPlanner.Plan? = nil) -> Data? {
        let plan = recomputed(flightPlan)
        let radioPlan = radio ?? RouteRadioPlanner.manualOnly(plan.waypoints)
        let rows = navLogRows(plan, radio: radioPlan)
        let a4 = PaperSize.a4.bounds
        let page = paperSize.bounds
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: page)
        return pdfRenderer.pdfData { context in
            let painter = NavLogPainter(plan: plan, rows: rows, radio: radioPlan, isFallback: radio == nil)
            let pages = NavLogLayout.pages(rowCount: painter.printedRowCount, radioHeight: painter.radioBoxHeight)
            for (index, layout) in pages.enumerated() {
                context.beginPage()
                let ctx = context.cgContext
                ctx.saveGState()
                if paperSize != .a4 {
                    // Uniform scale so the aspect ratio is preserved — A4 and A5 differ slightly in
                    // ratio, and stretching a form to fill the page would skew every column.
                    let scale = min(page.width / a4.width, page.height / a4.height)
                    ctx.scaleBy(x: scale, y: scale)
                }
                painter.draw(layout, pageNumber: index + 1, pageCount: pages.count, in: ctx)
                ctx.restoreGState()
            }
        }
    }

    /// How many sheets `exportToPDF` will produce — shown on the export menu before anything is shared.
    static func navLogPageCount(_ flightPlan: FlightPlan, radio: RouteRadioPlanner.Plan?) -> Int {
        let plan = recomputed(flightPlan)
        let radioPlan = radio ?? RouteRadioPlanner.manualOnly(plan.waypoints)
        let painter = NavLogPainter(plan: plan, rows: navLogRows(plan, radio: radioPlan),
                                    radio: radioPlan, isFallback: radio == nil)
        return NavLogLayout.pages(rowCount: painter.printedRowCount, radioHeight: painter.radioBoxHeight).count
    }

    // MARK: - PDF page layout

    /// Where each block of the nav log goes, in A4 points. PURE — the painter draws exactly what this
    /// decides, and the tests pin the page breaks without rendering anything.
    ///
    /// Blocks keep the single-sheet order (header, route, radio, fuel · times, notes, debriefing).
    /// When the route does not fit with the rest, it flows onto further pages with its column headers
    /// repeated, never splitting a row; the Radio box follows it; space left on that page becomes
    /// Notes; fuel · times and the debriefing move to the next sheet. The sheet you fly from carries
    /// the whole route and every frequency.
    enum NavLogLayout {
        static let margin: CGFloat = 24
        static let pageHeight: CGFloat = 842
        static var bottom: CGFloat { pageHeight - margin }
        static let firstTop: CGFloat = 106        // title + rule + 3 header rows
        static let continuationTop: CGFloat = 68  // title + rule + 1 running header row
        static let gap: CGFloat = 4
        static let sectionLabel: CGFloat = 13
        static let tableHeader: CGFloat = 18
        static let rowHeight: CGFloat = 18.5
        static let fuelBlock: CGFloat = 5 + 13 + 128
        static let notesMin: CGFloat = 50
        static let debriefMin: CGFloat = 90
        /// Short routes keep blank rows to write in, as the paper form always had.
        static let preferredRows = 16

        struct Page: Equatable {
            var isFirst: Bool
            var routeRows: Range<Int> = 0..<0
            /// The route table carries on to the next page.
            var routeContinues = false
            var routeIsContinuation = false
            var hasRadio = false
            var hasFuel = false
            var hasNotes = false
            var hasDebrief = false
        }

        static func radioBlock(_ height: CGFloat) -> CGFloat { 5 + 13 + height }

        /// Rows a single sheet holds with everything else on it, capped at the form's 16.
        static func singlePageRows(radioHeight: CGFloat) -> Int {
            let room = bottom - firstTop - gap - sectionLabel - tableHeader - radioBlock(radioHeight)
                - fuelBlock - (9 + notesMin + 8 + debriefMin)
            return max(0, min(preferredRows, Int((room / rowHeight).rounded(.down))))
        }

        /// Printed rows: the route, padded with blank rows up to what one sheet holds.
        static func printedRows(waypointCount: Int, radioHeight: CGFloat) -> Int {
            max(waypointCount, singlePageRows(radioHeight: radioHeight))
        }

        static func pages(rowCount: Int, radioHeight: CGFloat) -> [Page] {
            var pages: [Page] = []
            var page = Page(isFirst: true)
            var y = firstTop
            func nextPage() {
                pages.append(page)
                page = Page(isFirst: false)
                y = continuationTop
            }

            // Route: as many whole rows as fit, header repeated on every page.
            var row = 0
            repeat {
                let room = bottom - y - gap - sectionLabel - tableHeader
                let capacity = max(1, Int((room / rowHeight).rounded(.down)))
                let count = min(capacity, rowCount - row)
                page.routeRows = row..<(row + count)
                page.routeIsContinuation = row > 0
                row += count
                y += gap + sectionLabel + tableHeader + CGFloat(count) * rowHeight
                if row < rowCount {
                    page.routeContinues = true
                    nextPage()
                }
            } while row < rowCount

            // Radio box follows the route, whole.
            if y + radioBlock(radioHeight) > bottom { nextPage() }
            page.hasRadio = true
            y += radioBlock(radioHeight)

            // Everything else fits under it: the one-sheet form.
            if bottom - y >= fuelBlock + 9 + notesMin + 8 + debriefMin {
                page.hasFuel = true
                page.hasNotes = true
                page.hasDebrief = true
                pages.append(page)
                return pages
            }
            // Otherwise the rest of this sheet is for notes, and the admin blocks get their own.
            if bottom - y >= 9 + notesMin { page.hasNotes = true }
            let notesPlaced = page.hasNotes
            nextPage()
            page.hasFuel = true
            page.hasNotes = !notesPlaced
            page.hasDebrief = true
            pages.append(page)
            return pages
        }
    }

    // MARK: - PDF drawing

    /// Draws nav-log pages. Grayscale, print-first kneeboard form (#5 PDF redesign, Direction A).
    private final class NavLogPainter {
        let plan: FlightPlan
        let rows: [NavLogRow]
        let radio: RouteRadioPlanner.Plan
        let isFallback: Bool
        private var ctx: CGContext!

        let margin = NavLogLayout.margin
        let tableX: CGFloat = 24
        let tableWidth: CGFloat = 547

        let ink = UIColor(white: 0.11, alpha: 1)
        let labelInk = UIColor(white: 0.32, alpha: 1)
        let faintInk = UIColor(white: 0.45, alpha: 1)
        let dittoInk = UIColor(white: 0.62, alpha: 1)
        let gridLight = UIColor(white: 0.82, alpha: 1)
        let gridMed = UIColor(white: 0.68, alpha: 1)
        let shHeader = UIColor(white: 0.90, alpha: 1)
        let shLabel = UIColor(white: 0.925, alpha: 1)
        let shZebra = UIColor(white: 0.975, alpha: 1)
        let shDep = UIColor(white: 0.95, alpha: 1)
        let shNA = UIColor(white: 0.80, alpha: 1)

        let fTitle = UIFont.boldSystemFont(ofSize: 13)
        let fTitleNote = UIFont.systemFont(ofSize: 8.5, weight: .medium)
        let fLabel = UIFont.systemFont(ofSize: 8)
        let fValue = UIFont.systemFont(ofSize: 9.5, weight: .medium)
        let fRouteHdr = UIFont.systemFont(ofSize: 8.3, weight: .semibold)
        let fRoute = UIFont.systemFont(ofSize: 8.3)
        let fFreq = UIFont.systemFont(ofSize: 8, weight: .bold)
        let fCallSign = UIFont.systemFont(ofSize: 7, weight: .semibold)
        let fRemark = UIFont.systemFont(ofSize: 6.8)
        let fSec = UIFont.systemFont(ofSize: 8, weight: .semibold)
        let fFuelHdr = UIFont.systemFont(ofSize: 7.6, weight: .medium)
        let fFuel = UIFont.systemFont(ofSize: 8.2)
        let fGroup = UIFont.systemFont(ofSize: 7.4, weight: .semibold)
        let fRadio = UIFont.systemFont(ofSize: 7.3)
        let fRadioBold = UIFont.systemFont(ofSize: 7.3, weight: .bold)
        let fFoot = UIFont.systemFont(ofSize: 6.6)

        /// Freq · C/S · Waypoint · MC · Dist · Alt · Wind · GS · EET · ETO · ATO · Remarks (sum 547).
        let widths: [CGFloat] = [42, 66, 70, 28, 28, 32, 34, 24, 32, 32, 34, 125]
        let headers = ["Freq", "C/S", "Waypoint", "MC", "Dist.", "Alt", "Wind", "GS", "EET", "ETO", "ATO", "Remarks"]
        let radioLabelWidth: CGFloat = 62

        let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"; return f }()
        let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

        init(plan: FlightPlan, rows: [NavLogRow], radio: RouteRadioPlanner.Plan, isFallback: Bool) {
            self.plan = plan
            self.rows = rows
            self.radio = radio
            self.isFallback = isFallback
        }

        var printedRowCount: Int {
            NavLogLayout.printedRows(waypointCount: rows.count, radioHeight: radioBoxHeight)
        }

        // MARK: Radio box content

        private var radioLines: [(label: String, text: NSAttributedString)] {
            var lines: [(String, NSAttributedString)] = []
            let stations = NSMutableAttributedString()
            for (i, s) in radio.stations.enumerated() {
                if i > 0 { stations.append(attr(" · ", fRadio, ink)) }
                stations.append(attr(s.label + " ", fRadio, ink))
                stations.append(attr(s.frequency, fRadioBold, ink))
                if !s.marker.isEmpty { stations.append(attr(s.marker, fRadio, ink)) }
            }
            lines.append((L10n.PDF.radioStations, stations))
            if !radio.checkAreas.isEmpty {
                let tag = radio.checkAreaTag == "DABS" ? "DABS · NOTAM" : "NOTAM"
                lines.append((tag, attr(radio.checkAreas.joined(separator: " · "), fRadio, ink)))
            }
            var source = radio.notes
            if isFallback {
                source.append(L10n.Export.noRadioData)
            } else if let src = radio.source {
                source.append(L10n.Export.radioSource(src))
            } else {
                source.append(L10n.Export.noAirspaceData)
            }
            source.append(L10n.Export.verifyFrequencies)
            lines.append((L10n.PDF.radioSource, attr(source.joined(separator: " "), fRadio, faintInk)))
            return lines
        }

        private var radioTextWidth: CGFloat { tableWidth - radioLabelWidth - 10 }

        var radioBoxHeight: CGFloat {
            radioLines.reduce(0) { total, line in
                let h = line.text.boundingRect(with: CGSize(width: radioTextWidth, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin], context: nil).height
                return total + max(ceil(h), 9) + 6
            }
        }

        // MARK: Page

        func draw(_ layout: NavLogLayout.Page, pageNumber: Int, pageCount: Int, in ctx: CGContext) {
            self.ctx = ctx
            var y = margin
            drawTitle(continued: !layout.isFirst, y: &y)
            drawHeader(full: layout.isFirst, y: &y)
            if !layout.routeRows.isEmpty || layout.isFirst {
                drawRoute(layout.routeRows, continuation: layout.routeIsContinuation,
                          continues: layout.routeContinues, y: &y)
            }
            if layout.hasRadio { drawRadio(y: &y) }
            if layout.hasFuel { drawFuel(y: &y) }
            let remaining = NavLogLayout.bottom - y
            switch (layout.hasNotes, layout.hasDebrief) {
            case (true, true):
                let notesH = (remaining - 9 - 8) / 3
                y += 9
                drawBox("Notes", text: plan.remarks, y: y, height: notesH)
                y += notesH + 8
                drawBox("Debriefing", text: plan.debriefing, y: y, height: NavLogLayout.bottom - y)
            case (true, false):
                y += 9
                drawBox("Notes", text: plan.remarks, y: y, height: NavLogLayout.bottom - y)
            case (false, true):
                y += 9
                drawBox("Debriefing", text: plan.debriefing, y: y, height: NavLogLayout.bottom - y)
            case (false, false):
                break
            }
            drawFooter(pageNumber: pageNumber, pageCount: pageCount)
        }

        // MARK: Primitives

        private func attr(_ s: String, _ font: UIFont, _ color: UIColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        }

        private func drawText(_ r: CGRect, _ s: String, font: UIFont, align: NSTextAlignment, color: UIColor,
                              fitWidth: Bool = false) {
            guard !s.isEmpty else { return }
            let inset = r.insetBy(dx: 4, dy: 1)
            var font = font
            if fitWidth {
                // Long call signs shrink to fit rather than clip ("MEIRINGEN TWR").
                while font.pointSize > 5.5,
                      (s as NSString).size(withAttributes: [.font: font]).width > inset.width {
                    font = font.withSize(font.pointSize - 0.25)
                }
            }
            let para = NSMutableParagraphStyle()
            para.alignment = align
            para.lineBreakMode = .byClipping
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
            let ns = s as NSString
            let bb = ns.boundingRect(with: CGSize(width: inset.width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
            let ty = inset.minY + max(0, (inset.height - bb.height) / 2)
            ns.draw(in: CGRect(x: inset.minX, y: ty, width: inset.width, height: max(bb.height, inset.height)),
                    withAttributes: attrs)
        }

        private func cell(_ r: CGRect, _ s: String = "", font: UIFont? = nil, align: NSTextAlignment = .left,
                          fill: UIColor? = nil, color: UIColor? = nil, grid: UIColor? = nil, lw: CGFloat = 0.5,
                          stroke: Bool = true, fitWidth: Bool = false) {
            if let fill {
                ctx.setFillColor(fill.cgColor)
                ctx.fill(r)
            }
            if stroke {
                ctx.setStrokeColor((grid ?? gridLight).cgColor)
                ctx.setLineWidth(lw)
                ctx.stroke(r)
            }
            drawText(r, s, font: font ?? fRoute, align: align, color: color ?? ink, fitWidth: fitWidth)
        }

        private func dashedV(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) {
            ctx.saveGState()
            ctx.setStrokeColor(gridMed.cgColor)
            ctx.setLineWidth(0.5)
            ctx.setLineDash(phase: 0, lengths: [1.6, 1.6])
            ctx.move(to: CGPoint(x: x, y: y0))
            ctx.addLine(to: CGPoint(x: x, y: y1))
            ctx.strokePath()
            ctx.restoreGState()
        }

        private func section(_ s: String, y: inout CGFloat) {
            let attrs: [NSAttributedString.Key: Any] = [.font: fSec, .foregroundColor: labelInk, .kern: 1.1]
            (s.uppercased() as NSString).draw(at: CGPoint(x: tableX, y: y), withAttributes: attrs)
            y += NavLogLayout.sectionLabel
        }

        // MARK: Blocks

        private func drawTitle(continued: Bool, y: inout CGFloat) {
            let title = L10n.PDF.title as NSString
            title.draw(at: CGPoint(x: tableX, y: y), withAttributes: [.font: fTitle, .foregroundColor: ink])
            if continued {
                let w = title.size(withAttributes: [.font: fTitle]).width
                (L10n.PDF.continued as NSString).draw(at: CGPoint(x: tableX + w + 8, y: y + 3),
                                                      withAttributes: [.font: fTitleNote, .foregroundColor: faintInk])
            }
            y += 17
            ctx.setStrokeColor(ink.cgColor)
            ctx.setLineWidth(1.2)
            ctx.move(to: CGPoint(x: tableX, y: y))
            ctx.addLine(to: CGPoint(x: tableX + tableWidth, y: y))
            ctx.strokePath()
            y += 8
        }

        /// Label/value header. Continuation pages repeat only the first row, so a loose sheet still
        /// says whose flight it is.
        private func drawHeader(full: Bool, y: inout CGFloat) {
            let hRow: CGFloat = 19
            let lw1: CGFloat = 84, vw1: CGFloat = 100, lw2: CGFloat = 92, vw2: CGFloat = 72, lw3: CGFloat = 95
            let vw3 = tableWidth - lw1 - vw1 - lw2 - vw2 - lw3
            func headerRow(_ l1: String, _ v1: String, _ l2: String, _ v2: String, _ l3: String, _ v3: String) {
                var x = tableX
                cell(CGRect(x: x, y: y, width: lw1, height: hRow), l1, font: fLabel, fill: shLabel, color: labelInk); x += lw1
                cell(CGRect(x: x, y: y, width: vw1, height: hRow), v1, font: fValue); x += vw1
                cell(CGRect(x: x, y: y, width: lw2, height: hRow), l2, font: fLabel, fill: shLabel, color: labelInk); x += lw2
                cell(CGRect(x: x, y: y, width: vw2, height: hRow), v2, font: fValue); x += vw2
                cell(CGRect(x: x, y: y, width: lw3, height: hRow), l3, font: fLabel, fill: shLabel, color: labelInk); x += lw3
                cell(CGRect(x: x, y: y, width: vw3, height: hRow), v3, font: fValue)
                y += hRow
            }
            let dateStr = plan.plannedDepartureTime.map { dateFmt.string(from: $0) } ?? ""
            headerRow(L10n.PDF.pilot, plan.pilot, L10n.PDF.aircraft, plan.aircraftRegistration, "Date", dateStr)
            guard full else { return }
            let annDate = plan.announcementDate.map { dateFmt.string(from: $0) } ?? ""
            let annTime = plan.announcementTime.map { timeFmt.string(from: $0) } ?? ""
            headerRow(L10n.PDF.totalEET, plan.formattedTotalEET, L10n.PDF.endurance, plan.formattedEndurance ?? "--:--",
                      L10n.PDF.runwayInUse, plan.runwayInUse ?? "")
            headerRow(L10n.PDF.instructor, plan.instructor ?? "", L10n.PDF.noticeDate, annDate, L10n.PDF.noticeTime, annTime)
        }

        private func drawRoute(_ range: Range<Int>, continuation: Bool, continues: Bool, y: inout CGFloat) {
            y += NavLogLayout.gap
            section(continuation ? "Route · \(L10n.PDF.continued)" : "Route", y: &y)
            var hx = tableX
            for (i, h) in headers.enumerated() {
                cell(CGRect(x: hx, y: y, width: widths[i], height: NavLogLayout.tableHeader), h, font: fRouteHdr,
                     align: .center, fill: shHeader, grid: gridMed)
                hx += widths[i]
            }
            y += NavLogLayout.tableHeader

            let rowH = NavLogLayout.rowHeight
            let naCols: Set<Int> = [3, 4, 5, 6, 7, 8]   // MC, Dist, Alt, Wind, GS, EET — not on the departure row
            for i in range {
                let row = i < rows.count ? rows[i] : nil
                let isDep = row?.isDeparture ?? false
                let rowFill: UIColor? = isDep ? shDep : (i % 2 == 1 ? shZebra : nil)
                var rx = tableX
                func next(_ c: Int) -> CGRect {
                    defer { rx += widths[c] }
                    return CGRect(x: rx, y: y, width: widths[c], height: rowH)
                }
                guard let row else {
                    for c in 0..<widths.count { cell(next(c), fill: rowFill) }
                    y += rowH
                    continue
                }
                // Freq · C/S: printed where the station changes, ditto where it repeats.
                if let st = row.station, row.stationChanged {
                    let freq = st.frequency + (st.inferredFrom != nil ? "†" : "")
                    cell(next(0), freq, font: fFreq, align: .center, fill: rowFill, fitWidth: true)
                    cell(next(1), st.callSign, font: fCallSign, fill: rowFill, fitWidth: true)
                } else if row.station != nil {
                    cell(next(0), "〃", font: fRoute, align: .center, fill: rowFill, color: dittoInk)
                    cell(next(1), "〃", font: fRoute, align: .center, fill: rowFill, color: dittoInk)
                } else {
                    cell(next(0), fill: rowFill)
                    cell(next(1), fill: rowFill)
                }
                cell(next(2), row.name, font: isDep ? fRouteHdr : fRoute, fill: rowFill, fitWidth: true)
                let legValues = [row.mc, row.dist, row.alt, row.wind, row.gs, row.eet]
                for (offset, value) in legValues.enumerated() {
                    let c = 3 + offset
                    let na = isDep && naCols.contains(c)
                    cell(next(c), na ? "" : value, font: fRoute, align: .center, fill: na ? shNA : rowFill)
                }
                cell(next(9), row.eto, font: isDep ? fRouteHdr : fRoute, align: .center, fill: rowFill)
                cell(next(10), row.ato, font: fRoute, align: .center, fill: rowFill)
                let remarksRect = next(11)
                cell(remarksRect, fill: rowFill)
                drawRemarks(row.remarks, in: remarksRect)
                y += rowH
            }
            if continues {
                let note = "\(L10n.PDF.routeContinues) ▸" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: fFoot, .foregroundColor: faintInk]
                let w = note.size(withAttributes: attrs).width
                note.draw(at: CGPoint(x: tableX + tableWidth - w, y: y + 2), withAttributes: attrs)
            }
        }

        /// Remarks word-wrapped over at most two lines, items separated by " · "; anything that still
        /// does not fit ends in "…" rather than being cut mid-word at the column edge.
        private func drawRemarks(_ remarks: [String], in rect: CGRect) {
            guard !remarks.isEmpty else { return }
            let inset = rect.insetBy(dx: 4, dy: 1.5)
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping
            let text = NSAttributedString(string: remarks.joined(separator: " · "),
                                          attributes: [.font: fRemark, .foregroundColor: ink, .paragraphStyle: para])
            let twoLines = ceil(fRemark.lineHeight * 2)
            let needed = ceil(text.boundingRect(with: CGSize(width: inset.width, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin], context: nil).height)
            let height = min(needed, twoLines)
            let top = inset.minY + max(0, (inset.height - height) / 2)
            text.draw(with: CGRect(x: inset.minX, y: top, width: inset.width, height: twoLines),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }

        private func drawRadio(y: inout CGFloat) {
            y += 5
            section(L10n.PDF.sectionRadio, y: &y)
            let top = y
            for (label, text) in radioLines {
                let h = max(ceil(text.boundingRect(with: CGSize(width: radioTextWidth, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin], context: nil).height), 9) + 6
                cell(CGRect(x: tableX, y: y, width: radioLabelWidth, height: h), fill: shLabel, grid: gridMed)
                (label as NSString).draw(in: CGRect(x: tableX + 4, y: y + 3, width: radioLabelWidth - 8, height: h - 4),
                                         withAttributes: [.font: fGroup, .foregroundColor: labelInk])
                cell(CGRect(x: tableX + radioLabelWidth, y: y, width: tableWidth - radioLabelWidth, height: h), grid: gridMed)
                text.draw(with: CGRect(x: tableX + radioLabelWidth + 5, y: y + 3, width: radioTextWidth, height: h),
                          options: [.usesLineFragmentOrigin], context: nil)
                y += h
            }
            ctx.setStrokeColor(gridMed.cgColor)
            ctx.setLineWidth(0.5)
            ctx.stroke(CGRect(x: tableX, y: top, width: tableWidth, height: y - top))
        }

        /// Fuel calculation (left) and Times · Counter · Landings (right).
        private func drawFuel(y: inout CGFloat) {
            y += 5
            section(L10n.PDF.sectionFuel, y: &y)
            let panelTop = y
            let panelH: CGFloat = 128
            let panelGap: CGFloat = 9
            let carbW = (tableWidth - panelGap) * 0.6
            let tcW = tableWidth - panelGap - carbW
            let tcX = tableX + carbW + panelGap

            let cLabelW = carbW * 0.34
            let cFFW = carbW * 0.18
            let cHHW = carbW * 0.13
            let cMMW = carbW * 0.13
            let cFuelW = carbW - cLabelW - cFFW - cHHW - cMMW
            let carbHdrH: CGFloat = 22
            let timeW = cHHW + cMMW

            var chx = tableX
            cell(CGRect(x: chx, y: panelTop, width: cLabelW, height: carbHdrH), "Fuel calculation", font: fFuelHdr, fill: shHeader, color: labelInk, grid: gridMed); chx += cLabelW
            cell(CGRect(x: chx, y: panelTop, width: cFFW, height: carbHdrH), "Fuel flow\nl/h", font: fFuelHdr, align: .center, fill: shHeader, color: labelInk, grid: gridMed); chx += cFFW
            cell(CGRect(x: chx, y: panelTop, width: timeW, height: carbHdrH / 2), "Time", font: fFuelHdr, align: .center, fill: shHeader, color: labelInk, grid: gridMed)
            cell(CGRect(x: chx, y: panelTop + carbHdrH / 2, width: timeW, height: carbHdrH / 2), "", fill: shHeader, grid: gridMed)
            dashedV(chx + cHHW, panelTop + carbHdrH / 2, panelTop + carbHdrH)
            drawText(CGRect(x: chx, y: panelTop + carbHdrH / 2, width: cHHW, height: carbHdrH / 2), "hh", font: fFuelHdr, align: .center, color: labelInk)
            drawText(CGRect(x: chx + cHHW, y: panelTop + carbHdrH / 2, width: cMMW, height: carbHdrH / 2), "mm", font: fFuelHdr, align: .center, color: labelInk)
            chx += timeW
            cell(CGRect(x: chx, y: panelTop, width: cFuelW, height: carbHdrH), "Fuel\nliters", font: fFuelHdr, align: .center, fill: shHeader, color: labelInk, grid: gridMed)

            let fuelFlow = plan.fuelFlow ?? FlightPlan.defaultFuelFlow(for: plan.aircraftTypeId)
            let tripFuel = plan.tripFuel ?? 0
            let reserveFuel = plan.reserveFuel ?? 0
            let additionalFuel = plan.additionalFuel ?? (fuelFlow * 0.75)
            let extraFuel = plan.extraFuel ?? 0
            let fuelRequired = tripFuel + reserveFuel + additionalFuel + extraFuel
            func fmtL(_ v: Double) -> String { String(format: "%.1f", v) }
            let carbRows: [(label: String, ff: String, hh: String, mm: String, liters: String, ffGrey: Bool)] = [
                ("Trip fuel", String(format: "%.0f", fuelFlow), "", "", fmtL(tripFuel), false),
                ("Reserve fuel (alt)", "", "", "", fmtL(reserveFuel), false),
                ("Additional (45')", "", "0", "45", fmtL(additionalFuel), false),
                ("Extra fuel", "", "", "", fmtL(extraFuel), false),
                ("Fuel required", "", "", "", fmtL(fuelRequired), true)
            ]
            let carbRowH = (panelH - carbHdrH) / CGFloat(carbRows.count)
            for (idx, row) in carbRows.enumerated() {
                let cy = panelTop + carbHdrH + CGFloat(idx) * carbRowH
                let isTot = idx == carbRows.count - 1
                let rf: UIColor? = isTot ? shDep : nil
                let lblFont = isTot ? fRouteHdr : fFuel
                var rx = tableX
                cell(CGRect(x: rx, y: cy, width: cLabelW, height: carbRowH), row.label, font: lblFont, fill: rf); rx += cLabelW
                cell(CGRect(x: rx, y: cy, width: cFFW, height: carbRowH), row.ffGrey ? "" : row.ff, font: fFuel, align: .center, fill: row.ffGrey ? shNA : rf); rx += cFFW
                cell(CGRect(x: rx, y: cy, width: timeW, height: carbRowH), "", fill: rf)
                dashedV(rx + cHHW, cy, cy + carbRowH)
                drawText(CGRect(x: rx, y: cy, width: cHHW, height: carbRowH), row.hh, font: fFuel, align: .center, color: ink)
                drawText(CGRect(x: rx + cHHW, y: cy, width: cMMW, height: carbRowH), row.mm, font: fFuel, align: .center, color: ink)
                rx += timeW
                cell(CGRect(x: rx, y: cy, width: cFuelW, height: carbRowH), row.liters, font: lblFont, align: .center, fill: rf)
            }

            let tcLabelW = tcW * 0.6
            let tcValW = tcW - tcLabelW
            let groupH: CGFloat = 12
            let tcRowH = (panelH - 2 * groupH) / 7
            var ty = panelTop
            func tcGroup(_ s: String) {
                cell(CGRect(x: tcX, y: ty, width: tcW, height: groupH), s, font: fGroup, fill: shHeader, color: labelInk, grid: gridMed)
                ty += groupH
            }
            func tcRow(_ k: String, _ v: String) {
                cell(CGRect(x: tcX, y: ty, width: tcLabelW, height: tcRowH), k, font: fFuel, color: labelInk)
                cell(CGRect(x: tcX + tcLabelW, y: ty, width: tcValW, height: tcRowH), v, font: fValue, align: .right)
                ty += tcRowH
            }
            tcGroup(L10n.PDF.groupTimes)
            tcRow("Block OFF", plan.blockOff.map { timeFmt.string(from: $0) } ?? "")
            tcRow("Time OFF", plan.timeOff.map { timeFmt.string(from: $0) } ?? "")
            tcRow("Time ON", plan.timeOn.map { timeFmt.string(from: $0) } ?? "")
            tcRow("Block ON", plan.blockOn.map { timeFmt.string(from: $0) } ?? "")
            tcGroup(L10n.PDF.groupCounter)
            tcRow(L10n.PDF.counterStart, plan.counterStart.map { String(format: "%.1f", $0) } ?? "")
            tcRow(L10n.PDF.counterStop, plan.counterStop.map { String(format: "%.1f", $0) } ?? "")
            tcRow(L10n.PDF.landings, "\(plan.landingsAtBase ?? 0) / \(plan.totalLandings ?? 0)")

            y = panelTop + panelH
        }

        private func drawBox(_ title: String, text: String, y: CGFloat, height: CGFloat) {
            guard height > 12 else { return }
            cell(CGRect(x: tableX, y: y, width: tableWidth, height: height), grid: gridMed)
            (title as NSString).draw(at: CGPoint(x: tableX + 5, y: y + 4), withAttributes: [.font: fGroup, .foregroundColor: labelInk])
            if !text.isEmpty {
                (text as NSString).draw(in: CGRect(x: tableX + 5, y: y + 17, width: tableWidth - 10, height: height - 20),
                                        withAttributes: [.font: fFuel, .foregroundColor: ink])
            }
        }

        /// Route, aircraft and date on every sheet, plus "page n / N" when there is more than one.
        private func drawFooter(pageNumber: Int, pageCount: Int) {
            let attrs: [NSAttributedString.Key: Any] = [.font: fFoot, .foregroundColor: faintInk]
            var left: [String] = []
            if let first = plan.waypoints.first, let last = plan.waypoints.last, plan.waypoints.count >= 2 {
                left.append("\(RouteRadioPlanner.displayName(first, index: 0)) → \(RouteRadioPlanner.displayName(last, index: plan.waypoints.count - 1))")
            }
            if !plan.aircraftRegistration.isEmpty { left.append(plan.aircraftRegistration) }
            if let date = plan.plannedDepartureTime { left.append(dateFmt.string(from: date)) }
            let footY = NavLogLayout.pageHeight - margin + 8
            (left.joined(separator: " · ") as NSString).draw(at: CGPoint(x: tableX, y: footY), withAttributes: attrs)
            let right = pageCount > 1 ? "AeroCheck · \(L10n.PDF.page(pageNumber, pageCount))" : "AeroCheck"
            let w = (right as NSString).size(withAttributes: attrs).width
            (right as NSString).draw(at: CGPoint(x: tableX + tableWidth - w, y: footY), withAttributes: attrs)
        }
    }

    private static func escapeXML(_ string: String) -> String { string.xmlEscaped }
}
