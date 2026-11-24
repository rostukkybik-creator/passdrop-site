// The central price updater. Reads every `priceRules` entry in the catalog, fetches the page or endpoint,
// extracts the amount, and when a pass price differs from the tier in force it closes that tier yesterday
// and opens an "Observed price" tier today, bumping the catalog version. Day-ticket rules update
// `tickets`. Prints one line per change and exits 3 when something changed, so a workflow can commit.
//
// Runs anywhere Swift and Foundation run (the site repo's GitHub Action uses the swift Linux image), so it
// avoids Apple-only frameworks. The regex engine is NSRegularExpression (in swift-corelibs-foundation).
//
// Usage: swift Tools/catalog-update.swift <catalog.json> [--dry-run] [--today YYYY-MM-DD]
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct Rule: Codable { var url: String; var pattern: String; var kind: String?; var label: String?; var resortName: String?; var region: String?; var minCents: Int?; var maxCents: Int? }
struct Tier: Codable { var label: String; var priceCents: Int; var validFrom: String?; var validUntil: String?; var sourceURL: String; var verifiedOn: String }
struct Ticket: Codable { var resortName: String; var region: String; var label: String; var priceCents: Int; var previousCents: Int?; var sourceURL: String; var observedOn: String }

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: swift catalog-update.swift <catalog.json> [--dry-run] [--today YYYY-MM-DD]"); exit(2) }
let path = args[1]
let dryRun = args.contains("--dry-run")
var today: String = {
    if let i = args.firstIndex(of: "--today"), i + 1 < args.count { return args[i + 1] }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "America/Denver"); return f.string(from: Date())
}()
func dayBefore(_ day: String) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
    guard let d = f.date(from: day) else { return day }
    return f.string(from: d.addingTimeInterval(-86400))
}

let data = try! Data(contentsOf: URL(fileURLWithPath: path))
var root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
var passes = root["passes"] as! [[String: Any]]
var tickets = (root["tickets"] as? [[String: Any]]) ?? []
var changes: [String] = []

func fetch(_ url: String) -> String? {
    guard let u = URL(string: url) else { return nil }
    var request = URLRequest(url: u)
    request.timeoutInterval = 25
    request.setValue("PassDrop catalog updater/1.0 (+https://rostukkybik-creator.github.io/passdrop-site/support.html)", forHTTPHeaderField: "User-Agent")
    request.setValue("text/html,application/json", forHTTPHeaderField: "Accept")
    let sem = DispatchSemaphore(value: 0)
    var body: String?
    URLSession.shared.dataTask(with: request) { d, r, _ in
        if let d, let http = r as? HTTPURLResponse, (200..<300).contains(http.statusCode) { body = String(decoding: d.prefix(3_000_000), as: UTF8.self) }
        sem.signal()
    }.resume()
    sem.wait()
    return body
}

func extract(_ text: String, _ rule: Rule) -> Int? {
    guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { print("  bad pattern for \(rule.label ?? rule.url)"); return nil }
    let ns = text as NSString
    for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 2 {
        let raw = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
        guard let v = Double(raw) else { continue }
        let cents = Int((v * 100).rounded())
        let lo = rule.minCents ?? 1000, hi = rule.maxCents ?? 500_000
        if (lo...hi).contains(cents) { return cents }
    }
    return nil
}

func money(_ c: Int) -> String { "$" + String(format: "%.0f", Double(c) / 100).replacingOccurrences(of: "\\B(?=(\\d{3})+(?!\\d))", with: ",", options: .regularExpression) }

for (i, pass) in passes.enumerated() {
    let slug = pass["slug"] as? String ?? "?"
    guard let rulesJSON = pass["priceRules"], let rulesData = try? JSONSerialization.data(withJSONObject: rulesJSON), let rules = try? JSONDecoder().decode([Rule].self, from: rulesData), !rules.isEmpty else { continue }
    var tiers = (try? JSONDecoder().decode([Tier].self, from: JSONSerialization.data(withJSONObject: pass["tiers"] ?? []))) ?? []
    for rule in rules {
        guard let body = fetch(rule.url) else { print("\(slug): could not read \(rule.url)"); continue }
        guard let cents = extract(body, rule) else { print("\(slug): no price found at \(rule.url)"); continue }
        if (rule.kind ?? "pass") == "dayTicket" {
            let name = rule.resortName ?? slug, region = rule.region ?? ""
            let idx = tickets.firstIndex { ($0["resortName"] as? String) == name && ($0["region"] as? String) == region }
            let previous = idx.flatMap { tickets[$0]["priceCents"] as? Int }
            if previous != cents {
                let t: [String: Any] = ["resortName": name, "region": region, "label": rule.label ?? "Window ticket", "priceCents": cents, "previousCents": previous as Any, "sourceURL": rule.url, "observedOn": today]
                if let idx { tickets[idx] = t } else { tickets.append(t) }
                changes.append("\(name) \(rule.label ?? "ticket"): \(previous.map(money) ?? "new") -> \(money(cents))")
            }
            continue
        }
        // Pass price: compare with the tier in force today.
        let inForce = tiers.firstIndex { ($0.validFrom ?? "0000") <= today && ($0.validUntil ?? "9999") >= today }
        let current = inForce.map { tiers[$0].priceCents }
        if current == cents { continue }
        if let inForce, tiers[inForce].validFrom == today { tiers[inForce].priceCents = cents; tiers[inForce].verifiedOn = today; tiers[inForce].sourceURL = rule.url }
        else {
            if let inForce { tiers[inForce].validUntil = dayBefore(today) }
            let salesEnd = pass["salesEnd"] as? String
            tiers.append(Tier(label: "Observed price", priceCents: cents, validFrom: today, validUntil: salesEnd, sourceURL: rule.url, verifiedOn: today))
        }
        changes.append("\(slug) \(rule.label ?? "pass"): \(current.map(money) ?? "new") -> \(money(cents))")
        passes[i]["tiers"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(tiers))
    }
}

if changes.isEmpty { print("No price changes (\(today))."); exit(0) }
for c in changes { print("CHANGED \(c)") }
if dryRun { print("Dry run: catalog not written."); exit(3) }
root["passes"] = passes
root["tickets"] = tickets
root["version"] = (root["version"] as? Int ?? 0) + 1
root["updatedAt"] = today
let out = try! JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
try! out.write(to: URL(fileURLWithPath: path))
print("Wrote \(path), version \(root["version"]!).")
exit(3)
