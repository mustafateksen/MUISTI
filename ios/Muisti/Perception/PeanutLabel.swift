import Foundation

/// A source quotation, never a claim that the product is safe to eat.
struct PeanutLabel: Sendable {
    enum Reading: String, Sendable {
        case contains, possible, inspect, unreadable
        var message: String {
            switch self {
            case .contains: return "Peanut warning. The label says it contains peanuts."
            case .possible: return "Peanut warning. The label says it may contain peanuts."
            case .unreadable: return "I can see a label but cannot verify the peanut warning. Please show the full label."
            case .inspect: return "I couldn't verify the peanut wording. Please check the label."
            }
        }
    }
    let reading: Reading
    let quotes: [String]
    let lineNumbers: [Int]
    let hash: UInt64
    let frame: UUID
    let at: Date

    private static let markers: [String: Reading] = [
        "contains": .contains, "sisältää": .contains, "innehåller": .contains,
        "may contain": .possible, "may contain traces of": .possible,
        "saattaa sisältää": .possible, "kan innehålla": .possible, "kan innehålla spår av": .possible
    ]
    private static let nouns: Set<String> = ["peanut", "peanuts", "maapähkinä", "maapähkinät", "maapähkinää", "jordnöt", "jordnötter"]
    typealias Line = PerceptionEngine.TextLine
    static func normalized(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }
    static func mentions(_ s: String) -> Bool {
        ["peanut","maapähkin","jordnöt"].contains { normalized(s).contains($0) }
    }
    static func freeClaim(_ s: String) -> Bool {
        ["peanut-free","peanut free","does not contain peanuts","contains no peanuts",
         "maapähkinätön","jordnötsfri"].contains(normalized(s))
    }
    private static let headings = ["ingredients","ainesosat","ingredienser"]
    static func panel(_ s: String) -> Bool {
        let text = normalized(s)
        return headings.contains { text == $0 || text.hasPrefix($0 + ":") || text.hasPrefix($0 + " /") }
    }

    // Entire list items are matched, preserving the scope of "may contain".
    // Unsupported adjectives or clauses cause an inspect result.
    static func explicit(_ raw: String) -> Reading? {
        var text = normalized(raw)
        for prefix in ["this product ", "also, "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        let others: Set<String> = ["milk","soy","soya","almond","almonds","nuts","other nuts",
            "tree nuts","other tree nuts","egg","eggs","wheat","sesame","gluten","maitoa",
            "hasselpähkinää","mjölk","hasselnötter"]
        for (marker, reading) in markers {
            guard text.hasPrefix(marker + ":") || text.hasPrefix(marker + " ") else { continue }
            let body = String(text.dropFirst(marker.count)).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            let list = body.replacingOccurrences(of: " and ", with: ",")
                .replacingOccurrences(of: " och ", with: ",").replacingOccurrences(of: " ja ", with: ",")
                .components(separatedBy: ",").map { normalized($0) }
            if list.contains(where: nouns.contains), list.allSatisfy({ nouns.contains($0) || others.contains($0) }) { return reading }
        }
        if text.hasPrefix("contains"), text.contains(","), !text.contains(" ") {
            var body = String(text.dropFirst("contains".count))
            if body.hasSuffix("ingredients") { body.removeLast("ingredients".count) }
            let tokens = body.replacingOccurrences(of:"and",with:",").components(separatedBy:",")
            if tokens.contains(where:nouns.contains), tokens.allSatisfy({ nouns.contains($0) || others.contains($0) }) {
                return .contains
            }
        }
        for header in headings where text.hasPrefix(header + ":") {
            let body = normalized(String(text.dropFirst(header.count + 1)))
            let first = String(body.prefix(while: { $0 != "," && $0 != ";" }))
            if first.range(of: #"^(?:(?:hi-oleic|roasted) )?(?:peanuts?|maapähkinät|jordnötter)(?: [0-9]+(?:\.[0-9]+)?%)?$"#, options: .regularExpression) != nil {
                return .contains
            }
        }
        return nil
    }

    static func neighbors(_ a: CGRect, _ b: CGRect) -> Bool {
        let h = min(a.height,b.height), w = min(a.width,b.width)
        let gap = a.minY - b.maxY
        return b.midY < a.midY && gap >= -0.15*h && gap <= 1.2*h &&
            abs(a.minX-b.minX) <= min(0.05, 0.25*w) && min(a.maxX,b.maxX)-max(a.minX,b.minX) >= 0.75*w
    }

    static func evaluate(_ lines: [Line], hash: UInt64, frame: CapturedFrame,
                         retry: ((Int) -> Line?)? = nil) -> Self? {
        var hits: [(Reading,[Int],[String])] = []
        var free: [Int] = []
        var consumed = Set<Int>()
        func inside(_ box: CGRect) -> Bool {
            box.minX > 0.01 && box.maxX < 0.99 && box.minY > 0.01 && box.maxY < 0.99
        }
        func prefixAmbiguous(_ i: Int) -> Bool {
            let qualifiers = ["not","does not","may","without","no","ei","saattaa","kan","inte"]
            return lines.indices.contains { j in
                let t = normalized(lines[j].text)
                return neighbors(lines[j].box,lines[i].box) && qualifiers.contains { t == $0 || t.hasSuffix(" " + $0) }
            }
        }
        for i in lines.indices {
            let line = lines[i]
            let marker = normalized(line.text).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            guard let reading = markers[marker], inside(line.box), line.confidence >= 0.90, !prefixAmbiguous(i) else { continue }
            let near = lines.indices.filter { neighbors(line.box, lines[$0].box) }
            if near.count == 1, let j = near.first, inside(lines[j].box), lines[j].confidence >= 0.90,
               nouns.contains(normalized(lines[j].text)), !consumed.contains(j) {
                hits.append((reading,[i,j],[line.text,lines[j].text]))
                consumed.insert(j)
            }
        }
        // Require an unbroken same-column ingredient block, a unique heading,
        // and known ingredient words all the way to the isolated noun.
        let headers = lines.indices.filter { headings.contains(normalized(lines[$0].text).trimmingCharacters(in: CharacterSet(charactersIn: ": "))) }
        let foodWords = Set(["milk","chocolate","sugar","cocoa","butter","skim","lactose","milkfat",
                             "soy","lecithin","peanuts","peanut","corn","syrup","salt","oil","palm"])
        if headers.count == 1, let head = headers.first, inside(lines[head].box), lines[head].confidence >= 0.90 {
            for j in lines.indices where !consumed.contains(j) && nouns.contains(normalized(lines[j].text)) {
                let a = lines[head].box, b = lines[j].box
                guard b.midY < a.midY, a.midY-b.midY < 4*a.height,
                      a.minY > b.minY, lines[j].confidence >= 0.90, inside(b) else { continue }
                let indices = lines.indices.filter { lines[$0].box.midY <= a.midY+a.height*0.4 &&
                    lines[$0].box.midY >= b.midY-b.height*0.4 }.sorted { lines[$0].box.midY > lines[$1].box.midY }
                var rows = [[Int]]()
                for k in indices {
                    if let first = rows.last?.first, lines[first].box.midY-lines[k].box.midY <= 0.55*a.height {
                        rows[rows.count-1].append(k)
                    } else { rows.append([k]) }
                }
                let ordered = rows.map { row in row.sorted { lines[$0].box.minX < lines[$1].box.minX } }
                guard ordered.first?.first == head, ordered.last?.contains(j) == true else { continue }
                let coherent = ordered.enumerated().allSatisfy { index, row in
                    guard let first = row.first, abs(lines[first].box.minX-a.minX) <= 0.04 else { return false }
                    if index > 0, let prev = ordered[index-1].first,
                       lines[prev].box.midY-lines[first].box.midY > 1.7*a.height { return false }
                    for (offset,k) in row.enumerated() {
                        let item = lines[k]
                        if offset > 0 && item.box.minX-lines[row[offset-1]].box.maxX > 0.075 { return false }
                        if k == head { continue }
                        let tokens = normalized(item.text).split { !$0.isLetter }.map(String.init)
                        if item.confidence < 0.90 || tokens.isEmpty || !tokens.allSatisfy(foodWords.contains) { return false }
                    }
                    return true
                }
                if coherent {
                    consumed.insert(j)
                    hits.append((.contains,[head,j],[lines[head].text,lines[j].text]))
                }
            }
        }
        var retries = 0
        for i in lines.indices where !consumed.contains(i) {
            let line = lines[i]
            guard mentions(line.text) else { continue }
            if freeClaim(line.text) && line.confidence >= 0.90 && inside(line.box) { free.append(i); continue }
            var status = Reading.inspect
            var quotes = [line.text]
            if let reading = explicit(line.text), inside(line.box), !prefixAmbiguous(i) {
                if line.confidence >= 0.90 { status = reading }
                else if line.confidence >= 0.65 && retries < 2, let retry {
                    retries += 1
                    if let second = retry(i), second.confidence >= 0.90, explicit(second.text) == reading,
                       normalized(line.text).filter({ $0.isLetter || $0.isNumber }) ==
                       normalized(second.text).filter({ $0.isLetter || $0.isNumber }) {
                        status = reading
                        quotes.append(second.text)
                    }
                }
            }
            hits.append((status,[i],quotes))
        }
        guard let first = hits.first else {
            // On a recognizable ingredients panel, an incomplete read never means absence.
            guard free.isEmpty, let i = lines.firstIndex(where: { panel($0.text) }),
                  lines.count < 3 || lines.filter({ $0.confidence >= 0.90 }).count < 2 else { return nil }
            return Self(reading:.unreadable,quotes:[lines[i].text],lineNumbers:[i+1],hash:hash,frame:frame.id,at:frame.capturedAt)
        }
        let reading: Reading = free.isEmpty && hits.allSatisfy { $0.0 == first.0 } ? first.0 : .inspect
        return Self(reading:reading,quotes:hits.flatMap { $0.2 } + free.map { lines[$0].text },
                    lineNumbers:hits.flatMap { $0.1.map { $0+1 } } + free.map { $0+1 },
                    hash:hash,frame:frame.id,at:frame.capturedAt)
    }
}
