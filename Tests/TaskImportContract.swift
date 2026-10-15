import Foundation

@main struct Contract {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let fixtures = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        let result: [[String: Any]] = fixtures.map { fixture in
            let text = fixture["text"] as! String
            do {
                var doc = try TaskDocument(markdown: text)
                // Exercise a real native mutation, not only parsing.
                if fixture["mutate"] as? Bool == true, !doc.tasks.isEmpty { doc.tasks[0].title += " edited" }
                let canonical = doc.markdown
                let again = try TaskDocument(markdown: canonical)
                precondition(again.markdown == canonical)
                return ["name": fixture["name"]!, "accepted": true, "text": canonical]
            } catch { return ["name": fixture["name"]!, "accepted": false, "error": error.localizedDescription] }
        }
        let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(output)
    }
}
