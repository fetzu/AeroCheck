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
                <Font ss:Bold="1" ss:Size="12"/>
            </Style>
            <Style ss:ID="Label">
                <Font ss:Bold="1" ss:Size="9"/>
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
                <Font ss:Bold="1" ss:Size="9"/>
                <Alignment ss:Horizontal="Center" ss:Vertical="Center"/>
                <Borders>
                    <Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Left" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Right" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Top" ss:LineStyle="Continuous" ss:Weight="1"/>
                </Borders>
            </Style>
            <Style ss:ID="FuelLabel">
                <Font ss:Size="9"/>
                <Borders>
                    <Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Left" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Right" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Top" ss:LineStyle="Continuous" ss:Weight="1"/>
                </Borders>
            </Style>
            <Style ss:ID="FuelHeader">
                <Font ss:Size="9"/>
                <Alignment ss:Horizontal="Center" ss:Vertical="Center"/>
                <Borders>
                    <Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Left" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Right" ss:LineStyle="Continuous" ss:Weight="1"/>
                    <Border ss:Position="Top" ss:LineStyle="Continuous" ss:Weight="1"/>
                </Borders>
            </Style>
            <Style ss:ID="NoBorder">
                <Font ss:Size="9"/>
            </Style>
        </Styles>
        <Worksheet ss:Name="Plan de Vol">
        <Table ss:DefaultColumnWidth="60">
            <Column ss:Index="1" ss:Width="50"/>
            <Column ss:Index="2" ss:Width="40"/>
            <Column ss:Index="3" ss:Width="90"/>
            <Column ss:Index="4" ss:Width="35"/>
            <Column ss:Index="5" ss:Width="35"/>
            <Column ss:Index="6" ss:Width="40"/>
            <Column ss:Index="7" ss:Width="40"/>
            <Column ss:Index="8" ss:Width="35"/>
            <Column ss:Index="9" ss:Width="40"/>
            <Column ss:Index="10" ss:Width="40"/>
            <Column ss:Index="11" ss:Width="40"/>
            <Column ss:Index="12" ss:Width="100"/>
        """

        // Title row
        xml += """
        <Row ss:Height="20">
            <Cell ss:StyleID="Title" ss:MergeAcross="11"><Data ss:Type="String">AVIS DE VOL - PLAN DE VOL DE NAVIGATION</Data></Cell>
        </Row>
        """

        // Header section - Row 1: Pilote | Avion | Date
        xml += """
        <Row>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Pilote</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="2"><Data ss:Type="String">\(escapeXML(plan.pilot))</Data></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Avion</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="1"><Data ss:Type="String">\(escapeXML(plan.aircraftRegistration))</Data></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Date</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="3"><Data ss:Type="String">\(dateStr)</Data></Cell>
        </Row>
        """

        // Header section - Row 2: Durée totale EET | Autonomie | Piste en service
        xml += """
        <Row>
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Durée totale EET</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="1"><Data ss:Type="String">\(plan.formattedTotalEET)</Data></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Autonomie</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="1"><Data ss:Type="String">\(plan.formattedEndurance ?? "--:--")</Data></Cell>
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Piste en service</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="2"><Data ss:Type="String">\(escapeXML(plan.runwayInUse ?? ""))</Data></Cell>
        </Row>
        """

        // Header section - Row 3: Instructeur | Date de l'annonce | Heure de l'annonce
        xml += """
        <Row>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Instructeur</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="2"><Data ss:Type="String">\(escapeXML(plan.instructor ?? ""))</Data></Cell>
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Date de l'annonce</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String">\(announceDateStr)</Data></Cell>
            <Cell ss:StyleID="Label" ss:MergeAcross="1"><Data ss:Type="String">Heure de l'annonce</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="2"><Data ss:Type="String">\(announceTimeStr)</Data></Cell>
        </Row>
        """

        // Route table header - Two rows as per template
        // First header row
        xml += """
        <Row>
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
        <Row>
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
                <Row>
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
                <Row>
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

        // Fuel calculation section - matching template layout
        let fuelFlow = plan.fuelFlow ?? FlightPlan.defaultFuelFlow(for: plan.aircraftType)
        let tripFuel = plan.tripFuel ?? 0
        let reserveFuel = plan.reserveFuel ?? 0
        let additionalFuel = plan.additionalFuel ?? (fuelFlow * 0.75)
        let extraFuel = plan.extraFuel ?? 0
        let fuelRequired = tripFuel + reserveFuel + additionalFuel + extraFuel

        // Fuel header row
        xml += """
        <Row>
            <Cell ss:StyleID="FuelHeader" ss:MergeAcross="1"><Data ss:Type="String">Fuel calculation</Data></Cell>
            <Cell ss:StyleID="FuelHeader"><Data ss:Type="String">Fuel flow l/h</Data></Cell>
            <Cell ss:StyleID="FuelHeader" ss:MergeAcross="1"><Data ss:Type="String">Time</Data></Cell>
            <Cell ss:StyleID="FuelHeader" ss:MergeAcross="1"><Data ss:Type="String">Fuel liters</Data></Cell>
            <Cell ss:StyleID="NoBorder"></Cell>
            <Cell ss:StyleID="FuelHeader" ss:MergeAcross="2"><Data ss:Type="String">Compteur START</Data></Cell>
        </Row>
        """

        // Sub-header for time columns
        xml += """
        <Row>
            <Cell ss:StyleID="FuelLabel"><Data ss:Type="String">Trip fuel</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="Number">\(String(format: "%.0f", fuelFlow))</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="1"><Data ss:Type="Number">\(String(format: "%.1f", tripFuel))</Data></Cell>
            <Cell ss:StyleID="NoBorder"></Cell>
            <Cell ss:StyleID="FuelHeader" ss:MergeAcross="1"><Data ss:Type="String">Block OFF</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String">\(plan.counterStart.map { String(format: "%.1f", $0) } ?? "")</Data></Cell>
        </Row>
        <Row>
            <Cell ss:StyleID="FuelLabel"><Data ss:Type="String">Reserve fuel (alt)</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="1"><Data ss:Type="Number">\(String(format: "%.1f", reserveFuel))</Data></Cell>
            <Cell ss:StyleID="NoBorder"></Cell>
            <Cell ss:StyleID="FuelHeader" ss:MergeAcross="1"><Data ss:Type="String">Time OFF</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String">\(plan.blockOff.map { timeFormatter.string(from: $0) } ?? "")</Data></Cell>
        </Row>
        <Row>
            <Cell ss:StyleID="FuelLabel"><Data ss:Type="String">Additional (45')</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String">0</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String">45</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="1"><Data ss:Type="Number">\(String(format: "%.1f", additionalFuel))</Data></Cell>
            <Cell ss:StyleID="NoBorder"></Cell>
            <Cell ss:StyleID="FuelHeader" ss:MergeAcross="1"><Data ss:Type="String">Time ON</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String">\(plan.timeOff.map { timeFormatter.string(from: $0) } ?? "")</Data></Cell>
        </Row>
        <Row>
            <Cell ss:StyleID="FuelLabel"><Data ss:Type="String">Extra fuel</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="1"><Data ss:Type="Number">\(String(format: "%.1f", extraFuel))</Data></Cell>
            <Cell ss:StyleID="NoBorder"></Cell>
            <Cell ss:StyleID="FuelHeader" ss:MergeAcross="1"><Data ss:Type="String">Block ON</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String">\(plan.timeOn.map { timeFormatter.string(from: $0) } ?? "")</Data></Cell>
        </Row>
        <Row>
            <Cell ss:StyleID="FuelLabel"><Data ss:Type="String">Fuel required</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="1"><Data ss:Type="Number">\(String(format: "%.1f", fuelRequired))</Data></Cell>
            <Cell ss:StyleID="NoBorder"></Cell>
            <Cell ss:StyleID="FuelHeader" ss:MergeAcross="1"><Data ss:Type="String">Compteur STOP</Data></Cell>
            <Cell ss:StyleID="Data"><Data ss:Type="String">\(plan.counterStop.map { String(format: "%.1f", $0) } ?? "")</Data></Cell>
        </Row>
        """

        // Notes section with Atterrissages on the right
        xml += """
        <Row>
            <Cell ss:StyleID="FuelLabel"><Data ss:Type="String">Notes</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="5"><Data ss:Type="String">\(escapeXML(plan.remarks))</Data></Cell>
            <Cell ss:StyleID="NoBorder"></Cell>
            <Cell ss:StyleID="FuelHeader"><Data ss:Type="String">Atterrissages</Data></Cell>
            <Cell ss:StyleID="Data" ss:MergeAcross="2"><Data ss:Type="String">\(plan.landingsAtBase ?? 0) / \(plan.totalLandings ?? 0)</Data></Cell>
        </Row>
        <Row>
            <Cell ss:StyleID="Data" ss:MergeAcross="6"><Data ss:Type="String"></Data></Cell>
            <Cell ss:StyleID="NoBorder"></Cell>
            <Cell ss:StyleID="FuelHeader"><Data ss:Type="String">LSZQ / total</Data></Cell>
            <Cell ss:StyleID="NoBorder" ss:MergeAcross="2"></Cell>
        </Row>
        """

        // Debriefing section
        xml += """
        <Row ss:Height="15">
            <Cell ss:StyleID="FuelLabel"><Data ss:Type="String">Debriefing</Data></Cell>
            <Cell ss:StyleID="NoBorder" ss:MergeAcross="10"></Cell>
        </Row>
        <Row ss:Height="60">
            <Cell ss:StyleID="Data" ss:MergeAcross="11"><Data ss:Type="String">\(escapeXML(plan.debriefing))</Data></Cell>
        </Row>
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
        yPosition += 18

        // Header section - 3 rows with cells matching template
        let headerRowHeight: CGFloat = 24
        let col1Width: CGFloat = 90   // Pilote / Durée totale EET / Instructeur
        let col2Width: CGFloat = 120  // Value
        let col3Width: CGFloat = 80   // Avion / Autonomie / Date de l'annonce
        let col4Width: CGFloat = 80   // Value
        let col5Width: CGFloat = 80   // Date / Piste en service / Heure de l'annonce
        let col6Width: CGFloat = tableWidth - col1Width - col2Width - col3Width - col4Width - col5Width // Remaining

        let labelAttributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: UIColor.black]
        let dataAttributes: [NSAttributedString.Key: Any] = [.font: dataFont, .foregroundColor: UIColor.black]

        // Row 1: Pilote | [value] | Avion | [value] | Date | [value]
        drawCell(context, rect: CGRect(x: tableX, y: yPosition, width: col1Width, height: headerRowHeight),
                 text: "Pilote", attributes: labelAttributes)
        drawCell(context, rect: CGRect(x: tableX + col1Width, y: yPosition, width: col2Width, height: headerRowHeight),
                 text: plan.pilot, attributes: dataAttributes)
        drawCell(context, rect: CGRect(x: tableX + col1Width + col2Width, y: yPosition, width: col3Width, height: headerRowHeight),
                 text: "Avion", attributes: labelAttributes)
        drawCell(context, rect: CGRect(x: tableX + col1Width + col2Width + col3Width, y: yPosition, width: col4Width, height: headerRowHeight),
                 text: plan.aircraftRegistration, attributes: dataAttributes)
        drawCell(context, rect: CGRect(x: tableX + col1Width + col2Width + col3Width + col4Width, y: yPosition, width: col5Width, height: headerRowHeight),
                 text: "Date", attributes: labelAttributes)
        let dateStr = plan.plannedDepartureTime.map { dateFormatter.string(from: $0) } ?? ""
        drawCell(context, rect: CGRect(x: tableX + col1Width + col2Width + col3Width + col4Width + col5Width, y: yPosition, width: col6Width, height: headerRowHeight),
                 text: dateStr, attributes: dataAttributes)
        yPosition += headerRowHeight

        // Row 2: Durée totale EET | [value] | Autonomie | [value] | Piste en service | [value]
        drawCell(context, rect: CGRect(x: tableX, y: yPosition, width: col1Width, height: headerRowHeight),
                 text: "Durée totale\nEET", attributes: labelAttributes)
        drawCell(context, rect: CGRect(x: tableX + col1Width, y: yPosition, width: col2Width, height: headerRowHeight),
                 text: plan.formattedTotalEET, attributes: dataAttributes)
        drawCell(context, rect: CGRect(x: tableX + col1Width + col2Width, y: yPosition, width: col3Width, height: headerRowHeight),
                 text: "Autonomie", attributes: labelAttributes)
        drawCell(context, rect: CGRect(x: tableX + col1Width + col2Width + col3Width, y: yPosition, width: col4Width, height: headerRowHeight),
                 text: plan.formattedEndurance ?? "--:--", attributes: dataAttributes)
        drawCell(context, rect: CGRect(x: tableX + col1Width + col2Width + col3Width + col4Width, y: yPosition, width: col5Width, height: headerRowHeight),
                 text: "Piste\nen service", attributes: labelAttributes)
        drawCell(context, rect: CGRect(x: tableX + col1Width + col2Width + col3Width + col4Width + col5Width, y: yPosition, width: col6Width, height: headerRowHeight),
                 text: plan.runwayInUse ?? "", attributes: dataAttributes)
        yPosition += headerRowHeight

        // Row 3: Instructeur | [value] | Date de l'annonce | [value] | Heure de l'annonce | [value]
        drawCell(context, rect: CGRect(x: tableX, y: yPosition, width: col1Width, height: headerRowHeight),
                 text: "Instructeur", attributes: labelAttributes)
        drawCell(context, rect: CGRect(x: tableX + col1Width, y: yPosition, width: col2Width, height: headerRowHeight),
                 text: plan.instructor ?? "", attributes: dataAttributes)
        drawCell(context, rect: CGRect(x: tableX + col1Width + col2Width, y: yPosition, width: col3Width, height: headerRowHeight),
                 text: "Date de\nl'annonce", attributes: labelAttributes)
        let announceDateStr = plan.announcementDate.map { dateFormatter.string(from: $0) } ?? ""
        drawCell(context, rect: CGRect(x: tableX + col1Width + col2Width + col3Width, y: yPosition, width: col4Width, height: headerRowHeight),
                 text: announceDateStr, attributes: dataAttributes)
        drawCell(context, rect: CGRect(x: tableX + col1Width + col2Width + col3Width + col4Width, y: yPosition, width: col5Width, height: headerRowHeight),
                 text: "Heure de\nl'annonce", attributes: labelAttributes)
        let announceTimeStr = plan.announcementTime.map { timeFormatter.string(from: $0) } ?? ""
        drawCell(context, rect: CGRect(x: tableX + col1Width + col2Width + col3Width + col4Width + col5Width, y: yPosition, width: col6Width, height: headerRowHeight),
                 text: announceTimeStr, attributes: dataAttributes)
        yPosition += headerRowHeight

        // Route table - columns matching template
        let routeColWidths: [CGFloat] = [40, 30, 70, 30, 30, 30, 35, 28, 32, 35, 35, tableWidth - 395] // Freq, C/S, Waypoint, MC, Dist, Alt, Wind, GS, EET, ETO, ATO, Remarks
        let routeRowHeight: CGFloat = 16

        // Route header - two rows as per template
        let headerSmallFont = UIFont.boldSystemFont(ofSize: 7)
        let headerAttributes: [NSAttributedString.Key: Any] = [.font: headerSmallFont, .foregroundColor: UIColor.black]

        // First header row
        let routeHeaders = ["Freq", "C/S", "Waypoint", "MC", "Dist.", "Alt", "Wind", "GS", "EET", "ETO", "ATO", "Remarks"]
        var xPos = tableX
        for (index, header) in routeHeaders.enumerated() {
            drawCell(context, rect: CGRect(x: xPos, y: yPosition, width: routeColWidths[index], height: routeRowHeight),
                     text: header, attributes: headerAttributes, centered: true)
            xPos += routeColWidths[index]
        }
        yPosition += routeRowHeight

        // Second header row with dashes
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

        // Fuel calculation section - side by side with timing section
        let fuelFlow = plan.fuelFlow ?? FlightPlan.defaultFuelFlow(for: plan.aircraftType)
        let tripFuel = plan.tripFuel ?? 0
        let reserveFuel = plan.reserveFuel ?? 0
        let additionalFuel = plan.additionalFuel ?? (fuelFlow * 0.75)
        let extraFuel = plan.extraFuel ?? 0
        let fuelRequired = tripFuel + reserveFuel + additionalFuel + extraFuel

        let fuelRowHeight: CGFloat = 16
        let fuelLabelWidth: CGFloat = 95
        let fuelFlowWidth: CGFloat = 50
        let fuelTimeHHWidth: CGFloat = 30
        let fuelTimeMMWidth: CGFloat = 30
        let fuelLitersWidth: CGFloat = 50
        let fuelSectionWidth = fuelLabelWidth + fuelFlowWidth + fuelTimeHHWidth + fuelTimeMMWidth + fuelLitersWidth

        // Timing section widths (on the right)
        let timingGap: CGFloat = 15
        let timingLabelWidth: CGFloat = 70
        let timingValueWidth: CGFloat = 50
        let timingX = tableX + fuelSectionWidth + timingGap

        // Fuel header row
        drawCell(context, rect: CGRect(x: tableX, y: yPosition, width: fuelLabelWidth, height: fuelRowHeight),
                 text: "Fuel calculation", attributes: labelAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth, y: yPosition, width: fuelFlowWidth, height: fuelRowHeight),
                 text: "Fuel flow\nl/h", attributes: labelAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth, y: yPosition, width: fuelTimeHHWidth, height: fuelRowHeight),
                 text: "Time\nhh", attributes: labelAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth + fuelTimeHHWidth, y: yPosition, width: fuelTimeMMWidth, height: fuelRowHeight),
                 text: "mm", attributes: labelAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth + fuelTimeHHWidth + fuelTimeMMWidth, y: yPosition, width: fuelLitersWidth, height: fuelRowHeight),
                 text: "Fuel\nliters", attributes: labelAttributes, centered: true)

        // Timing header - Compteur START
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelWidth, height: fuelRowHeight),
                 text: "Compteur\nSTART", attributes: labelAttributes, centered: true)
        let counterStartStr = plan.counterStart.map { String(format: "%.1f", $0) } ?? ""
        drawCell(context, rect: CGRect(x: timingX + timingLabelWidth, y: yPosition, width: timingValueWidth, height: fuelRowHeight),
                 text: counterStartStr, attributes: dataAttributes, centered: true)
        yPosition += fuelRowHeight

        // Trip fuel row
        drawCell(context, rect: CGRect(x: tableX, y: yPosition, width: fuelLabelWidth, height: fuelRowHeight),
                 text: "Trip fuel", attributes: smallDataAttributes)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth, y: yPosition, width: fuelFlowWidth, height: fuelRowHeight),
                 text: String(format: "%.0f", fuelFlow), attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth, y: yPosition, width: fuelTimeHHWidth, height: fuelRowHeight),
                 text: "", attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth + fuelTimeHHWidth, y: yPosition, width: fuelTimeMMWidth, height: fuelRowHeight),
                 text: "", attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth + fuelTimeHHWidth + fuelTimeMMWidth, y: yPosition, width: fuelLitersWidth, height: fuelRowHeight),
                 text: String(format: "%.1f", tripFuel), attributes: smallDataAttributes, centered: true)
        // Block OFF
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelWidth, height: fuelRowHeight),
                 text: "Block\nOFF", attributes: labelAttributes, centered: true)
        let blockOffStr = plan.blockOff.map { timeFormatter.string(from: $0) } ?? ""
        drawCell(context, rect: CGRect(x: timingX + timingLabelWidth, y: yPosition, width: timingValueWidth, height: fuelRowHeight),
                 text: blockOffStr, attributes: dataAttributes, centered: true)
        yPosition += fuelRowHeight

        // Reserve fuel row
        drawCell(context, rect: CGRect(x: tableX, y: yPosition, width: fuelLabelWidth, height: fuelRowHeight),
                 text: "Reserve fuel (alt)", attributes: smallDataAttributes)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth, y: yPosition, width: fuelFlowWidth, height: fuelRowHeight),
                 text: "", attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth, y: yPosition, width: fuelTimeHHWidth, height: fuelRowHeight),
                 text: "", attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth + fuelTimeHHWidth, y: yPosition, width: fuelTimeMMWidth, height: fuelRowHeight),
                 text: "", attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth + fuelTimeHHWidth + fuelTimeMMWidth, y: yPosition, width: fuelLitersWidth, height: fuelRowHeight),
                 text: String(format: "%.1f", reserveFuel), attributes: smallDataAttributes, centered: true)
        // Time OFF
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelWidth, height: fuelRowHeight),
                 text: "Time\nOFF", attributes: labelAttributes, centered: true)
        let timeOffStr = plan.timeOff.map { timeFormatter.string(from: $0) } ?? ""
        drawCell(context, rect: CGRect(x: timingX + timingLabelWidth, y: yPosition, width: timingValueWidth, height: fuelRowHeight),
                 text: timeOffStr, attributes: dataAttributes, centered: true)
        yPosition += fuelRowHeight

        // Additional fuel row
        drawCell(context, rect: CGRect(x: tableX, y: yPosition, width: fuelLabelWidth, height: fuelRowHeight),
                 text: "Additional (45')", attributes: smallDataAttributes)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth, y: yPosition, width: fuelFlowWidth, height: fuelRowHeight),
                 text: "", attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth, y: yPosition, width: fuelTimeHHWidth, height: fuelRowHeight),
                 text: "0", attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth + fuelTimeHHWidth, y: yPosition, width: fuelTimeMMWidth, height: fuelRowHeight),
                 text: "45", attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth + fuelTimeHHWidth + fuelTimeMMWidth, y: yPosition, width: fuelLitersWidth, height: fuelRowHeight),
                 text: String(format: "%.1f", additionalFuel), attributes: smallDataAttributes, centered: true)
        // Time ON
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelWidth, height: fuelRowHeight),
                 text: "Time\nON", attributes: labelAttributes, centered: true)
        let timeOnStr = plan.timeOn.map { timeFormatter.string(from: $0) } ?? ""
        drawCell(context, rect: CGRect(x: timingX + timingLabelWidth, y: yPosition, width: timingValueWidth, height: fuelRowHeight),
                 text: timeOnStr, attributes: dataAttributes, centered: true)
        yPosition += fuelRowHeight

        // Extra fuel row
        drawCell(context, rect: CGRect(x: tableX, y: yPosition, width: fuelLabelWidth, height: fuelRowHeight),
                 text: "Extra fuel", attributes: smallDataAttributes)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth, y: yPosition, width: fuelFlowWidth, height: fuelRowHeight),
                 text: "", attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth, y: yPosition, width: fuelTimeHHWidth, height: fuelRowHeight),
                 text: "", attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth + fuelTimeHHWidth, y: yPosition, width: fuelTimeMMWidth, height: fuelRowHeight),
                 text: "", attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth + fuelTimeHHWidth + fuelTimeMMWidth, y: yPosition, width: fuelLitersWidth, height: fuelRowHeight),
                 text: String(format: "%.1f", extraFuel), attributes: smallDataAttributes, centered: true)
        // Block ON
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelWidth, height: fuelRowHeight),
                 text: "Block\nON", attributes: labelAttributes, centered: true)
        let blockOnStr = plan.blockOn.map { timeFormatter.string(from: $0) } ?? ""
        drawCell(context, rect: CGRect(x: timingX + timingLabelWidth, y: yPosition, width: timingValueWidth, height: fuelRowHeight),
                 text: blockOnStr, attributes: dataAttributes, centered: true)
        yPosition += fuelRowHeight

        // Fuel required row
        drawCell(context, rect: CGRect(x: tableX, y: yPosition, width: fuelLabelWidth, height: fuelRowHeight),
                 text: "Fuel required", attributes: smallDataAttributes)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth, y: yPosition, width: fuelFlowWidth, height: fuelRowHeight),
                 text: "", attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth, y: yPosition, width: fuelTimeHHWidth, height: fuelRowHeight),
                 text: "", attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth + fuelTimeHHWidth, y: yPosition, width: fuelTimeMMWidth, height: fuelRowHeight),
                 text: "", attributes: smallDataAttributes, centered: true)
        drawCell(context, rect: CGRect(x: tableX + fuelLabelWidth + fuelFlowWidth + fuelTimeHHWidth + fuelTimeMMWidth, y: yPosition, width: fuelLitersWidth, height: fuelRowHeight),
                 text: String(format: "%.1f", fuelRequired), attributes: smallDataAttributes, centered: true)
        // Compteur STOP
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelWidth, height: fuelRowHeight),
                 text: "Compteur\nSTOP", attributes: labelAttributes, centered: true)
        let counterStopStr = plan.counterStop.map { String(format: "%.1f", $0) } ?? ""
        drawCell(context, rect: CGRect(x: timingX + timingLabelWidth, y: yPosition, width: timingValueWidth, height: fuelRowHeight),
                 text: counterStopStr, attributes: dataAttributes, centered: true)
        yPosition += fuelRowHeight

        // Notes row with Atterrissages on the right
        let notesWidth = fuelSectionWidth
        drawCell(context, rect: CGRect(x: tableX, y: yPosition, width: 40, height: fuelRowHeight * 2),
                 text: "Notes", attributes: labelAttributes)
        drawCell(context, rect: CGRect(x: tableX + 40, y: yPosition, width: notesWidth - 40, height: fuelRowHeight * 2),
                 text: plan.remarks, attributes: smallDataAttributes)
        // Atterrissages
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelWidth, height: fuelRowHeight),
                 text: "Atterrissages", attributes: labelAttributes, centered: true)
        drawCell(context, rect: CGRect(x: timingX + timingLabelWidth, y: yPosition, width: timingValueWidth, height: fuelRowHeight),
                 text: "\(plan.landingsAtBase ?? 0) / \(plan.totalLandings ?? 0)", attributes: dataAttributes, centered: true)
        yPosition += fuelRowHeight

        // LSZQ / total label
        drawCell(context, rect: CGRect(x: timingX, y: yPosition, width: timingLabelWidth, height: fuelRowHeight),
                 text: "LSZQ / total", attributes: labelAttributes, centered: true)
        yPosition += fuelRowHeight

        // Debriefing section
        let debriefHeight: CGFloat = 50
        drawCell(context, rect: CGRect(x: tableX, y: yPosition, width: 60, height: debriefHeight),
                 text: "Debriefing", attributes: labelAttributes)
        drawCell(context, rect: CGRect(x: tableX + 60, y: yPosition, width: tableWidth - 60, height: debriefHeight),
                 text: plan.debriefing, attributes: smallDataAttributes)
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

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
