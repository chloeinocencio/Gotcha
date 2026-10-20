import Foundation

enum Affirmations {
    static let all: [String] = [
        "I am living my dream life. I have my dream career and money flows easily and effortlessly to me.",
        "I am extremely attractive both physically and emotionally. My energy attracts friends and romantic interests with little to no effort.",
        "I easily attract anyone I want. I am extremely attractive and I can attract anyone I want in my love life.",
        "I have the wealth to afford anything I want. I am living a luxurious lifestyle. I do not work hard, money comes to me easily.",
        "I am special, one of a kind and this makes me shine. I attract opportunities to advance in all areas of my life with little effort.",
        "My dream life is falling into place. I always surpass my own expectations.",
        "I'm so grateful that I'm living my dream life. I have everything I ever wanted.",
        "I am the best at everything I do and I gain widespread recognition & notoriety for my accomplishments.",
        "I attract positive attention everywhere I go. I am in the spotlight, my reputation precedes me."
    ]
}

/// A shuffled deck: every message appears once per round before any repeats.
struct Deck: Codable {
    var order: [Int]
    var pos: Int
    var round: Int

    static func fresh(avoiding last: Int?, round: Int) -> Deck {
        var order = Array(0..<Affirmations.all.count).shuffled()
        if let last, order.first == last, order.count > 1 { order.swapAt(0, 1) }
        return Deck(order: order, pos: 0, round: round)
    }
}

struct DrawnMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let number: Int
}

final class DeckStore {
    private let key = "gotcha.deck.v1"
    private(set) var deck: Deck

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(Deck.self, from: data),
           saved.order.count == Affirmations.all.count,
           (0...saved.order.count).contains(saved.pos) {
            deck = saved
        } else {
            deck = .fresh(avoiding: nil, round: 1)
        }
    }

    var remaining: Int { deck.order.count - deck.pos }
    var total: Int { deck.order.count }

    func draw() -> DrawnMessage {
        if deck.pos >= deck.order.count {
            deck = .fresh(avoiding: deck.order.last, round: deck.round + 1)
        }
        let index = deck.order[deck.pos]
        deck.pos += 1
        if let data = try? JSONEncoder().encode(deck) { UserDefaults.standard.set(data, forKey: key) }
        return DrawnMessage(text: Affirmations.all[index], number: deck.pos)
    }
}
