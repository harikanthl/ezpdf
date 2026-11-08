import Foundation

/// Ready-made documents: pick one, get a clean Letter PDF whose blanks are real form fields
/// (fill them in the reader, by asking the assistant, or with fill_form).
/// Written for ezpdf; no third-party template text. Legal-style templates carry a notice.
public struct DocTemplate: Identifiable, Sendable {
    public enum FieldType: String, Sendable { case text, date, multiline, money, checkbox, number }

    public struct Field: Sendable {
        public var label: String
        public var name: String
        public var type: FieldType
        public var wide: Bool
        public init(_ label: String, _ type: FieldType = .text, wide: Bool = false, name: String? = nil) {
            self.label = label; self.type = type; self.wide = wide
            self.name = name ?? DocTemplate.slug(label)
        }
    }

    public enum Block: Sendable {
        case title(String, String?)
        case party(String, prefix: String)                   // name, address, email, phone block
        case fields([Field])
        case heading(String)
        case text(String)                                    // {{Label}} becomes an inline blank
        case table(columns: [String], rows: Int, prefix: String)
        case totals([String])
        case checklist([String], prefix: String)
        case signatures([String])
        case notice(String)
    }

    public let id: String
    public let name: String
    public let category: String
    public let symbol: String
    public let summary: String
    public let blocks: [Block]

    static func slug(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}

extension DocTemplate {
    typealias F = Field
    static let legal = "Template only, not legal advice. Laws differ by place; have a lawyer review important agreements."

    public static let all: [DocTemplate] = [
        DocTemplate(id: "invoice", name: "Invoice", category: "Business", symbol: "doc.text", summary: "Bill a client for work or goods.", blocks: [
            .title("Invoice", nil), .party("From", prefix: "from"), .party("Bill to", prefix: "bill_to"),
            .fields([F("Invoice number"), F("Invoice date", .date), F("Due date", .date), F("PO number")]),
            .table(columns: ["Description", "Qty", "Unit price", "Amount"], rows: 6, prefix: "item"),
            .totals(["Subtotal", "Tax", "Discount", "Total due"]),
            .fields([F("Payment terms", wide: true), F("Payment details", .multiline, wide: true), F("Notes", .multiline, wide: true)]),
        ]),
        DocTemplate(id: "receipt", name: "Receipt", category: "Business", symbol: "scroll", summary: "Confirm a payment you received.", blocks: [
            .title("Receipt", nil), .party("Received by", prefix: "seller"),
            .fields([F("Receipt number"), F("Date", .date), F("Received from", wide: true), F("Payment method")]),
            .table(columns: ["Description", "Qty", "Unit price", "Amount"], rows: 6, prefix: "item"),
            .totals(["Subtotal", "Tax", "Total paid"]),
            .signatures(["Received by"]),
        ]),
        DocTemplate(id: "quote", name: "Quote / Estimate", category: "Business", symbol: "text.badge.checkmark", summary: "Price a job before it starts.", blocks: [
            .title("Quote", nil), .party("From", prefix: "from"),
            .fields([F("Quote number"), F("Date", .date), F("Valid until", .date), F("Prepared for", wide: true)]),
            .table(columns: ["Description", "Qty", "Unit price", "Amount"], rows: 6, prefix: "item"),
            .totals(["Subtotal", "Tax", "Estimated total"]),
            .fields([F("Scope and assumptions", .multiline, wide: true)]),
            .signatures(["Accepted by (client)", "Prepared by"]),
        ]),
        DocTemplate(id: "purchase_order", name: "Purchase Order", category: "Business", symbol: "cart", summary: "Order goods from a supplier.", blocks: [
            .title("Purchase Order", nil), .party("Buyer", prefix: "buyer"), .party("Vendor", prefix: "vendor"),
            .fields([F("PO number"), F("Order date", .date), F("Delivery date", .date), F("Ship to", .multiline, wide: true)]),
            .table(columns: ["Item", "Qty", "Unit price", "Amount"], rows: 6, prefix: "item"),
            .totals(["Subtotal", "Shipping", "Tax", "Total"]),
            .signatures(["Authorized by"]),
        ]),
        DocTemplate(id: "packing_slip", name: "Packing Slip", category: "Business", symbol: "shippingbox", summary: "List what's in a shipment.", blocks: [
            .title("Packing Slip", nil), .party("Ship from", prefix: "from"), .party("Ship to", prefix: "to"),
            .fields([F("Order number"), F("Ship date", .date), F("Carrier"), F("Tracking number")]),
            .table(columns: ["Item", "SKU", "Qty ordered", "Qty shipped"], rows: 8, prefix: "item"),
            .fields([F("Notes", .multiline, wide: true)]),
        ]),
        DocTemplate(id: "letter", name: "Letter with Letterhead", category: "Letters", symbol: "envelope", summary: "A formal letter on your letterhead.", blocks: [
            .party("", prefix: "sender"),
            .fields([F("Date", .date, wide: true)]),
            .fields([F("Recipient", .multiline, wide: true), F("Subject", wide: true)]),
            .fields([F("Letter", .multiline, wide: true, name: "body")]),
            .signatures(["Sincerely"]),
        ]),
        DocTemplate(id: "cover_letter", name: "Cover Letter", category: "Letters", symbol: "person.text.rectangle", summary: "Introduce yourself for a job.", blocks: [
            .party("", prefix: "applicant"),
            .fields([F("Date", .date), F("Position"), F("Hiring manager", wide: true), F("Company and address", .multiline, wide: true)]),
            .fields([F("Letter", .multiline, wide: true, name: "body")]),
            .signatures(["Sincerely"]),
        ]),
        DocTemplate(id: "resume", name: "Resume", category: "Personal", symbol: "person.crop.rectangle", summary: "A one-page resume.", blocks: [
            .fields([F("Full name", wide: true), F("Title"), F("Location"), F("Email"), F("Phone"), F("Website or LinkedIn", wide: true)]),
            .heading("Summary"), .fields([F("Summary", .multiline, wide: true)]),
            .heading("Experience"),
            .fields([F("Role 1"), F("Company 1"), F("Dates 1"), F("Highlights 1", .multiline, wide: true),
                     F("Role 2"), F("Company 2"), F("Dates 2"), F("Highlights 2", .multiline, wide: true)]),
            .heading("Education"), .fields([F("School"), F("Degree"), F("Year")]),
            .heading("Skills"), .fields([F("Skills", .multiline, wide: true)]),
        ]),
        DocTemplate(id: "nda", name: "Mutual NDA", category: "Agreements", symbol: "lock.doc", summary: "Keep shared information confidential.", blocks: [
            .title("Mutual Non-Disclosure Agreement", nil), .notice(legal),
            .text("This agreement is made on {{Effective date}} between {{Party A}} and {{Party B}} (each a \u{201C}Party\u{201D}), who plan to share confidential information to evaluate {{Purpose}}."),
            .heading("1. Confidential information"),
            .text("Confidential information is anything one Party shares with the other that is marked confidential or that a reasonable person would treat as confidential. It does not include information that is public, already known to the receiving Party, received from someone else without a duty of confidence, or developed independently."),
            .heading("2. Obligations"),
            .text("The receiving Party will use confidential information only for the purpose above, protect it with reasonable care, and share it only with people who need to know it and are bound by similar duties. Disclosure required by law is allowed with prompt notice where permitted."),
            .heading("3. Term"),
            .text("This agreement lasts {{Term in years}} years from the effective date. Confidentiality duties continue for {{Survival in years}} years after it ends. On request, each Party will return or destroy the other's confidential information."),
            .heading("4. General"),
            .text("No license or other right is granted beyond what is stated. This agreement is governed by the laws of {{Governing law}}. It is the entire agreement on this subject and may be changed only in writing signed by both Parties."),
            .signatures(["Party A", "Party B"]),
        ]),
        DocTemplate(id: "bill_of_sale", name: "Bill of Sale", category: "Agreements", symbol: "car", summary: "Record the sale of a vehicle or item.", blocks: [
            .title("Bill of Sale", nil), .notice(legal), .party("Seller", prefix: "seller"), .party("Buyer", prefix: "buyer"),
            .fields([F("Item description", .multiline, wide: true), F("Make / model"), F("Year"), F("Serial or VIN", wide: true),
                     F("Sale price", .money), F("Date of sale", .date)]),
            .text("The seller sells the item above to the buyer for the price stated, and states that they own it and have the right to sell it, free of liens or claims. The item is sold {{Condition (e.g. as is)}}."),
            .signatures(["Seller", "Buyer"]),
        ]),
        DocTemplate(id: "rental", name: "Room Rental Agreement", category: "Agreements", symbol: "house", summary: "A simple month-to-month rental.", blocks: [
            .title("Rental Agreement", "Month to month"), .notice(legal),
            .fields([F("Landlord", wide: true), F("Tenant", wide: true), F("Property address", .multiline, wide: true),
                     F("Start date", .date), F("Monthly rent", .money), F("Rent due day"), F("Security deposit", .money)]),
            .text("Rent is paid by {{Payment method}}. Either party may end this agreement with {{Notice days}} days' written notice. Utilities included: {{Utilities included}}. House rules and other terms: {{Other terms}}."),
            .signatures(["Landlord", "Tenant"]),
        ]),
        DocTemplate(id: "timesheet", name: "Timesheet", category: "Work", symbol: "clock", summary: "Track hours for a week.", blocks: [
            .title("Timesheet", nil),
            .fields([F("Employee name"), F("Employee ID"), F("Manager"), F("Week starting", .date)]),
            .table(columns: ["Day", "Start", "End", "Break", "Hours"], rows: 7, prefix: "day"),
            .totals(["Total hours", "Overtime hours"]),
            .signatures(["Employee", "Manager"]),
        ]),
        DocTemplate(id: "expense_report", name: "Expense Report", category: "Work", symbol: "creditcard", summary: "Claim work expenses back.", blocks: [
            .title("Expense Report", nil),
            .fields([F("Employee name"), F("Department"), F("Period from", .date), F("Period to", .date), F("Purpose", wide: true)]),
            .table(columns: ["Date", "Description", "Category", "Amount"], rows: 10, prefix: "expense"),
            .totals(["Total", "Advances", "Amount owed"]),
            .signatures(["Employee", "Approved by"]),
        ]),
        DocTemplate(id: "minutes", name: "Meeting Minutes", category: "Work", symbol: "person.3", summary: "Record decisions and actions.", blocks: [
            .title("Meeting Minutes", nil),
            .fields([F("Meeting"), F("Date", .date), F("Time"), F("Location"), F("Attendees", .multiline, wide: true)]),
            .heading("Agenda and notes"), .fields([F("Notes", .multiline, wide: true)]),
            .heading("Decisions"), .fields([F("Decisions", .multiline, wide: true)]),
            .table(columns: ["Action", "Owner", "Due"], rows: 6, prefix: "action"),
            .fields([F("Next meeting", wide: true)]),
        ]),
        DocTemplate(id: "vendor_form", name: "Vendor Information Form", category: "Business", symbol: "building.2", summary: "Collect a supplier's details.", blocks: [
            .title("Vendor Information", nil),
            .fields([F("Legal business name", wide: true), F("Trade name (DBA)", wide: true), F("Business type"), F("Tax ID"),
                     F("Address", .multiline, wide: true), F("Contact name"), F("Contact email"), F("Phone"), F("Website")]),
            .heading("Payment"), .fields([F("Bank name"), F("Account name"), F("Payment terms"), F("Remittance email")]),
            .checklist(["Certificate of insurance attached", "Tax form provided separately"], prefix: "vendor"),
            .signatures(["Authorized signer"]),
        ]),
        DocTemplate(id: "job_application", name: "Job Application", category: "Work", symbol: "briefcase", summary: "Apply for a position.", blocks: [
            .title("Employment Application", nil),
            .fields([F("Position applied for", wide: true), F("Full name", wide: true), F("Email"), F("Phone"), F("Address", .multiline, wide: true),
                     F("Available start date", .date), F("Desired pay")]),
            .heading("Experience"), .fields([F("Most recent employer"), F("Role"), F("Dates"), F("Duties", .multiline, wide: true)]),
            .heading("Education"), .fields([F("School"), F("Degree or certificate")]),
            .checklist(["I am legally allowed to work in this country", "I can provide references on request"], prefix: "applicant"),
            .text("I confirm the information above is true and complete."),
            .signatures(["Applicant"]),
        ]),
        DocTemplate(id: "consent", name: "Consent Form", category: "Personal", symbol: "checkmark.shield", summary: "Get informed consent for an activity or service.", blocks: [
            .title("Consent Form", nil), .notice(legal),
            .fields([F("Participant name", wide: true), F("Date of birth", .date), F("Phone"), F("Activity or service", wide: true)]),
            .text("I understand what {{Activity or service, again}} involves, including its risks and benefits as explained by {{Provider}}. I had the chance to ask questions. I agree to take part and know I may withdraw at any time."),
            .fields([F("Medical notes or allergies", .multiline, wide: true), F("Emergency contact", wide: true)]),
            .signatures(["Participant", "Parent or guardian (if under 18)"]),
        ]),
        DocTemplate(id: "permission_slip", name: "Permission Slip", category: "Personal", symbol: "figure.and.child.holdinghands", summary: "Parent permission for a trip or event.", blocks: [
            .title("Permission Slip", nil), .notice(legal),
            .fields([F("Event or trip", wide: true), F("Date", .date), F("Location"), F("Departure time"), F("Return time")]),
            .text("I give permission for {{Child's name}} to take part in the event above. In an emergency, staff may seek medical care if I can't be reached at {{Parent phone}}."),
            .fields([F("Medical notes or allergies", .multiline, wide: true)]),
            .signatures(["Parent or guardian"]),
        ]),
        DocTemplate(id: "certificate", name: "Certificate", category: "Personal", symbol: "rosette", summary: "Recognize an achievement.", blocks: [
            .title("Certificate of Completion", "This certifies that"),
            .fields([F("Recipient name", wide: true), F("Has completed", wide: true), F("Date", .date), F("Organization")]),
            .signatures(["Presented by"]),
        ]),
        DocTemplate(id: "event_registration", name: "Event Registration / RSVP", category: "Personal", symbol: "calendar.badge.plus", summary: "Sign up for an event.", blocks: [
            .title("Event Registration", nil),
            .fields([F("Event", wide: true), F("Date", .date), F("Full name", wide: true), F("Email"), F("Phone"), F("Number of guests", .number)]),
            .checklist(["I will attend", "I can't attend", "Vegetarian meal", "Needs accessibility support"], prefix: "rsvp"),
            .fields([F("Comments", .multiline, wide: true)]),
        ]),
    ]

    public static func find(_ id: String) -> DocTemplate? {
        let q = id.lowercased()
        return all.first { $0.id == q } ?? all.first { $0.name.lowercased() == q } ?? all.first { $0.name.lowercased().contains(q) }
    }

    // MARK: HTML

    /// Every field name in the template, in order.
    public var fieldNames: [String] {
        var out: [String] = []
        for b in blocks {
            switch b {
            case .party(_, let p): out += ["name", "address", "email", "phone"].map { "\(p)_\($0)" }
            case .fields(let fs): out += fs.map(\.name)
            case .table(let cols, let rows, let p): for r in 1...rows { out += cols.map { "\(p)\(r)_\(Self.slug($0))" } }
            case .totals(let ts): out += ts.map(Self.slug)
            case .checklist(let items, let p): out += items.map { "\(p)_\(Self.slug($0))" }
            case .text(let t): out += Self.inlineLabels(t).map(Self.slug)
            case .signatures(let s): out += s.map { Self.slug($0) + "_date" }
            default: break
            }
        }
        return out
    }

    static func inlineLabels(_ t: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"\{\{([^}]+)\}\}"#)
        return re.matches(in: t, range: NSRange(t.startIndex..., in: t)).compactMap { m in Range(m.range(at: 1), in: t).map { String(t[$0]) } }
    }

    func html() -> String {
        func e(_ s: String) -> String { ArticleHTML.escape(s) }
        func field(_ name: String, _ type: FieldType, label: String? = nil) -> String {
            "<span class=\"f \(type.rawValue)\" data-field=\"\(e(name))\" data-type=\"\(type.rawValue)\">\u{00A0}</span>"
        }
        var body = ""
        var inParties = false
        for b in blocks {
            if case .party = b { if !inParties { body += "<div class=\"parties\">"; inParties = true } }
            else if inParties { body += "</div>"; inParties = false }
            switch b {
            case .title(let t, let sub):
                body += "<header><h1>\(e(t))</h1>\(sub.map { "<p class=\"sub\">\(e($0))</p>" } ?? "")</header>"
            case .party(let label, let p):
                body += "<section class=\"party\">\(label.isEmpty ? "" : "<h3>\(e(label))</h3>")"
                for (l, k) in [("Name", "name"), ("Address", "address"), ("Email", "email"), ("Phone", "phone")] {
                    let wide = k == "name" || k == "address"
                    body += "<div class=\"row\(wide ? " wide" : "")\"><label>\(l)</label>\(field("\(p)_\(k)", k == "address" ? .multiline : .text))</div>"
                }
                body += "</section>"
            case .fields(let fs):
                let short = fs.allSatisfy { !$0.wide && $0.type != .multiline }
                body += "<section class=\"grid\(short && fs.count >= 3 ? " quad" : "")\">"
                for f in fs {
                    body += "<div class=\"cell\(f.wide || f.type == .multiline ? " wide" : "")\"><label>\(e(f.label))</label>\(field(f.name, f.type))</div>"
                }
                body += "</section>"
            case .heading(let h):
                body += "<h2>\(e(h))</h2>"
            case .text(let t):
                var out = e(t)
                for label in Self.inlineLabels(t) {
                    out = out.replacingOccurrences(of: "{{\(e(label))}}", with: "<span class=\"f inline\" data-field=\"\(Self.slug(label))\" data-type=\"text\" title=\"\(e(label))\">\u{00A0}</span>")
                }
                body += "<p class=\"terms\">\(out)</p>"
            case .table(let cols, let rows, let p):
                body += "<table><thead><tr>" + cols.map { "<th>\(e($0))</th>" }.joined() + "</tr></thead><tbody>"
                for r in 1...rows {
                    body += "<tr>" + cols.map { "<td>\(field("\(p)\(r)_\(Self.slug($0))", .text))</td>" }.joined() + "</tr>"
                }
                body += "</tbody></table>"
            case .totals(let ts):
                body += "<section class=\"totals\">" + ts.map { "<div class=\"row\"><label>\(e($0))</label>\(field(Self.slug($0), .money))</div>" }.joined() + "</section>"
            case .checklist(let items, let p):
                body += "<section class=\"checks\">" + items.map { "<div class=\"check\">\(field("\(p)_\(Self.slug($0))", .checkbox))<span>\(e($0))</span></div>" }.joined() + "</section>"
            case .signatures(let labels):
                body += "<section class=\"sigs\">" + labels.map { l in
                    "<div class=\"sig\"><div class=\"line\"></div><label>\(e(l)) signature</label><div class=\"row\"><label>Date</label>\(field(Self.slug(l) + "_date", .date))</div></div>"
                }.joined() + "</section>"
            case .notice(let n):
                body += "<p class=\"notice\">\(e(n))</p>"
            }
        }
        if inParties { body += "</div>" }
        return body
    }

    static let css = """
    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; background: #fff; }
    body { width: var(--content-w); font: 10.5px/1.45 -apple-system, "Helvetica Neue", Helvetica, sans-serif; color: #1c1c1e; }
    header { margin-bottom: 12px; }
    h1 { font-size: 24px; letter-spacing: -0.01em; margin: 0; }
    .sub { margin: 4px 0 0; color: #6e6e73; font-size: 12px; }
    h2 { font-size: 13px; margin: 16px 0 6px; padding-bottom: 3px; border-bottom: 1px solid #d1d1d6; }
    h3 { font-size: 10px; text-transform: uppercase; letter-spacing: .06em; color: #6e6e73; margin: 0 0 4px; }
    label { display: block; font-size: 8.5px; color: #6e6e73; text-transform: uppercase; letter-spacing: .04em; margin-bottom: 2px; }
    .f { display: block; min-height: 18px; border-bottom: 1px solid #aeaeb2; }
    .f.multiline { min-height: 46px; border: 1px solid #c7c7cc; border-radius: 3px; }
    .party .f.multiline { min-height: 32px; }
    .parties { display: flex; gap: 20px; margin: 4px 0 10px; }
    .parties .party { flex: 1; margin: 0; row-gap: 4px; }
    .grid.quad { grid-template-columns: repeat(4, 1fr); }
    .f.checkbox { display: inline-block; width: 12px; min-height: 12px; height: 12px; border: 1px solid #8e8e93; border-radius: 2px; vertical-align: middle; margin-right: 6px; }
    .f.inline { display: inline-block; min-width: 120px; min-height: 14px; vertical-align: baseline; }
    .party { margin: 8px 0 12px; display: grid; grid-template-columns: 1fr 1fr; column-gap: 14px; row-gap: 6px; }
    .party h3 { grid-column: 1 / -1; }
    .party .row.wide { grid-column: 1 / -1; }
    .grid { display: grid; grid-template-columns: 1fr 1fr; column-gap: 14px; row-gap: 6px; margin: 6px 0 10px; }
    .cell.wide { grid-column: 1 / -1; }
    table { width: 100%; border-collapse: collapse; margin: 10px 0; }
    th { text-align: left; font-size: 8.5px; text-transform: uppercase; letter-spacing: .04em; color: #6e6e73; border-bottom: 1.5px solid #1c1c1e; padding: 4px 6px; }
    td { padding: 2px 6px; border-bottom: 1px solid #e5e5ea; }
    td .f { border-bottom: none; min-height: 17px; }
    .totals { margin: 6px 0 14px auto; width: 45%; }
    .totals .row { display: grid; grid-template-columns: 1fr 1fr; align-items: end; column-gap: 8px; margin-bottom: 4px; }
    .totals .row:last-child label { color: #1c1c1e; font-weight: 600; }
    .checks { margin: 8px 0 12px; }
    .check { margin: 5px 0; display: flex; align-items: center; }
    .terms { text-align: left; margin: 6px 0; line-height: 1.7; }
    .notice { font-size: 9px; color: #8a6d00; background: #fff8e1; border: 1px solid #f2d27a; border-radius: 4px; padding: 6px 8px; }
    .sigs { display: flex; gap: 28px; margin-top: 28px; }
    .sig { flex: 1; }
    .sig .line { height: 36px; border-bottom: 1px solid #1c1c1e; }
    .sig .row { margin-top: 8px; }
    """

    func document(width: CGFloat) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><title>\(ArticleHTML.escape(name))</title>
        <style>:root{--content-w:\(width)px}</style><style>\(Self.css)</style></head>
        <body>\(html())</body></html>
        """
    }
}
