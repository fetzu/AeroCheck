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
    /// Creates a simple XML-based Excel file
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

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <?mso-application progid="Excel.Sheet"?>
        <Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"
         xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">
        <Styles>
            <Style ss:ID="Header">
                <Font ss:Bold="1" ss:Size="12"/>
                <Interior ss:Color="#FFD700" ss:Pattern="Solid"/>
                <Borders>
                    <Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1"/>
                </Borders>
            </Style>
            <Style ss:ID="Title">
                <Font ss:Bold="1" ss:Size="14"/>
            </Style>
            <Style ss:ID="Label">
                <Font ss:Bold="1"/>
            </Style>
            <Style ss:ID="Data">
                <Alignment ss:Horizontal="Center"/>
            </Style>
        </Styles>
        <Worksheet ss:Name="Plan de Vol">
        <Table>
        """

        // Title
        xml += """
        <Row>
            <Cell ss:StyleID="Title"><Data ss:Type="String">AVIS DE VOL - PLAN DE VOL DE NAVIGATION</Data></Cell>
        </Row>
        <Row></Row>
        """

        // Header info - Row 1
        xml += """
        <Row>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Pilote</Data></Cell>
            <Cell><Data ss:Type="String">\(escapeXML(plan.pilot))</Data></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Avion</Data></Cell>
            <Cell><Data ss:Type="String">\(escapeXML(plan.aircraftRegistration))</Data></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Date</Data></Cell>
            <Cell><Data ss:Type="String">\(dateStr)</Data></Cell>
        </Row>
        """

        // Header info - Row 2
        xml += """
        <Row>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Durée totale EET</Data></Cell>
            <Cell><Data ss:Type="String">\(plan.formattedTotalEET)</Data></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Autonomie</Data></Cell>
            <Cell><Data ss:Type="String">\(plan.formattedEndurance ?? "--:--")</Data></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Piste en service</Data></Cell>
            <Cell><Data ss:Type="String">\(escapeXML(plan.runwayInUse ?? ""))</Data></Cell>
        </Row>
        """

        // Header info - Row 3
        xml += """
        <Row>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Instructeur</Data></Cell>
            <Cell><Data ss:Type="String">\(escapeXML(plan.instructor ?? ""))</Data></Cell>
        </Row>
        <Row></Row>
        """

        // Route table header
        xml += """
        <Row>
            <Cell ss:StyleID="Header"><Data ss:Type="String">Freq</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">C/S</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">Waypoint</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">MC</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">Dist.</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">Alt</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">Wind</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">GS</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">EET</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">ETO</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">ATO</Data></Cell>
            <Cell ss:StyleID="Header"><Data ss:Type="String">Remarks</Data></Cell>
        </Row>
        """

        // Route waypoints
        for waypoint in plan.waypoints {
            let mc = waypoint.magneticCourse.map { String(format: "%03d°", Int($0)) } ?? ""
            let dist = waypoint.distance.map { String(format: "%.1f", $0) } ?? ""
            let alt = waypoint.altitude.map { String(format: "%.0f", $0) } ?? ""
            let wind = ""
            let gs = waypoint.plannedGroundSpeed.map { "\($0)" } ?? ""
            let eet = waypoint.formattedEET ?? ""
            let eto = waypoint.formattedETO ?? ""
            let ato = waypoint.formattedATO ?? ""

            xml += """
            <Row>
                <Cell ss:StyleID="Data"><Data ss:Type="String">\(escapeXML(waypoint.frequency ?? ""))</Data></Cell>
                <Cell ss:StyleID="Data"><Data ss:Type="String">\(escapeXML(waypoint.callSign ?? ""))</Data></Cell>
                <Cell><Data ss:Type="String">\(escapeXML(waypoint.name))</Data></Cell>
                <Cell ss:StyleID="Data"><Data ss:Type="String">\(mc)</Data></Cell>
                <Cell ss:StyleID="Data"><Data ss:Type="String">\(dist)</Data></Cell>
                <Cell ss:StyleID="Data"><Data ss:Type="String">\(alt)</Data></Cell>
                <Cell ss:StyleID="Data"><Data ss:Type="String">\(wind)</Data></Cell>
                <Cell ss:StyleID="Data"><Data ss:Type="String">\(gs)</Data></Cell>
                <Cell ss:StyleID="Data"><Data ss:Type="String">\(eet)</Data></Cell>
                <Cell ss:StyleID="Data"><Data ss:Type="String">\(eto)</Data></Cell>
                <Cell ss:StyleID="Data"><Data ss:Type="String">\(ato)</Data></Cell>
                <Cell><Data ss:Type="String">\(escapeXML(waypoint.remarks))</Data></Cell>
            </Row>
            """
        }

        // Add empty rows for remaining space
        for _ in plan.waypoints.count..<15 {
            xml += "<Row><Cell></Cell></Row>\n"
        }

        xml += "<Row></Row>\n"

        // Fuel calculation section
        let fuelFlow = plan.fuelFlow ?? FlightPlan.defaultFuelFlow(for: plan.aircraftType)
        let tripFuel = plan.tripFuel ?? 0
        let reserveFuel = plan.reserveFuel ?? 0
        let additionalFuel = plan.additionalFuel ?? (fuelFlow * 0.75)
        let extraFuel = plan.extraFuel ?? 0
        let fuelRequired = tripFuel + reserveFuel + additionalFuel + extraFuel

        xml += """
        <Row>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Fuel calculation</Data></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Fuel flow l/h</Data></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Time hh</Data></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">mm</Data></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Fuel liters</Data></Cell>
            <Cell></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Compteur START</Data></Cell>
            <Cell><Data ss:Type="String">\(plan.counterStart.map { String(format: "%.1f", $0) } ?? "")</Data></Cell>
        </Row>
        <Row>
            <Cell><Data ss:Type="String">Trip fuel</Data></Cell>
            <Cell><Data ss:Type="Number">\(fuelFlow)</Data></Cell>
            <Cell></Cell>
            <Cell></Cell>
            <Cell><Data ss:Type="Number">\(String(format: "%.1f", tripFuel))</Data></Cell>
            <Cell></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Block OFF</Data></Cell>
            <Cell><Data ss:Type="String">\(plan.blockOff.map { timeFormatter.string(from: $0) } ?? "")</Data></Cell>
        </Row>
        <Row>
            <Cell><Data ss:Type="String">Reserve fuel (alt)</Data></Cell>
            <Cell></Cell>
            <Cell></Cell>
            <Cell></Cell>
            <Cell><Data ss:Type="Number">\(String(format: "%.1f", reserveFuel))</Data></Cell>
            <Cell></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Time OFF</Data></Cell>
            <Cell><Data ss:Type="String">\(plan.timeOff.map { timeFormatter.string(from: $0) } ?? "")</Data></Cell>
        </Row>
        <Row>
            <Cell><Data ss:Type="String">Additional (45')</Data></Cell>
            <Cell></Cell>
            <Cell><Data ss:Type="String">0</Data></Cell>
            <Cell><Data ss:Type="String">45</Data></Cell>
            <Cell><Data ss:Type="Number">\(String(format: "%.1f", additionalFuel))</Data></Cell>
            <Cell></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Time ON</Data></Cell>
            <Cell><Data ss:Type="String">\(plan.timeOn.map { timeFormatter.string(from: $0) } ?? "")</Data></Cell>
        </Row>
        <Row>
            <Cell><Data ss:Type="String">Extra fuel</Data></Cell>
            <Cell></Cell>
            <Cell></Cell>
            <Cell></Cell>
            <Cell><Data ss:Type="Number">\(String(format: "%.1f", extraFuel))</Data></Cell>
            <Cell></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Block ON</Data></Cell>
            <Cell><Data ss:Type="String">\(plan.blockOn.map { timeFormatter.string(from: $0) } ?? "")</Data></Cell>
        </Row>
        <Row>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Fuel required</Data></Cell>
            <Cell></Cell>
            <Cell></Cell>
            <Cell></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="Number">\(String(format: "%.1f", fuelRequired))</Data></Cell>
            <Cell></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Compteur STOP</Data></Cell>
            <Cell><Data ss:Type="String">\(plan.counterStop.map { String(format: "%.1f", $0) } ?? "")</Data></Cell>
        </Row>
        <Row></Row>
        <Row>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Notes</Data></Cell>
            <Cell ss:MergeAcross="5"><Data ss:Type="String">\(escapeXML(plan.remarks))</Data></Cell>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Atterrissages LSZQ/total</Data></Cell>
            <Cell><Data ss:Type="String">\(plan.landingsAtBase ?? 0) / \(plan.totalLandings ?? 0)</Data></Cell>
        </Row>
        <Row></Row>
        <Row>
            <Cell ss:StyleID="Label"><Data ss:Type="String">Debriefing</Data></Cell>
            <Cell ss:MergeAcross="7"><Data ss:Type="String">\(escapeXML(plan.debriefing))</Data></Cell>
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

    /// Export flight plan to PDF format
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
        let margin: CGFloat = 30
        var yPosition: CGFloat = margin

        let titleFont = UIFont.boldSystemFont(ofSize: 14)
        let headerFont = UIFont.boldSystemFont(ofSize: 10)
        let bodyFont = UIFont.systemFont(ofSize: 9)
        let smallFont = UIFont.systemFont(ofSize: 8)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd.MM.yyyy"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        // Title
        let title = "AVIS DE VOL - PLAN DE VOL DE NAVIGATION"
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: UIColor.black
        ]
        title.draw(at: CGPoint(x: margin, y: yPosition), withAttributes: titleAttributes)
        yPosition += 25

        // Header section
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: UIColor.black
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: UIColor.black
        ]

        // Row 1: Pilote, Avion, Date
        let dateStr = plan.plannedDepartureTime.map { dateFormatter.string(from: $0) } ?? ""
        drawLabelValue("Pilote:", plan.pilot, at: CGPoint(x: margin, y: yPosition), labelFont: headerFont, valueFont: bodyFont)
        drawLabelValue("Avion:", plan.aircraftRegistration, at: CGPoint(x: 200, y: yPosition), labelFont: headerFont, valueFont: bodyFont)
        drawLabelValue("Date:", dateStr, at: CGPoint(x: 400, y: yPosition), labelFont: headerFont, valueFont: bodyFont)
        yPosition += 15

        // Row 2: EET, Autonomie, Piste
        drawLabelValue("Durée totale EET:", plan.formattedTotalEET, at: CGPoint(x: margin, y: yPosition), labelFont: headerFont, valueFont: bodyFont)
        drawLabelValue("Autonomie:", plan.formattedEndurance ?? "--:--", at: CGPoint(x: 200, y: yPosition), labelFont: headerFont, valueFont: bodyFont)
        drawLabelValue("Piste en service:", plan.runwayInUse ?? "", at: CGPoint(x: 400, y: yPosition), labelFont: headerFont, valueFont: bodyFont)
        yPosition += 15

        // Row 3: Instructeur
        drawLabelValue("Instructeur:", plan.instructor ?? "", at: CGPoint(x: margin, y: yPosition), labelFont: headerFont, valueFont: bodyFont)
        yPosition += 25

        // Route table
        let tableX = margin
        let tableWidth = rect.width - 2 * margin
        let columnWidths: [CGFloat] = [45, 35, 70, 35, 35, 40, 40, 30, 35, 40, 40, 90] // Freq, C/S, Waypoint, MC, Dist, Alt, Wind, GS, EET, ETO, ATO, Remarks
        let rowHeight: CGFloat = 18

        // Table header
        UIColor(white: 0.9, alpha: 1).setFill()
        context.fill(CGRect(x: tableX, y: yPosition, width: tableWidth, height: rowHeight))

        let headers = ["Freq", "C/S", "Waypoint", "MC", "Dist.", "Alt", "Wind", "GS", "EET", "ETO", "ATO", "Remarks"]
        var xPos = tableX
        for (index, header) in headers.enumerated() {
            header.draw(at: CGPoint(x: xPos + 2, y: yPosition + 3), withAttributes: [.font: smallFont, .foregroundColor: UIColor.black])
            xPos += columnWidths[index]
        }
        yPosition += rowHeight

        // Draw table borders
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(0.5)

        // Table rows
        let maxRows = min(plan.waypoints.count, 15)
        for i in 0..<maxRows {
            let waypoint = plan.waypoints[i]
            xPos = tableX

            let values = [
                waypoint.frequency ?? "",
                waypoint.callSign ?? "",
                waypoint.name,
                waypoint.magneticCourse.map { String(format: "%03d°", Int($0)) } ?? "",
                waypoint.distance.map { String(format: "%.1f", $0) } ?? "",
                waypoint.altitude.map { String(format: "%.0f", $0) } ?? "",
                "", // Wind
                waypoint.plannedGroundSpeed.map { "\($0)" } ?? "",
                waypoint.formattedEET ?? "",
                waypoint.formattedETO ?? "",
                waypoint.formattedATO ?? "",
                waypoint.remarks
            ]

            for (index, value) in values.enumerated() {
                let truncatedValue = String(value.prefix(Int(columnWidths[index] / 5)))
                truncatedValue.draw(at: CGPoint(x: xPos + 2, y: yPosition + 3), withAttributes: [.font: smallFont, .foregroundColor: UIColor.black])
                xPos += columnWidths[index]
            }

            // Row border
            context.stroke(CGRect(x: tableX, y: yPosition, width: tableWidth, height: rowHeight))
            yPosition += rowHeight
        }

        // Empty rows
        for _ in maxRows..<15 {
            context.stroke(CGRect(x: tableX, y: yPosition, width: tableWidth, height: rowHeight))
            yPosition += rowHeight
        }

        yPosition += 15

        // Fuel calculation section
        let fuelFlow = plan.fuelFlow ?? FlightPlan.defaultFuelFlow(for: plan.aircraftType)
        let tripFuel = plan.tripFuel ?? 0
        let reserveFuel = plan.reserveFuel ?? 0
        let additionalFuel = plan.additionalFuel ?? (fuelFlow * 0.75)
        let extraFuel = plan.extraFuel ?? 0
        let fuelRequired = tripFuel + reserveFuel + additionalFuel + extraFuel

        "Fuel calculation".draw(at: CGPoint(x: margin, y: yPosition), withAttributes: headerAttributes)
        yPosition += 15

        // Fuel rows
        let fuelData = [
            ("Trip fuel", String(format: "%.1f", tripFuel)),
            ("Reserve fuel (alt)", String(format: "%.1f", reserveFuel)),
            ("Additional (45')", String(format: "%.1f", additionalFuel)),
            ("Extra fuel", String(format: "%.1f", extraFuel)),
            ("Fuel required", String(format: "%.1f", fuelRequired))
        ]

        for (label, value) in fuelData {
            drawLabelValue(label, value + " L", at: CGPoint(x: margin, y: yPosition), labelFont: bodyFont, valueFont: bodyFont)
            yPosition += 12
        }

        // Timing section on the right
        let timingX: CGFloat = 350
        var timingY = yPosition - 60

        "Timing".draw(at: CGPoint(x: timingX, y: timingY), withAttributes: headerAttributes)
        timingY += 15

        let timingData = [
            ("Compteur START", plan.counterStart.map { String(format: "%.1f", $0) } ?? ""),
            ("Block OFF", plan.blockOff.map { timeFormatter.string(from: $0) } ?? ""),
            ("Time OFF", plan.timeOff.map { timeFormatter.string(from: $0) } ?? ""),
            ("Time ON", plan.timeOn.map { timeFormatter.string(from: $0) } ?? ""),
            ("Block ON", plan.blockOn.map { timeFormatter.string(from: $0) } ?? ""),
            ("Compteur STOP", plan.counterStop.map { String(format: "%.1f", $0) } ?? "")
        ]

        for (label, value) in timingData {
            drawLabelValue(label, value, at: CGPoint(x: timingX, y: timingY), labelFont: bodyFont, valueFont: bodyFont)
            timingY += 12
        }

        // Landings
        drawLabelValue("Atterrissages LSZQ/total:", "\(plan.landingsAtBase ?? 0) / \(plan.totalLandings ?? 0)", at: CGPoint(x: timingX, y: timingY + 5), labelFont: bodyFont, valueFont: bodyFont)

        yPosition += 20

        // Notes
        "Notes:".draw(at: CGPoint(x: margin, y: yPosition), withAttributes: headerAttributes)
        yPosition += 12

        let notesRect = CGRect(x: margin, y: yPosition, width: rect.width - 2 * margin, height: 50)
        context.stroke(notesRect)
        plan.remarks.draw(in: notesRect.insetBy(dx: 5, dy: 3), withAttributes: [.font: smallFont, .foregroundColor: UIColor.black])
        yPosition += 55

        // Debriefing
        "Debriefing:".draw(at: CGPoint(x: margin, y: yPosition), withAttributes: headerAttributes)
        yPosition += 12

        let debriefRect = CGRect(x: margin, y: yPosition, width: rect.width - 2 * margin, height: 50)
        context.stroke(debriefRect)
        plan.debriefing.draw(in: debriefRect.insetBy(dx: 5, dy: 3), withAttributes: [.font: smallFont, .foregroundColor: UIColor.black])
    }

    private static func drawLabelValue(_ label: String, _ value: String, at point: CGPoint, labelFont: UIFont, valueFont: UIFont) {
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: UIColor.black]
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: UIColor.darkGray]

        label.draw(at: point, withAttributes: labelAttributes)
        let labelSize = (label as NSString).size(withAttributes: labelAttributes)
        value.draw(at: CGPoint(x: point.x + labelSize.width + 5, y: point.y), withAttributes: valueAttributes)
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
