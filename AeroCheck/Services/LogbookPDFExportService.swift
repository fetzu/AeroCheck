import UIKit

// MARK: - Logbook PDF extract (v5.0.0)
//
// Renders recorded flights as logbook pages laid out like the AMC1 FCL.050 form.
//
// WHAT THIS IS NOT. It is not a logbook of record and the PDF says so on every page. In Switzerland
// the systems FOCA accepts are its own dLogbook and capzlog; an extract from an unaccredited app is
// not made acceptable by wearing the right layout. What this IS good for is transcribing into a real
// logbook without re-deriving every column, handing a club or an instructor a clean record of what
// was flown, and checking your own totals. Claiming more than that would be the same mistake the
// border pack exists to avoid: a confident-looking document that a pilot relies on and an auditor
// rejects.
//
// The FSTD SESSION columns of the form are deliberately absent. The app cannot record a simulator
// session, so they would be empty on every page while taking width from columns that carry data —
// and their absence is stated on the page rather than left for the reader to notice.
//
// Column HEADINGS stay in English even in the French build. They are the prescribed form's own
// wording, in the same class as the ICAO abbreviations this project already leaves untranslated; a
// helpfully-translated logbook column is a column an auditor cannot match to the regulation.

enum LogbookPDFExportService {

    struct Options: Sendable {
        /// Printed in the header, and used as the PIC name where a flight has none.
        var pilotName: String?
        /// Rows before a page break. The form is a page of lines with totals under it, so this is
        /// what makes the arithmetic per-page rather than one long list.
        var rowsPerPage: Int = 15
        /// Whose logbook this is. A student's lines are Dual with the instructor as PIC, and the
        /// page totals have to agree with them. (v5.x)
        var pilot: LogbookLineBuilder.PilotContext = .unknown

        init(pilotName: String? = nil,
             rowsPerPage: Int = 15,
             pilot: LogbookLineBuilder.PilotContext = .unknown) {
            self.pilotName = pilotName
            self.rowsPerPage = max(1, rowsPerPage)
            self.pilot = LogbookLineBuilder.PilotContext(name: pilot.name ?? pilotName,
                                                         isStudent: pilot.isStudent,
                                                         instructorName: pilot.instructorName)
        }
    }

    /// Landscape A4. The form has twelve column groups; portrait would crush them to illegibility.
    static let pageBounds = CGRect(x: 0, y: 0, width: 842, height: 595)

    /// Flights in, PDF out. Returns nil for an empty selection rather than a blank page — an empty
    /// logbook extract is a file someone would send by mistake.
    static func export(flights: [Flight], options: Options = Options()) -> Data? {
        guard !flights.isEmpty else { return nil }

        // A logbook reads oldest first, and the brought-forward totals are meaningless in any other
        // order. Callers hand us newest-first lists (that is how the flight log is sorted), so this
        // sorts rather than trusting.
        let ordered = flights.sorted { chronology(of: $0) < chronology(of: $1) }
        let pages = stride(from: 0, to: ordered.count, by: options.rowsPerPage).map {
            Array(ordered[$0..<min($0 + options.rowsPerPage, ordered.count)])
        }

        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        return renderer.pdfData { context in
            var broughtForward = LogbookTotals.zero
            for (index, pageFlights) in pages.enumerated() {
                context.beginPage()
                let pageTotals = LogbookTotals.forFlights(pageFlights, pilot: options.pilot)
                draw(pageFlights,
                     pageTotals: pageTotals,
                     broughtForward: broughtForward,
                     pageNumber: index + 1,
                     pageCount: pages.count,
                     options: options,
                     in: context.cgContext)
                broughtForward = broughtForward + pageTotals
            }
        }
    }

    /// The date a flight sorts by. Block off is the logbook's own answer; engine start and the GPS
    /// start are fallbacks for a flight recorded without block times. A flight with none of the three
    /// sorts to the front rather than crashing — it has no duration to contribute anyway.
    static func chronology(of flight: Flight) -> Date {
        flight.blockOffTime ?? flight.engineStartTime ?? flight.startTime ?? .distantPast
    }

    // MARK: - Columns
    //
    // Widths are WEIGHTS, normalised to the usable width, so the table always fills the page exactly
    // and a margin change cannot leave a gap or overflow the last column.

    private struct Column {
        let title: String
        let subtitles: [String]
        let weight: CGFloat
    }

    /// Relative widths, in `LogbookFormRow.layout` order.
    ///
    /// DATE carries dd.mm.yyyy, which needs more room than the heading suggests — at 46 it truncated
    /// to "01.09.20…", and a logbook date missing its year is worse than useless.
    private static let columnWeights: [CGFloat] = [58, 68, 68, 108, 60, 34, 40, 74, 50, 62, 124, 92]

    /// Headings come from `LogbookFormRow.layout`, which the on-screen row also renders — the printout
    /// and the screen describe the same form, so they cannot drift apart. Only the widths live here.
    private static let columns: [Column] = LogbookFormRow.layout.enumerated().map { index, entry in
        Column(title: entry.title,
               subtitles: entry.subtitles,
               weight: index < columnWeights.count ? columnWeights[index] : 60)
    }

    // MARK: - Drawing

    private static func draw(
        _ flights: [Flight],
        pageTotals: LogbookTotals,
        broughtForward: LogbookTotals,
        pageNumber: Int,
        pageCount: Int,
        options: Options,
        in ctx: CGContext
    ) {
        let margin: CGFloat = 22
        let tableX = margin
        let tableWidth = pageBounds.width - 2 * margin

        let ink = UIColor(white: 0.11, alpha: 1)
        let labelInk = UIColor(white: 0.34, alpha: 1)
        let grid = UIColor(white: 0.62, alpha: 1)
        let gridLight = UIColor(white: 0.84, alpha: 1)
        let shHeader = UIColor(white: 0.90, alpha: 1)
        let shTotal = UIColor(white: 0.94, alpha: 1)

        let fTitle = UIFont.boldSystemFont(ofSize: 11)
        let fMeta = UIFont.systemFont(ofSize: 7.5)
        let fColTitle = UIFont.systemFont(ofSize: 5.6, weight: .semibold)
        let fColSub = UIFont.systemFont(ofSize: 5.2)
        let fCell = UIFont.systemFont(ofSize: 7)
        let fCellBold = UIFont.systemFont(ofSize: 7, weight: .semibold)
        let fFoot = UIFont.systemFont(ofSize: 6)

        var y = margin

        // --- Title block ---
        drawText("PILOT LOGBOOK", at: CGRect(x: tableX, y: y, width: 300, height: 14),
                 font: fTitle, color: ink)
        drawText(L10n.Logbook.pdfPage(pageNumber, pageCount),
                 at: CGRect(x: tableX + tableWidth - 200, y: y + 2, width: 200, height: 12),
                 font: fMeta, color: labelInk, align: .right)
        y += 15

        let holder = options.pilotName?.trimmingCharacters(in: .whitespaces)
        if let holder, !holder.isEmpty {
            drawText(L10n.Logbook.pdfHolder(holder),
                     at: CGRect(x: tableX, y: y, width: 400, height: 11), font: fMeta, color: labelInk)
        }
        drawText(L10n.Logbook.pdfLayoutNote,
                 at: CGRect(x: tableX + tableWidth - 420, y: y, width: 420, height: 11),
                 font: fMeta, color: labelInk, align: .right)
        y += 15

        // --- Column geometry ---
        let totalWeight = columns.reduce(0) { $0 + $1.weight }
        var xs: [CGFloat] = [tableX]
        for column in columns {
            xs.append(xs[xs.count - 1] + tableWidth * column.weight / totalWeight)
        }

        // --- Header (two tiers: the group, then its sub-columns) ---
        let headerTop = y
        // Tall enough for two wrapped lines at `fColTitle`. At 13 the second line was clipped, so
        // "OPERATIONAL CONDITION TIME" read as "OPERATIONAL" and "REMARKS AND ENDORSEMENTS" as
        // "REMARKS AND" — a column heading that lies about which column it is.
        let titleHeight: CGFloat = 18
        let subHeight: CGFloat = 10
        let headerHeight = titleHeight + subHeight

        ctx.setFillColor(shHeader.cgColor)
        ctx.fill(CGRect(x: tableX, y: headerTop, width: tableWidth, height: headerHeight))

        for (index, column) in columns.enumerated() {
            let left = xs[index]
            let width = xs[index + 1] - left
            drawText(column.title,
                     at: CGRect(x: left + 1, y: headerTop + 3, width: width - 2, height: titleHeight),
                     font: fColTitle, color: ink, align: .center, lines: 2)

            let subs = column.subtitles.filter { !$0.isEmpty }
            if subs.count > 1 {
                let subWidth = width / CGFloat(subs.count)
                for (subIndex, sub) in subs.enumerated() {
                    let subLeft = left + CGFloat(subIndex) * subWidth
                    drawText(sub,
                             at: CGRect(x: subLeft, y: headerTop + titleHeight + 2,
                                        width: subWidth, height: subHeight),
                             font: fColSub, color: labelInk, align: .center)
                    if subIndex > 0 {
                        stroke(ctx, from: CGPoint(x: subLeft, y: headerTop + titleHeight),
                               to: CGPoint(x: subLeft, y: headerTop + headerHeight), color: gridLight)
                    }
                }
            } else if let only = subs.first {
                drawText(only,
                         at: CGRect(x: left, y: headerTop + titleHeight + 2, width: width, height: subHeight),
                         font: fColSub, color: labelInk, align: .center)
            }
        }
        y = headerTop + headerHeight

        // --- Rows ---
        let rowHeight: CGFloat = 19
        for slot in 0..<options.rowsPerPage {
            let rowTop = y + CGFloat(slot) * rowHeight
            if slot < flights.count {
                drawRow(flights[slot], xs: xs, top: rowTop, height: rowHeight,
                        font: fCell, ink: ink, grid: gridLight, options: options, ctx: ctx)
            }
            stroke(ctx, from: CGPoint(x: tableX, y: rowTop + rowHeight),
                   to: CGPoint(x: tableX + tableWidth, y: rowTop + rowHeight), color: gridLight)
        }
        y += CGFloat(options.rowsPerPage) * rowHeight

        // --- Totals: this page, brought forward, and the running total ---
        let totalRows: [(String, LogbookTotals)] = [
            ("TOTAL THIS PAGE", pageTotals),
            ("TOTAL FROM PREVIOUS PAGES", broughtForward),
            ("TOTAL TIME", pageTotals + broughtForward),
        ]
        let totalRowHeight: CGFloat = 15
        let totalsTop = y
        for (label, totals) in totalRows {
            ctx.setFillColor(shTotal.cgColor)
            ctx.fill(CGRect(x: tableX, y: y, width: tableWidth, height: totalRowHeight))
            drawText(label, at: CGRect(x: xs[0] + 2, y: y + 3.5, width: xs[4] - xs[0] - 4, height: 10),
                     font: fCellBold, color: ink)
            drawTotals(totals, xs: xs, top: y, height: totalRowHeight,
                       font: fCellBold, ink: ink, grid: gridLight, ctx: ctx)
            stroke(ctx, from: CGPoint(x: tableX, y: y + totalRowHeight),
                   to: CGPoint(x: tableX + tableWidth, y: y + totalRowHeight), color: grid)
            y += totalRowHeight
        }

        // --- Outer frame and column rules, drawn last so nothing paints over them ---
        ctx.setStrokeColor(grid.cgColor)
        ctx.setLineWidth(0.7)
        ctx.stroke(CGRect(x: tableX, y: headerTop, width: tableWidth, height: y - headerTop))
        for (index, x) in xs.enumerated() where index > 0 && index < xs.count - 1 {
            // The three rules inside the totals label span stop above it. "TOTAL FROM PREVIOUS
            // PAGES" reads across those columns, and ruling through it struck the words out.
            let bottom = index < 4 ? totalsTop : y
            stroke(ctx, from: CGPoint(x: x, y: headerTop), to: CGPoint(x: x, y: bottom), color: grid)
        }
        stroke(ctx, from: CGPoint(x: tableX, y: headerTop + headerHeight),
               to: CGPoint(x: tableX + tableWidth, y: headerTop + headerHeight), color: grid)

        // --- Certification and signature ---
        y += 14
        drawText("I certify that the entries in this log are true.",
                 at: CGRect(x: tableX, y: y, width: 260, height: 11), font: fMeta, color: ink)
        let sigX = tableX + tableWidth - 240
        stroke(ctx, from: CGPoint(x: sigX, y: y + 12), to: CGPoint(x: sigX + 240, y: y + 12), color: grid)
        drawText("PILOT'S SIGNATURE", at: CGRect(x: sigX, y: y + 13, width: 240, height: 10),
                 font: fColSub, color: labelInk)

        // --- The disclaimer. Deliberately on every page, not just the first: pages get separated. ---
        drawText(L10n.Logbook.pdfDisclaimer,
                 at: CGRect(x: tableX, y: pageBounds.height - margin - 14, width: tableWidth, height: 14),
                 font: fFoot, color: labelInk, lines: 2)
    }

    private static func drawRow(
        _ flight: Flight,
        xs: [CGFloat],
        top: CGFloat,
        height: CGFloat,
        font: UIFont,
        ink: UIColor,
        grid: UIColor,
        options: Options,
        ctx: CGContext
    ) {
        let line = LogbookLineBuilder.build(flight: flight,
                                            overrides: flight.logbook,
                                            defaultPilotName: options.pilotName,
                                            pilot: options.pilot)
        let totals = LogbookTotals.forFlight(flight, pilot: options.pilot)
        let y = top + (height - font.lineHeight) / 2

        func cell(_ index: Int, _ text: String, align: NSTextAlignment = .center) {
            guard !text.isEmpty else { return }
            drawText(text, at: CGRect(x: xs[index] + 2, y: y, width: xs[index + 1] - xs[index] - 4,
                                      height: font.lineHeight),
                     font: font, color: ink, align: align)
        }
        func split(_ index: Int, _ values: [String], align: NSTextAlignment = .center) {
            let left = xs[index]
            let width = (xs[index + 1] - left) / CGFloat(values.count)
            for (offset, value) in values.enumerated() where !value.isEmpty {
                drawText(value,
                         at: CGRect(x: left + CGFloat(offset) * width + 1, y: y,
                                    width: width - 2, height: font.lineHeight),
                         font: font, color: ink, align: align)
            }
            for offset in 1..<values.count {
                stroke(ctx, from: CGPoint(x: left + CGFloat(offset) * width, y: top),
                       to: CGPoint(x: left + CGFloat(offset) * width, y: top + height), color: grid)
            }
        }

        cell(0, line.date)
        split(1, [line.departurePlace, line.departureTimeUTC])
        split(2, [line.arrivalPlace, line.arrivalTimeUTC])
        split(3, [line.aircraftModel, line.aircraftRegistration])
        split(4, [line.singlePilotTime, ""])                     // ME stays blank: no twin in the fleet
        cell(5, "")                                              // multi-pilot: likewise
        cell(6, line.totalTime)
        cell(7, line.picName, align: .left)
        split(8, [line.landingsDay > 0 ? String(line.landingsDay) : "",
                  line.landingsNight > 0 ? String(line.landingsNight) : ""])
        split(9, [line.nightTime, line.ifrTime])
        split(10, [minutes(totals.picMinutes), minutes(totals.coPilotMinutes),
                   minutes(totals.dualMinutes), minutes(totals.instructorMinutes)])
        cell(11, line.remarks, align: .left)
    }

    private static func drawTotals(
        _ totals: LogbookTotals,
        xs: [CGFloat],
        top: CGFloat,
        height: CGFloat,
        font: UIFont,
        ink: UIColor,
        grid: UIColor,
        ctx: CGContext
    ) {
        let y = top + (height - font.lineHeight) / 2

        func split(_ index: Int, _ values: [String]) {
            let left = xs[index]
            let width = (xs[index + 1] - left) / CGFloat(values.count)
            for (offset, value) in values.enumerated() where !value.isEmpty {
                drawText(value,
                         at: CGRect(x: left + CGFloat(offset) * width + 1, y: y,
                                    width: width - 2, height: font.lineHeight),
                         font: font, color: ink, align: .center)
            }
        }
        func cell(_ index: Int, _ text: String) {
            guard !text.isEmpty else { return }
            drawText(text, at: CGRect(x: xs[index] + 2, y: y, width: xs[index + 1] - xs[index] - 4,
                                      height: font.lineHeight),
                     font: font, color: ink, align: .center)
        }

        split(4, [minutes(totals.singlePilotSEMinutes), ""])
        cell(5, minutes(totals.multiPilotMinutes))
        cell(6, minutes(totals.totalMinutes))
        split(8, [totals.landingsDay > 0 ? String(totals.landingsDay) : "",
                  totals.landingsNight > 0 ? String(totals.landingsNight) : ""])
        split(9, [minutes(totals.nightMinutes), minutes(totals.ifrMinutes)])
        split(10, [minutes(totals.picMinutes), minutes(totals.coPilotMinutes),
                   minutes(totals.dualMinutes), minutes(totals.instructorMinutes)])
    }

    // MARK: - Primitives

    private static func minutes(_ value: Int) -> String {
        LogbookLineBuilder.formatMinutes(value)
    }

    private static func stroke(_ ctx: CGContext, from: CGPoint, to: CGPoint, color: UIColor) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(0.4)
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()
    }

    private static func drawText(
        _ text: String,
        at rect: CGRect,
        font: UIFont,
        color: UIColor,
        align: NSTextAlignment = .left,
        lines: Int = 1
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }
}
