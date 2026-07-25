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
    /// Creates a simple XML-based Excel file matching the GVMP template
    static func exportToXLSX(_ flightPlan: FlightPlan) -> Data? {
        // Create XML Spreadsheet 2003 format (simpler than full XLSX)
        let xml = generateExcelXML(flightPlan)
        return xml.data(using: .utf8)
    }

    private static func generateExcelXML(_ plan: FlightPlan) -> String {
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

        // Route waypoints. SEC-C21: the row count is fixed by the template, so anything beyond it
        // was silently dropped — a 16-leg cross-country printed a nav log missing its destination
        // while the in-app route looked complete. The overflow is now stated in the document.
        let waypointRows = 15
        let omittedWaypoints = max(0, plan.waypoints.count - waypointRows)
        for i in 0..<waypointRows {
            if i < plan.waypoints.count {
                let waypoint = plan.waypoints[i]
                let isFirstWaypoint = i == 0
                let mc = isFirstWaypoint ? "" : (waypoint.magneticCourse.map { String(format: "%03d°", Int($0)) } ?? "")
                let dist = isFirstWaypoint ? "" : (waypoint.distance.map { String(format: "%.1f", $0) } ?? "")
                let alt = waypoint.altitude.map { String(format: "%.0f", $0) } ?? ""
                let wind = ""
                let gs = isFirstWaypoint ? "" : (waypoint.plannedGroundSpeed.map { "\($0)" } ?? "")
                let eet = isFirstWaypoint ? "" : (waypoint.formattedEET ?? "")
                let eto = isFirstWaypoint ? "" : (waypoint.formattedETO ?? "")
                let ato = waypoint.formattedATO ?? ""

                xml += """
                <Row ss:Height="16">
                    <Cell ss:StyleID="Data"><Data ss:Type="String">\(escapeXML(waypoint.frequency ?? ""))</Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String">\(escapeXML(waypoint.callSign ?? ""))</Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String">\(escapeXML(waypoint.name))</Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String">\(mc)</Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String">\(dist)</Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String">\(alt)</Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String">\(wind)</Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String">\(gs)</Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String">\(eet)</Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String">\(eto)</Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String">\(ato)</Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String">\(escapeXML(waypoint.remarks))</Data></Cell>
                </Row>
                """
            } else {
                xml += """
                <Row ss:Height="16">
                    <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
                    <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
                </Row>
                """
            }
        }

        // SEC-C21: say so, in the document, when the route did not fit the fixed template.
        if omittedWaypoints > 0 {
            xml += """
            <Row ss:Height="16">
                <Cell ss:StyleID="Header" ss:MergeAcross="11"><Data ss:Type="String">\(escapeXML(L10n.Export.routeTruncated(omittedWaypoints)))</Data></Cell>
            </Row>
            """
        }

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

    // MARK: - PDF Export

    /// Export flight plan to PDF format matching GVMP template
    static func exportToPDF(_ flightPlan: FlightPlan) -> Data? {
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)) // A4

        let data = pdfRenderer.pdfData { context in
            context.beginPage()

            let pageRect = context.pdfContextBounds
            drawFlightPlan(flightPlan, in: pageRect, context: context.cgContext)
        }

        return data
    }

    private static func drawFlightPlan(_ plan: FlightPlan, in rect: CGRect, context ctx: CGContext) {
        let margin: CGFloat = 24
        let tableX = margin
        let tableWidth = rect.width - 2 * margin
        var y = margin

        // Grayscale palette — print-first kneeboard form (#5 PDF redesign, Direction A)
        let ink = UIColor(white: 0.11, alpha: 1)
        let labelInk = UIColor(white: 0.32, alpha: 1)
        let gridLight = UIColor(white: 0.82, alpha: 1)
        let gridMed = UIColor(white: 0.68, alpha: 1)
        let shHeader = UIColor(white: 0.90, alpha: 1)
        let shLabel = UIColor(white: 0.925, alpha: 1)
        let shZebra = UIColor(white: 0.975, alpha: 1)
        let shDep = UIColor(white: 0.95, alpha: 1)
        let shNA = UIColor(white: 0.80, alpha: 1)

        let fTitle = UIFont.boldSystemFont(ofSize: 13)
        let fLabel = UIFont.systemFont(ofSize: 8)
        let fValue = UIFont.systemFont(ofSize: 9.5, weight: .medium)
        let fRouteHdr = UIFont.systemFont(ofSize: 8.3, weight: .semibold)
        let fRoute = UIFont.systemFont(ofSize: 8.3)
        let fSec = UIFont.systemFont(ofSize: 8, weight: .semibold)
        let fFuelHdr = UIFont.systemFont(ofSize: 7.6, weight: .medium)
        let fFuel = UIFont.systemFont(ofSize: 8.2)
        let fGroup = UIFont.systemFont(ofSize: 7.4, weight: .semibold)

        let dateFmt = DateFormatter(); dateFmt.dateFormat = "dd.MM.yyyy"
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"

        func drawText(_ r: CGRect, _ s: String, font: UIFont, align: NSTextAlignment, color: UIColor) {
            guard !s.isEmpty else { return }
            let para = NSMutableParagraphStyle()
            para.alignment = align
            para.lineBreakMode = .byClipping
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
            let inset = r.insetBy(dx: 4, dy: 1)
            let ns = s as NSString
            let bb = ns.boundingRect(with: CGSize(width: inset.width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
            let ty = inset.minY + max(0, (inset.height - bb.height) / 2)
            ns.draw(in: CGRect(x: inset.minX, y: ty, width: inset.width, height: max(bb.height, inset.height)), withAttributes: attrs)
        }

        func cell(_ r: CGRect, _ s: String = "", font: UIFont? = nil, align: NSTextAlignment = .left,
                  fill: UIColor? = nil, color: UIColor? = nil, grid: UIColor? = nil, lw: CGFloat = 0.5, stroke: Bool = true) {
            if let fill = fill {
                ctx.setFillColor(fill.cgColor)
                ctx.fill(r)
            }
            if stroke {
                ctx.setStrokeColor((grid ?? gridLight).cgColor)
                ctx.setLineWidth(lw)
                ctx.stroke(r)
            }
            drawText(r, s, font: font ?? fRoute, align: align, color: color ?? ink)
        }

        func dashedV(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) {
            ctx.saveGState()
            ctx.setStrokeColor(gridMed.cgColor)
            ctx.setLineWidth(0.5)
            ctx.setLineDash(phase: 0, lengths: [1.6, 1.6])
            ctx.move(to: CGPoint(x: x, y: y0))
            ctx.addLine(to: CGPoint(x: x, y: y1))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.restoreGState()
        }

        func section(_ s: String) {
            let attrs: [NSAttributedString.Key: Any] = [.font: fSec, .foregroundColor: labelInk, .kern: 1.1]
            (s.uppercased() as NSString).draw(at: CGPoint(x: tableX, y: y), withAttributes: attrs)
            y += 13
        }

        // Title
        (L10n.PDF.title as NSString).draw(at: CGPoint(x: tableX, y: y),
            withAttributes: [.font: fTitle, .foregroundColor: ink])
        y += 17
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(1.2)
        ctx.move(to: CGPoint(x: tableX, y: y))
        ctx.addLine(to: CGPoint(x: tableX + tableWidth, y: y))
        ctx.strokePath()
        y += 8

        // Header — label / value pairs (each value sits in the cell to the right of its label)
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
        let annDate = plan.announcementDate.map { dateFmt.string(from: $0) } ?? ""
        let annTime = plan.announcementTime.map { timeFmt.string(from: $0) } ?? ""
        headerRow(L10n.PDF.pilot, plan.pilot, L10n.PDF.aircraft, plan.aircraftRegistration, "Date", dateStr)
        headerRow(L10n.PDF.totalEET, plan.formattedTotalEET, L10n.PDF.endurance, plan.formattedEndurance ?? "--:--", L10n.PDF.runwayInUse, plan.runwayInUse ?? "")
        headerRow(L10n.PDF.instructor, plan.instructor ?? "", L10n.PDF.noticeDate, annDate, L10n.PDF.noticeTime, annTime)

        // Route — the centrepiece: 1 + 15 rows, uniform height whether filled or blank
        y += 4
        section("Route")
        var widths: [CGFloat] = [44, 38, 71, 36, 38, 38, 38, 33, 33, 38, 38, 0]
        widths[11] = tableWidth - widths.dropLast().reduce(0, +)
        let headers = ["Freq", "C/S", "Waypoint", "MC", "Dist.", "Alt", "Wind", "GS", "EET", "ETO", "ATO", "Remarks"]
        let routeHdrH: CGFloat = 18
        var hx = tableX
        for (i, h) in headers.enumerated() {
            cell(CGRect(x: hx, y: y, width: widths[i], height: routeHdrH), h, font: fRouteHdr, align: .center, fill: shHeader, grid: gridMed)
            hx += widths[i]
        }
        y += routeHdrH

        let rowH: CGFloat = 18.5
        let naCols: Set<Int> = [3, 4, 5, 6, 7, 8]   // MC, Dist, Alt, Wind, GS, EET — no value on the departure line
        // SEC-C21: the printed nav log is the copy a pilot may actually fly from, so a route longer
        // than the fixed table must not simply stop — potentially without its destination.
        let pdfRouteRows = 16
        let pdfOmittedWaypoints = max(0, plan.waypoints.count - pdfRouteRows)
        for i in 0..<pdfRouteRows {
            let isDep = i == 0
            let rowFill: UIColor? = isDep ? shDep : (i % 2 == 1 ? shZebra : nil)
            let rowFont = isDep ? fRouteHdr : fRoute
            let wp = i < plan.waypoints.count ? plan.waypoints[i] : nil
            var vals = [String](repeating: "", count: 12)
            if let wp = wp {
                vals[0] = wp.frequency ?? ""
                vals[1] = wp.callSign ?? ""
                vals[2] = wp.name
                vals[3] = wp.magneticCourse.map { String(format: "%03d°", Int($0)) } ?? ""
                vals[4] = wp.distance.map { String(format: "%.1f", $0) } ?? ""
                vals[5] = wp.altitude.map { String(format: "%.0f", $0) } ?? ""
                vals[7] = wp.plannedGroundSpeed.map { "\($0)" } ?? ""
                vals[8] = wp.formattedEET ?? ""
                vals[9] = wp.formattedETO ?? ""
                vals[10] = wp.formattedATO ?? ""
                vals[11] = wp.remarks
            }
            var rx = tableX
            for c in 0..<12 {
                let na = isDep && naCols.contains(c)
                let align: NSTextAlignment = (c == 2 || c == 11) ? .left : .center
                cell(CGRect(x: rx, y: y, width: widths[c], height: rowH), na ? "" : vals[c],
                     font: rowFont, align: align, fill: na ? shNA : rowFill)
                rx += widths[c]
            }
            y += rowH
        }

        // SEC-C21: a visible, unmissable line rather than a silently short table.
        if pdfOmittedWaypoints > 0 {
            cell(CGRect(x: tableX, y: y, width: tableWidth, height: rowH),
                 L10n.Export.routeTruncated(pdfOmittedWaypoints),
                 font: fRouteHdr, align: .center, fill: shDep)
            y += rowH
        }

        // Carburant · Temps · Compteur — two panels spanning the full width
        y += 5
        section(L10n.PDF.sectionFuel)
        let panelTop = y
        let panelH: CGFloat = 128
        let panelGap: CGFloat = 9
        let carbW = (tableWidth - panelGap) * 0.6
        let tcW = tableWidth - panelGap - carbW
        let tcX = tableX + carbW + panelGap

        // Carburant (left): label · Fuel flow l/h · Time hh|mm · Fuel liters
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

        // Temps · Compteur · Atterrissages (right) — one shared table
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

        // Notes (1/3) + Debriefing (2/3) fill the remaining page height
        y += 9
        let gap: CGFloat = 8
        let remaining = (rect.height - margin) - y
        let notesH = (remaining - gap) / 3
        let debriefH = remaining - gap - notesH
        cell(CGRect(x: tableX, y: y, width: tableWidth, height: notesH), grid: gridMed)
        ("Notes" as NSString).draw(at: CGPoint(x: tableX + 5, y: y + 4), withAttributes: [.font: fGroup, .foregroundColor: labelInk])
        if !plan.remarks.isEmpty {
            (plan.remarks as NSString).draw(in: CGRect(x: tableX + 5, y: y + 17, width: tableWidth - 10, height: notesH - 20),
                withAttributes: [.font: fFuel, .foregroundColor: ink])
        }
        y += notesH + gap
        cell(CGRect(x: tableX, y: y, width: tableWidth, height: debriefH), grid: gridMed)
        ("Debriefing" as NSString).draw(at: CGPoint(x: tableX + 5, y: y + 4), withAttributes: [.font: fGroup, .foregroundColor: labelInk])
        if !plan.debriefing.isEmpty {
            (plan.debriefing as NSString).draw(in: CGRect(x: tableX + 5, y: y + 17, width: tableWidth - 10, height: debriefH - 20),
                withAttributes: [.font: fFuel, .foregroundColor: ink])
        }
    }

    private static func escapeXML(_ string: String) -> String { string.xmlEscaped }
}
