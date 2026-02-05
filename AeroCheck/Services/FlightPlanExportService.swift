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

            gpx += "    <rtept lat=\"\(String(format: "%.6f", waypoint.latitude))\" lon=\"\(String(format: "%.6f", waypoint.longitude))\">\n"
            gpx += "      <name>\(escapeXML(waypointName))</name>\n"

            // Add elevation if available (convert feet to meters)
            // Note: Some SkyView firmware had issues with <ele> tag, but modern versions handle it
            if let altitudeFeet = waypoint.altitude {
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

        // Route waypoints (15 rows minimum as per template)
        let waypointRows = 15
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
                let eto = waypoint.formattedETO ?? ""
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

    private static func drawFlightPlan(_ plan: FlightPlan, in rect: CGRect, context: CGContext) {
        let margin: CGFloat = 25
        var yPosition: CGFloat = margin

        let titleFont = UIFont.boldSystemFont(ofSize: 11)
        let labelFont = UIFont.systemFont(ofSize: 8)
        let dataFont = UIFont.systemFont(ofSize: 9)
        let smallFont = UIFont.systemFont(ofSize: 7)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd.MM.yyyy"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(0.5)

        let tableWidth = rect.width - 2 * margin
        let tableX = margin

        // Title
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: UIColor.black]
        "AVIS DE VOL - PLAN DE VOL DE NAVIGATION".draw(at: CGPoint(x: margin, y: yPosition), withAttributes: titleAttributes)
        yPosition += 16

        // Header section - 3 rows matching the MODEL layout
        // Column widths proportional to MODEL (6 columns total)
        let headerRowHeight: CGFloat = 20
        let hCol1: CGFloat = 70    // Label (Pilote, Durée totale EET, Instructeur)
        let hCol2: CGFloat = 110   // Value
        let hCol3: CGFloat = 80    // Label (Avion, Autonomie, Date de l'annonce)
        let hCol4: CGFloat = 80    // Value
        let hCol5: CGFloat = 80    // Label (Date, Piste en service, Heure de l'annonce)
        let hCol6: CGFloat = tableWidth - hCol1 - hCol2 - hCol3 - hCol4 - hCol5 // Value

        let labelAttributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: UIColor.black]
        let dataAttributes: [NSAttributedString.Key: Any] = [.font: dataFont, .foregroundColor: UIColor.black]

        // Row 1: Pilote | [value] | Avion | [value] | Date | [value]
        var xOff: CGFloat = tableX
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol1, height: headerRowHeight), text: "Pilote", attributes: labelAttributes)
        xOff += hCol1
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol2, height: headerRowHeight), text: plan.pilot, attributes: dataAttributes)
        xOff += hCol2
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol3, height: headerRowHeight), text: "Avion", attributes: labelAttributes)
        xOff += hCol3
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol4, height: headerRowHeight), text: plan.aircraftRegistration, attributes: dataAttributes)
        xOff += hCol4
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol5, height: headerRowHeight), text: "Date", attributes: labelAttributes)
        xOff += hCol5
        let dateStr = plan.plannedDepartureTime.map { dateFormatter.string(from: $0) } ?? ""
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol6, height: headerRowHeight), text: dateStr, attributes: dataAttributes)
        yPosition += headerRowHeight

        // Row 2: Durée totale EET | [value] | Autonomie | [value] | Piste en service | [value]
        xOff = tableX
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol1, height: headerRowHeight), text: "Durée totale\nEET", attributes: labelAttributes)
        xOff += hCol1
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol2, height: headerRowHeight), text: plan.formattedTotalEET, attributes: dataAttributes)
        xOff += hCol2
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol3, height: headerRowHeight), text: "Autonomie", attributes: labelAttributes)
        xOff += hCol3
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol4, height: headerRowHeight), text: plan.formattedEndurance ?? "--:--", attributes: dataAttributes)
        xOff += hCol4
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol5, height: headerRowHeight), text: "Piste\nen service", attributes: labelAttributes)
        xOff += hCol5
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol6, height: headerRowHeight), text: plan.runwayInUse ?? "", attributes: dataAttributes)
        yPosition += headerRowHeight

        // Row 3: Instructeur | [value] | Date de l'annonce | [value] | Heure de l'annonce | [value]
        xOff = tableX
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol1, height: headerRowHeight), text: "Instructeur", attributes: labelAttributes)
        xOff += hCol1
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol2, height: headerRowHeight), text: plan.instructor ?? "", attributes: dataAttributes)
        xOff += hCol2
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol3, height: headerRowHeight), text: "Date de\nl'annonce", attributes: labelAttributes)
        xOff += hCol3
        let announceDateStr = plan.announcementDate.map { dateFormatter.string(from: $0) } ?? ""
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol4, height: headerRowHeight), text: announceDateStr, attributes: dataAttributes)
        xOff += hCol4
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol5, height: headerRowHeight), text: "Heure de\nl'annonce", attributes: labelAttributes)
        xOff += hCol5
        let announceTimeStr = plan.announcementTime.map { timeFormatter.string(from: $0) } ?? ""
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: hCol6, height: headerRowHeight), text: announceTimeStr, attributes: dataAttributes)
        yPosition += headerRowHeight

        // Route table - 12 columns: Freq, C/S, Waypoint, MC, Dist, Alt, Wind, GS, EET, ETO, ATO, Remarks
        let routeColWidths: [CGFloat] = [45, 32, 75, 32, 32, 32, 32, 32, 32, 38, 38, tableWidth - 420]
        let routeRowHeight: CGFloat = 16

        let headerSmallFont = UIFont.systemFont(ofSize: 8)
        let headerAttributes: [NSAttributedString.Key: Any] = [.font: headerSmallFont, .foregroundColor: UIColor.black]

        // Route header row 1
        let routeHeaders = ["Freq", "C/S", "Waypoint", "MC", "Dist.", "Alt", "Wind", "GS", "EET", "ETO", "ATO", "Remarks"]
        var xPos = tableX
        for (index, header) in routeHeaders.enumerated() {
            drawCell(context, rect: CGRect(x: xPos, y: yPosition, width: routeColWidths[index], height: routeRowHeight),
                     text: header, attributes: headerAttributes, centered: true)
            xPos += routeColWidths[index]
        }
        yPosition += routeRowHeight

        // Route header row 2 with dashes
        let dashHeaders = ["", "", "", "-", "-", "-", "", "-", "-", "-", "-", ""]
        xPos = tableX
        for (index, header) in dashHeaders.enumerated() {
            drawCell(context, rect: CGRect(x: xPos, y: yPosition, width: routeColWidths[index], height: routeRowHeight),
                     text: header, attributes: headerAttributes, centered: true)
            xPos += routeColWidths[index]
        }
        yPosition += routeRowHeight

        // Route waypoints (15 rows)
        let smallDataAttributes: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: UIColor.black]
        let waypointRows = 15
        for i in 0..<waypointRows {
            xPos = tableX
            if i < plan.waypoints.count {
                let waypoint = plan.waypoints[i]
                let isFirstWaypoint = i == 0

                let values: [String] = [
                    waypoint.frequency ?? "",
                    waypoint.callSign ?? "",
                    waypoint.name,
                    isFirstWaypoint ? "" : (waypoint.magneticCourse.map { String(format: "%03d°", Int($0)) } ?? ""),
                    isFirstWaypoint ? "" : (waypoint.distance.map { String(format: "%.1f", $0) } ?? ""),
                    waypoint.altitude.map { String(format: "%.0f", $0) } ?? "",
                    "", // Wind
                    isFirstWaypoint ? "" : (waypoint.plannedGroundSpeed.map { "\($0)" } ?? ""),
                    isFirstWaypoint ? "" : (waypoint.formattedEET ?? ""),
                    waypoint.formattedETO ?? "",
                    waypoint.formattedATO ?? "",
                    waypoint.remarks
                ]

                for (index, value) in values.enumerated() {
                    let centered = index != 2 && index != 11 // Don't center Waypoint and Remarks
                    drawCell(context, rect: CGRect(x: xPos, y: yPosition, width: routeColWidths[index], height: routeRowHeight),
                             text: value, attributes: smallDataAttributes, centered: centered)
                    xPos += routeColWidths[index]
                }
            } else {
                // Empty row
                for width in routeColWidths {
                    drawCell(context, rect: CGRect(x: xPos, y: yPosition, width: width, height: routeRowHeight),
                             text: "", attributes: smallDataAttributes)
                    xPos += width
                }
            }
            yPosition += routeRowHeight
        }

        // Fuel calculation section - matching MODEL layout exactly
        let fuelFlow = plan.fuelFlow ?? FlightPlan.defaultFuelFlow(for: plan.aircraftTypeId)
        let tripFuel = plan.tripFuel ?? 0
        let reserveFuel = plan.reserveFuel ?? 0
        let additionalFuel = plan.additionalFuel ?? (fuelFlow * 0.75)
        let extraFuel = plan.extraFuel ?? 0
        let fuelRequired = tripFuel + reserveFuel + additionalFuel + extraFuel

        let fuelRowHeight: CGFloat = 16

        // Fuel section columns (left side)
        let fuelLabelW: CGFloat = 90
        let fuelFlowW: CGFloat = 50
        let fuelTimeHHW: CGFloat = 32
        let fuelTimeMMW: CGFloat = 32
        let fuelLitersW: CGFloat = 50
        let fuelTotalW = fuelLabelW + fuelFlowW + fuelTimeHHW + fuelTimeMMW + fuelLitersW

        // Timing section columns (right side)
        let gapW: CGFloat = 8
        let timingLabelW: CGFloat = 75
        let timingValueW: CGFloat = 60
        let timingX = tableX + fuelTotalW + gapW

        // Fuel header row
        xOff = tableX
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelLabelW, height: fuelRowHeight), text: "Fuel calculation", attributes: labelAttributes, centered: true)
        xOff += fuelLabelW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelFlowW, height: fuelRowHeight), text: "Fuel flow", attributes: labelAttributes, centered: true)
        xOff += fuelFlowW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelTimeHHW + fuelTimeMMW, height: fuelRowHeight), text: "Time", attributes: labelAttributes, centered: true)
        xOff += fuelTimeHHW + fuelTimeMMW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelLitersW, height: fuelRowHeight), text: "Fuel", attributes: labelAttributes, centered: true)
        // Empty gap cell
        drawCell(context, rect: CGRect(x: tableX + fuelTotalW, y: yPosition, width: gapW, height: fuelRowHeight), text: "", attributes: labelAttributes)
        // Timing: Compteur START
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelW, height: fuelRowHeight), text: "Compteur START", attributes: labelAttributes, centered: true)
        let counterStartStr = plan.counterStart.map { String(format: "%.1f", $0) } ?? ""
        drawCell(context, rect: CGRect(x: timingX + timingLabelW, y: yPosition, width: timingValueW, height: fuelRowHeight), text: counterStartStr, attributes: dataAttributes, centered: true)
        yPosition += fuelRowHeight

        // Trip fuel row
        xOff = tableX
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelLabelW, height: fuelRowHeight), text: "Trip fuel", attributes: smallDataAttributes)
        xOff += fuelLabelW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelFlowW, height: fuelRowHeight), text: String(format: "%.0f", fuelFlow), attributes: smallDataAttributes, centered: true)
        xOff += fuelFlowW
        drawCellWithDottedRight(context, rect: CGRect(x: xOff, y: yPosition, width: fuelTimeHHW, height: fuelRowHeight), text: "", attributes: smallDataAttributes)
        xOff += fuelTimeHHW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelTimeMMW, height: fuelRowHeight), text: "", attributes: smallDataAttributes, centered: true)
        xOff += fuelTimeMMW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelLitersW, height: fuelRowHeight), text: String(format: "%.1f", tripFuel), attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelTotalW, y: yPosition, width: gapW, height: fuelRowHeight), text: "", attributes: labelAttributes)
        // Block OFF
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelW, height: fuelRowHeight), text: "Block OFF", attributes: labelAttributes, centered: true)
        let blockOffStr = plan.blockOff.map { timeFormatter.string(from: $0) } ?? ""
        drawCell(context, rect: CGRect(x: timingX + timingLabelW, y: yPosition, width: timingValueW, height: fuelRowHeight), text: blockOffStr, attributes: dataAttributes, centered: true)
        yPosition += fuelRowHeight

        // Reserve fuel row
        xOff = tableX
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelLabelW, height: fuelRowHeight), text: "Reserve fuel (alt)", attributes: smallDataAttributes)
        xOff += fuelLabelW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelFlowW, height: fuelRowHeight), text: "", attributes: smallDataAttributes, centered: true)
        xOff += fuelFlowW
        drawCellWithDottedRight(context, rect: CGRect(x: xOff, y: yPosition, width: fuelTimeHHW, height: fuelRowHeight), text: "", attributes: smallDataAttributes)
        xOff += fuelTimeHHW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelTimeMMW, height: fuelRowHeight), text: "", attributes: smallDataAttributes, centered: true)
        xOff += fuelTimeMMW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelLitersW, height: fuelRowHeight), text: String(format: "%.1f", reserveFuel), attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelTotalW, y: yPosition, width: gapW, height: fuelRowHeight), text: "", attributes: labelAttributes)
        // Time OFF
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelW, height: fuelRowHeight), text: "Time OFF", attributes: labelAttributes, centered: true)
        let timeOffStr = plan.timeOff.map { timeFormatter.string(from: $0) } ?? ""
        drawCell(context, rect: CGRect(x: timingX + timingLabelW, y: yPosition, width: timingValueW, height: fuelRowHeight), text: timeOffStr, attributes: dataAttributes, centered: true)
        yPosition += fuelRowHeight

        // Additional fuel row
        xOff = tableX
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelLabelW, height: fuelRowHeight), text: "Additional (45')", attributes: smallDataAttributes)
        xOff += fuelLabelW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelFlowW, height: fuelRowHeight), text: "", attributes: smallDataAttributes, centered: true)
        xOff += fuelFlowW
        drawCellWithDottedRight(context, rect: CGRect(x: xOff, y: yPosition, width: fuelTimeHHW, height: fuelRowHeight), text: "0", attributes: smallDataAttributes)
        xOff += fuelTimeHHW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelTimeMMW, height: fuelRowHeight), text: "45", attributes: smallDataAttributes, centered: true)
        xOff += fuelTimeMMW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelLitersW, height: fuelRowHeight), text: String(format: "%.1f", additionalFuel), attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelTotalW, y: yPosition, width: gapW, height: fuelRowHeight), text: "", attributes: labelAttributes)
        // Time ON
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelW, height: fuelRowHeight), text: "Time ON", attributes: labelAttributes, centered: true)
        let timeOnStr = plan.timeOn.map { timeFormatter.string(from: $0) } ?? ""
        drawCell(context, rect: CGRect(x: timingX + timingLabelW, y: yPosition, width: timingValueW, height: fuelRowHeight), text: timeOnStr, attributes: dataAttributes, centered: true)
        yPosition += fuelRowHeight

        // Extra fuel row
        xOff = tableX
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelLabelW, height: fuelRowHeight), text: "Extra fuel", attributes: smallDataAttributes)
        xOff += fuelLabelW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelFlowW, height: fuelRowHeight), text: "", attributes: smallDataAttributes, centered: true)
        xOff += fuelFlowW
        drawCellWithDottedRight(context, rect: CGRect(x: xOff, y: yPosition, width: fuelTimeHHW, height: fuelRowHeight), text: "", attributes: smallDataAttributes)
        xOff += fuelTimeHHW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelTimeMMW, height: fuelRowHeight), text: "", attributes: smallDataAttributes, centered: true)
        xOff += fuelTimeMMW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelLitersW, height: fuelRowHeight), text: String(format: "%.1f", extraFuel), attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelTotalW, y: yPosition, width: gapW, height: fuelRowHeight), text: "", attributes: labelAttributes)
        // Block ON
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelW, height: fuelRowHeight), text: "Block ON", attributes: labelAttributes, centered: true)
        let blockOnStr = plan.blockOn.map { timeFormatter.string(from: $0) } ?? ""
        drawCell(context, rect: CGRect(x: timingX + timingLabelW, y: yPosition, width: timingValueW, height: fuelRowHeight), text: blockOnStr, attributes: dataAttributes, centered: true)
        yPosition += fuelRowHeight

        // Fuel required row
        xOff = tableX
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelLabelW, height: fuelRowHeight), text: "Fuel required", attributes: smallDataAttributes)
        xOff += fuelLabelW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelFlowW, height: fuelRowHeight), text: "", attributes: smallDataAttributes, centered: true)
        xOff += fuelFlowW
        drawCellWithDottedRight(context, rect: CGRect(x: xOff, y: yPosition, width: fuelTimeHHW, height: fuelRowHeight), text: "", attributes: smallDataAttributes)
        xOff += fuelTimeHHW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelTimeMMW, height: fuelRowHeight), text: "", attributes: smallDataAttributes, centered: true)
        xOff += fuelTimeMMW
        drawCell(context, rect: CGRect(x: xOff, y: yPosition, width: fuelLitersW, height: fuelRowHeight), text: String(format: "%.1f", fuelRequired), attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelTotalW, y: yPosition, width: gapW, height: fuelRowHeight), text: "", attributes: labelAttributes)
        // Compteur STOP
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelW, height: fuelRowHeight), text: "Compteur STOP", attributes: labelAttributes, centered: true)
        let counterStopStr = plan.counterStop.map { String(format: "%.1f", $0) } ?? ""
        drawCell(context, rect: CGRect(x: timingX + timingLabelW, y: yPosition, width: timingValueW, height: fuelRowHeight), text: counterStopStr, attributes: dataAttributes, centered: true)
        yPosition += fuelRowHeight

        // Notes section (3 rows tall) with Atterrissages on the right
        let notesHeight = fuelRowHeight * 3
        let notesLabelW: CGFloat = 40
        let notesValueW = fuelTotalW - notesLabelW

        // Notes (spans 3 rows on left)
        drawCell(context, rect: CGRect(x: tableX, y: yPosition, width: notesLabelW, height: notesHeight), text: "Notes", attributes: labelAttributes)
        drawCell(context, rect: CGRect(x: tableX + notesLabelW, y: yPosition, width: notesValueW, height: notesHeight), text: plan.remarks, attributes: smallDataAttributes)
        drawCell(context, rect: CGRect(x: tableX + fuelTotalW, y: yPosition, width: gapW, height: notesHeight), text: "", attributes: labelAttributes)

        // Atterrissages row
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelW, height: fuelRowHeight), text: "Atterrissages", attributes: labelAttributes, centered: true)
        drawCell(context, rect: CGRect(x: timingX + timingLabelW, y: yPosition, width: timingValueW, height: fuelRowHeight), text: "\(plan.landingsAtBase ?? 0) / \(plan.totalLandings ?? 0)", attributes: dataAttributes, centered: true)
        yPosition += fuelRowHeight

        // LSZQ / total row
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelW, height: fuelRowHeight), text: "LSZQ / total", attributes: labelAttributes, centered: true)
        drawCell(context, rect: CGRect(x: timingX + timingLabelW, y: yPosition, width: timingValueW, height: fuelRowHeight), text: "", attributes: dataAttributes, centered: true)
        yPosition += fuelRowHeight

        // Empty row on right to complete Notes section height
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelW + timingValueW, height: fuelRowHeight), text: "", attributes: labelAttributes)
        yPosition += fuelRowHeight

        // Debriefing section (3 rows tall)
        let debriefHeight = fuelRowHeight * 3
        let debriefLabelW: CGFloat = 60
        drawCell(context, rect: CGRect(x: tableX, y: yPosition, width: debriefLabelW, height: debriefHeight), text: "Debriefing", attributes: labelAttributes)
        drawCell(context, rect: CGRect(x: tableX + debriefLabelW, y: yPosition, width: tableWidth - debriefLabelW, height: debriefHeight), text: plan.debriefing, attributes: smallDataAttributes)
    }

    /// Draw a cell with border and text
    private static func drawCell(_ context: CGContext, rect: CGRect, text: String, attributes: [NSAttributedString.Key: Any], centered: Bool = false) {
        context.stroke(rect)

        let textRect = rect.insetBy(dx: 2, dy: 2)
        if centered {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            var centeredAttributes = attributes
            centeredAttributes[.paragraphStyle] = paragraphStyle
            text.draw(in: textRect, withAttributes: centeredAttributes)
        } else {
            text.draw(in: textRect, withAttributes: attributes)
        }
    }

    /// Draw a cell with dotted right border (for Time hh column)
    private static func drawCellWithDottedRight(_ context: CGContext, rect: CGRect, text: String, attributes: [NSAttributedString.Key: Any]) {
        // Draw solid borders on top, bottom, left
        context.setLineDash(phase: 0, lengths: [])
        context.move(to: CGPoint(x: rect.minX, y: rect.minY))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)) // Top
        context.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)) // Bottom
        context.move(to: CGPoint(x: rect.minX, y: rect.minY))
        context.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)) // Left
        context.strokePath()

        // Draw dotted right border
        context.setLineDash(phase: 0, lengths: [2, 2])
        context.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        context.strokePath()

        // Reset dash pattern
        context.setLineDash(phase: 0, lengths: [])

        // Draw text centered
        let textRect = rect.insetBy(dx: 2, dy: 2)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        var centeredAttributes = attributes
        centeredAttributes[.paragraphStyle] = paragraphStyle
        text.draw(in: textRect, withAttributes: centeredAttributes)
    }

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
